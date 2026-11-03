import XCTest
@testable import Bandal

final class NativeWorkspaceChromeTests: XCTestCase {
    func testLargeWindowKeepsBothPanelsAndReadableEditor() {
        let value = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: true)
        XCTAssertTrue(value.leftPinned); XCTAssertTrue(value.rightPinned)
        XCTAssertEqual(value.rightWidth, 360)
        XCTAssertGreaterThanOrEqual(value.width - 48 - value.leftWidth - value.rightWidth - 2, 480)
    }
    func testMediumWindowPushesBothPanels() {
        let value = NativeWorkspaceChromeLayout(width: 1024, leftOpen: true, rightOpen: true)
        XCTAssertTrue(value.leftPinned); XCTAssertTrue(value.rightPinned)
    }
    func testPortraitPushesOnePanelAndSplitViewFallsBackToDrawer() {
        XCTAssertTrue(NativeWorkspaceChromeLayout(width: 834, leftOpen: true, rightOpen: false).leftPinned)
        XCTAssertTrue(NativeWorkspaceChromeLayout(width: 834, leftOpen: false, rightOpen: true).rightPinned)
        let both = NativeWorkspaceChromeLayout(width: 834, leftOpen: true, rightOpen: true)
        XCTAssertFalse(both.leftPinned); XCTAssertTrue(both.rightPinned)
        let split = NativeWorkspaceChromeLayout(width: 507, leftOpen: true, rightOpen: true)
        XCTAssertFalse(split.leftPinned); XCTAssertFalse(split.rightPinned)
        XCTAssertEqual(split.compactRightWidth, 507)
    }
    func testResizedPanelsCannotConsumeDocumentMinimumWidth() {
        for width in [700.0, 834, 900, 1024, 1199, 1200, 1366] {
            let value = NativeWorkspaceChromeLayout(width: width, leftOpen: true, rightOpen: true, leftRequested: 400, rightRequested: 520)
            let separators = (value.leftPinned ? 1.0 : 0) + (value.rightPinned ? 1.0 : 0)
            XCTAssertGreaterThanOrEqual(width - 48 - value.leftWidth - value.rightWidth - separators, NativeWorkspaceChromeLayout.editorMinimum, "width \(width)")
        }
    }
    func testCoveredWorkspaceReservesNoPanelWidth() {
        let value = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: true, showsWorkspace: false)
        XCTAssertFalse(value.leftPinned); XCTAssertFalse(value.rightPinned)
        XCTAssertEqual(value.leftWidth + value.rightWidth, 0)
    }
    func testAIRailTakesPriorityAndKeepsEditorMinimum() {
        let large = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: true, aiOpen: true)
        XCTAssertTrue(large.aiPinned); XCTAssertTrue(large.rightPinned); XCTAssertTrue(large.leftPinned, "13-inch landscape fits all three at minimum widths")
        let eleven = NativeWorkspaceChromeLayout(width: 1210, leftOpen: true, rightOpen: true, aiOpen: true)
        XCTAssertTrue(eleven.aiPinned); XCTAssertTrue(eleven.rightPinned); XCTAssertFalse(eleven.leftPinned,
            "Restored state with every rail open keeps AI and materials; the view closes rails when one opens")
        let courseAndAI = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: false, aiOpen: true)
        XCTAssertTrue(courseAndAI.leftPinned); XCTAssertTrue(courseAndAI.aiPinned); XCTAssertEqual(courseAndAI.aiWidth, 340)
        let portrait = NativeWorkspaceChromeLayout(width: 834, leftOpen: true, rightOpen: true, aiOpen: true)
        XCTAssertTrue(portrait.aiPinned); XCTAssertFalse(portrait.leftPinned); XCTAssertFalse(portrait.rightPinned)
        XCTAssertFalse(NativeWorkspaceChromeLayout(width: 700, leftOpen: false, rightOpen: false, aiOpen: true).aiPinned)
        for width in [790.0, 1024, 1194, 1366, 1600] {
            let value = NativeWorkspaceChromeLayout(width: width, leftOpen: true, rightOpen: true, aiOpen: true, leftRequested: 400, rightRequested: 520, aiRequested: 520)
            let columns = [value.leftPinned, value.aiPinned, value.rightPinned].filter { $0 }.count
            XCTAssertGreaterThanOrEqual(width - 48 - value.leftWidth - value.aiWidth - value.rightWidth - Double(columns), NativeWorkspaceChromeLayout.editorMinimum, "width \(width)")
        }
    }
}
