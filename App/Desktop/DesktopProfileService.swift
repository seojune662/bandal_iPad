import Foundation
import UIKit
import UniformTypeIdentifiers
import BandalCore
import SQLite3
import Darwin

/// A profile switch selects new storage. It never erases or rebinds the old one.
@MainActor
final class DesktopProfileService: NSObject, UIDocumentPickerDelegate {
    static let didActivate = Notification.Name("BandalProfileDidActivate")
    struct Selection: Codable { let id: String; let rootName: String }
    struct Fingerprint: Codable, Equatable { let path: String; let sha256: String; let bytes: Int64 }
    struct BackupReceipt: Codable { let directory: String; let sources: [String]; let fingerprints: [Fingerprint] }
    let documents: URL
    let root: URL
    weak var presenter: UIViewController?
    var prepare: (() async throws -> Void)?
    var resume: (() -> Void)?
    var activate: (() -> Void)?
    var exportDirectory: ((URL) async throws -> URL?)?
    private var busy = false
    private var pickerContinuation: CheckedContinuation<URL?, Error>?
    private var backupReceiptURL: URL { root.appendingPathComponent("profile-backup-receipt.json") }

    init(documents: URL, root: URL) { self.documents = documents; self.root = root }
    static func selectedRoot(in documents: URL) throws -> URL {
        let file = documents.appendingPathComponent("active-profile.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return documents.appendingPathComponent("BandalDesktop") }
        let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: file))
        guard UUID(uuidString: selection.id) != nil, selection.rootName == "BandalProfile-" + selection.id else { throw DesktopRuntimeError("프로필 위치를 확인하지 못했습니다.") }
        let root = documents.appendingPathComponent(selection.rootName)
        guard root.resolvingSymlinksInPath().deletingLastPathComponent().path == documents.resolvingSymlinksInPath().path, FileManager.default.fileExists(atPath: root.path) else { throw DesktopRuntimeError("보관된 프로필을 찾지 못했습니다.") }
        return root
    }
    static func legacyRoot(documents: URL, root: URL) -> URL {
        root.lastPathComponent == "BandalDesktop" ? documents.appendingPathComponent("Bandal") : root.appendingPathComponent("Legacy")
    }
    static func webStorageID(root: URL) -> UUID {
        UUID(uuidString: String(root.lastPathComponent.dropFirst("BandalProfile-".count))) ?? UUID(uuidString: "F2BE39F5-5762-4B21-AD23-26EBEF97D932")!
    }
    func handle(_ channel: String) async throws -> [String: Any] {
        guard !busy else { throw DesktopRuntimeError("프로필 작업이 진행 중입니다.") }
        busy = true
        var switched = false
        defer { busy = false; if !switched { resume?() } }
        try await prepare?()
        if channel == "profile:backup" { return try await backup() }
        guard channel == "profile:new" else { throw DesktopRuntimeError("지원하지 않는 프로필 요청입니다.") }
        guard let receipt = try? JSONDecoder().decode(BackupReceipt.self, from: Data(contentsOf: backupReceiptURL)) else { throw DesktopRuntimeError("먼저 현재 자료를 백업해 주세요.", code: "PROFILE_BACKUP_REQUIRED") }
        let saved = URL(fileURLWithPath: receipt.directory).standardizedFileURL
        let backups = documents.appendingPathComponent("BandalBackups").standardizedFileURL
        guard saved.path.hasPrefix(backups.path + "/"), FileManager.default.fileExists(atPath: saved.appendingPathComponent("manifest.json").path),
              try fingerprints(receipt.sources.map { URL(fileURLWithPath: $0) }) == receipt.fingerprints else {
            throw DesktopRuntimeError("마지막 백업 뒤 자료가 바뀌었습니다. 다시 백업한 뒤 새 프로필을 만들어 주세요.", code: "PROFILE_BACKUP_REQUIRED")
        }
        try verifyBackup(at: saved)
        let id = UUID().uuidString.lowercased(), name = "BandalProfile-" + id
        let next = documents.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: next.appendingPathComponent("Legacy"), withIntermediateDirectories: false)
        try Self.writeDurably(JSONEncoder().encode(Selection(id: id, rootName: name)), to: documents.appendingPathComponent("active-profile.json"))
        // The old root remains at its original absolute path for recovery.
        switched = true
        activate?(); return ["ok": true, "profileID": name]
    }
    private func sourceRoots() throws -> [URL] {
        var roots = [root]
        let legacy = Self.legacyRoot(documents: documents, root: root)
        if FileManager.default.fileExists(atPath: legacy.path), !legacy.path.hasPrefix(root.path + "/") { roots.append(legacy) }
        let database = root.appendingPathComponent("bandal.db")
        if FileManager.default.fileExists(atPath: database.path) {
            let db = try DesktopSQLite(url: database, readOnly: true)
            for course in try db.query("SELECT folder_path FROM courses", params: nil) {
                guard let path = course["folder_path"] as? String else { continue }
                let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                if roots.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) { continue }
                guard DesktopFileAccess.shared(root: root).allows(folder), FileManager.default.fileExists(atPath: folder.path) else { throw DesktopRuntimeError("연결한 과목 폴더에 접근한 뒤 백업을 다시 시도해 주세요.") }
                roots.append(folder)
            }
        }
        return roots
    }
    private func files(_ roots: [URL], includeSQLiteSidecars: Bool = true) throws -> [URL] {
        var result: [URL] = []
        let excluded = Set(["DesktopBrowser", "Temporary", "Logs", "profile-backup-receipt.json"])
        for source in roots {
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { throw DesktopRuntimeError("백업할 자료를 읽지 못했습니다.") }
            for case let file as URL in enumerator {
                let relative = String(file.path.dropFirst(source.path.count + 1)), first = relative.split(separator: "/").first.map(String.init) ?? ""
                if excluded.contains(first) { enumerator.skipDescendants(); continue }
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true else { throw DesktopRuntimeError("연결된 파일은 원본 위치를 확인한 뒤 백업해 주세요.") }
                guard attributes.isRegularFile == true else { continue }
                if file.path.hasSuffix("-shm") { continue }
                if !includeSQLiteSidecars, file.path.hasSuffix("-wal") { continue }
                result.append(file)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    private func fingerprints(_ roots: [URL]) throws -> [Fingerprint] {
        try files(roots).map { file in
            let revision = try AssetHasher.revision(of: file, contentType: "application/octet-stream")
            return Fingerprint(path: file.path, sha256: revision.sha256, bytes: revision.byteCount)
        }
    }
    private func backup() async throws -> [String: Any] {
        let sources = try sourceRoots(), before = try fingerprints(sources)
        let destination = documents.appendingPathComponent("BandalBackups/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        for (index, source) in sources.enumerated() {
            for file in try files([source], includeSQLiteSidecars: false) {
                let relative = String(file.path.dropFirst(source.path.count + 1)), target = destination.appendingPathComponent("source-\(index)/" + relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let handle = try FileHandle(forReadingFrom: file)
                let header = try handle.read(upToCount: 16); try handle.close()
                if header == Data("SQLite format 3\0".utf8) { try Self.snapshotDatabase(file, to: target) }
                else { try FileManager.default.copyItem(at: file, to: target) }
                let output = try FileHandle(forWritingTo: target); try output.synchronize(); try output.close()
            }
        }
        guard try fingerprints(sources) == before else { throw DesktopRuntimeError("백업하는 동안 자료가 바뀌었습니다. 잠시 후 다시 시도해 주세요.") }
        try Self.synchronizeDirectories(in: destination)
        let saved = try fingerprints([destination])
        let manifest: [String: Any] = ["format": "bandal-profile-backup", "version": 1, "sources": sources.map(\.path), "files": saved.map { ["path": String($0.path.dropFirst(destination.path.count + 1)), "sha256": $0.sha256, "bytes": $0.bytes] }]
        try Self.writeDurably(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), to: destination.appendingPathComponent("manifest.json"))
        try verifyBackup(at: destination)
        let exported: URL?
        if let exportDirectory { exported = try await exportDirectory(destination) }
        else {
            guard let presenter, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 창을 닫은 뒤 백업을 저장해 주세요.") }
            let picker = UIDocumentPickerViewController(forExporting: [destination], asCopy: true)
            picker.delegate = self
            exported = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                pickerContinuation = continuation; presenter.present(picker, animated: true)
            }
        }
        guard let exported else { return ["ok": false, "cancelled": true] }
        try Self.writeDurably(JSONEncoder().encode(BackupReceipt(directory: destination.path, sources: sources.map(\.path), fingerprints: before)), to: backupReceiptURL)
        complete = true
        return ["ok": true, "cancelled": false, "path": exported.path]
    }
    private func verifyBackup(at directory: URL) throws {
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any],
              manifest["format"] as? String == "bandal-profile-backup", let entries = manifest["files"] as? [[String: Any]] else { throw DesktopRuntimeError("백업 기록을 확인하지 못했습니다.") }
        for entry in entries {
            guard let path = entry["path"] as? String, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), let sha = entry["sha256"] as? String, let bytes = entry["bytes"] as? NSNumber else { throw DesktopRuntimeError("백업 파일 위치를 확인하지 못했습니다.") }
            let file = directory.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw DesktopRuntimeError("백업 파일 위치가 바뀌었습니다.") }
            let actual = try AssetHasher.revision(of: file, contentType: "application/octet-stream")
            guard actual.sha256 == sha, actual.byteCount == bytes.int64Value else { throw DesktopRuntimeError("백업 파일 검증에 실패했습니다.") }
        }
    }
    private static func synchronizeDirectories(in root: URL) throws {
        var directories = [root, root.deletingLastPathComponent()]
        if let children = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in children where try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.append(url) }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let fd = open(directory.path, O_RDONLY)
            guard fd >= 0 else { throw DesktopRuntimeError("백업 폴더를 저장하지 못했습니다.") }
            let result = fsync(fd); close(fd)
            guard result == 0 else { throw DesktopRuntimeError("백업 폴더 저장을 확인하지 못했습니다.") }
        }
    }
    static func snapshotDatabase(_ source: URL, to target: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let input else { if let input { sqlite3_close(input) }; throw DesktopRuntimeError("백업 저장소를 열지 못했습니다.") }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(target.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let output else { if let output { sqlite3_close(output) }; throw DesktopRuntimeError("백업 저장소를 만들지 못했습니다.") }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw DesktopRuntimeError("저장소 백업을 시작하지 못했습니다.") }
        let step = sqlite3_backup_step(backup, -1), finished = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finished == SQLITE_OK, sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw DesktopRuntimeError("저장소가 사용 중입니다. 잠시 후 백업을 다시 시도해 주세요.") }
    }
    static func writeDurably(_ data: Data, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, target.path) == 0 else { throw DesktopRuntimeError("프로필 상태를 저장하지 못했습니다.") }
        let fd = open(target.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw DesktopRuntimeError("프로필 저장을 확인하지 못했습니다.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DesktopRuntimeError("프로필 저장을 확인하지 못했습니다.") }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { let pending = pickerContinuation; pickerContinuation = nil; pending?.resume(returning: urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { let pending = pickerContinuation; pickerContinuation = nil; pending?.resume(returning: nil) }
}
