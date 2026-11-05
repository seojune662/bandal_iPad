import Foundation
import UIKit
import WebKit

/// The NSError domain is part of the code's meaning. In particular, Darwin or
/// WebKit error numbers must never be interpreted as Chromium net errors.
enum BrowserNavigationFailure {
    static func kind(_ error: NSError) -> String? {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff: return "offline"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "dns"
            case NSURLErrorTimedOut: return "timeout"
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "connection"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired: return "certificate"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "policy"
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "unsupported"
            default: return "unknown"
            }
        }
        // WebKit's download handoff is a policy interruption, not a page error.
        if error.domain == "WebKitErrorDomain", error.code == 102 { return nil }
        return "unknown"
    }
}

private final class BrowserNavigationAttempt {
    let id: Int
    var request: URLRequest
    let sourceURL: URL?
    var started = false
    var committed = false
    var ignored = false
    var method: String { (request.httpMethod ?? "GET").uppercased() }
    init(id: Int, request: URLRequest, sourceURL: URL?) { self.id = id; self.request = request; self.sourceURL = sourceURL }
}

@MainActor
final class DesktopBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    weak var host: DesktopBrowserHost?
    /// Never updated, so it denies every Scribble gesture: a Pencil tap on a
    /// website text field then presents the keyboard instead of the Scribble bar.
    private let scribbleDenial = DesktopScribblePolicy()
    let id: Int
    let tabID: String
    let profileID: String
    let isPrivate: Bool
    var courseID: String?
    var ownershipRevision = 0
    var bounds: CGRect?
    var layoutRevision = 0
    var findRequest = 0
    private(set) var liveWebView: WKWebView?
    private let configuration: WKWebViewConfiguration
    private var suspended: BrowserPageRestoration?
    private var restoring: BrowserPageRestoration?
    private var scrollRestoration: Task<Void, Never>?
    var preventsSuspension = false
    var lastUsedAt = Date()
    var isSuspended: Bool { liveWebView == nil && suspended != nil }
    var dataStore: WKWebsiteDataStore { configuration.websiteDataStore }
    var webView: WKWebView {
        lastUsedAt = Date()
        if let liveWebView { return liveWebView }
        let saved = suspended; suspended = nil; restoring = saved
        documentID = UUID().uuidString // Old DOM references cannot survive a reload.
        let view = makeWebView()
        if let saved {
            view.frame = saved.frame; view.pageZoom = saved.zoom
            host?.container?.addSubview(view); view.isHidden = bounds == nil
            view.interactionState = saved.interaction
        }
        return view
    }
    private var revision = 0
    private var documentID = UUID().uuidString
    private var httpStatus = 0
    private var navigationSequence = 0
    private var currentNavigation: BrowserNavigationAttempt?
    private var committedNavigation: BrowserNavigationAttempt?
    private var failedNavigation: BrowserNavigationAttempt?
    private var pendingRequest: URLRequest?
    private var pendingExplicitNavigation: BrowserNavigationAttempt?
    private var navigations: [ObjectIdentifier: (WKNavigation, BrowserNavigationAttempt)] = [:]
    private var committedURL: URL?
    private var recoveredURL: URL?
    private var observations: [NSKeyValueObservation] = []
    var state: [String: Any] {
        let cached = suspended?.state ?? restoring?.state
        let requestedURL = failedNavigation?.request.url ?? (currentNavigation?.committed == false && currentNavigation?.ignored == false ? currentNavigation?.request.url : nil)
        return ["id": id, "stateRevision": revision, "authDocumentId": documentID,
         "profileId": profileID, "isPrivate": isPrivate,
         "zoomLevel": liveWebView.map { log(Double($0.pageZoom)) / log(1.2) } ?? cached?["zoomLevel"] ?? 0,
         "navigationId": failedNavigation?.id ?? currentNavigation?.id ?? navigationSequence,
         "estimatedProgress": failedNavigation == nil ? min(1, max(0, liveWebView?.estimatedProgress ?? 0)) : 0,
         "url": requestedURL?.absoluteString ?? recoveredURL?.absoluteString ?? liveWebView?.url?.absoluteString ?? cached?["url"] ?? "about:blank",
         "title": liveWebView?.title ?? cached?["title"] ?? "", "httpStatus": httpStatus,
         "loading": failedNavigation == nil && (liveWebView?.isLoading ?? false),
         "canGoBack": failedNavigation?.sourceURL != nil || (liveWebView?.canGoBack ?? cached?["canGoBack"] as? Bool ?? false),
         "canGoForward": liveWebView?.canGoForward ?? cached?["canGoForward"] ?? false]
    }
    init(host: DesktopBrowserHost, id: Int, tabID: String, profileID: String, isPrivate: Bool, courseID: String?, configuration supplied: WKWebViewConfiguration?) {
        self.host = host; self.id = id; self.tabID = tabID; self.profileID = profileID; self.isPrivate = isPrivate; self.courseID = courseID
        let configuration = supplied ?? WKWebViewConfiguration()
        DesktopBrowserIdentity.configure(configuration)
        if supplied == nil { configuration.websiteDataStore = host.persistence!.dataStore(profile: profileID, isPrivate: isPrivate) }
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Popups retain WebKit's supplied process/session configuration, but get
        // their own observation-only controller. No application IPC is exposed.
        let observer = WKUserContentController()
        observer.add(host.observationRelay, name: "browserObservation")
        observer.addUserScript(WKUserScript(source: BrowserMemoryScripts.observe, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: BrowserMemoryScripts.world))
        observer.addUserScript(WKUserScript(source: BrowserScripts.observation, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        observer.addUserScript(WKUserScript(source: "addEventListener('pointerdown',e=>{globalThis.__bandalContextPoint={x:e.clientX,y:e.clientY}},true)", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        if !isPrivate {
            observer.addUserScript(WKUserScript(source: BrowserCredentialScripts.capture, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: BrowserCredentialScripts.world))
        }
        host.configurePrivacy(observer)
        configuration.userContentController = observer
        self.configuration = configuration
        preventsSuspension = supplied != nil
        super.init()
        _ = makeWebView()
    }
    private func makeWebView() -> WKWebView {
        host?.configurePrivacy(configuration.userContentController)
        let webView = DesktopBrowserWebView(frame: .zero, configuration: configuration)
        webView.nativePage = self
        liveWebView = webView
        webView.navigationDelegate = self; webView.uiDelegate = self
        scribbleDenial.attach(to: webView)
        webView.allowsBackForwardNavigationGestures = host?.swipeNavigation ?? true
        webView.isInspectable = false
        webView.accessibilityIdentifier = "desktop-browser-\(tabID)"
        let focus = UITapGestureRecognizer(target: self, action: #selector(focused(_:)))
        focus.cancelsTouchesInView = false; focus.delegate = self
        webView.addGestureRecognizer(focus)
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView else { return }; self.send("page-title-updated", ["title": webView.title ?? ""]) } },
            webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView, self.failedNavigation == nil, self.pendingRequest == nil, self.currentNavigation?.committed == true || self.recoveredURL != nil else { return }; self.recoveredURL = nil; self.committedURL = webView.url; self.currentNavigation?.request.url = webView.url; self.send("did-navigate-in-page", ["url": webView.url?.absoluteString ?? "", "isMainFrame": true]) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView, !webView.isLoading else { return }; self.send("did-stop-loading") } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView, self.failedNavigation == nil, self.currentNavigation?.started == true else { return }; self.send("load-progress-changed") } }
        ]
        return webView
    }
    /// Only a hidden, reloadable reading page is eligible. Interaction state
    /// stays in memory; form/JS application state is never promised portable.
    func suspendIfSafe() async -> Bool {
        guard let view = liveWebView, bounds == nil, !preventsSuspension, failedNavigation == nil,
              !view.isLoading, restoring == nil, view.url?.scheme == "http" || view.url?.scheme == "https",
              view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
              host?.downloads.values.contains(where: { $0.page === self && $0.state == "progressing" }) != true else { return false }
        let identity = documentID
        guard await view.requestMediaPlaybackState() == .none else { return false }
        guard let position = (try? await view.callAsyncJavaScript(BrowserMemoryScripts.canSuspend, arguments: [:], in: nil, contentWorld: BrowserMemoryScripts.world)) as? [String: Double],
              let x = position["x"], let y = position["y"], x.isFinite, y.isFinite,
              let host, host.pages[tabID] === self, liveWebView === view, documentID == identity,
              bounds == nil, !preventsSuspension, failedNavigation == nil, !view.isLoading,
              view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
              !host.downloads.values.contains(where: { $0.page === self && $0.state == "progressing" }),
              let interaction = view.interactionState else { return false }
        suspended = BrowserPageRestoration(interaction: interaction, state: state, frame: view.frame, zoom: view.pageZoom, documentOffset: CGPoint(x: x, y: y))
        observations.removeAll(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.stopLoading(); view.removeFromSuperview(); liveWebView = nil
        send("did-stop-loading")
        return true
    }
    func close() {
        scrollRestoration?.cancel(); scrollRestoration = nil
        observations.removeAll(); liveWebView?.stopLoading(); liveWebView?.removeFromSuperview()
        liveWebView?.navigationDelegate = nil; liveWebView?.uiDelegate = nil
        suspended = nil; restoring = nil; navigations.removeAll(); pendingRequest = nil; pendingExplicitNavigation = nil
    }
    func send(_ name: String, _ detail: [String: Any] = [:]) {
        guard host?.pages[tabID] === self else { return }
        revision += 1
        host?.emit("browser:page-event", ["tabId": tabID, "name": name, "state": state, "detail": detail])
    }
    private func begin(_ request: URLRequest) -> BrowserNavigationAttempt {
        navigationSequence += 1
        let attempt = BrowserNavigationAttempt(id: navigationSequence, request: request, sourceURL: committedURL)
        currentNavigation = attempt
        recoveredURL = nil
        return attempt
    }
    private func remember(_ navigation: WKNavigation?, attempt: BrowserNavigationAttempt) {
        guard let navigation else { return }
        navigations[ObjectIdentifier(navigation)] = (navigation, attempt)
        // Keep navigation objects alive so ObjectIdentifier cannot be reused.
        navigations = navigations.filter { $0.value.1.id >= navigationSequence - 32 }
    }
    /// WebKit canonicalizes the request it reports back (a trailing slash on
    /// an empty path, lowercase host). Comparing raw URLs cancelled every
    /// explicit load of a bare origin such as https://www.google.com.
    static func sameNavigationTarget(_ requested: URL?, _ reported: URL) -> Bool {
        guard let requested else { return false }
        func canonical(_ url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
            components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
            if components.path.isEmpty { components.path = "/" }
            return components.string ?? url.absoluteString
        }
        return canonical(requested) == canonical(reported)
    }
    @discardableResult
    func load(_ request: URLRequest) -> WKNavigation? {
        let view = webView
        let attempt = begin(request)
        pendingRequest = request; pendingExplicitNavigation = attempt
        let navigation = view.load(request)
        remember(navigation, attempt: attempt)
        #if DEBUG
        NSLog("[bandal.browser.nav] load scheme=%@ navigation=%d window=%d hidden=%d", request.url?.scheme ?? "-", navigation == nil ? 0 : 1, view.window == nil ? 0 : 1, view.isHidden ? 1 : 0)
        #endif
        return navigation
    }
    /// WebKit starts the supplied popup navigation itself. Observe its full
    /// method without replacing it with a second GET or losing window.opener.
    func expectPopupRequest(_ request: URLRequest) { pendingRequest = request }
    func retry(navigationID: Int, ignoringCache: Bool = false) throws {
        guard let failed = failedNavigation, failed.id == navigationID, failed.id == currentNavigation?.id else {
            throw DesktopBrowserError.unavailable("이미 다른 페이지로 이동했습니다. 현재 페이지에서 다시 시도해 주세요.")
        }
        try requireReloadable()
        guard let url = failed.request.url else { throw DesktopBrowserError.invalid("다시 시도할 주소") }
        // Do not preserve POST bodies or expired request credentials. WebKit
        // obtains current profile cookies while loading the exact failed URL.
        var request = host?.navigationRequest(url) ?? URLRequest(url: url)
        if ignoringCache { request.cachePolicy = .reloadIgnoringLocalCacheData }
        load(request)
    }
    func reload(ignoringCache: Bool = false) throws {
        if let failed = failedNavigation { try retry(navigationID: failed.id, ignoringCache: ignoringCache); return }
        if ignoringCache { webView.reloadFromOrigin() } else { webView.reload() }
    }
    func requireReloadable() throws {
        guard failedNavigation == nil || failedNavigation?.method == "GET" else {
            throw DesktopBrowserError.unavailable("입력한 내용은 자동으로 다시 보내지 않습니다. 원래 입력 화면으로 돌아가 다시 제출해 주세요.")
        }
    }
    func returnToForm(navigationID: Int) throws {
        guard let failed = failedNavigation, failed.id == navigationID, failed.id == currentNavigation?.id, let source = failed.sourceURL else {
            throw DesktopBrowserError.unavailable("돌아갈 입력 화면이 없습니다. 주소를 수정해 페이지를 다시 열어 주세요.")
        }
        if !failed.committed {
            // A provisional failure leaves the form document (and its typed
            // values) underneath the error overlay. History back would skip it.
            failedNavigation = nil; currentNavigation = nil; pendingRequest = nil; pendingExplicitNavigation = nil
            recoveredURL = source
            send("navigation-recovered", ["url": source.absoluteString, "navigationId": navigationID])
        } else {
            load(host?.navigationRequest(source) ?? URLRequest(url: source))
        }
    }
    func goBack() throws {
        if let failed = failedNavigation, failed.sourceURL != nil { try returnToForm(navigationID: failed.id) }
        else if webView.canGoBack { webView.goBack() }
    }
    func stop() {
        currentNavigation?.ignored = true
        pendingRequest = nil; pendingExplicitNavigation = nil
        recoveredURL = committedURL
        webView.stopLoading(); send("did-stop-loading")
    }
    func snapshot() async throws -> String? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let options = WKSnapshotConfiguration(); options.rect = webView.bounds; options.snapshotWidth = NSNumber(value: min(1024, webView.bounds.width))
        let image = try await webView.takeSnapshot(configuration: options)
        return image.pngData().map { "data:image/png;base64," + $0.base64EncodedString() }
    }
    @objc private func focused(_ recognizer: UITapGestureRecognizer) { send("focus", ["webContentsId": id]) }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        Task { [weak self] in
            guard let self, self.liveWebView === webView, self.host?.pages[self.tabID] === self else { completionHandler(nil); return }
            let document = self.state["authDocumentId"] as? String
            var params = (try? await webView.callAsyncJavaScript(BrowserScripts.contextMenu, arguments: [:], in: nil, contentWorld: .defaultClient)) as? [String: Any] ?? [:]
            guard self.liveWebView === webView, self.host?.pages[self.tabID] === self,
                  self.state["authDocumentId"] as? String == document else { completionHandler(nil); return }
            if let link = elementInfo.linkURL { params["linkURL"] = link.absoluteString }
            self.send("context-menu", ["params": params])
            let values = params
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
                UIMenu(children: self?.contextMenuItems(values, suggested: suggested) ?? suggested)
            })
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        preferences.preferredContentMode = host?.presentation(for: self, url: url).contentMode ?? .recommended
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
            host?.emit("browser:external-scheme", ["tabId": tabID, "url": url.absoluteString, "origin": webView.url.flatMap(DesktopBrowserHost.origin) ?? "", "outcome": "blocked", "reason": "이 링크는 다른 앱이 필요합니다. 웹사이트의 웹 버전 링크를 사용하거나 주소를 복사해 해당 앱에서 열어 주세요."])
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            if let explicit = pendingExplicitNavigation, !explicit.started,
               !Self.sameNavigationTarget(explicit.request.url, url) {
                // An earlier load's policy callback can arrive after a newer
                // address was submitted. Do not let it replace the new target.
                #if DEBUG
                NSLog("[bandal.browser.nav] policy cancel: stale explicit target")
                #endif
                decisionHandler(.cancel, preferences); return
            }
            if navigationAction.shouldPerformDownload {
                currentNavigation?.ignored = true
                recoveredURL = committedURL
            } else {
                pendingRequest = navigationAction.request
            }
        }
        // Universal links stay in the in-app browser; the user asked for the
        // website, not the installed app (YouTube results opened the YouTube app).
        // WebKit's "allow without app link" policy is `.allow + 2` and has no
        // public Swift constant.
        decisionHandler(navigationAction.shouldPerformDownload ? .download : Self.allowWithoutAppLink, preferences)
    }
    private static let allowWithoutAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { httpStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0 }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let download = !navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment")
        if download, navigationResponse.isForMainFrame { currentNavigation?.ignored = true; recoveredURL = committedURL }
        decisionHandler(download ? .download : .allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        #if DEBUG
        NSLog("[bandal.browser.nav] start hidden=%d frame=%@ superview=%d", webView.isHidden ? 1 : 0, NSCoder.string(for: webView.frame), webView.superview == nil ? 0 : 1)
        #endif
        guard liveWebView === webView else { return }
        let attempt: BrowserNavigationAttempt
        if let navigation, let tracked = navigations[ObjectIdentifier(navigation)]?.1 {
            guard tracked.id == currentNavigation?.id, !tracked.ignored else { return }
            attempt = tracked
        } else {
            guard pendingExplicitNavigation == nil else { return }
            guard let request = pendingRequest ?? webView.url.map({ URLRequest(url: $0) }) else { return }
            attempt = begin(request); remember(navigation, attempt: attempt)
        }
        attempt.started = true
        failedNavigation = nil; pendingRequest = nil; pendingExplicitNavigation = nil
        // The first navigation belongs to interactionState restoration; a
        // later navigation while scroll restoration runs invalidates that work.
        if scrollRestoration != nil { scrollRestoration?.cancel(); scrollRestoration = nil; restoring = nil }
        documentID = UUID().uuidString; findRequest += 1; httpStatus = 0; send("did-start-loading")
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let attempt = active(navigation, webView: webView), let url = webView.url else { return }
        if let pendingRequest, pendingRequest.url == url { attempt.request = pendingRequest }
        else { attempt.request.url = url }
        pendingRequest = nil
        send("did-redirect-navigation", ["url": url.absoluteString, "navigationId": attempt.id])
    }
    private func active(_ navigation: WKNavigation?, webView: WKWebView) -> BrowserNavigationAttempt? {
        guard liveWebView === webView, let navigation, let attempt = navigations[ObjectIdentifier(navigation)]?.1,
              attempt.id == currentNavigation?.id, !attempt.ignored else { return nil }
        return attempt
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scribbleDenial.refreshAttachments()
        guard let attempt = active(navigation, webView: webView) else { return }
        if let pendingRequest, pendingRequest.url == webView.url { attempt.request = pendingRequest }
        attempt.committed = true; attempt.request.url = webView.url; committedURL = webView.url; recoveredURL = nil
        committedNavigation = attempt
        pendingRequest = nil
        send("did-navigate", ["url": webView.url?.absoluteString ?? "", "httpResponseCode": httpStatus])
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scribbleDenial.refreshAttachments()
        #if DEBUG
        NSLog("[bandal.browser.nav] finish hidden=%d frame=%@", webView.isHidden ? 1 : 0, NSCoder.string(for: webView.frame))
        #endif
        guard active(navigation, webView: webView) != nil else { return }
        if let saved = restoring {
            if let url = saved.state["url"] as? String, webView.url?.absoluteString == url {
                let document = documentID
                scrollRestoration = Task { [weak self, weak webView] in
                    guard let self, let webView, self.liveWebView === webView else { return }
                    _ = try? await webView.callAsyncJavaScript(BrowserMemoryScripts.restoreScroll,
                        arguments: ["x": saved.documentOffset.x, "y": saved.documentOffset.y, "url": url], in: nil, contentWorld: BrowserMemoryScripts.world)
                    guard !Task.isCancelled, self.documentID == document, self.liveWebView === webView else { return }
                    self.restoring = nil; self.scrollRestoration = nil
                }
            } else { restoring = nil }
        }
        send("dom-ready"); send("did-finish-load"); send("did-stop-loading")
        Task { [weak self] in
            guard let self else { return }
            if let icons = try? await webView.evaluateJavaScript("Array.from(document.querySelectorAll('link[rel~=icon]'),n=>n.href)") as? [String] { send("page-favicon-updated", ["favicons": icons]) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation, webView: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        NSLog("[bandal.browser.nav] provisionalFail code=%ld", (error as NSError).code)
        #endif
 failed(error, navigation: navigation, webView: webView) }
    private func failed(_ error: Error, navigation: WKNavigation?, webView: WKWebView) {
        let error = error as NSError
        guard let kind = BrowserNavigationFailure.kind(error), liveWebView === webView else { return }
        let reportedURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let attempt: BrowserNavigationAttempt
        if let known = active(navigation, webView: webView) { attempt = known }
        else if navigation == nil, let current = currentNavigation, !current.ignored, reportedURL == current.request.url, reportedURL != nil {
            // Some early provisional errors omit WKNavigation. Require the
            // exact requested URL rather than borrowing the previous page URL.
            attempt = current
        } else { return }
        let failedURL = reportedURL ?? attempt.request.url
        // A link or script navigation can be accepted just before didStart.
        // A failure belonging to the page it supersedes must not cover it.
        if let pendingRequest, pendingRequest.url != failedURL { return }
        if let pendingRequest, pendingRequest.url == failedURL { attempt.request = pendingRequest }
        if let failedURL { attempt.request.url = failedURL }
        failedNavigation = attempt; pendingRequest = nil; pendingExplicitNavigation = nil
        scrollRestoration?.cancel(); scrollRestoration = nil
        restoring = nil
        send("did-fail-load", failureDetail(attempt, kind: kind, error: error))
    }
    private func failureDetail(_ attempt: BrowserNavigationAttempt, kind: String, error: NSError) -> [String: Any] {
        ["errorKind": kind, "errorDomain": error.domain, "errorCode": error.code, "errorDescription": error.localizedDescription,
         "validatedURL": attempt.request.url?.absoluteString ?? "", "isMainFrame": true, "navigationId": attempt.id,
         "retryable": attempt.method == "GET", "requestMethod": attempt.method, "canReturnToForm": attempt.method != "GET" && attempt.sourceURL != nil]
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard liveWebView === webView else { return }
        let attempt: BrowserNavigationAttempt?
        if let currentNavigation, !currentNavigation.ignored { attempt = currentNavigation }
        else if let committedNavigation {
            // Stop and download handoff leave the committed document visible;
            // its URL/method, not the cancelled target, is the recovery target.
            attempt = begin(committedNavigation.request)
            attempt?.committed = true
        } else { attempt = (recoveredURL ?? webView.url).map { begin(URLRequest(url: $0)) } }
        guard let attempt else { return }
        // Preserve the original method: a crashed submitted form is never
        // silently converted into a request that might resubmit its contents.
        failedNavigation = attempt; pendingRequest = nil; pendingExplicitNavigation = nil
        var detail = failureDetail(attempt, kind: "crashed", error: NSError(domain: WKError.errorDomain, code: WKError.webContentProcessTerminated.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "웹페이지 프로세스가 종료되었습니다. 다시 시도해 주세요."]))
        detail["reason"] = "web-content-process-terminated"
        send("render-process-gone", detail)
        send("did-fail-load", detail)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { host?.track(download, page: self) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { host?.track(download, page: self) }
    func webViewDidClose(_ webView: WKWebView) { host?.emit("browser:close-tab", ["tabId": tabID]); host?.destroy(tabID) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.popup(from: self, configuration: configuration, action: navigationAction)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = host?.presentingController, presenter.presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: String(message.prefix(10_000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() }); presenter.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Task { completionHandler(await host?.confirm(title: frame.request.url?.host ?? "웹 페이지", message: String(message.prefix(10_000))) ?? false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter = host?.presentingController, presenter.presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: String(prompt.prefix(10_000)), preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) }); presenter.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let permission = type == .microphone ? "microphone" : type == .camera ? "camera" : "camera-microphone"
        if type != .microphone && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") == nil { decisionHandler(.deny); return }
        let site = "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        if !isPrivate, let saved = host?.persistence?.state.permissions.first(where: { $0.profileID == profileID && $0.origin == site && $0.permission == permission }) {
            decisionHandler(saved.decision == "granted" ? .grant : .deny); return
        }
        Task {
            let granted = await host?.confirm(title: origin.host, message: "이 사이트가 \(permission == "microphone" ? "마이크" : "카메라")를 사용하도록 허용할까요?") ?? false
            if !isPrivate { try? host?.savePermission(profile: profileID, origin: site, permission: permission, decision: granted ? "granted" : "denied") }
            decisionHandler(granted ? .grant : .deny)
        }
    }
}

