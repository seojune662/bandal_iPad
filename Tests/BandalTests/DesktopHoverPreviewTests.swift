import XCTest
import CryptoKit
@testable import Bandal

final class DesktopHoverPreviewTests: XCTestCase {
    private let word = "UEsDBAoAAAAAAA1/TV0AAAAAAAAAAAAAAAAFAAAAd29yZC9QSwMECgAAAAgADX9NXSLEIq8/AAAAUgAAABEAAAB3b3JkL2RvY3VtZW50LnhtbLMpt0rJTy7NTc0rsbMptyoAEUUgosTuzdSWN3O3vO1Z8XryHIU3sye83rxDITy/KMVGHyQLIovAZAGYhJsCAFBLAQIUAAoAAAAAAA1/TV0AAAAAAAAAAAAAAAAFAAAAAAAAAAAAEAAAAAAAAAB3b3JkL1BLAQIUAAoAAAAIAA1/TV0ixCKvPwAAAFIAAAARAAAAAAAAAAAAAAAAACMAAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAgACAHIAAACRAAAAAAA="
    private let slides = "UEsDBAoAAAAAADx/TV0AAAAAAAAAAAAAAAAEAAAAcHB0L1BLAwQKAAAACAA8f01dSHhJGDIAAABOAAAAFAAAAHBwdC9wcmVzZW50YXRpb24ueG1ssymwKihKLU7NK0ksyczPs7MpsCrOSfFM8SkugbMViqwyU2yVigyV9O1s9JEV6KPpBgBQSwMECgAAAAAAPH9NXQAAAAAAAAAAAAAAAAoAAABwcHQvX3JlbHMvUEsDBAoAAAAIADx/TV17DcVoOQAAAFEAAAAfAAAAcHB0L19yZWxzL3ByZXNlbnRhdGlvbi54bWwucmVsc7MJSs1JLMnMzyvOyCwotrNB5ip4ptgqFRkqKYQkFqWnltgqFedkpqQW64MpQ72K3BwlfTsbfVQTAFBLAwQKAAAAAAA8f01dAAAAAAAAAAAAAAAACwAAAHBwdC9zbGlkZXMvUEsDBAoAAAAIADx/TV1sYEAkLwAAADUAAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTEueG1ss0m0KrCzSbQqAhEldq92bHizcIvC680Nb2fOUHi9Yc7biXNs9EEyILIITBbYAQBQSwECFAAKAAAAAAA8f01dAAAAAAAAAAAAAAAABAAAAAAAAAAAABAAAAAAAAAAcHB0L1BLAQIUAAoAAAAIADx/TV1IeEkYMgAAAE4AAAAUAAAAAAAAAAAAAAAAACIAAABwcHQvcHJlc2VudGF0aW9uLnhtbFBLAQIUAAoAAAAAADx/TV0AAAAAAAAAAAAAAAAKAAAAAAAAAAAAEAAAAIYAAABwcHQvX3JlbHMvUEsBAhQACgAAAAgAPH9NXXsNxWg5AAAAUQAAAB8AAAAAAAAAAAAAAAAArgAAAHBwdC9fcmVscy9wcmVzZW50YXRpb24ueG1sLnJlbHNQSwECFAAKAAAAAAA8f01dAAAAAAAAAAAAAAAACwAAAAAAAAAAABAAAAAkAQAAcHB0L3NsaWRlcy9QSwECFAAKAAAACAA8f01dbGBAJC8AAAA1AAAAFQAAAAAAAAAAAAAAAABNAQAAcHB0L3NsaWRlcy9zbGlkZTEueG1sUEsFBgAAAAAGAAYAdQEAAK8BAAAAAA=="

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor
    private func extract(_ service: DesktopHoverPreviewService, path: URL, worker: String) async throws -> [String: Any] {
        let value = try await service.handle(channel: "native:hoverExtract", request: ["workerID": worker, "input": ["absolutePath": path.path, "extension": "." + path.pathExtension]])
        return try XCTUnwrap(value as? [String: Any])
    }
    @MainActor
    func testActualWorkerParsesWordCSVAndExistingPPTCache() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = DesktopHoverPreviewService(root: root), worker = UUID().uuidString
        let docx = root.appendingPathComponent("원본.docx"); try XCTUnwrap(Data(base64Encoded: word)).write(to: docx)
        let result = try await extract(service, path: docx, worker: worker)
        XCTAssertEqual(result["kind"] as? String, "text"); XCTAssertEqual(result["text"] as? String, "아이패드 원본 Word")
        let csv = root.appendingPathComponent("표.csv"); try Data("이름,값\n한글,12".utf8).write(to: csv)
        let table = try await extract(service, path: csv, worker: worker)
        XCTAssertEqual(table["rows"] as? [[String]], [["이름", "값"], ["한글", "12"]])
        let ppt = root.appendingPathComponent("발표.ppt"), source = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]); try source.write(to: ppt)
        let missing = try await extract(service, path: ppt, worker: worker)
        XCTAssertEqual(missing["reason"] as? String, "needs-conversion")
        let cache = root.appendingPathComponent("ConvertedPresentations"); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        try XCTUnwrap(Data(base64Encoded: slides)).write(to: cache.appendingPathComponent(hash + ".pptx"))
        let presentation = try await extract(service, path: ppt, worker: worker)
        XCTAssertEqual(presentation["kind"] as? String, "slides"); XCTAssertEqual(presentation["text"] as? String, "기존 변환 발표")
        _ = try await service.handle(channel: "native:hoverTerminate", request: ["workerID": worker])
    }
    @MainActor
    func testHungWorkerTerminatesAndSnapshotRejectsUnapprovedFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("hang.docx"); try Data([1]).write(to: path)
        let service = DesktopHoverPreviewService(root: root, script: { "onmessage=()=>{while(true){}}" }), worker = UUID().uuidString
        let pending = Task { try await self.extract(service, path: path, worker: worker) }
        try await Task.sleep(for: .milliseconds(400))
        _ = try await service.handle(channel: "native:hoverTerminate", request: ["workerID": worker])
        do { _ = try await pending.value; XCTFail("Cancelled parser cannot return content") } catch { }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID()).docx")
        try Data([1]).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link.docx"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try await extract(service, path: link, worker: UUID().uuidString); XCTFail("Parser cannot read unapproved symlink") } catch { }
    }
}
