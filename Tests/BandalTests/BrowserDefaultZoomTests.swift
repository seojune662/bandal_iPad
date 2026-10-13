import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserDefaultZoomTests: XCTestCase {
    /// The companion original-renderer test proves that native-ready emits
    /// this command. Here the real settings repository and WKWebView consume
    /// it across repository recreation and document navigation.
    func testRestoredPreferenceZoomCommandChangesWebKitWithoutChangingExistingTabs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-default-zoom-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        _ = try await runtime.invoke("settings:set", request: ["browser": ["defaultZoomLevel": 1.22]])
        let restored = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await restored.start()
        func preferences() async throws -> [String: Any] {
            let result = try await restored.invoke("settings:get") as? [String: Any]
            return try XCTUnwrap(result?["browser"] as? [String: Any])
        }
        let saved = try await preferences(), defaultLevel = try XCTUnwrap(saved["defaultZoomLevel"] as? Double)
        XCTAssertEqual(defaultLevel, 1.22)
        let host = DesktopBrowserHost(root: root)
        host.applySettings(saved)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "first", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["first"])
        defer { host.destroy("first"); host.destroy("second") }
        page.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "first", "action": "setZoomLevel", "args": [defaultLevel]])
        XCTAssertEqual(page.webView.pageZoom, pow(1.2, 1.22), accuracy: 0.0001)
        for index in 0..<2 {
            let loaded = expectation(description: "Local document \(index) loaded")
            host.emit = { channel, value in
                guard channel == "browser:page-event", let event = value as? [String: Any],
                      event["tabId"] as? String == "first", event["name"] as? String == "did-finish-load" else { return }
                loaded.fulfill()
            }
            page.webView.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><p>Zoom document \(index)</p>", baseURL: nil)
            await fulfillment(of: [loaded], timeout: 15)
            XCTAssertEqual(page.webView.pageZoom, pow(1.2, 1.22), accuracy: 0.0001, "Document navigation retains the established tab zoom")
        }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "first", "action": "setZoomLevel", "args": [0.0]])
        XCTAssertEqual(page.webView.pageZoom, 1, accuracy: 0.0001)
        _ = try await restored.invoke("settings:set", request: ["browser": ["defaultZoomLevel": 3.07]])
        let next = try await preferences(), nextLevel = try XCTUnwrap(next["defaultZoomLevel"] as? Double)
        host.applySettings(next)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "second", "isPrivate": true])
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "second", "action": "setZoomLevel", "args": [nextLevel]])
        XCTAssertEqual(try XCTUnwrap(host.pages["second"]).webView.pageZoom, pow(1.2, 3.07), accuracy: 0.0001)
        XCTAssertEqual(page.webView.pageZoom, 1, accuracy: 0.0001, "A new-tab default must not overwrite an existing explicit 100% choice")
    }
}