/// A narrow, untrusted observation channel only. A website cannot invoke an
/// application command or read storage through this handler.
@MainActor
final class BrowserObservationRelay: NSObject, WKScriptMessageHandler {
    weak var host: DesktopBrowserHost?
    init(host: DesktopBrowserHost) { self.host = host }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let page = host?.pages.values.first(where: { $0.liveWebView === view }),
              let body = message.body as? [String: Any] else { return }
        if let text = body["console"] as? String, text.hasPrefix("__bandal"), text.utf8.count <= 150_000 { page.send("console-message", ["message": text]) }
    }
}

enum BrowserScripts {
    static let contextMenu = """
    const {x,y}=globalThis.__bandalContextPoint||{x:0,y:0};
    const el=document.elementFromPoint(x,y), link=el?.closest('a[href]'), media=el?.closest('img,video,audio,canvas'), tag=media?.tagName.toLowerCase();
    return {x,y,linkURL:link?.href||'',srcURL:media?.currentSrc||media?.src||'',mediaType:tag==='img'?'image':['audio','video','canvas'].includes(tag)?tag:'none',selectionText:getSelection()?.toString().slice(0,100000)||'',isEditable:!!el?.closest('input,textarea,[contenteditable=true]'),pageURL:location.href};
    """
    static let observation = """
    (()=>{const original=console.log;console.log=function(...args){try{if(typeof args[0]==='string'&&args[0].startsWith('__bandal')&&args[0].length<150000)window.webkit.messageHandlers.browserObservation.postMessage({console:args[0]})}catch{};return original.apply(this,args)}})();
    """
    static let stopFind = """
    globalThis.__bandalNativeFind=null;getSelection()?.removeAllRanges();
    globalThis.CSS?.highlights?.delete('bandal-find-all');
    globalThis.CSS?.highlights?.delete('bandal-find-active');
    document.getElementById('__bandalNativeFindStyle')?.remove();
    """
    static let find = #"""
    const previous=globalThis.__bandalNativeFind;
    // Rebuild against the current DOM even for next/previous. Connected Range
    // objects follow text edits, so retaining them can select non-matching text
    // indefinitely on live articles, search results and SPA navigation.
    let ranges=[];
    if(query){
      const segments=[], blocks=new WeakMap();let text='',lastBlock=null;
      const blockOf=element=>{if(blocks.has(element))return blocks.get(element);let block=element;while(block.parentElement&&getComputedStyle(block).display==='inline')block=block.parentElement;blocks.set(element,block);return block};
      const walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT,{acceptNode(node){
        const p=node.nodeType===Node.TEXT_NODE?node.parentElement:node;
        if(!p||p.closest('script,style,noscript,textarea,input,[hidden]')||!p.getClientRects().length||getComputedStyle(p).visibility==='hidden')return NodeFilter.FILTER_REJECT;
        return node.nodeType===Node.TEXT_NODE||p.tagName==='BR'?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_SKIP;
      }});
      let node;while((node=walker.nextNode())&&text.length<2000000){
        if(node.nodeType!==Node.TEXT_NODE){text+='\n';continue}
        const block=blockOf(node.parentElement);if(lastBlock&&lastBlock!==block)text+='\n';lastBlock=block;
        const start=text.length;text+=node.textContent;segments.push({node,start,end:text.length});
      }
      const escaped=query.split(/(\s+)/).map(part=>/^\s+$/.test(part)?'\\s+':part.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('');
      const expression=new RegExp(escaped,matchCase?'gu':'giu');let match;
      const startAt=offset=>{let lo=0,hi=segments.length;while(lo<hi){const mid=(lo+hi)>>1;if(segments[mid].end<=offset)lo=mid+1;else hi=mid}const segment=segments[lo];return segment?{node:segment.node,offset:Math.max(0,offset-segment.start)}:null};
      const endAt=offset=>{let lo=0,hi=segments.length;while(lo<hi){const mid=(lo+hi)>>1;if(segments[mid].start<offset)lo=mid+1;else hi=mid}const segment=segments[lo-1];return segment?{node:segment.node,offset:Math.min(segment.node.length,offset-segment.start)}:null};
      while((match=expression.exec(text))&&ranges.length<10000){if(!match[0].length){expression.lastIndex++;continue}const start=startAt(match.index),end=endAt(match.index+match[0].length);if(!start||!end)continue;const range=document.createRange();range.setStart(start.node,start.offset);range.setEnd(end.node,end.offset);if(!range.collapsed)ranges.push(range)}
    }
    let index=next&&previous?.query===query&&previous.matchCase===matchCase?previous.index+(forward?1:-1):(forward?0:ranges.length-1);
    if(ranges.length){index=(index%ranges.length+ranges.length)%ranges.length;const selection=getSelection();selection.removeAllRanges();selection.addRange(ranges[index]);ranges[index].startContainer.parentElement?.scrollIntoView({block:'center',inline:'nearest'})}else{index=-1;getSelection()?.removeAllRanges()}
    // Native selection remains a fallback on engines without CSS Highlights.
    // Highlights do not wrap/replace DOM text or alter editable form contents.
    if(globalThis.CSS?.highlights&&globalThis.Highlight){
      let style=document.getElementById('__bandalNativeFindStyle');
      if(!style){style=document.createElement('style');style.id='__bandalNativeFindStyle';style.textContent='::highlight(bandal-find-all){background-color:#ffe08a;color:#171717}::highlight(bandal-find-active){background-color:#f5a623;color:#171717}';(document.head||document.documentElement).append(style)}
      CSS.highlights.set('bandal-find-all',new Highlight(...ranges));
      CSS.highlights.set('bandal-find-active',new Highlight(...(index<0?[]:[ranges[index]])));
    }
    globalThis.__bandalNativeFind={query,matchCase,ranges,index};return {matches:ranges.length,ordinal:index+1};
    """#
    static let image = """
    const image=document.elementFromPoint(x,y)?.closest('img');if(!image)return null;
    try{const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;if(!canvas.width||canvas.width*canvas.height>16000000)return null;canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png')}catch{return null}
    """
}
