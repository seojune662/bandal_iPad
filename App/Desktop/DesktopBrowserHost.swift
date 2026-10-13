import Foundation
import UIKit
import WebKit

/// Implements the desktop renderer's nativePageHandle contract. The React
/// shell owns chrome and layout; these WKWebViews contain external sites only.
@MainActor
final class DesktopBrowserHost: NSObject {
    var emit: (String, Any) -> Void = { _, _ in }
    var onDownload: ((URL, String?) async throws -> String?)?
    var onCourseForURL: ((URL) -> String?)?
    var onDeleteProfile: ((String) throws -> Void)?
    var isImportingProfile: (String) -> Bool = { _ in false }
    var onAgentAttachment: ((String, String) async throws -> (name: String, mimeType: String, data: Data))?
    var onLayout: (() -> Void)?
    weak var presenter: UIViewController?
    weak var shell: WKWebView?
    weak var container: UIView?
    let root: URL
    private(set) var persistence: DesktopBrowserPersistence?
    private(set) var presentationStore: BrowserPresentationStore?
    private(set) var downloadStore: BrowserDownloadStore?
    private var initializationError: String?
    private(set) var pages: [String: DesktopBrowserPage] = [:]
    var downloads: [String: DesktopBrowserDownload] = [:]
    private var nextPageID = 1
    private var hostOccluded = false
    private var recentPopups: [Date] = []
    private var releasingInactivePages = false
    private var deletingProfileIDs = Set<String>()
    var isPresentingPageShare = false
    private(set) var popupBehavior = "balanced"
    private(set) var swipeNavigation = true
    private(set) var agentUse = true
    private(set) var doNotTrack = true
    private(set) var trackingProtection = "balanced"
    private(set) var privacyRules: WKContentRuleList?
    private var privacyTask: Task<Void, Error>?
    lazy var observationRelay = BrowserObservationRelay(host: self)

