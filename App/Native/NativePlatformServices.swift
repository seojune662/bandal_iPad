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
    private var syncError: Error?
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
        ai = DesktopAIService()
        assistant = NativeAssistantService(runtime:runtime,ai:ai)
        account = DesktopAccountService(root:runtime.root)
        recording = DesktopRecordingService(root:runtime.legacyRoot,invoke:{ channel,request in try await runtime.invokePrivate(channel,request:request) })
        connectAccount()
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
        do { sync = try DesktopSyncService(runtime:store.runtime,account:account); syncError = nil }
        catch { sync = nil; syncError = error }
        sync?.flushOpenDocuments = { [weak store] in try await store?.flushDocuments() }
        sync?.mutateOpenDocuments = { [weak store] action in
            guard let store else { throw CancellationError() }
            return try await store.withExternalMutation(action)
        }
        sync?.emit = { [weak store] channel,value in store?.runtime.onEmit?(channel,value) }
        account.emit = { [weak self, weak store] channel,value in
            store?.runtime.onEmit?(channel,value)
            if let state = value as? [String:Any] { self?.sync?.accountChanged(state) }
        }
    }
    func start() async {
        guard !started, let store, store.isReady else { return }; started = true
        do {
            if let settings = try await store.invoke("settings:get") as? [String:Any] {
                NativeAppearancePreference.apply(settings)
                if let value = settings["browser"] as? [String:Any] { browser.applySettings(value) }
                browser.applyShortcuts(NativeBrowserShortcuts.resolve(settings))
                settingsService.apply(settings)
            }
            _ = try await account.handle(channel:"auth:getState",request:[:])
            sync?.start()
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func handle(_ channel: String,_ request: [String:Any]) async throws -> Any {
        if channel == "native:extractArticle" { return try await articles.extract(request) }
        if channel == "studyMarket:request" { return try await marketplace.request(request) }
        if cloud.canHandle(channel) { return try await cloud.handle(channel: channel, request: request) }
        if channel.hasPrefix("nativeSettings:") { return try await settingsService.handle(channel,request) }
        if files.canHandle(channel) { return try await files.handle(channel:channel,request:request) }
        if credentials.canHandle(channel) { return try await credentials.handle(channel:channel,request:request) }
        if browser.canHandle(channel) { return try await browser.handle(channel:channel,request:request) }
        if ai.canHandle(channel) { return try await ai.handle(channel:channel,request:request) }
        if recording.canHandle(channel) { return try await recording.handle(channel:channel,request:request) }
        if account.canHandle(channel) { return try await account.handle(channel:channel,request:request) }
        if ["chat:send","chat:cancel","chat:close","nativeChat:open"].contains(channel) { return try await assistant.handle(channel,request) }
        if channel.hasPrefix("sync:") {
            guard let sync else { throw syncError ?? DesktopRuntimeError("동기화 저장소를 열지 못했습니다.") }
            switch channel {
            case "sync:status":return try await sync.status()
            case "sync:run":try await sync.synchronizeNow(); return try await sync.status()
            case "sync:conflicts":return try await sync.conflicts()
            case "sync:restoreConflict":return try await sync.restoreConflict(NativeValue.string(request["id"] ?? request["conflictID"],"충돌"),variant:NativeValue.string(request["variant"],"사본"))
            case "sync:exportConflict":return try await sync.exportConflict(NativeValue.string(request["id"],"충돌"))
            default:break
            }
        }
        if channel == "native:configureAccount" {
            let state = try await account.handle(channel:"auth:getState",request:[:]) as? [String:Any]
            guard ["signed-out","unconfigured"].contains(state?["phase"] as? String ?? "") else { throw DesktopRuntimeError("로그아웃한 뒤 계정 서버를 변경해 주세요.") }
            let raw = try NativeValue.string(request["url"],"서버 주소"), key = try NativeValue.string(request["publishableKey"],"공개 키")
            guard let url = URL(string:raw), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw DesktopRuntimeError("올바른 HTTPS 서버 주소를 입력해 주세요.") }
            await sync?.stop()
            UserDefaults.standard.set(raw,forKey:"sync.url"); UserDefaults.standard.set(key,forKey:"sync.publishableKey")
            guard let store else { throw CancellationError() }
            account = DesktopAccountService(root:store.root); connectAccount(); sync?.start()
            return try await account.handle(channel:"auth:getState",request:[:])
        }
        throw DesktopRuntimeError("이 기기 작업을 열 수 없습니다: \(channel)",code:"ENOSYS")
    }
    func attach(_ controller: UIViewController) {
        let presenter = controller.view.window?.rootViewController ?? controller
        files.presenter = presenter; browser.presenter = presenter; credentials.presenter = presenter
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
            services?.attach(self)
        }
    }
}
