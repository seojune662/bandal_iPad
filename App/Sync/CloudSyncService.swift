import Foundation

/// Settings › 동기화 and the engine's life (design §4): sync on or off for this profile, in iCloud
/// or in Google Drive, joining a root that already holds data (merge, overwrite, or a new profile
/// that takes the cloud's data), and a pause when the account changes or the root disappears.
/// Login, subscription and sync stay independent: nothing here asks for either, and the Google
/// account of Drive sync is not the 반달 login.
@MainActor
final class CloudSyncService {
    static let channels: Set<String> = ["cloudSync:status", "cloudSync:preview", "cloudSync:connect", "cloudSync:disconnect", "cloudSync:syncNow",
                                        "cloudSync:setDeviceName", "cloudSync:recreateRoot", "cloudSync:returnToPrevious", "cloudSync:signInDrive",
                                        "cloudSync:prepareMove", "cloudSync:move", "cloudSync:dismissMove"]
    private weak var store: NativeWorkspaceStore?
    private let runtime: DesktopRuntime, profile: DesktopProfileService
    private var engine: CloudSyncEngine?, provider: SyncProvider?, identityObserver: NSObjectProtocol?, starting = false, startAgain = false
    /// A move's last step under way (spec v2.7); "지금 동기화" waits for it.
    private var finishing: Task<Void, Never>?
    /// What is shown while no engine runs: off, signed out, another account.
    private var idle: [String: Any] = ["phase": "off"]

    /// iCloud and Google by default; tests give a folder, accounts, a Drive and their own keychain.
    struct Environment {
        /// The root, or nil while signed out, and the signed-in account. May block: called off the main thread.
        var locate: @Sendable () -> (URL?, String) = { (ICloudProvider.locate(), ICloudProvider.identity()?.base64EncodedString() ?? "") }
        var provider: (URL) -> SyncProvider = { ICloudProvider(root: $0) }
        var keychain = SyncStore.Keychain.live
        /// Google sign-in for Drive (nil when the user closes it), with the account to offer first, and the Drive root of an account.
        var signIn: @MainActor (String?) async throws -> GoogleDriveAuth.Account? = { try await GoogleDriveAuth.signIn(hint: $0) }
        var drive: (GoogleDriveAuth.Account) -> SyncProvider = { DriveProvider(account: $0, cache: CloudSyncService.driveCache($0.id)) }
    }
    /// A Google account signed in for a connection not made yet; it is kept only once the connection is.
    private var pendingDrive: GoogleDriveAuth.Account?
    /// The root the last preview or connection read, for the log: its provider and what it held.
    private var looked: (provider: SyncProvider, root: String?)?
    var environment = Environment()

    init(store: NativeWorkspaceStore, profile: DesktopProfileService) {
        self.store = store
        runtime = store.runtime
        self.profile = profile
    }

