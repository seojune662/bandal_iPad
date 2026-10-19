import Foundation
import Darwin
import CryptoKit

/// All repositories are called on DesktopRuntime's serial storage queue.
/// SQLite, file publication and recovery share this one lifetime and root.
final class NativeRepositoryContext {
    let db: DesktopSQLite
    let root: URL
    let legacyRoot: URL
    var emit: ((String, Any) -> Void)?
    var planMaterialRenameFiles: ((String, String, String, Bool, String) throws -> [[String: Any]])?
    var beforeMaterialRename: ((String, String, String, Bool) throws -> Void)?
    private var savepointSequence: UInt64 = 0
    private var materialLockDepth = 0
    let files = FileManager.default

    init(root: URL, legacyRoot: URL) throws {
        self.root = root.standardizedFileURL
        self.legacyRoot = legacyRoot.standardizedFileURL
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        db = try DesktopSQLite(url: root.appendingPathComponent("bandal.db"))
        try NativeDatabaseMigrations.apply(to: db)
        try db.exec("CREATE TABLE IF NOT EXISTS native_file_hashes(path TEXT PRIMARY KEY, identity TEXT NOT NULL, sha256 TEXT NOT NULL)")
        #if canImport(UIKit)
        // Loading the registry resumes persisted security-scoped folder access.
        _ = DesktopFileAccess.shared(root: root).allows(root)
        #endif
        try relocateManagedStorage()
    }

