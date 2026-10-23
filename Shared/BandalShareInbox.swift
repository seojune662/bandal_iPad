import Foundation
import Darwin

/// This file is compiled into both the app and the share extension. Only inbox
/// payloads and a destination snapshot are shared; the extension never opens DBs.
struct BandalShareCatalog: Codable, Sendable {
    struct Course: Codable, Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let folders: [String]
    }
    let workspaceID: String
    let courses: [Course]
    let updatedAt: Date
}

struct BandalShareBatch: Codable, Identifiable, Sendable {
    struct Item: Codable, Identifiable, Sendable {
        let id: String
        let storedName: String
        let fileName: String
        let byteCount: Int64
    }
    let id: String
    let workspaceID: String
    let courseID: String
    let folderPath: String
    let createdAt: Date
    let items: [Item]
}

struct BandalShareInbox: Sendable {
    static let appGroup = "group.app.bandal.ipad"
    static let maximumItems = 20
    static let maximumFileBytes: Int64 = 100 * 1024 * 1024
    static let maximumBatchBytes: Int64 = 250 * 1024 * 1024
    static let maximumQueuedBytes: Int64 = 500 * 1024 * 1024
    let root: URL
    private var files: FileManager { .default }

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func connected() -> BandalShareInbox? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return BandalShareInbox(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    func readCatalog() throws -> BandalShareCatalog {
        try JSONDecoder().decode(BandalShareCatalog.self, from: Data(contentsOf: root.appendingPathComponent("destinations.json")))
    }

    func publishCatalog(_ catalog: BandalShareCatalog) throws {
        try prepare()
        // Read the shared snapshot rather than trusting a scene-local cache:
        // another window/profile can publish while this scene is inactive.
        if let existing = try? readCatalog(), existing.workspaceID == catalog.workspaceID, existing.courses == catalog.courses { return }
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("destinations.json"), options: .atomic)
    }

