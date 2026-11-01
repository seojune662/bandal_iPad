import Foundation

/// Settings › 동기화 and the engine's life (design §4): sync on or off for this profile, joining a
/// root that already holds data (merge, overwrite, or a new profile that takes the cloud's data),
/// and a pause when the iCloud account changes or the root disappears. Login, subscription and
/// sync stay independent: nothing here asks for either.
@MainActor
final class CloudSyncService {
    static let channels: Set<String> = ["cloudSync:status", "cloudSync:preview", "cloudSync:connect", "cloudSync:disconnect", "cloudSync:syncNow",
                                        "cloudSync:setDeviceName", "cloudSync:recreateRoot", "cloudSync:returnToPrevious"]
    private weak var store: NativeWorkspaceStore?
    private let runtime: DesktopRuntime, profile: DesktopProfileService
    private var engine: CloudSyncEngine?, identityObserver: NSObjectProtocol?, starting = false, startAgain = false
    /// What is shown while no engine runs: off, signed out, another account.
    private var idle: [String: Any] = ["phase": "off"]

    /// iCloud by default; tests give a folder, an account and their own keychain.
    struct Environment {
        /// The root, or nil while signed out, and the signed-in account. May block: called off the main thread.
        var locate: @Sendable () -> (URL?, String) = { (ICloudProvider.locate(), ICloudProvider.identity()?.base64EncodedString() ?? "") }
        var provider: (URL) -> SyncProvider = { ICloudProvider(root: $0) }
        var keychain = SyncStore.Keychain.live
    }
    var environment = Environment()

    init(store: NativeWorkspaceStore, profile: DesktopProfileService) {
        self.store = store
        runtime = store.runtime
        self.profile = profile
    }

    func handle(_ channel: String, _ request: [String: Any]) async throws -> Any {
        switch channel {
        case "cloudSync:preview": return try await preview()
        case "cloudSync:connect": try await connect(request)
        case "cloudSync:disconnect": try await disconnect()
        case "cloudSync:syncNow": try await store?.flushDocuments(); await engine?.syncNow()
        case "cloudSync:setDeviceName": try await setDeviceName(request["name"])
        case "cloudSync:recreateRoot": try await engine?.recreateRoot()
        case "cloudSync:returnToPrevious":
            // What this profile changed goes out before it is left.
            try await store?.flushDocuments(); await engine?.syncNow()
            try await disconnect()
            return try await profile.returnToPrevious()
        default: break
        }
        return try await status()
    }

    /// Starts sync when this profile has it on. A profile made by 가져오기 connects on its first start;
    /// `-BandalCloudSync icloud|off` at launch also turns it on or off (device testing).
    func start() async {
        // One start at a time; an account change during one starts once more after it.
        guard !starting else { startAgain = true; return }
        starting = true
        defer { starting = false }
        repeat {
            startAgain = false
            await engine?.stop(); engine = nil
            await startOnce()
        } while startAgain
    }

    private func startOnce() async {
        let handoff = runtime.root.appendingPathComponent(DesktopProfileService.syncConnect)
        var requested = UserDefaults.standard.string(forKey: "BandalCloudSync")
        if requested == nil, let data = try? Data(contentsOf: handoff) { requested = (try? JSONDecoder().decode([String: String].self, from: data))?["provider"] }
        do {
            let provider = try await runtime.withSyncStorage { context, _ -> String? in
                if let requested { try SyncStore(context: context).setProvider(requested == "icloud" ? "icloud" : nil) }
                return try SyncStore.provider(context)
            }
            try? FileManager.default.removeItem(at: handoff)
            guard provider == "icloud" else { return publish(["phase": "off"]) }
            observeIdentity()
            let (root, account) = await locate()
            guard let root else { return publish(["phase": "paused", "reason": "signed-out"]) }
            let known = try await runtime.withSyncStorage { context, _ in try SyncStore(context: context).value("icloud_account") }
            if known == nil { try await runtime.withSyncStorage { context, _ in try SyncStore(context: context).set("icloud_account", account) } }
            // Another Apple ID holds another root: it is joined only through the connection sheet (design §4.4).
            else if known != account { return publish(["phase": "paused", "reason": "account-changed"]) }
            // Turned off while this start was waiting: stay off.
            guard try await runtime.withSyncStorage({ context, _ in try SyncStore.provider(context) }) == "icloud" else { return publish(["phase": "off"]) }
            try await run(environment.provider(root))
        } catch { publish(["phase": "error", "message": error.localizedDescription]) }
    }

