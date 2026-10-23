import XCTest
@testable import Bandal

@MainActor
final class DesktopPermissionTests: XCTestCase {
    func testNotificationAndCalendarRequestRecoverAndRefreshThroughActualHandlers() async throws {
        var states = ["microphone": "not-determined", "notifications": "not-determined", "calendar": "denied"]
        var requested: [String] = [], opened = 0
        let access = DesktopPermissionAccess(state: { states[$0] ?? "not-applicable" }, request: {
            requested.append($0); states[$0] = "granted"
        }, openSettings: { opened += 1; return true })
        let service = DesktopSystemServices(permissionAccess: access)
        let response = try await service.handle(channel: "permissions:status", request: [:])
        let report = try XCTUnwrap(response as? [String: Any])
        let rows = try XCTUnwrap(report["permissions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 6)
        // The iPad app has no microphone access (App Review 2.5.4): never offered, never requested.
        XCTAssertEqual(rows.first { $0["id"] as? String == "microphone" }?["state"] as? String, "not-applicable")
        XCTAssertEqual(rows.first { $0["id"] as? String == "microphone" }?["canRequest"] as? Bool, false)
        XCTAssertEqual(rows.first { $0["id"] as? String == "notifications" }?["canRequest"] as? Bool, true)
        XCTAssertEqual(rows.first { $0["id"] as? String == "calendar" }?["canRequest"] as? Bool, false)
        _ = try await service.handle(channel: "permissions:request", request: ["id": "microphone"])
        let granted = try await service.handle(channel: "permissions:request", request: ["id": "notifications"]) as? [String: Any]
        XCTAssertEqual(granted?["state"] as? String, "granted")
        _ = try await service.handle(channel: "permissions:request", request: ["id": "calendar"])
        XCTAssertEqual(requested, ["notifications"], "Denied access must not falsely report a second OS prompt")
        _ = try await service.handle(channel: "permissions:openSettings", request: ["id": "calendar"])
        XCTAssertEqual(opened, 1)
        states["calendar"] = "granted"
        let refreshed = try await service.handle(channel: "permissions:status", request: [:]) as? [String: Any]
        XCTAssertEqual((refreshed?["permissions"] as? [[String: Any]])?.first { $0["id"] as? String == "calendar" }?["state"] as? String, "granted")
    }

    func testNotificationDenialRecoveryAndSchedulerFailureNeverClaimSuccess() async throws {
        var state = "not-determined", requests = 0, delivered = 0, fail = false
        let service = DesktopSystemServices(permissionAccess: .init(state: { _ in state }, request: { _ in requests += 1; state = "denied" }, openSettings: { true }), scheduleTestNotification: {
            if fail { throw DesktopRuntimeError("Scheduler failed") }
            delivered += 1
        })
        do { _ = try await service.handle(channel: "notifications:test", request: [:]); XCTFail("Denied permission was accepted") } catch {}
        do { _ = try await service.handle(channel: "notifications:test", request: [:]); XCTFail("Denied permission was accepted") } catch {}
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(delivered, 0)
        state = "granted"
        let result = try await service.handle(channel: "notifications:test", request: [:]) as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertEqual(delivered, 1)
        fail = true
        do { _ = try await service.handle(channel: "notifications:test", request: [:]); XCTFail("Scheduler failure was accepted") } catch {}
        XCTAssertEqual(delivered, 1)
    }

    func testInvalidPermissionNeverPromptsAndFailedSettingsPresentationIsNotSuccess() async throws {
        var requests = 0
        let service = DesktopSystemServices(permissionAccess: .init(state: { _ in "not-determined" }, request: { _ in requests += 1 }, openSettings: { false }))
        do { _ = try await service.handle(channel: "permissions:request", request: ["id": "invalid"]); XCTFail("Invalid ID was accepted") } catch {}
        do { _ = try await service.handle(channel: "permissions:openSettings", request: ["id": "calendar"]); XCTFail("Failed Settings presentation was accepted") } catch {}
        _ = try await service.handle(channel: "permissions:request", request: ["id": "screen"])
        XCTAssertEqual(requests, 0)
    }
}
