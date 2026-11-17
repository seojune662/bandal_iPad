import XCTest
import UIKit
@testable import Bandal

@MainActor final class NativeTabFaviconsTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("favicons-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private static func dataURL(_ color: UIColor, side: CGFloat = 32) -> String {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return "data:image/png;base64," + image.pngData()!.base64EncodedString()
    }
    /// A page event as `DesktopBrowserPage.send` emits it.
    private func event(_ workspaceID: String, url: String, name: String = "did-navigate", isPrivate: Bool = false, favicons: [String]? = nil) -> [String: Any] {
        var detail: [String: Any] = [:]
        if let favicons { detail["favicons"] = favicons }
        return ["tabId": NativeBrowserSession.scopePrefix(workspaceID) + UUID().uuidString, "name": name,
                "state": ["url": url, "isPrivate": isPrivate, "profileId": "default"], "detail": detail]
    }
    /// Waits until `condition` holds, giving the store's tasks their turns.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testSitesAndScopes() {
        XCTAssertEqual(NativeTabFavicons.host("https://WWW.YouTube.com/watch?v=1"), "www.youtube.com")
        XCTAssertNil(NativeTabFavicons.host("about:blank"))
        XCTAssertNil(NativeTabFavicons.host("file:///tmp/a.html"))
        let workspace = "e4c5b2"
        let page = NativeBrowserSession.scopePrefix(workspace) + UUID().uuidString
        XCTAssertEqual(NativeTabFavicons.scopePrefix(ofPage: page), NativeBrowserSession.scopePrefix(workspace))
        XCTAssertNil(NativeTabFavicons.scopePrefix(ofPage: UUID().uuidString), "A page of the standalone browser is no dock tab")
    }
    func testCandidatesPreferThePagesOwnDrawableIconsThenTheSitesFavicon() {
        let list = NativeTabFavicons.candidates(declared: ["https://a.com/icon.svg", "https://cdn.a.com/i32.png", "https://a.com/i16.ico", "https://a.com/i64.png"], host: "a.com")
        XCTAssertEqual(list, ["https://cdn.a.com/i32.png", "https://a.com/i16.ico", "https://a.com/favicon.ico", "https://a.com/apple-touch-icon.png"])
        XCTAssertEqual(NativeTabFavicons.candidates(declared: [], host: "b.org"), ["https://b.org/favicon.ico", "https://b.org/apple-touch-icon.png"])
        XCTAssertEqual(NativeTabFavicons.candidates(declared: ["data:image/svg+xml;base64,AA", "javascript:alert(1)"], host: "c.net").count, 2)
    }
    func testDarkIconsGetAGroundInDarkModeAndBrightOnesInLightMode() {
        let black = try! XCTUnwrap(NativeTabFavicons.decode(Self.dataURL(.black)))
        let white = try! XCTUnwrap(NativeTabFavicons.decode(Self.dataURL(.white)))
        let red = try! XCTUnwrap(NativeTabFavicons.decode(Self.dataURL(.systemRed)))
        XCTAssertEqual(black.image.size, CGSize(width: 16, height: 16)); XCTAssertEqual(black.image.scale, 2)
        XCTAssertTrue(NativeTabFavicons.needsPlate(luminance: black.luminance, dark: true))
        XCTAssertFalse(NativeTabFavicons.needsPlate(luminance: black.luminance, dark: false))
        XCTAssertTrue(NativeTabFavicons.needsPlate(luminance: white.luminance, dark: false))
        XCTAssertFalse(NativeTabFavicons.needsPlate(luminance: white.luminance, dark: true))
        XCTAssertFalse(NativeTabFavicons.needsPlate(luminance: red.luminance, dark: true), "A coloured icon shows on either ground")
        XCTAssertFalse(NativeTabFavicons.needsPlate(luminance: red.luminance, dark: false))
        XCTAssertNil(NativeTabFavicons.decode("data:text/plain;base64,aGVsbG8="))
    }

    /// One request per site whatever the number of tabs on it, two sites at a time, the result kept on disk and
    /// shown at once on the next launch.
    func testManyTabsOfASiteShareOneFetchAndTheIconSurvivesARelaunch() async throws {
        var requests: [String] = [], inFlight = 0, most = 0
        let icon = Self.dataURL(.systemBlue)
        let fetch: NativeTabFavicons.Fetch = { url, _, isPrivate in
            XCTAssertFalse(isPrivate)
            requests.append(url); inFlight += 1; most = max(most, inFlight)
            try? await Task.sleep(for: .milliseconds(30))
            inFlight -= 1
            return url.contains("/favicon.ico") ? nil : icon
        }
        let favicons = NativeTabFavicons(directory: directory, fetch: fetch)
        let store = NativeWorkspaceStore(storageRoot: directory.appendingPathComponent("root", isDirectory: true))
        let sites = ["a.com", "b.com", "c.com", "d.com"]
        var tabs: [String: String] = [:]
        for index in 0..<12 {
            let workspace = "w\(index)", site = sites[index % sites.count]
            tabs[workspace] = site
            XCTAssertNil(favicons.image(forBrowser: workspace, dark: false, store: store))
            favicons.receive(event(workspace, url: "https://\(site)/page\(index)"))
            favicons.receive(event(workspace, url: "https://\(site)/page\(index)", name: "page-favicon-updated", favicons: ["https://\(site)/icon.png"]))
        }
        await settle { tabs.keys.allSatisfy { favicons.image(forBrowser: $0, dark: false, store: store) != nil } }
        XCTAssertTrue(tabs.keys.allSatisfy { favicons.image(forBrowser: $0, dark: true, store: store) != nil })
        XCTAssertEqual(Set(requests), Set(sites.map { "https://\($0)/icon.png" }), "The page's own icon, once per site")
        XCTAssertEqual(requests.count, sites.count)
        XCTAssertLessThanOrEqual(most, NativeTabFavicons.concurrency)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, sites.count)
        // Next launch: nothing fetched, the tab of a site seen before shows its icon as soon as its page is known.
        var again = 0
        let relaunched = NativeTabFavicons(directory: directory, fetch: { _, _, _ in again += 1; return nil })
        relaunched.receive(event("w0", url: "https://a.com/x"))
        _ = relaunched.image(forBrowser: "w0", dark: false, store: store)
        relaunched.receive(event("w0", url: "https://a.com/x"))
        XCTAssertNotNil(relaunched.image(forBrowser: "w0", dark: false, store: store))
        relaunched.receive(event("w0", url: "https://a.com/x", name: "page-favicon-updated", favicons: ["https://a.com/icon.png"]))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(again, 0, "A fresh cached icon is not fetched again")
    }

    /// A private page's icon is shown but never written to disk, and a site without any icon is not asked again soon.
    func testPrivateIconsStayInMemoryAndMissingIconsAreNotRetriedAtOnce() async throws {
        var requests: [(String, Bool)] = []
        let icon = Self.dataURL(.systemGreen)
        let favicons = NativeTabFavicons(directory: directory, fetch: { url, _, isPrivate in
            requests.append((url, isPrivate)); return url.hasPrefix("https://private.example") ? icon : nil
        })
        let store = NativeWorkspaceStore(storageRoot: directory.appendingPathComponent("root", isDirectory: true))
        _ = favicons.image(forBrowser: "secret", dark: false, store: store)
        favicons.receive(event("secret", url: "https://private.example/a", isPrivate: true))
        favicons.receive(event("secret", url: "https://private.example/a", name: "page-favicon-updated", isPrivate: true, favicons: []))
        await settle { favicons.image(forBrowser: "secret", dark: false, store: store) != nil }
        XCTAssertNotNil(favicons.image(forBrowser: "secret", dark: false, store: store))
        XCTAssertTrue(requests.allSatisfy { $0.1 }, "Fetched with the private profile's cookies")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path) && !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty,
                       "Nothing written for a private page")

        _ = favicons.image(forBrowser: "plain", dark: false, store: store)
        favicons.receive(event("plain", url: "https://noicon.example/"))
        favicons.receive(event("plain", url: "https://noicon.example/", name: "page-favicon-updated", favicons: []))
        await settle { requests.filter { $0.0.contains("noicon") }.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        let asked = requests.filter { $0.0.contains("noicon") }.count
        XCTAssertEqual(asked, 2, "/favicon.ico and the touch icon")
        for _ in 0..<5 { XCTAssertNil(favicons.image(forBrowser: "plain", dark: false, store: store)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests.filter { $0.0.contains("noicon") }.count, asked, "Drawing the tab again asks nobody")
    }
}
