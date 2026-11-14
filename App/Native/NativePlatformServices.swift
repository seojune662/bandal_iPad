import SwiftUI
import UIKit
import Combine

@MainActor
final class NativePlatformServices: ObservableObject {
    private let files: DesktopFileServices
    let browser: DesktopBrowserHost
    private let credentials: DesktopCredentialsService
    private let ai: DesktopAIService
    private let assistant: NativeAssistantService
    private let recording: DesktopRecordingService
    private let settingsService: NativeSettingsPlatformService
    private let articles = DesktopArticleService()
    private lazy var cloud = DesktopCloudService(environment: DesktopCloudEnvironment(
        signedIn: { [weak self] in
            guard let self else { return false }
            return (try? await self.account.handle(channel: "auth:getState", request: [:]) as? [String: Any])?["phase"] as? String == "signed-in"
        }, credential: { [weak self] in
            guard let self else { throw CancellationError() }
            return (try await self.account.syncIdentity(), try await self.account.accessToken())
        }))
    private lazy var marketplace = NativeStudyMarketClient(cloud: cloud)
    private var account: DesktopAccountService
    private var sync: DesktopSyncService?
    private let cloudSync: CloudSyncService
    private var billing: DesktopBillingService?
    private let profile: DesktopProfileService
    private var syncError: Error?
    private var foreground: NSObjectProtocol?
    private weak var store: NativeWorkspaceStore?
    private var subscription: AnyCancellable?
    private var started = false

