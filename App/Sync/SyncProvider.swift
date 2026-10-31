import Foundation

/// A sync root holding spec files (design §1.2). Paths are spec paths under the root. Files
/// are never removed: a removal is a tombstone in the log.
protocol SyncProvider: AnyObject {
    /// Every file in the root, with a version that changes whenever its bytes do.
    func list() async throws -> [String: SyncRemoteFile]
    /// Bytes of a file that is on this device now; throws while it is still downloading.
    func read(_ path: String) throws -> Data
    /// Creates or replaces a file of this device. The bytes are finished outside the root first.
    func write(_ content: SyncOutbox.Content, to path: String) async throws
    /// Yields when the root may have changed elsewhere.
    var changes: AsyncStream<Void> { get }
}

struct SyncRemoteFile: Equatable {
    let version: String
    /// On this device and readable now.
    let local: Bool
}

/// A folder as the root: the tests' cloud, and the file handling under `ICloudProvider`.
/// Unchecked: its own state never changes; a subclass keeps its state on one queue.
class FolderProvider: SyncProvider, @unchecked Sendable {
    let root: URL
    let changes: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation

    init(root: URL) {
        self.root = root
        (changes, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func list() async throws -> [String: SyncRemoteFile] { try scan() }

    private func scan() throws -> [String: SyncRemoteFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let base = Self.unprefixed(root.path) + "/"
        var files: [String: SyncRemoteFile] = [:]
        guard FileManager.default.fileExists(atPath: root.path) else { return files }
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) ?? .init() {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = Self.unprefixed(url.path)
            guard values.isRegularFile == true, path.hasPrefix(base) else { continue }
            files[String(path.dropFirst(base.count))] = SyncRemoteFile(version: "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)", local: true)
        }
        return files
    }

    /// `/private/var/…` and `/var/…` name the same place; a path is compared without the prefix.
    /// (`resolvingSymlinksInPath` drops it only for files that exist, not for iCloud placeholders.)
    static func unprefixed(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }

    func read(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    func write(_ content: SyncOutbox.Content, to path: String) async throws {
        let target = try url(path), temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bandal-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        switch content {
        case .data(let data): try data.write(to: temporary)
        case .file(let file):
            try FileManager.default.copyItem(at: file, to: temporary)
            // A PDF or asset is named by its hash and never written again under that name, so bytes
            // that changed after they were hashed must not go out under it.
            if SyncFormat.isBlob(path), SyncFormat.sha256(try Data(contentsOf: temporary)) != String((path as NSString).lastPathComponent.prefix(64)) {
                throw DesktopRuntimeError("\(path) changed while syncing", code: "CONFLICT")
            }
        }
        try place(temporary, at: target)
    }

    /// Finished bytes go into place in one rename, so the root never holds a partial file (design §1.5).
    func place(_ temporary: URL, at target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: target) }
    }

    func url(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw DesktopRuntimeError("Invalid sync path", code: "VALIDATION_ERROR")
        }
        return root.appendingPathComponent(path)
    }
}
