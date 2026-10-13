import Foundation
import WebKit

/// Only static, anonymously fetched HTML enters this isolated parser. The page
/// is never navigated to the article origin; scripts/subresources do not run.
@MainActor
final class DesktopArticleService {
    var sourceTab: ((String, String, String, String) async throws -> [String: Any])?
    private let client: PublicArticleClient
    init(client: PublicArticleClient = PublicArticleClient()) { self.client = client }
    func extract(_ request: [String: Any]) async throws -> [String: Any] {
        guard let address = request["url"] as? String else { throw DesktopRuntimeError("기사 주소를 확인해 주세요.") }
        let source = try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("DesktopNative/article-extraction.js"), encoding: .utf8)
        if let tab = request["tabId"] as? String {
            guard let course = request["courseId"] as? String, let sourceTab else { throw DesktopRuntimeError("원문 브라우저 탭을 확인하지 못했어요.") }
            return try await sourceTab(course, tab, address, source)
        }
        let result = try await client.load(address)
        try Task.checkCancellation()
        let parser = ArticleHTMLParser()
        let raw = try await parser.extract(html: result.html, url: result.url.absoluteString, script: source)
        return ["raw": raw, "sourceUrl": result.url.absoluteString, "access": "public"]
    }
}

@MainActor
private final class ArticleHTMLParser: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private var ready: CheckedContinuation<Void, Error>?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init(); view.navigationDelegate = self
    }
    func extract(html: String, url: String, script: String) async throws -> [String: Any] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                view.loadHTMLString("<html><head><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; base-uri 'none'; form-action 'none'\"></head><body></body></html>", baseURL: nil)
            }
            try Task.checkCancellation()
            let function = """
            const detached = new DOMParser().parseFromString(html, 'text/html');
            detached.querySelectorAll('base').forEach(node => node.remove());
            const base = detached.createElement('base'); base.href = url; detached.head.prepend(base);
            return ((document, location) => { return \(script) })(detached, {href: url});
            """
            let value = try await view.callAsyncJavaScript(function, arguments: ["html": html, "url": url], in: nil, contentWorld: .world(name: "bandal-article-parser"))
            guard let raw = value as? [String: Any] else { throw DesktopRuntimeError("기사 본문을 추출하지 못했어요.") }
            return raw
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.view.stopLoading(); let pending = self.ready; self.ready = nil; pending?.resume(throwing: CancellationError())
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let pending = ready; ready = nil; pending?.resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let pending = ready; ready = nil; pending?.resume(throwing: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.webView(webView, didFail: navigation, withError: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { let pending = ready; ready = nil; pending?.resume(throwing: URLError(.networkConnectionLost)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}
