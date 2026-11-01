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
        let empty = !files.keys.contains(where: SyncFormat.isSpecFile)
        // An empty root is started here; a root of any other format is never written (spec "원격 입력 검증").
        if let blocked = state.blocked, !(blocked == .missingRoot && empty) { return publish("paused", ["reason": blocked.rawValue]) }
        let (me, session) = (try await storage { store, _, _ in try store.deviceID() }, newSession)
        let flags = try await storage { store, _, _ in (exportFirst: try store.value("export_first") != nil, rootSeen: try store.value("root_seen") != nil, name: try store.value("device_label") ?? "iPad") }
        // This iPad's devices file stays in a root it wrote to. Once seen, its absence means the folder
        // was removed or replaced (Files app, another device): not every document deleted, and not a
        // root that holds what this iPad sent. It is filled again only when the user says so (design §4.4).
        let mine = files["devices/\(me).json"] != nil
        if flags.rootSeen, !mine { return publish("paused", ["reason": "root-missing"]) }
        // Other devices' files, and PDFs or assets arriving or finishing their download, are applied
        // in full. This device's own log and notes can only add conflict copies and renames, so a
        // change there applies documents without ink.
        let remote = files.filter { !Self.own($0.key, me) }.mapValues { "\($0.version):\($0.local)" }
        let own = files.filter { Self.own($0.key, me) && !$0.key.hasPrefix("ink/") }.mapValues(\.version)
        let full = remote != appliedRemote || retryAt.map { Date() >= $0 } == true
        var skipped = 0, waiting: String?
        // After an overwrite the first export goes out before anything is applied (design §4.2).
        if !flags.exportFirst, full || own != appliedOwn {
            do {
                let report = try await apply(state, ink: full)
                skipped = report.skipped.count
                retryAt = report.skipped.isEmpty ? nil : Date().addingTimeInterval(60)
            } catch {
                // An editor that cannot save now (a note in conflict) holds back the change to its
                // document only; this device's own changes still go out below.
                waiting = error.localizedDescription
                retryAt = Date().addingTimeInterval(60)
                publish("waiting", ["message": error.localizedDescription])
            }
            if full { appliedRemote = remote }
            appliedOwn = own
        }
        let batch = try await storage { store, library, _ in
            let outbox = SyncOutbox(store: store, library: library)
            outbox.deviceName = flags.name
            if session { try outbox.endSession() }
            return try outbox.prepare(remote: Set(files.keys))
        }
        newSession = newSession && !session
        if !batch.writes.isEmpty { publish("syncing", ["remaining": batch.writes.count]) }
        for write in batch.writes { try await provider.write(write.content, to: write.path) }
        let finished = Int64(Date().timeIntervalSince1970 * 1000)
        try await storage { store, library, _ in
            try SyncOutbox(store: store, library: library).commit(batch)
            if mine { try store.set("root_seen", "1") }
            try store.set("last_success_at", String(finished))
        }
        if let waiting { return publish("waiting", ["message": waiting]) }
        // iCloud uploads in the background after a write; what has not gone up yet is shown apart (design §4.5).
        publish("idle", ["lastSuccessAt": finished, "uploads": files.values.filter { !$0.uploaded }.count, "skipped": skipped + batch.skipped.count])
    }

    /// The removed root is filled again with everything this iPad holds (design §4.4). A root that
    /// holds this iPad's files again (restored from Recently Deleted) just resumes.
    func recreateRoot() async throws {
        let me = try await storage { store, _, _ in try store.deviceID() }
        if try await provider.list()["devices/\(me).json"] == nil { try await storage { store, _, _ in try store.resetExchange() } }
        (listing, state, appliedRemote, appliedOwn, retryAt, cache) = (nil, nil, nil, nil, nil, [:])
        await syncNow()
    }

    /// The root as it is now, for the connection sheet; no state while a text file is still downloading.
    nonisolated static func peek(_ provider: SyncProvider) async throws -> (files: [String: SyncRemoteFile], state: SyncMerge.State?, downloading: Int) {
        let files = try await provider.list(), result = await read(files, cache: [:], provider: provider)
        return (files, result.state, result.downloading)
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
