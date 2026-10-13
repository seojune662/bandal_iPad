import XCTest
import Network
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class BrowserImageCopyTests: XCTestCase {
    func testCrossOriginImageCopiesOriginalUsingOnlyTheCurrentPrivateProfileCookies() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }.pngData())
        let server = try BrowserImageFixtureServer(body: png), port = try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-image-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "fixture", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["fixture"])
        defer { host.destroy("fixture") }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "image_fixture_session", .value: "selected_private_profile"]))
        await page.dataStore.httpCookieStore.setCookie(cookie)
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let loaded = expectation(description: "Cross-origin image loaded")
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "did-finish-load" else { return }
            loaded.fulfill()
        }
        // No network request for the base document. The image's different host
        // and port make canvas.toDataURL fail, like a CDN without CORS headers.
        page.webView.loadHTMLString("<!doctype html><style>body{margin:0}</style><img width=32 height=24 src='http://127.0.0.1:\(port)/image.png'>", baseURL: URL(string: "http://localhost:1/document"))
        await fulfillment(of: [loaded], timeout: 15)
        let canvas = try await page.webView.callAsyncJavaScript(BrowserScripts.image, arguments: ["x": 10, "y": 10], in: nil, contentWorld: .defaultClient)
        XCTAssertTrue(canvas == nil || canvas is NSNull, "The fixture must exercise the tainted-canvas fallback")
        let image = try await DesktopBrowserImageCopy.image(in: page.webView, at: CGPoint(x: 10, y: 10), doNotTrack: true)
        XCTAssertEqual(image.size.width * image.scale, 32)
        XCTAssertEqual(image.size.height * image.scale, 24)
        XCTAssertGreaterThanOrEqual(server.requests.count, 2)
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(request.contains("image_fixture_session=selected_private_profile"))
        XCTAssertTrue(request.lowercased().contains("dnt: 1"))
        XCTAssertTrue(request.lowercased().contains("sec-gpc: 1"))
        XCTAssertTrue(request.contains(" Safari/")); XCTAssertTrue(request.contains(" Bandal"))
        XCTAssertFalse(page.dataStore.isPersistent)
        let normalCookies = await host.persistence!.dataStore(profile: "default", isPrivate: false).httpCookieStore.allCookies()
        XCTAssertFalse(normalCookies.contains { $0.name == "image_fixture_session" })
        // The helper is tested without modifying the user's actual clipboard.
    }
    func testInvalidImagesAndNonWebFallbackSourcesAreRejected() {
        XCTAssertThrowsError(try DesktopBrowserImageCopy.decode(Data("not an image".utf8)))
        for address in ["file:///private/a.png", "data:image/png;base64,a", "https://user:password@example.test/image.png"] {
            XCTAssertFalse(DesktopBrowserImageCopy.isWebImageURL(URL(string: address)!))
        }
        XCTAssertTrue(DesktopBrowserImageCopy.isWebImageURL(URL(string: "https://cdn.example.test/image.png")!))
    }
}

private final class BrowserImageFixtureServer: @unchecked Sendable {
    private let body: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bandal.image-copy-fixture")
    private let lock = NSLock()
    private var captured: [String] = []
    var requests: [String] { lock.withLock { captured } }
    init(body: Data) throws { self.body = body; listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port { self.listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue) }
                if case .failed(let error) = state { self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    self.lock.withLock { self.captured.append(String(data: data ?? Data(), encoding: .utf8) ?? "") }
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8) + self.body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
