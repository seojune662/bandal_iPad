import XCTest
import WebKit
import Network
@testable import Bandal

@MainActor
final class DesktopBrowserMemoryTests: XCTestCase {
    func testTwentyWebTabsReleaseOnlySafePagesAndRestorePrivateHistoryAndScroll() async throws {
        let server = try MemoryPageServer(), port = try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        host.applySettings(["trackingProtection": "off"]); try await host.waitForPrivacySettings()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        let shell = WKWebView(frame: container.bounds); container.addSubview(shell); host.attach(to: container, shell: shell)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "memory-private", .value: "kept"] ))
        let store = host.persistence!.dataStore(profile: "default", isPrivate: true)
        await store.httpCookieStore.setCookie(cookie)
        defer { for tab in Array(host.pages.keys) { host.destroy(tab) } }
        var weakViews: [WeakWebView] = []
        for index in 0..<20 {
            let page = try host.createPage(tabID: "tab-\(index)", profileID: "default", isPrivate: index.isMultiple(of: 2), courseID: "course")
            page.webView.frame = container.bounds
            let path = index == 1 ? "form" : index == 2 ? "frame" : index == 3 ? "media" : "read-\(index)"
            if index == 6 { try await load(page, host: host, address: "http://127.0.0.1:\(port)/first") }
            try await load(page, host: host, address: "http://127.0.0.1:\(port)/\(path)")
            weakViews.append(WeakWebView(page.webView))
        }
        let active = try XCTUnwrap(host.pages["tab-0"]); active.bounds = container.bounds
        let popup = try XCTUnwrap(host.pages["tab-4"]); popup.preventsSuspension = true
        let form = try XCTUnwrap(host.pages["tab-1"])
        _ = try await form.webView.evaluateJavaScript("document.querySelector('input').value='Keep this unfinished answer'")
        let saved = try XCTUnwrap(host.pages["tab-6"])
        _ = try await saved.webView.evaluateJavaScript("window.scrollTo(0,650)")
        // The script reply can arrive before WebKit commits the scroll position
        // to its UIKit scroll view. Capture only the requested, settled offset.
        try await eventually { abs(saved.webView.scrollView.contentOffset.y - 650) <= 3 }
        let offset = saved.webView.scrollView.contentOffset.y
        XCTAssertEqual(offset, 650, accuracy: 3)
        let generation = host.agentGeneration(saved)
        let originalID = saved.id
        let released = await host.releaseInactivePages(keeping: 4)
        XCTAssertEqual(Set(released), Set((5..<20).map { "tab-\($0)" }))
        XCTAssertEqual(host.pages.count, 20, "Releasing a web process must preserve all original tabs")
        XCTAssertEqual(host.pages.values.filter { $0.liveWebView != nil }.count, 5)
        for index in 0...4 { XCTAssertNotNil(host.pages["tab-\(index)"]?.liveWebView) }
        XCTAssertEqual(saved.state["url"] as? String, "http://127.0.0.1:\(port)/read-6")
        XCTAssertEqual(saved.state["canGoBack"] as? Bool, true)
        XCTAssertTrue(saved.dataStore === store)
        let tabs = try await host.agentRequest(["tool": "tabs", "courseId": "course"]) as? [String: Any]
        XCTAssertTrue((tabs?["tabs"] as? [[String: Any]])?.filter { $0["tabId"] as? String == "tab-5" }.first?["asleep"] as? Bool == true)
        XCTAssertNil(saved.liveWebView, "Listing tabs must not wake them")
        try await eventually { weakViews[6].value == nil }
        let restored = expectation(description: "WebKit interaction state loaded saved page")
        host.emit = { channel, payload in
            let value = payload as? [String: Any]
            if channel == "browser:page-event", value?["tabId"] as? String == "tab-6", value?["name"] as? String == "did-finish-load" { restored.fulfill() }
        }
        saved.bounds = container.bounds; host.layoutPages()
        await fulfillment(of: [restored], timeout: 15)
        XCTAssertEqual(saved.id, originalID)
        XCTAssertTrue(saved.dataStore === store)
        XCTAssertEqual(saved.webView.url?.path, "/read-6")
        XCTAssertTrue(saved.webView.canGoBack)
        try await eventually { abs(saved.webView.scrollView.contentOffset.y - offset) <= 3 }
        // A transient native offset at didFinish is insufficient: WebKit may
        // apply interactionState after that callback. Check the settled DOM and
        // UIKit positions together, after the restoration stability interval.
        try await Task.sleep(for: .milliseconds(400))
        let documentOffset = try await saved.webView.evaluateJavaScript("scrollY") as? NSNumber
        XCTAssertEqual(try XCTUnwrap(documentOffset).doubleValue, 650, accuracy: 1)
        XCTAssertEqual(saved.webView.scrollView.contentOffset.y, offset, accuracy: 3)
        XCTAssertGreaterThan(host.agentGeneration(saved), generation, "Old DOM references must become stale on restoration")
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        let normal = await host.persistence!.dataStore(profile: "default", isPrivate: false).httpCookieStore.allCookies()
        XCTAssertFalse(normal.contains { $0.name == cookie.name })
        let value = try await form.webView.evaluateJavaScript("document.querySelector('input').value")
        XCTAssertEqual(value as? String, "Keep this unfinished answer")
        let back = expectation(description: "Restored previous navigation entry")
        host.emit = { channel, payload in
            let value = payload as? [String: Any]
            if channel == "browser:page-event", value?["tabId"] as? String == "tab-6", value?["name"] as? String == "did-finish-load" { back.fulfill() }
        }
        saved.webView.goBack(); await fulfillment(of: [back], timeout: 15)
        XCTAssertEqual(saved.webView.url?.path, "/first")
        host.emit = { _, _ in }
    }

    private func load(_ page: DesktopBrowserPage, host: DesktopBrowserHost, address: String) async throws {
        let ready = expectation(description: "Loaded \(address)")
        host.emit = { channel, payload in
            let value = payload as? [String: Any]
            if channel == "browser:page-event", value?["tabId"] as? String == page.tabID, value?["name"] as? String == "did-finish-load" { ready.fulfill() }
        }
        page.webView.load(URLRequest(url: try XCTUnwrap(URL(string: address))))
        await fulfillment(of: [ready], timeout: 15)
        host.emit = { _, _ in }
    }
    private func eventually(_ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(check())
    }
}

private final class WeakWebView {
    weak var value: WKWebView?
    init(_ value: WKWebView) { self.value = value }
}
private final class MemoryPageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.memory.test")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port { self.listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue) }
                if case .failed(let error) = state { self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            let interactive = path == "/form" ? "<form><input name='answer'></form>" : path == "/frame" ? "<iframe srcdoc='<p>Embedded session</p>'></iframe>" : path == "/media" ? "<video controls></video>" : ""
            let body = Data("<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><title>Memory \(path)</title></head><body><h1>\(path)</h1>\(interactive)<article style='height:3000px'>Read-only lecture reference</article></body></html>".utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
