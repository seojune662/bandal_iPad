import XCTest
import WebKit
import UIKit
import PDFKit
import Network
@testable import Bandal

@MainActor
final class DesktopBrowserTests: XCTestCase {
    func testHTTPTransportExceptionAppliesOnlyToWebContent() throws {
        let settings = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(settings["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true)
        XCTAssertNotEqual(settings["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNotEqual(settings["NSAllowsArbitraryLoadsForMedia"] as? Bool, true)
    }
    func testNavigationErrorsUseTheirNativeDomainAndNeverTreatCancellationAsFailure() {
        let cases: [(Int, String)] = [(NSURLErrorNotConnectedToInternet, "offline"), (NSURLErrorCannotFindHost, "dns"),
            (NSURLErrorTimedOut, "timeout"), (NSURLErrorCannotConnectToHost, "connection"),
            (NSURLErrorServerCertificateUntrusted, "certificate"), (NSURLErrorAppTransportSecurityRequiresSecureConnection, "policy"),
            (NSURLErrorBadURL, "unsupported")]
        for (code, kind) in cases { XCTAssertEqual(BrowserNavigationFailure.kind(NSError(domain: NSURLErrorDomain, code: code)), kind) }
        XCTAssertNil(BrowserNavigationFailure.kind(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertNil(BrowserNavigationFailure.kind(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertEqual(BrowserNavigationFailure.kind(NSError(domain: "unrelated-domain", code: NSURLErrorNotConnectedToInternet)), "unknown")
        XCTAssertEqual(BrowserNavigationFailure.kind(NSError(domain: "unrelated-domain", code: NSURLErrorCancelled)), "unknown")
    }

    func testRealWebKitRetriesInitialFailureAndFailedDestinationInsteadOfPreviousPage() async throws {
        let server = try NavigationRecoveryServer(), port = try await server.start()
        defer { server.stop() }
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let page = try host.createPage(tabID: "recovery", profileID: "default", isPrivate: true, courseID: nil)
        defer { host.destroy("recovery") }
        var events: [[String: Any]] = []
        host.emit = { channel, value in if channel == "browser:page-event", let event = value as? [String: Any] { events.append(event) } }
        for path in ["/drop-initial", "/drop-next"] {
            server.dropsResponses = true; events.removeAll()
            let target = URL(string: "http://127.0.0.1:\(port)\(path)?original=1")!
            _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "recovery", "action": "loadURL", "args": [target.absoluteString]])
            try await waitForNavigation { events.contains { $0["name"] as? String == "did-fail-load" } }
            let failure = try XCTUnwrap(events.last { $0["name"] as? String == "did-fail-load" }?["detail"] as? [String: Any])
            let navigationID = try XCTUnwrap(failure["navigationId"] as? Int)
            XCTAssertEqual(failure["validatedURL"] as? String, target.absoluteString)
            XCTAssertEqual(failure["requestMethod"] as? String, "GET"); XCTAssertEqual(failure["retryable"] as? Bool, true)
            XCTAssertEqual(page.state["url"] as? String, target.absoluteString)
            XCTAssertEqual(page.state["loading"] as? Bool, false)
            let failedView = page.liveWebView
            let suspended = await page.suspendIfSafe()
            XCTAssertFalse(suspended, "Memory release must retain the exact failed destination for retry")
            XCTAssertTrue(page.liveWebView === failedView)
            XCTAssertEqual(page.state["url"] as? String, target.absoluteString)
            server.dropsResponses = false; events.removeAll()
            if path == "/drop-initial" {
                _ = try await host.handle(channel: "browser:retryNavigation", request: ["tabId": "recovery", "navigationId": navigationID])
            } else {
                // Toolbar reload must have the same correct destination.
                _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "recovery", "action": "reload"])
            }
            try await waitForNavigation { events.contains { $0["name"] as? String == "did-finish-load" } }
            XCTAssertEqual(page.webView.url, target)
            let title = try await page.webView.evaluateJavaScript("document.title") as? String
            XCTAssertEqual(title, path + "?original=1")
            XCTAssertGreaterThan(try XCTUnwrap(page.state["navigationId"] as? Int), navigationID)
            XCTAssertEqual(page.state["estimatedProgress"] as? Double, 1)
            XCTAssertFalse(events.contains { $0["name"] as? String == "did-fail-load" })
            do {
                _ = try await host.handle(channel: "browser:retryNavigation", request: ["tabId": "recovery", "navigationId": navigationID])
                XCTFail("A completed navigation cannot be retried using an old failure ID")
            } catch { }
        }
    }

    func testFailedPOSTReturnsToOriginalFormWithoutReplayingSubmission() async throws {
        let server = try NavigationRecoveryServer(), port = try await server.start()
        defer { server.stop() }
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let page = try host.createPage(tabID: "form", profileID: "default", isPrivate: true, courseID: nil)
        defer { host.destroy("form") }
        var events: [[String: Any]] = []
        host.emit = { channel, value in if channel == "browser:page-event", let event = value as? [String: Any] { events.append(event) } }
        page.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/form")!))
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-finish-load" } }
        server.dropsResponses = true; events.removeAll()
        _ = try await page.webView.evaluateJavaScript("document.querySelector('input').value='keep my answer'; document.forms[0].submit(); true")
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-fail-load" } }
        let detail = try XCTUnwrap(events.last { $0["name"] as? String == "did-fail-load" }?["detail"] as? [String: Any])
        let navigationID = try XCTUnwrap(detail["navigationId"] as? Int)
        XCTAssertEqual(detail["requestMethod"] as? String, "POST"); XCTAssertEqual(detail["retryable"] as? Bool, false)
        XCTAssertEqual(detail["canReturnToForm"] as? Bool, true)
        let count = server.requestCount
        do {
            _ = try await host.handle(channel: "browser:retryNavigation", request: ["tabId": "form", "navigationId": navigationID])
            XCTFail("POST must not replay")
        } catch { }
        _ = try await host.handle(channel: "browser:returnToForm", request: ["tabId": "form", "navigationId": navigationID])
        XCTAssertEqual(server.requestCount, count)
        let answer = try await page.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(answer, "keep my answer")
        XCTAssertEqual(page.state["url"] as? String, "http://127.0.0.1:\(port)/form")
        XCTAssertEqual(events.last?["name"] as? String, "navigation-recovered")
    }

    func testLateCallbacksStopAndWebProcessRecoveryRespectNavigationIdentity() async throws {
        let server = try NavigationRecoveryServer(), port = try await server.start()
        defer { server.stop() }
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let page = try host.createPage(tabID: "race", profileID: "default", isPrivate: true, courseID: nil)
        defer { host.destroy("race") }
        var events: [[String: Any]] = []
        host.emit = { channel, value in if channel == "browser:page-event", let event = value as? [String: Any] { events.append(event) } }
        let old = try XCTUnwrap(page.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hang")!)))
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-start-loading" } }
        let target = URL(string: "http://127.0.0.1:\(port)/newer")!
        let current = try XCTUnwrap(page.load(URLRequest(url: target)))
        page.webView(page.webView, didFailProvisionalNavigation: old, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-finish-load" } }
        XCTAssertFalse(events.contains { $0["name"] as? String == "did-fail-load" })
        XCTAssertEqual(page.state["url"] as? String, target.absoluteString)
        page.webView(page.webView, didFailProvisionalNavigation: current, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertFalse(events.contains { $0["name"] as? String == "did-fail-load" })
        page.webViewWebContentProcessDidTerminate(page.webView)
        let crashedID = try XCTUnwrap(page.state["navigationId"] as? Int)
        XCTAssertEqual(events.last?["name"] as? String, "did-fail-load")
        events.removeAll(); try page.retry(navigationID: crashedID)
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-finish-load" } }
        let stopped = try XCTUnwrap(page.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hang")!)))
        page.stop(); events.removeAll()
        page.webView(page.webView, didFailProvisionalNavigation: stopped, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertFalse(events.contains { $0["name"] as? String == "did-fail-load" })
        page.webViewWebContentProcessDidTerminate(page.webView)
        let stoppedCrash = try XCTUnwrap(events.last?["detail"] as? [String: Any])
        XCTAssertEqual(stoppedCrash["validatedURL"] as? String, target.absoluteString, "A crash after stop must recover the visible document, not the cancelled request")
        XCTAssertEqual(stoppedCrash["requestMethod"] as? String, "GET")
        events.removeAll(); try page.retry(navigationID: XCTUnwrap(stoppedCrash["navigationId"] as? Int))
        try await waitForNavigation { events.contains { $0["name"] as? String == "did-finish-load" } }
        XCTAssertEqual(page.webView.url, target)
    }

    func testRedirectedPOSTUsesTheFinalMethodForRecovery() async throws {
        let server = try NavigationRecoveryServer(), port = try await server.start()
        defer { server.stop() }
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let page = try host.createPage(tabID: "redirect", profileID: "default", isPrivate: true, courseID: nil)
        defer { host.destroy("redirect") }
        var failure: [String: Any]?
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "did-fail-load" else { return }
            failure = event["detail"] as? [String: Any]
        }
        server.dropsResponses = true
        for (status, method) in [(303, "GET"), (307, "POST")] {
            failure = nil
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/redirect\(status)")!)
            request.httpMethod = "POST"; request.httpBody = Data("answer=fixture".utf8)
            page.load(request)
            try await waitForNavigation { failure != nil }
            XCTAssertEqual(failure?["validatedURL"] as? String, "http://127.0.0.1:\(port)/drop-redirected")
            XCTAssertEqual(failure?["requestMethod"] as? String, method)
            XCTAssertEqual(failure?["retryable"] as? Bool, method == "GET")
        }
    }

    private func waitForNavigation(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !ready() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(ready(), "WebKit navigation did not complete before the deadline")
    }
    func testDeletingProfileRejectsCredentialAndPageUseBeforeAsynchronousStoreRemoval() async throws {
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let value = try await host.handle(channel: "browser:saveProfile", request: ["name": "Disposable", "color": "#123456", "icon": "globe"]) as? [String: Any]
        let id = try XCTUnwrap(value?["id"] as? String)
        var deletedSecret = false
        host.onDeleteProfile = { deleting in
            XCTAssertEqual(deleting, id); XCTAssertFalse(host.isProfileAvailable(id))
            XCTAssertThrowsError(try host.createPage(tabID: "racing-page", profileID: id, isPrivate: false, courseID: nil))
            deletedSecret = true
        }
        _ = try await host.handle(channel: "browser:deleteProfile", request: ["id": id])
        XCTAssertTrue(deletedSecret); XCTAssertFalse(host.isProfileAvailable(id))
        XCTAssertNil(host.pages["racing-page"])
    }
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-browser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProfilesHistoryAndPermissionsPersistWithExactDesktopShapes() async throws {
        let root = try temporaryRoot(), host = DesktopBrowserHost(root: root)
        let profile = try await host.handle(channel: "browser:saveProfile", request: ["name": "학습", "color": "#397db5", "icon": "book"]) as? [String: Any]
        let id = try XCTUnwrap(profile?["id"] as? String)
        for title in ["처음", "다시"] {
            _ = try await host.handle(channel: "browser:recordVisit", request: ["profileId": id, "url": "https://example.test/lecture", "title": title, "courseId": "course-a"])
        }
        _ = try await host.handle(channel: "browser:setPopupPermission", request: ["profileId": id, "origin": "https://example.test", "decision": "granted"])
        let restored = DesktopBrowserHost(root: root)
        let history = try await restored.handle(channel: "browser:searchHistory", request: ["profileId": id, "query": "다시"]) as? [String: Any]
        let entries = try XCTUnwrap(history?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["visitCount"] as? Int, 2)
        let permissions = try await restored.handle(channel: "browser:sitePermissions", request: ["profileId": id]) as? [String: Any]
        XCTAssertEqual((permissions?["permissions"] as? [[String: Any]])?.first?["decision"] as? String, "granted")
        let extensions = try await restored.handle(channel: "browser:extensions", request: [:]) as? [String: Any]
        XCTAssertEqual((extensions?["extensions"] as? [Any])?.count, 0)
        let normalHistory = try await restored.handle(channel: "browser:searchHistory", request: ["query": ""]) as? [String: Any]
        XCTAssertEqual((normalHistory?["entries"] as? [Any])?.count, 0)
    }

    func testPrivateStoreSurvivesSiblingTabsThenIsDiscardedWithoutNormalCookies() async throws {
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let regular = try host.createPage(tabID: "normal", profileID: "default", isPrivate: false, courseID: nil)
        let first = try host.createPage(tabID: "private-1", profileID: "default", isPrivate: true, courseID: nil)
        let second = try host.createPage(tabID: "private-2", profileID: "default", isPrivate: true, courseID: nil)
        let store = first.webView.configuration.websiteDataStore
        XCTAssertFalse(store.isPersistent)
        XCTAssertTrue(store === second.webView.configuration.websiteDataStore)
        XCTAssertFalse(store === regular.webView.configuration.websiteDataStore)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "private-\(UUID().uuidString).test", .path: "/", .name: "session", .value: "only-private"]))
        await store.httpCookieStore.setCookie(cookie)
        let privateCookies = await second.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let normalCookies = await regular.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(privateCookies.contains { $0.domain == cookie.domain })
        XCTAssertFalse(normalCookies.contains { $0.domain == cookie.domain })
        host.destroy("private-1")
        XCTAssertTrue(store === host.persistence?.dataStore(profile: "default", isPrivate: true))
        host.destroy("private-2")
        let newStore = try XCTUnwrap(host.persistence?.dataStore(profile: "default", isPrivate: true))
        XCTAssertFalse(store === newStore)
        let freshCookies = await newStore.httpCookieStore.allCookies()
        XCTAssertFalse(freshCookies.contains { $0.domain == cookie.domain })
        host.destroy("normal")
    }

    func testBoundsOcclusionAndOwnershipIgnoreStaleDestruction() async throws {
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let shell = WKWebView(frame: container.bounds); container.addSubview(shell); host.attach(to: container, shell: shell)
        let result = try await host.handle(channel: "browser:createPage", request: ["tabId": "tab", "isPrivate": false, "courseId": "old"]) as? [String: Any]
        let id = try XCTUnwrap((result?["state"] as? [String: Any])?["id"] as? Int)
        let page = try XCTUnwrap(host.pages["tab"])
        _ = try await host.handle(channel: "browser:pageBounds", request: ["tabId": "tab", "bounds": ["x": 20.0, "y": 80.0, "width": 420.0, "height": 700.0]])
        XCTAssertEqual(page.webView.frame, CGRect(x: 20, y: 80, width: 420, height: 520))
        XCTAssertFalse(page.webView.isHidden)
        _ = try await host.handle(channel: "browser:setHostOccluded", request: ["occluded": true]); XCTAssertTrue(page.webView.isHidden)
        _ = try await host.handle(channel: "browser:setHostOccluded", request: ["occluded": false]); XCTAssertFalse(page.webView.isHidden)
        _ = try await host.handle(channel: "browser:setCourse", request: ["tabId": "tab", "courseId": "new", "revision": 2, "expectedWebContentsId": id])
        _ = try await host.handle(channel: "browser:setCourse", request: ["tabId": "tab", "courseId": "stale", "revision": 1, "expectedWebContentsId": id])
        XCTAssertEqual(page.courseID, "new")
        _ = try await host.handle(channel: "browser:destroyPage", request: ["tabId": "tab", "expectedWebContentsId": id + 1])
        XCTAssertTrue(host.pages["tab"] === page)
        _ = try await host.handle(channel: "browser:destroyPage", request: ["tabId": "tab", "expectedWebContentsId": id])
        XCTAssertNil(host.pages["tab"])
        XCTAssertNil(page.webView.superview)
    }

    func testActualWebPageScriptFindObservationAndNoApplicationBridge() async throws {
        let host = DesktopBrowserHost(root: try temporaryRoot())
        let page = try host.createPage(tabID: "web", profileID: "default", isPrivate: true, courseID: nil)
        page.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let loaded = expectation(description: "WebKit loaded real HTML"), observed = expectation(description: "Console observation forwarded")
        var events: [[String: Any]] = []
        host.emit = { channel, payload in
            guard channel == "browser:page-event", let event = payload as? [String: Any] else { return }
            events.append(event)
            if event["name"] as? String == "did-finish-load" { loaded.fulfill() }
            if event["name"] as? String == "console-message", (event["detail"] as? [String: Any])?["message"] as? String == "__bandal_test:ok" { observed.fulfill() }
        }
        page.webView.loadHTMLString("<html><head><title>Fixture</title></head><body><p>alpha beta alpha</p></body></html>", baseURL: URL(string: "https://fixture.test"))
        await fulfillment(of: [loaded], timeout: 20)
        let scriptResult = try await host.handle(channel: "browser:pageAction", request: ["tabId": "web", "action": "executeJavaScript", "args": ["({title:document.title,appBridge:!!window.bandal,ipcHandler:!!window.webkit.messageHandlers.bandal,observer:typeof window.webkit.messageHandlers.browserObservation?.postMessage})"]]) as? [String: Any]
        XCTAssertEqual(scriptResult?["title"] as? String, "Fixture")
        XCTAssertEqual(scriptResult?["appBridge"] as? Bool, false)
        XCTAssertEqual(scriptResult?["ipcHandler"] as? Bool, false)
        XCTAssertEqual(scriptResult?["observer"] as? String, "function")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "web", "action": "executeJavaScript", "args": ["console.log('__bandal_test:ok');42"]])
        await fulfillment(of: [observed], timeout: 5)
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "web", "action": "findInPage", "args": ["alpha"]])
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "web", "action": "findInPage", "args": ["alpha", ["findNext": true, "forward": true]]])
        let found = try XCTUnwrap(events.last { $0["name"] as? String == "found-in-page" }?["detail"] as? [String: Any])
        let matches = try XCTUnwrap(found["result"] as? [String: Any])
        XCTAssertEqual(matches["matches"] as? Int, 2)
        XCTAssertEqual(matches["activeMatchOrdinal"] as? Int, 2)
        let revisions = events.compactMap { ($0["state"] as? [String: Any])?["stateRevision"] as? Int }
        XCTAssertEqual(revisions, revisions.sorted())
        XCTAssertEqual(Set(revisions).count, revisions.count)
        let printed = try await host.handle(channel: "browser:pageAction", request: ["tabId": "web", "action": "printToPDF", "args": [["pageSize": "Letter", "landscape": true, "printBackground": false]]]) as? [String: Any]
        let bytes = try XCTUnwrap((printed?["__bandalBytes"] as? String).flatMap { Data(base64Encoded: $0) })
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(pdf.pageCount, 0)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).width, 792, accuracy: 1)
        XCTAssertTrue(pdf.string?.contains("alpha") == true)
        host.destroy("web")
    }

    func testRejectsLocalFileJavaScriptNavigationAndInvalidBounds() throws {
        for source in ["file:///private/data", "javascript:alert(1)", "bandal-app://shell/index.html", "data:text/html,hello", "https://"] {
            XCTAssertThrowsError(try DesktopBrowserHost.navigationURL(source), source)
        }
        XCTAssertNoThrow(try DesktopBrowserHost.navigationURL("https://example.test/path?q=1"))
        XCTAssertThrowsError(try DesktopBrowserHost.rectangle(["x": Double.infinity, "y": 0.0, "width": 10.0, "height": 10.0]))
        XCTAssertFalse(DesktopBrowserHost.domain("notexample.test", matches: "example.test"))
    }

    func testFaviconCookiesCannotFollowCrossOriginOrInsecureRedirects() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "school.test", .path: "/account", .name: "session", .value: "fixture", .secure: "TRUE"]))
        let delegate = BrowserFaviconRedirect(cookies: [cookie])
        XCTAssertNotNil(delegate.request(for: URL(string: "https://school.test/account/icon.png")!).value(forHTTPHeaderField: "Cookie"))
        for raw in ["https://cdn.test/account/icon.png", "http://school.test/account/icon.png", "https://school.test/accounts/icon.png", "https://school.test.evil.test/account/icon.png"] {
            XCTAssertNil(delegate.request(for: URL(string: raw)!).value(forHTTPHeaderField: "Cookie"), raw)
        }
    }
}

