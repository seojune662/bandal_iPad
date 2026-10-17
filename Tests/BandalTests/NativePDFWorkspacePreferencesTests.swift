import XCTest
@testable import Bandal

final class NativePDFWorkspacePreferencesTests: XCTestCase {
    @MainActor
    func testDocumentSwitchRestoresIndependentToolStylesAndPanelState() {
        let suite = "NativePDFWorkspacePreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NativeWorkspaceStore(storageRoot: root)
        let a = NativeDocumentReference(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf")
        let b = NativeDocumentReference(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf")
        let first = NativePDFWorkspaceModel(document: a, store: store, defaults: defaults)
        first.chooseColor("red"); first.setWidth(0.012); first.setOpacity(0.4)
        first.chooseTool("highlighter"); first.chooseColor("green")
        first.toggleAnnotations()
        let second = NativePDFWorkspaceModel(document: b, store: store, defaults: defaults)
        second.chooseColor("blue"); second.chooseTool("eraser")
        let reopened = NativePDFWorkspaceModel(document: a, store: store, defaults: defaults)
        XCTAssertEqual(reopened.tool, "highlighter"); XCTAssertEqual(reopened.color, "green")
        XCTAssertEqual(reopened.width, 0.006); XCTAssertEqual(reopened.opacity, 0.28)
        XCTAssertTrue(reopened.showAnnotations)
        reopened.chooseTool("pen"); XCTAssertEqual(reopened.color, "red")
        XCTAssertEqual(reopened.width, 0.012); XCTAssertEqual(reopened.opacity, 0.4)
        reopened.chooseTool("highlighter"); XCTAssertEqual(reopened.color, "green")
        let reopenedB = NativePDFWorkspaceModel(document: b, store: store, defaults: defaults)
        XCTAssertEqual(reopenedB.tool, "eraser")
        reopenedB.chooseTool("pen"); XCTAssertEqual(reopenedB.color, "blue")
        let isolated = NativeWorkspaceStore(storageRoot: root.appendingPathComponent("other-workspace"))
        XCTAssertEqual(NativePDFWorkspaceModel(document: a, store: isolated, defaults: defaults).color, "ink")
    }
    @MainActor
    func testDuplicateCopiesPresentationOnceThenKeepsItsOwnToolAndViewport() throws {
        let suite = "NativePDFDuplicatePreferences.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NativeWorkspaceStore(storageRoot: root)
        let original = NativeDocumentReference(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf")
        var duplicate = original; duplicate.instanceID = UUID().uuidString
        let a = NativePDFWorkspaceModel(document: original, store: store, defaults: defaults)
        a.chooseTool("highlighter"); a.chooseColor("green")
        store.documentDuplicateSourceIDs[duplicate.id] = original.id
        let b = NativePDFWorkspaceModel(document: duplicate, store: store, defaults: defaults)
        XCTAssertEqual(b.tool, "highlighter"); XCTAssertEqual(b.color, "green")
        b.chooseTool("pen"); b.chooseColor("blue")
        let reopened = NativePDFWorkspaceModel(document: duplicate, store: store, defaults: defaults)
        XCTAssertEqual(reopened.tool, "pen"); XCTAssertEqual(reopened.color, "blue")
        XCTAssertEqual(a.tool, "highlighter"); XCTAssertEqual(a.color, "green")
        let saved = try XCTUnwrap(NativePDFWorkspacePreferences.Viewport(revision: "a", values: ["page": 2, "zoom": 1.4, "progress": 0.8, "horizontalProgress": 0.3]))
        let restored = saved.restoring(["page": 1, "zoom": 1.0], revision: "a", independent: true)
        XCTAssertEqual(restored["page"] as? Int, 2); XCTAssertEqual(restored["zoom"] as? Double, 1.4)
        XCTAssertEqual(restored["progress"] as? Double, 0.8)
        XCTAssertEqual(saved.restoring(["page": 1, "zoom": 1.0], revision: "replaced", independent: true)["page"] as? Int, 1)
    }
    func testHighlighterMatchesDesktopOpacityAndInvalidPresentationValuesCannotReachInk() {
        var settings = NativePDFWorkspacePreferences()
        settings.tool = "highlighter"; settings.opacity = 0.1; settings.width = 0.005
        XCTAssertEqual(settings.drawingStyle["opacity"] as? Double, 0.1)
        XCTAssertEqual(settings.drawingStyle["width"] as? Double, 0.02)
        settings.opacity = 0.9; XCTAssertEqual(settings.drawingStyle["opacity"] as? Double, 0.34)
        settings.tool = "unknown"; settings.color = "not-a-color"; settings.width = .nan; settings.opacity = .infinity
        let valid = settings.validated()
        XCTAssertEqual(valid.tool, "pen"); XCTAssertEqual(valid.color, "ink")
        XCTAssertEqual(valid.width, 0.004); XCTAssertEqual(valid.opacity, 0.95)
    }
    func testExactScrollRestoreRequiresMatchingRevisionAndCanonicalViewState() throws {
        let saved = try XCTUnwrap(NativePDFWorkspacePreferences.Viewport(revision: "revision-a", values: [
            "page": 3, "zoom": 1.75, "progress": 0.72, "horizontalProgress": 0.41]))
        let canonical: [String: Any] = ["page": 3, "zoom": 1.75]
        let restored = saved.restoring(canonical, revision: "revision-a")
        XCTAssertEqual(restored["progress"] as? Double, 0.72)
        XCTAssertEqual(restored["horizontalProgress"] as? Double, 0.41)
        XCTAssertNil(saved.restoring(canonical, revision: "revision-b")["progress"])
        XCTAssertNil(saved.restoring(["page": 2, "zoom": 1.75], revision: "revision-a")["progress"])
        XCTAssertNil(saved.restoring(["page": 3, "zoom": 1.5], revision: "revision-a")["progress"])
    }
}