    func suspend() async { await engine?.suspend() }
    func resume() { engine?.resume() }

    // MARK: Connection (design §4.2)

    /// What the root and this iPad hold, read before anything is written.
    private func preview() async throws -> [String: Any] {
        let (root, account) = await locate()
        guard let root else { return ["available": false] }
        let files: [String: SyncRemoteFile], state: SyncMerge.State
        switch try await peek(root) {
        case .downloading(let count): return ["available": true, "downloading": count]
        case .ready(let listing, let merged): (files, state) = (listing, merged)
        }
        let empty = !files.keys.contains(where: SyncFormat.isSpecFile)
        if let blocked = state.blocked, !empty { return ["available": true, "blocked": blocked.rawValue] }
        var result = try await runtime.withSyncStorage { context, library in
            let store = try SyncStore(context: context)
            // Joining another Apple ID's root forgets what was matched with the old one (see connect).
            let forgetting = try store.value("icloud_account").map { $0 != account } ?? false
            return try SyncConnection.preview(state, files: files, forgetting: forgetting, context: context, library: library)
        }
        result["available"] = true; result["empty"] = empty
        return result
    }

    /// `mode`: start (an empty root), merge, overwrite, or import (a new profile takes the cloud's data).
    private func connect(_ request: [String: Any]) async throws {
        let mode = request["mode"] as? String ?? "start"
        if mode == "import" {
            try await store?.flushDocuments(); await engine?.syncNow()
            let wasOn = engine != nil
            try await disconnect()
            do { _ = try await profile.newProfileForSync(provider: "icloud") } catch {
                // The switch did not happen: this profile goes on as it was.
                if wasOn { _ = try? await runtime.withSyncStorage { context, _ in try SyncStore(context: context).setProvider("icloud") }; await start() }
                throw error
            }
            return
        }
        guard let connection = SyncConnection.Mode(rawValue: mode) else { throw DesktopRuntimeError("연결 방법을 확인해 주세요.", code: "VALIDATION_ERROR") }
        let pairs = (request["pairs"] as? [[String: Any]] ?? []).compactMap { pair -> (local: String, remote: String)? in
            guard let local = pair["local"] as? String, let remote = pair["remote"] as? String else { return nil }
            return (local, remote)
        }
        let (root, account) = await locate()
        guard let root else { throw DesktopRuntimeError("iCloud에 로그인하고 iCloud Drive를 켜야 합니다.", code: "SYNC_SIGNED_OUT") }
        guard case .ready(let files, let state) = try await peek(root) else {
            throw DesktopRuntimeError("iCloud에서 반달 폴더를 아직 내려받고 있어요. 잠시 뒤 다시 시도해 주세요.", code: "SYNC_NOT_READY")
        }
        let empty = !files.keys.contains(where: SyncFormat.isSpecFile)
        if state.blocked != nil, !empty { throw DesktopRuntimeError("이 반달 폴더는 새 버전의 반달이 만들었어요. 앱을 업데이트해 주세요.", code: "SYNC_UPDATE_REQUIRED") }
        // What the user agreed to must still be what is there.
        if connection == .start, !empty { throw DesktopRuntimeError("클라우드에 반달 자료가 생겼어요. 다시 확인해 주세요.", code: "SYNC_ROOT_CHANGED") }
        if connection == .overwrite, request["fingerprint"] as? String != SyncConnection.fingerprint(files) {
            throw DesktopRuntimeError("클라우드 자료가 바뀌었어요. 지워질 자료를 다시 확인해 주세요.", code: "SYNC_ROOT_CHANGED")
        }
        await engine?.stop(); engine = nil
        try await runtime.withSyncStorage { context, library in
            let store = try SyncStore(context: context)
            // All or nothing: a connection that fails leaves the earlier one as it was.
            try context.transaction {
                // Another Apple ID is another root: what was exchanged with the old one says nothing about it.
                if let known = try store.value("icloud_account"), known != account { try store.forgetRoot() }
                if empty { try context.run("DELETE FROM cloud_sync_state WHERE key IN ('pending_deletes','export_first')") }
                else { try SyncConnection.connect(connection, pairs: pairs, state: state, store: store, library: library) }
                try store.set("icloud_account", account)
                try store.setProvider("icloud")
            }
        }
        observeIdentity()
        try await run(environment.provider(root))
    }