    init(root: URL) {
        self.root = root.appendingPathComponent("DesktopBrowser", isDirectory: true)
        super.init()
        do {
            persistence = try DesktopBrowserPersistence(root: self.root)
            presentationStore = try BrowserPresentationStore(root: self.root)
            downloadStore = try BrowserDownloadStore(root: self.root)
            for record in downloadStore?.records ?? [] where persistence?.state.profiles.contains(where: { $0.id == record.profileID }) == true {
                let item = DesktopBrowserDownload(restoring: record, host: self)
                downloads[item.id] = item
            }
        }
        catch { initializationError = error.localizedDescription }
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    @objc private func memoryWarning() { Task { await releaseInactivePages() } }
    @discardableResult
    func releaseInactivePages(keeping limit: Int = 4) async -> [String] {
        guard !releasingInactivePages else { return [] }
        releasingInactivePages = true; defer { releasingInactivePages = false }
        var released: [String] = []
        for page in pages.values.sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            guard pages.values.filter({ $0.liveWebView != nil }).count > max(0, limit) else { break }
            if await page.suspendIfSafe() { released.append(page.tabID) }
        }
        return released
    }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("browser:") }
    func applySettings(_ browser: [String: Any]) {
        swipeNavigation = browser["swipeNavigation"] as? Bool ?? true
        popupBehavior = browser["popupBehavior"] as? String == "strict" ? "strict" : "balanced"
        agentUse = browser["agentUse"] as? Bool ?? true
        doNotTrack = browser["doNotTrack"] as? Bool ?? true
        trackingProtection = browser["trackingProtection"] as? String ?? "balanced"
        let tracking = trackingProtection, dnt = doNotTrack
        privacyTask = Task { [weak self] in
            let rules = try await BrowserPrivacy.compile(tracking: tracking, doNotTrack: dnt)
            guard let self, tracking == self.trackingProtection, dnt == self.doNotTrack else { return }
            self.privacyRules = rules
            for page in self.pages.values {
                guard let view = page.liveWebView else { continue }
                view.allowsBackForwardNavigationGestures = self.swipeNavigation
                self.configurePrivacy(view.configuration.userContentController)
                _ = try? await view.evaluateJavaScript(BrowserPrivacy.signalScript(enabled: dnt))
            }
        }
    }
    func waitForPrivacySettings() async throws { try await privacyTask?.value }
    func prepareBrowserNetwork() async throws {
        if privacyTask == nil { applySettings([:]) }
        try await waitForPrivacySettings()
        try await DesktopBrowserIdentity.prepare()
    }
    func validateSettings(_ settings: [String: Any]) async throws {
        _ = try await BrowserPrivacy.compile(tracking: settings["trackingProtection"] as? String ?? trackingProtection,
                                             doNotTrack: settings["doNotTrack"] as? Bool ?? doNotTrack)
    }
    func configurePrivacy(_ controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if let privacyRules { controller.add(privacyRules) }
        // Replace our signal script while keeping observation/context scripts.
        let scripts = controller.userScripts.filter { !$0.source.hasPrefix("/*bandal-privacy*/") }
        controller.removeAllUserScripts(); scripts.forEach(controller.addUserScript)
        controller.addUserScript(WKUserScript(source: "/*bandal-privacy*/" + BrowserPrivacy.signalScript(enabled: doNotTrack), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func navigationRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if doNotTrack { request.setValue("1", forHTTPHeaderField: "DNT"); request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
        return request
    }
    func requireAgentAccess() throws {
        guard agentUse else { throw DesktopBrowserError.unavailable("브라우저 설정에서 AI의 브라우저 사용이 꺼져 있습니다.") }
    }
    func clearCache() async {
        let stores = (persistence?.knownDataStores() ?? []) + pages.values.map { $0.dataStore }
        var visited = Set<ObjectIdentifier>()
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        for store in stores where visited.insert(ObjectIdentifier(store)).inserted {
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }
    /// Used by both dragged links and PDF source retrieval. The tab's exact
    /// profile/private cookies are selected; every redirect rebuilds scope.
    func fetchLinkedFile(url: String, tabID: String?) async throws -> (fileName: String, dataBase64: String) {
        let address = try Self.navigationURL(url)
        guard address.scheme == "https" || address.scheme == "http", let persistence else { throw DesktopBrowserError.invalid("다운로드 주소") }
        let store: WKWebsiteDataStore
        if let tabID {
            guard let page = pages[tabID] else { throw DesktopBrowserError.unavailable("다운로드할 브라우저 탭이 닫혔습니다.") }
            store = page.dataStore
        } else { store = persistence.dataStore(profile: "default", isPrivate: false) }
        let cookies = await store.httpCookieStore.allCookies()
        return try await BrowserLinkedFile.fetch(address, cookies: cookies, doNotTrack: doNotTrack)
    }
    func attach(to view: UIView, shell: WKWebView) {
        self.container = view; self.shell = shell
        for page in pages.values { if let live = page.liveWebView, live.superview !== view { view.addSubview(live) } }
        layoutPages()
    }
    func layoutPages() {
        guard let container, let shell else { return }
        defer { onLayout?() }
        for page in pages.values {
            guard let rect = page.bounds, !hostOccluded else { page.liveWebView?.isHidden = true; continue }
            let scale = shell.scrollView.zoomScale
            let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            let frame = shell.convert(scaled, to: container).intersection(shell.convert(shell.bounds, to: container)).intersection(container.bounds)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { page.webView.isHidden = true; continue }
            page.webView.frame = frame
            page.webView.isHidden = false
            container.bringSubviewToFront(page.webView)
        }
    }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        guard let persistence else { throw DesktopBrowserError.unavailable(initializationError ?? "브라우저 저장소를 열지 못했습니다.") }
        switch channel {
        case "browser:sharePage": return try await sharePage(owned(request))
        case "browser:dismissDownload": return try dismissDownload(request)
        case "browser:downloadsSnapshot": return downloads.values.map(\.payload)
        case "browser:sitePresentation": return try await presentationRequest(request, page: owned(request), update: false)
        case "browser:setSitePresentation": return try await presentationRequest(request, page: owned(request), update: true)
        case "browser:createPage":
            try await prepareBrowserNetwork()
            let tab = try Self.string(request, "tabId")
            let profile = try profileID(request)
            let privateMode = request["isPrivate"] as? Bool ?? false
            if let existing = pages[tab] {
                guard existing.profileID == profile, existing.isPrivate == privateMode else { throw DesktopBrowserError.invalid("탭 세션 불일치") }
                return ["state": existing.state, "adopted": true]
            }
            let page = try createPage(tabID: tab, profileID: profile, isPrivate: privateMode, courseID: request["courseId"] as? String)
            return ["state": page.state, "adopted": false]
        case "browser:pageBounds":
            let page = try owned(request)
            let bounds = try Self.rectangle(request["bounds"])
            page.layoutRevision += 1
            let revision = page.layoutRevision
            var snapshot: String?
            if request["preview"] as? Bool == true, page.liveWebView?.isHidden == false {
                snapshot = try? await page.snapshot()
            }
            if pages[page.tabID] === page, page.layoutRevision == revision {
                page.bounds = bounds
                layoutPages()
            }
            return ["snapshot": snapshot as Any? ?? NSNull()]
        case "browser:setHostOccluded":
            hostOccluded = request["occluded"] as? Bool ?? false
            if hostOccluded { shell?.becomeFirstResponder() }
            layoutPages(); return ["ok": true]
        case "browser:pageAction":
            return try await action(try owned(request), action: Self.string(request, "action"), args: request["args"] as? [Any] ?? [])
        case "browser:destroyPage":
            let id = try Self.string(request, "tabId")
            if let page = pages[id], request["expectedWebContentsId"] == nil || (request["expectedWebContentsId"] as? Int) == page.id { destroy(id) }
            return ["ok": true]
        case "browser:setCourse":
            let page = try owned(request)
            guard let revision = request["revision"] as? Int, revision > 0 else { throw DesktopBrowserError.invalid("소유권 버전") }
            guard request["expectedWebContentsId"] as? Int == page.id, revision > page.ownershipRevision else { return ["ok": false] }
            page.ownershipRevision = revision; page.courseID = request["courseId"] as? String; return ["ok": true]
        case "browser:setDownloadTarget":
            let page = try owned(request)
            guard request["webContentsId"] as? Int == page.id else { throw DesktopBrowserError.invalid("탭 식별자") }
            page.courseID = request["courseId"] as? String; return ["ok": true]
        case "browser:prepareClose", "browser:prepareProfileSwitch":
            guard let page = pages[try Self.string(request, "tabId")] else { return ["allowed": true] }
            if page.isSuspended { return ["allowed": true] }
            let cancelled = (try? await page.webView.evaluateJavaScript("(()=>{const e=new Event('beforeunload',{cancelable:true});return !window.dispatchEvent(e)||e.returnValue===false})()")) as? Bool ?? false
            let allowed = cancelled ? await confirm(title: "페이지를 닫을까요?", message: "웹 페이지에서 저장하지 않은 내용이 있을 수 있습니다.") : true
            return ["allowed": allowed]
        case "browser:profiles": return persistence.state.profiles.map(\.json)
        case "browser:saveProfile":
            var state = persistence.state
            let id = request["id"] is String ? try Self.string(request, "id") : UUID().uuidString
            guard !deletingProfileIDs.contains(id), id == "default" || UUID(uuidString: id) != nil else { throw DesktopBrowserError.invalid("프로필 식별자") }
            let name = try Self.string(request, "name", limit: 100)
            let color = try Self.string(request, "color", limit: 64)
            let icon = try Self.string(request, "icon", limit: 64)
            let item = DesktopBrowserProfile(id: id, name: name, color: color, icon: icon)
            if let index = state.profiles.firstIndex(where: { $0.id == id }) { state.profiles[index] = item }
            else { guard state.profiles.count < 30 else { throw DesktopBrowserError.invalid("프로필 개수") }; state.profiles.append(item) }
            try persistence.commit(state); return item.json
        case "browser:deleteProfile":
            let id = try Self.string(request, "id")
            guard id != "default" else { throw DesktopBrowserError.invalid("기본 프로필은 삭제할 수 없습니다") }
            guard isProfileAvailable(id) else { throw DesktopBrowserError.invalid("존재하지 않거나 삭제 중인 프로필") }
            guard !isImportingProfile(id) else { throw DesktopBrowserError.unavailable("이 프로필에 북마크를 가져오는 중입니다. 완료한 뒤 삭제해 주세요.") }
            guard !downloads.values.contains(where: { $0.profileID == id && $0.isChangingTransfer }) else { throw DesktopBrowserError.unavailable("다운로드 상태를 변경하는 중입니다. 잠시 후 프로필을 삭제해 주세요.") }
            guard !pages.values.contains(where: { $0.profileID == id }) else { throw DesktopBrowserError.unavailable("해당 프로필의 브라우저 탭을 먼저 닫아 주세요.") }
            deletingProfileIDs.insert(id)
            defer { deletingProfileIDs.remove(id) }
            try onDeleteProfile?(id)
            for item in downloads.values where item.profileID == id { await item.cancel(pause: false) }
            try await persistence.forgetProfileStore(id)
            try presentationStore?.forget(id)
            try downloadStore?.forgetProfile(id)
            downloads = downloads.filter { $0.value.profileID != id }
            var state = persistence.state; state.profiles.removeAll { $0.id == id }; state.visits.removeAll { $0.profileID == id }; state.permissions.removeAll { $0.profileID == id }
            try persistence.commit(state); return ["ok": true]
        case "browser:recordVisit":
            let profile = try profileID(request); let raw = try Self.string(request, "url", limit: 20_000)
            let url = try Self.navigationURL(raw)
            guard url.scheme != "about" else { return ["ok": true] }
            var state = persistence.state
            let previous = state.visits.first { $0.profileID == profile && $0.url == raw }
            state.visits.removeAll { $0.profileID == profile && $0.url == raw }
            state.visits.append(.init(profileID: profile, courseID: request["courseId"] as? String, url: raw,
                title: String((request["title"] as? String ?? "").prefix(10_000)), host: url.host ?? "",
                visitCount: (previous?.visitCount ?? 0) + 1, lastVisitedAt: ISO8601DateFormatter().string(from: Date())))
            state.visits = Array(state.visits.suffix(20_000)); try persistence.commit(state); return ["ok": true]
        case "browser:searchHistory":
            let profile = try profileID(request); let query = request["query"] as? String ?? ""
            let limit = min(200, max(1, request["limit"] as? Int ?? 20))
            let visits = persistence.state.visits.filter { $0.profileID == profile && (query.isEmpty || $0.url.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)) }
            return ["entries": visits.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(limit).map(\.json)]
        case "browser:clearHistory":
            let profile = try profileID(request); let course = request["courseId"] as? String
            var state = persistence.state; state.visits.removeAll { $0.profileID == profile && (course == nil || $0.courseID == course) }
            try persistence.commit(state); return ["ok": true]
        case "browser:courseForUrl":
            let url = try Self.navigationURL(Self.string(request, "url", limit: 20_000))
            return ["courseId": onCourseForURL?(url) as Any? ?? NSNull()]
        case "browser:sessionSites":
            let store = persistence.dataStore(profile: try profileID(request), isPrivate: false)
            let cookies = await store.httpCookieStore.allCookies()
            let groups = Dictionary(grouping: cookies, by: { "https://" + $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            return ["sites": groups.keys.sorted().map { ["origin": $0, "cookieCount": groups[$0]!.count] as [String: Any] }]
        case "browser:clearSession", "browser:clearStorage":
            let store = persistence.dataStore(profile: try profileID(request), isPrivate: false)
            let origin = request["origin"] as? String
            let host = origin.flatMap { URL(string: $0)?.host }
            if origin != nil && host == nil { throw DesktopBrowserError.invalid("사이트 주소") }
            if channel == "browser:clearSession" {
                for cookie in await store.httpCookieStore.allCookies() where host == nil || Self.domain(cookie.domain, matches: host!) { await store.httpCookieStore.deleteCookie(cookie) }
            } else {
                var types = WKWebsiteDataStore.allWebsiteDataTypes()
                if request["cache"] as? Bool != true { types.remove(WKWebsiteDataTypeDiskCache); types.remove(WKWebsiteDataTypeMemoryCache) }
                if let host {
                    // WebKit groups storage by registrable domain; only remove the
                    // requested record, never all sites when no match is found.
                    let records = await store.dataRecords(ofTypes: types).filter { Self.domain(host, matches: $0.displayName) }
                    await store.removeData(ofTypes: types, for: records)
                } else { await store.removeData(ofTypes: types, modifiedSince: .distantPast) }
            }
            return ["ok": true]
        case "browser:sitePermissions":
            let profile = try profileID(request)
            return ["permissions": persistence.state.permissions.filter { $0.profileID == profile }.map(\.json)]
        case "browser:forgetPermission":
            let profile = try profileID(request); let id = request["id"] as? String
            var state = persistence.state; state.permissions.removeAll { $0.profileID == profile && (id == nil || $0.id == id) }
            try persistence.commit(state); return ["ok": true]
        case "browser:setPopupPermission":
            let profile = try profileID(request); let origin = try Self.string(request, "origin")
            _ = try Self.navigationURL(origin)
            let decision = try Self.string(request, "decision")
            guard ["granted", "denied"].contains(decision) else { throw DesktopBrowserError.invalid("권한 값") }
            try savePermission(profile: profile, origin: origin, permission: "popups", decision: decision)
            return ["ok": true]
        case "browser:favicon":
            let raw = try Self.string(request, "url", limit: 20_000)
            guard let url = try? Self.navigationURL(raw), url.scheme != "about" else { return ["dataUrl": NSNull()] }
            let store = persistence.dataStore(profile: try profileID(request), isPrivate: request["isPrivate"] as? Bool ?? false)
            let result = await BrowserFavicon.fetch(url, doNotTrack: doNotTrack, store: store)
            return ["dataUrl": result as Any? ?? NSNull()]
        case "browser:downloadFile": return try await downloadFile(request)
        case "browser:controlDownload": return try await controlDownload(request)
        case "browser:extensions": return ["extensions": [Any]()]
        case "browser:importSources": return [Any]()
        case "browser:installExtension", "browser:setExtensionEnabled", "browser:removeExtension": throw DesktopBrowserError.unsupported("Chromium 확장")
        case "browser:importBookmarks", "browser:importFile", "browser:importStart", "browser:importJob", "browser:importCancel":
            throw DesktopBrowserError.unsupported("다른 앱의 브라우저 저장소 가져오기")
        default: throw DesktopBrowserError.unsupported(channel)
        }
    }

    private func action(_ page: DesktopBrowserPage, action: String, args: [Any]) async throws -> Any {
        func string(_ index: Int) throws -> String {
            guard args.indices.contains(index), let value = args[index] as? String else { throw DesktopBrowserError.invalid(action) }; return value
        }
        let view = page.webView
        switch action {
        case "loadURL": view.load(navigationRequest(try Self.navigationURL(string(0))))
        case "goBack": if view.canGoBack { view.goBack() }
        case "goForward": if view.canGoForward { view.goForward() }
        case "reload": view.reload()
        case "reloadIgnoringCache": view.reloadFromOrigin()
        case "stop": view.stopLoading()
        case "focus": view.becomeFirstResponder(); page.send("focus", ["webContentsId": page.id])
        case "setZoomLevel":
            guard let level = args.first as? Double, level.isFinite, (-8...8).contains(level) else { throw DesktopBrowserError.invalid("확대 배율") }
            view.pageZoom = pow(1.2, level)
        case "executeJavaScript":
            let source = try string(0)
            guard source.utf8.count <= 1_000_000 else { throw DesktopBrowserError.invalid("스크립트 크기") }
            return try await view.callAsyncJavaScript("return await (0,eval)(source)", arguments: ["source": source], in: nil, contentWorld: .page) ?? NSNull()
        case "findInPage":
            let text = try string(0), options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            page.findRequest += 1
            let id = page.findRequest
            let result = try await view.callAsyncJavaScript(BrowserScripts.find, arguments: ["query": text, "next": options["findNext"] as? Bool ?? false, "forward": options["forward"] as? Bool ?? true, "matchCase": options["matchCase"] as? Bool ?? false], in: nil, contentWorld: .defaultClient) as? [String: Any] ?? [:]
            page.send("found-in-page", ["result": ["requestId": id, "activeMatchOrdinal": result["ordinal"] ?? 0, "matches": result["matches"] ?? 0, "finalUpdate": true]])
            return id
        case "stopFindInPage":
            _ = try? await view.callAsyncJavaScript("globalThis.__bandalNativeFind=null;getSelection()?.removeAllRanges()", arguments: [:], in: nil, contentWorld: .defaultClient)
        case "printToPDF":
            let data = try await BrowserPrint.pdf(webView: view, options: args.first as? [String: Any] ?? [:])
            return ["__bandalBytes": data.base64EncodedString()]
        case "downloadURL":
            let url = try Self.navigationURL(string(0)); let download = await view.startDownload(using: navigationRequest(url)); track(download, page: page)
        case "copy", "cut", "paste", "selectAll":
            let selectors = ["copy": #selector(UIResponderStandardEditActions.copy(_:)), "cut": #selector(UIResponderStandardEditActions.cut(_:)), "paste": #selector(UIResponderStandardEditActions.paste(_:)), "selectAll": #selector(UIResponderStandardEditActions.selectAll(_:))]
            view.becomeFirstResponder()
            guard let selector = selectors[action], UIApplication.shared.sendAction(selector, to: nil, from: view, for: nil) else { throw DesktopBrowserError.unavailable("현재 선택에서 \(action) 동작을 실행할 수 없습니다.") }
        case "undo": view.undoManager?.undo()
        case "redo": view.undoManager?.redo()
        case "copyImageAt":
            guard args.count > 1, let x = args[0] as? Double, let y = args[1] as? Double, x.isFinite, y.isFinite else { throw DesktopBrowserError.invalid("이미지 위치") }
            let image = try await DesktopBrowserImageCopy.image(in: view, at: CGPoint(x: x, y: y), doNotTrack: doNotTrack)
            guard pages[page.tabID] === page, page.liveWebView === view else { throw DesktopBrowserError.unavailable("이미지를 복사하던 브라우저 탭이 닫혔습니다.") }
            UIPasteboard.general.image = image
        case "openDevTools": throw DesktopBrowserError.unsupported("Chromium 개발자 도구")
        default: throw DesktopBrowserError.unsupported(action)
        }
        return NSNull()
    }
    private func owned(_ request: [String: Any]) throws -> DesktopBrowserPage {
        guard let page = pages[try Self.string(request, "tabId")] else { throw DesktopBrowserError.unavailable("브라우저 탭이 이미 닫혔습니다.") }; return page
    }
    private func profileID(_ request: [String: Any]) throws -> String {
        let id = request["profileId"] as? String ?? "default"
        guard isProfileAvailable(id) else { throw DesktopBrowserError.invalid("존재하지 않거나 삭제 중인 프로필") }; return id
    }
    func isProfileAvailable(_ id: String) -> Bool {
        !deletingProfileIDs.contains(id) && persistence?.state.profiles.contains(where: { $0.id == id }) == true
    }
    func createPage(tabID: String, profileID: String, isPrivate: Bool, courseID: String?, configuration: WKWebViewConfiguration? = nil) throws -> DesktopBrowserPage {
        guard isProfileAvailable(profileID) else { throw DesktopBrowserError.unavailable("존재하지 않거나 삭제 중인 브라우저 프로필입니다.") }
        let page = DesktopBrowserPage(host: self, id: nextPageID, tabID: tabID, profileID: profileID, isPrivate: isPrivate, courseID: courseID, configuration: configuration)
        nextPageID += 1; pages[tabID] = page
        container?.addSubview(page.webView); page.webView.isHidden = true
        return page
    }
    func destroy(_ id: String) {
        guard let page = pages.removeValue(forKey: id) else { return }
        page.close()
        if page.isPrivate, !pages.values.contains(where: { $0.profileID == page.profileID && $0.isPrivate }) { persistence?.discardPrivateStore(page.profileID); presentationStore?.discardPrivate(page.profileID) }
    }
    func popup(from opener: DesktopBrowserPage, configuration: WKWebViewConfiguration, action: WKNavigationAction) -> WKWebView? {
        guard let url = action.request.url, (try? Self.navigationURL(url.absoluteString)) != nil else { return nil }
        let origin = opener.webView.url.flatMap(Self.origin) ?? ""
        let remembered = persistence?.state.permissions.first { $0.profileID == opener.profileID && $0.origin == origin && $0.permission == "popups" }?.decision
        let blocked = remembered == "denied" || (popupBehavior == "strict" && remembered != "granted")
        recentPopups.removeAll { Date().timeIntervalSince($0) > 3 }
        guard !blocked, recentPopups.count < 6, pages.count < 64 else {
            emit("browser:popup-blocked", ["profileId": opener.profileID, "isPrivate": opener.isPrivate, "url": url.absoluteString, "origin": origin, "reason": blocked ? "policy" : "limit"]); return nil
        }
        recentPopups.append(Date())
        opener.preventsSuspension = true // Preserve window.opener authentication flows.
        let tabID = UUID().uuidString
        guard let child = try? createPage(tabID: tabID, profileID: opener.profileID, isPrivate: opener.isPrivate, courseID: opener.courseID, configuration: configuration) else { return nil }
        emit("browser:open-url", ["tabId": tabID, "openerTabId": opener.tabID, "courseId": opener.courseID as Any? ?? NSNull(), "url": url.absoluteString, "isPrivate": opener.isPrivate, "profileId": opener.profileID, "webContentsId": child.id])
        return child.webView
    }
    func savePermission(profile: String, origin: String, permission: String, decision: String) throws {
        guard let persistence else { return }
        var state = persistence.state
        state.permissions.removeAll { $0.profileID == profile && $0.origin == origin && $0.permission == permission }
        state.permissions.append(.init(profileID: profile, origin: origin, permission: permission, decision: decision)); try persistence.commit(state)
    }
    var presentingController: UIViewController? {
        if let presenter { return presenter }
        var responder: UIResponder? = container
        while let current = responder { if let controller = current as? UIViewController { return controller }; responder = current.next }
        return nil
    }
    func confirm(title: String, message: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let controller = presentingController, controller.presentedViewController == nil else { continuation.resume(returning: false); return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "허용", style: .default) { _ in continuation.resume(returning: true) })
            controller.present(alert, animated: true)
        }
    }
    static func string(_ request: [String: Any], _ key: String, limit: Int = 512) throws -> String {
        guard let value = request[key] as? String, !value.isEmpty, value.utf8.count <= limit else { throw DesktopBrowserError.invalid(key) }; return value
    }
    static func rectangle(_ value: Any?) throws -> CGRect? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rect = value as? [String: Any], let x = rect["x"] as? Double, let y = rect["y"] as? Double, let w = rect["width"] as? Double, let h = rect["height"] as? Double,
              [x, y, w, h].allSatisfy({ $0.isFinite && abs($0) < 100_000 }) else { throw DesktopBrowserError.invalid("화면 위치") }
        return w > 0 && h > 0 ? CGRect(x: x, y: y, width: w, height: h) : nil
    }
    static func navigationURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), raw.utf8.count <= 20_000,
              (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) || raw == "about:blank" else { throw DesktopBrowserError.invalid("웹 주소") }
        return url
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }; return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
    static func domain(_ domain: String, matches host: String) -> Bool {
        let domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(), host = host.lowercased()
        return domain == host || domain.hasSuffix("." + host)
    }
}
