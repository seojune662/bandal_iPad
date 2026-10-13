import XCTest
@testable import Bandal

final class DesktopRecordingCheckpointTests: XCTestCase {
    @MainActor
    func testTranscriptWindowAndCursorCommitAtomicallyAndReplayWithoutDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let courseValue = try await runtime.invoke("courses:create", request: ["name": "전사 원자성", "color": "#60a5fa"])
        let courseID = try XCTUnwrap((courseValue as? [String: Any])?["id"] as? String)
        let created = try await runtime.invokePrivate("nativeRecording:create", request: ["courseId": courseID, "title": "checkpoint", "modelId": "zipformer-ko"])
        let id = try XCTUnwrap((created as? [String: Any])?["id"] as? String)
        _ = try await runtime.invokePrivate("nativeRecording:status", request: ["id": id, "status": "recording"])
        _ = try await runtime.invokePrivate("nativeRecording:append", request: ["id": id, "sequence": 0, "pcm": ["__bandalBytes": Data(repeating: 0, count: 32000).base64EncodedString()]])
        _ = try await runtime.invokePrivate("nativeRecording:status", request: ["id": id, "status": "interrupted", "error": "Earlier temporary failure"])
        let first: [String: Any] = ["id": id, "startSample": 0, "endSample": 8000, "text": "처리된 첫 구간"]
        let committed = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow", request: first) as? [String: Any]
        let session = try XCTUnwrap(committed?["session"] as? [String: Any])
        XCTAssertEqual(session["transcribedSamples"] as? Int, 8000)
        XCTAssertTrue(session["error"] == nil || session["error"] is NSNull)
        XCTAssertNotNil(committed?["segment"])
        let repeated = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow", request: first) as? [String: Any]
        XCTAssertNil(repeated?["segment"], "Retry after a lost IPC acknowledgment must not create a second segment")
        for range in [(0, 12000), (9000, 12000), (8000, 20000)] {
            do {
                _ = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow", request: ["id": id, "startSample": range.0, "endSample": range.1, "text": "Must not be saved"])
                XCTFail("Overlapping, gapped, and out-of-audio windows must fail")
            } catch {}
        }
        let detail = try await runtime.invoke("recordings:read", request: ["id": id]) as? [String: Any]
        XCTAssertEqual((detail?["segments"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((detail?["segments"] as? [[String: Any]])?.first?["text"] as? String, "처리된 첫 구간")
        let empty = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow", request: ["id": id, "startSample": 8000, "endSample": 16000, "text": "  "]) as? [String: Any]
        XCTAssertNil(empty?["segment"])
        XCTAssertEqual((empty?["session"] as? [String: Any])?["transcribedSamples"] as? Int, 16000, "Silent audio still advances the durable checkpoint")
    }
}
