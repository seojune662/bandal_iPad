import XCTest
import WebKit
import Network
@testable import Bandal

@MainActor
final class DesktopBrowserPrivacyTests: XCTestCase {
    func testLMSHTTPTransportUsesScopedCookiesAndReturnsRealStatusAndBody() async throws {
        let server = try BrowserHeaderServer(), port = try await server.start()
        defer { server.stop() }
        let address = URL(string: "http://127.0.0.1:\(port)/headers")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "lms-session", .value: "fixture-only"]))
        let response = try await BrowserLMSResponse.fetch(address, cookies: [cookie], doNotTrack: true)
        XCTAssertEqual(response["httpStatus"] as? Int, 200)
        let body = try XCTUnwrap((response["text"] as? String)?.data(using: .utf8))
        let headers = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(headers["cookie"], "lms-session=fixture-only"); XCTAssertEqual(headers["accept"], "application/json")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lms-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        do { _ = try await host.fetchLMS(url: address.absoluteString, origin: "http://127.0.0.1:\(port)", profileID: "default"); XCTFail("Only original Canvas API endpoints are allowed") } catch {}
    }
    func testPrivacySignalsAndDirectRequestHeadersWithExplicitWebKitSubresourceLimit() async throws {
        let server = try BrowserHeaderServer(); let port = try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        host.applySettings(["trackingProtection": "balanced", "doNotTrack": true, "agentUse": false])
        try await host.waitForPrivacySettings()
        XCTAssertThrowsError(try host.requireAgentAccess())
        let page = try host.createPage(tabID: "privacy", profileID: "default", isPrivate: true, courseID: "course")
        let ready = expectation(description: "Actual HTTP page loaded")
        host.emit = { channel, value in if channel == "browser:page-event", (value as? [String: Any])?["name"] as? String == "did-finish-load" { ready.fulfill() } }
        page.webView.load(host.navigationRequest(URL(string: "http://127.0.0.1:\(port)/headers")!))
        await fulfillment(of: [ready], timeout: 10)
        let value = try await page.webView.evaluateJavaScript("JSON.parse(document.body.innerText)")
        let headers = try XCTUnwrap(value as? [String: String])
        XCTAssertEqual(headers["dnt"], "1"); XCTAssertEqual(headers["sec-gpc"], "1")
        let signals = try await page.webView.evaluateJavaScript("[navigator.doNotTrack,navigator.globalPrivacyControl]") as? [Any]
        XCTAssertEqual(signals?.first as? String, "1"); XCTAssertEqual(signals?.last as? Bool, true)
        host.applySettings(["trackingProtection": "off", "doNotTrack": false, "agentUse": true])
        try await host.waitForPrivacySettings(); XCTAssertNoThrow(try host.requireAgentAccess())
        let offValue = try await page.webView.callAsyncJavaScript("return await fetch('/headers?off').then(r=>r.json())", arguments: [:], in: nil, contentWorld: .page)
        let off = try XCTUnwrap(offValue as? [String: String])
        XCTAssertNil(off["dnt"]); XCTAssertNil(off["sec-gpc"])
    }

    func testClearingCacheKeepsNormalAndPrivateSessionCookies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let normal = host.persistence!.dataStore(profile: "default", isPrivate: false)
        let privateStore = host.persistence!.dataStore(profile: "default", isPrivate: true)
        let domain = "cache-\(UUID()).test".lowercased()
        for store in [normal, privateStore] {
            await store.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "login", .value: "keep"])))
        }
        for store in [normal, privateStore] {
            let before = await store.httpCookieStore.allCookies(); XCTAssertTrue(before.contains { $0.domain == domain })
        }
        await host.clearCache()
        for store in [normal, privateStore] {
            let cookies = await store.httpCookieStore.allCookies()
            XCTAssertTrue(cookies.contains { $0.domain == domain && $0.value == "keep" })
            for cookie in cookies where cookie.domain == domain { await store.httpCookieStore.delete(cookie) }
        }
    }
}

private final class BrowserHeaderServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.header.test")
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
            let lines = request.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") { headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            let json = lines.first?.contains("/headers") == true
            let body = json ? (try? JSONSerialization.data(withJSONObject: headers)) ?? Data() : Data("<!doctype html><html><body>HTTP header fixture</body></html>".utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(json ? "application/json" : "text/html"); charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
