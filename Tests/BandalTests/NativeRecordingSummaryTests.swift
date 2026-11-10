import XCTest
@testable import Bandal

final class NativeRecordingSummaryTests: XCTestCase {
    @MainActor func testTranscriptJoinsSpokenLinesAndSkipsEmptyOnes() {
        let detail: [String: Any] = ["segments": [["id": 1, "text": " 첫 문장 "], ["id": 2, "text": ""], ["id": 3, "text": "둘째 문장"], ["id": 4]]]
        XCTAssertEqual(NativePDFWorkspaceModel.transcript(detail), "첫 문장\n둘째 문장")
        XCTAssertEqual(NativePDFWorkspaceModel.transcript([:]), "", "Nothing heard: nothing to summarize")
    }
    @MainActor func testTranscriptIsCappedAtTheAttachmentLimit() {
        let detail: [String: Any] = ["segments": [["text": String(repeating: "가", count: 90_000)]]]
        XCTAssertEqual(NativePDFWorkspaceModel.transcript(detail).count, 80_000)
    }
}
