import XCTest
import UIKit
import WebKit
import Network
@testable import Bandal

@MainActor
final class BrowserPageActionsTests: XCTestCase {
    func testRealHTTPPopupPreservesPostCookieAndOpenerAndMultipartUpload() async throws {
        let server = try BrowserFormsFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-forms-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "form", "isPrivate": true])
        let opener = try XCTUnwrap(host.pages["form"])
        defer { for id in Array(host.pages.keys) { host.destroy(id) } }
        opener.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let formLoaded = expectation(description: "HTTP form loaded"), popupLoaded = expectation(description: "POST popup loaded")
        var popupID: String?
        host.emit = { channel, value in
            guard let event = value as? [String: Any] else { return }
            if channel == "browser:open-url" { popupID = event["tabId"] as? String }
            guard channel == "browser:page-event", event["name"] as? String == "did-finish-load" else { return }
            if event["tabId"] as? String == "form" { formLoaded.fulfill() }
            else if event["tabId"] as? String == popupID { popupLoaded.fulfill() }
        }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "form", "action": "loadURL", "args": ["http://127.0.0.1:\(port)/form"]])
        await fulfillment(of: [formLoaded], timeout: 20)
        // A named login window requests an opener. The separate _blank default
        // intentionally implies noopener and must remain the website's choice.
        _ = try await opener.webView.evaluateJavaScript("document.querySelector('form').submit()")
        await fulfillment(of: [popupLoaded], timeout: 20)
        let child = try XCTUnwrap(host.pages[try XCTUnwrap(popupID)])
        XCTAssertTrue(child.dataStore === opener.dataStore)
        XCTAssertEqual(child.profileID, opener.profileID)
        XCTAssertTrue(child.isPrivate)
        let openerResult = try await opener.webView.evaluateJavaScript("document.body.dataset.auth") as? String
        XCTAssertEqual(openerResult, "received", "The popup must retain window.opener")
        let posts = server.requests.filter { $0.path == "/auth" }
        XCTAssertEqual(posts.count, 1, "WebKit's supplied popup configuration must not cause a second GET")
        XCTAssertEqual(posts.first?.method, "POST")
        XCTAssertEqual(posts.first?.body, "ticket=fixture-ticket")
        XCTAssertTrue(posts.first?.headers.contains("session=fixture-cookie") == true)
        // Exercise the site's multipart upload through the same real WK cookie
        // store. OS picker presentation is a separate interactive device check.
        let upload = try await opener.webView.callAsyncJavaScript("""
        const form = new FormData();
        form.append('document', new File(['study-fixture'], 'lecture.txt', {type:'text/plain'}));
        const response = await fetch('/upload', {method:'POST', body:form});
        return await response.text();
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(upload, "uploaded")
        let request = try XCTUnwrap(server.requests.last { $0.path == "/upload" })
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.headers.lowercased().contains("multipart/form-data; boundary="))
        XCTAssertTrue(request.headers.contains("session=fixture-cookie"))
        XCTAssertTrue(request.body.contains("filename=\"lecture.txt\""))
        XCTAssertTrue(request.body.contains("study-fixture"))
    }

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

private final class BrowserFormsFixtureServer: @unchecked Sendable {
    struct Request { let method: String; let path: String; let headers: String; let body: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bandal.browser-forms-fixture")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    var requests: [Request] { lock.withLock { recorded } }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            let bytes = accumulated + (data ?? Data())
            guard bytes.count <= 1_000_000, error == nil else { connection.cancel(); return }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                return
            }
            let headers = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
            let count = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count - boundary.upperBound >= count else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                return
            }
            let first = headers.components(separatedBy: "\r\n")[0].split(separator: " ")
            let request = Request(method: first.first.map(String.init) ?? "", path: first.count > 1 ? String(first[1]) : "",
                                  headers: headers, body: String(decoding: bytes[boundary.upperBound...], as: UTF8.self))
            self.lock.withLock { self.recorded.append(request) }
            let text: String
            switch request.path {
            case "/form": text = "<!doctype html><form action='/auth' method='post' target='login-popup'><input name='ticket' value='fixture-ticket'></form>"
            case "/auth": text = "<!doctype html><title>Signed in</title><script>if(window.opener)window.opener.document.body.dataset.auth='received'</script>"
            case "/upload": text = "uploaded"
            default: text = "fixture"
            }
            let body = Data(text.utf8)
            let cookie = request.path == "/form" ? "Set-Cookie: session=fixture-cookie; Path=/; SameSite=Lax\r\n" : ""
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\(cookie)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { if $0 != nil { connection.cancel() } })
        }
    }
    func stop() { listener.cancel(); queue.async { self.connections.forEach { $0.cancel() }; self.connections.removeAll() } }
}