    func handle(_ channel: String, _ request: [String: Any]) async throws -> Any {
        switch channel {
        case "cloudSync:preview":
            let kind = request["provider"] as? String ?? "icloud"
            do { return try await preview(kind) } catch { await log("preview", (error as? DesktopRuntimeError)?.code ?? "error", kind); throw error }
        case "cloudSync:connect":
            do { try await connect(request) } catch { await log("connect", (error as? DesktopRuntimeError)?.code ?? "error", request["provider"] as? String ?? "icloud"); throw error }
        case "cloudSync:disconnect": try await disconnect()
        case "cloudSync:prepareMove":
            let kind = request["provider"] as? String ?? ""
            do { return try await prepareMove(kind, hint: request["accountHint"] as? String) } catch { await log("move", (error as? DesktopRuntimeError)?.code ?? "error", kind); throw error }
        case "cloudSync:move":
            let kind = request["provider"] as? String ?? ""
            do { try await move(kind, expect: request["expect"] as? String) } catch { await log("move", (error as? DesktopRuntimeError)?.code ?? "error", kind); throw error }
        case "cloudSync:dismissMove": try await dismissMove(request["t"])
        case "cloudSync:syncNow": try await store?.flushDocuments(); await (provider as? DriveProvider)?.hurry(); await engine?.syncNow(); await finishing?.value
        case "cloudSync:signInDrive":
            // Google stopped honouring the token: the same account again replaces it; another one is
            // joined only through the sheet (start pauses for it).
            guard let account = try await environment.signIn(nil) else { break }
            let joined = try await runtime.withSyncStorage { context, _ in try Self.joined(SyncStore(context: context)) }
            if joined == "drive:" + account.id { try keepDriveAccount(account) } else { pendingDrive = account }
            await start()
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
    /// `-BandalCloudSync icloud|drive|off` at launch also turns it on or off (device testing).
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
                if let requested { try SyncStore(context: context).setProvider(Self.kinds.contains(requested) ? requested : nil) }
                return try SyncStore.provider(context)
            }
            try? FileManager.default.removeItem(at: handoff)
            guard let provider, Self.kinds.contains(provider) else { return publish(["phase": "off"]) }
            if provider == "icloud" { observeIdentity() }
            guard let target = try await target(provider) else { return publish(["phase": "paused", "reason": provider == "drive" ? "drive-signed-out" : "signed-out"]) }
            let known = try await runtime.withSyncStorage { context, _ in try Self.joined(SyncStore(context: context)) }
            if known == nil { try await runtime.withSyncStorage { context, _ in try SyncStore(context: context).set("sync_account", target.account) } }
            // Another account holds another root: it is joined only through the connection sheet (design §4.4).
            else if known != target.account { return publish(["phase": "paused", "reason": "account-changed"]) }
            // Turned off while this start was waiting: stay off.
            guard try await runtime.withSyncStorage({ context, _ in try SyncStore.provider(context) }) == provider else { return publish(["phase": "off"]) }
            try await run(target.provider, kind: provider)
        } catch { publish(["phase": "error", "message": error.localizedDescription]) }
    }

    func suspend() async { await engine?.suspend() }
    func resume() { engine?.resume() }

    // MARK: Connection (design §4.2)

    /// What the root and this iPad hold, read before anything is written. Drive asks for the
    /// Google account first when this profile has none, and again when the one kept stopped working.
    private func preview(_ kind: String) async throws -> [String: Any] {
        do { return try await previewOnce(kind) }
        catch let error as DesktopRuntimeError where kind == "drive" && error.code == GoogleDriveAuth.signedOut.code {
            pendingDrive = nil
            try keepDriveAccount(nil)
            return try await previewOnce(kind)
        }
    }

    private func previewOnce(_ kind: String) async throws -> [String: Any] {
        looked = nil
        guard let target = try await target(kind, signIn: true) else { return ["available": false, "provider": kind] }
        let peek = try await self.peek(target.provider)
        // Another device still filling the root is waited for, told from its mark before the rest is
        // down; once it has stopped, the root can be merged or taken, not overwritten (spec v2.6).
        let uploader = try await initialUploader(peek.state ?? peek.mark)
        if let uploader, uploader.going {
            await log("preview", "uploading", kind)
            return ["available": true, "initialUpload": ["device": uploader.name, "going": true], "provider": kind]
        }
        guard let state = peek.state else {
            await log("preview", "downloading", kind)
            return ["available": true, "downloading": peek.downloading, "provider": kind]
        }
        let files = peek.files, empty = !files.keys.contains(where: SyncFormat.isSpecFile)
        if let blocked = state.blocked, !empty {
            await log("preview", blocked.rawValue, kind)
            return ["available": true, "blocked": blocked.rawValue, "provider": kind]
        }
        var result = try await runtime.withSyncStorage { context, library in
            let store = try SyncStore(context: context)
            // Joining another account's root forgets what was matched with the old one (see connect).
            let forgetting = try Self.joined(store).map { $0 != target.account } ?? false
            return try SyncConnection.preview(state, files: files, forgetting: forgetting, context: context, library: library)
        }
        result["available"] = true; result["empty"] = empty; result["provider"] = kind
        if let uploader { result["initialUpload"] = ["device": uploader.name, "going": false] }
        return result
    }

    private func initialUploader(_ state: SyncMerge.State?) async throws -> (name: String, going: Bool)? {
        guard let state, state.initialUpload != nil else { return nil }
        let keychain = environment.keychain
        let me = try await runtime.withSyncStorage { context, _ in try SyncStore(context: context, keychain: keychain).deviceID() }
        return state.initialUploader(besides: me, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// `mode`: start (an empty root), merge, overwrite, or import (a new profile takes the cloud's data).
    private func connect(_ request: [String: Any]) async throws {
        let mode = request["mode"] as? String ?? "start", kind = request["provider"] as? String ?? "icloud"
        guard Self.kinds.contains(kind) else { throw DesktopRuntimeError("동기화 위치를 확인해 주세요.", code: "VALIDATION_ERROR") }
        if mode == "import" {
            try await store?.flushDocuments(); await engine?.syncNow()
            let was = engine == nil ? nil : try await runtime.withSyncStorage { context, _ in try SyncStore.provider(context) }
            // The new profile takes the Google account (and its downloads) with it; this one lets it go.
            let account = kind == "drive" ? pendingDrive ?? driveAccount : nil, kept = driveAccount
            try await disconnect(movingAccount: true)
            do {
                _ = try await profile.newProfileForSync(provider: kind) { [self] root in if let account { try keepDriveAccount(account, key: Self.driveKey(root)) } }
            } catch {
                // The switch did not happen: this profile goes on as it was.
                if let kept { try? keepDriveAccount(kept) }
                if let was { _ = try? await runtime.withSyncStorage { context, _ in try SyncStore(context: context).setProvider(was) }; await start() }
                throw error
            }
            return
        }
        guard let connection = SyncConnection.Mode(rawValue: mode) else { throw DesktopRuntimeError("연결 방법을 확인해 주세요.", code: "VALIDATION_ERROR") }
        let pairs = (request["pairs"] as? [[String: Any]] ?? []).compactMap { pair -> (local: String, remote: String)? in
            guard let local = pair["local"] as? String, let remote = pair["remote"] as? String else { return nil }
            return (local, remote)
        }
        looked = nil
        guard let target = try await target(kind) else {
            throw kind == "drive" ? GoogleDriveAuth.signedOut : DesktopRuntimeError("iCloud에 로그인하고 iCloud Drive를 켜야 합니다.", code: "SYNC_SIGNED_OUT")
        }
        let peek = try await self.peek(target.provider)
        if let uploader = try await initialUploader(peek.state ?? peek.mark) {
            if uploader.going { throw DesktopRuntimeError("‘\(uploader.name)’에서 처음 올리는 중이에요. 끝난 뒤 다시 켜 주세요.", code: "SYNC_INITIAL_UPLOAD") }
            if connection == .overwrite { throw DesktopRuntimeError("처음 올리기가 끝나지 않은 폴더는 덮어쓸 수 없어요. 합치거나 가져와 주세요.", code: "SYNC_INITIAL_UPLOAD") }
        }
        guard let state = peek.state else {
            throw DesktopRuntimeError("\(Self.name(kind))에서 반달 폴더를 아직 내려받고 있어요. 잠시 뒤 다시 시도해 주세요.", code: "SYNC_NOT_READY")
        }
        let files = peek.files, empty = !files.keys.contains(where: SyncFormat.isSpecFile)
        if state.blocked != nil, !empty { throw DesktopRuntimeError("이 반달 폴더는 새 버전의 반달이 만들었어요. 앱을 업데이트해 주세요.", code: "SYNC_UPDATE_REQUIRED") }
        // What the user agreed to must still be what is there.
        if connection == .start, !empty { throw DesktopRuntimeError("클라우드에 반달 자료가 생겼어요. 다시 확인해 주세요.", code: "SYNC_ROOT_CHANGED") }
        if connection == .overwrite, request["fingerprint"] as? String != SyncConnection.fingerprint(files) {
            throw DesktopRuntimeError("클라우드 자료가 바뀌었어요. 지워질 자료를 다시 확인해 주세요.", code: "SYNC_ROOT_CHANGED")
        }
        await engine?.stop(); engine = nil; provider = nil
        try await runtime.withSyncStorage { context, library in
            let store = try SyncStore(context: context)
            // All or nothing: a connection that fails leaves the earlier one as it was.
            try context.transaction {
                // Another account, or the other provider, is another root: what was exchanged with the old one says nothing about it.
                if let known = try Self.joined(store), known != target.account { try store.forgetRoot() }
                if empty { try context.run("DELETE FROM cloud_sync_state WHERE key IN ('pending_deletes','export_first')") }
                else { try SyncConnection.connect(connection, pairs: pairs, state: state, store: store, library: library) }
                try store.set("sync_account", target.account)
                try store.setProvider(kind)
            }
        }
        // The Google account is kept from now on; joining iCloud lets it go.
        try keepDriveAccount(target.drive)
        pendingDrive = nil
        if kind == "icloud" { observeIdentity() }
        // No folder found, so the first write makes one: how two devices end up on two roots (spec v2.6).
        if let drive = target.provider as? DriveProvider, await drive.lookup().chosen == nil { await log("connect", "new-root-folder", kind) }
        try await run(target.provider, kind: kind)
    }

    // MARK: Moving (spec v2.7)

    /// The storage this profile moves from: the one it syncs with, to the other one, one move at a time.
    private func moveFrom(_ kind: String) async throws -> String {
        let (from, moving) = try await runtime.withSyncStorage { context, _ in (try SyncStore.provider(context), try SyncStore(context: context).moving()) }
        guard let from, engine != nil else { throw DesktopRuntimeError("먼저 동기화를 켜 주세요.", code: "SYNC_MOVE_OFF") }
        guard Self.kinds.contains(kind), kind != from else { throw DesktopRuntimeError("이미 \(Self.name(from))와 동기화하고 있어요.", code: "VALIDATION_ERROR") }
        guard moving == nil else { throw DesktopRuntimeError("앞서 옮긴 것을 아직 마무리하고 있어요. 잠시 뒤 다시 시도해 주세요.", code: "SYNC_MOVING") }
        return from
    }

    /// The other storage as a move would find it: `upload` when it holds nothing alive, `join` when it holds data
    /// to merge with by id; or why a move cannot go on now. `hint`: the Google account another device moved to.
    private func prepareMove(_ kind: String, hint: String?) async throws -> [String: Any] {
        _ = try await moveFrom(kind)
        looked = nil
        guard let target = try await target(kind, signIn: true, hint: hint) else { return ["available": false, "provider": kind] }
        let peek = try await self.peek(target.provider)
        let uploader = try await initialUploader(peek.state ?? peek.mark)
        if let uploader, uploader.going {
            await log("move", "uploading", kind)
            return ["available": true, "initialUpload": ["device": uploader.name, "going": true], "provider": kind]
        }
        guard let state = peek.state else {
            await log("move", "downloading", kind)
            return ["available": true, "downloading": peek.downloading, "provider": kind]
        }
        let files = peek.files
        if let blocked = state.blocked, files.keys.contains(where: SyncFormat.isSpecFile) { return ["available": true, "blocked": blocked.rawValue, "provider": kind] }
        var result = try await runtime.withSyncStorage { context, library in
            try SyncConnection.preview(state, files: files, forgetting: false, context: context, library: library)
        }.filter { ["cloud", "local"].contains($0.key) }
        result["available"] = true; result["provider"] = kind; result["plan"] = Self.plan(state)
        if let uploader { result["initialUpload"] = ["device": uploader.name, "going": false] }
        return result
    }

    /// A move into a root that holds nothing alive fills it; one into a root with data joins it by id.
    private static func plan(_ state: SyncMerge.State) -> String {
        state.courses.values.contains(where: \.isAlive) || state.docs.values.contains(where: \.isAlive) ? "join" : "upload"
    }

    /// Moves this profile's sync to the other storage: a last pass with the old root, which must go through, then
    /// the new root, filled whole when it is empty and joined by id when it holds data (its first pass rebases the
    /// base). The old root is told and let go once the new one holds everything (`finishMove`); its files stay.
    /// `expect`: the plan the user saw; the move stops if the new root changed since.
    private func move(_ kind: String, expect: String?) async throws {
        let from = try await moveFrom(kind)
        guard let old = engine else { return }
        // What this iPad changed goes to the old root and what others left there comes here before it is let go:
        // after a pass that did not go through, this iPad's older values would go up as new ones.
        try await store?.flushDocuments()
        let asked = Self.now()
        await (provider as? DriveProvider)?.hurry()
        await old.syncNow()
        guard old.status["phase"] as? String == "idle", old.status["lastSuccessAt"] as? Int64 ?? 0 >= asked else {
            throw DesktopRuntimeError("\(Self.name(from))와 아직 다 맞추지 못했어요. 동기화가 끝난 뒤 다시 옮겨 주세요. \(Self.name(from))를 더 쓸 수 없으면 고급에서 연결을 해제한 뒤 \(Self.name(kind))에 연결해 주세요.", code: "SYNC_MOVE_BEHIND")
        }
        looked = nil
        guard let target = try await target(kind) else {
            throw kind == "drive" ? GoogleDriveAuth.signedOut : DesktopRuntimeError("iCloud에 로그인하고 iCloud Drive를 켜야 합니다.", code: "SYNC_SIGNED_OUT")
        }
        let peek = try await self.peek(target.provider)
        if let uploader = try await initialUploader(peek.state ?? peek.mark), uploader.going {
            throw DesktopRuntimeError("‘\(uploader.name)’에서 \(Self.name(kind))에 처음 올리는 중이에요. 끝난 뒤 다시 옮겨 주세요.", code: "SYNC_INITIAL_UPLOAD")
        }
        guard let state = peek.state else {
            throw DesktopRuntimeError("\(Self.name(kind))에서 반달 폴더를 아직 내려받고 있어요. 잠시 뒤 다시 시도해 주세요.", code: "SYNC_NOT_READY")
        }
        if state.blocked != nil, peek.files.keys.contains(where: SyncFormat.isSpecFile) { throw DesktopRuntimeError("이 반달 폴더는 새 버전의 반달이 만들었어요. 앱을 업데이트해 주세요.", code: "SYNC_UPDATE_REQUIRED") }
        if let expect, expect != Self.plan(state) { throw DesktopRuntimeError("그사이 \(Self.name(kind))의 자료가 바뀌었어요. 다시 확인해 주세요.", code: "SYNC_ROOT_CHANGED") }
        // Turned off meanwhile: nothing is bound again.
        guard engine === old else { throw DesktopRuntimeError("동기화를 꺼서 옮기지 않았어요.", code: "SYNC_MOVE_OFF") }
        await old.stop(); engine = nil; provider = nil
        let keychain = environment.keychain, now = Self.now()
        do {
            try await runtime.withSyncStorage { context, _ in
                let store = try SyncStore(context: context, keychain: keychain)
                guard try SyncStore.provider(context) == from, let account = try Self.joined(store) else { throw DesktopRuntimeError("동기화를 꺼서 옮기지 않았어요.", code: "SYNC_MOVE_OFF") }
                try context.transaction {
                    try store.setMoving(.init(provider: from, account: account, at: now, clock: try store.clock(), rebase: true))
                    // This iPad's files and name in the old root say nothing about the new one.
                    try context.run("DELETE FROM cloud_sync_files")
                    try context.run("DELETE FROM cloud_sync_state WHERE key IN ('root_seen','device_name','pending_deletes','export_first')")
                    try store.set("sync_account", target.account)
                    try store.setProvider(kind)
                }
            }
        } catch { await start(); throw error }
        // The Google account of a Drive left behind stays until the old root is told (`finishMove`).
        if let drive = target.drive { try keepDriveAccount(drive) }
        pendingDrive = nil
        if kind == "icloud" { observeIdentity() }
        if let drive = target.provider as? DriveProvider, await drive.lookup().chosen == nil { await log("move", "new-root-folder", kind) }
        try await run(target.provider, kind: kind)
    }

    /// A move's last step, after a pass in the new root went through: the old root is told where this iPad went, as
    /// `moved_to` in its own devices file there, and let go. It only tells other devices, so the move ends without it
    /// when the old storage is not reached as the same account or holds no file of this iPad any more, or when its
    /// write kept failing for a week (tried again after each pass until then).
    private func finishMove() async {
        let keychain = environment.keychain
        guard let read = try? await runtime.withSyncStorage({ context, _ in
            let store = try SyncStore(context: context, keychain: keychain)
            return (moving: try store.moving(), me: try store.deviceID(), name: try store.value("device_label") ?? "iPad", kind: try SyncStore.provider(context))
        }), let moving = read.moving, let kind = read.kind, kind != moving.provider else { return }
        let (me, name, now) = (read.me, read.name, Self.now())
        if let old = await oldRoot(moving) {
            do {
                // A root without this iPad's file is not the one it left (removed or made again): nothing to tell.
                if try await old.list()["devices/\(me).json"] != nil {
                    await (old as? DriveProvider)?.hurry()
                    // The t of an event in that root: past everything this iPad saw there (user decision 2026-11-03).
                    let note = SyncFormat.MovedTo(kind: kind, t: max(now, moving.clock + 1), account: kind == "drive" ? driveAccount?.email : nil)
                    try await old.write(.data(SyncOutbox.deviceFile(name: name, lastSeen: now, movedTo: note)), to: "devices/\(me).json")
                }
            } catch {
                guard now - moving.at >= Self.tellingFor else { return }
                runtime.log.record("sync.move", channel: moving.provider, code: "gave-up")
            }
        }
        // As a disconnect: the Google account of a Drive left behind goes with its downloads, never revoked (spec v2.5).
        if moving.provider == "drive", let account = driveAccount {
            try? keepDriveAccount(nil)
            try? FileManager.default.removeItem(at: Self.driveCache(account.id))
        }
        guard (try? await runtime.withSyncStorage({ context, _ in try SyncStore(context: context, keychain: keychain).setMoving(nil) })) != nil else { return }
        engine?.moving = nil
        engine?.republish()
    }

    /// How long a move tries to tell the old root (as the desktop does).
    static let tellingFor: Int64 = 7 * 24 * 3_600_000

    /// The root a move left, when this iPad still reaches it as the same account; nil otherwise.
    private func oldRoot(_ moving: SyncStore.Moving) async -> SyncProvider? {
        if moving.provider == "drive" { return driveAccount.flatMap { "drive:" + $0.id == moving.account ? environment.drive($0) : nil } }
        let (root, account) = await locate()
        return root.flatMap { "icloud:" + account == moving.account ? environment.provider($0) : nil }
    }

    /// "나중에" on another device's move: neither it nor an earlier one is offered again.
    private func dismissMove(_ value: Any?) async throws {
        guard let t = (value as? NSNumber)?.int64Value else { throw DesktopRuntimeError("옮기기 안내를 확인해 주세요.", code: "VALIDATION_ERROR") }
        try await runtime.withSyncStorage { context, _ in
            let store = try SyncStore(context: context)
            try store.set("move_dismissed", String(max(t, Int64(try store.value("move_dismissed") ?? "") ?? 0)))
        }
        engine?.dismissMove(t)
    }

    /// Sync off. The Google account of Drive sync is forgotten here with its downloads, not revoked:
    /// a revoke ends the grant on the user's other devices too. Drive keeps its files.
    private func disconnect(movingAccount: Bool = false) async throws {
        await engine?.stop(); engine = nil; provider = nil
        let runtime = runtime
        try await runtime.withSyncStorage { context, _ in
            runtime.onLocalChange = nil
            guard try context.tableExists("cloud_sync_state") else { return }
            // An overwrite that did not go out yet is dropped with the connection (review HIGH).
            try context.run("DELETE FROM cloud_sync_state WHERE key IN ('pending_deletes','export_first')")
            let store = try SyncStore(context: context)
            // A move not finished yet ends here too, untold. Before the new root's first pass the base still describes the old root.
            if let moving = try store.moving() {
                if moving.rebase { try store.set("sync_account", moving.account) }
                try store.setMoving(nil)
            }
            try store.setProvider(nil)
        }
        pendingDrive = nil
        if let account = driveAccount {
            try keepDriveAccount(nil)
            if !movingAccount { try? FileManager.default.removeItem(at: Self.driveCache(account.id)) }
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
        if let account = driveAccount { result["driveEmail"] = account.email }
        return result
    }

    // MARK: Engine

    private func run(_ provider: SyncProvider, kind: String) async throws {
        self.provider = provider
        let engine = CloudSyncEngine(runtime: runtime, provider: provider, kind: kind, keychain: environment.keychain)
        engine.onPass = { [weak self] in
            guard let self, finishing == nil else { return }
            finishing = Task { await self.finishMove(); self.finishing = nil }
        }
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

    /// The root as `CloudSyncEngine.peek` reads it, kept for the connection log.
    private func peek(_ provider: SyncProvider) async throws -> (files: [String: SyncRemoteFile], state: SyncMerge.State?, mark: SyncMerge.State?, downloading: Int) {
        looked = (provider, nil)
        let peek = try await CloudSyncEngine.peek(provider)
        let device = (peek.state ?? peek.mark)?.initialUpload ?? "-"
        looked = (provider, "entries:\(peek.files.count):bandal_json:\(peek.files["bandal.json"] == nil ? 0 : 1):initial_upload:\(device)")
        return peek
    }

    /// The connection log (spec v2.6): a preview or connection that waits or fails, or makes a new Drive
    /// folder, with the root it read and, on Drive, each folder it looked at as
    /// `id:createdTime:mark|name:bandal.json 1|0:chosen 1|0:name`. Two devices on two roots show in it.
    private func log(_ step: String, _ outcome: String, _ kind: String) async {
        runtime.log.record("sync.\(step)", channel: kind, code: outcome)
        guard let looked else { return }
        if let root = looked.root { runtime.log.record("sync.\(step).root", channel: kind, code: root) }
        for folder in await (looked.provider as? DriveProvider)?.lookup().folders ?? [] { runtime.log.record("sync.\(step).folder", channel: kind, code: folder) }
    }

    private static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    private func locate() async -> (URL?, String) {
        let locate = environment.locate
        return await Task.detached { locate() }.value
    }

    // MARK: Providers

    static let kinds: Set = ["icloud", "drive"]
    static func name(_ kind: String) -> String { kind == "drive" ? "Google Drive" : "iCloud" }

    /// A provider's root with the account it belongs to; another account, or the other provider,
    /// is another root (design §4.4). nil while signed out of it.
    private struct Target { let provider: SyncProvider; let account: String; var drive: GoogleDriveAuth.Account? }

    private func target(_ kind: String, signIn: Bool = false, hint: String? = nil) async throws -> Target? {
        if kind == "drive" {
            var account = pendingDrive ?? driveAccount
            if account == nil, signIn { account = try await environment.signIn(hint); pendingDrive = account }
            return account.map { Target(provider: environment.drive($0), account: "drive:" + $0.id, drive: $0) }
        }
        let (root, account) = await locate()
        return root.map { Target(provider: environment.provider($0), account: "icloud:" + account) }
    }

    /// Downloads of one Google account's Drive, under Caches (the system may clear them; they come down again).
    nonisolated static func driveCache(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BandalDrive/" + id, isDirectory: true)
    }

    /// The account of the root last joined. Before Drive it was kept as the iCloud account alone.
    private static func joined(_ store: SyncStore) throws -> String? {
        try store.value("sync_account") ?? store.value("icloud_account").map { "icloud:" + $0 }
    }

    /// The Google account of this profile's Drive sync, in the keychain like the device id: one per profile.
    static func driveKey(_ root: String) -> String { root == "BandalDesktop" ? "drive.account" : "drive.account." + root }
    private var driveAccount: GoogleDriveAuth.Account? {
        environment.keychain.read(Self.driveKey(runtime.root.lastPathComponent)).flatMap { try? JSONDecoder().decode(GoogleDriveAuth.Account.self, from: Data($0.utf8)) }
    }
    private func keepDriveAccount(_ account: GoogleDriveAuth.Account?, key: String? = nil) throws {
        let value = try account.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try environment.keychain.write(key ?? Self.driveKey(runtime.root.lastPathComponent), value)
    }
}
