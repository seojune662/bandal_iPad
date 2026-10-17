import Foundation

final class NativePlannerRepository {
    private let context: NativeRepositoryContext
    init(context: NativeRepositoryContext) { self.context = context }
    private let fields = ["id":"id", "course_id":"courseId", "title":"title", "notes":"notes", "status":"status", "kind":"kind", "color":"color", "start_at":"startAt", "due_at":"dueAt", "sort_order":"sortOrder", "created_at":"createdAt", "updated_at":"updatedAt"]
    private func task(_ row: [String: Any]) -> [String: Any] {
        var result = NativeValue.mapped(row, fields); result["allDay"] = (row["all_day"] as? NSNumber)?.boolValue ?? false; return result
    }
    private func get(_ id: String) throws -> [String: Any] {
        guard let row = try context.db.query("SELECT * FROM board_tasks WHERE id = ? AND deleted_at IS NULL", params: [id]).first else { throw DesktopRuntimeError("일정을 찾을 수 없습니다.", code: "NOT_FOUND") }; return task(row)
    }
    private func choice(_ value: Any?, _ choices: [String], _ name: String) throws -> String {
        guard let text = value as? String, choices.contains(text) else { throw DesktopRuntimeError("올바르지 않은 \(name)입니다.", code: "VALIDATION_ERROR") }; return text
    }
    private func day(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; return format.string(from: date)
    }
    private func parseDay(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard value.count == 10, let date = f.date(from: value), f.string(from: date) == value else { return nil }; return date
    }
    private func schedule(_ value: Any?, allDay: Bool, converting: Bool) throws -> Any {
        guard let value, !(value is NSNull) else { return NativeValue.null }
        let text = try NativeValue.string(value, "날짜")
        if let date = parseDay(text) {
            if allDay { return text }
            if converting { return ISO8601DateFormatter().string(from: date) }
        }
        guard let date = NativeValue.date(text) else { throw DesktopRuntimeError("일정 날짜를 확인해 주세요.", code: "VALIDATION_ERROR") }
        return allDay ? day(date) : ISO8601DateFormatter().string(from: date)
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        switch channel {
        case "board:listTasks", "calendar:range", "calendar:upcoming":
            var clauses = ["deleted_at IS NULL", "(course_id IS NULL OR EXISTS (SELECT 1 FROM courses c WHERE c.id = board_tasks.course_id AND c.deleted_at IS NULL))"]
            var parameters: [Any] = []
            if request["courseId"] is NSNull { clauses.append("course_id IS NULL") }
            else if let course = request["courseId"] { clauses.append("course_id = ?"); parameters.append(try NativeValue.string(course, "과목")) }
            if request["includeDone"] as? Bool != true && channel != "calendar:range" { clauses.append("status != 'done'") }
            var values = try context.db.query("SELECT * FROM board_tasks WHERE \(clauses.joined(separator: " AND ")) ORDER BY status,sort_order,created_at", params: parameters).map(task)
            if channel == "calendar:range" {
                guard let from = NativeValue.date(try NativeValue.string(request["from"], "시작")), let to = NativeValue.date(try NativeValue.string(request["to"], "종료")), from < to else { throw DesktopRuntimeError("일정 조회 범위를 확인해 주세요.") }
                values = values.filter { value in
                    guard let due = value["dueAt"] as? String else { return false }
                    if value["allDay"] as? Bool == true { return due >= day(from) && (value["startAt"] as? String ?? due) <= day(to.addingTimeInterval(-0.001)) }
                    guard let end = NativeValue.date(due), let start = NativeValue.date(value["startAt"] as? String ?? due) else { return false }
                    return (end > from || (end == from && start == end)) && start < to
                }
                return values.sorted { ($0["dueAt"] as? String ?? "") < ($1["dueAt"] as? String ?? "") }
            }
            if channel == "calendar:upcoming" {
                let now = Date(), days = try NativeValue.int(request["withinDays"] ?? 14, "기간", max: 3650), limit = try NativeValue.int(request["limit"] ?? 5, "개수", min: 1, max: 1000)
                let end = Calendar.current.date(byAdding: .day, value: days + 1, to: Calendar.current.startOfDay(for: now))!
                return try values.compactMap { value -> (Date, Bool, [String: Any])? in
                    guard let raw = value["dueAt"] as? String, let due = parseDay(raw) ?? NativeValue.date(raw), due < end else { return nil }
                    let left = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: due)).day ?? 0
                    let overdue = value["allDay"] as? Bool == true ? left < 0 : due < now
                    let name = try context.db.query("SELECT name FROM courses WHERE id = ?", params: [value["courseId"] ?? NativeValue.null]).first?["name"] ?? NativeValue.null
                    return (due, overdue, ["task": value, "courseName": name, "daysLeft": left, "overdue": overdue])
                }.sorted { $0.1 != $1.1 ? $0.1 : ($0.1 ? $0.0 > $1.0 : $0.0 < $1.0) }.prefix(limit).map { $0.2 }
            }
            return values
        case "board:createTask", "board:updateTask":
            let creating = channel == "board:createTask", now = NativeValue.now()
            let id = creating ? UUID().uuidString : try NativeValue.string(request["id"], "일정")
            let previous: [String: Any] = creating ? ["courseId": NativeValue.null, "title": "", "notes": "", "status": "todo", "kind": "task", "color": "none", "allDay": false, "createdAt": now] : try get(id)
            var value = previous.merging(request) { _, new in new }
            value["id"] = id; value["title"] = try NativeValue.string(value["title"], "제목").trimmingCharacters(in: .whitespacesAndNewlines)
            guard value["notes"] is String, let allDay = value["allDay"] as? Bool else { throw DesktopRuntimeError("일정 형식을 확인해 주세요.") }
            value["status"] = try choice(value["status"], ["todo","in-progress","done"], "상태")
            value["kind"] = try choice(value["kind"], ["task","assignment","exam","class"], "종류")
            value["color"] = try choice(value["color"], ["none","red","orange","yellow","green","blue","violet"], "색상")
            if let course = value["courseId"] as? String { _ = try context.courseFolder(course) }
            value["dueAt"] = try schedule(value["dueAt"], allDay: allDay, converting: request["dueAt"] == nil)
            value["startAt"] = value["dueAt"] is NSNull && request["startAt"] == nil ? NativeValue.null : try schedule(value["startAt"], allDay: allDay, converting: request["startAt"] == nil)
            if let start = value["startAt"] as? String { guard let end = value["dueAt"] as? String, start <= end else { throw DesktopRuntimeError("종료 날짜와 시각은 시작보다 빠를 수 없습니다.") } }
            if let sort = request["sortOrder"] { value["sortOrder"] = try NativeValue.int(sort, "순서") }
            else if creating || value["status"] as? String != previous["status"] as? String || value["courseId"] as? String != previous["courseId"] as? String {
                let row = try context.db.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS n FROM board_tasks WHERE deleted_at IS NULL AND status = ? AND course_id IS ?", params: [value["status"]!, value["courseId"] ?? NativeValue.null]).first
                value["sortOrder"] = row?["n"] ?? 0
            }
            value["updatedAt"] = now
            let columns = ["id","course_id","title","notes","status","kind","color","start_at","due_at","sort_order","created_at","updated_at"]
            let args = columns.map { value[fields[$0]!] ?? NativeValue.null } + [allDay ? 1 : 0]
            _ = try context.db.run("INSERT INTO board_tasks (\(columns.joined(separator: ",")),all_day) VALUES (\(Array(repeating: "?", count: args.count).joined(separator: ","))) ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id,title=excluded.title,notes=excluded.notes,status=excluded.status,kind=excluded.kind,color=excluded.color,start_at=excluded.start_at,due_at=excluded.due_at,sort_order=excluded.sort_order,updated_at=excluded.updated_at,all_day=excluded.all_day", params: args)
            context.emit?("board:changed", ["courseId": value["courseId"] ?? NativeValue.null]); return try get(id)
        case "board:deleteTask":
            let id = try NativeValue.string(request["id"], "일정"); _ = try get(id); let now = NativeValue.now()
            _ = try context.db.run("UPDATE board_tasks SET deleted_at=?,updated_at=? WHERE id=?", params: [now,now,id]); context.emit?("board:changed", [:]); return NativeValue.ok
        case "board:reorderTasks":
            let course = try NativeValue.string(request["courseId"], "과목"); _ = try context.courseFolder(course)
            guard let updates = request["updates"] as? [[String: Any]] else { throw DesktopRuntimeError("일정 순서를 확인해 주세요.") }
            return try context.transaction {
                try updates.map { update -> Any in
                    let id = try NativeValue.string(update["id"], "일정"), old = try get(id)
                    guard old["courseId"] as? String == course else { throw DesktopRuntimeError("다른 과목의 일정입니다.") }
                    return try handle("board:updateTask", update) ?? NativeValue.null
                }
            }
        default: return nil
        }
    }
}
