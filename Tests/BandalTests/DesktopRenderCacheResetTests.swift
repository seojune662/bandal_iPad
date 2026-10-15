import XCTest
@testable import Bandal

final class DesktopRenderCacheResetTests: XCTestCase {
    func testResetRemovesOnlyDerivedPDFCopiesAndIsRepeatable() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cache-reset-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let durable = ["bandal.db", "bandal.db-wal", "PDFOriginals/source.pdf",
            "Courses/course/document.pdf", "PendingNativePDFInk/stroke.json",
            "DesktopBrowser/profiles.json", "CommonSync/journal.json",
            "Temporary/Imports/pending.pdf", "SyncRecovery/retry.json", "Home/settings.json"]
        for path in durable + ["NativePDFCache/revision.pdf"] {
            let file = root.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        XCTAssertTrue(try DesktopRenderCacheReset.removePDFCopies(root: root))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("NativePDFCache").path))
        for path in durable { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(path.utf8), path) }
        XCTAssertFalse(try DesktopRenderCacheReset.removePDFCopies(root: root))
    }

    func testCacheSymlinkDoesNotDeleteItsOriginalsTarget() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cache-reset-link-\(UUID())")
        let originals = root.appendingPathComponent("PDFOriginals")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        let file = originals.appendingPathComponent("original.pdf"), data = Data("original".utf8)
        try data.write(to: file)
        try manager.createSymbolicLink(at: root.appendingPathComponent("NativePDFCache"), withDestinationURL: originals)
        XCTAssertTrue(try DesktopRenderCacheReset.removePDFCopies(root: root))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
