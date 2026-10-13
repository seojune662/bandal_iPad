import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserIdentityTests: XCTestCase {
    func testCompatibilityTokenComesFromEngineInsteadOfAHardcodedVersion() {
        XCTAssertEqual(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (iPad) AppleWebKit/999.42.7 (KHTML, like Gecko) Mobile/test"), "Safari/999.42.7 Bandal")
        XCTAssertEqual(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 (Macintosh) AppleWebKit/612.1.2"), "Safari/612.1.2 Bandal")
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "Mozilla/5.0 Chrome/123.0"))
        XCTAssertNil(DesktopBrowserIdentity.applicationName(from: "AppleWebKit/612.inject"))
    }
    func testOriginalPageRouteAndRealPopupKeepDynamicIdentityAndPrivateSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "opener", "isPrivate": true])
        defer { for tab in Array(host.pages.keys) { host.destroy(tab) } }
        let opener = try XCTUnwrap(host.pages["opener"]), expected = try XCTUnwrap(DesktopBrowserIdentity.applicationName)
        XCTAssertTrue(expected.hasPrefix("Safari/")); XCTAssertTrue(expected.hasSuffix(" Bandal"))
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
