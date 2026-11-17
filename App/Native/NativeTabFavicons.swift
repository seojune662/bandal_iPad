import Combine
import CryptoKit
import SwiftUI
import UIKit

/// The icons of the web pages open in dock tabs, kept by site (host) so every tab of a site shares one.
///
/// Where they come from: a page reports the icons it declares once it has loaded (`page-favicon-updated`,
/// `DesktopBrowserPage`); the first that `browser:favicon` can fetch wins, else the site's `/favicon.ico`. That
/// channel follows `BrowserFavicon`'s rules: the tab's own profile and cookie jar, nothing kept in URLSession's
/// shared jar, Do Not Track when the setting asks, a size cap. At most two sites are fetched at a time, each
/// once, and a site with no icon is not asked again for half an hour, so many tabs never send a burst.
///
/// Where they are kept: in memory, and for ordinary browsing on disk in the caches folder (32-pixel PNGs named by a
/// hash of the host), so a relaunch shows them at once: a tab that was not opened yet reads its last page from
/// the browser's saved tabs. A private tab's icon stays in memory only and is never written.
@MainActor @Observable final class NativeTabFavicons {
    static let shared: NativeTabFavicons = {
        #if DEBUG
        // A UI test that starts from nothing starts without the icons an earlier run kept.
        if ProcessInfo.processInfo.arguments.contains("--reset-native-ui-testing"), let directory = defaultDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        #endif
        return NativeTabFavicons()
    }()
    typealias Fetch = @MainActor (_ url: String, _ profileID: String, _ isPrivate: Bool) async -> String?

    /// Read by the tabs that show an icon, and bumped when one arrives, so they draw again.
    private(set) var revision = 0
    @ObservationIgnored private var icons: [String: Icon] = [:]
    @ObservationIgnored private var privateIcons: [String: Icon] = [:]
    @ObservationIgnored private var scopes: [String: Scope] = [:]
    /// A page's id starts with its dock tab's scope prefix (`NativeBrowserSession.scopePrefix`); this finds the tab.
    @ObservationIgnored private var prefixes: [String: String] = [:]
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var running = Set<String>()
    @ObservationIgnored private var rendered: [String: UIImage] = [:]
    @ObservationIgnored private weak var store: NativeWorkspaceStore?
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let injected: Fetch?
    @ObservationIgnored private var fetch: Fetch?

    static let concurrency = 2
    static let retryAfter: TimeInterval = 30 * 60
    /// A cached icon older than this is fetched again when its site next reports its icons.
    static let refreshAfter: TimeInterval = 7 * 24 * 3600

    /// `live`: a page of it has reported since launch, so its own icons are on the way; a tab not opened yet asks
    /// its site for `/favicon.ico` instead.
    struct Scope: Equatable { var host: String?; var isPrivate = false; var profileID = "default"; var live = false }
    struct Icon {
        let image: UIImage
        /// The icon's mean relative luminance over its visible pixels (0 black … 1 white).
        let luminance: Double
        var saved: Date = .distantPast
    }
    private struct Job { let host: String; let candidates: [String]; let profileID: String; let isPrivate: Bool }

