import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

/// A tab owns its web view, so changing panes never creates a new browsing session.
@MainActor
final class BrowserSession: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    let webView: WKWebView
    @Published private(set) var url: URL?
    @Published private(set) var title = "새 브라우저 탭"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published var errorMessage: String?
    var onOpenTab: (URL, Bool) -> Void = { _, _ in }
    var onCreateSession: ((BrowserSession) -> Void)?
    var onDownload: (URL) -> Void = { _ in }
    var onStateChange: (URL?, String) -> Void = { _, _ in }
    var onClose: (() -> Void)?
    weak var presenter: UIViewController?
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: (WKDownload, URL?)] = [:]
    var hasActiveDownloads: Bool { !downloads.isEmpty }

    init(id: UUID = UUID(), url: URL? = nil, isPrivate: Bool = false, configuration suppliedConfiguration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.isPrivate = isPrivate
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        if suppliedConfiguration == nil { configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default() }
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // External websites deliberately have no application message handlers or scripts.
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.url = view.url
                    self.onStateChange(self.url, self.title)
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.title = view.title ?? "브라우저"
                    self.onStateChange(self.url, self.title)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.progress = view.estimatedProgress }
            }
        ]
        if let url { navigate(to: url) }
    }

    static func destination(for address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return url }
        if !value.contains(where: \.isWhitespace), !value.contains("://"),
           value.contains(".") || value.hasPrefix("localhost"),
           let url = URL(string: "https://" + value), url.host != nil { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        return search.url
    }

    func navigate(to destination: URL) {
        guard ["http", "https"].contains(destination.scheme?.lowercased() ?? "") else {
            errorMessage = "이 주소는 브라우저에서 열 수 없어요."
            return
        }
        errorMessage = nil
        url = destination
        webView.load(URLRequest(url: destination))
    }

    func submit(_ address: String) {
        if let destination = Self.destination(for: address) { navigate(to: destination) }
    }

    func reload() {
        errorMessage = nil
        if webView.url != nil { webView.reload() }
        else if let url { navigate(to: url) }
    }

    func stop() { webView.stopLoading() }

    private func track(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = (download, nil)
        download.delegate = self
    }
}

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["https", "http", "about", "blob", "data"].contains(scheme) else {
            errorMessage = "외부 앱을 여는 링크예요. 주소를 복사해 해당 앱에서 열어 주세요."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType?.lowercased()
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || mime == "application/pdf" || disposition.lowercased().contains("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { track(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { track(download) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showNavigationError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showNavigationError(error) }
    private func showNavigationError(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = "메모리를 확보하는 동안 이 페이지가 중단됐어요. 새로고침하면 다시 열립니다. 입력 중이던 웹 양식은 복구되지 않을 수 있어요."
    }
}

extension BrowserSession: WKUIDelegate {
    func webViewDidClose(_ webView: WKWebView) { onClose?() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let create = onCreateSession,
              let destination = navigationAction.request.url,
              ["http", "https", "about"].contains(destination.scheme?.lowercased() ?? "") else { return nil }
        // Returning a view built with WebKit's supplied configuration preserves
        // window.opener, popup POST bodies, and the originating website data store.
        // WebKit performs navigation itself; loading destination again loses POST.
        let child = BrowserSession(isPrivate: isPrivate, configuration: configuration)
        child.url = destination
        child.onCreateSession = onCreateSession
        create(child)
        return child.webView
    }

    // WebKit's built-in iPad file chooser handles <input type=file>, including
    // multiple selection/camera access; no desktop paths or custom JS bridge are used.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter, presenter.presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? "웹 페이지", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter, presenter.presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? "웹 페이지", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter, presenter.presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? "웹 페이지", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }
}

extension BrowserSession: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BandalDownloads", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let leaf = (suggestedFilename as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            let cleaned = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: ":", with: "_")
            let name = String(cleaned.prefix(200))
            let destination = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "다운로드" : name)
            downloads[ObjectIdentifier(download)] = (download, destination)
            completionHandler(destination)
        } catch {
            errorMessage = "다운로드를 저장하지 못했어요: \(error.localizedDescription)"
            completionHandler(nil)
        }
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let (_, destination) = downloads.removeValue(forKey: ObjectIdentifier(download)), let destination { onDownload(destination) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let (_, destination) = downloads.removeValue(forKey: ObjectIdentifier(download)), let destination { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        errorMessage = "다운로드를 완료하지 못했어요: \(error.localizedDescription)"
    }
}
