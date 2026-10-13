import UIKit
import WebKit

/// The same desktop player/toolbar run in a small app window. External video
/// pages remain separate WKWebViews with their source browsing data store.
@MainActor
final class DesktopMiniPlayer: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    var emit: (String, Any) -> Void = { _, _ in }
    var websiteDataStore: ([String: Any]) throws -> WKWebsiteDataStore = { _ in .nonPersistent() }
    private let runtime: DesktopRuntime
    private weak var container: UIView?
    private var panel: UIView?
    private var player: WKWebView?
    private var chrome: WKWebView?
    private var source: [String: Any]?
    private var position = 0.0, rate = 1.0, paused = true
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private let world = WKContentWorld.world(name: "bandal-mini-player")
    init(runtime: DesktopRuntime) { self.runtime = runtime }
    func attach(to view: UIView) { container = view }
    func canHandle(_ channel: String) -> Bool { ["pip:open", "pip:close", "pip:restore", "pip:getState", "pip:report", "pip:moveBy"].contains(channel) }
    var state: [String: Any] { ["open": panel != nil, "source": source as Any? ?? NSNull(), "positionSec": position, "playbackRate": rate, "paused": paused] }
    func handle(_ channel: String, _ request: [String: Any]) async throws -> Any {
        switch channel {
        case "pip:open": try await open(request)
        case "pip:close": close()
        case "pip:restore": restore()
        case "pip:getState": return state
        case "pip:report": try await report(request)
        case "pip:moveBy":
            guard let dx = request["dx"] as? Double, let dy = request["dy"] as? Double, dx.isFinite, dy.isFinite else { throw DesktopRuntimeError("플레이어 위치를 확인해 주세요.") }
            if let panel { panel.frame.origin.x += CGFloat(max(-4096, min(dx, 4096))); panel.frame.origin.y += CGFloat(max(-4096, min(dy, 4096))); layout() }
        default: throw DesktopRuntimeError("Unknown mini player operation")
        }
        return ["ok": true]
    }
    private func trustedView(_ query: [URLQueryItem]) -> WKWebView {
        let configuration = WKWebViewConfiguration(), assets = DesktopAssets(runtime: runtime)
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(assets, forURLScheme: "bandal-app")
        configuration.setURLSchemeHandler(assets, forURLScheme: "bandal-media")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bandal")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.scrollView.isScrollEnabled = false; view.isOpaque = false; view.backgroundColor = .clear
        var url = URLComponents(string: "bandal-app://shell/pip.html")!; url.queryItems = query
        view.load(URLRequest(url: url.url!)); return view
    }
    private func open(_ request: [String: Any]) async throws {
        guard let source = request["source"] as? [String: Any], let kind = source["kind"] as? String, let container else { throw DesktopRuntimeError("재생할 영상을 확인해 주세요.") }
        let video: WKWebView, toolbar: WKWebView?
        if kind == "local" {
            guard let course = source["courseId"] as? String, let path = source["relPath"] as? String,
                  let _ = try await runtime.invokePrivate("nativeMaterial:path", request: ["courseId": course, "relPath": path]) as? String else { throw DesktopRuntimeError("영상 자료를 확인해 주세요.") }
            video = trustedView([.init(name: "course", value: course), .init(name: "rel", value: path), .init(name: "title", value: source["title"] as? String ?? (path as NSString).lastPathComponent)])
            toolbar = nil
        } else if kind == "web" {
            guard let address = source["url"] as? String, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw DesktopRuntimeError("영상 사이트 주소를 확인해 주세요.") }
            let config = WKWebViewConfiguration(); config.websiteDataStore = try websiteDataStore(source)
            config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = []
            video = WKWebView(frame: .zero, configuration: config); video.navigationDelegate = self
            video.load(URLRequest(url: url)); toolbar = trustedView([.init(name: "view", value: "toolbar")])
        } else { throw DesktopRuntimeError("지원하지 않는 영상 소스입니다.") }
        close()
        self.source = source; position = Self.number(request["positionSec"], fallback: 0, minimum: 0); rate = Self.number(request["playbackRate"], fallback: 1, minimum: 0.1); paused = request["paused"] as? Bool ?? false
        let panel = UIView(); panel.backgroundColor = .black; panel.layer.cornerRadius = 8; panel.clipsToBounds = true
        let width = min(480, max(240, container.bounds.width - 32))
        panel.frame = CGRect(x: container.bounds.width - width - 24, y: container.bounds.height - width * 9 / 16 - 24, width: width, height: width * 9 / 16)
        panel.addSubview(video); if let toolbar { panel.addSubview(toolbar) }
        self.panel = panel; self.player = video; chrome = toolbar
        container.addSubview(panel); layout(); emit("pip:state", state)
        if kind == "web" {
            let current = generation
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, self.generation == current, self.player === video else { return }
                    if let snapshot = try? await video.callAsyncJavaScript("const v=document.querySelector('[data-bandal-pip-video],video'); return v ? {positionSec:v.currentTime,playbackRate:v.playbackRate,paused:v.paused}:null", arguments: [:], in: nil, contentWorld: self.world) as? [String: Any], self.generation == current {
                        try? await self.report(snapshot)
                    }
                }
            }
        }
    }
    private static func number(_ value: Any?, fallback: Double, minimum: Double) -> Double {
        guard let number = value as? Double, number.isFinite, number >= minimum else { return fallback }; return number
    }
    private func report(_ report: [String: Any]) async throws {
        guard let source else { return }
        position = Self.number(report["positionSec"], fallback: position, minimum: 0)
        rate = Self.number(report["playbackRate"], fallback: rate, minimum: 0.1); paused = report["paused"] as? Bool ?? paused
        if let aspect = report["aspect"] as? Double, aspect.isFinite, aspect > 0.2, aspect < 8, let panel { panel.frame.size.height = panel.bounds.width / aspect; layout() }
        emit("pip:state", state)
        if source["kind"] as? String == "local", let course = source["courseId"] as? String, let path = source["relPath"] as? String {
            let snapshotPosition = position, snapshotRate = rate
            let previous = try await runtime.invoke("media:getProgress", request: ["courseId": course, "relPath": path]) as? [String: Any]
            _ = try await runtime.invoke("media:setProgress", request: ["courseId": course, "relPath": path, "positionSec": snapshotPosition, "playbackRate": snapshotRate, "durationSec": previous?["durationSec"] ?? NSNull()])
        }
    }
    func layout() {
        guard let panel, let container else { return }
        let area = container.bounds.inset(by: container.safeAreaInsets).insetBy(dx: 8, dy: 8)
        panel.frame.size.width = min(panel.frame.width, max(1, area.width)); panel.frame.size.height = min(panel.frame.height, max(1, area.height))
        panel.frame.origin.x = min(max(panel.frame.minX, area.minX), area.maxX - panel.frame.width)
        panel.frame.origin.y = min(max(panel.frame.minY, area.minY), area.maxY - panel.frame.height)
        player?.frame = panel.bounds; chrome?.frame = CGRect(x: 0, y: 0, width: panel.bounds.width, height: 44)
        container.bringSubviewToFront(panel)
    }
    private func close() {
        generation = UUID(); polling?.cancel(); polling = nil
        for view in [player, chrome].compactMap({ $0 }) { view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "bandal", contentWorld: .page); view.removeFromSuperview() }
        player = nil; chrome = nil; panel?.removeFromSuperview(); panel = nil; source = nil; position = 0; rate = 1; paused = true
        emit("pip:state", state)
    }
    private func restore() {
        guard let source else { return }
        let payload = source.merging(["positionSec": position, "playbackRate": rate]) { _, new in new }
        close(); emit(source["kind"] as? String == "local" ? "ui:openMaterial" : "ui:openUrl", payload)
    }
    func receive(_ channel: String, _ payload: Any) {
        for view in [source?["kind"] as? String == "local" ? player : nil, chrome].compactMap({ $0 }) {
            view.callAsyncJavaScript("window.__bandalReceive?.(channel,payload)", arguments: ["channel": channel, "payload": payload], in: nil, in: .page, completionHandler: nil)
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard (message.webView === chrome || source?["kind"] as? String == "local" && message.webView === player), message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "bandal-app", message.frameInfo.securityOrigin.host == "shell", message.frameInfo.request.url?.path == "/pip.html",
              let value = message.body as? [String: Any], let channel = value["channel"] as? String,
              ["settings:get", "pip:getState", "pip:report", "pip:moveBy", "pip:restore", "pip:close"].contains(channel) else { replyHandler(nil, "Invalid mini player request"); return }
        Task {
            do { replyHandler(try await (channel == "settings:get" ? runtime.invoke(channel) : handle(channel, value["request"] as? [String: Any] ?? [:])), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === player, let source else { return }
        if source["kind"] as? String == "local" { receive("pip:seek", ["positionSec": position, "playbackRate": rate, "play": !paused]); return }
        let current = generation
        Task {
            do {
                let bundle = try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("DesktopNative/web-pip.js"), encoding: .utf8)
                let script = try await view.callAsyncJavaScript(bundle + ";return BandalWebPip.webPipIsolationSource(source,position,rate,paused)", arguments: ["source": source, "position": position, "rate": rate, "paused": paused], in: nil, contentWorld: world) as? String
                guard let script, current == generation, view === player else { return }
                let result = try await view.callAsyncJavaScript("return await (" + script + ")", arguments: [:], in: nil, contentWorld: world) as? [String: Any]
                guard current == generation, view === player else { return }
                guard result?["ready"] as? Bool == true else { throw DesktopRuntimeError("이 사이트의 영상만 작은 창으로 분리하지 못했어요.") }
                if let aspect = result?["aspect"] { try await report(["aspect": aspect]) }
            } catch {
                guard current == generation else { return }
                emit("pip:error", ["message": error.localizedDescription]); restore()
            }
        }
    }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        guard view === player || view === chrome else { return }
        emit("pip:error", ["message": "영상 재생 프로세스가 종료되어 원래 화면으로 돌아갑니다."]); restore()
    }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(view, error) }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(view, error) }
    private func navigationFailed(_ view: WKWebView, _ error: Error) {
        guard view === player || view === chrome,
              (error as NSError).code != NSURLErrorCancelled else { return }
        emit("pip:error", ["message": "영상을 불러오지 못해 원래 화면으로 돌아갑니다. " + error.localizedDescription])
        restore()
    }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if view === chrome || source?["kind"] as? String == "local" {
            decisionHandler(url.scheme == "bandal-app" && url.host == "shell" && url.path == "/pip.html" ? .allow : .cancel)
        } else { decisionHandler(["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil ? .allow : .cancel) }
    }
}
