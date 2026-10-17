import XCTest
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class BrowserEngineImprovementsTests: XCTestCase {
    func testPopupReportURLsStayWithinTheirCreatingOriginAndMatchDesktopLimits() {
        XCTAssertEqual(BrowserPopupAdmission.sourceOrigin(scheme: "HTTPS", host: "School.Test", port: 443)?.absoluteString, "https://school.test")
        XCTAssertEqual(BrowserPopupAdmission.sourceOrigin(scheme: "http", host: "school.test", port: 0)?.absoluteString, "http://school.test")
        XCTAssertEqual(BrowserPopupAdmission.sourceOrigin(scheme: "https", host: "school.test", port: 8443)?.port, 8443)
        XCTAssertNil(BrowserPopupAdmission.sourceOrigin(scheme: "about", host: "", port: 0))
        XCTAssertNil(BrowserPopupAdmission.sourceOrigin(scheme: "https", host: "null", port: 443))
        XCTAssertNil(BrowserPopupAdmission.sourceOrigin(scheme: "https", host: "", port: 443))
        XCTAssertFalse(BrowserPopupAdmission.accepts(URL(string: "blob:https://school.test/report-id")!, opener: nil))
        let origin = URL(string: "https://school.test/course")!
        XCTAssertTrue(BrowserPopupAdmission.accepts(URL(string: "blob:https://school.test/report-id")!, opener: origin))
        XCTAssertTrue(BrowserPopupAdmission.accepts(URL(string: "blob:https://school.test:443/report-id")!, opener: origin))
        XCTAssertTrue(BrowserPopupAdmission.accepts(URL(string: "about:blank")!, opener: origin))
        XCTAssertTrue(BrowserPopupAdmission.accepts(NSURL(string: "about:blank")! as URL, opener: origin), "WebKit provides an NSURL-backed opaque URL")
        XCTAssertFalse(BrowserPopupAdmission.accepts(NSURL(string: "about:config")! as URL, opener: origin))
        XCTAssertTrue(BrowserPopupAdmission.accepts(URL(string: "https://login.school.test/auth")!, opener: origin))
        for raw in ["blob:https://other.test/id", "blob:http://school.test/id", "blob:null/id", "file:///private/report", "javascript:alert(1)", "data:text/html,report"] {
            XCTAssertFalse(BrowserPopupAdmission.accepts(URL(string: raw)!, opener: origin), raw)
        }
        var limiter = BrowserPopupAdmission()
        XCTAssertNil(limiter.admit(owner: 1, now: 10)); XCTAssertNil(limiter.admit(owner: 1, now: 10.1))
        XCTAssertEqual(limiter.admit(owner: 1, now: 10.2), "burst")
        XCTAssertNil(limiter.admit(owner: 1, now: 11.2))
        XCTAssertEqual(limiter.admit(owner: 1, now: 12.3), "limit")
        for owner in 2...4 { XCTAssertNil(limiter.admit(owner: owner, now: 12.3)) }
        XCTAssertEqual(limiter.admit(owner: 5, now: 12.3), "limit")
        limiter.release(owner: 1)
        XCTAssertNil(limiter.admit(owner: 5, now: 13.4), "Closing one child frees exactly one global slot")
    }

    func testSessionSwitchCancellationAndInvalidProfileKeepOriginalTypedForm() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-session-switch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "form", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["form"])
        defer { host.destroy("form") }
        try await load("<title>Draft form</title><input id='answer' value='initial'>", page: page, host: host)
        _ = try await page.webView.evaluateJavaScript("document.querySelector('input').value='keep this answer';window.refuse=e=>e.preventDefault();addEventListener('beforeunload',window.refuse);true")
        let profile = UUID().uuidString
        _ = try await host.handle(channel: "browser:saveProfile", request: ["id": profile, "name": "Separate", "color": "green", "icon": "globe"])
        // No visible presenter is a denied request, never implicit consent.
        let cancelledResult = try await host.handle(channel: "browser:switchPageSession", request: ["tabId": "form", "profileId": profile, "isPrivate": false])
        let cancelled = try XCTUnwrap(cancelledResult as? [String: Any])
        XCTAssertEqual(cancelled["allowed"] as? Bool, false)
        XCTAssertTrue(host.pages["form"] === page)
        let answerAfterCancel = try await page.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(answerAfterCancel, "keep this answer")
        do {
            _ = try await host.handle(channel: "browser:switchPageSession", request: ["tabId": "form", "profileId": "missing-profile"])
            XCTFail("An invalid profile must fail before replacing the form")
        } catch { }
        XCTAssertTrue(host.pages["form"] === page)
        let answerAfterFailure = try await page.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(answerAfterFailure, "keep this answer")
        let oldStore = page.dataStore, oldID = page.id
        _ = try await page.webView.evaluateJavaScript("removeEventListener('beforeunload',window.refuse);true")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "form", "action": "setZoomLevel", "args": [2.0]])
        let switchedResult = try await host.handle(channel: "browser:switchPageSession", request: ["tabId": "form", "profileId": profile, "isPrivate": false, "expectedWebContentsId": oldID])
        let switched = try XCTUnwrap(switchedResult as? [String: Any]), replacement = try XCTUnwrap(host.pages["form"])
        XCTAssertEqual(switched["allowed"] as? Bool, true)
        XCTAssertFalse(replacement === page); XCTAssertNotEqual(replacement.id, oldID)
        XCTAssertFalse(replacement.dataStore === oldStore)
        XCTAssertEqual(replacement.profileID, profile); XCTAssertFalse(replacement.isPrivate)
        XCTAssertEqual(replacement.webView.pageZoom, 1.44, accuracy: 0.001)
        XCTAssertEqual(host.pages.count, 1)
    }

    func testFindRebuildsAfterLiveTextChangesAndReportsQueryReverseCountAndZoomState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-live-find-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "find", "isPrivate": true])
        let page = try XCTUnwrap(host.pages["find"])
        defer { host.destroy("find") }
        try await load("<p id='first'>alpha <b>beta</b></p><p id='second'>alpha<br>beta</p><p hidden>alpha beta</p><input value='do not alter'>", page: page, host: host)
        var results: [[String: Any]] = [], zoomEvents = 0
        host.emit = { channel, value in
            guard channel == "browser:page-event", let event = value as? [String: Any] else { return }
            if event["name"] as? String == "zoom-updated" { zoomEvents += 1 }
            if event["name"] as? String == "found-in-page", let detail = event["detail"] as? [String: Any], let result = detail["result"] as? [String: Any] { results.append(result) }
        }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "find", "action": "findInPage", "args": ["alpha beta", ["forward": false]]])
        XCTAssertEqual(results.last?["query"] as? String, "alpha beta")
        XCTAssertEqual(results.last?["matches"] as? Int, 2); XCTAssertEqual(results.last?["activeMatchOrdinal"] as? Int, 2)
        // Mutate the existing connected text node: cached Ranges used to select
        // unrelated characters here instead of searching the new live content.
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#first').firstChild.nodeValue='changed ';document.querySelector('#second').remove();true")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "find", "action": "findInPage", "args": ["alpha beta", ["findNext": true]]])
        XCTAssertEqual(results.last?["matches"] as? Int, 0); XCTAssertEqual(results.last?["activeMatchOrdinal"] as? Int, 0)
        let untouchedInput = try await page.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(untouchedInput, "do not alter")
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "find", "action": "stopFindInPage"])
        let highlightsCleared = try await page.webView.callAsyncJavaScript("return !globalThis.CSS?.highlights?.has('bandal-find-all') && !document.getElementById('__bandalNativeFindStyle')", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(highlightsCleared, true)
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "find", "action": "setZoomLevel", "args": [2.0]])
        XCTAssertEqual(zoomEvents, 1)
        XCTAssertEqual(try XCTUnwrap(page.state["zoomLevel"] as? Double), 2, accuracy: 0.0001)
    }

    func testContextMenuPreservesSystemActionsAndNewTabKeepsSourceScopeAndPrivateStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-context-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let page = try host.createPage(tabID: "native-scope.fixture.original", profileID: "default", isPrivate: true, courseID: "course")
        defer { for id in Array(host.pages.keys) { host.destroy(id) } }
        let systemCopy = UIAction(title: "System copy", identifier: .init("fixture.system-copy")) { _ in }
        let items = page.contextMenuItems(["linkURL": "https://school.test/lecture", "selectionText": "selected text"], suggested: [systemCopy])
        let ids = items.compactMap { ($0 as? UIAction)?.identifier.rawValue }
        XCTAssertEqual(ids, ["bandal.open-link", "bandal.copy-link", "bandal.download-link", "bandal.search-selection", "fixture.system-copy"])
        let unsafe = page.contextMenuItems(["linkURL": "javascript:alert(1)"], suggested: [systemCopy])
        XCTAssertEqual(unsafe.count, 1); XCTAssertTrue(unsafe.first === systemCopy)
        var opened: [String: Any]?
        host.emit = { channel, value in if channel == "browser:open-url" { opened = value as? [String: Any] } }
        let child = try host.openLinkTab(URL(string: "about:blank")!, from: page)
        XCTAssertTrue(child.tabID.hasPrefix("native-scope.fixture.")); XCTAssertNotEqual(child.tabID, page.tabID)
        XCTAssertEqual(child.courseID, "course"); XCTAssertTrue(child.isPrivate)
        XCTAssertTrue(child.dataStore === page.dataStore)
        XCTAssertEqual(opened?["openerTabId"] as? String, page.tabID)
        XCTAssertEqual(opened?["tabId"] as? String, child.tabID)
        host.destroy(page.tabID)
        XCTAssertThrowsError(try host.openLinkTab(URL(string: "https://school.test/")!, from: page), "A menu from a closed or switched tab cannot create a new page")
    }

    private func load(_ html: String, page: DesktopBrowserPage, host: DesktopBrowserHost) async throws {
        let loaded = expectation(description: "Local WebKit fixture loaded")
        var finished = false
        host.emit = { channel, value in
            guard !finished, channel == "browser:page-event", let event = value as? [String: Any], event["name"] as? String == "did-finish-load" else { return }
            finished = true; loaded.fulfill()
        }
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        page.webView.loadHTMLString("<!doctype html>" + html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertTrue(finished)
    }
}