final class NavigationRecoveryServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.navigation-recovery.fixture")
    private let lock = NSLock()
    private var drop = false
    private var requests = 0
    private var connections: [NWConnection] = []
    var dropsResponses: Bool { get { lock.withLock { drop } } set { lock.withLock { drop = newValue } } }
    var requestCount: Int { lock.withLock { requests } }
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
    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }
    private func receive(_ connection: NWConnection) {
        connections.append(connection); connection.start(queue: queue)
        receiveHeaders(connection, accumulated: Data())
    }
    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, _ in
            guard let self, let data else { connection.cancel(); return }
            let accumulated = accumulated + data
            guard let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !complete, accumulated.count < 65_536 { self.receiveHeaders(connection, accumulated: accumulated) }
                else { connection.cancel() }
                return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            let shouldDrop = self.lock.withLock { self.requests += 1; return self.drop && path.hasPrefix("/drop") }
            if shouldDrop { connection.cancel(); return }
            if path == "/hang" { return }
            if path == "/redirect303" || path == "/redirect307" {
                let code = path == "/redirect303" ? "303 See Other" : "307 Temporary Redirect"
                let response = Data("HTTP/1.1 \(code)\r\nLocation: /drop-redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }); return
            }
            let form = path == "/form" ? "<form method='post' action='/drop-post'><input name='answer'><button>Send</button></form>" : ""
            let body = Data("<!doctype html><html><head><title>\(path)</title></head><body><h1>\(path)</h1>\(form)</body></html>".utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
