import UIKit
import WebKit

/// App-local capture. The original desktop selection renderer receives only a
/// frozen image and its own selection IPC; it has no workspace or browser bridge.
@MainActor
final class DesktopCaptureService: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    typealias Snapshot = (UIView) async throws -> UIImage
    private let runtime: DesktopRuntime
    private let snapshot: Snapshot
    private weak var container: UIView?
    private var busy = false
    private var generation = UUID()
    private var image: UIImage?
    private var viewport = CGSize.zero
    private var completion: CheckedContinuation<Any, Error>?
    private var backgroundObserver: NSObjectProtocol?
    private(set) var selectionWebView: WKWebView?

    init(runtime: DesktopRuntime, snapshot: Snapshot? = nil) {
        self.runtime = runtime
        self.snapshot = snapshot ?? Self.captureView
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }
    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
    func attach(to view: UIView) { container = view }
    func canHandle(_ channel: String) -> Bool { ["assistant:capture", "desktopAgent:permissionStatus", "desktopAgent:openPermissionSettings"].contains(channel) }
    func layout() {
        guard let web = selectionWebView, let container else { return }
        guard container.bounds.size == viewport else { cancel(); return }
        container.bringSubviewToFront(web)
    }

    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "desktopAgent:permissionStatus": return ["state": "unsupported", "platform": "ios"]
        case "desktopAgent:openPermissionSettings": throw DesktopRuntimeError("iPad에서는 다른 앱의 화면을 읽거나 조작하는 시스템 권한을 제공하지 않습니다. 반달 내부 화면은 채팅의 캡처 버튼을 사용하세요.", code: "ENOSYS")
        default: break
        }
        guard channel == "assistant:capture", let region = request["region"] as? Bool else { throw DesktopRuntimeError("화면 캡처 요청을 확인해 주세요.") }
        guard !busy, let container, container.window != nil, !container.isHidden else { throw DesktopRuntimeError("열린 화면 캡처를 마친 뒤 다시 시도해 주세요.") }
        busy = true; let operation = UUID(); generation = operation
        defer { if generation == operation { busy = false } }
        let size = container.bounds.size
        let captured = try await snapshot(container)
        try Task.checkCancellation()
        guard generation == operation, container.bounds.size == size else { throw CancellationError() }
        if !region { return try Self.attachment(captured) }
        image = captured; viewport = size
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.completion = continuation
                self.showSelection(in: container)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(operation: operation) } })
    }

    func cancel(operation: UUID? = nil) {
        guard operation == nil || operation == generation else { return }
        finish(.success(NSNull()))
    }

    private func showSelection(in container: UIView) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DesktopAssets(runtime: runtime), forURLScheme: "bandal-app")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bandal")
        let webView = CaptureSelectionWebView(frame: container.bounds, configuration: config)
        webView.onSizeChange = { [weak self] size in
            guard let self, size != self.viewport else { return }
            self.cancel()
        }
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityIdentifier = "bandal-screen-selection"
        selectionWebView = webView
        container.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "bandal-app://shell/capture.html")!))
    }

    private func finish(_ result: Result<Any, Error>) {
        generation = UUID(); busy = false
        selectionWebView?.stopLoading()
        selectionWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "bandal", contentWorld: .page)
        selectionWebView?.navigationDelegate = nil
        selectionWebView?.removeFromSuperview()
        selectionWebView = nil; image = nil; viewport = .zero
        let pending = completion; completion = nil
        pending?.resume(with: result)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === selectionWebView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "bandal-app", message.frameInfo.securityOrigin.host == "shell",
              message.frameInfo.request.url?.path == "/capture.html",
              let body = message.body as? [String: Any], body["channel"] as? String == "assistant:selection",
              let request = body["request"] as? [String: Any], let action = request["action"] as? String,
              let image, completion != nil else { replyHandler(nil, "Invalid capture origin or operation"); return }
        do {
            switch action {
            case "get":
                guard let png = image.pngData(), png.count <= 32 * 1024 * 1024 else { throw DesktopRuntimeError("캡처 이미지 크기 한도를 초과했습니다.") }
                replyHandler(["image": "data:image/png;base64," + png.base64EncodedString()], nil)
            case "cancel": replyHandler([:], nil); finish(.success(NSNull()))
            case "select":
                guard let value = request["rect"] as? [String: Any], let x = value["x"] as? Double, let y = value["y"] as? Double,
                      let width = value["width"] as? Double, let height = value["height"] as? Double else { throw DesktopRuntimeError("선택한 영역을 확인해 주세요.") }
                let attachment = try Self.attachment(Self.crop(image, rect: CGRect(x: x, y: y, width: width, height: height), viewport: viewport))
                replyHandler([:], nil); finish(.success(attachment))
            default: throw DesktopRuntimeError("지원하지 않는 화면 선택 요청입니다.")
            }
        } catch { replyHandler(nil, error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === selectionWebView, action.targetFrame?.isMainFrame == true, let url = action.request.url,
              url.scheme == "bandal-app", url.host == "shell", url.path == "/capture.html" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === selectionWebView { finish(.failure(error)) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === selectionWebView { finish(.failure(error)) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === selectionWebView { finish(.failure(DesktopRuntimeError("화면 선택기가 종료되었습니다. 다시 캡처해 주세요."))) } }

    /// Matches shared/screenGeometry.cropPixels, including outward pixel rounding.
    static func crop(_ image: UIImage, rect: CGRect, viewport: CGSize) throws -> UIImage {
        guard let bitmap = image.cgImage, image.imageOrientation == .up,
              [rect.origin.x, rect.origin.y, rect.width, rect.height, viewport.width, viewport.height].allSatisfy({ $0.isFinite }),
              viewport.width > 0, viewport.height > 0, rect.width >= 4, rect.height >= 4,
              rect.intersects(CGRect(origin: .zero, size: viewport)) else { throw DesktopRuntimeError("선택한 영역이 올바르지 않습니다.") }
        let sx = CGFloat(bitmap.width) / viewport.width, sy = CGFloat(bitmap.height) / viewport.height
        let x = max(0, min(CGFloat(bitmap.width - 1), floor(rect.minX * sx)))
        let y = max(0, min(CGFloat(bitmap.height - 1), floor(rect.minY * sy)))
        let right = max(x + 1, min(CGFloat(bitmap.width), ceil(rect.maxX * sx)))
        let bottom = max(y + 1, min(CGFloat(bitmap.height), ceil(rect.maxY * sy)))
        guard let cropped = bitmap.cropping(to: CGRect(x: x, y: y, width: right - x, height: bottom - y)) else { throw DesktopRuntimeError("선택한 영역을 자르지 못했습니다.") }
        return UIImage(cgImage: cropped)
    }
    static func attachment(_ image: UIImage) throws -> [String: String] {
        guard let bitmap = image.cgImage else { throw DesktopRuntimeError("화면 이미지를 읽지 못했습니다.") }
        let ratio = min(1, 1800 / CGFloat(max(bitmap.width, bitmap.height)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: max(1, floor(CGFloat(bitmap.width) * ratio)), height: max(1, floor(CGFloat(bitmap.height) * ratio)))
        let output = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = output.pngData(), png.count <= 16 * 1024 * 1024 else { throw DesktopRuntimeError("화면 첨부 이미지 크기 한도를 초과했습니다.") }
        return ["mediaType": "image/png", "dataBase64": png.base64EncodedString()]
    }

    private static func captureView(_ container: UIView) async throws -> UIImage {
        let bounds = container.bounds, window = container.window
        guard let window, bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw DesktopRuntimeError("캡처할 반달 화면이 없습니다.") }
        let scale = min(window.screen.scale, 3)
        guard bounds.width * bounds.height * scale * scale <= 24_000_000 else { throw DesktopRuntimeError("화면 캡처 크기 한도를 초과했습니다.") }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let base = renderer.image { _ in container.drawHierarchy(in: CGRect(origin: .zero, size: bounds.size), afterScreenUpdates: true) }
        var layers: [(UIImage, CGRect, CGFloat)] = []
        func collect(_ view: UIView, clip: CGRect, alpha: CGFloat) async throws {
            guard !view.isHidden, view.alpha > 0 else { return }
            let frame = view.convert(view.bounds, to: container)
            let visible = frame.intersection(clip)
            guard !visible.isNull, !visible.isEmpty else { return }
            if let webView = view as? WKWebView {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = webView.convert(visible, from: container)
                configuration.snapshotWidth = NSNumber(value: Double(visible.width))
                let url = webView.url
                let image = try await webView.takeSnapshot(configuration: configuration)
                guard container.window === window, container.bounds == bounds, webView.url == url, webView.convert(webView.bounds, to: container) == frame else { throw CancellationError() }
                layers.append((image, visible.offsetBy(dx: -bounds.minX, dy: -bounds.minY), alpha * view.alpha))
                return
            }
            for child in view.subviews { try await collect(child, clip: view.clipsToBounds ? visible : clip, alpha: alpha * view.alpha) }
        }
        try await collect(container, clip: bounds, alpha: 1)
        try Task.checkCancellation()
        return renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: bounds.size))
            for (image, frame, alpha) in layers { image.draw(in: frame, blendMode: .normal, alpha: alpha) }
        }
    }
}

@MainActor
private final class CaptureSelectionWebView: WKWebView {
    var onSizeChange: ((CGSize) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onSizeChange?(bounds.size) }
}
