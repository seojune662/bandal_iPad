import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserIdentityTests: XCTestCase {
    func testRetryingFailedPrivacyPreparationPreservesSelectedSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-preparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        host.applySettings(["trackingProtection": "invalid-fixture", "doNotTrack": false, "swipeNavigation": false, "agentUse": false])
        for _ in 0..<2 {
            do { try await host.prepareBrowserNetwork(); XCTFail("An invalid selected rule set must not be silently replaced with defaults") }
            catch { }
            XCTAssertEqual(host.trackingProtection, "invalid-fixture")
            XCTAssertFalse(host.doNotTrack); XCTAssertFalse(host.swipeNavigation); XCTAssertFalse(host.agentUse)
        }
        host.applySettings(["trackingProtection": "off", "doNotTrack": false, "swipeNavigation": false, "agentUse": false])
        try await host.prepareBrowserNetwork()
        XCTAssertEqual(host.trackingProtection, "off"); XCTAssertFalse(host.doNotTrack)
    }
    func testFailedEnginePreparationCanRetryWithoutRestartingTheApp() async throws {
        let preparation = BrowserIdentityPreparation()
        var attempts = 0
        do {
            try await preparation.prepare { attempts += 1; throw NSError(domain: "fixture", code: 1) }
            XCTFail("The first probe must fail")
        } catch { }
        XCTAssertNil(preparation.applicationName)
        try await preparation.prepare { attempts += 1; return "Version/26.0 Safari/999.1" }
        try await preparation.prepare { attempts += 1; return "Unexpected repeated probe" }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(preparation.applicationName, "Version/26.0 Safari/999.1")
    }
    func testSafariTokensComeFromTheEngineAndTheSystemVersion() {
        XCTAssertEqual(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (iPad) AppleWebKit/999.42.7 (KHTML, like Gecko) Mobile/test", systemVersion: "26.0"), "Version/26.0 Safari/999.42.7")
        XCTAssertEqual(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (Macintosh) AppleWebKit/612.1.2", systemVersion: "27.1.2"), "Version/27.1 Safari/612.1.2")
        XCTAssertEqual(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15", systemVersion: "26"), "Version/26.0 Safari/605.1.15")
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 Chrome/123.0", systemVersion: "26.0"))
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "AppleWebKit/612.inject", systemVersion: "26.0"))
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15", systemVersion: "26.x"))
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15", systemVersion: ""))
    }
    func testOriginalPageRouteAndRealPopupKeepDynamicIdentityAndPrivateSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "opener", "isPrivate": true])
        defer { for tab in Array(host.pages.keys) { host.destroy(tab) } }
        let opener = try XCTUnwrap(host.pages["opener"]), expected = try XCTUnwrap(DesktopBrowserIdentity.applicationName)
        XCTAssertNotNil(expected.range(of: #"^Version/[0-9]+\.[0-9]+ Safari/[0-9.]+$"#, options: .regularExpression), expected)
        XCTAssertEqual(opener.webView.configuration.applicationNameForUserAgent, expected)
        XCTAssertTrue(opener.webView.customUserAgent?.isEmpty ?? true)
        XCTAssertEqual(opener.webView.configuration.defaultWebpagePreferences.preferredContentMode, .recommended)
        let loaded = expectation(description: "Blank opener document loaded")
        host.emit = { channel, payload in
            guard channel == "browser:page-event", let event = payload as? [String: Any], event["tabId"] as? String == "opener", event["name"] as? String == "did-finish-load" else { return }
            loaded.fulfill()
        }
        opener.webView.loadHTMLString("<!doctype html><title>Private opener</title>", baseURL: URL(string: "about:blank"))
        await fulfillment(of: [loaded], timeout: 15)
        // What a site reads: WebKit's own identity ending in Safari's two tokens, nothing after them.
        let agent = try await opener.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        XCTAssertNotNil(agent.range(of: #"AppleWebKit/[0-9.]+ \(KHTML, like Gecko\) Version/[0-9]+\.[0-9]+ Safari/[0-9.]+$"#, options: .regularExpression), agent)
        let opened = expectation(description: "WebKit supplied real popup configuration")
        var popupID: String?
        host.emit = { channel, payload in
            guard channel == "browser:open-url", let value = payload as? [String: Any] else { return }
            popupID = value["tabId"] as? String; opened.fulfill()
        }
        _ = try await opener.webView.evaluateJavaScript("window.open('about:blank','identity-popup'); true")
        await fulfillment(of: [opened], timeout: 10)
        let child = try XCTUnwrap(host.pages[try XCTUnwrap(popupID)])
        XCTAssertTrue(child.dataStore === opener.dataStore); XCTAssertFalse(child.dataStore.isPersistent)
        XCTAssertEqual(child.webView.configuration.applicationNameForUserAgent, expected)
        XCTAssertTrue(child.webView.customUserAgent?.isEmpty ?? true)
    }
}
