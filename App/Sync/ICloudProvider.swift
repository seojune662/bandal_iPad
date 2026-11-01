import Foundation

/// iCloud Drive › 반달 (design §1.3): the folder provider with file coordination, a metadata
/// query for the listing and its change signals, and a download asked for every file not here.
final class ICloudProvider: FolderProvider, @unchecked Sendable {
    static let container = "iCloud.app.bandal"

    /// The root, or nil while iCloud is signed out or iCloud Drive is off for this app.
    /// It may block, so it is called off the main thread.
    static func locate() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: container)?.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The signed-in account, archived so that another Apple ID is noticed across launches (design §4.4).
    /// Only compared, never unarchived. ponytail: byte comparison of the archive; verify on a device
    /// that one account archives the same across launches.
    static func identity() -> Data? {
        FileManager.default.ubiquityIdentityToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
    }

    private static let notReady = DesktopRuntimeError("iCloud has not listed the 반달 folder yet.", code: "SYNC_NOT_READY")
    private let query = NSMetadataQuery(), queue = OperationQueue()
    // On `queue` only.
    private var gathered = false, failed = false, waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observers: [NSObjectProtocol] = []

    override init(root: URL) {
        super.init(root: root)
        queue.maxConcurrentOperationCount = 1
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { [weak self] _ in
            guard let self else { return }
            gathered = true
            waiting.values.forEach { $0.resume() }; waiting = [:]
            signal.yield()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: queue) { [weak self] _ in self?.signal.yield() })
        DispatchQueue.main.async { [weak self, query] in
            guard !query.start() else { return }
            self?.queue.addOperation { [weak self] in
                guard let self else { return }
                failed = true
                waiting.values.forEach { $0.resume(throwing: Self.notReady) }; waiting = [:]
            }
        }
    }

    deinit {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func list() async throws -> [String: SyncRemoteFile] {
        // Nothing is listed, so nothing is written, before the first full gathering (design §1.7).
        // A gathering that never ends fails the cycle instead of holding the engine.
        let id = UUID()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.addOperation { [self] in
                if gathered { return done.resume() }
                if failed { return done.resume(throwing: Self.notReady) }
                waiting[id] = done
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                    self?.queue.addOperation { [weak self] in self?.waiting.removeValue(forKey: id)?.resume(throwing: Self.notReady) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { done in
            queue.addOperation { [self] in
                query.disableUpdates()
                defer { query.enableUpdates() }
                let base = Self.unprefixed(root.path) + "/"
                var files: [String: SyncRemoteFile] = [:]
                for case let item as NSMetadataItem in query.results {
                    guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                          item.value(forAttribute: NSMetadataItemContentTypeKey) as? String != "public.folder" else { continue }
                    let local = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String == NSMetadataUbiquitousItemDownloadingStatusCurrent
                    // Every file of the root is kept on this iPad, as the desktop keeps its folder.
                    if !local { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                    let path = Self.unprefixed(url.path)
                    guard path.hasPrefix(base) else { continue }
                    let changed = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970 ?? 0
                    let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
                    files[String(path.dropFirst(base.count))] = SyncRemoteFile(version: "\(changed):\(size)", local: local)
                }
                // An empty listing while the folder holds files (or their placeholders) means iCloud has
                // not told this iPad what the root holds yet; taken as empty, it would start a new root.
                if files.isEmpty, let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path), !entries.isEmpty {
                    return done.resume(throwing: Self.notReady)
                }
                done.resume(returning: files)
            }
        }
    }

    /// A file still downloading is not waited for: the read fails and the caller tries again later.
    override func read(_ path: String) throws -> Data {
        let file = try url(path)
        guard (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .current else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            throw DesktopRuntimeError("\(path) is not downloaded yet", code: "SYNC_DOWNLOADING")
        }
        var coordination: NSError?, result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordination) { url in result = Result { try Data(contentsOf: url) } }
        if let coordination { throw coordination }
        return try result.get()
    }

    override func place(_ temporary: URL, at target: URL) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordination) { url in
            do { try super.place(temporary, at: url) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }
}