    private func disconnect() async throws {
        await engine?.stop(); engine = nil
        let runtime = runtime
        try await runtime.withSyncStorage { context, _ in
            runtime.onLocalChange = nil
            guard try context.tableExists("cloud_sync_state") else { return }
            // An overwrite that did not go out yet is dropped with the connection (review HIGH).
            try context.run("DELETE FROM cloud_sync_state WHERE key IN ('pending_deletes','export_first')")
            try SyncStore(context: context).setProvider(nil)
        }
        publish(["phase": "off"])
    }

    private func setDeviceName(_ value: Any?) async throws {
        let name = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains("/") else { throw DesktopRuntimeError("기기 이름은 1–40자로, /는 쓸 수 없어요.", code: "VALIDATION_ERROR") }
        try await runtime.withSyncStorage { context, _ in try SyncStore(context: context).set("device_label", name) }
        engine?.requestSync()
    }

    private func status() async throws -> [String: Any] {
        let stored = try await runtime.withSyncStorage { context, _ -> [String: Any] in
            guard try context.tableExists("cloud_sync_state") else { return [:] }
            let store = try SyncStore(context: context)
            var values: [String: Any] = ["deviceName": try store.value("device_label") ?? "iPad"]
            if let provider = try SyncStore.provider(context) { values["provider"] = provider }
            if let last = try store.value("last_success_at").flatMap({ Int64($0) }) { values["lastSuccessAt"] = last }
            return values
        }
        var result = stored.merging(engine?.status ?? idle) { _, current in current }
        result["previousProfile"] = profile.previous != nil
        return result
    }

    // MARK: Engine

    private func run(_ provider: SyncProvider) async throws {
        let engine = CloudSyncEngine(runtime: runtime, provider: provider, keychain: environment.keychain)
        engine.mutateOpenDocuments = { [weak store] action in
            guard let store else { throw CancellationError() }
            return try await store.withExternalMutation(action)
        }
        engine.openDocuments = { [weak store] in store?.openDocuments }
        engine.emit = { [weak runtime] channel, value in runtime?.onEmit?(channel, value) }
        let runtime = runtime
        // Read on the storage queue, so it is set there too.
        try await runtime.withSyncStorage { _, _ in runtime.onLocalChange = { [weak engine] in Task { @MainActor in engine?.localChanged() } } }
        self.engine = engine
        engine.start()
    }

    /// Signing out or into another Apple ID pauses sync until it is checked again (design §4.4).
    private func observeIdentity() {
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.start() }
        }
    }

    private func publish(_ state: [String: Any]) {
        idle = state
        runtime.onEmit?("runtime:cloudSyncChanged", state)
    }

    private enum Peek { case downloading(Int), ready([String: SyncRemoteFile], SyncMerge.State) }

    private func peek(_ root: URL) async throws -> Peek {
        let peek = try await CloudSyncEngine.peek(environment.provider(root))
        guard let state = peek.state else { return .downloading(peek.downloading) }
        return .ready(peek.files, state)
    }

    private func locate() async -> (URL?, String) {
        let locate = environment.locate
        return await Task.detached { locate() }.value
    }
}