    func beginBatch(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw Failure(message: "잘못된 공유 식별자입니다.") }
        try prepare()
        let directory = root.appendingPathComponent(".staging-" + id, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func stageFile(_ source: URL, name: String, in directory: URL) throws -> BandalShareBatch.Item {
        let accessible = source.startAccessingSecurityScopedResource()
        defer { if accessible { source.stopAccessingSecurityScopedResource() } }
        var result: Result<BandalShareBatch.Item, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                let attributes = try files.attributesOfItem(atPath: readable.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumFileBytes else {
                    throw Failure(message: "파일은 한 개당 100MB까지 공유할 수 있습니다.")
                }
                let itemID = UUID().uuidString.lowercased()
                let target = directory.appendingPathComponent(itemID)
                try files.copyItem(at: readable, to: target)
                let copiedSize = (try files.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard copiedSize == size.int64Value, copiedSize >= 0, copiedSize <= Self.maximumFileBytes else {
                    try? files.removeItem(at: target)
                    throw Failure(message: "복사 중 파일이 변경되었습니다. 다시 공유해 주세요.")
                }
                return BandalShareBatch.Item(id: itemID, storedName: itemID, fileName: Self.safeFileName(name), byteCount: copiedSize)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure(message: "공유 파일에 접근할 수 없습니다.") }
        return try result.get()
    }

    func stageText(_ text: String, name: String, in directory: URL) throws -> BandalShareBatch.Item {
        let bytes = Data(text.utf8)
        guard bytes.count <= 5 * 1024 * 1024 else { throw Failure(message: "공유 텍스트는 5MB까지 저장할 수 있습니다.") }
        let id = UUID().uuidString.lowercased()
        try bytes.write(to: directory.appendingPathComponent(id), options: .atomic)
        return BandalShareBatch.Item(id: id, storedName: id, fileName: Self.safeFileName(name), byteCount: Int64(bytes.count))
    }

    /// The manifest and every payload become visible together by one rename.
    func commit(_ batch: BandalShareBatch, staging: URL) throws {
        try validate(batch)
        guard staging.standardizedFileURL == root.appendingPathComponent(".staging-" + batch.id).standardizedFileURL else {
            throw Failure(message: "잘못된 공유 임시 경로입니다.")
        }
        for item in batch.items { _ = try payloadURL(item, in: staging) }
        try JSONEncoder().encode(batch).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try withQueueLock {
            let queued = try batches().reduce(Int64(0)) { $0 + $1.items.reduce(Int64(0)) { $0 + $1.byteCount } }
            guard queued + batch.items.reduce(Int64(0), { $0 + $1.byteCount }) <= Self.maximumQueuedBytes else {
                throw Failure(message: "반달을 열어 대기 중인 공유 자료를 먼저 가져와 주세요.")
            }
            try files.moveItem(at: staging, to: root.appendingPathComponent(batch.id, isDirectory: true))
        }
    }

    func batches() throws -> [BandalShareBatch] {
        try prepare()
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { directory in
                let batch = try JSONDecoder().decode(BandalShareBatch.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                try validate(batch)
                guard batch.id == directory.lastPathComponent else { throw Failure(message: "공유 자료 식별자가 일치하지 않습니다.") }
                return batch
            }.sorted { $0.createdAt < $1.createdAt }
    }

    func payloadURL(_ item: BandalShareBatch.Item, batchID: String) throws -> URL {
        guard UUID(uuidString: batchID) != nil else { throw Failure(message: "잘못된 공유 식별자입니다.") }
        return try payloadURL(item, in: root.appendingPathComponent(batchID, isDirectory: true))
    }

    func removeCompleted(_ batch: BandalShareBatch) throws {
        try retireCompleted(batch)
        // Cleanup may be interrupted. A tombstone is already outside the queue,
        // so a partial recursive removal can never block another batch.
        try cleanupOwnedDirectories()
    }

    func retireCompleted(_ batch: BandalShareBatch) throws {
        try validate(batch)
        try withQueueLock {
            let source = root.appendingPathComponent(batch.id, isDirectory: true)
            let completed = root.appendingPathComponent(".completed-" + batch.id, isDirectory: true)
            if files.fileExists(atPath: source.path) {
                try files.moveItem(at: source, to: completed)
                let descriptor = Darwin.open(root.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(descriptor) }
                guard fsync(descriptor) == 0 || errno == EINVAL else { throw POSIXError(.EIO) }
            }
        }
    }

    static func safeFileName(_ input: String) -> String {
        let clean = input.replacingOccurrences(of: #"[/\\:*?\"<>|\x00-\x1f]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return "공유 자료.md" }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        return String(stem.prefix(90)) + (ext.isEmpty ? "" : "." + String(ext.prefix(16)))
    }

    static func validRelativeFolder(_ path: String) -> Bool {
        path.isEmpty || (!path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") })
    }

    private func validate(_ batch: BandalShareBatch) throws {
        guard UUID(uuidString: batch.id) != nil, UUID(uuidString: batch.workspaceID) != nil,
              UUID(uuidString: batch.courseID) != nil, Self.validRelativeFolder(batch.folderPath),
              !batch.items.isEmpty, batch.items.count <= Self.maximumItems,
              Set(batch.items.map(\.id)).count == batch.items.count,
              batch.items.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.storedName == $0.id && $0.fileName == Self.safeFileName($0.fileName) && $0.byteCount >= 0 && $0.byteCount <= Self.maximumFileBytes }),
              batch.items.reduce(Int64(0), { $0 + $1.byteCount }) <= Self.maximumBatchBytes else {
            throw Failure(message: "공유 자료 형식이 잘못되었거나 한도(20개, 총 250MB)를 넘었습니다.")
        }
    }

    private func payloadURL(_ item: BandalShareBatch.Item, in directory: URL) throws -> URL {
        guard UUID(uuidString: item.id) != nil, item.storedName == item.id else { throw Failure(message: "잘못된 공유 파일 경로입니다.") }
        let file = directory.appendingPathComponent(item.storedName)
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { throw Failure(message: "공유 파일의 연결 경로는 허용하지 않습니다.") }
        let attributes = try files.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == item.byteCount else { throw Failure(message: "공유 파일이 없거나 변경되었습니다.") }
        return file
    }

    private func prepare() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try cleanupOwnedDirectories()
    }

    /// Only UUID-named directories owned by this queue are eligible. Published
    /// batches are never expired. Uncommitted staging is left alone for 24 hours
    /// so a running extension cannot race a foreground app's cleanup.
    private func cleanupOwnedDirectories(now: Date = Date()) throws {
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let completed = name.hasPrefix(".completed-")
            let staging = name.hasPrefix(".staging-")
            guard completed || staging,
                  UUID(uuidString: String(name.dropFirst(completed ? 11 : 9))) != nil,
                  let attributes = try? files.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            if staging {
                guard let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            }
            // Another process may already be removing the same completed batch.
            // Failure preserves it for the next pass without poisoning the inbox.
            try? files.removeItem(at: url)
        }
    }
    private func withQueueLock<T>(_ operation: () throws -> T) throws -> T {
        try prepare()
        let descriptor = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
