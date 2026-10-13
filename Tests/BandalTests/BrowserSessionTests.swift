import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserSessionTests: XCTestCase {
    func testPrivateSessionsUseIsolatedNonpersistentDataStores() async throws {
        let regular = BrowserSession()
        let first = BrowserSession(isPrivate: true)
        let second = BrowserSession(isPrivate: true)
        XCTAssertTrue(regular.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(first.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(second.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "bandal-private-test.invalid", .path: "/", .name: "private", .value: "only-first", .secure: "TRUE"]))
        let firstStore = first.webView.configuration.websiteDataStore.httpCookieStore
        await firstStore.setCookie(cookie)
        let firstCookies = await firstStore.allCookies()
        let secondCookies = await second.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let regularCookies = await regular.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(firstCookies.contains { $0.name == "private" && $0.domain == cookie.domain })
        XCTAssertFalse(secondCookies.contains { $0.domain == cookie.domain })
        XCTAssertFalse(regularCookies.contains { $0.domain == cookie.domain })
        XCTAssertEqual(first.webView.configuration.userContentController.userScripts.count, 0)
        XCTAssertFalse(first.hasActiveDownloads)
    }

    func testPopupSessionPreservesProvidedStoreAndDoesNotReloadAURL() {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = store
        let child = BrowserSession(isPrivate: true, configuration: configuration)
        XCTAssertTrue(child.webView.configuration.websiteDataStore === store)
        XCTAssertNil(child.webView.url)
        XCTAssertNil(child.webView.backForwardList.currentItem)
    }
}
