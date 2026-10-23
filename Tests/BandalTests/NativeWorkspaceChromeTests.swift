import XCTest
@testable import Bandal

final class NativeWorkspaceChromeTests: XCTestCase {
    func testLargeWindowKeepsBothPanelsAndReadableEditor() {
        let value = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: true)
        XCTAssertTrue(value.leftPinned); XCTAssertTrue(value.rightPinned)
        XCTAssertEqual(value.rightWidth, 360)
        XCTAssertGreaterThanOrEqual(value.width - 48 - value.leftWidth - value.rightWidth - 2, 480)
    }
    func testMediumWindowUsesOnlyPinnedInspector() {
        let value = NativeWorkspaceChromeLayout(width: 1024, leftOpen: true, rightOpen: true)
        XCTAssertFalse(value.leftPinned); XCTAssertTrue(value.rightPinned)
        XCTAssertEqual(value.leftWidth, 0)
    }
    func testPortraitAndSplitViewUseDrawerAndFullWidthRespectively() {
        let portrait = NativeWorkspaceChromeLayout(width: 834, leftOpen: true, rightOpen: true)
        XCTAssertFalse(portrait.leftPinned); XCTAssertFalse(portrait.rightPinned)
        XCTAssertEqual(portrait.compactRightWidth, 360)
        let split = NativeWorkspaceChromeLayout(width: 507, leftOpen: true, rightOpen: true)
        XCTAssertEqual(split.compactRightWidth, 507)
    }
    func testResizedPanelsCannotConsumeDocumentMinimumWidth() {
        for width in [900.0, 1024, 1199, 1200, 1366] {
            let value = NativeWorkspaceChromeLayout(width: width, leftOpen: true, rightOpen: true, leftRequested: 400, rightRequested: 520)
            let separators = (value.leftPinned ? 1.0 : 0) + (value.rightPinned ? 1.0 : 0)
            XCTAssertGreaterThanOrEqual(width - 48 - value.leftWidth - value.rightWidth - separators, 480, "width \(width)")
        }
    }
    func testCoveredWorkspaceReservesNoPanelWidth() {
        let value = NativeWorkspaceChromeLayout(width: 1366, leftOpen: true, rightOpen: true, showsWorkspace: false)
        XCTAssertFalse(value.leftPinned); XCTAssertFalse(value.rightPinned)
        XCTAssertEqual(value.leftWidth + value.rightWidth, 0)
    }
}
