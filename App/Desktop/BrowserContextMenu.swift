import UIKit
import WebKit

extension DesktopBrowserPage {
    /// UIKit's suggested actions include platform editing, lookup and image
    /// actions. Preserve those while adding application-owned tab operations.
    func contextMenuItems(_ values: [String: Any], suggested: [UIMenuElement]) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let text = values["linkURL"] as? String, let url = try? DesktopBrowserHost.navigationURL(text), url.scheme != "about" {
            items.append(UIAction(title: "링크를 새 탭에서 열기", image: UIImage(systemName: "plus.square"), identifier: .init("bandal.open-link")) { [weak self] _ in
                guard let self, let host = self.host, host.pages[self.tabID] === self else { return }
                do { _ = try host.openLinkTab(url, from: self) }
                catch { host.emit("browser:context-action-failed", ["tabId": self.tabID, "message": error.localizedDescription]) }
            })
            items.append(UIAction(title: "링크 주소 복사", image: UIImage(systemName: "link"), identifier: .init("bandal.copy-link")) { _ in UIPasteboard.general.url = url })
            items.append(UIAction(title: "링크 파일 다운로드", image: UIImage(systemName: "arrow.down.circle"), identifier: .init("bandal.download-link")) { [weak self] _ in self?.performContextAction("downloadURL", args: [url.absoluteString]) })
        }
        if values["mediaType"] as? String == "image", let x = values["x"] as? Double, let y = values["y"] as? Double {
            items.append(UIAction(title: "이미지 복사", image: UIImage(systemName: "photo.on.rectangle"), identifier: .init("bandal.copy-image")) { [weak self] _ in self?.performContextAction("copyImageAt", args: [x, y]) })
        }
        if let selected = values["selectionText"] as? String, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = String(selected.prefix(10_000))
            items.append(UIAction(title: "선택한 텍스트로 검색", image: UIImage(systemName: "magnifyingglass"), identifier: .init("bandal.search-selection")) { [weak self] _ in
                guard let self, let host = self.host, host.pages[self.tabID] === self else { return }
                host.emit("browser:search-selection", ["tabId": self.tabID, "text": text])
            })
        }
        return items + suggested
    }
    private func performContextAction(_ action: String, args: [Any]) {
        Task { [weak self] in
            guard let self, let host = self.host, host.pages[self.tabID] === self else { return }
            do { _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": self.tabID, "action": action, "args": args]) }
            catch { host.emit("browser:context-action-failed", ["tabId": self.tabID, "message": error.localizedDescription]) }
        }
    }
}

extension DesktopBrowserHost {
    @discardableResult
    func openLinkTab(_ url: URL, from opener: DesktopBrowserPage) throws -> DesktopBrowserPage {
        guard pages[opener.tabID] === opener, pages.count < 64 else { throw DesktopBrowserError.unavailable("새 탭을 열 수 없습니다. 사용하지 않는 탭을 닫아 주세요.") }
        _ = try Self.navigationURL(url.absoluteString)
        let scope = opener.tabID.hasPrefix("native-scope.") ? opener.tabID.split(separator: ".").dropLast().joined(separator: ".") + "." : ""
        let tabID = scope + UUID().uuidString
        let child = try createPage(tabID: tabID, profileID: opener.profileID, isPrivate: opener.isPrivate, courseID: opener.courseID)
        emit("browser:open-url", ["tabId": tabID, "openerTabId": opener.tabID, "courseId": opener.courseID as Any? ?? NSNull(),
            "url": url.absoluteString, "isPrivate": opener.isPrivate, "profileId": opener.profileID, "webContentsId": child.id])
        child.load(navigationRequest(url))
        return child
    }
}