    init(directory: URL? = NativeTabFavicons.defaultDirectory, fetch: Fetch? = nil) {
        self.directory = directory; injected = fetch; self.fetch = fetch
    }
    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TabFavicons", isDirectory: true)
    }

    // MARK: Asking

    /// The icon to draw for the dock browser tab `workspaceID`, in this appearance; nil draws the globe.
    func image(forBrowser workspaceID: String, dark: Bool, store: NativeWorkspaceStore) -> UIImage? {
        _ = revision
        attach(store)
        let scope = resolve(workspaceID)
        guard let host = scope.host, let icon = icon(for: host, isPrivate: scope.isPrivate) else {
            if let host = scope.host, !scope.isPrivate, !scope.live { enqueue(Job(host: host, candidates: [], profileID: scope.profileID, isPrivate: false)) }
            return nil
        }
        let key = (scope.isPrivate && privateIcons[host] != nil ? "p:" : "") + host + (dark ? ":dark" : ":light")
        if let image = rendered[key] { return image }
        let image = Self.tabImage(icon, dark: dark)
        rendered[key] = image
        return image
    }
    /// The site a dock browser tab shows, once known (tests and the tab list).
    func host(forBrowser workspaceID: String) -> String? { scopes[workspaceID]?.host }

    private func resolve(_ workspaceID: String) -> Scope {
        if let scope = scopes[workspaceID] { return scope }
        prefixes[NativeBrowserSession.scopePrefix(workspaceID)] = workspaceID
        // A tab not opened since launch: its last page from the browser's saved tabs (never a private one).
        var scope = Scope(host: nil)
        if let store, let page = NativeBrowserSession.currentPage(workspaceID: workspaceID, store: store) {
            scope = Scope(host: Self.host(page.url), isPrivate: page.isPrivate, profileID: page.profileID)
        }
        scopes[workspaceID] = scope
        return scope
    }
    private func icon(for host: String, isPrivate: Bool) -> Icon? {
        if isPrivate, let icon = privateIcons[host] { return icon }
        if let icon = icons[host] { return icon }
        guard let icon = load(host) else { return nil }
        icons[host] = icon
        return icon
    }

    // MARK: Listening

    private func attach(_ store: NativeWorkspaceStore) {
        guard self.store !== store else { return }
        self.store = store
        if injected == nil {
            fetch = { [weak store] url, profile, isPrivate in
                guard let store else { return nil }
                let result = try? await store.invoke("browser:favicon", ["url": url, "profileId": profile, "isPrivate": isPrivate]) as? [String: Any]
                return result?["dataUrl"] as? String
            }
        }
        subscription = store.events.receive(on: RunLoop.main).sink { [weak self] event in
            guard event.channel == "browser:page-event", let payload = event.payload as? [String: Any] else { return }
            MainActor.assumeIsolated { self?.receive(payload) }
        }
    }
    /// One page's event: its site, and with `page-favicon-updated` the icons it declares.
    func receive(_ payload: [String: Any]) {
        guard let tabID = payload["tabId"] as? String, let workspaceID = Self.scopePrefix(ofPage: tabID).flatMap({ prefixes[$0] }) else { return }
        let state = payload["state"] as? [String: Any] ?? [:]
        let previous = scopes[workspaceID]
        var scope = previous ?? Scope(host: nil)
        scope.live = true
        if let url = state["url"] as? String {
            let host = Self.host(url)
            // about:blank between pages keeps the last site's icon until the next site reports.
            if host != nil || (!url.isEmpty && url != "about:blank") { scope.host = host }
        }
        if let value = state["isPrivate"] as? Bool { scope.isPrivate = value }
        if let value = state["profileId"] as? String { scope.profileID = value }
        if scope != previous { scopes[workspaceID] = scope; revision += 1 }
        guard payload["name"] as? String == "page-favicon-updated", let host = scope.host else { return }
        let declared = ((payload["detail"] as? [String: Any])?["favicons"] as? [String]) ?? []
        if !scope.isPrivate, let icon = icon(for: host, isPrivate: false), Date().timeIntervalSince(icon.saved) < Self.refreshAfter { return }
        if scope.isPrivate, privateIcons[host] != nil { return }
        enqueue(Job(host: host, candidates: declared, profileID: scope.profileID, isPrivate: scope.isPrivate), force: true)
    }

    // MARK: Fetching

    private func enqueue(_ job: Job, force: Bool = false) {
        guard fetch != nil, !running.contains(job.host), !pending.contains(where: { $0.host == job.host && $0.isPrivate == job.isPrivate }) else { return }
        if !force, let date = failed[job.host], Date().timeIntervalSince(date) < Self.retryAfter { return }
        pending.append(job)
        Task { @MainActor [weak self] in self?.pump() }
    }
    private func pump() {
        while running.count < Self.concurrency, !pending.isEmpty {
            let job = pending.removeFirst()
            running.insert(job.host)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let icon = await self.download(job)
                self.running.remove(job.host)
                self.finish(job, icon: icon)
                self.pump()
            }
        }
    }
    private func download(_ job: Job) async -> Icon? {
        for candidate in Self.candidates(declared: job.candidates, host: job.host) {
            let encoded: String?
            if candidate.hasPrefix("data:") { encoded = candidate } else { encoded = await fetch?(candidate, job.profileID, job.isPrivate) }
            if let encoded, let icon = Self.decode(encoded) { return icon }
        }
        return nil
    }
    private func finish(_ job: Job, icon: Icon?) {
        guard var icon else { failed[job.host] = Date(); return }
        failed[job.host] = nil
        icon.saved = Date()
        rendered = rendered.filter { !$0.key.hasPrefix(job.host + ":") && !$0.key.hasPrefix("p:" + job.host + ":") }
        if job.isPrivate { privateIcons[job.host] = icon } else { icons[job.host] = icon; save(icon, host: job.host) }
        revision += 1
    }

    // MARK: Disk

    private func file(_ host: String) -> URL? {
        let digest = SHA256.hash(data: Data(host.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".png")
    }
    private func load(_ host: String) -> Icon? {
        guard let url = file(host), let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: 2) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Icon(image: image, luminance: Self.luminance(image), saved: date)
    }
    private func save(_ icon: Icon, host: String) {
        guard let url = file(host), let data = icon.image.pngData() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    #if DEBUG
    static let marksTabsForTests = ProcessInfo.processInfo.arguments.contains("--native-ui-testing")
    /// `--native-chrome-favicon-fixture`'s icon: an orange square with a white dot, as a data URL.
    static var fixtureIcon: String {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 10, y: 10, width: 12, height: 12))
        }
        return "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
    }
    #endif

    // MARK: Pure parts

    /// The host of an http(s) page, lower-cased; nil for anything else (about:blank, a file, a data URL).
    nonisolated static func host(_ url: String) -> String? {
        guard let components = URLComponents(string: url), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
    /// `native-scope.<hash>.` of a page id that belongs to a dock tab, else nil.
    nonisolated static func scopePrefix(ofPage id: String) -> String? {
        let head = "native-scope."
        guard id.hasPrefix(head) else { return nil }
        let rest = id.dropFirst(head.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return head + rest[..<dot] + "."
    }
    /// What to try, in order: the page's own icons that iOS can draw (two at most; not SVG), then the site's
    /// `/favicon.ico`, then its touch icon.
    nonisolated static func candidates(declared: [String], host: String) -> [String] {
        let own = declared.filter { link in
            let lower = link.lowercased()
            if lower.hasPrefix("data:") { return lower.hasPrefix("data:image/") && !lower.hasPrefix("data:image/svg") }
            guard Self.host(link) != nil, let path = URLComponents(string: link)?.path.lowercased() else { return false }
            return !path.hasSuffix(".svg")
        }
        var seen = Set<String>(), result: [String] = []
        for link in Array(own.prefix(2)) + ["https://" + host + "/favicon.ico", "https://" + host + "/apple-touch-icon.png"] where seen.insert(link).inserted {
            result.append(link)
        }
        return result
    }
    /// A data URL into a 32-pixel icon (16 points), or nil when it is no image.
    nonisolated static func decode(_ dataURL: String) -> Icon? {
        guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), let source = UIImage(data: data),
              source.size.width > 0, source.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let side: CGFloat = 16
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let scale = min(side / source.size.width, side / source.size.height)
            let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        return Icon(image: image, luminance: luminance(image))
    }
    /// Mean relative luminance, weighted by alpha. A fully clear image counts as mid grey.
    nonisolated static func luminance(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.5 }
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        var total = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.05 else { continue }
            let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
            total += (0.2126 * linear(min(r, 1)) + 0.7152 * linear(min(g, 1)) + 0.0722 * linear(min(b, 1))) * alpha
            weight += alpha
        }
        return weight > 0 ? total / weight : 0.5
    }
    /// Whether the icon needs a small ground to show against the strip: a dark icon on the dark glass, a nearly
    /// white one on the light glass.
    nonisolated static func needsPlate(luminance: Double, dark: Bool) -> Bool { dark ? luminance < 0.09 : luminance > 0.75 }
    /// The 16-point image the tab draws: the icon with slightly rounded corners, or on a small rounded ground.
    nonisolated static func tabImage(_ icon: Icon, dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let side: CGFloat = 16, bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let plate = needsPlate(luminance: icon.luminance, dark: dark)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            if plate {
                (dark ? UIColor.white.withAlphaComponent(0.9) : UIColor.black.withAlphaComponent(0.14)).setFill()
                UIBezierPath(roundedRect: bounds, cornerRadius: 4).fill()
                icon.image.draw(in: bounds.insetBy(dx: 2, dy: 2))
            } else {
                UIBezierPath(roundedRect: bounds, cornerRadius: 3).addClip()
                icon.image.draw(in: bounds)
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
