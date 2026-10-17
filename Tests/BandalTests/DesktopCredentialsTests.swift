import XCTest
@testable import Bandal

@MainActor
final class DesktopCredentialsTests: XCTestCase {
    @MainActor final class Fixture {
        var values: [String: Data] = [:]
        var failWrites = false
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var service = DesktopCredentialsService(environment: .init(read: { [unowned self] in values[$0] }, write: { [unowned self] key, value in
            if failWrites { throw DesktopRuntimeError("fixture denied") }; values[key] = value
        }, now: { [unowned self] in now }))
    }
    func testProfileScopedSecretsNeverReturnedAndAmbiguousAccountNeverFilled() async throws {
        let fixture = Fixture(), service = fixture.service, other = UUID().uuidString
        service.profileExists = { $0 == "default" || $0 == other }
        let request: [String: Any] = ["origin": "https://school.example/login", "username": "student", "password": "secret-fixture"]
        let savedValue = try await service.handle(channel: "credentials:save", request: request)
        let saved = try XCTUnwrap(savedValue as? [String: Any])
        XCTAssertNil(saved["password"]); XCTAssertEqual(saved["origin"] as? String, "https://school.example")
        let otherList = try await service.handle(channel: "credentials:list", request: ["profileId": other])
        XCTAssertEqual((otherList as? [[String: Any]])?.count, 0)
        _ = try await service.handle(channel: "credentials:save", request: ["id": saved["id"]!, "origin": "https://school.example", "username": "renamed", "password": "", "autoSubmit": true])
        service.target = { guest, origin in .init(guestID: guest, tabID: "tab", profileID: "default", origin: origin, generation: 1) }
        var filledPassword = ""
        service.fill = { _, user, password, autoSubmit in XCTAssertEqual(user, "renamed"); XCTAssertTrue(autoSubmit); filledPassword = password; return ["filled": true, "submitted": true] }
        _ = try await service.handle(channel: "credentials:fill", request: ["origin": "https://school.example", "guestWebContentsId": 7])
        XCTAssertEqual(filledPassword, "secret-fixture")
        _ = try await service.handle(channel: "credentials:save", request: request)
        filledPassword = ""
        let ambiguous = try await service.handle(channel: "credentials:fill", request: ["origin": "https://school.example", "guestWebContentsId": 7])
        XCTAssertEqual((ambiguous as? [String: Bool])?["filled"], false); XCTAssertEqual(filledPassword, "")
    }
    func testFailedWriteAndCorruptPayloadPreserveExistingKeychainData() async throws {
        let fixture = Fixture(), service = fixture.service
        _ = try await service.handle(channel: "credentials:save", request: ["origin": "https://school.example", "username": "student", "password": "before"])
        let original = fixture.values["default"]; fixture.failWrites = true
        do { _ = try await service.handle(channel: "credentials:save", request: ["origin": "https://school.example", "username": "student", "password": "after"]); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(fixture.values["default"], original)
        fixture.values["default"] = Data("broken".utf8); fixture.failWrites = false
        let availability = try await service.handle(channel: "credentials:availability", request: [:])
        XCTAssertEqual((availability as? [String: String])?["state"], "unavailable")
        do { _ = try await service.handle(channel: "credentials:save", request: ["origin": "https://school.example", "username": "student", "password": "after"]); XCTFail("Expected corruption failure") } catch {}
        XCTAssertEqual(fixture.values["default"], Data("broken".utf8))
    }
    func testStagedCaptureExpiresAndNavigationRaceCannotSave() async throws {
        let fixture = Fixture(), service = fixture.service
        var generation = 1
        service.target = { guest, origin in .init(guestID: guest, tabID: "tab", profileID: "default", origin: origin, generation: generation) }
        service.capture = { _ in ["username": "student", "password": "fixture"] }
        let base: [String: Any] = ["origin": "https://school.example", "guestWebContentsId": 1]
        let stage = try await service.handle(channel: "credentials:capture", request: base.merging(["mode": "stage"], uniquingKeysWith: { _, new in new }))
        XCTAssertNil((stage as? [String: Any])?["password"]); XCTAssertNil(fixture.values["default"])
        fixture.now.addTimeInterval(61)
        let expired = try await service.handle(channel: "credentials:capture", request: base.merging(["mode": "commit"], uniquingKeysWith: { _, new in new }))
        XCTAssertTrue(expired is NSNull); XCTAssertNil(fixture.values["default"])
        service.capture = { _ in generation += 1; return ["username": "student", "password": "fixture"] }
        let raced = try await service.handle(channel: "credentials:capture", request: base)
        XCTAssertTrue(raced is NSNull); XCTAssertNil(fixture.values["default"])
        XCTAssertThrowsError(try DesktopCredentialsService.origin("http://school.example"))
        XCTAssertThrowsError(try DesktopCredentialsService.origin("https://user:secret@school.example"))
    }
    func testCSVQuotedFieldsHTTPSAndConflictKeepAreAtomic() throws {
        let fixture = Fixture(), service = fixture.service
        let result = try service.importCSV("\u{FEFF}url,username,password\r\nhttps://school.example,\"student, one\",\"pass\"\"word\"\r\nhttp://unsafe.example,u,p\r\nhttps://school.example,\"student, one\",replacement\r\n", profile: "default")
        XCTAssertEqual(result["imported"] as? Int, 1); XCTAssertEqual(result["skipped"] as? Int, 2)
        let values = try JSONDecoder().decode([DesktopCredentialsService.Login].self, from: XCTUnwrap(fixture.values["default"]))
        XCTAssertEqual(values.first?.password, "pass\"word"); XCTAssertEqual(values.first?.autoSubmit, false)
        let original = fixture.values["default"]; fixture.failWrites = true
        XCTAssertThrowsError(try service.importCSV("url,username,password\nhttps://second.example,user,new", profile: "default"))
        XCTAssertEqual(fixture.values["default"], original)
        XCTAssertThrowsError(try DesktopCredentialsService.csvRows("url,username,password\n\"unterminated"))
    }
    func testPrivateOrDeletedPageTargetCannotCaptureOrFill() async throws {
        let fixture = Fixture(), service = fixture.service
        service.target = { _, _ in throw DesktopRuntimeError("Private page") }
        var accessed = false
        service.capture = { _ in accessed = true; return ["username": "u", "password": "p"] }
        service.fill = { _, _, _, _ in accessed = true; return ["filled": true, "submitted": false] }
        for channel in ["credentials:capture", "credentials:fill"] {
            do { _ = try await service.handle(channel: channel, request: ["origin": "https://school.example", "guestWebContentsId": 1]); XCTFail("Expected target rejection") } catch {}
        }
        XCTAssertFalse(accessed); XCTAssertTrue(fixture.values.isEmpty)
    }
    func testManualStagedSaveCannotCommitAfterSameOriginNavigationAndFillCanSuppressAutoSubmit() async throws {
        let fixture = Fixture(), service = fixture.service
        var generation = 1
        service.target = { guest, origin in .init(guestID: guest, tabID: "tab", profileID: "default", origin: origin, generation: generation) }
        service.capture = { _ in ["username": "student", "password": "fixture-only"] }
        let base: [String: Any] = ["origin": "https://school.example", "guestWebContentsId": 7]
        _ = try await service.handle(channel: "credentials:capture", request: base.merging(["mode": "stage"], uniquingKeysWith: { _, new in new }))
        XCTAssertTrue(fixture.values.isEmpty, "Showing a save confirmation cannot persist a password")
        generation += 1
        let rejected = try await service.handle(channel: "credentials:capture", request: base.merging(["mode": "commit"], uniquingKeysWith: { _, new in new }))
        XCTAssertTrue(rejected is NSNull); XCTAssertTrue(fixture.values.isEmpty)
        _ = try await service.handle(channel: "credentials:save", request: ["origin": "https://school.example", "username": "student", "password": "fixture-only", "autoSubmit": true])
        var submitted: Bool?
        service.fill = { _, _, _, autoSubmit in submitted = autoSubmit; return ["filled": true, "submitted": autoSubmit] }
        let result = try await service.handle(channel: "credentials:fill", request: base.merging(["autoSubmit": false], uniquingKeysWith: { _, new in new }))
        XCTAssertEqual(submitted, false); XCTAssertEqual((result as? [String: Bool])?["submitted"], false)
    }
}
