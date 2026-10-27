import XCTest
@testable import Bandal

@MainActor
final class NativePanelViewStateTests: XCTestCase {
    func testSameResourceInstancesRestoreIndependentMediaBoardAndLearningState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativePanelViewStateStore(root: root)
        let original = NativeDocumentReference(courseID: "course", relativePath: "lecture.wav", title: "Lecture", kind: "audio")
        let duplicate = original.duplicated()
        try store.write(NativeMediaPanelState(position: 12, rate: 1.25), id: original.id, kind: "media")
        try store.write(NativeMediaPanelState(position: 43, rate: 1.75), id: duplicate.id, kind: "media")
        try store.write(NativeWhiteboardPanelState(page: 3, zoom: 1.4, offsetX: 12, offsetY: 90), id: original.id, kind: "whiteboard")
        try store.write(NativeLearningPanelScrollState(offset: 240), id: original.id, kind: "learning")
        let restarted = NativePanelViewStateStore(root: root)
        XCTAssertEqual(restarted.read(NativeMediaPanelState.self, id: original.id, kind: "media"), .init(position: 12, rate: 1.25))
        XCTAssertEqual(restarted.read(NativeMediaPanelState.self, id: duplicate.id, kind: "media"), .init(position: 43, rate: 1.75))
        XCTAssertEqual(restarted.read(NativeWhiteboardPanelState.self, id: original.id, kind: "whiteboard")?.page, 3)
        XCTAssertEqual(restarted.read(NativeLearningPanelScrollState.self, id: original.id, kind: "learning")?.offset, 240)
        let otherProfile = NativePanelViewStateStore(root: root.appendingPathComponent("OtherProfile"))
        XCTAssertNil(otherProfile.read(NativeMediaPanelState.self, id: original.id, kind: "media"))
    }
}
