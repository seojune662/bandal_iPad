import Foundation

final class NativeWhiteboardRepository {
    private typealias V = NativePDFRepositoryValidation
    private let context: NativeRepositoryContext
    init(context: NativeRepositoryContext) { self.context = context }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard channel.hasPrefix("canvas:") else { return nil }
        let now = NativeRepositoryContext.nowISO
        switch channel {
        case "canvas:list":
            let course = try V.id(request["courseId"]); _ = try context.courseFolder(course)
            return try context.query("SELECT * FROM whiteboards WHERE course_id=? AND deleted_at IS NULL ORDER BY sort_order,created_at,id", [course]).map(board)
        case "canvas:create":
            let course = try V.id(request["courseId"]); _ = try context.courseFolder(course)
            let id = UUID().uuidString.lowercased(), order = (try context.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS next FROM whiteboards WHERE course_id=?", [course]).first?["next"] as? NSNumber)?.intValue ?? 0
            let title = try V.string(request["title"] ?? "노트 \(order + 1)", "title")
            let settings = try NativePreferencesRepository(context:context).settings()
            let background = (settings["tabs"] as? [String:Any])?["whiteboardBackground"] as? String ?? "grid"
            try context.run("INSERT INTO whiteboards(id,course_id,title,background,surface,page_count,sort_order,created_at,updated_at,added_at) VALUES(?,?,?,?,'light',1,?,?,?,?)", [id, course, title, background, order, now, now, Date().timeIntervalSince1970 * 1000])
            changed(course, id: id); return try board(get(id, request: request))
        case "canvas:get", "canvas:open", "canvas:hoverPreview":
            let id = try V.id(request["boardId"] ?? request["id"]), row = try get(id, request: request)
            if channel == "canvas:get" { return board(row) }
            let rows = try context.query("SELECT * FROM whiteboard_local_shapes WHERE board_id=? AND deleted_at IS NULL ORDER BY page,created_at,id", [id])
            var geometries: [String: [String: Any]] = [:]
            if try context.tableExists("ipad_sync_projection") {
                for record in try context.query("SELECT payload_json FROM ipad_sync_projection WHERE kind='drawing'") {
                    let payload = try NativeSyncFormat.object(record["payload_json"])
                    guard payload["materialID"] as? String == id else { continue }
                    let page = try NativeSyncFormat.decodePage(["payload": payload]), number = try V.integer(page["page"], "page")
                    geometries[String(number)] = try NativeSyncInkGeometry.validate(page["geometry"])
                }
            }
            return ["board": board(row), "shapes": try rows.map(shape), "pageGeometries": geometries]
        case "canvas:rename":
            let id = try V.id(request["id"]), row = try get(id, request: request), title = try V.string(request["title"], "title")
            try context.run("UPDATE whiteboards SET title=?,updated_at=? WHERE id=?", [title, now, id]); changed(row["course_id"] as! String, id: id); return try board(get(id, request: request))
        case "canvas:delete", "canvas:remove":
            let id = try V.id(request["id"]), row = try get(id, request: request)
            try context.transaction {
                try context.run("UPDATE whiteboards SET deleted_at=?,updated_at=? WHERE id=?", [now, now, id])
                try context.run("UPDATE whiteboard_local_shapes SET deleted_at=?,updated_at=? WHERE board_id=? AND deleted_at IS NULL", [now, now, id])
            }
            changed(row["course_id"] as! String, id: id); return ["ok": true]
        case "canvas:setBackground":
            let id = try V.id(request["boardId"]), row = try get(id, request: request)
            let background = request["background"] as? String ?? row["background"] as? String ?? "grid", surface = request["surface"] as? String ?? row["surface"] as? String ?? "light"
            guard ["grid", "dots", "lines", "blank"].contains(background), ["light", "dark"].contains(surface) else { throw V.error("Invalid whiteboard paper") }
            try context.run("UPDATE whiteboards SET background=?,surface=?,updated_at=? WHERE id=?", [background, surface, now, id]); changed(row["course_id"] as! String, id: id); return try board(get(id, request: request))
        case "canvas:setPageCount":
            let id = try V.id(request["boardId"]), row = try get(id, request: request), count = try V.integer(request["pageCount"], "pageCount")
            guard count <= 1000, try context.query("SELECT id FROM whiteboard_local_shapes WHERE board_id=? AND page>? AND deleted_at IS NULL LIMIT 1", [id, count]).isEmpty else { throw V.error("필기가 있는 페이지는 제거할 수 없습니다.") }
            try context.run("UPDATE whiteboards SET page_count=?,updated_at=? WHERE id=?", [count, now, id]); changed(row["course_id"] as! String, id: id); return try board(get(id, request: request))
        case "canvas:putShape":
            let boardID = try V.id(request["boardId"]), board = try get(boardID, request: request), id = try V.id(request["id"])
            let page = try V.integer(request["page"] ?? 1, "page"), value = try V.object(request["shape"], "shape")
            guard page <= ((board["page_count"] as? NSNumber)?.intValue ?? 1) else { throw V.error("Whiteboard page is unavailable") }
            try NativeSyncInkGeometry.validateShape(value)
            let old = try context.query("SELECT * FROM whiteboard_local_shapes WHERE id=?", [id]).first
            guard old == nil || old?["board_id"] as? String == boardID else { throw V.error("Shape belongs to another board") }
            let deleted = request["restore"] as? Bool == true ? NSNull() : old?["deleted_at"] ?? NSNull()
            try NativeSyncFormat.upsert(context, table: "whiteboard_local_shapes", values: ["id": id, "board_id": boardID, "page": page, "kind": value["kind"]!, "data_json": try NativeSyncFormat.canonical(value["data"]!), "style_json": try NativeSyncFormat.canonical(value["style"]!), "created_at": old?["created_at"] ?? now, "updated_at": now, "deleted_at": deleted])
            return try shape(context.query("SELECT * FROM whiteboard_local_shapes WHERE id=?", [id])[0])
        case "canvas:removeShapes":
            let boardID = try V.id(request["boardId"]); _ = try get(boardID, request: request)
            guard let raw = request["ids"] as? [Any] else { throw V.error("Invalid shape IDs") }; let ids = try Set(raw.map { try V.id($0) })
            for id in ids { if let old = try context.query("SELECT board_id FROM whiteboard_local_shapes WHERE id=?", [id]).first, old["board_id"] as? String != boardID { throw V.error("Shape belongs to another board") } }
            try context.transaction { for id in ids { try context.run("UPDATE whiteboard_local_shapes SET deleted_at=?,updated_at=? WHERE board_id=? AND id=?", [now, now, boardID, id]) } }; return ["ok": true]
        default: return nil
        }
    }
    private func get(_ id: String, request: [String: Any]) throws -> [String: Any] {
        guard let row = try context.query("SELECT b.* FROM whiteboards b JOIN courses c ON c.id=b.course_id WHERE b.id=? AND b.deleted_at IS NULL AND c.deleted_at IS NULL", [id]).first else { throw NativeRepositoryContext.notFound("whiteboard", id) }
        if let course = request["courseId"] as? String, course != row["course_id"] as? String { throw V.error("Whiteboard belongs to another course") }; return row
    }
    private func board(_ row: [String: Any]) -> [String: Any] {
        ["id": row["id"]!, "courseId": row["course_id"]!, "title": row["title"]!, "background": row["background"] ?? "grid", "surface": row["surface"] ?? "light", "pageCount": row["page_count"] ?? 1, "sortOrder": row["sort_order"]!, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!, "addedAt": row["added_at"] ?? NSNull()]
    }
    private func shape(_ row: [String: Any]) throws -> [String: Any] {
        ["id": row["id"]!, "page": row["page"]!, "kind": row["kind"]!, "data": try NativeSyncFormat.object(row["data_json"]), "style": try NativeSyncFormat.object(row["style_json"]), "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!]
    }
    private func changed(_ course: String, id: String) { context.emit?("canvas:changed", ["courseId": course, "boardId": id]); context.emit?("materials:changed", ["courseId": course]) }
}