    init(store: NativeWorkspaceStore, credentialEnvironment: DesktopCredentialsService.Environment = .live) {
        self.store = store
        let runtime = store.runtime
        files = DesktopFileServices(runtime:runtime)
        settingsService = NativeSettingsPlatformService(store:store,files:files)
        browser = DesktopBrowserHost(root:runtime.root)
        credentials = DesktopCredentialsService(namespace: runtime.root.lastPathComponent, environment: credentialEnvironment)
        let account = DesktopAccountService(root:runtime.root)
        self.account = account
        var aiEnvironment = DesktopAIEnvironment()
        aiEnvironment.askConsent = { [weak store] provider in
            let settings = (try? await store?.invoke("settings:get")) as? [String: Any]
            return await AIConsent.ask(provider, english: settings?["locale"] as? String == "en-US")
        }
        aiEnvironment.endpoint = { [account] in
            let identity: DesktopSyncIdentity
            do { identity = try await account.syncIdentity() } catch { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return AIEndpoint(userID: identity.userID, projectURL: identity.projectURL, publishableKey: identity.publishableKey, token: { [weak account] in
                do {
                    guard let account else { throw CancellationError() }
                    return try await account.accessToken()
                } catch is CancellationError where Task.isCancelled { throw CancellationError() }
                catch { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            })
        }
        store.schools = LiveSchoolDirectory(endpoint: aiEnvironment.endpoint, send: { [session = aiEnvironment.session] in try await session.data(for: $0) })
        store.referral.service = LiveReferralService(endpoint: aiEnvironment.endpoint, send: { [session = aiEnvironment.session] in try await session.data(for: $0) })
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(SchoolDirectoryFake.argument) { store.schools = SchoolDirectoryFake() }
        if arguments.contains(ReferralServiceFake.argument) { store.referral.service = ReferralServiceFake(signedIn: !arguments.contains(ReferralServiceFake.signedOutArgument)) }
        #endif
        // Keys and the local AI counter from the BYOK versions (≤ 1.3) are no longer used.
        if !UserDefaults.standard.bool(forKey: "ai.byokRetired") {
            for retired in ["ai.openai", "ai.claude", "ai.gemini", "membership.ai-uses"] { try? KeychainStore.write("", account: retired) }
            UserDefaults.standard.set(true, forKey: "ai.byokRetired")
        }
        aiEnvironment.onUsage = { usage in AIUsage.shared.update(usage) }
        aiEnvironment.onLimit = { code, usage in AIUsage.presentLimit(code, usage: usage) }
        if NativeReleaseFlags.membership {
            runtime.limits = { channel, request, library in if !Membership.unlimited { try FreeTier.check(channel, request, library: library) } }
        }
        ai = DesktopAIService(environment: aiEnvironment)
        assistant = NativeAssistantService(runtime:runtime,ai:ai)
        profile = DesktopProfileService(documents:runtime.root.deletingLastPathComponent(),root:runtime.root)
        cloudSync = CloudSyncService(store:store,profile:profile)
        recording = DesktopRecordingService(root:runtime.legacyRoot,invoke:{ channel,request in try await runtime.invokePrivate(channel,request:request) })
        connectAccount()
        Membership.shared.accountToken = { [weak account] in account?.userID.flatMap(UUID.init(uuidString:)) }
        MembershipPaywall.freeUsage = { [weak store] in try? await store?.invokePrivate("nativeMembership:usage") as? [String: Any] }
        StoreSync.shared.post = { [weak account] body in
            guard let account, account.userID != nil else { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return try await account.serviceRequest(path: "/functions/v1/ipad-store", body: body)
        }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in if NativeReleaseFlags.membership { await StoreSync.shared.redeemPending() } }
        }
        StoreSync.shared.onStatus = { [weak self] status in
            AIUsage.shared.update(status)
            self?.ai.invalidate()
        }
        profile.prepare = { [weak self, weak store] in
            await self?.sync?.suspendForProfileOperation()
            await self?.cloudSync.suspend()
            try await store?.flushDocuments()
        }
        profile.resume = { [weak self] in self?.sync?.resumeAfterProfileOperation(); self?.cloudSync.resume() }
        profile.activate = { NotificationCenter.default.post(name:DesktopProfileService.didActivate,object:nil) }
        browser.emit = { [weak runtime] channel,payload in runtime?.onEmit?(channel,payload) }
        recording.emit = { [weak runtime] channel,payload in runtime?.onEmit?(channel,payload) }
        browser.onCourseForURL = { [weak store] _ in store?.selectedCourseID }
        browser.onOpenMaterial = { [weak runtime] course, path in
            runtime?.onEmit?("nativeWorkspace:openDocument", ["courseId": course, "relPath": path,
                "title": (path as NSString).lastPathComponent, "kind": NativeSidebarDescriptor.materialKind(path)])
        }
        credentials.profileExists = { [weak browser] in browser?.isProfileAvailable($0) == true }
        credentials.target = { [weak browser] guest, origin in
            guard let browser else { throw CancellationError() }
            return try browser.credentialTarget(guestID: guest, origin: origin)
        }
        credentials.capture = { [weak browser] target in
            guard let browser else { throw CancellationError() }
            return try await browser.captureLogin(target)
        }
        credentials.fill = { [weak browser] target, username, password, submit in
            guard let browser else { throw CancellationError() }
            return try await browser.fillLogin(target, username: username, password: password, autoSubmit: submit)
        }
        credentials.offer = { [weak browser] in browser?.loginOffer(tabID: $0) }
        credentials.clearOffer = { [weak browser] in browser?.clearLoginOffer(tabID: $0) }
        credentials.neverSave = { [weak browser] profile, origin in
            try browser?.savePermission(profile: profile, origin: origin, permission: DesktopBrowserHost.passwordSavePermission, decision: "denied")
        }
        credentials.tabTarget = { [weak browser] in browser?.credentialTarget(tabID: $0) }
        credentials.hasLoginForm = { [weak browser] in await browser?.hasLoginForm($0) ?? false }
        browser.onDeleteProfile = { [weak credentials] profile in
            guard let credentials else { throw CancellationError() }
            try credentials.deleteProfile(profile)
        }
        articles.sourceTab = { [weak browser] course, tab, url, script in
            guard let browser else { throw CancellationError() }
            return try await browser.extractArticle(courseID: course, tabID: tab, expectedURL: url, script: script)
        }
        browser.onDownload = { [weak store, weak settingsService] file,course in
            guard let store, let course else { return nil }
            guard let result = try await store.invoke("materials:import",["courseId":course,"dirRelPath":"","paths":[file.path]]) as? [String:Any], let imported = result["imported"] as? [String], let path = imported.first else { throw DesktopRuntimeError("다운로드 파일을 자료실에 추가하지 못했습니다.") }
            settingsService?.downloaded(file.lastPathComponent)
            return path
        }
        browser.onAgentAttachment = { [weak files] course,path in
            guard let files else { throw CancellationError() }
            return (URL(fileURLWithPath:path).lastPathComponent,"application/octet-stream",try await files.readAttachment(courseID:course,relPath:path))
        }
        store.nativeChannelHandler = { [weak self] channel,request in
            guard let self else { throw CancellationError() }; return try await self.handle(channel,request)
        }
        subscription = store.events.sink { [weak self] event in
            self?.settingsService.receive(event)
            if event.channel == "settings:changed", let value = event.payload as? [String:Any], let settings = value["settings"] as? [String:Any] {
                NativeAppearancePreference.apply(settings)
                if let browser = settings["browser"] as? [String:Any] { self?.browser.applySettings(browser) }
                self?.browser.applyShortcuts(NativeBrowserShortcuts.resolve(settings))
                self?.settingsService.apply(settings)
            }
        }
    }
    private func connectAccount() {
        guard let store else { return }
        // Both legacy services upload to Supabase, so neither is created unless the legacy switch is on.
        if NativeReleaseFlags.legacyCloudSync {
            do { sync = try DesktopSyncService(runtime:store.runtime,account:account); syncError = nil }
            catch { sync = nil; syncError = error }
            sync?.flushOpenDocuments = { [weak store] in try await store?.flushDocuments() }
            sync?.mutateOpenDocuments = { [weak store] action in
                guard let store else { throw CancellationError() }
                return try await store.withExternalMutation(action)
            }
            sync?.emit = { [weak store] channel,value in store?.runtime.onEmit?(channel,value) }
            let billing = DesktopBillingService(account:account)
            billing.emit = { [weak store] channel,value in store?.runtime.onEmit?(channel,value) }
            billing.entitlementChanged = { [weak self] in self?.sync?.requestSync(force:true) }
            self.billing = billing
        }
        account.emit = { [weak self, weak store] channel,value in
            store?.runtime.onEmit?(channel,value)
            if let state = value as? [String:Any] {
                self?.sync?.accountChanged(state); self?.billing?.accountChanged()
                if state["phase"] as? String != "signed-in" { AIUsage.shared.reset() }
                if NativeReleaseFlags.membership { StoreSync.shared.accountChanged(self?.account.userID) }
            }
        }
    }
    func start() async {
        guard !started, let store, store.isReady else { return }; started = true
        if NativeReleaseFlags.membership { Membership.shared.start() }
        do {
            if let settings = try await store.invoke("settings:get") as? [String:Any] {
                NativeAppearancePreference.apply(settings)
                if let value = settings["browser"] as? [String:Any] { browser.applySettings(value) }
                browser.applyShortcuts(NativeBrowserShortcuts.resolve(settings))
                settingsService.apply(settings)
            }
            // The engine identity probe (~0.6 s, one throwaway web view) otherwise
            // runs when the first browser tab opens. Failure is retried there.
            Task { try? await DesktopBrowserIdentity.prepare() }
            _ = try await account.handle(channel:"auth:getState",request:[:])
            sync?.start()
        } catch { store.errorMessage = error.localizedDescription }
        await cloudSync.start()
    }
    private func handle(_ channel: String,_ request: [String:Any]) async throws -> Any {
        if channel == "native:extractArticle" { return try await articles.extract(request) }
        if channel == "studyMarket:request" || cloud.canHandle(channel) {
            guard NativeReleaseFlags.showsMarketplace else { throw DesktopRuntimeError("이 버전에서는 마켓플레이스를 사용할 수 없습니다.", code: "MARKETPLACE_DISABLED") }
            if channel == "studyMarket:request" { return try await marketplace.request(request) }
            return try await cloud.handle(channel: channel, request: request)
        }
        if channel.hasPrefix("nativeSettings:") { return try await settingsService.handle(channel,request) }
        if files.canHandle(channel) { return try await files.handle(channel:channel,request:request) }
        if credentials.canHandle(channel) { return try await credentials.handle(channel:channel,request:request) }
        if browser.canHandle(channel) { return try await browser.handle(channel:channel,request:request) }
        if ai.canHandle(channel) { return try await ai.handle(channel:channel,request:request) }
        if recording.canHandle(channel) { return try await recording.handle(channel:channel,request:request) }
        if account.canHandle(channel) { return try await account.handle(channel:channel,request:request) }
        if channel == "auth:deleteAccount" { let result = try await account.deleteAccount(); billing?.accountChanged(); return result }
        if let billing, billing.canHandle(channel) { return try await billing.handle(channel,request:request) }
        if channel == "profile:backup" || channel == "profile:new" { return try await profile.handle(channel) }
        if CloudSyncService.channels.contains(channel) { return try await cloudSync.handle(channel,request) }
        if ["chat:send","chat:cancel","chat:close","nativeChat:open"].contains(channel) { return try await assistant.handle(channel,request) }
        if channel.hasPrefix("sync:") {
            guard NativeReleaseFlags.legacyCloudSync else { throw DesktopRuntimeError("이 버전에서는 이전 계정 동기화를 사용할 수 없습니다.", code: "LEGACY_SYNC_DISABLED") }
            guard let sync else { throw syncError ?? DesktopRuntimeError("동기화 저장소를 열지 못했습니다.") }
            switch channel {
            case "sync:status":return try await sync.status()
            case "sync:run":try await sync.synchronizeNow(force:true); return try await sync.status()
            case "sync:setEnabled":return try await sync.setEnabled(request["enabled"] as? Bool == true)
            case "sync:conflicts":return try await sync.conflictSummaries()
            case "sync:conflictDetails":return try await sync.conflicts()
            case "sync:restoreConflict","sync:resolveConflict":return try await sync.restoreConflict(NativeValue.string(request["id"] ?? request["conflictID"],"충돌"),variant:NativeValue.string(request["variant"],"사본"))
            case "sync:exportConflict":return try await sync.exportConflict(NativeValue.string(request["id"],"충돌"))
            default:break
            }
        }
        throw DesktopRuntimeError("이 기기 작업을 열 수 없습니다: \(channel)",code:"ENOSYS")
    }
    func attach(_ controller: UIViewController) {
        let presenter = controller.view.window?.rootViewController ?? controller
        files.presenter = presenter; browser.presenter = presenter; credentials.presenter = presenter; profile.presenter = presenter
    }
}

struct NativePresentationAnchor: UIViewControllerRepresentable {
    let services: NativePlatformServices
    func makeUIViewController(context: Context) -> Anchor {
        let controller = Anchor()
        controller.services = services
        return controller
    }
    func updateUIViewController(_ controller: Anchor, context: Context) {
        if controller.viewIfLoaded?.window != nil { services.attach(controller) }
    }
    final class Anchor: UIViewController {
        weak var services: NativePlatformServices?
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            NativeInputTrace.install(in: view.window)
            services?.attach(self)
        }
    }
}
