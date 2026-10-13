import XCTest
import WebKit
@testable import Bandal

@MainActor
final class BrowserPresentationTests: XCTestCase {
    func testAutomaticDefaultAndExactHostProfileIsolationSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserPresentationStore(root: root)
        XCTAssertEqual(store.mode(profile: "default", host: "school.test", isPrivate: false), .automatic)
        try store.set(.desktop, profile: "default", host: "SCHOOL.test", isPrivate: false)
        try store.set(.mobile, profile: "second", host: "school.test", isPrivate: false)
        let restored = try BrowserPresentationStore(root: root)
        XCTAssertEqual(restored.mode(profile: "default", host: "school.test", isPrivate: false), .desktop)
        XCTAssertEqual(restored.mode(profile: "second", host: "school.test", isPrivate: false), .mobile)
        XCTAssertEqual(restored.mode(profile: "default", host: "sub.school.test", isPrivate: false), .automatic)
        XCTAssertEqual(restored.mode(profile: "default", host: "school.test.evil.test", isPrivate: false), .automatic)
        try restored.forget("second")
        XCTAssertEqual(try BrowserPresentationStore(root: root).mode(profile: "second", host: "school.test", isPrivate: false), .automatic)
    }
    func testPrivateOverridesNeverWriteAndEndWithTheirSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-private-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserPresentationStore(root: root)
        try store.set(.desktop, profile: "default", host: "school.test", isPrivate: false)
        let before = try Data(contentsOf: root.appendingPathComponent("website-presentation.json"))
        try store.set(.mobile, profile: "default", host: "private.test", isPrivate: true)
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: true), .mobile)
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: false), .automatic)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("website-presentation.json")), before)
        XCTAssertEqual(try BrowserPresentationStore(root: root).mode(profile: "default", host: "private.test", isPrivate: true), .automatic)
        store.discardPrivate("default")
        XCTAssertEqual(store.mode(profile: "default", host: "private.test", isPrivate: true), .automatic)
    }
    func testPublicWebKitPreferenceDoesNotFakeAnOldBrowserVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-preference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        try await host.prepareBrowserNetwork()
        let page = try host.createPage(tabID: "fixture", profileID: "default", isPrivate: true, courseID: nil)
        XCTAssertEqual(page.webView.configuration.defaultWebpagePreferences.preferredContentMode, .recommended)
        XCTAssertTrue(page.webView.customUserAgent?.isEmpty ?? true)
        XCTAssertEqual(page.webView.configuration.applicationNameForUserAgent, DesktopBrowserIdentity.applicationName)
        XCTAssertEqual(host.presentation(for: page, url: URL(string: "https://site.test")), .automatic)
        try host.presentationStore?.set(.desktop, profile: "default", host: "site.test", isPrivate: true)
        XCTAssertEqual(host.presentation(for: page, url: URL(string: "https://site.test/path")).contentMode, .desktop)
        host.destroy("fixture")
        let second = try host.createPage(tabID: "next", profileID: "default", isPrivate: true, courseID: nil)
        XCTAssertEqual(host.presentation(for: second, url: URL(string: "https://site.test")).contentMode, .recommended)
        host.destroy("next")
    }
}
