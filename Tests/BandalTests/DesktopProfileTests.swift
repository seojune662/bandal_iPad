import XCTest
@testable import Bandal

@MainActor
final class DesktopProfileTests: XCTestCase {
    func testNewProfileRequiresVerifiedCurrentBackupAndRetainsOriginalBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("BandalDesktop")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = root.appendingPathComponent("note.md"); try Data("private original".utf8).write(to: note)
        let database = try DesktopSQLite(url: root.appendingPathComponent("bandal.db"))
        try database.exec("CREATE TABLE courses(folder_path TEXT); CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES('in-WAL')")
        let service = DesktopProfileService(documents: folder, root: root)
        service.exportDirectory = { $0 }
        do { _ = try await service.handle("profile:new"); XCTFail("Backup is required") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("active-profile.json").path))
        let backup = try await service.handle("profile:backup")
        XCTAssertEqual(backup["ok"] as? Bool, true)
        let exported = URL(fileURLWithPath: try XCTUnwrap(backup["path"] as? String))
        let copy = try DesktopSQLite(url: exported.appendingPathComponent("source-0/bandal.db"), readOnly: true)
        XCTAssertEqual(try copy.query("SELECT value FROM fixture", params: nil).first?["value"] as? String, "in-WAL")
        try Data("newer local text".utf8).write(to: note)
        do { _ = try await service.handle("profile:new"); XCTFail("Stale backup must not qualify") } catch { }
        _ = try await service.handle("profile:backup")
        let created = try await service.handle("profile:new")
        XCTAssertEqual(created["ok"] as? Bool, true)
        let selected = try DesktopProfileService.selectedRoot(in: folder)
        XCTAssertNotEqual(selected, root)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "newer local text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.appendingPathComponent("bandal.db").path))
        XCTAssertNotEqual(DesktopProfileService.legacyRoot(documents: folder, root: selected), folder.appendingPathComponent("Bandal"))
        XCTAssertNotEqual(DesktopProfileService.webStorageID(root: root), DesktopProfileService.webStorageID(root: selected))
    }
    func testCancelledExportDoesNotAuthorizeNewProfile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("BandalDesktop")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: root.appendingPathComponent("keep.md"))
        let service = DesktopProfileService(documents: folder, root: root)
        service.exportDirectory = { _ in nil }
        let result = try await service.handle("profile:backup")
        XCTAssertEqual(result["cancelled"] as? Bool, true)
        do { _ = try await service.handle("profile:new"); XCTFail("Cancelled backup must not qualify") } catch { }
        XCTAssertEqual(try DesktopProfileService.selectedRoot(in: folder).path, root.path)
    }
}
