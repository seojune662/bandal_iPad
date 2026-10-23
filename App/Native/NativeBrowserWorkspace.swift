import Combine
import CryptoKit
import SwiftUI
import WebKit

struct NativeBrowserTab: Codable, Identifiable {
    let id: String
    let profileID: String
    let isPrivate: Bool
    var title: String
    var url: String
    var loading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
}

struct NativeBrowserScopeClosePlan {
    let workspaceID: String?
    fileprivate let pages: [String: Int]
    fileprivate let stateURL: URL
}

@MainActor
final class NativeBrowserSession: ObservableObject {
    private final class WeakSession { weak var value: NativeBrowserSession?; init(_ value: NativeBrowserSession) { self.value = value } }
    private static var sessions: [String: WeakSession] = [:]
    let host: DesktopBrowserHost
    let store: NativeWorkspaceStore
    @Published var tabs: [NativeBrowserTab] = []
    @Published var activeID: String?
    @Published var error: String?
    @Published var busy = false
    @Published var profiles: [[String: String]] = []
    private var subscriptions = Set<AnyCancellable>()
    private var loaded = false
    private var navigatingPending = false
    private var ready = false
    private(set) var retired = false
    private var lastOuterTitle: String?
    @Published var preferences: [String: Any] = [:]
    @Published var favorites: [NativeSidebarFavorite] = []
    @Published var downloadItems: [NativeBrowserDownloadItem] = []
    @Published var findStates: [String: NativeBrowserFindState] = [:]
    @Published var zoomLevels: [String: Double] = [:]
    @Published var sessionChanging = false
    var findTasks: [String: Task<Void, Never>] = [:]
    var favoriteRequest = UUID()
    var profileRequest = UUID()
    let workspaceID: String?
    let courseID: String?
    var effectiveCourseID: String? { courseID ?? store.selectedCourseID }
    private var scopeKey: String { workspaceID ?? "global" }
    static func scopePrefix(_ workspaceID: String?) -> String {
        guard let workspaceID else { return "" }
        let digest = SHA256.hash(data: Data(workspaceID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "native-scope." + digest + "."
    }
    func owns(_ id: String) -> Bool { Self.owns(id, workspaceID: workspaceID) }
    static func owns(_ id: String, workspaceID: String?) -> Bool {
        workspaceID == nil ? !id.hasPrefix("native-scope.") : id.hasPrefix(scopePrefix(workspaceID))
    }
    private struct Saved: Codable { let tabs: [NativeBrowserTab]; let activeID: String? }
    private var saveURL: URL { Self.stateURL(workspaceID: workspaceID, store: store) }
    private static func stateURL(workspaceID: String?, store: NativeWorkspaceStore) -> URL {
        store.root.appendingPathComponent(workspaceID == nil ? "native-browser-tabs.json" : "native-browser-tabs-" + scopePrefix(workspaceID).replacingOccurrences(of: ".", with: "-") + ".json")
    }
    static func currentPage(workspaceID: String, store: NativeWorkspaceStore, host: DesktopBrowserHost) -> NativeBrowserTab? {
        let key = stateURL(workspaceID: workspaceID, store: store).path
        if let session = sessions[key]?.value {
            guard !session.retired, let active = session.active, !active.isPrivate else { return nil }
            return host.pages[active.id].map(tab) ?? active
        }
        guard let data = try? Data(contentsOf: stateURL(workspaceID: workspaceID, store: store)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let active = saved.tabs.first(where: { $0.id == saved.activeID }), !active.isPrivate else { return nil }
        if let live = host.pages[active.id] { return live.isPrivate ? nil : tab(live) }
        return active
    }
    static func currentPage(workspaceID: String, store: NativeWorkspaceStore) -> NativeBrowserTab? {
        if let session = sessions[stateURL(workspaceID: workspaceID, store: store).path]?.value {
            return currentPage(workspaceID: workspaceID, store: store, host: session.host)
        }
        guard let data = try? Data(contentsOf: stateURL(workspaceID: workspaceID, store: store)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let active = saved.tabs.first(where: { $0.id == saved.activeID }), !active.isPrivate else { return nil }
        return active
    }
    /// Preparation never destroys a page or changes the saved scope. A batch
    /// caller collects every plan before committing any document closure.
    static func prepareScope(workspaceID: String?, host: DesktopBrowserHost, store: NativeWorkspaceStore,
        approve: ((String) async throws -> Bool)? = nil) async throws -> NativeBrowserScopeClosePlan? {
        let pages = host.pages.filter { owns($0.key, workspaceID: workspaceID) }.mapValues(\.id)
        for id in pages.keys.sorted() {
            let allowed: Bool
            if let approve { allowed = try await approve(id) }
            else { allowed = (try await host.handle(channel: "browser:prepareClose", request: ["tabId": id]) as? [String: Any])?["allowed"] as? Bool == true }
            if !allowed { return nil }
        }
        return NativeBrowserScopeClosePlan(workspaceID: workspaceID, pages: pages, stateURL: stateURL(workspaceID: workspaceID, store: store))
    }
    /// All state files are staged before the synchronous page destruction. A
    /// filesystem failure rolls back the staging without closing any browser.
    /// A changed page set invalidates the plans and requires new confirmation.
    static func commitScopes(_ plans: [NativeBrowserScopeClosePlan], host: DesktopBrowserHost, store: NativeWorkspaceStore) throws -> Bool {
        let manager = FileManager.default
        var scopes = Set<String>()
        let unique = plans.filter { scopes.insert($0.workspaceID ?? "global").inserted }
        for plan in unique {
            guard plan.stateURL == stateURL(workspaceID: plan.workspaceID, store: store),
                  host.pages.filter({ owns($0.key, workspaceID: plan.workspaceID) }).mapValues(\.id) == plan.pages else { return false }
        }
        var staged: [(URL, URL)] = []
        do {
            for plan in unique where manager.fileExists(atPath: plan.stateURL.path) {
                let temporary = plan.stateURL.appendingPathExtension("closing-" + UUID().uuidString)
                try manager.moveItem(at: plan.stateURL, to: temporary)
                staged.append((plan.stateURL, temporary))
            }
        } catch {
            var rollbackFailed = false
            for (original, temporary) in staged.reversed() {
                do { try manager.moveItem(at: temporary, to: original) } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw DesktopRuntimeError("브라우저 탭을 닫지 못했습니다. 저장된 탭의 복구 파일은 기기에 보존되어 있습니다.") }
            throw error
        }
        for plan in unique {
            for id in plan.pages.keys { host.destroy(id) }
            store.pendingBrowserURLs.removeValue(forKey: plan.workspaceID ?? "global")
            store.events.send(.init(channel: "nativeBrowser:scopeClosed", payload: ["workspaceID": plan.workspaceID ?? "global"]))
        }
        for (_, temporary) in staged { try? manager.removeItem(at: temporary) }
        host.layoutPages()
        return true
    }
    var active: NativeBrowserTab? { tabs.first { $0.id == activeID } }
    init(store: NativeWorkspaceStore, host: DesktopBrowserHost, workspaceID: String? = nil, courseID: String? = nil) {
        self.store = store; self.host = host; self.workspaceID = workspaceID; self.courseID = courseID
        Self.sessions[Self.stateURL(workspaceID: workspaceID, store: store).path] = WeakSession(self)
        store.events.sink { [weak self] event in self?.receive(event) }.store(in: &subscriptions)
        store.$pendingBrowserURLs.sink { [weak self] values in
            guard let self, values[self.scopeKey] != nil, self.loaded else { return }
            Task { @MainActor [weak self] in await self?.consumePendingURL() }
        }.store(in: &subscriptions)
    }
    func start() async {
        guard !loaded, !retired else { return }; loaded = true; busy = true
        defer { busy = false }
        do {
            preferences = try await store.invoke("settings:get") as? [String: Any] ?? [:]
            try await reloadProfiles()
            guard !retired else { throw CancellationError() }
            if host.pages.keys.contains(where: owns) {
                tabs = host.pages.values.filter { owns($0.tabID) }.sorted { $0.id < $1.id }.map(Self.tab)
                if let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) { activeID = saved.activeID }
            } else if FileManager.default.fileExists(atPath: saveURL.path) {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: saveURL))
                // A private browsing session is intentionally never restored.
                for tab in saved.tabs where !tab.isPrivate && owns(tab.id) && host.isProfileAvailable(tab.profileID) {
                    guard !retired else { throw CancellationError() }
                    _ = try await host.handle(channel: "browser:createPage", request: ["tabId": tab.id, "profileId": tab.profileID, "courseId": effectiveCourseID as Any? ?? NSNull()])
                    guard !retired else { host.destroy(tab.id); throw CancellationError() }
                    let url = tab.url == "about:blank" && tab.title.isEmpty ? newTabURL(isPrivate: false) : tab.url
                    if url != "about:blank" { _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": tab.id, "action": "loadURL", "args": [url]]) }
                }
                tabs = host.pages.values.filter { owns($0.tabID) }.sorted { $0.id < $1.id }.map(Self.tab)
                activeID = saved.activeID
            }
            if tabs.isEmpty { try await add(initialURL: store.pendingBrowserURLs[scopeKey] == nil ? nil : "about:blank") }
            if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs.first?.id }
            guard !retired else { throw CancellationError() }
            ready = true
            await reloadFeatures()
            publishOuterTitle()
            await consumePendingURL()
            #if DEBUG
            if let id = activeID { await loadUITestFixture(id: id) }
            #endif
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func add(profileID: String? = nil, isPrivate: Bool = false, initialURL: String? = nil) async throws -> String {
        guard !retired else { throw CancellationError() }
        let id = Self.scopePrefix(workspaceID) + UUID().uuidString
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": id, "profileId": profileID ?? active?.profileID ?? "default", "isPrivate": isPrivate, "courseId": effectiveCourseID as Any? ?? NSNull()])
        guard !retired else { host.destroy(id); throw CancellationError() }
        if let page = host.pages[id] {
            tabs.append(Self.tab(page)); activeID = id
            publishOuterTitle()
            let browser = preferences["browser"] as? [String: Any] ?? [:]
            let zoom = (browser["defaultZoomLevel"] as? NSNumber)?.doubleValue ?? 0
            if zoom != 0 { _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": id, "action": "setZoomLevel", "args": [zoom]]) }
            let target = initialURL ?? newTabURL(isPrivate: isPrivate)
            if target != "about:blank" {
                try await action("loadURL", args: [target], tabID: id)
            }
            try save()
        }
        return id
    }
    private func newTabURL(isPrivate: Bool) -> String {
        #if DEBUG
        // Local browser UI fixtures must never race an unrelated remote page.
        if ProcessInfo.processInfo.arguments.contains("--native-browser-ui-fixture") { return "about:blank" }
        #endif
        return NativeBrowserAddress.newTabURL(preferences: preferences, isPrivate: isPrivate)
    }
    func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        publishOuterTitle()
        do { try save() } catch { self.error = error.localizedDescription }
    }
    func close(_ id: String) async throws {
        let check = try await host.handle(channel: "browser:prepareClose", request: ["tabId": id]) as? [String: Any]
        guard check?["allowed"] as? Bool == true else { return }
        _ = try await host.handle(channel: "browser:destroyPage", request: ["tabId": id])
        tabs.removeAll { $0.id == id }
        if activeID == id { activeID = tabs.last?.id }
        publishOuterTitle()
        try save()
    }
    func navigate(_ address: String) async throws {
        guard !retired else { throw CancellationError() }
        let url = try Self.addressURL(address, searchEngine: preferences["browserSearchEngine"] as? String ?? "google")
        if activeID == nil { try await add(initialURL: "about:blank") }
        try await action("loadURL", args: [url.absoluteString])
    }
    static func addressURL(_ text: String, searchEngine: String = "google") throws -> URL {
        try NativeBrowserAddress.resolve(text, engine: searchEngine)
    }
    func action(_ action: String, args: [Any] = [], tabID: String? = nil) async throws {
        guard !retired, let id = tabID ?? activeID, owns(id), host.pages[id] != nil else { return }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": id, "action": action, "args": args])
        refresh(id)
    }
    func refresh(_ id: String) {
        guard owns(id), let page = host.pages[id] else { return }
        let tab = Self.tab(page)
        zoomLevels[id] = (page.state["zoomLevel"] as? NSNumber)?.doubleValue ?? log(Double(page.liveWebView?.pageZoom ?? 1)) / log(1.2)
        if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index] = tab }
        else { tabs.append(tab) }
        if activeID == id { publishOuterTitle() }
    }
    private func publishOuterTitle() {
        guard let workspaceID, !retired else { return }
        let title: String
        if active?.isPrivate == true { title = "개인정보 보호 브라우저" }
        else if let value = active?.title.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { title = String(value.prefix(100)) }
        else if let value = active?.url, let host = URL(string: value)?.host { title = host }
        else { title = "브라우저" }
        guard title != lastOuterTitle else { return }; lastOuterTitle = title
        store.events.send(.init(channel: "nativeWorkspace:updateToolTitle", payload: ["workspaceID": workspaceID, "title": title]))
    }
    private static func tab(_ page: DesktopBrowserPage) -> NativeBrowserTab {
        let state = page.state
        return NativeBrowserTab(id: page.tabID, profileID: page.profileID, isPrivate: page.isPrivate,
            title: state["title"] as? String ?? "", url: state["url"] as? String ?? "about:blank",
            loading: state["loading"] as? Bool ?? false, progress: (state["estimatedProgress"] as? NSNumber)?.doubleValue ?? 0,
            canGoBack: state["canGoBack"] as? Bool ?? false, canGoForward: state["canGoForward"] as? Bool ?? false)
    }
    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "nativeBrowser:scopeClosed", let payload = event.payload as? [String: String], payload["workspaceID"] == scopeKey {
            retired = true; ready = false; findTasks.values.forEach { $0.cancel() }; findTasks.removeAll(); tabs = []; activeID = nil; return
        }
        guard !retired else { return }
        receiveFeatureEvent(event)
        if event.channel == "nativeBrowser:scopeAction", let payload = event.payload as? [String: String], payload["workspaceID"] == scopeKey, payload["action"] == "reload" {
            Task { do { try await action("reload") } catch { self.error = error.localizedDescription } }; return
        }
        if event.channel == "settings:changed", let value = event.payload as? [String: Any] { preferences = value["settings"] as? [String: Any] ?? value; return }
        guard event.channel.hasPrefix("browser:"), let payload = event.payload as? [String: Any] else { return }
        if event.channel == "browser:page-event", let id = payload["tabId"] as? String, owns(id) {
            refresh(id)
            let name = payload["name"] as? String
            if name == "did-fail-load", id == activeID {
                let detail = payload["detail"] as? [String: Any]
                error = detail?["errorDescription"] as? String ?? detail?["message"] as? String ?? "페이지를 불러오지 못했습니다. 주소와 연결을 확인하세요."
            }
            if name == "did-navigate" || name == "did-navigate-in-page" {
                if id == activeID { error = nil }
                do { try save() } catch { self.error = error.localizedDescription }
                if let page = host.pages[id], !page.isPrivate, let tab = tabs.first(where: { $0.id == id }), tab.url != "about:blank" {
                    Task {
                        do { _ = try await host.handle(channel: "browser:recordVisit", request: ["profileId": tab.profileID, "url": tab.url, "title": tab.title, "courseId": page.courseID as Any? ?? NSNull()]) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        } else if event.channel == "browser:open-url", let id = payload["tabId"] as? String, owns(id), (payload["openerTabId"] as? String).map(owns) ?? true { refresh(id); select(id) }
        else if event.channel == "browser:close-tab", let id = payload["tabId"] as? String, owns(id) {
            tabs.removeAll { $0.id == id }; if activeID == id { activeID = tabs.last?.id }
            publishOuterTitle()
            do { try save() } catch { self.error = error.localizedDescription }
        } else if event.channel == "browser:external-scheme", let id = payload["tabId"] as? String, owns(id) { error = payload["reason"] as? String }
    }
    private func consumePendingURL() async {
        guard !navigatingPending, ready else { return }
        navigatingPending = true
        defer { navigatingPending = false }
        while let value = store.pendingBrowserURLs[scopeKey] {
            do {
                try await navigate(value)
                if store.pendingBrowserURLs[scopeKey] == value { store.pendingBrowserURLs.removeValue(forKey: scopeKey) }
            } catch { self.error = error.localizedDescription; return }
        }
    }
    func save() throws {
        guard !retired else { return }
        let regular = tabs.filter { !$0.isPrivate }
        let saved = Saved(tabs: regular, activeID: regular.contains(where: { $0.id == activeID }) ? activeID : regular.first?.id)
        try JSONEncoder().encode(saved).write(to: saveURL, options: .atomic)
    }
}

struct NativeBrowserWorkspace: View {
    @ObservedObject private var annotation: NativeAnnotationCoordinator
    @State private var annotationRegionMode = true
    @State private var annotationBusy = false
    @State private var annotationPageID: String?
    @ObservedObject var store: NativeWorkspaceStore
    @StateObject private var session: NativeBrowserSession
    @State private var address = ""
    @State private var addressFocused = false
    @State private var addressHistory: [NativeBrowserLink] = []
    @State private var suggestionSelection = NativeBrowserSuggestionSelection()
    @State private var showingHistory = false
    @State private var showingProfile = false
    @State private var pendingProfile: (id: String, tabID: String, isPrivate: Bool)?
    @State private var workspaceHeight: CGFloat = 440
    @State private var showingDownloads = false
    @State private var credentialContext: NativeBrowserCredentialContext?
    @State private var pendingDownloadAction: (NativeBrowserDownloadItem, String)?
    init(store: NativeWorkspaceStore, host: DesktopBrowserHost, workspaceID: String? = nil, courseID: String? = nil) {
        self.store = store; _annotation = ObservedObject(wrappedValue: store.annotation); _session = StateObject(wrappedValue: NativeBrowserSession(store: store, host: host, workspaceID: workspaceID, courseID: courseID))
    }
    var body: some View {
        VStack(spacing: 0) {
            if session.workspaceID == nil || session.tabs.count > 1 { tabs }
            GeometryReader { geometry in toolbar(width: geometry.size.width) }.frame(height: 44).zIndex(3)
            if !session.favoriteLinks.isEmpty && !addressFocused { bookmarks }
            if let error = session.error {
                HStack { NativeToolError(message: error); Button("닫기", systemImage: "xmark") { session.error = nil }.buttonStyle(NativeBrowserIconStyle()) }
            }
            if session.findState.visible { NativeBrowserFindBar(session: session) }
            if annotationRequest != nil {
                NativeAnnotationToolbar(coordinator: annotation, regionMode: $annotationRegionMode,
                    supportsElement: true, busy: annotationBusy, attachText: { captureAnnotation() })
            }
            page
        }.background(NativeDesktopTheme.bgApp).foregroundStyle(NativeDesktopTheme.text)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { workspaceHeight = $0 }
        .sheet(item: $credentialContext) { context in NativeBrowserCredentialsPanel(session: session, context: context) }
        .sheet(isPresented: $showingHistory) { NativeBrowserHistoryPanel(session: session, navigate: navigate) }
        .sheet(isPresented: $showingDownloads, onDismiss: finishDownloadPresentation) {
            NativeBrowserDownloadsPanel(session: session) { item, action in
                if ["open", "saveAs", "reveal"].contains(action) { pendingDownloadAction = (item, action); showingDownloads = false }
                else { perform { try await session.downloadAction(item, action: action) } }
            }
        }
        .sheet(isPresented: $showingProfile, onDismiss: finishProfileCreation) {
            NativeNameSheet(title: "새 브라우저 프로필", prompt: "프로필 이름", initialValue: "", actionTitle: "만들기") { name in
                guard let source = session.active else { return }
                let profile = try await session.host.handle(channel: "browser:saveProfile", request: ["name": name, "color": "blue", "icon": "person"]) as? [String: String]
                if let profile, let id = profile["id"] {
                    try await session.reloadProfiles()
                    pendingProfile = (id, source.id, source.isPrivate)
                }
            }
        }
        .task { await session.start(); updateAddress() }
        .task(id: addressHistoryKey) { await loadAddressHistory() }
        .onChange(of: addressFocused) { _, focused in
            if focused { address = session.active?.url == "about:blank" ? "" : session.active?.url ?? ""; suggestionSelection = .init() }
            else { updateAddress() }
        }
        .onChange(of: address) { _, _ in suggestionSelection = .init() }
        .onReceive(annotation.$request) { request in
            guard request?.documentID == annotationDocumentID else { annotationPageID = nil; return }
            annotationPageID = session.activeID; annotationRegionMode = true; addressFocused = false
        }
        .onChange(of: session.activeID) { _, _ in
            if annotationRequest != nil { annotation.cancel() }
            addressFocused = false; updateAddress() }
        .onChange(of: session.active?.url) { _, _ in if !addressFocused { updateAddress() } }
        .onReceive(store.events) { event in
            guard event.channel == "shortcut:passthrough", let p = event.payload as? [String: Any],
                  let active = session.activeID, let page = session.host.pages[active],
                  (p["webContentsId"] as? NSNumber)?.intValue == page.id, let action = p["action"] as? String else { return }
            shortcut(action)
        }
    }
    private var annotationDocumentID: String {
        guard let workspaceID = session.workspaceID else { return "browser" }
        return (session.courseID ?? "") + ":" + workspaceID
    }
    private var annotationRequest: NativeAnnotationCoordinator.Request? {
        annotation.request?.documentID == annotationDocumentID ? annotation.request : nil
    }
    private func captureAnnotation(bounds: CGRect? = nil, element: CGPoint? = nil) {
        guard let request = annotationRequest, !annotationBusy,
              let id = annotationPageID ?? session.activeID, let page = session.host.pages[id],
              let webView = page.liveWebView else { return }
        annotationBusy = true
        let documentID = page.state["authDocumentId"] as? String
        let capturedURL = webView.url?.absoluteString
        let sourceURL = capturedURL ?? session.active?.url
        let title = webView.title ?? session.active?.title ?? "웹 자료"
        Task { @MainActor in
            defer { annotationBusy = false }
            do {
                let script: String
                if let element {
                    // DOM content is quoted data. Form field values (including passwords) are never read.
                    script = """
                    (() => {
                      const e = document.elementFromPoint(\(element.x) * innerWidth, \(element.y) * innerHeight);
                      if (!e) return null;
                      const r = e.getBoundingClientRect();
                      return {text: (e.innerText || e.textContent || '').slice(0, 16000), x:r.x/innerWidth, y:r.y/innerHeight, width:r.width/innerWidth, height:r.height/innerHeight};
                    })()
                    """
                } else { script = bounds == nil ? "({text: String(window.getSelection() || '').slice(0, 16000)})" : "({text: ''})" }
                let result = try await webView.evaluateJavaScript(script) as? [String: Any] ?? [:]
                guard page.state["authDocumentId"] as? String == documentID, webView.url?.absoluteString == capturedURL else {
                    throw DesktopRuntimeError("웹페이지가 바뀌었습니다. 새 페이지에서 다시 선택해 주세요.")
                }
                let text = (result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var region = bounds
                if element != nil, let x = result["x"] as? Double, let y = result["y"] as? Double,
                   let width = result["width"] as? Double, let height = result["height"] as? Double {
                    region = CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                var dataURL: String?
                if let region, !region.isNull, region.width > 0, region.height > 0 {
                    let config = WKSnapshotConfiguration()
                    config.rect = CGRect(x: region.minX * webView.bounds.width, y: region.minY * webView.bounds.height,
                                         width: region.width * webView.bounds.width, height: region.height * webView.bounds.height)
                    config.snapshotWidth = NSNumber(value: Double(min(1600, config.rect.width * 2)))
                    dataURL = NativeAssistantAttachment.dataURL(try await webView.takeSnapshot(configuration: config))
                }
                guard !text.isEmpty || dataURL != nil else { throw DesktopRuntimeError("먼저 웹페이지의 텍스트나 영역을 선택해 주세요.") }
                guard page.state["authDocumentId"] as? String == documentID, webView.url?.absoluteString == capturedURL else {
                    throw DesktopRuntimeError("웹페이지가 바뀌었습니다. 새 페이지에서 다시 선택해 주세요.")
                }
                annotation.complete(.init(title: title, text: text.isEmpty ? nil : text, imageDataURL: dataURL,
                    courseID: session.effectiveCourseID, url: sourceURL, revision: documentID), requestID: request.id)
            } catch { annotation.fail(error.localizedDescription, requestID: request.id) }
        }
    }
    private var tabs: some View {
        NativeBrowserTabStrip(tabs: session.tabs, activeID: session.activeID, select: session.select,
            close: { id in perform { try await session.close(id) } }, add: { perform { try await session.add() } })
    }
    private func toolbar(width: CGFloat) -> some View {
        let expanded = width >= 650
        return HStack(spacing: 0) {
            Button("뒤로", systemImage: "arrow.left") { perform { try await session.action("goBack") } }
                .disabled(session.active?.canGoBack != true).accessibilityIdentifier("native-browser-back")
            if width >= 400 {
                Button("앞으로", systemImage: "arrow.right") { perform { try await session.action("goForward") } }
                    .disabled(session.active?.canGoForward != true).accessibilityIdentifier("native-browser-forward")
            }
            reloadButton
            if expanded {
                Button("홈", systemImage: "house") { perform { try await session.home() } }.accessibilityIdentifier("native-browser-home")
            }
            addressBar
            if expanded {
                Button(session.activeFavorite == nil ? "즐겨찾기 추가" : "즐겨찾기 해제", systemImage: session.activeFavorite == nil ? "star" : "star.fill") { perform { try await session.toggleFavorite() } }
                    .disabled(session.active?.isPrivate == true || session.active?.url == "about:blank").accessibilityIdentifier("native-browser-favorite")
                if !session.visibleDownloads.isEmpty { downloadButton() }
            }
            if addressFocused {
                Button("주소 입력 닫기", systemImage: "xmark") { addressFocused = false }.accessibilityIdentifier("native-browser-address-cancel")
            } else {
                if width >= 400 { profileMenu(expanded: width >= 850) }
                browserMenu
            }
        }.buttonStyle(NativeBrowserIconStyle()).padding(.horizontal, 4).background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .overlay(alignment: .bottom) {
                if session.active?.loading == true {
                    ProgressView(value: session.active?.progress ?? 0).tint(NativeDesktopTheme.accent).frame(height: 2)
                }
            }
            .disabled(session.sessionChanging)
    }
    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: session.active?.isPrivate == true ? "hand.raised" : session.active?.url.hasPrefix("https:") == true ? "lock" : "globe")
                .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            NativeBrowserAddressField(text: $address, focused: $addressFocused, onSubmit: submitAddress, onEscape: { addressFocused = false }, onMove: moveSuggestion)
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            if !addressFocused && abs(session.zoomLevel - session.defaultZoom) > 0.01 {
                Button("\(session.zoomPercent)%") { perform { try await session.zoom(nil) } }
                    .font(.system(size: 11).monospacedDigit()).buttonStyle(.plain).frame(minHeight: 32).fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("확대율 \(session.zoomPercent)퍼센트, 기본 크기로 복원").accessibilityIdentifier("native-browser-zoom-reset")
            }
        }.padding(.horizontal, 12).frame(height: 32).background(NativeDesktopTheme.bgApp, in: Capsule())
            .overlay(Capsule().strokeBorder(addressFocused ? NativeDesktopTheme.secondary : NativeDesktopTheme.border))
            .overlay(alignment: .topLeading) {
                if addressFocused && !suggestions.isEmpty { suggestionList.offset(y: 38) }
            }
    }
    private var suggestionIndex: Int { suggestionSelection.index(in: suggestions) }
    private var suggestions: [NativeBrowserSuggestion] { session.suggestions(address, history: addressHistory) }
    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                        Button { navigate(item.url) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol).frame(width: 16).foregroundStyle(NativeDesktopTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                                    Text(item.source + " · " + NativeBrowserAddress.display(item.url)).font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.horizontal, 10).frame(minHeight: 50).background(index == suggestionIndex ? NativeDesktopTheme.raised : NativeDesktopTheme.overlay)
                        }.buttonStyle(.plain).accessibilityIdentifier("native-browser-suggestion-\(index)").id(index)
                    }
                }
            }.frame(height: suggestionHeight)
                .onChange(of: suggestionIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                .onChange(of: suggestions.map(\.id)) { _, _ in proxy.scrollTo(suggestionIndex, anchor: .center) }
        }.clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NativeDesktopTheme.border))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
    private var suggestionHeight: CGFloat {
        let tabHeight: CGFloat = session.workspaceID == nil || session.tabs.count > 1 ? 44 : 0
        return min(CGFloat(suggestions.count) * 50, max(50, workspaceHeight - tabHeight - 54))
    }
    private var bookmarks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !session.schoolLinks.isEmpty { schoolLinksMenu }
                ForEach(session.favoriteLinks) { link in
                    Button { navigate(link.url) } label: { Label(link.title, systemImage: "star").font(.system(size: 11)).lineLimit(1).frame(maxWidth: 170).padding(.horizontal, 8).frame(height: 32) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 8)
        }.background(NativeDesktopTheme.surface)
    }
    @ViewBuilder private var page: some View {
        if session.activeID != nil {
            NativeBrowserSurface(host: session.host, selectedID: session.activeID)
                .overlay {
                    if annotationRequest != nil, annotationRegionMode {
                        NativeAnnotationRegionOverlay(selected: { captureAnnotation(bounds: $0) }, tapped: { captureAnnotation(element: $0) })
                            .allowsHitTesting(!annotationBusy)
                    }
                }
                .overlay { if session.active?.url == "about:blank", session.active?.title.isEmpty == true { NativeBrowserStartPage(session: session, navigate: navigate) } }
        } else {
            VStack(spacing: 16) {
                NativeToolEmptyState(title: "열린 탭이 없습니다", message: "새 탭에서 웹사이트를 열어보세요.", symbol: "square.on.square")
                Button("새 탭 열기") { perform { try await session.add() } }.buttonStyle(NativeToolButtonStyle(primary: true)).padding(.bottom, 32)
            }
        }
    }
    private var reloadButton: some View {
        Button(session.active?.loading == true ? "중지" : "새로고침", systemImage: session.active?.loading == true ? "xmark" : "arrow.clockwise") {
            perform { try await session.action(session.active?.loading == true ? "stop" : "reload") }
        }.accessibilityIdentifier("native-browser-reload")
    }
    private func downloadButton(inMenu: Bool = false) -> some View {
        Button("다운로드", systemImage: "arrow.down.circle") { showingDownloads = true }
            .accessibilityIdentifier(inMenu ? "native-browser-downloads-menu-item" : "native-browser-downloads-button")
    }
    private func profileMenu(expanded: Bool, inMenu: Bool = false) -> some View {
        Menu {
            Text("현재 프로필 · " + session.activeProfileName)
            ForEach(session.profiles, id: \.self) { profile in
                Button { perform { try await session.switchSession(profileID: profile["id"] ?? "default", isPrivate: session.active?.isPrivate ?? false) } } label: {
                    Label(profile["name"] ?? "프로필", systemImage: session.active?.profileID == profile["id"] ? "checkmark" : "person.crop.circle")
                }
            }
            Button("새 프로필", systemImage: "person.crop.circle.badge.plus") { showingProfile = true }.accessibilityIdentifier("native-browser-new-profile")
            Divider()
            Button(session.active?.isPrivate == true ? "개인정보 보호 종료" : "개인정보 보호로 전환", systemImage: "hand.raised") {
                perform { try await session.switchSession(profileID: session.active?.profileID ?? "default", isPrivate: session.active?.isPrivate != true) }
            }.accessibilityIdentifier("native-browser-private-toggle")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.active?.isPrivate == true ? "hand.raised.fill" : "person.crop.circle.fill").font(.system(size: 17))
                if expanded {
                    Text(session.active?.isPrivate == true ? "시크릿" : session.activeProfileName).font(.system(size: 12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }.padding(.horizontal, expanded ? 10 : 0).frame(minWidth: 44, maxWidth: expanded ? 116 : 44, minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityLabel("브라우저 프로필, " + session.activeProfileName + (session.active?.isPrivate == true ? ", 개인정보 보호" : ""))
            .accessibilityIdentifier(inMenu ? "native-browser-profile-menu-item" : "native-browser-profile")
    }
    private var schoolLinksMenu: some View {
        Menu {
            ForEach(session.schoolLinks) { link in
                Button(link.title) { navigate(link.url) }
            }
        } label: { Label("학교 사이트", systemImage: "folder").font(.system(size: 11)).frame(minHeight: 32) }
            .accessibilityIdentifier("native-browser-school-links")
    }
    private var browserMenu: some View {
        Menu {
            Button("새 탭", systemImage: "plus") { perform { try await session.add() } }
            Button("새 개인정보 보호 탭", systemImage: "hand.raised") { perform { try await session.add(isPrivate: true) } }
            Divider()
            Button("앞으로", systemImage: "chevron.right") { perform { try await session.action("goForward") } }.disabled(session.active?.canGoForward != true)
            reloadButton
            Button("홈", systemImage: "house") { perform { try await session.home() } }
            Button(session.activeFavorite == nil ? "즐겨찾기 추가" : "즐겨찾기 해제", systemImage: "star") { perform { try await session.toggleFavorite() } }.disabled(session.active?.isPrivate == true || session.active?.url == "about:blank")
            Divider()
            Button("방문 기록", systemImage: "clock") { showingHistory = true }.disabled(session.active?.isPrivate == true)
            if !session.schoolLinks.isEmpty { schoolLinksMenu }
            profileMenu(expanded: true, inMenu: true)
            Button("페이지에서 찾기", systemImage: "magnifyingglass") { session.setFindVisible(true) }.accessibilityIdentifier("native-browser-show-find")
            downloadButton(inMenu: true)
            Menu("확대/축소 · \(session.zoomPercent)%") {
                Button("확대", systemImage: "plus.magnifyingglass") { perform { try await session.zoom(1) } }.accessibilityIdentifier("native-browser-zoom-in")
                Button("축소", systemImage: "minus.magnifyingglass") { perform { try await session.zoom(-1) } }
                Button("기본 크기") { perform { try await session.zoom(nil) } }
            }.accessibilityIdentifier("native-browser-zoom-menu")
            Button("로그인 관리", systemImage: "key") {
                guard let active = session.active, let page = session.host.pages[active.id] else { return }
                do {
                    let origin = try DesktopCredentialsService.origin(active.url)
                    credentialContext = NativeBrowserCredentialContext(target: try session.host.credentialTarget(guestID: page.id, origin: origin))
                } catch { session.error = error.localizedDescription }
            }.disabled(session.active?.isPrivate != false || URL(string: session.active?.url ?? "")?.scheme != "https")
                .accessibilityIdentifier("native-browser-logins")
            Menu("웹사이트 표시") {
                Button("자동") { presentation("automatic") }
                Button("데스크톱 웹사이트") { presentation("desktop") }
                Button("모바일 웹사이트") { presentation("mobile") }
            }
            Button("페이지 공유", systemImage: "square.and.arrow.up") {
                guard let id = session.activeID else { return }
                perform { _ = try await session.host.handle(channel: "browser:sharePage", request: ["tabId": id]) }
            }.disabled(session.active?.url == "about:blank" || session.active == nil)
        } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44) }
            .accessibilityLabel("브라우저 메뉴").accessibilityIdentifier("native-browser-menu")
    }
    private var addressHistoryKey: String { "\(addressFocused):\(session.activeID ?? ""):\(session.active?.profileID ?? ""):\(address)" }
    private func loadAddressHistory() async {
        addressHistory = []
        guard addressFocused, session.active?.isPrivate != true else { return }
        do { try await Task.sleep(for: .milliseconds(90)); let rows = try await session.searchHistory(address); try Task.checkCancellation(); addressHistory = rows }
        catch is CancellationError {} catch { session.error = error.localizedDescription }
    }
    private func updateAddress() { address = NativeBrowserAddress.display(session.active?.url ?? "") }
    private func navigate(_ value: String) { addressFocused = false; perform { try await session.navigate(value) } }
    private func submitAddress() { let rows = suggestions; navigate(rows.indices.contains(suggestionIndex) ? rows[suggestionIndex].url : address) }
    private func moveSuggestion(_ offset: Int) { suggestionSelection.move(offset, in: suggestions) }
    private func presentation(_ mode: String) {
        guard let id = session.activeID else { return }; perform { _ = try await session.host.handle(channel: "browser:setSitePresentation", request: ["tabId": id, "mode": mode]) }
    }
    private func finishProfileCreation() {
        guard let pending = pendingProfile else { return }; pendingProfile = nil
        guard session.activeID == pending.tabID else { return }
        perform { try await session.switchSession(profileID: pending.id, isPrivate: pending.isPrivate) }
    }
    private func finishDownloadPresentation() {
        guard let (item, action) = pendingDownloadAction else { return }; pendingDownloadAction = nil
        perform { try await session.downloadAction(item, action: action) }
    }
    private func shortcut(_ action: String) {
        switch action {
        case "focus-address": addressFocused = true
        case "find": session.setFindVisible(true)
        case "new-tab": perform { try await session.add() }
        case "close-tab": if let id = session.activeID { perform { try await session.close(id) } }
        case "browser-back": perform { try await session.action("goBack") }
        case "browser-forward": perform { try await session.action("goForward") }
        case "reload", "reload-hard": perform { try await session.action(action == "reload" ? "reload" : "reloadIgnoringCache") }
        case "prev-tab", "next-tab":
            if let index = session.tabs.firstIndex(where: { $0.id == session.activeID }), !session.tabs.isEmpty { session.select(session.tabs[(index + (action == "next-tab" ? 1 : session.tabs.count - 1)) % session.tabs.count].id) }
        case "activate-last-tab": if let id = session.tabs.last?.id { session.select(id) }
        case "zoom-in": perform { try await session.zoom(1) }
        case "zoom-out": perform { try await session.zoom(-1) }
        case "zoom-reset": perform { try await session.zoom(nil) }
        default:
            if action.hasPrefix("activate-tab-"), let index = Int(action.dropFirst("activate-tab-".count)), session.tabs.indices.contains(index - 1) { session.select(session.tabs[index - 1].id) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { session.error = error.localizedDescription } } }
}

struct NativeBrowserSurface: UIViewRepresentable {
    let host: DesktopBrowserHost
    let selectedID: String?
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.host = host; return view }
    func updateUIView(_ view: Surface, context: Context) { host.attachNative(to: view, selectedTabID: selectedID) }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.host?.detachNative(from: view) }
    final class Surface: UIView {
        weak var host: DesktopBrowserHost?
        override func layoutSubviews() { super.layoutSubviews(); host?.layoutPages() }
    }
}
