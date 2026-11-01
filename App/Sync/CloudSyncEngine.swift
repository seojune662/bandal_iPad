import Foundation
import UIKit

/// The spec v2 sync loop (design §1): list the root, read the files that changed, merge,
/// apply what other devices wrote, then write this device's changes. One cycle runs at a
/// time; a request during a cycle runs one more after it.
@MainActor
final class CloudSyncEngine {
    var emit: ((String, Any) -> Void)?
    /// Runs apply inside the workspace barrier: open editors save first, and those whose
    /// documents changed reopen from the store (design §2.8).
    var mutateOpenDocuments: ((@escaping @MainActor () async throws -> Any) async throws -> Any)?
    /// Documents open in an editor, as `course\0path`; nil when an editor does not say.
    var openDocuments: (() -> Set<String>?)?
    var deviceName = "iPad"
    private(set) var status: [String: Any] = ["phase": "idle"]

    let provider: SyncProvider
    private let runtime: DesktopRuntime, keychain: SyncStore.Keychain
    typealias Cache = [String: (version: String, bytes: Data)]
    private var cache: Cache = [:]
    /// The listing the merged state was read from; an unchanged listing reuses it.
    private var listing: [String: SyncRemoteFile]?, state: SyncMerge.State?
    /// What the last apply saw: other devices' files and every PDF or asset (with whether it is
    /// downloaded), and this device's own log and notes.
    private var appliedRemote: [String: String]?, appliedOwn: [String: String]?
    /// Something could not be applied: try again at this time even if nothing changes.
    private var retryAt: Date?
    private var running: Task<Void, Never>?, again = false, suspended = false, newSession = true
    private var idle: Task<Void, Never>?, listening: Task<Void, Never>?
    private var timer: Timer?, observers: [NSObjectProtocol] = []

