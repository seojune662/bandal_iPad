import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DesktopShell: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DesktopShellController { DesktopShellController() }
    func updateUIViewController(_ controller: DesktopShellController, context: Context) {}
}

@MainActor
final class DesktopShellController: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private(set) var runtime: DesktopRuntime!
    private var shell: WKWebView!
    private var browser: DesktopBrowserHost!
    private var assets: DesktopAssets!
    private var account: DesktopAccountService!
    private var fileServices: DesktopFileServices!
    private lazy var fileStaging = DesktopFileStaging.shared(root: runtime.root)
    private var syncService: DesktopSyncService?
    private var recordings: DesktopRecordingService!
    private var notifications: DesktopNotificationService?
    private var presentations: DesktopPresentationService!
    private var cloud: DesktopCloudService!
    private var pluginCatalog: DesktopPluginCatalogTransport!
    private var credentials: DesktopCredentialsService!
    private var miniPlayer: DesktopMiniPlayer!
    private let mcp = DesktopMCPService()
    private var previews: DesktopHoverPreviewService!
    private var capture: DesktopCaptureService!
    private let aiServices = DesktopAIService()
    private let mailServices = DesktopMailService()
    private let dictionary = DesktopDictionaryService()
    private let articles = DesktopArticleService()
    private let systemServices = DesktopSystemServices()
    private var printEnabled = false
    private var pendingOpen: [String: Any] = [:]
    private var workspaceContext: [String: Any] = [:]
    private var startupError: UILabel?
    private var lifecycleObserver: NSObjectProtocol?
    private var flushTask: Task<Void, Never>?
    private var saveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var shortcutRevision = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"), let data = try? Data(contentsOf: url),
           let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
            UserDefaults.standard.register(defaults: configuration)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing") || NSClassFromString("XCTestCase") != nil
        let root = documents.appendingPathComponent(testing ? "BandalDesktop-UI-Tests" : "BandalDesktop", isDirectory: true)
        if testing, ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { try? FileManager.default.removeItem(at: root) }
        runtime = DesktopRuntime(root: root, legacyRoot: documents.appendingPathComponent(testing ? "Bandal-UI-Tests" : "Bandal"))
        credentials = DesktopCredentialsService(namespace: root.lastPathComponent)
        previews = DesktopHoverPreviewService(root: root)
        capture = DesktopCaptureService(runtime: runtime)
        capture.attach(to: view)
        pluginCatalog = DesktopPluginCatalogTransport(sources: { [weak self] in
            guard let self else { throw CancellationError() }
            let settings = try await self.runtime.invoke("settings:get") as? [String: Any]
            var sources = settings?["pluginSources"] as? [String] ?? []
            if let raw = UserDefaults.standard.string(forKey: "marketplace.url"),
               let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                sources.append(url.appendingPathComponent("index.json").absoluteString)
            }
            return sources
        })
        recordings = DesktopRecordingService(root: runtime.legacyRoot) { [weak self] channel, request in
            guard let self else { throw CancellationError() }
            return try await self.runtime.invokePrivate(channel, request: request)
        }
        recordings.emit = { [weak self] channel, value in self?.emit(channel, value) }
        notifications = DesktopNotificationService { [weak self] channel, request in
            guard let self else { throw CancellationError() }
            return try await self.runtime.invokePrivate(channel, request: request)
        }
        fileServices = DesktopFileServices(runtime: runtime)
        fileServices.presenter = self
        account = DesktopAccountService(root: root)
        presentations = DesktopPresentationService(root: root) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.account.accessToken()
        }
        cloud = DesktopCloudService(environment: DesktopCloudEnvironment(signedIn: { [weak self] in
            guard let self else { return false }
            let state = try? await self.account.handle(channel: "auth:getState", request: [:]) as? [String: Any]
            return state?["phase"] as? String == "signed-in"
        }, credential: { [weak self] in
            guard let self else { throw CancellationError() }
            let identity = try await self.account.syncIdentity()
            return (identity, try await self.account.accessToken())
        }))
        account.emit = { [weak self] channel, value in
            if channel == "auth:changed", let state = value as? [String: Any] { self?.syncService?.accountChanged(state) }
            self?.emit(channel, value)
        }
        assets = DesktopAssets(runtime: runtime)
        let configuration = WKWebViewConfiguration()
        // Shell localStorage (selected workspace, sidebar state) survives a
        // restart, separately from all external browser profiles and cookies.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: testing ? "ED916975-26E7-4D47-B394-E082360B99CA" : "F2BE39F5-5762-4B21-AD23-26EBEF97D932")!)
        configuration.setURLSchemeHandler(assets, forURLScheme: "bandal-app")
        configuration.setURLSchemeHandler(assets, forURLScheme: "bandal-media")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bandal")
        #if DEBUG
        if testing, ProcessInfo.processInfo.arguments.contains("--desktop-gesture-diagnostics") {
            configuration.userContentController.addUserScript(WKUserScript(source: #"""
                (() => {
                  const events = []; let timer;
                  const publish = () => {
                    let status = document.getElementById('gesture-test-status');
                    if (!status) { status = document.createElement('div'); status.id = 'gesture-test-status'; status.setAttribute('role', 'status'); Object.assign(status.style, {position:'fixed',left:'0',bottom:'0',width:'1px',height:'1px',overflow:'hidden'}); document.body.append(status); }
                    status.setAttribute('aria-label', 'Gesture diagnostic: ' + JSON.stringify({touches:navigator.maxTouchPoints,touchEvents:'ontouchstart' in window,events}));
                  };
                  const record = (event, detached = false) => {
                    if (events.length >= 180) return;
                    events.push([event.type, detached, event.target?.tagName, event.target?.isConnected,
                      [...(event.changedTouches || [])].map(t=>[t.identifier,Math.round(t.clientX),Math.round(t.clientY),t.touchType]),event.pointerType,event.pointerId]);
                    clearTimeout(timer); timer = setTimeout(publish, 200);
                  };
                  for (const type of ['touchstart','touchmove','touchend','touchcancel','pointerdown','pointerup','pointercancel']) document.addEventListener(type, event => {
                    record(event);
                    if (type === 'touchstart') for (const name of ['touchmove','touchend','touchcancel']) event.target.addEventListener(name, later => { if (!later.target.isConnected) record(later, true); }, {passive:true});
                  }, {capture:true,passive:true});
                })();
                """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif
        shell = WKWebView(frame: .zero, configuration: configuration)
        shell.navigationDelegate = self
        shell.scrollView.isScrollEnabled = true
        shell.scrollView.bounces = false
        shell.scrollView.contentInsetAdjustmentBehavior = .never
        shell.isOpaque = true
        shell.backgroundColor = .systemBackground
        shell.accessibilityIdentifier = "bandal-desktop-shell"
        #if DEBUG
        shell.isInspectable = true
        #endif
        view.addSubview(shell)
        lifecycleObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flushForBackground() }
        }
        browser = DesktopBrowserHost(root: root)
        browser.attach(to: view, shell: shell)
        miniPlayer = DesktopMiniPlayer(runtime: runtime)
        miniPlayer.attach(to: view)
        miniPlayer.emit = { [weak self] channel, value in self?.emit(channel, value) }
        miniPlayer.websiteDataStore = { [weak self] source in
            guard let self else { throw CancellationError() }
            guard let tab = source["nativeTabId"] as? String, let page = self.browser.pages[tab],
                  page.webView.url?.absoluteString == source["url"] as? String else { throw DesktopRuntimeError("영상을 연 브라우저 탭이 변경되었습니다. 다시 시도해 주세요.") }
            return page.webView.configuration.websiteDataStore
        }
        browser.onLayout = { [weak self] in self?.miniPlayer.layout(); self?.capture.layout() }
        credentials.presenter = self
        credentials.profileExists = { [weak self] id in self?.browser.isProfileAvailable(id) == true }
        credentials.target = { [weak self] guest, origin in
            guard let self else { throw CancellationError() }
            return try self.browser.credentialTarget(guestID: guest, origin: origin)
        }
        credentials.capture = { [weak self] target in
            guard let self else { throw CancellationError() }
            return try await self.browser.captureLogin(target)
        }
        credentials.fill = { [weak self] target, username, password, submit in
            guard let self else { throw CancellationError() }
            return try await self.browser.fillLogin(target, username: username, password: password, autoSubmit: submit)
        }
        browser.onDeleteProfile = { [weak self] id in
            guard let self else { throw CancellationError() }
            try self.credentials.deleteProfile(id)
        }
        browser.onAgentAttachment = { [weak self] course, path in
            guard let self else { throw CancellationError() }
            let data = try await self.fileServices.readAttachment(courseID: course, relPath: path)
            let name = (path as NSString).lastPathComponent
            return (name, UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream", data)
        }
        articles.sourceTab = { [weak self] course, tab, address, script in
            guard let self else { throw CancellationError() }
            return try await self.browser.extractArticle(courseID: course, tabID: tab, expectedURL: address, script: script)
        }
        browser.emit = { [weak self] channel, value in self?.emit(channel, value) }
        browser.onDownload = { [weak self] url, courseID in
            guard let self, let courseID else { return nil }
            let staged = try self.fileStaging.copy(url)
            defer { self.fileStaging.discard(paths: [staged.path]) }
            let result = try await self.handle("materials:import", request: ["courseId": courseID, "paths": [staged.path]]) as? [String: Any]
            return (result?["imported"] as? [String])?.first
        }
        runtime.onEmit = { [weak self] channel, value in Task { @MainActor in self?.emit(channel, value) } }
        systemServices.emit = { [weak self] channel, value in self?.emit(channel, value) }
        runtime.onNativeCall = { [weak self] channel, request in
            guard let self else { throw CancellationError() }
            return try await self.handleNativeService(channel, request: request)
        }
        aiServices.onEvent = { [weak self] identifier, event in
            guard let self else { throw CancellationError() }
            _ = try await self.runtime.invokePrivate("nativeAI:event", request: ["requestId": identifier, "event": event])
        }
        aiServices.onTool = { [weak self] identifier, call in
            guard let self else { throw CancellationError() }
            let result = try await self.runtime.invokePrivate("nativeAI:tool", request: ["requestId": identifier, "call": call])
            guard let value = result as? String else { throw DesktopRuntimeError("AI 도구 결과를 확인할 수 없습니다.") }
            return value
        }
        Task {
            do {
                try await runtime.start()
                if testing, ProcessInfo.processInfo.arguments.contains("--desktop-parity-fixture") {
                    let courses = try await runtime.invoke("courses:list") as? [[String: Any]] ?? []
                    let course: [String: Any]
                    if let first = courses.first { course = first }
                    else { course = try await runtime.invoke("courses:create", request: ["name": "개발", "color": "#a78bfa"]) as? [String: Any] ?? [:] }
                    _ = try await runtime.invoke("settings:set", request: ["onboarding": ["flowVersion": 2, "closedAt": ISO8601DateFormatter().string(from: Date()), "lastCompletedStep": 4], "tutorial": ["seenVersion": 1, "activeCourseId": NSNull()], "lastActiveCourseId": course["id"] ?? NSNull()])
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--desktop-pdf-fixture"), let courseID = course["id"] as? String {
                        let folder = runtime.root.appendingPathComponent("Temporary/Imports/PDFGestureFixture", isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let source = folder.appendingPathComponent("PDF pinch fixture.pdf")
                        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
                            context.beginPage()
                            ("PDF pinch fixture" as NSString).draw(at: CGPoint(x: 60, y: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
                            ("The original PDF viewer must resize only this page." as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                            ("원본 PDF 한글 표시 검증" as NSString).draw(at: CGPoint(x: 60, y: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                        }
                        try bytes.write(to: source, options: .atomic)
                        let imported = try await runtime.invoke("materials:import", request: ["courseId": courseID, "paths": [source.path]]) as? [String: Any]
                        guard (imported?["imported"] as? [String])?.isEmpty == false else { throw DesktopRuntimeError("PDF 제스처 테스트 자료를 가져오지 못했습니다.") }
                    }
                    #endif
                }
                if let settings = try await runtime.invoke("settings:get") as? [String: Any], let preferences = settings["browser"] as? [String: Any] {
                    browser.applySettings(preferences)
                    try await browser.waitForPrivacySettings()
                }
                try await refreshBrowserShortcuts()
                shell.load(URLRequest(url: URL(string: "bandal-app://shell/index.html")!))
                if !testing {
                    notifications?.start()
                    let sync = try DesktopSyncService(runtime: runtime, account: account)
                    sync.emit = { [weak self] channel, value in self?.emit(channel, value) }
                    sync.flushOpenDocuments = { [weak self] in try await self?.flushDocuments() }
                    syncService = sync
                    sync.start()
                }
            } catch { showStartupError(error.localizedDescription) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        shell?.frame = view.bounds
        browser?.layoutPages()
        miniPlayer?.layout()
        capture?.layout()
        startupError?.frame = view.bounds.insetBy(dx: 32, dy: 32)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === shell, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "bandal-app", message.frameInfo.securityOrigin.host == "shell",
              message.frameInfo.request.url?.path == "/index.html",
              let body = message.body as? [String: Any], let channel = body["channel"] as? String else {
            replyHandler(nil, "Invalid desktop bridge origin or message"); return
        }
        let request = body["request"] as? [String: Any] ?? [:]
        guard !channel.hasPrefix("native") else { replyHandler(nil, "Private native service"); return }
        Task {
            do { replyHandler(try await handle(channel, request: request), nil) }
            catch {
                runtime.log.record("ipc.failed", channel: channel, code: (error as? DesktopRuntimeError)?.code ?? String((error as NSError).code))
                NSLog("[Desktop IPC] %@ failed: %@", channel, error.localizedDescription)
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    private func handle(_ channel: String, request: [String: Any]) async throws -> Any {
        if capture.canHandle(channel) { return try await capture.handle(channel: channel, request: request) }
        if miniPlayer.canHandle(channel) { return try await miniPlayer.handle(channel, request) }
        if credentials.canHandle(channel) { return try await credentials.handle(channel: channel, request: request) }
        if recordings.canHandle(channel) { return try await recordings.handle(channel: channel, request: request) }
        if fileServices.canHandle(channel) { return try await fileServices.handle(channel: channel, request: request) }
        if account.canHandle(channel) { return try await account.handle(channel: channel, request: request) }
        if systemServices.canHandle(channel) { return try await systemServices.handle(channel: channel, request: request) }
        if browser.canHandle(channel) { return try await browser.handle(channel: channel, request: request) }
        switch channel {
        case "settings:set":
            if let preferences = request["browser"] as? [String: Any] { try await browser.validateSettings(preferences) }
            return try await runtime.invoke(channel, request: request)
        case "runtime:syncState":
            guard let syncService else { return ["phase": "idle", "conflicts": 0, "pending": 0] }
            return try await syncService.status()
        case "runtime:syncNow":
            guard let syncService else { throw DesktopRuntimeError("동기화 서비스를 준비 중입니다.") }
            syncService.requestSync()
            return ["ok": true]
        case "runtime:syncConflicts":
            return try await syncService?.conflicts() ?? []
        case "runtime:syncRestore", "runtime:syncExport":
            guard let syncService, let identifier = request["id"] as? String else { throw DesktopRuntimeError("동기화 충돌 사본을 확인해 주세요.") }
            if channel == "runtime:syncExport" {
                return try await fileServices.handle(channel: "native:saveFile", request: syncService.exportConflict(identifier))
            }
            return try await syncService.restoreConflict(identifier, variant: request["variant"] as? String ?? "")
        case "app:clearCache":
            await browser.clearCache()
            await shell.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
            return ["ok": true]
        case "print:pdfFromUrl":
            guard let address = request["url"] as? String else { throw DesktopRuntimeError("PDF 주소를 확인해 주세요.") }
            let fetched = try await browser.fetchLinkedFile(url: address, tabID: request["tabId"] as? String)
            return ["base64": fetched.dataBase64]
        case "materials:downloadFromUrl":
            guard let address = request["url"] as? String, let courseID = request["courseId"] as? String, let directory = request["dirRelPath"] as? String else { throw DesktopRuntimeError("가져올 자료를 확인해 주세요.") }
            let fetched = try await browser.fetchLinkedFile(url: address, tabID: request["tabId"] as? String)
            return try await runtime.invoke("materials:writeFile", request: ["courseId": courseID, "dirRelPath": directory, "fileName": fetched.fileName, "encoding": "base64", "data": fetched.dataBase64])
        case "runtime:diagnostic":
            runtime.log.record("renderer.error")
            NSLog("[Desktop renderer] %@", String(describing: request).prefix(8_192).description)
            return NSNull()
        case "runtime:stageFileBegin", "runtime:stageFileWrite", "runtime:stageFileFinish", "runtime:stageFileCancel":
            return try fileStaging.handle(channel, request)
        case "materials:import", "chat:importAttachments":
            let paths = request["paths"] as? [String] ?? []
            let lease = fileStaging.beginConsumption(paths: paths)
            do {
                let result = try await runtime.invoke(channel, request: request)
                let successful: [String]
                if channel == "materials:import", let result = result as? [String: Any], let failures = result["failed"] as? [[String: Any]], let imported = result["imported"] as? [String], imported.count + failures.count == paths.count {
                    let failed = Set(failures.compactMap { $0["path"] as? String })
                    successful = paths.filter { !failed.contains($0) }
                } else if channel == "chat:importAttachments", let imported = result as? [[String: Any]], imported.count == paths.count { successful = paths }
                else { successful = [] }
                fileStaging.endConsumption(lease, successfulPaths: successful)
                return result
            } catch { fileStaging.endConsumption(lease, successfulPaths: []); throw error }
        case "window:getState": return ["fullscreen": view.window?.windowScene?.sizeRestrictions == nil]
        case "window:setPrintEnabled": printEnabled = request["enabled"] as? Bool ?? false; return ["ok": true]
        case "window:openSettings": emit("ui:openSettings", request); return NSNull()
        case "ui:consumePendingOpen": let result = pendingOpen; pendingOpen = [:]; return result
        case "agent:syncWorkspace":
            workspaceContext = request
            return try await runtime.invokePrivate("nativeAI:workspace", request: request)
        case "shell:openExternal":
            guard let address = request["url"] as? String, let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw DesktopRuntimeError("Expected an HTTP or HTTPS URL") }
            guard await UIApplication.shared.open(url) else { throw DesktopRuntimeError("Could not open the browser") }
            return ["ok": true]
        case "update:status", "update:check": return ["phase": "unsupported", "currentVersion": DesktopVersion.current]
        default: return try await runtime.invoke(channel, request: request)
        }
    }

    private func handleNativeService(_ channel: String, request: [String: Any]) async throws -> Any {
        if pluginCatalog.canHandle(channel) { return try await pluginCatalog.handle(channel: channel, request: request) }
        if previews.canHandle(channel) { return try await previews.handle(channel: channel, request: request) }
        if mcp.canHandle(channel) { return try await mcp.handle(channel: channel, request: request) }
        if cloud.canHandle(channel) { return try await cloud.handle(channel: channel, request: request) }
        if channel == "native:browserTool" {
            let result = try await browser.agentRequest(request)
            if request["tool"] as? String == "savedLogin" {
                guard let validated = result as? [String: Any], let guest = validated["guestWebContentsId"] as? Int, let origin = validated["origin"] as? String else { throw DesktopRuntimeError("로그인할 브라우저 탭을 확인하지 못했습니다.") }
                return try await credentials.fillForAgent(guestID: guest, origin: origin)
            }
            if request["tool"] as? String == "download" {
                guard let validated = result as? [String: Any] else { throw DesktopRuntimeError("브라우저 다운로드 요청을 확인하지 못했습니다.") }
                let file = try await handle("materials:downloadFromUrl", request: validated) as? [String: Any] ?? [:]
                return file.merging(["status": "ok"]) { _, new in new }
            }
            return result
        }
        if presentations.canHandle(channel) { return try await presentations.handle(channel: channel, request: request) }
        if channel == "native:learningApprovePack" {
            guard presentedViewController == nil else { throw DesktopRuntimeError("열린 창을 닫은 뒤 다시 시도해 주세요.") }
            let dialog = UIAlertController(title: request["name"] as? String ?? "학습 도구 실행", message: request["description"] as? String ?? "가져온 학습 도구의 실행을 허용할까요?", preferredStyle: .alert)
            return await withCheckedContinuation { continuation in
                for (index, title) in ["취소", "한 번 허용", "항상 허용"].enumerated() {
                    dialog.addAction(UIAlertAction(title: title, style: index == 0 ? .cancel : .default) { _ in continuation.resume(returning: ["response": index]) })
                }
                present(dialog, animated: true)
            }
        }
        if channel == "native:learningDictionary" { return await dictionary.lookup(request["text"] as? String ?? "") }
        if channel == "native:learningExtract" { return try await articles.extract(request) }
        if fileServices.canHandle(channel) { return try await fileServices.handle(channel: channel, request: request) }
        if aiServices.canHandle(channel) { return try await aiServices.handle(channel: channel, request: request) }
        if mailServices.canHandle(channel) { return try await mailServices.handle(channel: channel, request: request) }
        guard systemServices.canHandle(channel) else { throw DesktopRuntimeError("Native service is not implemented: \(channel)", code: "ENOSYS") }
        return try await systemServices.handle(channel: channel, request: request)
    }

    func emit(_ channel: String, _ payload: Any) {
        miniPlayer?.receive(channel, payload)
        capture?.layout()
        notifications?.receive(channel, payload)
        if channel == "settings:changed", let event = payload as? [String: Any], let settings = event["settings"] as? [String: Any], let preferences = settings["browser"] as? [String: Any] { browser?.applySettings(preferences) }
        if channel == "settings:changed" {
            Task { [weak self] in
                do { try await self?.refreshBrowserShortcuts() }
                catch { self?.runtime.log.record("browser.shortcuts.failed") }
            }
        }
        shell?.callAsyncJavaScript("window.__bandalReceive?.(channel, payload)", arguments: ["channel": channel, "payload": payload], in: nil, in: .page) { result in
            if case .failure(let error) = result { NSLog("[Desktop push] %@: %@", channel, error.localizedDescription) }
        }
    }

    private func refreshBrowserShortcuts() async throws {
        shortcutRevision += 1
        let revision = shortcutRevision
        browser.applyShortcuts([])
        let shortcuts = try await runtime.invokePrivate("nativeBrowser:shortcuts") as? [[String: Any]] ?? []
        guard revision == shortcutRevision else { return }
        browser.applyShortcuts(shortcuts)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let local = url.scheme == "bandal-app" && url.host == "shell" && url.path == "/index.html"
        if local { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            emit("ui:openUrl", ["url": url.absoluteString])
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showStartupError(error.localizedDescription) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fileStaging.cancelUnfinished()
        runtime.log.record("renderer.processTerminated")
        Task { await recordings.interruptForLifecycle(); webView.reload() }
    }

    private func flushDocuments() async throws {
        let result = try await shell.callAsyncJavaScript("""
        if (typeof window.__bandalFlushNative !== 'function') return {ok:false,pending:[]};
        return await window.__bandalFlushNative();
        """, arguments: [:], in: nil, contentWorld: .page)
        guard let value = result as? [String: Any], value["ok"] as? Bool == true else { throw DesktopRuntimeError("열린 필기의 저장을 완료하지 못해 동기화를 기다립니다.") }
    }

    private func flushForBackground() {
        guard flushTask == nil else { return }
        saveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save open Bandal documents") { [weak self] in
            self?.flushTask?.cancel()
            self?.finishBackgroundSave()
        }
        flushTask = Task { [weak self] in
            guard let self else { return }
            defer { self.flushTask = nil; self.finishBackgroundSave() }
            do { try await self.flushDocuments() }
            catch { NSLog("[Desktop lifecycle] Could not finish document save: %@", error.localizedDescription) }
        }
    }

    private func finishBackgroundSave() {
        guard saveBackgroundTask != .invalid else { return }
        let identifier = saveBackgroundTask; saveBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    deinit {
        if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) }
        flushTask?.cancel()
    }

    private func showStartupError(_ message: String) {
        let label = startupError ?? UILabel()
        label.numberOfLines = 0
        label.text = "반달을 열지 못했습니다\n\n" + message
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.backgroundColor = .systemBackground
        startupError = label
        view.addSubview(label)
        view.setNeedsLayout()
    }
}

@MainActor
final class DesktopAssets: NSObject, WKURLSchemeHandler {
    private let runtime: DesktopRuntime
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(runtime: DesktopRuntime) { self.runtime = runtime }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        pending[identifier] = Task {
            do {
                guard let url = urlSchemeTask.request.url else { throw URLError(.badURL) }
                let data: Data
                let fileExtension: String
                if url.scheme == "bandal-app", url.host == "shell", let root = Bundle.main.resourceURL?.appendingPathComponent("Desktop") {
                    let path = String(url.path.drop(while: { $0 == "/" }))
                    let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                    guard target.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), target.lastPathComponent != "backend.js" else { throw URLError(.noPermissionsToReadFile) }
                    data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: target) }.value
                    fileExtension = target.pathExtension
                } else if url.scheme == "bandal-media", url.host == "material" {
                    let components = url.pathComponents.filter { $0 != "/" }
                    guard let courseID = components.first, components.count >= 2 else { throw URLError(.badURL) }
                    let relative = components.dropFirst().joined(separator: "/")
                    try await sendMaterial(courseID: courseID, relative: relative, task: urlSchemeTask, identifier: identifier)
                    return
                } else { throw URLError(.noPermissionsToReadFile) }
                guard !Task.isCancelled, pending.removeValue(forKey: identifier) != nil else { return }
                let mime: String
                switch fileExtension {
                case "js", "mjs": mime = "text/javascript"
                case "css": mime = "text/css"
                case "html": mime = "text/html"
                case "wasm": mime = "application/wasm"
                default: mime = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
                }
                var headers = ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "bandal-app://shell", "Accept-Ranges": "bytes"]
                var status = 200
                var responseData = data
                if let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                    let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    if bounds.count == 2, let lower = Int(bounds[0]), lower >= 0, lower < data.count {
                        let upper = min(Int(bounds[1]) ?? data.count - 1, data.count - 1)
                        if upper >= lower {
                            responseData = data.subdata(in: lower..<(upper + 1)); status = 206
                            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(data.count)"
                            headers["Content-Length"] = String(responseData.count)
                        }
                    }
                }
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(responseData)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled, pending.removeValue(forKey: identifier) != nil { urlSchemeTask.didFailWithError(error) }
            }
        }
    }

    private func sendMaterial(courseID: String, relative: String, task: WKURLSchemeTask, identifier: ObjectIdentifier) async throws {
        guard let path = try await runtime.invokePrivate("nativeMaterial:path", request: ["courseId": courseID, "relPath": relative]) as? String,
              let url = task.request.url else { throw URLError(.fileDoesNotExist) }
        let root = runtime.root
        let file = try await Task.detached(priority: .userInitiated) { try DesktopMaterialFile(path: path, root: root) }.value
        let selection = DesktopMaterialFile.selection(size: file.size, range: task.request.value(forHTTPHeaderField: "Range"))
        let mime = UTType(filenameExtension: (relative as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Content-Type": mime, "Content-Length": String(selection.length), "Access-Control-Allow-Origin": "bandal-app://shell", "Accept-Ranges": "bytes"]
        if let range = selection.contentRange { headers["Content-Range"] = range }
        try Task.checkCancellation()
        guard pending[identifier] != nil, let response = HTTPURLResponse(url: url, statusCode: selection.status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        if task.request.httpMethod != "HEAD", selection.status != 416 {
            var offset = selection.offset, remaining = selection.length
            while remaining > 0 {
                try Task.checkCancellation()
                let position = UInt64(offset), count = Int(min(256 * 1024, remaining))
                let chunk = try await Task.detached(priority: .userInitiated) { try file.read(offset: position, count: count) }.value
                try Task.checkCancellation()
                guard pending[identifier] != nil else { return }
                guard !chunk.isEmpty else { throw URLError(.cannotDecodeRawData) }
                task.didReceive(chunk); offset += Int64(chunk.count); remaining -= Int64(chunk.count)
            }
        }
        if pending.removeValue(forKey: identifier) != nil { task.didFinish() }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
}
