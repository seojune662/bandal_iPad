import XCTest
@testable import Bandal

@MainActor
final class DesktopFileStagingTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func begin(_ service: DesktopFileStaging, name: String = "자료.pdf", size: Int) throws -> String {
        (try service.handle("runtime:stageFileBegin", ["name": name, "size": size]) as! [String: Any])["id"] as! String
    }
    private func write(_ service: DesktopFileStaging, _ id: String, offset: Int, data: Data) throws {
        let result = try service.handle("runtime:stageFileWrite", ["id": id, "offset": offset, "data": data.base64EncodedString()]) as! [String: Any]
        XCTAssertEqual((result["offset"] as? NSNumber)?.intValue, offset + data.count)
    }
    private func finish(_ service: DesktopFileStaging, _ id: String) throws -> String {
        (try service.handle("runtime:stageFileFinish", ["id": id]) as! [String: Any])["path"] as! String
    }
    func testLargeFileBoundedWritesAndCancelWaitsForConsumer() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var maximum = 0
        let service = DesktopFileStaging(root: root, writeChunk: { handle, data in maximum = max(maximum, data.count); try handle.write(contentsOf: data) })
        let chunk = Data(repeating: 71, count: DesktopFileStaging.chunkBytes), size = chunk.count * 64 + 3
        let id = try begin(service, size: size)
        for offset in stride(from: 0, to: size - 3, by: chunk.count) { try write(service, id, offset: offset, data: chunk) }
        try write(service, id, offset: size - 3, data: Data([1, 2, 3]))
        let path = try finish(service, id)
        XCTAssertEqual(maximum, 256 * 1024)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, size)
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); try file.seek(toOffset: UInt64(size - 3))
        XCTAssertEqual(try file.read(upToCount: 3), Data([1, 2, 3])); try file.close()
        let lease = service.beginConsumption(paths: [path]); XCTAssertEqual(lease.count, 1)
        _ = try service.handle("runtime:stageFileCancel", ["id": id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "A replay cancellation must not delete a source while the repository is reading it")
        service.endConsumption(lease, successfulPaths: [path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testInvalidOffsetOversizedChunkAndIncompleteFinishRemoveOnlyOwnedPartial() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = DesktopFileStaging(root: root), original = root.appendingPathComponent("original.pdf")
        try Data([9]).write(to: original)
        let wrong = try begin(service, size: 4)
        XCTAssertThrowsError(try write(service, wrong, offset: 1, data: Data([1])))
        let huge = try begin(service, size: DesktopFileStaging.chunkBytes + 1)
        XCTAssertThrowsError(try write(service, huge, offset: 0, data: Data(repeating: 1, count: DesktopFileStaging.chunkBytes + 1)))
        let short = try begin(service, size: 10)
        try write(service, short, offset: 0, data: Data([1]))
        XCTAssertThrowsError(try finish(service, short))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Temporary/Imports").path), [])
        XCTAssertEqual(try Data(contentsOf: original), Data([9]))
        XCTAssertThrowsError(try begin(service, name: "../original.pdf", size: 0))
    }
    func testDiskFullWriteRemovesPartialAndNeverPublishesPath() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = DesktopFileStaging(root: root, writeChunk: { _, _ in throw POSIXError(.ENOSPC) })
        let id = try begin(service, size: 1)
        XCTAssertThrowsError(try write(service, id, offset: 0, data: Data([1]))) { XCTAssertEqual(($0 as? POSIXError)?.code, .ENOSPC) }
        XCTAssertThrowsError(try finish(service, id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Temporary/Imports").path), [])
    }
    func testFailedImportRetainsRetryAndSuccessfulCopyPreservesOriginal() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"); try Data([4, 5]).write(to: source)
        let service = DesktopFileStaging(root: root), staged = try service.copy(source)
        let failed = service.beginConsumption(paths: [source.path, staged.path]); XCTAssertEqual(failed.count, 1)
        service.endConsumption(failed, successfulPaths: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        service.discard(paths: [source.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let succeeded = service.beginConsumption(paths: [staged.path])
        service.endConsumption(succeeded, successfulPaths: [staged.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path)); XCTAssertEqual(try Data(contentsOf: source), Data([4, 5]))
    }
    func testReplacedPathIsNoLongerOwnedAndEmptyFileFinishes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = DesktopFileStaging(root: root), id = try begin(service, size: 0), path = try finish(service, id)
        try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
        try Data([8]).write(to: URL(fileURLWithPath: path))
        _ = try service.handle("runtime:stageFileCancel", ["id": id])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([8]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".old"))
    }
    func testNativeCopyOver64MiBAndRendererTerminationPreservesReadyFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large-video.mp4")
        try Data([1]).write(to: source)
        let writer = try FileHandle(forWritingTo: source); try writer.truncate(atOffset: 70 * 1024 * 1024); try writer.close()
        let service = DesktopFileStaging(root: root), copy = try service.copy(source)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.intValue, 70 * 1024 * 1024)
        let partial = try begin(service, size: 100)
        try write(service, partial, offset: 0, data: Data([2]))
        service.cancelUnfinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertThrowsError(try finish(service, partial))
        service.discard(paths: [copy.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
