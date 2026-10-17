import Foundation

/// PDF/whiteboard projection and import share the same binding checks as local
/// editing. A page envelope never reassigns existing objects to another page.
final class NativeSyncDrawings {
    private typealias F = NativeSyncFormat
    private typealias V = NativePDFRepositoryValidation
    private typealias G = NativeSyncInkGeometry
    private let context: NativeRepositoryContext
    private let pdf: NativePDFRepository
    init(context: NativeRepositoryContext, pdf: NativePDFRepository) { self.context = context; self.pdf = pdf }

    func snapshot() throws -> NativeSyncSnapshot { try snapshot(onlyMaterialID: nil) }

    func snapshot(onlyMaterialID: String?) throws -> NativeSyncSnapshot {
        var output = NativeSyncSnapshot(), mapped: [String: [String: Any]] = [:]
        if try context.tableExists("ipad_sync_projection") {
            for row in try context.query("SELECT * FROM ipad_sync_projection") {
                guard let id = row["id"] as? String else { continue }
                mapped[id] = ["payload": try F.object(row["payload_json"])]
            }
        }
        let materials = try context.query("SELECT * FROM materials_index"), boards = try context.query("SELECT * FROM whiteboards")
        let liveCourses = Set(try context.query("SELECT id FROM courses WHERE deleted_at IS NULL").compactMap { $0["id"] as? String })
        func append(_ id: String, kind: String, payload: [String: Any], source: [String: Any], deleted: Bool = false) {
            var merged = mapped[id]?["payload"] as? [String: Any] ?? [:]; merged.merge(payload) { _, new in new }
            output.records.append(F.record(id: id, kind: kind, payload: merged, deleted: deleted)); output.sources[id] = source
        }
        func portableShape(_ row: [String: Any], geometry: [String: Any], course: String) throws -> [String: Any] {
            var result = try G.shape(["id": row["id"]!, "kind": row["kind"]!, "data": F.object(row["data_json"]), "style": F.object(row["style_json"]), "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!], geometry: geometry)
            var data = result["data"] as! [String: Any]
            for key in ["image", "clip"] {
                guard var source = data[key] as? [String: Any] else { continue }
                guard let image = materials.first(where: { $0["course_id"] as? String == course && $0["rel_path"] as? String == source["relPath"] as? String && $0["deleted_at"] is NSNull }) else { throw V.error("Sync ink \(key) source is missing") }
                source["assetId"] = image["id"]; data[key] = source
            }
            result["data"] = data; return result
        }
        func pageNumbers(_ rows: [[String: Any]], prefix: String) throws -> [Int] {
            var pages = Set(try rows.map { try V.integer($0["page"], "page") })
            for key in mapped.keys where key.hasPrefix(prefix) {
                guard let page = Int(key.dropFirst(prefix.count)), page > 0 else { throw V.error("Invalid historical ink page identity") }; pages.insert(page)
            }
            return pages.sorted()
        }
        func tombstones(_ previous: [String: Any]?, collection: String, deletedKey: String, rows: [[String: Any]], active: [[String: Any]], page: Int) throws -> [String] {
            var removed = Set(try ids(previous?[deletedKey]))
            let current = Set(active.compactMap { $0["id"] as? String })
            for row in rows where (row["page"] as? NSNumber)?.intValue == page && !(row["deleted_at"] is NSNull) { if let id = row["id"] as? String { removed.insert(id) } }
            for row in try objects(previous?[collection]) { if let id = row["id"] as? String, !current.contains(id) { removed.insert(id) } }
            // An explicit live canonical row supersedes an old projection tombstone.
            return removed.subtracting(current).sorted()
        }
        for material in materials {
            guard onlyMaterialID == nil || material["id"] as? String == onlyMaterialID else { continue }
            guard material["deleted_at"] is NSNull, let course = material["course_id"] as? String, liveCourses.contains(course),
                  let path = material["rel_path"] as? String, path.lowercased().hasSuffix(".pdf"), let materialID = material["id"] as? String else { continue }
            let url = try context.materialURL(courseID: course, relativePath: path, allowMissing: true)
            guard context.files.fileExists(atPath: url.path) else { continue }
            let binding = try pdf.checkBinding(["courseId": course, "relPath": path])
            guard binding["materialID"] as? String == materialID, let revision = binding["documentRevision"] as? String else { throw V.error("PDF identity changed while preparing sync; retry") }
            let drawings = try context.query("SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY page,created_at,id", [course, path])
            let annotations = try context.query("SELECT * FROM annotations WHERE course_id=? AND rel_path=? ORDER BY page,created_at,id", [course, path])
            let prefix = "drawing:\(materialID):\(revision):", pages = try pageNumbers(drawings + annotations, prefix: prefix)
            if pages.isEmpty { continue }
            let geometries = try G.pages(url)
            guard try pdf.revision(at: url) == revision else { throw V.error("PDF changed while preparing ink sync") }
            for page in pages {
                guard geometries.indices.contains(page - 1) else {
                    // Removed pages keep canonical deleted rows for recovery.
                    // They belong to an earlier revision, not this page set.
                    let active = (drawings + annotations).contains { ($0["page"] as? NSNumber)?.intValue == page && $0["deleted_at"] is NSNull }
                    guard !active, mapped[prefix + String(page)] == nil else { throw V.error("Sync ink page \(page) is missing from PDF") }
                    continue
                }
                let geometry = geometries[page - 1], prior = try mapped[prefix + String(page)].map(F.decodePage)
                let drawings = try drawings.filter { ($0["page"] as? NSNumber)?.intValue == page && $0["deleted_at"] is NSNull }.map { try portableShape($0, geometry: geometry, course: course) }
                let highlights = try annotations.filter { ($0["page"] as? NSNumber)?.intValue == page && $0["deleted_at"] is NSNull }.map { row -> [String: Any] in
                    var value = try F.object(row["anchor_json"])
                    guard let rects = try V.parse(row["rects_json"]) as? [[String: Any]] else { throw V.error("Invalid stored highlight rectangles") }
                    value.merge(["id": row["id"]!, "rects": try rects.map { try G.box($0, rotation: geometry["rotation"] as! Int) }, "color": row["color"]!, "comment": row["comment"] ?? NSNull(), "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!]) { _, new in new }; return value
                }
                let rawRows = try context.query("SELECT id,page,deleted_at FROM pdf_drawings WHERE course_id=? AND rel_path=? AND page=?", [course, path, page])
                let portable: [String: Any] = ["schemaVersion": 1, "materialID": materialID, "documentRevision": revision, "page": page, "coordinateSpace": F.coordinateSpace, "geometry": geometry, "objects": drawings, "highlights": highlights,
                    "deletedObjectIDs": try tombstones(prior, collection: "objects", deletedKey: "deletedObjectIDs", rows: rawRows, active: drawings, page: page),
                    "deletedHighlightIDs": try tombstones(prior, collection: "highlights", deletedKey: "deletedHighlightIDs", rows: annotations, active: highlights, page: page)]
                append(prefix + String(page), kind: "drawing", payload: try F.encodePage(portable), source: ["courseID": course, "relPath": path, "path": url.path, "hash": revision, "geometry": geometry])
            }
        }
        for board in boards {
            guard onlyMaterialID == nil || board["id"] as? String == onlyMaterialID else { continue }
            let materialID = try F.identity(board["id"]), course = try F.identity(board["course_id"])
            let revision = (mapped["material:" + materialID]?["payload"] as? [String: Any])?["revision"] as? String ?? "whiteboard-" + materialID
            let source: [String: Any] = ["courseID": course, "whiteboard": true]
            append("material:" + materialID, kind: "material", payload: ["id": materialID, "courseID": course, "title": board["title"]!, "fileName": "canvas.json", "kind": "whiteboard", "revision": revision, "createdAt": board["created_at"]!,
                "desktop": ["background": board["background"] ?? "blank", "surface": board["surface"] ?? "light", "pageCount": board["page_count"] ?? 1, "sortOrder": board["sort_order"] ?? 0]], source: source, deleted: !(board["deleted_at"] is NSNull))
            guard board["deleted_at"] is NSNull, liveCourses.contains(course) else { continue }
            let rows = try context.query("SELECT * FROM whiteboard_local_shapes WHERE board_id=? ORDER BY page,created_at,id", [materialID]), prefix = "drawing:\(materialID):\(revision):"
            for page in try pageNumbers(rows, prefix: prefix) {
                let previous = try mapped[prefix + String(page)].map(F.decodePage)
                let geometry = try G.validate(previous?["geometry"] ?? ["cropX": 0, "cropY": 0, "width": 595.28, "height": 841.89, "rotation": 0])
                let objects = try rows.filter { ($0["page"] as? NSNumber)?.intValue == page && $0["deleted_at"] is NSNull }.map { try portableShape($0, geometry: geometry, course: course) }
                let portable: [String: Any] = ["schemaVersion": 1, "materialID": materialID, "documentRevision": revision, "page": page, "coordinateSpace": F.coordinateSpace, "geometry": geometry, "objects": objects, "highlights": [], "deletedObjectIDs": try tombstones(previous, collection: "objects", deletedKey: "deletedObjectIDs", rows: rows, active: objects, page: page), "deletedHighlightIDs": []]
                var source = source; source["geometry"] = geometry
                append(prefix + String(page), kind: "drawing", payload: try F.encodePage(portable), source: source)
            }
        }
        return output
    }

    func plan(_ record: [String: Any], assets: [String: URL]) throws -> NativeSyncPlan? {
        guard let payload = record["payload"] as? [String: Any] else { throw V.error("Invalid sync payload") }
        if record["kind"] as? String == "material", payload["kind"] as? String == "whiteboard" { return try whiteboard(record, payload: payload) }
        guard record["kind"] as? String == "drawing" else { return nil }
        try F.validate(record)
        let page = try F.decodePage(record), materialID = try F.identity(page["materialID"]), number = try V.integer(page["page"], "page"), revision = try V.string(page["documentRevision"], "documentRevision"), deleted = record["deleted"] as? Bool == true
        guard try V.integer(page["schemaVersion"], "schemaVersion") == 1, page["coordinateSpace"] as? String == F.coordinateSpace,
              payload["materialID"] as? String == materialID, try V.integer(payload["page"], "page") == number,
              payload["documentRevision"] as? String == revision, record["id"] as? String == "drawing:\(materialID):\(revision):\(number)" else { throw V.error("Unsupported ink page format or identity") }
        let geometry = try G.validate(page["geometry"]), board = try context.query("SELECT * FROM whiteboards WHERE id=?", [materialID]).first
        let material: [String: Any]
        if let board {
            guard deleted || board["deleted_at"] is NSNull else { throw V.error("Sync whiteboard is unavailable") }
            material = ["id": materialID, "course_id": board["course_id"]!, "rel_path": ""]
            if try context.tableExists("ipad_sync_projection"), let prior = try context.query("SELECT payload_json FROM ipad_sync_projection WHERE id=?", ["material:" + materialID]).first,
               let oldRevision = try F.object(prior["payload_json"])["revision"] as? String, oldRevision != revision { throw V.error("Ink belongs to another whiteboard revision") }
        } else {
            guard let row = try context.query("SELECT * FROM materials_index WHERE id=?", [materialID]).first, deleted || row["deleted_at"] is NSNull else { throw V.error("Sync material is unavailable") }
            material = row
        }
        let course = try F.identity(material["course_id"]), path = material["rel_path"] as! String, now = NativeRepositoryContext.nowISO
        try requireCourse(course, deleting: deleted)
        var source: [String: Any] = ["courseID": course, "relPath": path, "geometry": geometry]
        if board != nil { source["whiteboard"] = true }
        else {
            guard path.lowercased().hasSuffix(".pdf") else { throw V.error("Ink can only target a PDF or whiteboard") }
            // A page rewrite preserves object IDs while moving them to the new
            // document revision. A tombstone for an approved ancestor is only
            // a historical projection update, never a deletion of those rows.
            if deleted, let current = try context.query("SELECT b.bound_sha FROM pdf_document_bindings b JOIN pdf_document_aliases a ON a.material_id=b.material_id WHERE b.material_id=? AND a.course_id=? AND a.rel_path=?", [materialID, course, path]).first?["bound_sha"] as? String,
               current != revision, try isAncestor(revision, of: current, materialID: materialID) {
                _ = try V.digest(revision)
                if material["deleted_at"] is NSNull {
                    let binding = try pdf.checkBinding(["courseId": course, "relPath": path, "documentRevision": current])
                    guard binding["materialID"] as? String == materialID else { throw V.error("Historical ink belongs to another material") }
                }
                let original = context.root.appendingPathComponent("PDFOriginals/" + revision + ".pdf")
                let pages = try G.pages(original)
                guard pages.indices.contains(number - 1), G.matches(pages[number - 1], geometry), try pdf.revision(at: original) == revision else { throw V.error("Historical ink geometry does not match PDF") }
                source["path"] = original.path; source["hash"] = revision
                return NativeSyncPlan(source: source, courseID: course, apply: {})
            }
            let url: URL
            if deleted, !(material["deleted_at"] is NSNull) {
                _ = try V.digest(revision)
                guard let binding = try context.query("SELECT b.bound_sha FROM pdf_document_bindings b JOIN pdf_document_aliases a ON a.material_id=b.material_id WHERE b.material_id=? AND a.course_id=? AND a.rel_path=?", [materialID, course, path]).first,
                      binding["bound_sha"] as? String == revision else { throw V.error("Deleted ink has no matching preserved PDF identity") }
                url = context.root.appendingPathComponent("PDFOriginals/" + revision + ".pdf")
            } else {
                url = try context.materialURL(courseID: course, relativePath: path)
                let binding = try pdf.checkBinding(["courseId": course, "relPath": path, "documentRevision": revision])
                guard binding["materialID"] as? String == materialID else { throw V.error("Ink belongs to another material") }
            }
            let geometries = try G.pages(url)
            guard geometries.indices.contains(number - 1), G.matches(geometries[number - 1], geometry), try pdf.revision(at: url) == revision else { throw V.error("Ink geometry does not match PDF") }
            source["path"] = url.path; source["hash"] = revision
        }
        let table = board == nil ? "pdf_drawings" : "whiteboard_local_shapes"
        let scope = board == nil ? "course_id=? AND rel_path=?" : "board_id=?", scopeValues: [Any] = board == nil ? [course, path] : [materialID]
        var changes: [() throws -> Void] = [], objectIDs = Set<String>(), highlightIDs = Set<String>()
        let removed = Set(try ids(page["deletedObjectIDs"])), removedHighlights = Set(try ids(page["deletedHighlightIDs"]))
        if deleted {
            changes.append { try self.context.run("UPDATE \(table) SET deleted_at=?,updated_at=? WHERE \(scope) AND page=?", [now, now] + scopeValues + [number]) }
            if board == nil { changes.append { try self.context.run("UPDATE annotations SET deleted_at=?,updated_at=? WHERE course_id=? AND rel_path=? AND page=?", [now, now, course, path, number]) } }
        }
        for raw in try objects(page["objects"]) {
            let id = try F.identity(raw["id"])
            guard objectIDs.insert(id).inserted else { throw V.error("Duplicate ink object identity") }
            var value = try G.shape(raw, geometry: geometry, inverse: true), data = try V.object(value["data"], "data")
            for key in ["image", "clip"] {
                guard var image = data[key] as? [String: Any] else { continue }
                if let assetID = image["assetId"] {
                    let asset = try liveMaterial(F.identity(assetID), allowDeleted: deleted)
                    guard asset["course_id"] as? String == course else { throw V.error("Ink source crosses course boundary") }
                    image["relPath"] = asset["rel_path"]; image.removeValue(forKey: "assetId"); image.removeValue(forKey: "storage")
                }
                let relative = try V.path(image["relPath"])
                if !deleted { _ = try context.materialURL(courseID: course, relativePath: relative) }
                data[key] = image
            }
            value["data"] = data; try G.validateShape(value)
            if let old = try context.query("SELECT * FROM \(table) WHERE id=?", [id]).first {
                guard (board != nil ? old["board_id"] as? String == materialID : old["course_id"] as? String == course && old["rel_path"] as? String == path),
                      try acceptsPage(old, page: number, table: table, materialID: materialID, revision: revision, course: course, path: path) else { throw V.error("Ink identity belongs to another page") }
            }
            var row: [String: Any] = ["id": id, "page": number, "kind": value["kind"]!, "data_json": try F.canonical(data), "style_json": try F.canonical(value["style"]!), "created_at": try timestamp(value["createdAt"], fallback: now), "updated_at": try timestamp(value["updatedAt"], fallback: now), "deleted_at": deleted || removed.contains(id) ? now as Any : NSNull()]
            if board != nil { row["board_id"] = materialID } else { row["course_id"] = course; row["rel_path"] = path }
            changes.append { try F.upsert(self.context, table: table, values: row) }
        }
        for id in removed { changes.append { try self.context.run("UPDATE \(table) SET deleted_at=?,updated_at=? WHERE id=? AND \(scope) AND page=?", [now, now, id] + scopeValues + [number]) } }
        let highlights = try objects(page["highlights"])
        guard board == nil || highlights.isEmpty && removedHighlights.isEmpty else { throw V.error("Whiteboards cannot contain PDF text highlights") }
        for highlight in highlights {
            let id = try F.identity(highlight["id"])
            guard highlightIDs.insert(id).inserted else { throw V.error("Duplicate highlight identity") }
            if let old = try context.query("SELECT * FROM annotations WHERE id=?", [id]).first {
                guard old["course_id"] as? String == course, old["rel_path"] as? String == path,
                      try acceptsPage(old, page: number, table: "annotations", materialID: materialID, revision: revision, course: course, path: path) else { throw V.error("Highlight identity belongs to another page") }
            }
            guard let color = highlight["color"] as? String, ["yellow", "green", "blue", "pink"].contains(color) else { throw V.error("Invalid highlight color") }
            let rects = try objects(highlight["rects"]).map { try G.box($0, rotation: geometry["rotation"] as! Int, inverse: true) }
            guard !rects.isEmpty else { throw V.error("A highlight needs rectangles") }
            var anchor: [String: Any] = [:]
            for key in ["quote", "prefix", "suffix"] { guard highlight[key] == nil || highlight[key] is String else { throw V.error("Invalid highlight anchor") }; anchor[key] = highlight[key] ?? "" }
            guard highlight["comment"] == nil || highlight["comment"] is NSNull || highlight["comment"] is String else { throw V.error("Invalid highlight comment") }
            let row: [String: Any] = ["id": id, "course_id": course, "rel_path": path, "page": number, "color": color, "rects_json": try F.canonical(rects), "anchor_json": try F.canonical(anchor), "comment": highlight["comment"] ?? NSNull(), "created_at": try timestamp(highlight["createdAt"], fallback: now), "updated_at": try timestamp(highlight["updatedAt"], fallback: now), "deleted_at": deleted || removedHighlights.contains(id) ? now as Any : NSNull()]
            changes.append { try F.upsert(self.context, table: "annotations", values: row) }
        }
        for id in removedHighlights { changes.append { try self.context.run("UPDATE annotations SET deleted_at=?,updated_at=? WHERE id=? AND course_id=? AND rel_path=? AND page=?", [now, now, id, course, path, number]) } }
        return NativeSyncPlan(source: source, courseID: course, apply: { try self.context.transaction { for change in changes { try change() } } })
    }

    private func acceptsPage(_ old: [String: Any], page: Int, table: String, materialID: String, revision: String, course: String, path: String) throws -> Bool {
        if (old["page"] as? NSNumber)?.intValue == page { return true }
        // Only an already deleted PDF row may be revived at the page recorded
        // for this exact revision. Current live rows never change ownership.
        guard ["pdf_drawings", "annotations"].contains(table), !(old["deleted_at"] is NSNull),
              let id = old["id"] as? String, try context.tableExists("native_pdf_page_history") else { return false }
        let histories = try context.query("SELECT before_sha,after_sha,before_json,after_json FROM native_pdf_page_history WHERE material_id=? AND (before_sha=? OR after_sha=?)", [materialID, revision, revision])
        for history in histories {
            for variant in ["before", "after"] where history[variant + "_sha"] as? String == revision {
                let snapshot = try F.object(history[variant + "_json"])
                if (snapshot[table] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id && $0["course_id"] as? String == course && $0["rel_path"] as? String == path && ($0["page"] as? NSNumber)?.intValue == page }) { return true }
            }
        }
        return false
    }

    private func isAncestor(_ revision: String, of current: String, materialID: String) throws -> Bool {
        guard try context.tableExists("native_pdf_revision_lineage") else { return false }
        let rows = try context.query("SELECT from_sha,to_sha FROM native_pdf_revision_lineage WHERE material_id=?", [materialID])
        var pending = [revision], seen = Set<String>()
        while let value = pending.popLast() {
            guard seen.insert(value).inserted else { continue }
            for row in rows where row["from_sha"] as? String == value {
                guard let next = row["to_sha"] as? String else { continue }
                if next == current { return true }; pending.append(next)
            }
        }
        return false
    }

    private func whiteboard(_ record: [String: Any], payload: [String: Any]) throws -> NativeSyncPlan {
        try F.validate(record)
        let id = try F.identity(payload["id"]), course = try F.identity(payload["courseID"]), deleted = record["deleted"] as? Bool == true, now = NativeRepositoryContext.nowISO
        guard record["id"] as? String == "material:" + id, try context.query("SELECT id FROM materials_index WHERE id=?", [id]).isEmpty else { throw V.error("Whiteboard identity conflicts with a file") }
        try requireCourse(course, deleting: deleted)
        if let old = try context.query("SELECT course_id FROM whiteboards WHERE id=?", [id]).first, old["course_id"] as? String != course { throw V.error("Whiteboard identity belongs to another course") }
        let desktop = payload["desktop"] as? [String: Any] ?? [:]
        let row: [String: Any] = ["id": id, "course_id": course, "title": try V.string(payload["title"], "whiteboard title"), "sort_order": try V.integer(desktop["sortOrder"] ?? 0, "sort order", min: 0), "created_at": try timestamp(payload["createdAt"], fallback: now), "updated_at": now, "deleted_at": deleted ? now as Any : NSNull(), "background": try V.string(desktop["background"] ?? "blank", "background"), "surface": try V.string(desktop["surface"] ?? "light", "surface"), "page_count": try V.integer(desktop["pageCount"] ?? 1, "page count"), "added_at": NSNull()]
        return NativeSyncPlan(source: ["courseID": course, "whiteboard": true], courseID: course, apply: { try F.upsert(self.context, table: "whiteboards", values: row) })
    }
    private func requireCourse(_ id: String, deleting: Bool) throws {
        guard let course = try context.query("SELECT deleted_at FROM courses WHERE id=?", [id]).first, deleting || course["deleted_at"] is NSNull else { throw V.error("Sync course is unavailable") }
    }
    private func liveMaterial(_ id: String, allowDeleted: Bool = false) throws -> [String: Any] {
        guard let material = try context.query("SELECT * FROM materials_index WHERE id=?", [id]).first, allowDeleted || material["deleted_at"] is NSNull else { throw V.error("Sync material is unavailable") }
        return material
    }
    private func objects(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw else { return [] }
        guard let values = raw as? [[String: Any]] else { throw V.error("Invalid sync object array") }; return values
    }
    private func ids(_ raw: Any?) throws -> [String] {
        guard let raw else { return [] }
        guard let values = raw as? [Any] else { throw V.error("Invalid sync identity array") }; return try values.map(F.identity)
    }
    private func timestamp(_ raw: Any?, fallback: String) throws -> String { raw == nil ? fallback : try V.string(raw, "timestamp") }
}
