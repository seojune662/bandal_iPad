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
        let slot = childTab(of: opener)
        let child = try createPage(tabID: slot.tabID, profileID: opener.profileID, isPrivate: opener.isPrivate, courseID: opener.courseID)
        announce(child, opener: opener, url: url.absoluteString, workspaceID: slot.workspaceID, background: true)
        child.load(navigationRequest(url))
        return child
    }
    /// ⌘T / "새 탭" inside a dock browser tab: same route as a link, so the
    /// new page becomes a dock tab instead of a nested one.
    func openNewTab(from opener: DesktopBrowserPage, isPrivate: Bool, url: String) throws {
        guard pages[opener.tabID] === opener, pages.count < 64 else { throw DesktopBrowserError.unavailable("새 탭을 열 수 없습니다. 사용하지 않는 탭을 닫아 주세요.") }
        let target = try Self.navigationURL(url)
        let slot = childTab(of: opener)
        let child = try createPage(tabID: slot.tabID, profileID: opener.profileID, isPrivate: isPrivate, courseID: opener.courseID)
        announce(child, opener: opener, url: url, workspaceID: slot.workspaceID, background: false)
        if url != "about:blank" { child.load(navigationRequest(target)) }
    }
    /// Chrome never nests tabs: a link or popup from a dock browser tab becomes
    /// its own dock tab. It gets a fresh scope, which the dock adopts as a new
    /// browser document. The standalone (unscoped) browser keeps its own strip.
    func childTab(of opener: DesktopBrowserPage) -> (tabID: String, workspaceID: String?) {
        guard opener.tabID.hasPrefix("native-scope.") else { return (UUID().uuidString, nil) }
        let workspaceID = UUID().uuidString.lowercased()
        return (NativeBrowserSession.scopePrefix(workspaceID) + UUID().uuidString, workspaceID)
    }
    func announce(_ child: DesktopBrowserPage, opener: DesktopBrowserPage, url: String, workspaceID: String?, background: Bool) {
        emit("browser:open-url", ["tabId": child.tabID, "openerTabId": opener.tabID, "courseId": opener.courseID as Any? ?? NSNull(),
            "url": url, "isPrivate": child.isPrivate, "profileId": child.profileID, "webContentsId": child.id,
            "workspaceId": workspaceID as Any? ?? NSNull(), "background": background])
    }
}
