import XCTest
import BandalCore
@testable import Bandal

final class DesktopMaterialFileTests: XCTestCase {
    func testDocumentsContainerAndOpenedFileAliasesUseTheSameAuthorizedRoot() throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("path-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.pdf"), data = Data("fixture".utf8)
        try data.write(to: file)
        let opened = try DesktopMaterialFile(path: file.path, root: root)
        XCTAssertEqual(try opened.read(offset: 0, count: data.count), data)
        XCTAssertEqual(try FileDigestCache().revision(of: file), try AssetHasher.revision(of: file))
    }
    func testHTTPRangeIncludesSuffixAndRejectsInvalidRanges() {
        XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: nil), .init(status: 200, offset: 0, length: 100, contentRange: nil))
        XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: "bytes=0-1"), .init(status: 206, offset: 0, length: 2, contentRange: "bytes 0-1/100"))
        XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: "bytes=-10").offset, 90)
        XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: "bytes=95-").length, 5)
        XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: "bytes=95-999").length, 5)
        for value in ["bytes=100-", "bytes=10-5", "bytes=-0", "bytes=0-1,4-5", "other=1", "bytes=99999999999999999999999-"] {
            XCTAssertEqual(DesktopMaterialFile.selection(size: 100, range: value).status, 416)
        }
    }
    func testLargeSourceReadsOnlyRequestedBytesAndKeepsOpenedInode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("movie.mp4")
        try Data([1, 2, 3, 4]).write(to: path)
        let writer = try FileHandle(forWritingTo: path); try writer.truncate(atOffset: 512 * 1024 * 1024); try writer.close()
        let file = try DesktopMaterialFile(path: path.path, root: root)
        XCTAssertEqual(file.size, 512 * 1024 * 1024)
        XCTAssertEqual(try file.read(offset: 1, count: 2), Data([2, 3]))
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("old.mp4")); try Data([9]).write(to: path)
        XCTAssertEqual(try file.read(offset: 0, count: 1), Data([1]))
        XCTAssertThrowsError(try file.read(offset: 0, count: 256 * 1024 + 1))
        let changed = try FileHandle(forWritingTo: root.appendingPathComponent("old.mp4")); try changed.truncate(atOffset: 3); try changed.close()
        XCTAssertThrowsError(try file.read(offset: 0, count: 1))
    }
    func testSymlinkOutsideAuthorizedRootsIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try DesktopMaterialFile(path: link.path, root: root))
    }
}
