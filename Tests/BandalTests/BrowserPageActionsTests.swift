import XCTest
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class BrowserPageActionsTests: XCTestCase {
    func testShareAcceptsWebAddressesWithoutLeakingHTTPUserCredentials() throws {
        let address = try DesktopBrowserHost.shareablePageURL(URL(string: "https://username:password@example.test/article?id=7#section"))
        XCTAssertEqual(address.absoluteString, "https://example.test/article?id=7#section")
        for address in [nil, URL(string: "about:blank"), URL(string: "file:///private/note.pdf"), URL(string: "javascript:alert(1)")] {
            XCTAssertThrowsError(try DesktopBrowserHost.shareablePageURL(address))
        }
    }

    func testOriginalFindRouteMatchesAcrossInlineElementsAndControlsPageZoom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-find-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "fixture", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["fixture"])
        defer { host.destroy("fixture") }
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let loaded = expectation(description: "Find fixture loaded")
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "did-finish-load" else { return }
            loaded.fulfill()
        }
        page.webView.loadHTMLString("<!doctype html><p>alpha <b>beta</b></p><p>ALPHA <i>BETA</i></p><p hidden>alpha beta</p><p>İ prefix emoji 🌓</p>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        var results: [[String: Any]] = []
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "found-in-page",
                  let detail = event["detail"] as? [String: Any], let result = detail["result"] as? [String: Any] else { return }
            results.append(result)
        }
        func find(_ query: String, options: [String: Any] = [:]) async throws {
            _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "fixture", "action": "findInPage", "args": [query, options]])
        }
        try await find("alpha beta")
        XCTAssertEqual(results.last?["matches"] as? Int, 2); XCTAssertEqual(results.last?["activeMatchOrdinal"] as? Int, 1)
        try await find("alpha beta", options: ["findNext": true])
        XCTAssertEqual(results.last?["activeMatchOrdinal"] as? Int, 2)
        try await find("alpha beta", options: ["matchCase": true])
        XCTAssertEqual(results.last?["matches"] as? Int, 1)
        try await find("emoji 🌓")
        let selected = try await page.webView.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "emoji 🌓", "Unicode case conversion must not shift selection offsets")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "fixture", "action": "stopFindInPage", "args": []])
        let cleared = try await page.webView.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(cleared, "")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "fixture", "action": "setZoomLevel", "args": [2.0]])
        XCTAssertEqual(page.webView.pageZoom, 1.44, accuracy: 0.001)
    }

    func testActualShareRouteRequiresVisiblePresenterAndPresentsAnchoredSheetWithoutSharing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-page-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "fixture", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["fixture"])
        defer { host.destroy("fixture") }
        let loaded = expectation(description: "Local HTML acquired a web base address without a network request")
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "did-finish-load" else { return }
            loaded.fulfill()
        }
        page.webView.loadHTMLString("<!doctype html><title>Share fixture</title><p>Only local test content</p>", baseURL: URL(string: "https://example.test/article"))
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertEqual(page.webView.url?.host, "example.test")
        do {
            _ = try await host.handle(channel: "browser:sharePage", request: ["tabId": "fixture"])
            XCTFail("An absent presenter must not report successful sharing")
        } catch { /* Expected: no active application window for this host. */ }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible(); host.presenter = controller
        defer { controller.dismiss(animated: false); window.isHidden = true; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        host.attach(to: controller.view, shell: shell)
        _ = try await host.handle(channel: "browser:sharePage", request: ["tabId": "fixture"])
        let sheet = try XCTUnwrap(controller.presentedViewController as? UIActivityViewController)
        XCTAssertTrue(sheet.popoverPresentationController?.sourceView === controller.view)
        XCTAssertFalse(sheet.popoverPresentationController?.sourceRect.isEmpty ?? true)
        do {
            _ = try await host.handle(channel: "browser:sharePage", request: ["tabId": "fixture"])
            XCTFail("A second share request must not be silently dropped while a sheet is open")
        } catch { /* Expected: the existing sheet is kept. */ }
        // Never select an activity or transmit test data. Merely close the sheet.
        await withCheckedContinuation { continuation in controller.dismiss(animated: false) { continuation.resume() } }
        XCTAssertFalse(page.dataStore.isPersistent)
    }
}
