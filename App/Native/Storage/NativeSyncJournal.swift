import Foundation

/// Files and SQLite commit separately. A durable receipt decides whether a
/// crash is completed or rolled back; original copies remain available.
final class NativeSyncJournal {
    private let context: NativeRepositoryContext
    private let root: URL
    init(context: NativeRepositoryContext) throws {
        self.context = context; root = context.root.appendingPathComponent("SyncRecovery")
        try context.files.createDirectory(at: root, withIntermediateDirectories: true)
        try context.db.exec("CREATE TABLE IF NOT EXISTS ipad_sync_commits(id TEXT PRIMARY KEY)")
    }
    func recover() throws {
        for directory in try context.files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) where (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            let path = directory.appendingPathComponent("intent.json")
            if !context.files.fileExists(atPath: path.path) { continue }
            guard let intent = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any], let id = intent["id"] as? String, let entries = intent["entries"] as? [[String: Any]], id == directory.lastPathComponent else { throw NativeRepositoryContext.validation("Invalid sync recovery journal") }
            let committed = try !context.query("SELECT id FROM ipad_sync_commits WHERE id=?", [id]).isEmpty
            if !committed { try restore(entries, directory: directory) }
            do { try context.files.removeItem(at: path); try context.syncDirectory(directory) }
            catch {
                // A durable commit receipt makes a leftover intent inert.
                // An uncommitted intent must be removed before allowing edits,
                // otherwise the next recovery could roll back those new edits.
                if !committed { throw error }
            }
        }
    }
    /// Recovery changes canonical files and therefore runs before editors are
    /// opened. In a running workspace, even export must remain read-only when
    /// an earlier failed import left a recoverable intent behind.
    func requireSettled() throws {
        for directory in try context.files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) where (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            let path = directory.appendingPathComponent("intent.json")
            if !context.files.fileExists(atPath: path.path) { continue }
            guard let intent = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any], let id = intent["id"] as? String, id == directory.lastPathComponent else { throw NativeRepositoryContext.validation("Invalid sync recovery journal") }
            if try context.query("SELECT id FROM ipad_sync_commits WHERE id=?", [id]).isEmpty {
                throw DesktopRuntimeError("동기화 복구 기록을 보존했습니다. 앱을 다시 열어 복구한 뒤 동기화를 다시 시도해 주세요.", code: "RECOVERY_REQUIRED")
            }
        }
    }
    func apply(_ plan: NativeSyncPlan, commit: () throws -> Void) throws {
        let id = UUID().uuidString.lowercased(), directory = root.appendingPathComponent(id), intentPath = directory.appendingPathComponent("intent.json")
        try context.files.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [[String: Any]] = [], unique = Set<String>()
        for (index, file) in plan.files.enumerated() {
            try validateTarget(file.target)
            guard unique.insert(NativeRepositoryContext.key(file.target.path)).inserted else { throw NativeRepositoryContext.validation("Duplicate sync file target") }
            let existed = context.files.fileExists(atPath: file.target.path), backup = directory.appendingPathComponent("\(index).original")
            if file.expectedMissing && existed { throw NativeRepositoryContext.conflict("Sync target appeared after its snapshot") }
            if let expected = file.expectedHash { guard existed, try NativeSyncFormat.hash(file.target) == expected else { throw NativeRepositoryContext.conflict("Sync target changed after its snapshot") } }
            var row: [String: Any] = ["target": file.target.path, "backup": backup.path, "existed": existed, "remove": file.data == nil]
            if existed {
                _ = try NativeRepositoryContext.identity(file.target)
                let data = try Data(contentsOf: file.target)
                row["beforeHash"] = NativeSyncFormat.hash(data); try context.atomicWrite(data, to: backup)
            }
            if let data = file.data { row["afterHash"] = NativeSyncFormat.hash(data) }
            entries.append(row)
        }
        try context.atomicWrite(Data(try NativeSyncFormat.canonical(["id": id, "entries": entries]).utf8), to: intentPath)
        do {
            try context.transaction {
                for (index, file) in plan.files.enumerated() {
                    try validateTarget(file.target)
                    let entry = entries[index], exists = context.files.fileExists(atPath: file.target.path)
                    if (entry["existed"] as? Bool == true) {
                        guard exists, try NativeSyncFormat.hash(file.target) == entry["beforeHash"] as? String else { throw NativeRepositoryContext.conflict("Sync file changed before commit") }
                    } else if exists { throw NativeRepositoryContext.conflict("Sync target appeared before commit") }
                    try context.files.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let data = file.data { try context.atomicWrite(data, to: file.target) }
                    else if exists { try context.files.removeItem(at: file.target); try context.syncDirectory(file.target.deletingLastPathComponent()) }
                }
                try plan.apply(); try commit(); try context.run("INSERT INTO ipad_sync_commits(id) VALUES(?)", [id])
            }
        } catch {
            do { try restore(entries, directory: directory); try context.files.removeItem(at: intentPath); try context.syncDirectory(directory) }
            catch { throw DesktopRuntimeError("Sync recovery retained originals: \(error.localizedDescription)", code: "RECOVERY_REQUIRED") }
            throw error
        }
        // Publication and its receipt are already durable. Cleanup failure is
        // not a failed import: keep the receipt and retry cleanup on recovery.
        // Returning success lets the caller retire affected open editors.
        try? context.files.removeItem(at: intentPath)
        try? context.syncDirectory(directory)
    }
    private func validateTarget(_ target: URL) throws {
        guard target.path == target.standardizedFileURL.path else { throw NativeRepositoryContext.validation("Unsafe sync target") }
        for course in try context.query("SELECT folder_path FROM courses") {
            guard let folder = course["folder_path"] as? String, NativeRepositoryContext.contains(folder, target.path), folder != target.path else { continue }
            let relative = String(target.path.dropFirst(folder.count + 1))
            _ = try context.resolve(in: URL(fileURLWithPath: folder), relativePath: relative); return
        }
        // A new course has not entered SQLite until this journal commits.
        let managed = context.root.appendingPathComponent("Courses")
        if NativeRepositoryContext.contains(managed.path, target.path), target.path != managed.path {
            _ = try context.resolve(in: managed, relativePath: String(target.path.dropFirst(managed.path.count + 1))); return
        }
        throw NativeRepositoryContext.validation("Sync target is outside registered course storage")
    }
    private func restore(_ entries: [[String: Any]], directory: URL) throws {
        for entry in entries.reversed() {
            guard let targetPath = entry["target"] as? String, let backupPath = entry["backup"] as? String, let existed = entry["existed"] as? Bool else { throw NativeRepositoryContext.validation("Invalid recovery entry") }
            let target = URL(fileURLWithPath: targetPath), backup = URL(fileURLWithPath: backupPath)
            try validateTarget(target)
            guard backup.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
                  NativeRepositoryContext.contains(root.resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path) else { throw NativeRepositoryContext.validation("Unsafe recovery backup") }
            if existed { _ = try NativeRepositoryContext.identity(backup) }
            let before = existed ? try NativeSyncFormat.hash(backup) : nil
            if let declared = entry["beforeHash"] as? String, declared != before { throw NativeRepositoryContext.conflict("Recovery original checksum changed") }
            var after = entry["afterHash"] as? String
            if after == nil, let source = entry["source"] as? String, context.files.fileExists(atPath: source) { after = try NativeSyncFormat.hash(URL(fileURLWithPath: source)) }
            if after == nil, let text = entry["text"] as? String { after = NativeSyncFormat.hash(Data(text.utf8)) }
            let exists = context.files.fileExists(atPath: target.path), actual = exists ? try NativeSyncFormat.hash(target) : nil
            if actual == before { continue }
            guard actual == after || actual == nil else { throw NativeRepositoryContext.conflict("A newer file blocks recovery; both versions remain preserved: \(target.lastPathComponent)") }
            if existed { try context.files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try context.atomicWrite(Data(contentsOf: backup), to: target) }
            else if exists { try context.files.removeItem(at: target); try context.syncDirectory(target.deletingLastPathComponent()) }
        }
    }
}
