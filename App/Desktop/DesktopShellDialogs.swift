import UIKit
import WebKit

/// A WebKit completion belongs to one dialog and must settle exactly once,
/// including navigation, backgrounding and controller teardown.
@MainActor
final class DesktopDialogCompletion<Value> {
    private var callback: ((Value) -> Void)?
    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    func finish(_ value: Value) { let pending = callback; callback = nil; pending?(value) }
}

@MainActor
final class DesktopShellDialogs: NSObject, WKUIDelegate {
    enum Response { case accepted, cancelled, text(String) }
    weak var presenter: UIViewController?
    weak var webView: WKWebView?
    private struct Request {
        let id = UUID()
        let make: (@escaping (Response) -> Void) -> UIAlertController
        let answer: (Response) -> Void
        let cancel: () -> Void
    }
    private var requests: [Request] = []
    private var active: (request: Request, alert: UIAlertController)?
    private var dismissing: UUID?
    var activeDialogIdentifier: UUID? { active?.request.id }

    /// Shared by UIKit actions and the isolated WK regression fixture. The
    /// request identifier prevents a late action from answering a newer dialog.
    func resolveDialog(_ identifier: UUID, response: Response) {
        guard let current = active, current.request.id == identifier else { return }
        current.request.answer(response)
        finishCurrent(identifier)
    }

    func cancelAll() {
        let waiting = requests; requests.removeAll()
        let current = active; active = nil; dismissing = nil
        current?.request.cancel(); waiting.forEach { $0.cancel() }
        current?.alert.dismiss(animated: false)
    }

    private func trusted(_ view: WKWebView, _ frame: WKFrameInfo) -> Bool {
        UIApplication.shared.applicationState == .active && view === webView && frame.isMainFrame && frame.securityOrigin.protocol == "bandal-app" && frame.securityOrigin.host == "shell"
    }

    private func enqueue(_ request: Request) { requests.append(request); presentNext() }
    private func presentNext() {
        guard active == nil, dismissing == nil, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            request.cancel(); presentNext(); return
        }
        let alert = request.make { [weak self] response in self?.resolveDialog(request.id, response: response) }
        active = (request, alert)
        presenter.present(alert, animated: true)
        // UIAlertController owns its presentation-controller delegate. UIKit
        // rejects replacing it for .alert; lifecycle cancellation is explicit.
    }

    private func finishCurrent(_ id: UUID) {
        guard let current = active, current.request.id == id else { return }
        active = nil; dismissing = id
        current.alert.dismiss(animated: true) { [weak self] in
            guard let self, self.dismissing == id else { return }
            self.dismissing = nil; self.presentNext()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let completion = DesktopDialogCompletion<Void> { _ in completionHandler() }
        guard trusted(webView, frame) else { completion.finish(()); return }
        enqueue(Request(make: { respond in
            let alert = UIAlertController(title: "반달", message: String(message.prefix(10_000)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in respond(.accepted) })
            return alert
        }, answer: { _ in completion.finish(()) }, cancel: { completion.finish(()) }))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let completion = DesktopDialogCompletion(completionHandler)
        guard trusted(webView, frame) else { completion.finish(false); return }
        enqueue(Request(make: { respond in
            let alert = UIAlertController(title: "반달", message: String(message.prefix(10_000)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in respond(.cancelled) })
            alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in respond(.accepted) })
            return alert
        }, answer: { response in
            if case .accepted = response { completion.finish(true) } else { completion.finish(false) }
        }, cancel: { completion.finish(false) }))
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let completion = DesktopDialogCompletion(completionHandler)
        guard trusted(webView, frame) else { completion.finish(nil); return }
        enqueue(Request(make: { respond in
            let alert = UIAlertController(title: "반달", message: String(prompt.prefix(10_000)), preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in respond(.cancelled) })
            alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak alert] _ in respond(.text(alert?.textFields?.first?.text ?? "")) })
            return alert
        }, answer: { response in
            if case .text(let value) = response { completion.finish(value) } else { completion.finish(nil) }
        }, cancel: { completion.finish(nil) }))
    }
}

/// WKUserContentController retains its handler. Keep the controller out of
/// that retain cycle so SwiftUI teardown can release its runtime and timers.
@MainActor
final class DesktopScriptMessageRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: DesktopShellController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "The app screen has closed"); return }
        owner.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}
