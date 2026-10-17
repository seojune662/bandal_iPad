import Foundation

final class NativeSyncMaterials {
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    private let context: C
    private let checkBinding: ([String: Any]) throws -> [String: Any]
    init(context: NativeRepositoryContext, checkBinding: @escaping ([String: Any]) throws -> [String: Any]) { self.context = context; self.checkBinding = checkBinding }
    func snapshot() throws -> NativeSyncSnapshot {
        var result = NativeSyncSnapshot()
        let materials = try context.query("SELECT * FROM materials_index")
        for course in try context.query("SELECT * FROM courses ORDER BY created_at,id") {
            let id = course["id"] as! String
            let payload: [String: Any] = ["id": id, "name": course["name"]!, "color": course["color"]!, "desktop": ["archived": (course["archived"] as? NSNumber)?.boolValue ?? false, "sortOrder": course["sort_order"] ?? 0, "groupID": course["group_id"] ?? NSNull(), "workspaceKind": course["workspace_kind"] ?? "course", "createdAt": course["created_at"]!]]
            let deleted = !(course["deleted_at"] is NSNull)
            result.records.append(F.record(id: "course:\(id)", kind: "course", payload: payload, deleted: deleted)); result.sources["course:\(id)"] = ["folder": course["folder_path"]!]
            if deleted { continue }
            _ = try context.courseFolder(id)
            for material in materials where material["course_id"] as? String == id && material["deleted_at"] is NSNull {
                let mid = material["id"] as! String, relative = material["rel_path"] as! String
                let url = try context.materialURL(courseID: id, relativePath: relative, allowMissing: true)
                if !context.files.fileExists(atPath: url.path) { continue }
                let ext = url.pathExtension.lowercased(), kind = ext == "pdf" ? "pdf" : ["md", "markdown"].contains(ext) ? "note" : ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(ext) ? "image" : "file"
                let binding = kind == "pdf" ? try checkBinding(["courseId": id, "relPath": relative]) : nil
                let asset = try F.asset(materialID: mid, url: url), hash = asset["sha256"] as! String
                if let binding { guard binding["materialID"] as? String == mid, binding["documentRevision"] as? String == hash else { throw C.conflict("PDF identity changed during sync; original ink was preserved") } }
                result.assets.append(asset)
                let source: [String: Any] = ["courseID": id, "relPath": relative, "path": url.path, "hash": hash]
                var payload: [String: Any] = ["id": mid, "courseID": id, "title": url.deletingPathExtension().lastPathComponent, "fileName": url.lastPathComponent, "revision": hash, "kind": kind, "byteCount": asset["byteCount"]!, "createdAt": material["created_at"]!, "desktop": ["relPath": relative]]
                if kind == "pdf" {
                    let history = try NativePDFPageSync.export(context: context, material: mid)
                    // `pdfLineageAssets` is a Swift extra (byte counts for the originals); the desktop ignores it.
                    if !history.steps.isEmpty { payload["pdfLineage"] = history.steps; payload["pdfLineageAssets"] = history.assets.map { asset in asset.filter { ["sha256", "byteCount", "originalName", "contentType"].contains($0.key) } }; result.assets += history.assets }
                }
                result.records.append(F.record(id: "material:\(mid)", kind: "material", payload: payload)); result.sources["material:\(mid)"] = source
                if kind == "note" {
                    let data = try Data(contentsOf: url); guard F.hash(data) == hash, let markdown = String(data: data, encoding: .utf8) else { throw C.conflict("Note changed while exporting sync") }
                    result.records.append(F.record(id: "note:\(mid)", kind: "note", payload: ["materialID": mid, "markdown": markdown])); result.sources["note:\(mid)"] = source
                }
            }
        }
        return result
    }
    func plan(_ record: [String: Any], assets: [String: URL]) throws -> NativeSyncPlan? {
        guard let kind = record["kind"] as? String, let p = record["payload"] as? [String: Any] else { return nil }
        if kind == "drawing", let material = p["materialID"] as? String, let revision = p["documentRevision"] as? String, try NativePDFPageSync.isHistorical(context: context, material: material, revision: revision) {
            // An envelope for an approved ancestor revision is already-applied history.
            return NativeSyncPlan(source: try context.query("SELECT source_json FROM ipad_sync_projection WHERE id=?", [record["id"] ?? ""]).first.map { try F.object($0["source_json"]) } ?? [:])
        }
        guard ["course", "material", "note"].contains(kind) else { return nil }
        if kind == "material", p["kind"] as? String == "whiteboard" { return nil }
        let now = C.nowISO, deleted: Any = record["deleted"] as? Bool == true ? now : NSNull()
        func courseFolder(_ id: String) throws -> URL {
            if record["deleted"] as? Bool != true { return try context.courseFolder(id) }
            try context.assertPathAvailable(courseID: id)
            guard let path = try context.query("SELECT folder_path FROM courses WHERE id=?", [id]).first?["folder_path"] as? String, path.hasPrefix("/") else { throw C.validation("Sync course is unavailable") }
            let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard (try C.identity(folder))["directory"] as? Bool == true else { throw C.validation("Sync course folder is unavailable") }; return folder
        }
        if kind == "course" {
            let id = try F.identity(p["id"])
            guard record["id"] as? String == "course:\(id)", let name = p["name"] as? String, !name.isEmpty, UUID(uuidString: id) != nil else { throw C.validation("Invalid course payload") }
            let old = try context.query("SELECT * FROM courses WHERE id=?", [id]).first, desktop = p["desktop"] as? [String: Any] ?? [:]
            let folder = old?["folder_path"] as? String ?? context.root.appendingPathComponent("Courses/Synced/\(id)").path
            let row: [String: Any] = ["id": id, "name": name, "slug": old?["slug"] ?? "synced-\(id)", "color": p["color"] ?? "green", "folder_path": folder, "source": old?["source"] ?? "managed", "workspace_kind": desktop["workspaceKind"] ?? old?["workspace_kind"] ?? "course", "group_id": desktop["groupID"] ?? old?["group_id"] ?? NSNull(), "archived": desktop["archived"] as? Bool == true ? 1 : 0, "sort_order": desktop["sortOrder"] ?? old?["sort_order"] ?? 0, "created_at": old?["created_at"] ?? desktop["createdAt"] ?? now, "updated_at": now, "deleted_at": deleted]
            return NativeSyncPlan(source: ["folder": folder], courseID: id, apply: { [context] in
                if old == nil { try context.files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
                try F.upsert(context, table: "courses", values: row)
            })
        }
        if kind == "material" {
            let id = try F.identity(p["id"]), course = try F.identity(p["courseID"]), folder = try courseFolder(course)
            let old = try context.query("SELECT * FROM materials_index WHERE id=?", [id]).first
            guard record["id"] as? String == "material:\(id)", old == nil || old?["course_id"] as? String == course else { throw C.validation("Material identity mismatch") }
            guard try context.query("SELECT id FROM whiteboards WHERE id=?", [id]).isEmpty else { throw C.conflict("A whiteboard identity cannot become a file") }
            let desktop = p["desktop"] as? [String: Any] ?? [:]
            guard var relative = old?["rel_path"] as? String ?? desktop["relPath"] as? String ?? p["fileName"] as? String else { throw C.validation("Missing material filename") }
            var target = try context.resolve(in: folder, relativePath: relative)
            if old == nil {
                let original = target, parent = (relative as NSString).deletingLastPathComponent
                var suffix = 2
                while context.files.fileExists(atPath: target.path) {
                    guard suffix <= 10_000 else { throw C.conflict("Too many material name collisions") }
                    let ext = original.pathExtension, name = original.deletingPathExtension().lastPathComponent + " (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
                    relative = parent.isEmpty ? name : parent + "/" + name; target = try context.resolve(in: folder, relativePath: relative); suffix += 1
                }
            }
            let pdf = (old?["rel_path"] as? String)?.lowercased().hasSuffix(".pdf") == true
            if pdf && p["kind"] as? String != "pdf" { throw C.conflict("A preserved PDF material cannot change its kind") }
            let revision = p["revision"] as? String ?? "", isDeleted = record["deleted"] as? Bool == true
            var transition: NativeSyncPlan?
            let currentRevision = pdf && !isDeleted && context.files.fileExists(atPath: target.path) ? try checkBinding(["courseId": course, "relPath": relative])["documentRevision"] as? String : nil
            if let lineage = p["pdfLineage"], !isDeleted {
                guard p["kind"] as? String == "pdf" else { throw C.validation("Only PDF materials can carry page-edit history") }
                transition = try NativePDFPageSync.plan(context: context, material: id, course: course, path: relative, from: currentRevision, to: revision, lineage: lineage, assets: assets)
            } else if let currentRevision, currentRevision != revision { throw C.conflict("PDF replacement conflicts with its preserved drawing revision; import a separate material") }
            var files: [NativeSyncFileChange] = transition?.files ?? []
            if isDeleted { files.append(.init(target: target, data: nil)) }
            else if !files.contains(where: { $0.target == target }), try !context.files.fileExists(atPath: target.path) || F.hash(target) != revision {
                guard revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil, let source = assets[revision] else { throw C.validation("Verified sync asset is unavailable") }
                let bytes = try Data(contentsOf: source)
                guard F.hash(bytes) == revision, (p["byteCount"] as? NSNumber).map({ $0.intValue == bytes.count }) ?? true else { throw C.conflict("Sync asset checksum or length mismatch") }
                files.append(.init(target: target, data: bytes, expectedMissing: old == nil))
            }
            let row: [String: Any] = ["id": id, "course_id": course, "rel_path": relative, "kind": p["kind"] as? String == "file" ? "other" : p["kind"] ?? "other", "size": p["byteCount"] ?? old?["size"] ?? 0, "mtime": Date().timeIntervalSince1970 * 1000, "created_at": old?["created_at"] ?? p["createdAt"] ?? now, "updated_at": now, "deleted_at": deleted]
            return NativeSyncPlan(files: files, source: ["courseID": course, "relPath": relative, "path": target.path, "hash": revision], courseID: course, affectedCourseIDs: transition?.affectedCourseIDs ?? [], apply: { [context] in
                try F.upsert(context, table: "materials_index", values: row); try transition?.apply()
            })
        }
        let mid = try F.identity(p["materialID"])
        guard record["id"] as? String == "note:\(mid)", let markdown = p["markdown"] as? String, let material = try context.query("SELECT * FROM materials_index WHERE id=?", [mid]).first, (material["deleted_at"] is NSNull || record["deleted"] as? Bool == true), material["kind"] as? String == "note", let course = material["course_id"] as? String, let relative = material["rel_path"] as? String, ["md", "markdown"].contains((relative as NSString).pathExtension.lowercased()) else { throw C.validation("Note cannot write outside its Markdown material") }
        let target = try context.resolve(in: courseFolder(course), relativePath: relative)
        return NativeSyncPlan(files: [.init(target: target, data: record["deleted"] as? Bool == true ? nil : Data(markdown.utf8))], source: ["courseID": course, "relPath": relative, "path": target.path], courseID: course)
    }
}
