import Foundation

final class NativePreferencesRepository {
    private let context: NativeRepositoryContext
    init(context: NativeRepositoryContext) { self.context = context }
    private var url: URL { context.root.appendingPathComponent("settings.json") }
    private var defaults: [String: Any] { NativeSettingsSchema.defaults(dataRoot:context.root.appendingPathComponent("Courses").path) }
    func settings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath:url.path) else { return defaults }
        let data = try Data(contentsOf:url)
        guard let value = try DesktopJSON.decode(data) as? [String:Any] else { throw DesktopRuntimeError("설정 파일을 읽을 수 없습니다. 원본은 보존되어 있습니다.") }
        return NativeSettingsSchema.normalized(value,dataRoot:context.root.appendingPathComponent("Courses").path)
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        switch channel {
        case "settings:get": return try settings()
        case "settings:set", "settings:reset":
            let previous = try settings(); var next: [String:Any]
            if channel == "settings:reset" {
                next = defaults
                for key in ["dataRoot","locale","onboarding","tutorial","university","milestones","lastActiveCourseId"] { next[key] = previous[key] }
            } else {
                next = NativeSettingsSchema.merging(previous,patch:request)
                if request["theme"] != nil || request["palette"] != nil { next["pluginTheme"] = request["pluginTheme"] ?? NativeValue.null }
            }
            if let provider = next["agentProvider"] as? String, !["claude-code","codex","gemini"].contains(provider) { throw DesktopRuntimeError("AI 제공자를 확인해 주세요.") }
            if let browser = next["browser"] as? [String:Any], let home = browser["homePage"] as? String, !home.isEmpty {
                guard let url = URL(string:home), ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw DesktopRuntimeError("홈페이지에 올바른 HTTP 또는 HTTPS 주소를 입력하세요.") }
            }
            // Moving data is a coordinated operation, never a preference edit.
            if let path = request["dataRoot"] as? String, path != previous["dataRoot"] as? String { throw DesktopRuntimeError("자료 저장 위치는 과목 폴더 연결에서 변경해 주세요.") }
            next = NativeSettingsSchema.normalized(next,dataRoot:context.root.appendingPathComponent("Courses").path)
            try Data(NativeValue.json(next).utf8).write(to:url,options:.atomic)
            context.emit?("settings:changed", ["settings":next]); return next
        case "layout:get":
            let id = try NativeValue.string(request["courseId"],"과목")
            guard let row = try context.db.query("SELECT layout_json FROM tabs_layout WHERE course_id=?",params:[id]).first else { return NativeValue.null }
            return try NativeValue.decode(row["layout_json"])
        case "layout:save", "layout:saveMany":
            let values = channel == "layout:save" ? [request] : request["layouts"] as? [[String:Any]] ?? []
            return try context.transaction {
                for value in values {
                    let id = try NativeValue.string(value["courseId"],"과목"), now = NativeValue.now(); _ = try context.courseFolder(id)
                    _ = try context.db.run("INSERT INTO tabs_layout(course_id,layout_json,created_at,updated_at) VALUES(?,?,?,?) ON CONFLICT(course_id) DO UPDATE SET layout_json=excluded.layout_json,updated_at=excluded.updated_at",params:[id,try NativeValue.json(value["layout"] ?? NativeValue.null),now,now])
                }
                return NativeValue.ok
            }
        case "media:getProgress", "media:setProgress":
            let course = try NativeValue.string(request["courseId"],"과목"), path = try NativeValue.string(request["relPath"],"경로")
            _ = try context.materialURL(courseID:course,relativePath:path)
            if channel == "media:setProgress" {
                for key in ["positionSec","playbackRate","durationSec"] {
                    if key == "durationSec", request[key] is NSNull { continue }
                    guard let value = request[key] as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { throw DesktopRuntimeError("재생 위치를 확인해 주세요.") }
                }
                _ = try context.db.run("INSERT INTO media_progress(course_id,rel_path,position_sec,duration_sec,playback_rate,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(course_id,rel_path) DO UPDATE SET position_sec=excluded.position_sec,duration_sec=excluded.duration_sec,playback_rate=excluded.playback_rate,updated_at=excluded.updated_at",params:[course,path,request["positionSec"]!,request["durationSec"] ?? NativeValue.null,request["playbackRate"]!,NativeValue.now()])
            }
            guard let row = try context.db.query("SELECT * FROM media_progress WHERE course_id=? AND rel_path=?",params:[course,path]).first else { return NativeValue.null }
            return NativeValue.mapped(row,["course_id":"courseId","rel_path":"relPath","position_sec":"positionSec","duration_sec":"durationSec","playback_rate":"playbackRate","updated_at":"updatedAt"])
        case "favorites:list":
            return try favoriteRows(request["courseId"] ?? NativeValue.null).compactMap { try? favorite($0) }
        case "favorites:add":
            let course = request["courseId"] ?? NativeValue.null; if let id = course as? String { _ = try context.courseFolder(id) }
            guard let descriptor = request["descriptor"] as? [String:Any], let kind = descriptor["kind"] as? String, !kind.isEmpty else { throw DesktopRuntimeError("즐겨찾기 자료를 확인해 주세요.") }
            let id = UUID().uuidString, now = NativeValue.now(), title = try NativeValue.string(request["label"],"이름")
            let order = try context.db.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS n FROM favorites WHERE course_id IS ? AND deleted_at IS NULL",params:[course]).first?["n"] ?? 0
            _ = try context.db.run("INSERT INTO favorites(id,course_id,label,descriptor_json,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",params:[id,course,title,try NativeValue.json(descriptor),order,now,now])
            return try favoriteByID(id)
        case "favorites:rename", "favorites:remove":
            let id = try NativeValue.string(request["id"],"즐겨찾기"); _ = try favoriteByID(id); let now = NativeValue.now()
            if channel == "favorites:rename" { _ = try context.db.run("UPDATE favorites SET label=?,updated_at=? WHERE id=?",params:[try NativeValue.string(request["label"],"이름"),now,id]); return try favoriteByID(id) }
            _ = try context.db.run("UPDATE favorites SET deleted_at=?,updated_at=? WHERE id=?",params:[now,now,id]); return NativeValue.ok
        case "favorites:reorder":
            let course = request["courseId"] ?? NativeValue.null
            guard let ids = request["ids"] as? [String] else { throw DesktopRuntimeError("즐겨찾기 순서를 확인해 주세요.") }
            let existing = try favoriteRows(course).compactMap { try? favorite($0)["id"] as? String }
            guard ids.count == Set(ids).count, Set(ids) == Set(existing) else { throw DesktopRuntimeError("즐겨찾기 목록이 변경되었습니다.") }
            try context.transaction { for (index,id) in ids.enumerated() { _ = try context.db.run("UPDATE favorites SET sort_order=?,updated_at=? WHERE id=?",params:[index,NativeValue.now(),id]) } }; return NativeValue.ok
        default: return nil
        }
    }
    private func favoriteRows(_ course: Any) throws -> [[String:Any]] { try context.db.query("SELECT * FROM favorites WHERE course_id IS ? AND deleted_at IS NULL ORDER BY sort_order,created_at",params:[course]) }
    private func favorite(_ row: [String:Any]) throws -> [String:Any] {
        var value = NativeValue.mapped(row,["id":"id","course_id":"courseId","label":"label","sort_order":"sortOrder","created_at":"createdAt","updated_at":"updatedAt"])
        value["descriptor"] = try NativeValue.object(row["descriptor_json"]); return value
    }
    private func favoriteByID(_ id: String) throws -> [String:Any] {
        guard let row = try context.db.query("SELECT * FROM favorites WHERE id=? AND deleted_at IS NULL",params:[id]).first else { throw DesktopRuntimeError("즐겨찾기를 찾을 수 없습니다.") }; return try favorite(row)
    }
}
