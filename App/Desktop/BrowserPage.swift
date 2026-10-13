import Foundation
import UIKit
import WebKit

@MainActor
final class DesktopBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    weak var host: DesktopBrowserHost?
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
    private var observations: [NSKeyValueObservation] = []
    var state: [String: Any] {
        let cached = suspended?.state ?? restoring?.state
        return ["id": id, "stateRevision": revision, "authDocumentId": documentID,
         "url": liveWebView?.url?.absoluteString ?? cached?["url"] ?? "about:blank",
         "title": liveWebView?.title ?? cached?["title"] ?? "", "httpStatus": httpStatus,
         "loading": liveWebView?.isLoading ?? false,
         "canGoBack": liveWebView?.canGoBack ?? cached?["canGoBack"] ?? false,
         "canGoForward": liveWebView?.canGoForward ?? cached?["canGoForward"] ?? false]
    }
    init(host: DesktopBrowserHost, id: Int, tabID: String, profileID: String, isPrivate: Bool, courseID: String?, configuration supplied: WKWebViewConfiguration?) {
        self.host = host; self.id = id; self.tabID = tabID; self.profileID = profileID; self.isPrivate = isPrivate; self.courseID = courseID
        let configuration = supplied ?? WKWebViewConfiguration()
        if supplied == nil { configuration.websiteDataStore = host.persistence!.dataStore(profile: profileID, isPrivate: isPrivate) }
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
        webView.allowsBackForwardNavigationGestures = host?.swipeNavigation ?? true
        webView.isInspectable = false
        webView.accessibilityIdentifier = "desktop-browser-\(tabID)"
        let focus = UITapGestureRecognizer(target: self, action: #selector(focused(_:)))
        focus.cancelsTouchesInView = false; focus.delegate = self
        webView.addGestureRecognizer(focus)
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView else { return }; self.send("page-title-updated", ["title": webView.title ?? ""]) } },
            webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView else { return }; self.send("did-navigate-in-page", ["url": webView.url?.absoluteString ?? "", "isMainFrame": true]) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in Task { @MainActor in guard let self, let webView, self.liveWebView === webView else { return }; self.send(webView.isLoading ? "did-start-loading" : "did-stop-loading") } }
        ]
        return webView
    }
    /// Only a hidden, reloadable reading page is eligible. Interaction state
    /// stays in memory; form/JS application state is never promised portable.
    func suspendIfSafe() async -> Bool {
        guard let view = liveWebView, bounds == nil, !preventsSuspension,
              !view.isLoading, restoring == nil, view.url?.scheme == "http" || view.url?.scheme == "https",
              view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
              host?.downloads.values.contains(where: { $0.page === self && $0.state == "progressing" }) != true else { return false }
        let identity = documentID
        guard await view.requestMediaPlaybackState() == .none else { return false }
        guard let position = (try? await view.callAsyncJavaScript(BrowserMemoryScripts.canSuspend, arguments: [:], in: nil, contentWorld: BrowserMemoryScripts.world)) as? [String: Double],
              let x = position["x"], let y = position["y"], x.isFinite, y.isFinite,
              let host, host.pages[tabID] === self, liveWebView === view, documentID == identity,
              bounds == nil, !preventsSuspension, !view.isLoading,
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
        suspended = nil; restoring = nil
    }
    func send(_ name: String, _ detail: [String: Any] = [:]) {
        guard host?.pages[tabID] === self else { return }
        revision += 1
        host?.emit("browser:page-event", ["tabId": tabID, "name": name, "state": state, "detail": detail])
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
            if let self, let params = try? await webView.callAsyncJavaScript(BrowserScripts.contextMenu, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] {
                self.send("context-menu", ["params": params])
            }
            completionHandler(nil)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
            host?.emit("browser:external-scheme", ["url": url.absoluteString, "origin": webView.url.flatMap(DesktopBrowserHost.origin) ?? "", "outcome": "blocked"])
            decisionHandler(.cancel); return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { httpStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0 }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment") ? .download : .allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The first navigation belongs to interactionState restoration; a
        // later navigation while scroll restoration runs invalidates that work.
        if scrollRestoration != nil { scrollRestoration?.cancel(); scrollRestoration = nil; restoring = nil }
        documentID = UUID().uuidString; httpStatus = 0; send("did-start-loading")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { send("did-navigate", ["url": webView.url?.absoluteString ?? "", "httpResponseCode": httpStatus]) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        let error = error as NSError
        scrollRestoration?.cancel(); scrollRestoration = nil
        restoring = nil
        send("did-fail-load", ["errorCode": error.code == NSURLErrorCancelled ? -3 : error.code, "errorDescription": error.localizedDescription,
                              "validatedURL": (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? webView.url?.absoluteString ?? "", "isMainFrame": true])
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { send("render-process-gone", ["reason": "web-content-process-terminated"]) }
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
    static let find = """
    const previous=globalThis.__bandalNativeFind;
    let ranges=[];
    if(next&&previous?.query===query&&previous.matchCase===matchCase){ranges=previous.ranges.filter(r=>r.startContainer.isConnected)}
    else if(query){const walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT,{acceptNode(node){const p=node.parentElement;if(!p||p.closest('script,style,noscript,textarea,input,[hidden]')||!p.getClientRects().length)return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}});let node;while((node=walker.nextNode())&&ranges.length<10000){const text=matchCase?node.textContent:node.textContent.toLocaleLowerCase();const q=matchCase?query:query.toLocaleLowerCase();let pos=0;while((pos=text.indexOf(q,pos))>=0){const r=document.createRange();r.setStart(node,pos);r.setEnd(node,pos+query.length);ranges.push(r);pos+=Math.max(query.length,1);if(ranges.length>=10000)break}}}
    let index=next&&previous?.query===query?previous.index+(forward?1:-1):0;
    if(ranges.length){index=(index%ranges.length+ranges.length)%ranges.length;const selection=getSelection();selection.removeAllRanges();selection.addRange(ranges[index]);ranges[index].startContainer.parentElement?.scrollIntoView({block:'center',inline:'nearest'})}else{index=-1;getSelection()?.removeAllRanges()}
    globalThis.__bandalNativeFind={query,matchCase,ranges,index};return {matches:ranges.length,ordinal:index+1};
    """
    static let image = """
    const image=document.elementFromPoint(x,y)?.closest('img');if(!image)return null;
    try{const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;if(!canvas.width||canvas.width*canvas.height>16000000)return null;canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png')}catch{return null}
    """
}