    private var hashes: [String: (identity: String, digest: String)] = [:]
    /// SHA-256 of a file, cached by `dev:ino:size:mtime_ns:ctime_ns` in memory and
    /// in SQLite. Any write changes that identity, so no writer has to invalidate;
    /// a file is hashed once per version and stat-checked afterwards.
    func contentHash(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw POSIXError(.EIO) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw Self.validation("Source is not a regular file") }
        let signature = Self.fileIdentity(before)
        if let cached = hashes[url.path], cached.identity == signature { return cached.digest }
        if let row = try? query("SELECT sha256 FROM native_file_hashes WHERE path=? AND identity=?", [url.path, signature]).first,
           let digest = row["sha256"] as? String, digest.count == 64 {
            hashes[url.path] = (signature, digest); return digest
        }
        var hash = SHA256(), bytes = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }; hash.update(data: Data(bytes.prefix(count)))
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              Self.fileIdentity(after) == signature, Self.fileIdentity(current) == signature else { throw Self.validation("File changed while hashing; retry after saving finishes") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if hashes.count >= 512 { hashes.removeAll(keepingCapacity: true) }
        hashes[url.path] = (signature, digest)
        try? run("INSERT OR REPLACE INTO native_file_hashes(path,identity,sha256) VALUES(?,?,?)", [url.path, signature, digest])
        return digest
    }
    static func fileIdentity(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    @discardableResult func run(_ sql: String, _ values: [Any] = []) throws -> [String: Any] { try db.run(sql, params: values) }
    func query(_ sql: String, _ values: [Any] = []) throws -> [[String: Any]] { try db.query(sql, params: values) }
    func tableExists(_ name: String) throws -> Bool { try !query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty }
    func columns(_ table: String) throws -> Set<String> {
        guard table.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil else { throw Self.validation("Invalid SQL table") }
        return Set(try query("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        savepointSequence &+= 1
        let name = "native_\(savepointSequence)"
        try db.exec("SAVEPOINT \(name)")
        do {
            let value = try body()
            try db.exec("RELEASE SAVEPOINT \(name)")
            return value
        } catch {
            do { try db.exec("ROLLBACK TO SAVEPOINT \(name); RELEASE SAVEPOINT \(name)") }
            catch { throw DesktopRuntimeError("저장 작업과 되돌리기에 실패했습니다. 원본과 복구 기록을 보존했습니다: \(error.localizedDescription)", code: "RECOVERY_REQUIRED") }
            throw error
        }
    }
    func withMaterialLock<T>(_ body: () throws -> T) throws -> T {
        if materialLockDepth > 0 { return try body() }
        let fd = Darwin.open(root.appendingPathComponent("material-path-lock.db").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posix() }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.conflict("다른 저장 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.") }
        materialLockDepth += 1
        defer { materialLockDepth -= 1; flock(fd, LOCK_UN) }
        return try body()
    }
    func courseFolder(_ id: String) throws -> URL {
        _ = try Self.requireID(id)
        guard let row = try query("SELECT folder_path FROM courses WHERE id=? AND deleted_at IS NULL", [id]).first,
              let path = row["folder_path"] as? String, path.hasPrefix("/") else { throw Self.notFound("course", id) }
        let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { throw Self.notFound("course folder", path) }
        return folder
    }
    func materialURL(courseID: String, relativePath: String, allowMissing: Bool = false) throws -> URL {
        try assertPathAvailable(courseID: courseID, relativePath: relativePath)
        let result = try resolve(in: courseFolder(courseID), relativePath: relativePath, allowRoot: false)
        if !allowMissing && !files.fileExists(atPath: result.path) { throw Self.notFound("material", relativePath) }
        return result
    }
    func resolve(in folder: URL, relativePath: String, allowRoot: Bool = false) throws -> URL {
        if relativePath.isEmpty && allowRoot { return folder }
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: { $0.value < 32 }),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw DesktopRuntimeError("[path-traversal] Invalid relative path: \(relativePath)", code: "PATH_TRAVERSAL") }
        let target = folder.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalRoot = folder.resolvingSymlinksInPath().standardizedFileURL
        // Resolving all existing parents also protects a new file beneath a symlink.
        var existing = target
        var suffix: [String] = []
        while !files.fileExists(atPath: existing.path) {
            var info = stat()
            if lstat(existing.path, &info) == 0 { throw Self.validation("Dangling symbolic link: \(relativePath)") }
            guard existing.path != "/" else { throw Self.notFound("parent", relativePath) }
            suffix.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
        }
        var actual = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in suffix { actual.appendPathComponent(part) }
        guard Self.contains(canonicalRoot.path, actual.path), Self.contains(canonicalRoot.path, target.path) else { throw DesktopRuntimeError("[path-traversal] \(relativePath) escapes the course folder", code: "PATH_TRAVERSAL") }
        return target
    }
    func assertPathAvailable(courseID: String, relativePath: String? = nil) throws {
        guard try tableExists("material_path_intents") else { return }
        for row in try query("SELECT course_id,from_rel_path,to_rel_path,note_writes FROM material_path_intents") {
            let from = row["from_rel_path"] as? String ?? "", to = row["to_rel_path"] as? String ?? ""
            let notes = (try? Self.jsonObject(row["note_writes"] as? String ?? "[]")) as? [[String: Any]] ?? []
            let owns = row["course_id"] as? String == courseID
            let paths = (owns ? [from, to] : []) + notes.filter { ($0["courseId"] as? String ?? row["course_id"] as? String) == courseID }.compactMap { $0["relPath"] as? String }
            if paths.isEmpty { continue }
            if relativePath == nil || paths.contains(where: { Self.overlaps($0, relativePath!) }) { throw Self.conflict("자료 경로 복구가 필요합니다. \(from) → \(to)의 원본과 기록을 보존했습니다.") }
        }
    }
    func atomicWrite(_ data: Data, to url: URL, beforePublish: (() throws -> Void)? = nil) throws {
        let parent = url.deletingLastPathComponent()
        guard files.fileExists(atPath: parent.path) else { throw Self.notFound("directory", parent.path) }
        let temp = parent.appendingPathComponent(".bandal-save-\(UUID().uuidString)")
        let mode = (try? files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else { throw Self.posix() }
        defer { Darwin.close(fd); try? files.removeItem(at: temp) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if wrote < 0 && errno == EINTR { continue }
                guard wrote > 0 else { throw Self.posix() }; offset += wrote
            }
        }
        guard fsync(fd) == 0 else { throw Self.posix() }
        try beforePublish?()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw Self.posix() }
        try syncDirectory(parent)
    }
    func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posix() }
        defer { Darwin.close(fd) }
        if fsync(fd) != 0 && errno != EINVAL { throw Self.posix() }
    }
    func movePreserving(_ source: URL, to target: URL) throws {
        guard !files.fileExists(atPath: target.path) else { throw Self.conflict("대상 파일이 이미 있습니다: \(target.lastPathComponent)") }
        try files.moveItem(at: source, to: target)
        try syncDirectory(source.deletingLastPathComponent())
        if source.deletingLastPathComponent() != target.deletingLastPathComponent() { try syncDirectory(target.deletingLastPathComponent()) }
    }
    static func mtimeToken(_ url: URL) throws -> Double {
        var value = stat()
        guard fstatat(AT_FDCWD, url.path, &value, 0) == 0 else { throw posix() }
        return Double(Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)) / 1_000_000
    }
    static func identity(_ url: URL) throws -> [String: Any] {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posix() }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw validation("Not a regular file or directory: \(url.lastPathComponent)") }
        return ["dev": String(value.st_dev), "ino": String(value.st_ino), "size": String(value.st_size),
                "mtimeNs": String(Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)),
                "ctimeNs": String(Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec)), "directory": kind == S_IFDIR]
    }
    static func sameIdentity(_ a: [String: Any], _ b: [String: Any], changeTime: Bool = true) -> Bool {
        let base = ["dev", "ino"].allSatisfy { a[$0] as? String == b[$0] as? String } && a["directory"] as? Bool == b["directory"] as? Bool
        return base && (a["directory"] as? Bool == true || (["size", "mtimeNs"] + (changeTime ? ["ctimeNs"] : [])).allSatisfy { a[$0] as? String == b[$0] as? String })
    }
    static var nowISO: String { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.string(from: Date()) }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self) }
    static func jsonObject(_ text: String) throws -> Any { try DesktopJSON.decode(Data(text.utf8), options: [.fragmentsAllowed]) }
    static func requireString(_ value: Any?, _ name: String, allowEmpty: Bool = false) throws -> String {
        guard let result = value as? String, allowEmpty || !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw validation("\(name) must be a string\(allowEmpty ? "" : " with content")") }; return result
    }
    static func requireID(_ value: Any?) throws -> String {
        let text = try requireString(value, "id")
        guard UUID(uuidString: text) != nil else { throw validation("id must be a UUID") }; return text
    }
    static func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/") }
    static func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    static func overlaps(_ a: String, _ b: String) -> Bool { contains(key(a), key(b)) || contains(key(b), key(a)) }
    static func repointed(_ path: String, from: String, to: String, directory: Bool) -> String? {
        if key(path) == key(from) { return to }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false), prefix = from.split(separator: "/", omittingEmptySubsequences: false)
        guard directory, parts.count > prefix.count, key(parts.prefix(prefix.count).joined(separator: "/")) == key(from) else { return nil }
        return to + "/" + parts.dropFirst(prefix.count).joined(separator: "/")
    }
    static func validation(_ message: String) -> DesktopRuntimeError { DesktopRuntimeError("[validation] " + message, code: "VALIDATION") }
    static func conflict(_ message: String) -> DesktopRuntimeError { DesktopRuntimeError("[conflict] " + message, code: "CONFLICT") }
    static func notFound(_ entity: String, _ id: String) -> DesktopRuntimeError { DesktopRuntimeError("[not-found] \(entity) \"\(id)\" does not exist", code: "NOT_FOUND") }
    static func posix() -> DesktopRuntimeError { DesktopRuntimeError(String(cString: strerror(errno)), code: errno == ENOENT ? "ENOENT" : "EIO") }

    private func relocateManagedStorage() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS ipad_storage_locations(root TEXT PRIMARY KEY)")
        func clean(_ path: String) -> Bool { path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && URL(fileURLWithPath: path).standardizedFileURL.path == path }
        var previous = Set(try query("SELECT root FROM ipad_storage_locations").compactMap { $0["root"] as? String }.filter(clean))
        let courses = try query("SELECT id,source,folder_path FROM courses"), settingsPath = root.appendingPathComponent("settings.json")
        let settings = (try? Data(contentsOf: settingsPath)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let pattern = #"^((?:/private)?/var/mobile/Containers/Data/Application/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/Documents/BandalDesktop)(?:/|$)"#
        let candidates = courses.filter { $0["source"] as? String == "managed" }.compactMap { $0["folder_path"] as? String } + [settings?["dataRoot"] as? String].compactMap { $0 }
        for path in candidates where clean(path) {
            if let match = path.range(of: pattern, options: .regularExpression) { let found = String(path[match]); previous.insert(found.hasSuffix("/") ? String(found.dropLast()) : found) }
        }
        for path in Array(previous) where path.range(of: pattern, options: .regularExpression) != nil { previous.insert(path.hasPrefix("/private/") ? String(path.dropFirst(8)) : "/private" + path) }
        // Every launch re-encoded every sync row. Once this root and every known
        // old root are recorded, nothing can have moved since the last relocation.
        let recorded = Set(try query("SELECT root FROM ipad_storage_locations").compactMap { $0["root"] as? String })
        if recorded.contains(root.path), previous.subtracting([root.path]).isSubset(of: recorded) { return }
        previous.remove(root.path)
        func replacement(_ path: String) -> String? { guard clean(path) else { return nil }; for old in previous.sorted(by: { $0.count > $1.count }) where Self.contains(old, path) { return root.path + path.dropFirst(old.count) }; return nil }
        func preservedDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return files.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue && Self.contains(root.resolvingSymlinksInPath().path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        var moved: [(String, String, String)] = []
        for course in courses where course["source"] as? String == "managed" {
            guard let id = course["id"] as? String, let old = course["folder_path"] as? String, let new = replacement(old), Self.contains(root.appendingPathComponent("Courses").path, new), preservedDirectory(new) else { continue }
            if courses.contains(where: { $0["id"] as? String != id && $0["folder_path"] as? String == new }) { throw Self.conflict("복원된 폴더가 다른 과목에 연결되어 있습니다.") }
            moved.append((id, old, new))
        }
        func rebase(_ value: Any) -> Any {
            guard let path = value as? String, clean(path) else { return value }
            for (_, old, new) in moved where Self.contains(old, path) { return new + path.dropFirst(old.count) }
            guard let target = replacement(path) else { return value }
            for directory in ["SyncRecovery", "SyncConflictAssets", "CommonSync", "Temporary", "MigrationRecovery"] where Self.contains(root.appendingPathComponent(directory).path, target) { return target }
            return value
        }
        var fileChanges: [(URL, Any)] = []
        if var settings, let old = settings["dataRoot"] as? String, let target = replacement(old), Self.contains(root.appendingPathComponent("Courses").path, target), preservedDirectory(target) { settings["dataRoot"] = target; fileChanges.append((settingsPath, settings)) }
        let recovery = root.appendingPathComponent("SyncRecovery")
        if files.fileExists(atPath: recovery.path) {
            for directory in try files.contentsOfDirectory(at: recovery, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]); if info.isDirectory != true || info.isSymbolicLink == true { continue }
                let path = directory.appendingPathComponent("intent.json"); if !files.fileExists(atPath: path.path) { continue }
                guard var intent = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any], let entries = intent["entries"] as? [[String: Any]] else { throw Self.validation("Invalid storage recovery journal") }
                intent["entries"] = entries.map { entry -> [String: Any] in var result = entry; for field in ["target", "source", "backup"] { if let value = result[field] { result[field] = rebase(value) } }; return result }
                fileChanges.append((path, intent))
            }
        }
        var jsonChanges: [(String, String, String, Any, String)] = []
        func rows(_ table: String, _ column: String, _ key: String, _ update: (Any) throws -> Any) throws {
            guard try tableExists(table), try columns(table).contains(column) else { return }
            for row in try query("SELECT \(key),\(column) FROM \(table)") {
                guard let text = row[column] as? String else { continue }
                let old = try Self.jsonObject(text), next = try update(old), encoded = try Self.json(next)
                if encoded != (try Self.json(old)) { jsonChanges.append((table, column, key, row[key]!, encoded)) }
            }
        }
        try rows("ipad_sync_projection", "source_json", "id") { value in
            guard var object = value as? [String: Any] else { throw Self.validation("Invalid sync source") }
            if let id = object["courseID"] as? String, courses.contains(where: { $0["id"] as? String == id && $0["source"] as? String == "linked" }) { return object }
            for field in ["path", "folder", "root"] { if let value = object[field] { object[field] = rebase(value) } }; return object
        }
        try rows("ipad_sync_conflicts", "assets_json", "id") { value in
            guard let assets = value as? [[String: Any]] else { throw Self.validation("Invalid conflict assets") }
            return assets.map { asset -> [String: Any] in var result = asset; if let path = result["path"] { result["path"] = rebase(path) }; return result }
        }
        try rows("ipad_legacy_migrations", "report_json", "version") { value in guard var object = value as? [String: Any] else { throw Self.validation("Invalid legacy migration report") }; if let path = object["recoveryPath"] { object["recoveryPath"] = rebase(path) }; return object }
        // Persist retry evidence before a settings-only old-root hint is replaced.
        try transaction { for old in previous { try run("INSERT OR IGNORE INTO ipad_storage_locations(root) VALUES(?)", [old]) } }
        for (path, value) in fileChanges { try atomicWrite(Data(Self.json(value).utf8), to: path) }
        try transaction {
            for (id, old, new) in moved { try run("UPDATE courses SET folder_path=? WHERE id=? AND folder_path=?", [new, id, old]); try run("UPDATE material_added_baselines SET folder=? WHERE course_id=? AND folder=?", [new, id, old]); try run("UPDATE material_path_intents SET folder_path=? WHERE course_id=? AND folder_path=?", [new, id, old]) }
            for (table, column, key, id, text) in jsonChanges { try run("UPDATE \(table) SET \(column)=? WHERE \(key)=?", [text, id]) }
            if try tableExists("ipad_sync_asset_cache") { for row in try query("SELECT sha256,path FROM ipad_sync_asset_cache") { if let path = row["path"] { try run("UPDATE ipad_sync_asset_cache SET path=? WHERE sha256=?", [rebase(path), row["sha256"]!]) } } }
            try run("INSERT OR IGNORE INTO ipad_storage_locations(root) VALUES(?)", [root.path])
        }
    }
}
