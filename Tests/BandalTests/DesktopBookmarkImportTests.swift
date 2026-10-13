import XCTest
@testable import Bandal

@MainActor
final class DesktopBookmarkImportTests: XCTestCase {
    func testSelectedHTMLReachesPrivateAtomicImportWithProfileAndBusyGuard() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        try Data("<a href=\"https://example.test\">수업</a>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let profile = UUID().uuidString
        var service: DesktopBookmarkImportService!
        service = DesktopBookmarkImportService(invoke: { channel, input in
            XCTAssertEqual(channel, "nativeBookmark:import")
            XCTAssertEqual(input["profileId"] as? String, profile)
            XCTAssertTrue((input["html"] as? String)?.contains("수업") == true)
            XCTAssertTrue(service.isImporting(profile))
            return ["imported": 1, "skipped": 0, "cancelled": false]
        }, pick: { file })
        service.profileExists = { $0 == profile }
        let result = try await service.handle(["profileId": profile]) as? [String: Any]
        XCTAssertEqual(result?["imported"] as? Int, 1)
        XCTAssertFalse(service.isImporting(profile))
    }

    func testCancelDeletedProfileOversizeAndInvalidUTF8NeverWrite() async throws {
        var selected: URL?, profileAlive = true, calls = 0
        let service = DesktopBookmarkImportService(invoke: { _, _ in calls += 1; return [:] }, pick: { selected })
        service.profileExists = { _ in profileAlive }
        let cancel = try await service.handle([:]) as? [String: Any]
        XCTAssertEqual(cancel?["cancelled"] as? Bool, true)
        profileAlive = false
        do { _ = try await service.handle([:]); XCTFail("Deleted profile accepted") } catch {}
        profileAlive = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        selected = file; defer { try? FileManager.default.removeItem(at: file) }
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        do { _ = try await service.handle([:]); XCTFail("Invalid UTF-8 accepted") } catch {}
        try Data(repeating: 65, count: DesktopBookmarkImportService.maximumBytes + 1).write(to: file)
        do { _ = try await service.handle([:]); XCTFail("Oversized HTML accepted") } catch {}
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(service.isImporting("default"))
    }

    func testProfileDisappearingWhilePickerIsOpenCannotBeImported() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        var alive = true, calls = 0
        let service = DesktopBookmarkImportService(invoke: { _, _ in calls += 1; return [:] }, pick: { alive = false; return file })
        service.profileExists = { _ in alive }
        do { _ = try await service.handle([:]); XCTFail("Profile disappeared during picker") } catch {}
        XCTAssertEqual(calls, 0)
    }
}
