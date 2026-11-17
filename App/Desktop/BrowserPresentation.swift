import Foundation
import WebKit

enum BrowserPresentationMode: String, Codable, CaseIterable {
    case desktop, mobile, automatic
    var contentMode: WKWebpagePreferences.ContentMode {
        switch self { case .desktop: .desktop; case .mobile: .mobile; case .automatic: .recommended }
    }
}

/// YouTube on a touch screen: its desktop player pauses on a click, and a Pencil tap (or a tap with a trackpad
/// attached) reaches it as one. The mobile site shows its controls on a tap, pauses on its own button and seeks
/// ten seconds on a double tap, as the YouTube app does. Until the person picks 웹사이트 표시 for the site, it opens mobile.
enum BrowserVideoSites {
    static let mobileByDefault: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
    static func defaultPresentation(host: String) -> BrowserPresentationMode {
        mobileByDefault.contains(host.lowercased()) ? .mobile : .automatic
    }
    /// Where a site's 웹사이트 표시 choice is kept, most specific last. YouTube's hosts share `youtube.com`, and a
    /// choice saved for one of them before they shared it still counts.
    static func presentationKeys(_ host: String) -> [String] {
        let host = host.lowercased()
        return mobileByDefault.contains(host) && host != "youtube.com" ? ["youtube.com", host] : [host]
    }
}

/// Website presentation is a device preference, isolated by profile and host.
/// Private overrides never enter the on-disk preferences or normal profiles.
@MainActor
final class BrowserPresentationStore {
    private struct Entry: Codable { let profile: String; let host: String; let mode: BrowserPresentationMode }
    private let file: URL
    private var saved: [Entry]
    private var ephemeral: [Entry] = []
    init(root: URL) throws {
        file = root.appendingPathComponent("website-presentation.json")
        saved = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) : []
    }
    func mode(profile: String, host: String, isPrivate: Bool) -> BrowserPresentationMode {
        let entries = isPrivate ? ephemeral : saved
        for key in BrowserVideoSites.presentationKeys(host) {
            if let mode = entries.last(where: { $0.profile == profile && $0.host == key })?.mode { return mode }
        }
        return BrowserVideoSites.defaultPresentation(host: host)
    }
    func set(_ mode: BrowserPresentationMode, profile: String, host: String, isPrivate: Bool) throws {
        guard !host.isEmpty, host.count <= 253 else { throw DesktopBrowserError.invalid("사이트 주소") }
        // YouTube's hosts share one choice: www and m redirect to each other by the device the site is asked for.
        let keys = BrowserVideoSites.presentationKeys(host), key = keys[0]
        var next = (isPrivate ? ephemeral : saved).filter { !($0.profile == profile && keys.contains($0.host)) }
        next.append(Entry(profile: profile, host: key, mode: mode))
        if isPrivate { ephemeral = next }
        else { try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); saved = next }
    }
    func discardPrivate(_ profile: String) { ephemeral.removeAll { $0.profile == profile } }
    func forget(_ profile: String) throws {
        let next = saved.filter { $0.profile != profile }
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        saved = next; discardPrivate(profile)
    }
}

extension DesktopBrowserHost {
    func presentation(for page: DesktopBrowserPage, url: URL?) -> BrowserPresentationMode {
        presentationStore?.mode(profile: page.profileID, host: url?.host ?? "", isPrivate: page.isPrivate) ?? .automatic
    }
    func presentationRequest(_ request: [String: Any], page: DesktopBrowserPage, update: Bool) async throws -> [String: Any] {
        guard let address = page.state["url"] as? String, let url = URL(string: address), let host = url.host, ["https", "http"].contains(url.scheme ?? "") else {
            return ["mode": "automatic", "available": false]
        }
        if update {
            guard let raw = request["mode"] as? String, let mode = BrowserPresentationMode(rawValue: raw), let presentationStore else { throw DesktopBrowserError.invalid("웹사이트 표시 모드") }
            if mode != presentation(for: page, url: url) {
                try page.requireReloadable()
                let navigationID = page.state["navigationId"] as? Int
                let cancelled = (try? await page.webView.evaluateJavaScript("(()=>{const e=new Event('beforeunload',{cancelable:true});return !window.dispatchEvent(e)||e.returnValue===false})()")) as? Bool ?? false
                if cancelled {
                    let allowed = await confirm(title: "웹사이트를 다시 불러올까요?", message: "작성 중인 내용이 사라질 수 있습니다.")
                    if !allowed { return ["mode": presentation(for: page, url: url).rawValue, "available": true] }
                }
                // Do not apply a stale menu action to a page that navigated while asking.
                guard page.state["url"] as? String == address, page.state["navigationId"] as? Int == navigationID, pages[page.tabID] === page else { throw DesktopBrowserError.unavailable("페이지가 변경됐습니다. 다시 선택해 주세요.") }
                try page.requireReloadable()
                try presentationStore.set(mode, profile: page.profileID, host: host, isPrivate: page.isPrivate)
                try page.reload()
            }
        }
        return ["mode": presentation(for: page, url: url).rawValue, "available": true]
    }
}
