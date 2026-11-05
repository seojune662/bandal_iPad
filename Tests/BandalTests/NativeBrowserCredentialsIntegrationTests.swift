import XCTest
import Combine
@testable import Bandal

@MainActor
final class NativeBrowserCredentialsIntegrationTests: XCTestCase {
    func testNativeRuntimeRoutesExplicitCredentialActionsAndProfileDeletionWithoutRealKeychainWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-credential-routing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        var values: [String: Data] = [:], writes = 0
        let services = NativePlatformServices(store: store, credentialEnvironment: .init(read: { values[$0] }, write: { key, value in values[key] = value; writes += 1 }))
        defer { withExtendedLifetime(services) {} }
        await store.start()
        XCTAssertTrue(store.isReady, store.errorMessage ?? "Store startup failed")
        let availability = try await store.invoke("credentials:availability") as? [String: String]
        XCTAssertEqual(availability?["state"], "ready"); XCTAssertEqual(writes, 0)
        let profile = UUID().uuidString
        var profileEvents: [[String: Any]] = []
        let subscription = store.events.sink { event in
            if event.channel == "browser:profiles-changed", let payload = event.payload as? [String: Any] { profileEvents.append(payload) }
        }
        defer { subscription.cancel() }
        _ = try await store.invoke("browser:saveProfile", ["id": profile, "name": "Fixture", "color": "green", "icon": "globe"])
        XCTAssertEqual(profileEvents.last?["profileId"] as? String, profile)
        XCTAssertEqual(profileEvents.last?["action"] as? String, "saved")
        _ = try await store.invoke("credentials:save", ["profileId": profile, "origin": "https://example.test", "username": "fixture-user", "password": "fixture-secret"])
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(Set(values.keys), [root.lastPathComponent + ":" + profile], "Use the legacy namespace without writing to production Keychain")
        let list = try await store.invoke("credentials:list", ["profileId": profile]) as? [[String: Any]]
        XCTAssertEqual(list?.count, 1); XCTAssertNil(list?.first?["password"])
        XCTAssertEqual(list?.first?["username"] as? String, "fixture-user")
        let privatePage = try services.browser.createPage(tabID: "private", profileID: profile, isPrivate: true, courseID: nil)
        do {
            _ = try await store.invoke("credentials:capture", ["origin": "https://example.test", "guestWebContentsId": privatePage.id, "mode": "stage"])
            XCTFail("The real host target must reject private capture before accessing form contents")
        } catch { }
        XCTAssertEqual(writes, 1)
        services.browser.destroy("private")
        _ = try await store.invoke("browser:deleteProfile", ["id": profile])
        XCTAssertTrue(values.isEmpty); XCTAssertEqual(writes, 2)
        XCTAssertEqual(profileEvents.map { $0["action"] as? String }, ["saved", "deleted"])
    }

    func testSubmittedLoginOfferSavesUpdatesAndRespectsNeverForSite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-credential-offer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        var values: [String: Data] = [:]
        let services = NativePlatformServices(store: store, credentialEnvironment: .init(read: { values[$0] }, write: { key, value in values[key] = value }))
        defer { withExtendedLifetime(services) {} }
        await store.start()
        let page = try services.browser.createPage(tabID: "offer", profileID: "default", isPrivate: false, courseID: nil)
        defer { services.browser.destroy("offer") }
        func offer(_ password: String) { page.loginOffer = .init(origin: "https://login.test", username: "student", password: password, expires: Date().addingTimeInterval(60)) }

        offer("first")
        let prompt = try await store.invoke("credentials:reviewOffer", ["tabId": "offer"]) as? [String: Any]
        XCTAssertEqual(prompt?["username"] as? String, "student"); XCTAssertEqual(prompt?["update"] as? Bool, false)
        XCTAssertNil(prompt?["password"], "The prompt carries metadata only")
        _ = try await store.invoke("credentials:resolveOffer", ["tabId": "offer", "decision": "save"])
        XCTAssertNil(page.loginOffer)
        let saved = try await store.invoke("credentials:list", ["profileId": "default"]) as? [[String: Any]]
        XCTAssertEqual(saved?.count, 1)

        offer("first")
        let same = try await store.invoke("credentials:reviewOffer", ["tabId": "offer"])
        XCTAssertTrue(same is NSNull, "Submitting a login that is already saved shows no prompt")
        offer("second")
        let changed = try await store.invoke("credentials:reviewOffer", ["tabId": "offer"]) as? [String: Any]
        XCTAssertEqual(changed?["update"] as? Bool, true)
        _ = try await store.invoke("credentials:resolveOffer", ["tabId": "offer", "decision": "never"])
        XCTAssertTrue(services.browser.neverSavesPasswords(profileID: "default", origin: "https://login.test"))
        let afterNever = try await store.invoke("credentials:list", ["profileId": "default"]) as? [[String: Any]]
        XCTAssertEqual(afterNever?.count, 1, "Never does not save the new password")

        page.loginOffer = .init(origin: "https://login.test", username: "student", password: "x", expires: Date().addingTimeInterval(-1))
        let expired = try await store.invoke("credentials:reviewOffer", ["tabId": "offer"])
        XCTAssertTrue(expired is NSNull)
    }

    func testSavedLoginFillsOnLoadAndSeveralAccountsAreOfferedInstead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-credential-autofill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        var values: [String: Data] = [:]
        let services = NativePlatformServices(store: store, credentialEnvironment: .init(read: { values[$0] }, write: { key, value in values[key] = value }))
        defer { withExtendedLifetime(services) {} }
        await store.start()
        let page = try services.browser.createPage(tabID: "fill", profileID: "default", isPrivate: false, courseID: nil)
        defer { services.browser.destroy("fill") }
        func load(_ html: String) async throws {
            let loaded = expectation(description: "loaded")
            let subscription = store.events.sink { event in
                if event.channel == "browser:page-event", let value = event.payload as? [String: Any], value["tabId"] as? String == "fill", value["name"] as? String == "did-finish-load" { loaded.fulfill() }
            }
            page.webView.loadHTMLString(html, baseURL: URL(string: "https://login.test/"))
            await fulfillment(of: [loaded], timeout: 10); subscription.cancel()
        }
        let form = "<form><input id=u name=u><input id=p type=password name=p><button>Go</button></form>"
        let read = "return document.getElementById('u').value + '/' + document.getElementById('p').value"

        try await load("<p>No login form here</p>")
        _ = try await store.invoke("credentials:save", ["profileId": "default", "origin": "https://login.test", "username": "student", "password": "secret"])
        let noForm = try await store.invoke("credentials:autofill", ["tabId": "fill"]) as? [String: Any]
        XCTAssertEqual(noForm?["filled"] as? Bool, false)

        try await load(form)
        let single = try await store.invoke("credentials:autofill", ["tabId": "fill"]) as? [String: Any]
        XCTAssertEqual(single?["filled"] as? Bool, true)
        let filled = try await page.webView.callAsyncJavaScript(read, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(filled, "student/secret")

        _ = try await store.invoke("credentials:save", ["profileId": "default", "origin": "https://login.test", "username": "other", "password": "secret2"])
        try await load(form)
        let several = try await store.invoke("credentials:autofill", ["tabId": "fill"]) as? [String: Any]
        XCTAssertEqual(several?["filled"] as? Bool, false)
        XCTAssertEqual((several?["accounts"] as? [[String: Any]])?.compactMap { $0["username"] as? String }.sorted(), ["other", "student"])
        XCTAssertNil((several?["accounts"] as? [[String: Any]])?.first?["password"])
        let untouched = try await page.webView.callAsyncJavaScript(read, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(untouched, "/", "With several accounts nothing is filled until the user picks one")
    }
}
