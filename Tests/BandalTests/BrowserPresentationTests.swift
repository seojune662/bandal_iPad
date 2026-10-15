import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserPresentationTests: XCTestCase {
    func testChangingPresentationRetriesFailedGETAndRejectsFailedPOSTWithoutSavingMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-mode-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try NavigationRecoveryServer(), port = try await server.start()
        defer { server.stop() }
        let host = DesktopBrowserHost(root: root)
        let page = try host.createPage(tabID: "mode", profileID: "default", isPrivate: true, courseID: nil)
        defer { host.destroy("mode") }
        var failed = false, finished = false
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any] else { return }
            if event["name"] as? String == "did-fail-load" { failed = true }
            if event["name"] as? String == "did-finish-load" { finished = true }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertTrue(predicate())
        }
        let target = URL(string: "http://127.0.0.1:\(port)/drop-mode")!
        server.dropsResponses = true; page.load(URLRequest(url: target))
        try await wait { failed }
        server.dropsResponses = false
        _ = try await host.handle(channel: "browser:setSitePresentation", request: ["tabId": "mode", "mode": "desktop"])
        try await wait { finished }
        XCTAssertEqual(page.webView.url, target)
        XCTAssertEqual(host.presentation(for: page, url: target), .desktop)
        finished = false
        page.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/form")!))
        try await wait { finished }
        failed = false; server.dropsResponses = true
        _ = try await page.webView.evaluateJavaScript("document.forms[0].submit(); true")
        try await wait { failed }
        let count = server.requestCount
        do {
            _ = try await host.handle(channel: "browser:setSitePresentation", request: ["tabId": "mode", "mode": "mobile"])
            XCTFail("Changing site mode cannot replay a failed POST")
        } catch { }
        XCTAssertEqual(server.requestCount, count)
        XCTAssertEqual(host.presentation(for: page, url: target), .desktop)
    }
    func testAutomaticDefaultAndExactHostProfileIsolationSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserPresentationStore(root: root)
        XCTAssertEqual(store.mode(profile: "default", host: "school.test", isPrivate: false), .automatic)
        try store.set(.desktop, profile: "default", host: "SCHOOL.test", isPrivate: false)
        try store.set(.mobile, profile: "second", host: "school.test", isPrivate: false)
        let restored = try BrowserPresentationStore(root: root)
        XCTAssertEqual(restored.mode(profile: "default", host: "school.test", isPrivate: false), .desktop)
        XCTAssertEqual(restored.mode(profile: "second", host: "school.test", isPrivate: false), .mobile)
        XCTAssertEqual(restored.mode(profile: "default", host: "sub.school.test", isPrivate: false), .automatic)
        XCTAssertEqual(restored.mode(profile: "default", host: "school.test.evil.test", isPrivate: false), .automatic)
        try restored.forget("second")
        XCTAssertEqual(try BrowserPresentationStore(root: root).mode(profile: "second", host: "school.test", isPrivate: false), .automatic)
    }
    func testPrivateOverridesNeverWriteAndEndWithTheirSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-private-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserPresentationStore(root: root)
        try store.set(.desktop, profile: "default", host: "school.test", isPrivate: false)
        let before = try Data(contentsOf: root.appendingPathComponent("website-presentation.json"))
        try store.set(.mobile, profile: "default", host: "private.test", isPrivate: true)
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: true), .mobile)
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: false), .automatic)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("website-presentation.json")), before)
        XCTAssertEqual(try BrowserPresentationStore(root: root).mode(profile: "default", host: "private.test", isPrivate: true), .automatic)
        store.discardPrivate("default")
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: true), .automatic)
    }
    func testPublicWebKitPreferenceDoesNotFakeAnOldBrowserVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-preference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        try await host.prepareBrowserNetwork()
        let page = try host.createPage(tabID: "fixture", profileID: "default", isPrivate: true, courseID: nil)
        XCTAssertEqual(page.webView.configuration.defaultWebpagePreferences.preferredContentMode, .recommended)
        XCTAssertTrue(page.webView.customUserAgent?.isEmpty ?? true)
        XCTAssertEqual(page.webView.configuration.applicationNameForUserAgent, DesktopBrowserIdentity.applicationName)
        XCTAssertEqual(host.presentation(for: page, url: URL(string: "https://site.test")), .automatic)
        try host.presentationStore?.set(.desktop, profile: "default", host: "site.test", isPrivate: true)
        XCTAssertEqual(host.presentation(for: page, url: URL(string: "https://site.test/path")).contentMode, .desktop)
        host.destroy("fixture")
        let second = try host.createPage(tabID: "next", profileID: "default", isPrivate: true, courseID: nil)
        XCTAssertEqual(host.presentation(for: second, url: URL(string: "https://site.test")).contentMode, .recommended)
        host.destroy("next")
    }
}
