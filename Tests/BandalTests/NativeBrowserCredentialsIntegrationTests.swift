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
}
