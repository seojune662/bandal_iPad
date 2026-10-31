import Foundation
import Darwin

/// Swift repositories for the existing bandal.db and course folders.
final class NativeLibraryRepository {
    private typealias C = NativeRepositoryContext
    let context: NativeRepositoryContext
    private var recovered = false
    static let channels = ["courses:list", "courses:create", "courses:addFromFolder", "courses:relink", "courses:rename", "courses:setColor", "courses:setWorkspaceKind", "courses:archive", "courses:organize", "courses:delete", "courses:restore", "courses:purge", "courseGroups:list", "courseGroups:create", "courseGroups:rename", "courseGroups:delete", "courseLinks:list", "courseLinks:create", "courseLinks:update", "courseLinks:delete", "materials:tree", "materials:snapshot", "materials:search", "materials:readFile", "materials:import", "materials:importShared", "materials:rename", "materials:move", "materials:delete", "materials:duplicate", "materials:createFolder", "materials:writeFile", "materials:adoptFile", "notes:read", "notes:write", "notes:create", "notes:rename", "nativeMaterial:path"]
    init(context: NativeRepositoryContext) { self.context = context }

    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard Self.channels.contains(channel) || channel == "nativeMaterial:folders" else { return nil }
        if !recovered { try recoverPathChanges(); recovered = true }
        if channel == "nativeMaterial:folders" { return try folders(id(request)) }
        let result: Any
        if channel.hasPrefix("courses:") { result = try courses(String(channel.dropFirst(8)), request) }
        else if channel.hasPrefix("courseGroups:") { result = try groups(String(channel.dropFirst(13)), request) }
        else if channel.hasPrefix("courseLinks:") { result = try links(String(channel.dropFirst(12)), request) }
        else if channel.hasPrefix("notes:") { result = try notes(String(channel.dropFirst(6)), request) }
        else if channel == "nativeMaterial:path" { return try context.materialURL(courseID: id(request), relativePath: string(request, "relPath")).path }
        else { result = try materials(String(channel.dropFirst(10)), request) }
        let action = channel.split(separator: ":").last.map(String.init) ?? ""
        if !["list", "tree", "snapshot", "search", "read", "readFile"].contains(action) {
            if channel.hasPrefix("courses:") || channel.hasPrefix("courseGroups:") { context.emit?("courses:changed", [:]) }
            else if let course = request["courseId"] as? String { context.emit?("materials:changed", ["courseId": course]) }
        }
        return result
    }
    private func id(_ request: [String: Any], _ key: String = "courseId") throws -> String { try C.requireID(request[key]) }
    private func string(_ request: [String: Any], _ key: String, empty: Bool = false) throws -> String { try C.requireString(request[key], key, allowEmpty: empty) }
    private func row(_ table: String, id: String, live: Bool = true) throws -> [String: Any] {
        guard let row = try context.query("SELECT * FROM \(table) WHERE id=?\(live ? " AND deleted_at IS NULL" : "")", [id]).first else { throw C.notFound(table, id) }; return row
    }
    private func course(_ row: [String: Any]) -> [String: Any] {
        let path = row["folder_path"] as? String ?? ""
        var directory: ObjCBool = false
        var value: [String: Any] = ["id": row["id"] ?? "", "name": row["name"] ?? "", "slug": row["slug"] ?? "", "color": row["color"] ?? "blue", "folderPath": path, "source": row["source"] ?? "managed", "workspaceKind": row["workspace_kind"] ?? "course", "missing": !context.files.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue, "archived": (row["archived"] as? NSNumber)?.boolValue ?? false, "groupId": row["group_id"] ?? NSNull(), "sortOrder": row["sort_order"] ?? 0, "createdAt": row["created_at"] ?? "", "updatedAt": row["updated_at"] ?? ""]
        if let deleted = row["deleted_at"] as? String { value["deletedAt"] = deleted }
        return value
    }
    private func listCourses(_ request: [String: Any] = [:]) throws -> [[String: Any]] {
        try context.query("SELECT * FROM courses WHERE \(request["includeDeleted"] as? Bool == true ? "1=1" : "deleted_at IS NULL") \(request["includeArchived"] as? Bool == true ? "" : "AND archived=0") ORDER BY sort_order,created_at").map(course)
    }
    private func slug(_ name: String) -> String {
        let result = C.key(name).replacingOccurrences(of: #"[/:*?\"<>|.#%&{}$!'@+`=~^;,\[\]()\\]"#, with: "", options: .regularExpression).replacingOccurrences(of: #"[\s_]+"#, with: "-", options: .regularExpression).replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "course" : String(result.prefix(64))
    }
    private func uniqueSlug(_ base: String, directory: URL?) throws -> String {
        let used = Set(try context.query("SELECT slug FROM courses").compactMap { $0["slug"] as? String })
        for n in 1..<1000 {
            let name = n == 1 ? base : "\(base)-\(n)"
            if !used.contains(name), directory == nil || !context.files.fileExists(atPath: directory!.appendingPathComponent(name).path) { return name }
        }
        throw C.conflict("새 과목 폴더 이름을 만들 수 없습니다.")
    }
    private func dataRoot() throws -> URL {
        let settings = context.root.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settings), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = value["dataRoot"] as? String, path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return context.root.appendingPathComponent("Courses", isDirectory: true)
    }
    private func courses(_ action: String, _ request: [String: Any]) throws -> Any {
        if action == "list" { return try listCourses(request) }
        if action == "create" || action == "addFromFolder" {
            let linked = action == "addFromFolder"
            let kind = request["workspaceKind"] as? String ?? "course"
            guard ["course", "study-space"].contains(kind) else { throw C.validation("Invalid workspace kind") }
            var name = (request["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let color = try string(request, "color").trimmingCharacters(in: .whitespacesAndNewlines)
            let folder: URL, source: String, token: String
            if linked {
                let path = try string(request, "folderPath")
                guard path.hasPrefix("/") else { throw C.validation("folderPath must be absolute") }
                folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(); source = "linked"
                if let failure = folderProblem(folder) { return ["status": "failed", "reason": failure] }
                if let existing = try context.query("SELECT * FROM courses WHERE folder_path=? AND deleted_at IS NULL", [folder.path]).first {
                    try context.run("UPDATE courses SET archived=0,updated_at=? WHERE id=?", [C.nowISO, existing["id"]!])
                    return ["status": "duplicate", "course": course(try row("courses", id: existing["id"] as! String))]
                }
                if name.isEmpty { name = folder.lastPathComponent }
                token = try uniqueSlug(slug(name), directory: nil)
            } else {
                _ = try C.requireString(name, "name")
                let parent = try dataRoot(); try context.files.createDirectory(at: parent, withIntermediateDirectories: true)
                token = try uniqueSlug(slug(name), directory: parent)
                folder = parent.appendingPathComponent(token); source = "managed"
                try context.files.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let key = UUID().uuidString.lowercased(), now = C.nowISO
            do {
                let order = try context.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS value FROM courses WHERE deleted_at IS NULL").first?["value"] ?? 0
                try context.run("INSERT INTO courses(id,name,slug,color,folder_path,source,workspace_kind,archived,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?,?,0,?,?,?)", [key, name, token, color, folder.path, source, kind, order, now, now])
            } catch {
                if !linked, (try? context.files.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? context.files.removeItem(at: folder) }
                throw error
            }
            let value = course(try row("courses", id: key)); return linked ? ["status": "ok", "course": value] : value
        }
        let key = try id(request), current = try row("courses", id: key, live: !["restore", "purge"].contains(action)), now = C.nowISO
        switch action {
        case "rename", "setColor", "setWorkspaceKind":
            let input = action == "rename" ? "name" : action == "setColor" ? "color" : "kind"
            let column = action == "rename" ? "name" : action == "setColor" ? "color" : "workspace_kind"
            let value = try string(request, input).trimmingCharacters(in: .whitespacesAndNewlines)
            if column == "workspace_kind", !["course", "study-space"].contains(value) { throw C.validation("Invalid workspace kind") }
            try context.run("UPDATE courses SET \(column)=?,updated_at=? WHERE id=?", [value, now, key])
        case "archive":
            guard let archive = request["archived"] as? Bool else { throw C.validation("archived must be boolean") }
            try context.run("UPDATE courses SET archived=?,updated_at=? WHERE id=?", [archive ? 1 : 0, now, key])
        case "delete":
            try context.run("UPDATE courses SET deleted_at=?,updated_at=? WHERE id=?", [now, now, key]); return ["ok": true]
        case "restore":
            let folder = URL(fileURLWithPath: current["folder_path"] as! String).resolvingSymlinksInPath()
            guard folderProblem(folder) == nil else { throw C.notFound("course folder", folder.path) }
            if try context.query("SELECT id,folder_path FROM courses WHERE deleted_at IS NULL AND id<>?", [key]).contains(where: { URL(fileURLWithPath: $0["folder_path"] as! String).resolvingSymlinksInPath() == folder }) { throw C.conflict("이 폴더가 다른 공간에 연결되어 있습니다.") }
            try context.run("UPDATE courses SET deleted_at=NULL,archived=0,updated_at=? WHERE id=?", [now, key])
        case "relink":
            let path = try string(request, "folderPath"); guard path.hasPrefix("/") else { throw C.validation("folderPath must be absolute") }
            let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            if let failure = folderProblem(folder) { return ["status": "failed", "reason": failure] }
            if let other = try context.query("SELECT * FROM courses WHERE folder_path=? AND deleted_at IS NULL AND id<>?", [folder.path, key]).first { return ["status": "duplicate", "course": course(other)] }
            try context.assertPathAvailable(courseID: key)
            try context.run("UPDATE courses SET folder_path=?,source='linked',updated_at=? WHERE id=?", [folder.path, now, key])
            return ["status": "ok", "course": course(try row("courses", id: key))]
        case "organize":
            let group = request["groupId"] as? String, before = request["beforeCourseId"] as? String
            if let group { _ = try row("course_groups", id: C.requireID(group)) }
            if before == key { throw C.validation("Cannot place a course before itself") }
            try context.transaction {
                var ordered = try context.query("SELECT id,group_id FROM courses WHERE deleted_at IS NULL AND id<>? ORDER BY sort_order,created_at", [key])
                let position: Int
                if let before {
                    guard let index = ordered.firstIndex(where: { $0["id"] as? String == before }), ordered[index]["group_id"] as? String == group else { throw C.validation("The target course must belong to the target group") }; position = index
                } else { position = ordered.lastIndex(where: { $0["group_id"] as? String == group }).map { $0 + 1 } ?? ordered.count }
                ordered.insert(["id": key, "group_id": group as Any? ?? NSNull()], at: position)
                try context.run("UPDATE courses SET group_id=?,updated_at=? WHERE id=?", [group as Any? ?? NSNull(), now, key])
                for (index, item) in ordered.enumerated() { try context.run("UPDATE courses SET sort_order=?,updated_at=? WHERE id=?", [index, now, item["id"]!]) }
            }
            return try listCourses()
        case "purge": return try purgeCourse(current)
        default: throw C.validation("Unsupported course action")
        }
        return course(try row("courses", id: key))
    }
    private func folderProblem(_ url: URL) -> String? {
        var directory: ObjCBool = false
        guard context.files.fileExists(atPath: url.path, isDirectory: &directory) else { return "missing" }
        if !directory.boolValue { return "not-a-directory" }
        return context.files.isReadableFile(atPath: url.path) ? nil : "unreadable"
    }
    private func groups(_ action: String, _ request: [String: Any]) throws -> Any {
        func value(_ row: [String: Any]) -> [String: Any] { ["id": row["id"]!, "name": row["name"]!, "sortOrder": row["sort_order"]!, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!] }
        if action == "list" { return try context.query("SELECT * FROM course_groups WHERE deleted_at IS NULL ORDER BY sort_order,created_at").map(value) }
        let now = C.nowISO
        if action == "create" {
            let key = UUID().uuidString.lowercased(), name = try string(request, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            let order = try context.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS value FROM course_groups WHERE deleted_at IS NULL").first?["value"] ?? 0
            try context.run("INSERT INTO course_groups(id,name,sort_order,created_at,updated_at) VALUES(?,?,?,?,?)", [key, name, order, now, now]); return value(try row("course_groups", id: key))
        }
        let key = try id(request, "groupId"); _ = try row("course_groups", id: key)
        if action == "rename" { try context.run("UPDATE course_groups SET name=?,updated_at=? WHERE id=?", [try string(request, "name").trimmingCharacters(in: .whitespacesAndNewlines), now, key]); return value(try row("course_groups", id: key)) }
        try context.transaction { try context.run("UPDATE courses SET group_id=NULL,updated_at=? WHERE group_id=?", [now, key]); try context.run("UPDATE course_groups SET deleted_at=?,updated_at=? WHERE id=?", [now, now, key]) }; return ["ok": true]
    }
    private func links(_ action: String, _ request: [String: Any]) throws -> Any {
        func value(_ r: [String: Any]) -> [String: Any] { ["id": r["id"]!, "courseId": r["course_id"]!, "label": r["label"]!, "url": r["url"]!, "rawUrl": r["raw_url"]!, "kind": r["kind"]!, "lmsCourseId": r["lms_course_id"] ?? NSNull(), "sortOrder": r["sort_order"]!, "createdAt": r["created_at"]!, "updatedAt": r["updated_at"]!] }
        if action == "list" { return try context.query("SELECT * FROM course_links WHERE course_id=? ORDER BY sort_order,created_at", [id(request)]).map(value) }
        let now = C.nowISO
        if action == "create" {
            let course = try id(request); _ = try row("courses", id: course)
            let label = try string(request, "label").trimmingCharacters(in: .whitespacesAndNewlines), raw = try string(request, "rawUrl").trimmingCharacters(in: .whitespacesAndNewlines), target = request["url"] as? String ?? raw
            guard label.count <= 60, let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw C.validation("Invalid link label or HTTP URL") }
            let kind = try string(request, "kind"); guard ["lms-course", "portal", "lms", "library", "mail", "registration", "homepage", "other"].contains(kind) else { throw C.validation("Invalid link kind") }
            let key = UUID().uuidString.lowercased(), order = try context.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS value FROM course_links WHERE course_id=?", [course]).first?["value"] ?? 0
            try context.run("INSERT INTO course_links(id,course_id,label,url,raw_url,kind,lms_course_id,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)", [key, course, label, url.absoluteString, raw, kind, request["lmsCourseId"] ?? NSNull(), order, now, now]); return value(try row("course_links", id: key, live: false))
        }
        let key = try id(request, "id"), current = try row("course_links", id: key, live: false)
        if action == "delete" { try context.run("DELETE FROM course_links WHERE id=?", [key]); return ["ok": true] }
        let label = (request["label"] as? String ?? current["label"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        let order = (request["sortOrder"] as? NSNumber)?.doubleValue ?? (current["sort_order"] as! NSNumber).doubleValue
        guard !label.isEmpty, label.count <= 60, order.isFinite, order >= 0, order.rounded() == order else { throw C.validation("Invalid link label/order") }
        try context.run("UPDATE course_links SET label=?,sort_order=?,updated_at=? WHERE id=?", [label, order, now, key]); return value(try row("course_links", id: key, live: false))
    }

    private func basename(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.count <= 120, name.range(of: #"[/\\:*?\"<>|\x00-\x1f]"#, options: .regularExpression) == nil else { throw C.validation("Invalid file or folder name") }; return name
    }
    private func title(_ input: String) throws -> String {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"[/\\:*?\"<>|\x00-\x1f]"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"^\.+"#, with: "", options: .regularExpression)
        return try basename(String(clean.prefix(120)))
    }
    private func path(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
    private func parent(_ relative: String) -> String { let result = (relative as NSString).deletingLastPathComponent; return result == "." ? "" : result }
    private func freeName(in directory: URL, requested: String, duplicate: Bool = false) throws -> String {
        let ext = (requested as NSString).pathExtension, stem = (requested as NSString).deletingPathExtension
        for n in (duplicate ? 2 : 1)...1000 {
            let candidate = n == 1 ? requested : stem + (duplicate ? "-\(n)" : " (\(n))") + (ext.isEmpty ? "" : "." + ext)
            var statValue = stat()
            if lstat(directory.appendingPathComponent(candidate).path, &statValue) != 0 && errno == ENOENT { return candidate }
        }
        throw C.conflict("사용 가능한 파일 이름이 없습니다.")
    }
    static func kind(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "pdf" }
        if ["md", "markdown"].contains(ext) { return "note" }
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "heic"].contains(ext) { return "image" }
        if ["mp4", "m4v", "webm"].contains(ext) { return "video" }
        return "other"
    }
    private func directory(course: String, relative: String, create: Bool = false) throws -> URL {
        try context.assertPathAvailable(courseID: course, relativePath: relative.isEmpty ? nil : relative)
        let url = try context.resolve(in: context.courseFolder(course), relativePath: relative, allowRoot: true)
        if create, !context.files.fileExists(atPath: url.path) { try context.files.createDirectory(at: url, withIntermediateDirectories: true) }
        guard (try C.identity(url)["directory"] as? Bool) == true else { throw C.notFound("directory", relative) }; return url
    }
    private func recordAdded(course: String, relative: String, directory: Bool = false) throws {
        try ensureBaseline(course)
        try context.run("INSERT INTO material_added_state(course_id,rel_path,added_at,pending_children) VALUES(?,?,?,?) ON CONFLICT(course_id,rel_path) DO UPDATE SET added_at=excluded.added_at,pending_children=excluded.pending_children", [course, relative, Date().timeIntervalSince1970 * 1000, directory ? 1 : 0])
    }
    @discardableResult private func ensureBaseline(_ course: String) throws -> Bool {
        let folder = try context.courseFolder(course).path
        if let old = try context.query("SELECT folder,completed FROM material_added_baselines WHERE course_id=?", [course]).first, old["folder"] as? String == folder { return (old["completed"] as? NSNumber)?.boolValue == true }
        try context.transaction { try context.run("DELETE FROM material_added_state WHERE course_id=?", [course]); try context.run("INSERT OR REPLACE INTO material_added_baselines(course_id,folder,completed) VALUES(?,?,0)", [course, folder]) }; return false
    }
    private func readDirectory(_ url: URL, remaining: inout Int, truncated: inout Bool, directoriesOnly: Bool = false) throws -> [(String, Bool)] {
        guard let directory = opendir(url.path) else { throw C.posix() }; defer { closedir(directory) }
        var output: [(String, Bool)] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0).precomposedStringWithCanonicalMapping } }
            if name == "." || name == ".." { continue }
            guard remaining > 0 else { truncated = true; break }; remaining -= 1
            if name.hasPrefix(".") { continue }
            if directoriesOnly, entry.pointee.d_type != UInt8(DT_DIR), entry.pointee.d_type != UInt8(DT_UNKNOWN) { continue }
            var info = stat(); guard lstat(url.appendingPathComponent(name).path, &info) == 0 else { throw C.posix() }
            let mode = info.st_mode & S_IFMT
            if mode == S_IFDIR || (!directoriesOnly && mode == S_IFREG) { output.append((name, mode == S_IFDIR)) }
        }
        return output.sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
    /// Share destinations need directory names, not file metadata or a rebuilt
    /// material index. This read-only walk does not mutate sync/export state.
    private func folders(_ course: String) throws -> [String] {
        try context.assertPathAvailable(courseID: course)
        let root = try context.courseFolder(course)
        var remaining = 20_000, truncated = false, result: [String] = []
        func walk(_ directory: URL, relative: String, depth: Int) throws {
            for (name, _) in try readDirectory(directory, remaining: &remaining, truncated: &truncated, directoriesOnly: true) {
                let relative = path(relative, name), url = try context.resolve(in: root, relativePath: relative)
                result.append(relative)
                if depth < 12 { try walk(url, relative: relative, depth: depth + 1) }
                else { truncated = true }
            }
        }
        try walk(root, relative: "", depth: 0)
        guard !truncated else { throw C.validation("폴더가 너무 많거나 깊어 공유 위치를 모두 읽지 못했습니다.") }
        return result
    }
    private func tree(_ course: String) throws -> [[String: Any]] {
        try context.assertPathAvailable(courseID: course)
        let folder = try context.courseFolder(course), initialized = try ensureBaseline(course)
        let existing = try context.query("SELECT rel_path,added_at,pending_children FROM material_added_state WHERE course_id=?", [course])
        // SQLite compares UTF-8 bytes, while Swift String equality treats NFC/NFD
        // as equal. Existing desktop databases can contain both spellings.
        var timestamps: [String: Any] = [:]
        for row in existing {
            guard let path = row["rel_path"] as? String else { continue }
            if timestamps[path] == nil || timestamps[path] is NSNull { timestamps[path] = row["added_at"] ?? NSNull() }
        }
        var indexedPaths: [String: String] = [:]
        for row in try context.query("SELECT rel_path FROM materials_index WHERE course_id=? ORDER BY deleted_at IS NOT NULL,created_at,id", [course]) {
            if let path = row["rel_path"] as? String, indexedPaths[path] == nil { indexedPaths[path] = path }
        }
        var remaining = 20_000, truncated = false, flat: [[String: Any]] = []
        func walk(_ directory: URL, _ relative: String, _ depth: Int) throws -> [[String: Any]] {
            var result: [[String: Any]] = []
            for (name, isDirectory) in try readDirectory(directory, remaining: &remaining, truncated: &truncated) {
                let rel = path(relative, name), url = try context.resolve(in: folder, relativePath: rel)
                if isDirectory {
                    let children: [[String: Any]]
                    if depth >= 12 { truncated = true; children = [] } else { children = try walk(url, rel, depth + 1) }
                    result.append(["relPath": rel, "name": name, "kind": "dir", "children": children])
                } else {
                    let attrs = try context.files.attributesOfItem(atPath: url.path)
                    var item: [String: Any] = ["relPath": indexedPaths[rel] ?? rel, "name": name, "kind": Self.kind(for: name), "size": attrs[.size] ?? 0, "mtime": try C.mtimeToken(url)]
                    if timestamps[rel] == nil {
                        let copiedParent = existing.filter { ($0["pending_children"] as? NSNumber)?.boolValue == true && C.contains($0["rel_path"] as? String ?? "", rel) }.max { ($0["rel_path"] as? String ?? "").count < ($1["rel_path"] as? String ?? "").count }
                        timestamps[rel] = copiedParent?["added_at"] ?? (initialized ? Date().timeIntervalSince1970 * 1000 : NSNull())
                    }
                    if let added = timestamps[rel], !(added is NSNull) { item["addedAt"] = added }
                    result.append(item); flat.append(item)
                }
            }
            return result
        }
        var nodes = try walk(folder, "", 0)
        // The 5 s watcher and every sync refresh call this. When the walk matches
        // the stored snapshot nothing on disk changed, so skip the fsync'd rewrite.
        if initialized, !truncated, let stored = try context.query("SELECT tree FROM material_tree_snapshots WHERE course_id=? AND folder=?", [course, folder.path]).first?["tree"] as? String,
           stored == (try C.json(nodes)) { return nodes }
        let now = C.nowISO, found = Set(flat.compactMap { $0["relPath"] as? String })
        try context.transaction {
            for file in flat {
                let rel = file["relPath"] as! String
                let bound = try context.tableExists("pdf_document_aliases") ? context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [course, rel]).first?["material_id"] as? String : nil
                let old = try context.query("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [course, rel]).first?["id"] as? String
                try context.run("INSERT INTO materials_index(id,course_id,rel_path,kind,size,mtime,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(course_id,rel_path) DO UPDATE SET id=excluded.id,kind=excluded.kind,size=excluded.size,mtime=excluded.mtime,updated_at=excluded.updated_at,deleted_at=NULL", [bound ?? old ?? UUID().uuidString.lowercased(), course, rel, file["kind"]!, file["size"]!, file["mtime"]!, now, now])
                try context.run("INSERT OR IGNORE INTO material_added_state(course_id,rel_path,added_at) VALUES(?,?,?)", [course, rel, timestamps[rel] ?? NSNull()])
            }
            if !truncated {
                for row in try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL", [course]) where !found.contains(row["rel_path"] as? String ?? "") { try context.run("UPDATE materials_index SET deleted_at=?,updated_at=? WHERE course_id=? AND rel_path=?", [now, now, course, row["rel_path"]!]) }
                for row in existing where !found.contains(row["rel_path"] as? String ?? "") { try context.run("DELETE FROM material_added_state WHERE course_id=? AND rel_path=?", [course, row["rel_path"]!]) }
                try context.run("UPDATE material_added_baselines SET completed=1 WHERE course_id=?", [course])
            }
            if truncated { nodes.append(["relPath": ".bandal/__materials_scan_truncated__", "name": "일부 자료만 표시됨 — 폴더 깊이 또는 자료 수가 스캔 한도를 넘었습니다", "kind": "dir", "children": []]) }
            try context.run("INSERT OR REPLACE INTO material_tree_snapshots(course_id,folder,tree) VALUES(?,?,?)", [course, folder.path, C.json(nodes)])
        }
        return nodes
    }
    private func materials(_ action: String, _ request: [String: Any]) throws -> Any {
        let course = try id(request)
        switch action {
        case "tree": return try tree(course)
        case "snapshot":
            let folder = try context.courseFolder(course).path
            guard let row = try context.query("SELECT tree FROM material_tree_snapshots WHERE course_id=? AND folder=?", [course, folder]).first, let json = row["tree"] as? String else { return ["tree": NSNull()] }
            return ["tree": try C.jsonObject(json)]
        case "search":
            let needle = C.key(try string(request, "query").trimmingCharacters(in: .whitespacesAndNewlines)); _ = try tree(course)
            return try context.query("SELECT rel_path,kind FROM materials_index WHERE course_id=? AND deleted_at IS NULL", [course]).compactMap { item -> [String: Any]? in
                let relative = item["rel_path"] as! String, name = (relative as NSString).lastPathComponent, key = C.key(name)
                guard C.key(relative).contains(needle) else { return nil }; return ["relPath": relative, "name": name, "kind": item["kind"]!, "score": key == needle ? 100 : key.hasPrefix(needle) ? 80 : key.contains(needle) ? 60 : 40]
            }.sorted { ($0["score"] as! Int) > ($1["score"] as! Int) }
        case "readFile":
            let url = try context.materialURL(courseID: course, relativePath: string(request, "relPath"))
            let identity = try C.identity(url); guard identity["directory"] as? Bool == false, (Int64(identity["size"] as? String ?? "0") ?? 0) <= 64 * 1024 * 1024 else { throw C.validation("파일을 읽을 수 없거나 64 MiB보다 큽니다.") }
            let bytes = try Data(contentsOf: url)
            if ["md", "markdown", "txt", "csv", "tsv", "json", "yml", "yaml", "xml", "html", "css", "js", "ts", "tex", "log", "srt", "vtt"].contains(url.pathExtension.lowercased()) { return ["encoding": "utf8", "data": String(decoding: bytes, as: UTF8.self)] }
            return ["encoding": "base64", "data": bytes.base64EncodedString()]
        case "importShared": return try importShared(course: course, request: request)
        case "import":
            guard let sources = request["paths"] as? [String] else { throw C.validation("paths must be strings") }
            return try context.withMaterialLock {
                let relative = request["dirRelPath"] as? String ?? "", target = try directory(course: course, relative: relative)
                var imported: [String] = [], failed: [[String: String]] = []
                for source in sources {
                    do {
                        guard source.hasPrefix("/") else { throw C.validation("Import source must be absolute") }
                        let original = URL(fileURLWithPath: source); guard try C.identity(original)["directory"] as? Bool == false else { throw C.validation("Import source must be a file") }
                        let name = try freeName(in: target, requested: basename(original.lastPathComponent)), dest = target.appendingPathComponent(name), rel = path(relative, name)
                        try context.files.copyItem(at: original, to: dest); try context.syncDirectory(target)
                        try recordAdded(course: course, relative: rel); imported.append(rel)
                    } catch { failed.append(["path": source, "reason": error.localizedDescription]) }
                }
                return ["imported": imported, "failed": failed]
            }
        case "rename", "move":
            let relative = try string(request, action == "rename" ? "relPath" : "fromRelPath"), source = try context.materialURL(courseID: course, relativePath: relative), isDirectory = try C.identity(source)["directory"] as? Bool == true
            let destination: String
            if action == "rename" { destination = path(parent(relative), try basename(string(request, "newName"))) }
            else {
                let target = try string(request, "toDirRelPath", empty: true), folder = try directory(course: course, relative: target)
                if target == parent(relative) { return ["relPath": relative] }
                guard !isDirectory || !C.contains(source.path, folder.path) else { throw C.validation("폴더를 자기 안으로 옮길 수 없습니다.") }
                destination = path(target, try freeName(in: folder, requested: source.lastPathComponent))
            }
            let rewritten = try rename(course: course, from: relative, to: destination, directory: isDirectory)
            return ["relPath": destination, "changedDocuments": rewritten]
        case "delete":
            return try context.withMaterialLock {
                let relative = try string(request, "relPath"), source = try context.materialURL(courseID: course, relativePath: relative)
                _ = try C.identity(source)
                _ = try trash(source, course: course, relative: relative)
                return ["ok": true]
            }
        case "duplicate":
            return try context.withMaterialLock {
                let relative = try string(request, "relPath"), source = try context.materialURL(courseID: course, relativePath: relative), info = try C.identity(source), folder = source.deletingLastPathComponent()
                let name = try freeName(in: folder, requested: source.lastPathComponent, duplicate: true), next = path(parent(relative), name)
                try context.files.copyItem(at: source, to: folder.appendingPathComponent(name)); try context.syncDirectory(folder)
                try recordAdded(course: course, relative: next, directory: info["directory"] as? Bool == true); return ["relPath": next]
            }
        case "createFolder":
            return try context.withMaterialLock {
                let relative = try string(request, "dirRelPath", empty: true), folder = try directory(course: course, relative: relative), name = try basename(string(request, "name")), target = folder.appendingPathComponent(name)
                guard !context.files.fileExists(atPath: target.path) else { throw C.conflict("동일한 이름의 자료가 있습니다.") }
                try context.files.createDirectory(at: target, withIntermediateDirectories: false); try context.syncDirectory(folder); return ["relPath": path(relative, name)]
            }
        case "writeFile", "adoptFile":
            return try context.withMaterialLock {
                let relative = try string(request, "dirRelPath", empty: true), folder = try directory(course: course, relative: relative, create: request["createDirIfMissing"] as? Bool == true), requested = try basename(string(request, "fileName"))
                let name = context.files.fileExists(atPath: folder.appendingPathComponent(requested).path) ? try freeName(in: folder, requested: requested, duplicate: true) : requested, target = folder.appendingPathComponent(name)
                if action == "writeFile" {
                    let encoding = try string(request, "encoding"), text = try string(request, "data", empty: true), bytes: Data
                    if encoding == "utf8" { bytes = Data(text.utf8) } else if encoding == "base64", let decoded = Data(base64Encoded: text) { bytes = decoded } else { throw C.validation("Invalid file encoding") }
                    guard bytes.count <= 50 * 1024 * 1024 else { throw C.validation("File exceeds 50 MiB write limit") }
                    try context.atomicWrite(bytes, to: target) { if self.context.files.fileExists(atPath: target.path) { throw C.conflict("대상 자료가 생성되었습니다.") } }
                } else {
                    let path = try string(request, "sourcePath"); guard path.hasPrefix("/") else { throw C.validation("sourcePath must be absolute") }
                    let source = URL(fileURLWithPath: path); guard try C.identity(source)["directory"] as? Bool == false else { throw C.validation("source must be a file") }
                    try context.movePreserving(source, to: target)
                }
                let next = path(relative, name); try recordAdded(course: course, relative: next); return ["relPath": next]
            }
        default: throw C.validation("Unsupported material action")
        }
    }
    /// A receipt is durable before publication. A relaunch after the file copy
    /// resumes that same destination; completed receipts never recreate a file
    /// the user subsequently moved or deleted.
    private func importShared(course: String, request: [String: Any]) throws -> [String: Any] {
        try context.withMaterialLock {
            let shareID = try string(request, "shareID")
            guard UUID(uuidString: shareID) != nil else { throw C.validation("Invalid share identifier") }
            let relative = request["dirRelPath"] as? String ?? ""
            let requested = try basename(string(request, "fileName"))
            let sourcePath = try string(request, "sourcePath")
            guard sourcePath.hasPrefix("/") else { throw C.validation("Share source must be absolute") }
            let source = URL(fileURLWithPath: sourcePath), hash = try context.contentHash(source)
            let receipts = context.root.appendingPathComponent("ShareReceipts", isDirectory: true)
            try context.files.createDirectory(at: receipts, withIntermediateDirectories: true)
            let receiptURL = receipts.appendingPathComponent(shareID + ".json")
            var receipt: [String: Any]
            if context.files.fileExists(atPath: receiptURL.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
                      saved["courseID"] as? String == course, saved["folderPath"] as? String == relative,
                      saved["sourceHash"] as? String == hash, let savedPath = saved["relativePath"] as? String else {
                    throw C.conflict("공유 가져오기 기록과 자료가 일치하지 않습니다. 원본을 보존했습니다.")
                }
                if saved["complete"] as? Bool == true { return ["relPath": savedPath, "alreadyImported": true] }
                receipt = saved
            } else {
                let folder = try directory(course: course, relative: relative)
                let name = try freeName(in: folder, requested: requested)
                receipt = ["courseID": course, "folderPath": relative, "sourceHash": hash,
                           "relativePath": path(relative, name), "complete": false]
                try context.atomicWrite(try JSONSerialization.data(withJSONObject: receipt), to: receiptURL)
            }
            guard let destination = receipt["relativePath"] as? String else { throw C.validation("Missing share destination") }
            let folder = try directory(course: course, relative: relative)
            Self.removeStaleShareCopies(in: folder)
            let target = try context.materialURL(courseID: course, relativePath: destination, allowMissing: true)
            if context.files.fileExists(atPath: target.path) {
                guard try context.contentHash(target) == hash else {
                    throw C.conflict("공유 대상 파일이 변경되었습니다. 덮어쓰지 않고 공유 원본을 보존했습니다.")
                }
            } else {
                let temporary = folder.appendingPathComponent(".bandal-share-" + UUID().uuidString)
                defer { try? context.files.removeItem(at: temporary) }
                try context.files.copyItem(at: source, to: temporary)
                guard try context.contentHash(temporary) == hash else { throw C.conflict("공유 원본이 복사 중 변경되었습니다.") }
                let handle = try FileHandle(forWritingTo: temporary)
                do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
                // RENAME_EXCL prevents replacing a file created by Files or a
                // linked-folder provider between the availability check and move.
                guard Darwin.renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw C.posix() }
                try context.syncDirectory(folder)
            }
            try recordAdded(course: course, relative: destination)
            receipt["complete"] = true
            try context.atomicWrite(try JSONSerialization.data(withJSONObject: receipt), to: receiptURL)
            return ["relPath": destination, "alreadyImported": false]
        }
    }

    /// Copying preserves the source's modification date, so expiry uses ctime
    /// (last local inode change) instead. A newly copied old PDF remains live.
    static func removeStaleShareCopies(in directory: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in entries {
            let name = file.lastPathComponent
            guard name.hasPrefix(".bandal-share-"), UUID(uuidString: String(name.dropFirst(14))) != nil else { continue }
            var attributes = stat()
            guard lstat(file.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                  now.timeIntervalSince1970 - Double(attributes.st_ctimespec.tv_sec) > 24 * 60 * 60 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func notes(_ action: String, _ request: [String: Any]) throws -> Any {
        let course = try id(request)
        if action == "create" {
            return try context.withMaterialLock {
                let relative = try string(request, "dirRelPath", empty: true), folder = try directory(course: course, relative: relative, create: true), title = try title(string(request, "title"))
                let requested = title + ".md", name = context.files.fileExists(atPath: folder.appendingPathComponent(requested).path) ? try freeName(in: folder, requested: requested, duplicate: true) : requested
                let url = folder.appendingPathComponent(name), next = path(relative, name)
                try context.atomicWrite(Data("# \(title)\n".utf8), to: url) { if self.context.files.fileExists(atPath: url.path) { throw C.conflict("노트가 이미 생성되었습니다.") } }
                try recordAdded(course: course, relative: next); return ["courseId": course, "relPath": next]
            }
        }
        let relative = try string(request, "relPath")
        guard (relative as NSString).pathExtension.lowercased() == "md" else { throw C.validation("notes must be .md files") }
        let url = try context.materialURL(courseID: course, relativePath: relative, allowMissing: action == "write")
        if action == "read" {
            let before = try C.identity(url); guard before["directory"] as? Bool == false else { throw C.notFound("note", relative) }
            let text = try String(contentsOf: url, encoding: .utf8), token = try C.mtimeToken(url)
            guard C.sameIdentity(before, try C.identity(url)) else { throw C.conflict("읽는 동안 노트가 변경되었습니다.") }
            return ["courseId": course, "relPath": relative, "markdown": text, "mtime": token]
        }
        if action == "write" {
            return try context.withMaterialLock {
                let text = try string(request, "markdown", empty: true), expected = (request["expectedMtime"] as? NSNumber)?.doubleValue
                let existed = context.files.fileExists(atPath: url.path)
                if request["expectedMtime"] != nil && (expected == nil || expected?.isFinite != true) { throw C.validation("expectedMtime must be finite") }
                func check() throws {
                    _ = try self.context.resolve(in: self.context.courseFolder(course), relativePath: relative)
                    if let expected { guard self.context.files.fileExists(atPath: url.path), try C.mtimeToken(url) == expected else { throw C.conflict("\(relative) changed on disk") } }
                }
                try check()
                if existed { guard try C.identity(url)["directory"] as? Bool == false else { throw C.validation("Note is not a file") } }
                try context.files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try context.atomicWrite(Data(text.utf8), to: url, beforePublish: check)
                if !existed { try recordAdded(course: course, relative: relative) }
                return ["mtime": try C.mtimeToken(url)]
            }
        }
        let requested = try string(request, "newName"), newTitle = try title(requested.replacingOccurrences(of: #"(?i)\.md$"#, with: "", options: .regularExpression))
        let folder = url.deletingLastPathComponent(), desired = newTitle + ".md"
        let name = desired == url.lastPathComponent || !context.files.fileExists(atPath: folder.appendingPathComponent(desired).path) ? desired : try freeName(in: folder, requested: desired, duplicate: true)
        let next = path(parent(relative), name), before = try String(contentsOf: url, encoding: .utf8), after = Self.replaceNoteTitle(before, title: (name as NSString).deletingPathExtension)
        _ = try rename(course: course, from: relative, to: next, directory: false, heading: (before, after))
        let final = try context.materialURL(courseID: course, relativePath: next)
        return ["relPath": next, "title": (name as NSString).deletingPathExtension, "markdown": try String(contentsOf: final, encoding: .utf8), "mtime": try C.mtimeToken(final)]
    }

    private func walkRegular(_ folder: URL, limit: Int = 100_000) throws -> [(String, URL)] {
        var remaining = limit, truncated = false, result: [(String, URL)] = []
        func walk(_ directory: URL, _ relative: String, _ depth: Int) throws {
            guard depth <= 64 else { throw C.validation("Folder is too deep to preserve a rename safely") }
            for (name, isDirectory) in try readDirectory(directory, remaining: &remaining, truncated: &truncated) {
                let rel = path(relative, name), url = try context.resolve(in: folder, relativePath: rel)
                if isDirectory { try walk(url, rel, depth + 1) } else { result.append((rel, url)) }
            }
        }
        try walk(folder, "", 0)
        if truncated { throw C.validation("Folder is too large to preserve a rename safely") }; return result
    }
    /// Returns the notes whose links were rewritten (course + path before the
    /// rename), so only their open editors are invalidated.
    @discardableResult
    private func rename(course: String, from: String, to: String, directory: Bool, heading: (String, String)? = nil) throws -> [[String: Any]] {
        try context.withMaterialLock {
            try context.assertPathAvailable(courseID: course)
            let folder = try context.courseFolder(course), source = try context.resolve(in: folder, relativePath: from), target = try context.resolve(in: folder, relativePath: to)
            if from == to && heading == nil { return [] }
            var rewritten: [[String: Any]] = []
            guard from == to || !context.files.fileExists(atPath: target.path) else { throw C.conflict("동일한 이름의 자료가 있습니다.") }
            if directory && C.contains(source.path, target.path) { throw C.validation("폴더를 자기 안으로 옮길 수 없습니다.") }
            try context.beforeMaterialRename?(course, from, to, directory)
            var original = try C.identity(source)
            guard original["directory"] as? Bool == directory else { throw C.conflict("자료 종류가 변경되었습니다.") }
            if directory {
                original["pdfs"] = try walkRegular(source).filter { $0.1.pathExtension.lowercased() == "pdf" }.map { ["relativePath": $0.0, "identity": try C.identity($0.1)] }
            }
            var notes: [[String: Any]] = [], total = 0
            for (relative, url) in try walkRegular(folder) where ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                let info = try C.identity(url)
                guard (Int64(info["size"] as? String ?? "0") ?? 0) <= 16 * 1024 * 1024 else { throw C.validation("Note is too large to journal safely: \(relative)") }
                let before = try String(contentsOf: url, encoding: .utf8)
                guard C.sameIdentity(info, try C.identity(url)) else { throw C.conflict("노트를 읽는 동안 변경되었습니다.") }
                let next = C.repointed(relative, from: from, to: to, directory: directory) ?? relative
                if relative == from, let heading, before != heading.0 { throw C.conflict("이름 변경 전에 노트가 변경되었습니다.") }
                let body = relative == from ? heading?.1 ?? before : before
                let after = try Self.rewriteMaterialNote(body, course: course, from: from, to: to, directory: directory)
                if after != before {
                    let mode = (try context.files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                    guard mode & 0o222 != 0 else { throw C.validation("읽기 전용 노트의 링크를 변경할 수 없습니다: \(relative)") }
                    total += before.utf8.count + after.utf8.count
                    guard total <= 32 * 1024 * 1024 else { throw C.validation("Rename note recovery plan exceeds 32 MiB") }
                    notes.append(["relPath": next, "before": before, "after": after, "mode": mode])
                    if relative != from { rewritten.append(["courseId": course, "relPath": relative]) }
                }
            }
            let key = UUID().uuidString.lowercased()
            let linkedPageNotes = try crossCoursePageNoteRenameFiles(course: course, from: from, to: to, directory: directory)
            let additionalFiles = try context.planMaterialRenameFiles?(course, from, to, directory, key) ?? []
            for proposed in linkedPageNotes + additionalFiles {
                let owner = proposed["courseId"] as? String ?? course, ownerFolder = try context.courseFolder(owner)
                let next = try C.requireString(proposed["relPath"], "rename file path"), before = try C.requireString(proposed["before"], "rename file before", allowEmpty: true), after = try C.requireString(proposed["after"], "rename file after", allowEmpty: true)
                if before == after { continue }
                let old = owner == course ? C.repointed(next, from: to, to: from, directory: directory) ?? next : next
                let url = try context.resolve(in: ownerFolder, relativePath: old)
                _ = try context.resolve(in: ownerFolder, relativePath: next)
                guard try String(contentsOf: url, encoding: .utf8) == before, !notes.contains(where: { ($0["courseId"] as? String ?? course) == owner && $0["relPath"] as? String == next }) else { throw C.conflict("이름 변경에 연결된 파일이 변경되거나 중복되었습니다.") }
                let mode = (try context.files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                guard mode & 0o222 != 0 else { throw C.validation("연결된 학습 파일이 읽기 전용입니다.") }
                total += before.utf8.count + after.utf8.count
                guard total <= 32 * 1024 * 1024 else { throw C.validation("Rename recovery plan exceeds 32 MiB") }
                notes.append(["courseId": owner, "relPath": next, "before": before, "after": after, "mode": mode, "folderIdentity": try C.identity(ownerFolder)])
                rewritten.append(["courseId": owner, "relPath": old])
            }
            guard C.sameIdentity(original, try C.identity(source)) else { throw C.conflict("이름 변경 준비 중 자료가 변경되었습니다.") }
            try context.run("INSERT INTO material_path_intents(id,course_id,folder_path,folder_identity,from_rel_path,to_rel_path,original_identity,created_at,note_writes) VALUES(?,?,?,?,?,?,?,?,?)", [key, course, folder.path, C.json(C.identity(folder)), from, to, C.json(original), C.nowISO, C.json(notes)])
            do {
                if from != to { try context.movePreserving(source, to: target) }
                try context.run("UPDATE material_path_intents SET moved_identity=? WHERE id=?", [C.json(C.identity(target)), key])
                for note in notes {
                    let relative = note["relPath"] as! String, before = note["before"] as! String, after = note["after"] as! String, noteFolder = try validatedNoteFolder(note, fallback: folder), url = try context.resolve(in: noteFolder, relativePath: relative)
                    try context.atomicWrite(Data(after.utf8), to: url) {
                        guard try String(contentsOf: url, encoding: .utf8) == before else { throw C.conflict("링크를 저장하기 전에 노트가 변경되었습니다: \(relative)") }
                    }
                }
                try context.transaction {
                    try repointDatabase(course: course, from: from, to: to, directory: directory)
                    try context.run("DELETE FROM material_path_intents WHERE id=?", [key])
                }
            } catch {
                let operationError = error
                do { try rollbackIntent(key) }
                catch { throw DesktopRuntimeError("이름 변경 복구가 필요합니다. 원본·변경본·복구 기록을 보존했습니다. \(operationError.localizedDescription) / \(error.localizedDescription)", code: "RECOVERY_REQUIRED") }
                throw operationError
            }
            return rewritten
        }
    }
    /// A page note may be stored in another course. Its link proves which PDF
    /// owns the manifest; ordinary relative links in that course stay untouched.
    private func crossCoursePageNoteRenameFiles(course: String, from: String, to: String, directory: Bool) throws -> [[String: Any]] {
        var result: [[String: Any]] = [], targets = Set<String>()
        let prefix = "<!-- bandal:pdf-page-note "
        for row in try context.query("SELECT source_json,target_json FROM material_links WHERE kind='pdf-page-note'") {
            guard let source = try C.jsonObject(row["source_json"] as? String ?? "") as? [String: Any],
                  source["kind"] as? String == "pdf", let sourcePayload = source["payload"] as? [String: Any],
                  sourcePayload["courseId"] as? String == course, let oldPath = sourcePayload["relPath"] as? String,
                  let newPath = C.repointed(oldPath, from: from, to: to, directory: directory), oldPath != newPath,
                  let target = try C.jsonObject(row["target_json"] as? String ?? "") as? [String: Any],
                  target["kind"] as? String == "note", let targetPayload = target["payload"] as? [String: Any],
                  let owner = targetPayload["courseId"] as? String, owner != course,
                  let path = targetPayload["relPath"] as? String else { continue }
            guard targets.insert(owner + ":" + path).inserted else { throw C.conflict("중복된 PDF 페이지 노트 연결을 먼저 정리해 주세요.") }
            let url = try context.materialURL(courseID: owner, relativePath: path), identity = try C.identity(url)
            guard (Int64(identity["size"] as? String ?? "0") ?? 0) <= 16 * 1024 * 1024 else { throw C.validation("연결된 페이지 노트가 너무 큽니다.") }
            let before = try String(contentsOf: url, encoding: .utf8)
            guard C.sameIdentity(identity, try C.identity(url)), before.hasPrefix(prefix), let end = before.range(of: " -->") else { throw C.conflict("연결된 페이지 노트의 원본 정보를 확인하지 못했습니다.") }
            let range = before.index(before.startIndex, offsetBy: prefix.count)..<end.lowerBound
            guard var manifest = try C.jsonObject(String(before[range])) as? [String: Any], manifest["version"] as? Int == 1,
                  let encoded = manifest["source"] as? String, encoded.removingPercentEncoding == oldPath || encoded == oldPath else { throw C.conflict("연결된 페이지 노트의 원본 경로가 다릅니다. 원문을 보존했습니다.") }
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
            manifest["source"] = newPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? newPath
            var after = before; after.replaceSubrange(range, with: try C.json(manifest))
            result.append(["courseId": owner, "relPath": path, "before": before, "after": after])
        }
        return result
    }
    /// An unfinished SQL transaction has not repointed records. Restore the
    /// exact captured file/text state before allowing either old or new path.
    func recoverPathChanges() throws {
        try context.withMaterialLock {
            for row in try context.query("SELECT id FROM material_path_intents ORDER BY created_at,id") { if let id = row["id"] as? String { try rollbackIntent(id) } }
        }
    }
    private func rollbackIntent(_ key: String) throws {
        guard let intent = try context.query("SELECT * FROM material_path_intents WHERE id=?", [key]).first,
              let course = intent["course_id"] as? String, let from = intent["from_rel_path"] as? String, let to = intent["to_rel_path"] as? String,
              let folderIdentity = try C.jsonObject(intent["folder_identity"] as? String ?? "") as? [String: Any], let original = try C.jsonObject(intent["original_identity"] as? String ?? "") as? [String: Any] else { throw C.validation("Malformed material recovery intent") }
        let folder = try context.courseFolder(course), currentFolder = try C.identity(folder)
        guard folderIdentity["dev"] as? String == currentFolder["dev"] as? String, folderIdentity["ino"] as? String == currentFolder["ino"] as? String else { throw C.conflict("복구할 과목 폴더가 다른 폴더로 교체되었습니다.") }
        let source = try context.resolve(in: folder, relativePath: from), target = try context.resolve(in: folder, relativePath: to)
        let sourceExists = context.files.fileExists(atPath: source.path), targetExists = context.files.fileExists(atPath: target.path)
        if from != to && sourceExists && targetExists { throw C.conflict("복구 대상의 두 경로가 모두 존재합니다. 두 자료를 보존했습니다.") }
        guard sourceExists || targetExists else { throw C.conflict("복구할 자료가 원래 경로와 변경 경로 모두에 없습니다.") }
        let moved = from == to || !sourceExists, location = moved ? target : source
        let notes = try C.jsonObject(intent["note_writes"] as? String ?? "[]") as? [[String: Any]] ?? []
        let current = try C.identity(location)
        let originalNote = notes.first { ($0["courseId"] as? String ?? course) == course && $0["relPath"] as? String == to }
        let knownText: Bool
        if let originalNote, current["directory"] as? Bool == false, let text = try? String(contentsOf: location, encoding: .utf8) { knownText = text == originalNote["before"] as? String || text == originalNote["after"] as? String } else { knownText = false }
        let sameDirectory = original["directory"] as? Bool == true && current["directory"] as? Bool == true && original["dev"] as? String == current["dev"] as? String && original["ino"] as? String == current["ino"] as? String
        // Publishing journaled child text updates the parent's mtime. The
        // directory inode and each protected PDF, not mtime, identify that tree.
        guard sameDirectory || C.sameIdentity(original, current, changeTime: false) || knownText else { throw C.conflict("복구 대상 파일이 외부에서 변경되었습니다.") }
        for pdf in original["pdfs"] as? [[String: Any]] ?? [] {
            guard let relative = pdf["relativePath"] as? String, let previous = pdf["identity"] as? [String: Any] else { throw C.validation("Invalid protected PDF identity") }
            guard C.sameIdentity(previous, try C.identity(context.resolve(in: location, relativePath: relative))) else { throw C.conflict("이름 변경 중 PDF가 교체되었습니다. 원래 필기 기록을 보존했습니다.") }
        }
        for note in notes {
            guard let next = note["relPath"] as? String, let before = note["before"] as? String, let after = note["after"] as? String else { throw C.validation("Invalid note recovery data") }
            let owner = note["courseId"] as? String ?? course, noteFolder = try validatedNoteFolder(note, fallback: folder)
            let rel = moved || owner != course ? next : C.repointed(next, from: to, to: from, directory: original["directory"] as? Bool == true) ?? next
            let url = try context.resolve(in: noteFolder, relativePath: rel), text = try String(contentsOf: url, encoding: .utf8)
            if text == before { continue }
            guard text == after else { throw C.conflict("복구 중 노트의 새 변경을 발견했습니다: \(rel)") }
            try context.atomicWrite(Data(before.utf8), to: url) { guard try String(contentsOf: url, encoding: .utf8) == after else { throw C.conflict("복구 중 노트가 변경되었습니다.") } }
        }
        if moved && from != to { try context.movePreserving(target, to: source) }
        try context.run("DELETE FROM material_path_intents WHERE id=?", [key])
    }
    private func validatedNoteFolder(_ note: [String: Any], fallback: URL) throws -> URL {
        guard let owner = note["courseId"] as? String else { return fallback }
        let folder = try context.courseFolder(owner), current = try C.identity(folder)
        guard let recorded = note["folderIdentity"] as? [String: Any], recorded["dev"] as? String == current["dev"] as? String, recorded["ino"] as? String == current["ino"] as? String else { throw C.conflict("이름 변경에 연결된 과목 폴더가 교체되었습니다.") }
        return folder
    }
    private func repointDatabase(course: String, from: String, to: String, directory: Bool) throws {
        let now = C.nowISO
        // Include inactive/tombstoned rows: undo and immutable create receipts
        // must still address their original drawing after a file move.
        let tables = ["annotations", "pdf_drawings", "media_progress", "pdf_view_state", "materials_index", "material_added_state", "pdf_document_aliases", "cloud_sync_docs"]
        for table in tables where try context.tableExists(table) {
            let columns = try context.columns(table)
            for row in try context.query("SELECT rowid AS native_row,rel_path FROM \(table) WHERE course_id=?", [course]) {
                guard let old = row["rel_path"] as? String, let next = C.repointed(old, from: from, to: to, directory: directory), next != old else { continue }
                // A stale destination row can carry ink identity. Refuse instead
                // of replacing it or silently merging unrelated histories.
                let occupied = try context.query("SELECT rowid AS native_row FROM \(table) WHERE course_id=? AND rel_path=?", [course, next])
                if ["materials_index", "pdf_document_aliases", "media_progress", "pdf_view_state"].contains(table), !occupied.isEmpty { throw C.conflict("이전 자료 기록이 대상 경로를 사용하고 있습니다: \(next)") }
                if table == "material_added_state" { try context.run("DELETE FROM material_added_state WHERE course_id=? AND rel_path=?", [course, next]) }
                // Ink moving with its PDF is not an edit: the stroke keeps its updated_at.
                let touch = columns.contains("updated_at") && table != "pdf_drawings"
                try context.run("UPDATE \(table) SET rel_path=?\(touch ? ",updated_at=?" : "") WHERE rowid=?", touch ? [next, now, row["native_row"]!] : [next, row["native_row"]!])
            }
        }
        func rewrite(_ value: Any, assumedCourse: String?) -> Any {
            if let items = value as? [Any] { return items.map { rewrite($0, assumedCourse: assumedCourse) } }
            guard var object = value as? [String: Any] else { return value }
            let owner = object["courseId"] as? String ?? object["courseID"] as? String ?? assumedCourse
            for (key, item) in object {
                if owner == course, ["relPath", "relativePath", "sourceRelPath", "audioRelPath", "transcriptRelPath", "audio_rel_path", "transcript_rel_path"].contains(key), let path = item as? String, let next = C.repointed(path, from: from, to: to, directory: directory) { object[key] = next }
                else if item is [String: Any] || item is [Any] { object[key] = rewrite(item, assumedCourse: owner) }
            }
            return object
        }
        for (table, fields) in [("favorites", ["descriptor_json"]), ("material_links", ["source_json", "target_json"]), ("pdf_drawings", ["data_json"]), ("tabs_layout", ["layout_json"]), ("whiteboard_local_shapes", ["data_json"]), ("recording_sessions", ["payload"]), ("recording_anchors", ["payload"])] where try context.tableExists(table) {
            let columns = try context.columns(table)
            let filter = table == "material_links" ? "" : columns.contains("course_id") ? " WHERE course_id=?" : table == "recording_anchors" ? " WHERE session_id IN (SELECT id FROM recording_sessions WHERE course_id=?)" : " WHERE board_id IN (SELECT id FROM whiteboards WHERE course_id=?)"
            for row in try context.query("SELECT rowid AS native_row,* FROM \(table)\(filter)", table == "material_links" ? [] : [course]) {
                for field in fields where columns.contains(field) {
                    guard let text = row[field] as? String else { continue }
                    let previous = try C.jsonObject(text), next = rewrite(previous, assumedCourse: row["course_id"] as? String ?? course), encoded = try C.json(next)
                    if encoded != (try C.json(previous)) { try context.run("UPDATE \(table) SET \(field)=?\(columns.contains("updated_at") ? ",updated_at=?" : "") WHERE rowid=?", columns.contains("updated_at") ? [encoded, now, row["native_row"]!] : [encoded, row["native_row"]!]) }
                }
            }
        }
        if try context.tableExists("recordings") {
            let columns = try context.columns("recordings")
            for field in ["audio_rel_path", "transcript_rel_path", "audio_path", "transcript_path"] where columns.contains(field) {
                for row in try context.query("SELECT id,\(field) FROM recordings WHERE course_id=?", [course]) {
                    if let old = row[field] as? String, let next = C.repointed(old, from: from, to: to, directory: directory) { try context.run("UPDATE recordings SET \(field)=?,updated_at=? WHERE id=?", [next, now, row["id"]!]) }
                }
            }
        }
        if try context.tableExists("content_links") {
            for row in try context.query("SELECT rowid AS native_row,source_ref,target_path FROM content_links WHERE course_id=?", [course]) {
                for field in ["source_ref", "target_path"] {
                    if let old = row[field] as? String, let next = C.repointed(old, from: from, to: to, directory: directory) { try context.run("UPDATE content_links SET \(field)=? WHERE rowid=?", [next, row["native_row"]!]) }
                }
            }
        }
        // Derived snapshots are regenerated from the renamed filesystem.
        try context.run("DELETE FROM material_tree_snapshots WHERE course_id=?", [course])
    }

    static func replaceNoteTitle(_ markdown: String, title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        var metadataEnd = -1
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let end = lines.indices.dropFirst().first(where: { lines[$0].range(of: #"^(?:---|\.\.\.)\s*$"#, options: .regularExpression) != nil }),
           lines[1..<end].contains(where: { $0.range(of: #"^[\w.-]+[ \t]*:"#, options: .regularExpression) != nil }) { metadataEnd = end }
        var fence: (Character, Int)?, comment = false, tag: String?
        for index in lines.indices where index > metadataEnd {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if comment { if line.contains("-->") { comment = false }; continue }
            if let literal = tag { if line.range(of: "</\(literal)\\s*>", options: [.regularExpression, .caseInsensitive]) != nil { tag = nil }; continue }
            if let active = fence {
                if let first = trimmed.first, first == active.0, trimmed.allSatisfy({ $0 == first }), trimmed.count >= active.1 { fence = nil }; continue
            }
            if line.range(of: #"^ {0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil, let first = trimmed.first { fence = (first, trimmed.prefix(while: { $0 == first }).count); continue }
            if line.range(of: #"^ {0,3}<!--"#, options: .regularExpression) != nil { comment = !line.contains("-->"); continue }
            if let range = line.range(of: #"^ {0,3}<(pre|script|style|textarea)(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) {
                let text = String(line[range]).trimmingCharacters(in: .whitespaces).dropFirst(), name = String(text.prefix(while: { $0.isLetter })).lowercased()
                if line.range(of: "</\(name)\\s*>", options: [.regularExpression, .caseInsensitive]) == nil { tag = name }; continue
            }
            if line.range(of: #"^ {0,3}#(?:[ \t]+.*|[ \t]*)$"#, options: .regularExpression) != nil { lines[index] = "# " + title; return lines.joined(separator: "\n") }
        }
        if metadataEnd >= 0 { lines.insert(contentsOf: ["", "# " + title, ""], at: metadataEnd + 1); return lines.joined(separator: "\n") }
        return "# \(title)\n\n" + markdown
    }
    static func rewriteMaterialNote(_ markdown: String, course: String, from: String, to: String, directory: Bool) throws -> String {
        func replacements(_ text: String, pattern: String, transform: (String, [String]) throws -> String) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern), ns = text as NSString
            var result = text
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let original = ns.substring(with: match.range), groups = (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
                guard let range = Range(match.range, in: result) else { continue }; result.replaceSubrange(range, with: try transform(original, groups))
            }
            return result
        }
        func noteKey(_ value: String) -> String { C.key(value.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: .regularExpression) }
        var value = try replacements(markdown, pattern: #"!?\[\[([^\[\]|#\n]+?)(?:#([^\[\]|\n]+?))?(?:\|([^\[\]\n]+?))?\]\]"#) { original, groups in
            let target = groups[0].trimmingCharacters(in: .whitespacesAndNewlines), pathForm = target.contains("/"), oldName = (from as NSString).lastPathComponent, newName = (to as NSString).lastPathComponent
            let next: String?
            if directory { next = pathForm ? C.repointed(target, from: from, to: to, directory: true) : nil }
            else {
                let ext = (oldName as NSString).pathExtension, wroteExtension = !ext.isEmpty && C.key(target).hasSuffix("." + C.key(ext))
                if pathForm {
                    next = noteKey(target) == noteKey(from) ? (wroteExtension ? to : to.replacingOccurrences(of: #"(?i)\.(md|markdown)$"#, with: "", options: .regularExpression)) : nil
                } else if noteKey(target) == noteKey(oldName) || noteKey(target) == noteKey((oldName as NSString).deletingPathExtension) {
                    let wroteStem = !wroteExtension && noteKey(target) == noteKey((oldName as NSString).deletingPathExtension)
                    next = wroteStem ? (newName as NSString).deletingPathExtension : wroteExtension ? newName : newName.replacingOccurrences(of: #"(?i)\.(md|markdown)$"#, with: "", options: .regularExpression)
                } else { next = nil }
            }
            guard let next, next != target else { return original }
            let heading = groups[1].trimmingCharacters(in: .whitespacesAndNewlines), alias = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
            return (original.hasPrefix("!") ? "!" : "") + "[[" + next + (heading.isEmpty ? "" : "#" + heading) + (alias.isEmpty ? "" : "|" + alias) + "]]"
        }
        value = try replacements(value, pattern: #"bandal://material/?\?[^\s)>]+"#) { original, _ in
            guard var url = URLComponents(string: original), var items = url.queryItems,
                  let index = items.firstIndex(where: { ["path", "relPath"].contains($0.name) }), let path = items[index].value,
                  let next = C.repointed(path, from: from, to: to, directory: directory) else { return original }
            if let owner = items.first(where: { ["courseId", "course"].contains($0.name) })?.value, owner != course { return original }
            items[index].value = next; url.queryItems = items; return url.string ?? original
        }
        if value.hasPrefix("<!-- bandal:pdf-page-note "), let end = value.range(of: " -->") {
            let prefix = "<!-- bandal:pdf-page-note ", range = value.index(value.startIndex, offsetBy: prefix.count)..<end.lowerBound
            if var manifest = try? C.jsonObject(String(value[range])) as? [String: Any], let encoded = manifest["source"] as? String, let source = encoded.removingPercentEncoding, let next = C.repointed(source, from: from, to: to, directory: directory) {
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
                manifest["source"] = next.addingPercentEncoding(withAllowedCharacters: allowed) ?? next
                value.replaceSubrange(range, with: try C.json(manifest))
            }
        }
        return value
    }
    @discardableResult private func trash(_ source: URL, course: String, relative: String) throws -> URL {
        let directory = context.root.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try context.files.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try context.atomicWrite(Data(C.json(["courseId": course, "relPath": relative, "originalPath": source.path, "createdAt": C.nowISO]).utf8), to: directory.appendingPathComponent("manifest.json"))
        do { try context.movePreserving(source, to: target) }
        catch { if context.files.fileExists(atPath: source.path), !context.files.fileExists(atPath: target.path) { try? context.files.removeItem(at: directory) }; throw error }
        return target
    }
    private func purgeCourse(_ course: [String: Any]) throws -> Any {
        guard course["deleted_at"] is String, course["source"] as? String == "managed", let id = course["id"] as? String, let path = course["folder_path"] as? String else { throw C.validation("Only a deleted managed course can be purged") }
        let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        for row in try context.query("SELECT folder_path FROM courses WHERE deleted_at IS NULL") {
            if let path = row["folder_path"] as? String {
                let other = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                if C.contains(folder.path, other) || C.contains(other, folder.path) { throw C.conflict("이 폴더를 다른 공간에서 사용하고 있습니다.") }
            }
        }
        return try context.withMaterialLock {
            let backup = context.root.appendingPathComponent("MigrationRecovery", isDirectory: true)
            try context.files.createDirectory(at: backup, withIntermediateDirectories: true)
            // Purge is rare. Retain a consistent SQLite backup alongside Trash,
            // including annotations and receipts, before removing any rows.
            try context.run("VACUUM INTO ?", [backup.appendingPathComponent("purged-course-\(id)-\(UUID().uuidString).db").path])
            let trashed = context.files.fileExists(atPath: folder.path) ? try trash(folder, course: id, relative: "") : nil
            do {
                try context.transaction {
                    try context.run("DELETE FROM message_blocks WHERE message_id IN (SELECT id FROM messages WHERE course_id=?)", [id])
                    try context.run("DELETE FROM whiteboard_local_shapes WHERE board_id IN (SELECT id FROM whiteboards WHERE course_id=?)", [id])
                    try context.run("DELETE FROM messages WHERE course_id=?", [id])
                    for row in try context.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('courses','messages')") {
                        guard let table = row["name"] as? String, table.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
                        if try context.columns(table).contains("course_id") { try context.run("DELETE FROM \(table) WHERE course_id=?", [id]) }
                    }
                    try context.run("DELETE FROM courses WHERE id=?", [id])
                }
            } catch {
                if let trashed, !context.files.fileExists(atPath: folder.path) { try context.movePreserving(trashed, to: folder) }; throw error
            }
            return ["ok": true]
        }
    }
}
