import XCTest
@testable import Bandal

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    func testPackagedDesktopRuntimeAndIdentity() throws {
        let bundle = Bundle.main
        XCTAssertNotNil(bundle.url(forResource: "index", withExtension: "html", subdirectory: "Desktop"))
        XCTAssertNotNil(bundle.url(forResource: "backend", withExtension: "js", subdirectory: "Desktop"))
        XCTAssertNotNil(bundle.url(forResource: "source-provenance", withExtension: "json", subdirectory: "Desktop"))
        XCTAssertEqual(bundle.infoDictionary?["UIDeviceFamily"] as? [Int], [2])
    }
    func testTwentyMixedTabsRestoreAndPrivateSessionsDoNotPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, seedWelcome: false)
        while model.loading { await Task.yield() }
        model.addCourse("Test course")
        for index in 0..<20 {
            if index % 4 == 0 { model.createNote(title: "Note \(index)", markdown: "Saved \(index)") }
            else if index % 4 == 1 { model.open(.browser, url: URL(string: "about:blank")) }
            else if index % 4 == 2 { model.open(.board) }
            else { model.createWhiteboard() }
        }
        XCTAssertEqual(model.courseTabs.count, 20)
        model.toggleSplit()
        for tab in model.courseTabs where tab.kind == .browser { _ = model.browser(for: tab) }
        model.handleMemoryWarning()
        XCTAssertEqual(model.courseTabs.count, 20)
        XCTAssertLessThanOrEqual(model.browserSessions.count, 2)
        model.open(.browser, url: URL(string: "about:blank"), isPrivate: true)
        await model.flush()
        let restored = AppModel(storageRoot: root, seedWelcome: false)
        while restored.loading { await Task.yield() }
        XCTAssertEqual(restored.courseTabs.count, 20)
        XCTAssertFalse(restored.courseTabs.contains(where: \.isPrivate))
        XCTAssertEqual(restored.notes.count, 5)
        XCTAssertTrue(restored.notes.values.contains("Saved 0"))
    }
    func testUnsafeFileNamesCannotEscapeApplicationStorage() {
        for name in ["../escape.pdf", "/tmp/file.pdf", "..", "", "folder\\file.pdf"] {
            let material = Material(courseID:"c",title:"t",fileName:name,revision:"v",kind:.pdf)
            XCTAssertFalse(material.hasSafePath)
        }
        XCTAssertFalse(RecordingMetadata(id:"not-a-uuid",courseID:"c",title:"t",fileName:"../../escape.wav").hasSafePath)
    }
}