    init(runtime: DesktopRuntime, provider: SyncProvider, keychain: SyncStore.Keychain = .live) {
        self.runtime = runtime
        self.provider = provider
        self.keychain = keychain
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestSync() } }
        // A session runs from the app coming to the foreground until it leaves (design §1.8).
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.newSession = true; self?.requestSync() }
        })
        let changes = provider.changes
        listening = Task { [weak self] in for await _ in changes { self?.requestSync() } }
        requestSync()
    }

    func stop() async {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        listening?.cancel(); idle?.cancel()
        suspended = true
        await running?.value
    }

    /// A local write: sync once nothing else was written for 1.5 s (design §1.6).
    func localChanged() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.requestSync()
        }
    }

    func requestSync() {
        guard !suspended else { return }
        guard running == nil else { again = true; return }
        running = Task { [weak self] in
            while let self, !self.suspended {
                self.again = false
                await self.cycleReportingErrors()
                guard self.again else { break }
            }
            self?.running = nil
        }
    }

    /// One cycle now, after the one in flight.
    func syncNow() async {
        requestSync()
        await running?.value
    }

    func suspend() async { suspended = true; await running?.value }
    func resume() { suspended = false; requestSync() }

    private func cycleReportingErrors() async {
        do { try await cycle() }
        catch { publish("error", ["message": error.localizedDescription]) }
    }

    private func cycle() async throws {
        let files = try await provider.list()
        if files != listing {
            let read = await Self.read(files, cache: cache, provider: provider)
            cache = read.cache
            // Until every spec file is here, nothing is applied or written.
            guard let merged = read.state else { listing = nil; return publish("downloading", ["remaining": read.downloading]) }
            // Every t written after this passes every t in the root (spec "식별자와 시간").
            try await storage { store, library, read in try SyncApply(store: store, library: library, read: read).observeClock(merged) }
            (listing, state) = (files, merged)
        }
        guard let state else { return }
        // An empty root is started here; a root of any other format is never written (spec "원격 입력 검증").
        if let blocked = state.blocked, !(blocked == .missingRoot && !files.keys.contains(where: SyncFormat.isSpecFile)) {
            return publish("paused", ["reason": blocked.rawValue])
        }
        let (me, session) = (try await storage { store, _, _ in try store.deviceID() }, newSession)
        // Other devices' files, and PDFs or assets arriving or finishing their download, are applied
        // in full. This device's own log and notes can only add conflict copies and renames, so a
        // change there applies documents without ink.
        let remote = files.filter { !Self.own($0.key, me) }.mapValues { "\($0.version):\($0.local)" }
        let own = files.filter { Self.own($0.key, me) && !$0.key.hasPrefix("ink/") }.mapValues(\.version)
        let full = remote != appliedRemote || retryAt.map { Date() >= $0 } == true
        var skipped = 0, waiting = false
        if full || own != appliedOwn {
            do {
                let report = try await apply(state, ink: full)
                skipped = report.skipped.count
                retryAt = report.skipped.isEmpty ? nil : Date().addingTimeInterval(60)
            } catch {
                // An editor that cannot save now (a note in conflict) holds back the change to its
                // document only; this device's own changes still go out below.
                waiting = true
                retryAt = Date().addingTimeInterval(60)
                publish("waiting", ["message": error.localizedDescription])
            }
            if full { appliedRemote = remote }
            appliedOwn = own
        }
        let name = deviceName
        let batch = try await storage { store, library, _ in
            let outbox = SyncOutbox(store: store, library: library)
            outbox.deviceName = name
            if session { try outbox.endSession() }
            return try outbox.prepare(remote: Set(files.keys))
        }
        newSession = newSession && !session
        for write in batch.writes { try await provider.write(write.content, to: write.path) }
        try await storage { store, library, _ in try SyncOutbox(store: store, library: library).commit(batch) }
        if !waiting { publish("idle", ["lastSuccessAt": Date().timeIntervalSince1970 * 1000, "skipped": skipped + batch.skipped.count]) }
    }

    /// Reading and merging the root is the heavy part of a cycle, so it runs off the main actor and
    /// only after the listing changed. Text files are read again only when their version changed;
    /// a PDF or asset counts as there once it is downloaded (the merge holds what needs it till then).
    private nonisolated static func read(_ files: [String: SyncRemoteFile], cache: Cache, provider: SyncProvider) async -> (state: SyncMerge.State?, cache: Cache, downloading: Int) {
        var texts: [(path: String, bytes: Data)] = [], next: Cache = [:], downloading = 0
        for (path, file) in files where SyncFormat.isSpecFile(path) && !SyncFormat.isBlob(path) {
            if let cached = cache[path], cached.version == file.version { texts.append((path, cached.bytes)); next[path] = cached; continue }
            guard file.local, let bytes = try? provider.read(path) else { downloading += 1; continue }
            next[path] = (file.version, bytes); texts.append((path, bytes))
        }
        guard downloading == 0 else { return (nil, next, downloading) }
        let present = files.filter { SyncFormat.isBlob($0.key) && $0.value.local }.map(\.key)
        return (SyncMerge.merge(SyncFormat.readRoot(texts, present: present).files), next, 0)
    }

    private static func own(_ path: String, _ me: String) -> Bool {
        SyncFormat.writer(of: path)?.device == me || path == "devices/\(me).json"
    }

    /// Everything but changes to open documents goes in at once and the library is told to
    /// refresh. Only when an open document changed does apply run again inside the workspace
    /// barrier, so typing in one note is not interrupted by changes elsewhere.
    private func apply(_ state: SyncMerge.State, ink: Bool) async throws -> SyncApply.Report {
        func pass(_ open: Set<String>?) async throws -> SyncApply.Report {
            try await storage { store, library, read in
                let apply = SyncApply(store: store, library: library, read: read)
                apply.open = open; apply.includesInk = ink
                return try apply.apply(state)
            }
        }
        var report = try await pass(openDocuments.map { $0() } ?? [])
        if !report.courses.isEmpty { emit?("courses:changed", [:]) }
        for course in report.files.keys.sorted() { emit?("materials:changed", ["courseId": course]) }
        guard report.held else { return report }
        let action: @MainActor () async throws -> Any = {
            report = try await pass([])
            return report.workspaceChanges
        }
        if let mutateOpenDocuments { _ = try await mutateOpenDocuments(action) } else { _ = try await action() }
        return report
    }

    /// Sync state lives in bandal.db, on the storage queue like every repository.
    private func storage<T>(_ work: @escaping (SyncStore, NativeLibraryRepository, @escaping (String) throws -> Data) throws -> T) async throws -> T {
        let keychain = keychain, provider = provider
        return try await runtime.withSyncStorage { context, library in
            try work(SyncStore(context: context, keychain: keychain), library, provider.read)
        }
    }

    private func publish(_ phase: String, _ details: [String: Any] = [:]) {
        status = details.merging(["phase": phase]) { $1 }
        emit?("runtime:cloudSyncChanged", status)
    }
}
