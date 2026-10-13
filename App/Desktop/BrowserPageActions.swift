import Foundation
import UIKit

extension DesktopBrowserHost {
    static func shareablePageURL(_ url: URL?) throws -> URL {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else {
            throw DesktopBrowserError.unavailable("웹페이지를 연 뒤 주소를 공유해 주세요.")
        }
        // HTTP credentials belong to the session, not the shared URL.
        components.user = nil; components.password = nil
        guard let result = components.url else { throw DesktopBrowserError.invalid("공유 주소") }
        return result
    }
    func sharePage(_ page: DesktopBrowserPage) async throws -> Any {
        let url = try Self.shareablePageURL(page.webView.url)
        guard let presenter = presentingController, presenter.viewIfLoaded?.window != nil,
              !isPresentingPageShare, !presenter.isBeingDismissed, presenter.presentedViewController == nil else {
            throw DesktopBrowserError.unavailable("다른 창을 닫은 뒤 다시 공유해 주세요.")
        }
        isPresentingPageShare = true; defer { isPresentingPageShare = false }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let anchor = container ?? presenter.view!
        share.popoverPresentationController?.sourceView = anchor
        share.popoverPresentationController?.sourceRect = CGRect(x: max(0, anchor.bounds.maxX - 48), y: min(22, anchor.bounds.midY), width: 44, height: 1)
        // Activity providers can prepare asynchronously before UIKit attaches
        // the sheet. Wait for presentation, keeping duplicate taps excluded.
        await withCheckedContinuation { continuation in
            presenter.present(share, animated: true) { continuation.resume() }
        }
        guard share.presentingViewController != nil else { throw DesktopBrowserError.unavailable("공유 창을 열지 못했습니다. 다시 시도해 주세요.") }
        return ["ok": true]
    }
}
