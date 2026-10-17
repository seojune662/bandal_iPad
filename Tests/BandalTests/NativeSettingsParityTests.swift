import XCTest
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class NativeSettingsParityTests: XCTestCase {
    func testPortableAppearancePreferencesPopulateOnlyValidatedRenderingValues() {
        let name = "settings-parity-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        NativeAppearancePreference.apply(["theme": "graphite", "fontScale": 1.2, "editorFont": "serif", "density": "compact", "openAdjacentTab": true, "restoreLastCourse": false], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "dark")
        XCTAssertEqual(defaults.double(forKey: "native.fontScale"), 1.2)
        XCTAssertEqual(defaults.string(forKey: "native.editorFont"), "serif")
        XCTAssertEqual(defaults.string(forKey: "native.density"), "compact")
        XCTAssertTrue(defaults.bool(forKey: "native.openAdjacentTab")); XCTAssertFalse(defaults.bool(forKey: "native.restoreLastCourse"))
        NativeAppearancePreference.apply(["fontScale": 12, "editorFont": "system", "density": "invalid"], defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: "native.fontScale"), 1)
        XCTAssertEqual(defaults.string(forKey: "native.editorFont"), "sans")
        XCTAssertEqual(defaults.string(forKey: "native.density"), "comfortable")
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "dark", "A partial update must not reset the current theme")
    }
    func testDesktopCategoryOrderAndSearchRetainThePortableDestinations() {
        XCTAssertEqual(NativeSettingsCatalog.categories.map(\.id), ["ai", "assistant", "account", "general", "university", "packs", "calendar", "browser", "appearance", "tabs", "widgets", "notifications", "shortcuts", "usage", "permissions", "privacy", "advanced", "experimental", "courses", "about"])
        XCTAssertEqual(NativeSettingsCatalog.matching("마이크 자막").map(\.id), ["tabs"])
        XCTAssertEqual(NativeSettingsCatalog.matching("privacy diagnostics", locale: "en-US").map(\.id), ["privacy"])
        XCTAssertEqual(NativeSettingsCatalog.localized("en-US").first { $0.id == "appearance" }?.title, "Appearance")
    }
    func testUniversityOverridesPreserveHiddenSitesAndApplyExplicitOrder() throws {
        XCTAssertEqual(NativeUniversityCatalog.universities.count, 18)
        let settings: [String: Any] = ["university": ["universityId": "snu", "hiddenServiceIds": ["snu.portal"], "serviceOrder": ["custom:test", "snu.myetl"], "openExternallyOverrides": ["snu.myetl": true], "customServices": [["id": "custom:test", "label": "시험 자료", "url": "https://example.edu/exams", "kind": "other"]]]]
        let visible = NativeUniversityCatalog.resolvedServices(settings: settings)
        XCTAssertEqual(Array(visible.prefix(2).map(\.id)), ["custom:test", "snu.myetl"])
        XCTAssertTrue(try XCTUnwrap(visible.first { $0.id == "snu.myetl" }).opensExternally)
        XCTAssertFalse(visible.contains { $0.id == "snu.portal" })
        XCTAssertTrue(try XCTUnwrap(NativeUniversityCatalog.resolvedServices(settings: settings, includeHidden: true).first { $0.id == "snu.portal" }).hidden)
        XCTAssertTrue(visible.contains { $0.id == "common.everytime" })
    }
    func testShortcutImportRejectsReservedTypingAndPreservesOtherDesktopActions() throws {
        let value = try NativeShortcutPreference.validateImport(Data(#"{"keybindings":{"browser-reload":"shift+mod+r","desktop-only-action":"mod+alt+g","close-tab":null}}"#.utf8))
        XCTAssertEqual(value["browser-reload"] as? String, "mod+shift+r")
        XCTAssertEqual(value["desktop-only-action"] as? String, "mod+alt+g")
        XCTAssertTrue(value["close-tab"] is NSNull)
        for key in ["t", "alt+t", "mod+v", "mod+shift+z", "mod+mod+b", "mod++"] { XCTAssertThrowsError(try NativeShortcutPreference.canonical(key), key) }
        XCTAssertEqual(try NativeShortcutPreference.canonical("mod+shift+space"), "mod+shift+space")
        let resolved = NativeBrowserShortcuts.resolve(["keybindings": value])
        XCTAssertFalse(resolved.contains { $0["action"] as? String == "close-tab" })
        XCTAssertTrue(resolved.contains { $0["chord"] as? String == "mod+shift+r" && $0["action"] as? String == "reload" })
    }
    func testSearchEngineSelectionOnlyChangesSearchRequests() throws {
        for (engine, host, parameter) in [("google", "www.google.com", "q"), ("naver", "search.naver.com", "query"), ("daum", "search.daum.net", "q"), ("duckduckgo", "duckduckgo.com", "q")] {
            let components = try XCTUnwrap(URLComponents(url: NativeBrowserSession.addressURL("한글 & 미분", searchEngine: engine), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, host)
            XCTAssertEqual(components.queryItems?.first { $0.name == parameter }?.value, "한글 & 미분")
            XCTAssertEqual(try NativeBrowserSession.addressURL("https://example.org/path", searchEngine: engine).host, "example.org")
        }
        XCTAssertThrowsError(try NativeSettingsValidation.webURL("https://user:password@example.org"))
        XCTAssertThrowsError(try NativeSettingsValidation.webURL("file:///private/test"))
    }
    func testBrowserScopesNeverAdoptEachOthersPagesAndSurviveScopeReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root); await store.start()
        XCTAssertTrue(store.isReady, store.errorMessage ?? "")
        let host = DesktopBrowserHost(root: root)
        host.emit = { channel, payload in store.events.send(.init(channel: channel, payload: payload)) }
        let left = NativeBrowserSession(store: store, host: host, workspaceID: "left", courseID: "course-A")
        let right = NativeBrowserSession(store: store, host: host, workspaceID: "right", courseID: "course-B")
        await left.start(); await right.start()
        XCTAssertNil(left.error); XCTAssertNil(right.error)
        let leftID = try XCTUnwrap(left.activeID), rightID = try XCTUnwrap(right.activeID)
        XCTAssertNotEqual(leftID, rightID)
        XCTAssertEqual(left.tabs.map(\.id), [leftID]); XCTAssertEqual(right.tabs.map(\.id), [rightID])
        XCTAssertEqual(host.pages[leftID]?.courseID, "course-A"); XCTAssertEqual(host.pages[rightID]?.courseID, "course-B")
        let global = NativeBrowserSession(store: store, host: host); await global.start()
        XCTAssertFalse(global.tabs.contains { $0.id == leftID || $0.id == rightID })
        try await left.add()
        let secondLeftID = try XCTUnwrap(left.activeID)
        XCTAssertNotEqual(secondLeftID, leftID)
        let reopened = NativeBrowserSession(store: store, host: host, workspaceID: "left", courseID: "course-A"); await reopened.start()
        XCTAssertEqual(reopened.tabs.map(\.id), [leftID, secondLeftID])
        XCTAssertEqual(reopened.activeID, secondLeftID, "Moving a pane must preserve its selected browser tab")
        XCTAssertEqual(NativeBrowserSession.currentPage(workspaceID: "left", store: store, host: host)?.id, secondLeftID)
        try await reopened.add(isPrivate: true)
        XCTAssertNil(NativeBrowserSession.currentPage(workspaceID: "left", store: store, host: host), "A private active page must not fall back to a public page saved in the same scope")
        reopened.select(secondLeftID)
        try await right.close(rightID)
        XCTAssertNotNil(host.pages[leftID]); XCTAssertEqual(left.activeID, secondLeftID)
    }
    func testTwoNativeWebViewportsRetainIndependentDOMAndDetachOnlyTheirOwnPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-viewports-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let first = try host.createPage(tabID: "left", profileID: "default", isPrivate: true, courseID: nil)
        let second = try host.createPage(tabID: "right", profileID: "default", isPrivate: true, courseID: nil)
        let left = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500)), right = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        host.attachNative(to: left, selectedTabID: first.tabID); host.attachNative(to: right, selectedTabID: second.tabID)
        first.webView.loadHTMLString("<html><body><input id='draft' value='left'></body></html>", baseURL: nil)
        second.webView.loadHTMLString("<html><body><input id='draft' value='right'></body></html>", baseURL: nil)
        try await waitForDOM(first.webView, expected: "left"); try await waitForDOM(second.webView, expected: "right")
        _ = try await first.webView.evaluateJavaScript("document.getElementById('draft').value='unsaved left'")
        host.layoutPages()
        XCTAssertTrue(first.webView.superview === left); XCTAssertTrue(second.webView.superview === right)
        XCTAssertFalse(first.webView.isHidden); XCTAssertFalse(second.webView.isHidden)
        host.detachNative(from: right)
        XCTAssertFalse(first.webView.isHidden); XCTAssertTrue(second.webView.isHidden)
        let leftDraft = try await first.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(leftDraft, "unsaved left")
        host.attachNative(to: right, selectedTabID: second.tabID)
        let rightDraft = try await second.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(rightDraft, "right")
        XCTAssertEqual(first.webView.frame, left.bounds); XCTAssertEqual(second.webView.frame, right.bounds)
    }
    func testClosingBrowserScopesCancelsAtomicallyAndInvalidatesChangedPlans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root); await store.start()
        let host = DesktopBrowserHost(root: root)
        host.emit = { channel, payload in store.events.send(.init(channel: channel, payload: payload)) }
        let left = NativeBrowserSession(store: store, host: host, workspaceID: "left")
        let right = NativeBrowserSession(store: store, host: host, workspaceID: "right")
        await left.start(); await right.start()
        let leftID = try XCTUnwrap(left.activeID), rightID = try XCTUnwrap(right.activeID)
        let leftPrepared = try await NativeBrowserSession.prepareScope(workspaceID: "left", host: host, store: store, approve: { _ in true })
        let leftPlan = try XCTUnwrap(leftPrepared)
        let rejected = try await NativeBrowserSession.prepareScope(workspaceID: "right", host: host, store: store, approve: { _ in false })
        XCTAssertNil(rejected)
        XCTAssertNotNil(host.pages[leftID]); XCTAssertNotNil(host.pages[rightID])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("native-browser-tabs-") }.count, 2)
        let rightPrepared = try await NativeBrowserSession.prepareScope(workspaceID: "right", host: host, store: store, approve: { _ in true })
        let rightPlan = try XCTUnwrap(rightPrepared)
        try await left.add()
        XCTAssertFalse(try NativeBrowserSession.commitScopes([leftPlan, rightPlan], host: host, store: store), "A popup/new page requires a fresh close confirmation")
        XCTAssertEqual(host.pages.count, 3)
        let refreshedPrepared = try await NativeBrowserSession.prepareScope(workspaceID: "left", host: host, store: store, approve: { _ in true })
        let refreshed = try XCTUnwrap(refreshedPrepared)
        XCTAssertTrue(try NativeBrowserSession.commitScopes([refreshed, rightPlan], host: host, store: store))
        XCTAssertTrue(host.pages.isEmpty); XCTAssertTrue(left.tabs.isEmpty); XCTAssertTrue(right.tabs.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("native-browser-tabs-") }.count, 0)
        do { try await left.add(); XCTFail("A retired scope recreated its pages") } catch is CancellationError { } catch { XCTFail("Unexpected close error: \(error)") }
    }
    private func waitForDOM(_ view: WKWebView, expected: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.getElementById('draft')?.value")) as? String == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Local HTML failed to load")
    }
}
