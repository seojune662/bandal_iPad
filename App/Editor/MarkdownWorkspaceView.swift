import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MarkdownWorkspaceView: View {
    let materialID: String
    let markdown: String
    var onSave: (String) -> Bool
    var onOpenLink: (URL) -> Void = { _ in }
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            MarkdownWebView(materialID: materialID, markdown: markdown, onSave: onSave, onOpenLink: onOpenLink, onError: { error = $0 })
        }
    }
}

/// A separate, local-only WKWebView. The browser never receives this bridge.
private struct MarkdownWebView: UIViewRepresentable {
    let materialID: String
    let markdown: String
    let onSave: (String) -> Bool
    let onOpenLink: (URL) -> Void
    let onError: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(materialID: materialID, markdown: markdown, onSave: onSave, onOpenLink: onOpenLink, onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EditorAssets(), forURLScheme: "bandal-editor")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "bandalEditor")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.isInspectable = false
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "bandal-editor://app/index.html")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSave = onSave
        coordinator.onOpenLink = onOpenLink
        coordinator.onError = onError
        guard coordinator.materialID != materialID || coordinator.markdown != markdown else { return }
        coordinator.materialID = materialID
        coordinator.markdown = markdown
        coordinator.deliverDocument()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Each transaction is already sent without a timer; removing the bridge
        // cannot discard a debounce queue when a tab is closed.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bandalEditor", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        weak var webView: WKWebView?
        var materialID: String
        var markdown: String
        var onSave: (String) -> Bool
        var onOpenLink: (URL) -> Void
        var onError: (String?) -> Void
        private var ready = false
        private var lastDeliveredID: String?
        private var lastDeliveredMarkdown: String?

        init(materialID: String, markdown: String, onSave: @escaping (String) -> Bool, onOpenLink: @escaping (URL) -> Void, onError: @escaping (String?) -> Void) {
            self.materialID = materialID
            self.markdown = markdown
            self.onSave = onSave
            self.onOpenLink = onOpenLink
            self.onError = onError
        }

        func deliverDocument() {
            guard ready, lastDeliveredID != materialID || lastDeliveredMarkdown != markdown else { return }
            lastDeliveredID = materialID
            lastDeliveredMarkdown = markdown
            webView?.callAsyncJavaScript("window.bandalEditor.load(document)", arguments: ["document": ["version": 1, "materialID": materialID, "markdown": markdown]], in: nil, in: .page) { [weak self] result in
                if case .failure(let error) = result { self?.onError("필기를 표시하지 못했어요: \(error.localizedDescription)") }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "bandal-editor",
                  message.frameInfo.securityOrigin.host == "app",
                  message.frameInfo.request.url?.path == "/index.html",
                  message.webView === webView,
                  let body = message.body as? [String: Any],
                  let version = body["version"] as? Int, version == 1,
                  let type = body["type"] as? String else {
                replyHandler(nil, "Invalid editor origin or message")
                return
            }
            switch type {
            case "ready":
                ready = true
                onError(nil)
                deliverDocument()
                replyHandler(["accepted": true], nil)
            case "change":
                guard let id = body["materialID"] as? String, id == materialID,
                      let text = body["markdown"] as? String else {
                    replyHandler(nil, "Invalid editor document")
                    return
                }
                guard text.utf8.count <= 8 * 1024 * 1024, onSave(text) else {
                    let message = "저장 한도를 넘었거나 저장소에 쓸 수 없어 반영하지 못했어요. 내용을 복사해 보관하고 노트를 나누어 주세요."
                    onError(message)
                    replyHandler(nil, message)
                    return
                }
                markdown = text
                lastDeliveredID = id
                lastDeliveredMarkdown = text
                onError(nil)
                replyHandler(["accepted": true], nil)
            case "error":
                onError("편집기를 불러오지 못했어요. 탭을 다시 열어 주세요.")
                replyHandler(["accepted": true], nil)
            default:
                replyHandler(nil, "Unknown editor message")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // Only a user-activated link can leave the local document. The
            // destination is opened by the workspace, never in this bridged view.
            if navigationAction.navigationType == .linkActivated, let url,
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") || (url.scheme == "bandal" && url.host == "material") {
                decisionHandler(.cancel)
                onOpenLink(url)
                return
            }
            decisionHandler(url?.scheme == "bandal-editor" && url?.host == "app" && url?.path == "/index.html" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onError("편집기 리소스를 열지 못했어요: \(error.localizedDescription)") }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            lastDeliveredID = nil
            lastDeliveredMarkdown = nil
            webView.reload()
        }
    }
}

/// Only the built application resources are addressable through this scheme.
private final class EditorAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "bandal-editor", url.host == "app",
              let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let relative = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative).standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard file.path.hasPrefix(allowedRoot), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime: String
        switch file.pathExtension {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        case "json": mime = "application/json"
        default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
