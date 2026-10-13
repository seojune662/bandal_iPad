import XCTest
import WebKit
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class DesktopBrowserTests: XCTestCase {
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
