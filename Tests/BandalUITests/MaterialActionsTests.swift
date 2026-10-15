import XCTest

/// Uses a generated PDF in the reset UI-testing library. These tests present
/// real native export UI but always cancel before sharing or writing a file.
final class MaterialActionsTests: XCTestCase {
    private let fixtureName = "PDF pinch fixture.pdf"

    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: label).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ label: String) {
        let target = element(app, label)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "Missing \(label)\n\(app.debugDescription)")
        XCTAssertTrue(target.isHittable, "Unreachable \(label)\n\(app.debugDescription)")
        target.tap()
    }

    private func launchFixture() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture"]
        app.launch()
        tap(app, "자료 사이드바 펼치기")
        XCTAssertTrue(element(app, "자료 파일 트리").waitForExistence(timeout: 20), app.debugDescription)
        let more = element(app, fixtureName + " 더 보기")
        XCTAssertTrue(more.waitForExistence(timeout: 20), "The generated PDF must have a touch menu\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(more.frame.width, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        assertNoRuntimeFailure(app)
        return app
    }

    private func openAction(_ app: XCUIApplication, _ action: String) {
        tap(app, fixtureName + " 더 보기")
        XCTAssertTrue(element(app, fixtureName + " 메뉴").waitForExistence(timeout: 10), app.debugDescription)
        let target = element(app, action)
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        // The canonical context menu may scroll on a short iPad window.
        if !target.isHittable {
            let menu = element(app, fixtureName + " 메뉴")
            for _ in 0..<3 where !target.isHittable { menu.swipeUp() }
        }
        XCTAssertTrue(target.isHittable, "Unreachable material action \(action)\n\(app.debugDescription)")
        target.tap()
    }

    private func expectDismissed(_ app: XCUIApplication, _ presented: XCUIElement) {
        let dismissed = expectation(for: NSPredicate { _, _ in !presented.exists }, evaluatedWith: app)
        wait(for: [dismissed], timeout: 15)
        XCTAssertTrue(element(app, fixtureName + " 더 보기").isHittable, "Cancellation must return to the same material row\n\(app.debugDescription)")
        assertNoRuntimeFailure(app)
    }

    private func assertNoRuntimeFailure(_ app: XCUIApplication) {
        let failure = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier IN %@ OR label IN %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            ["bandal-operation-notice", "bandal-native-diagnostic"], ["작업 오류", "시작 오류"],
            "반달 실행 연결을 확인해 주세요.", "반달 화면을 열지 못했어요", "작업을 완료하지 못했어요")).firstMatch
        XCTAssertFalse(failure.exists, app.debugDescription)
    }

    func testMaterialMoreOpensMoveDialogAndCancelKeepsOriginalFile() {
        let app = launchFixture()
        // Repeating the canonical action also proves cancel clears its modal
        // owner and does not leave the materials drawer blocked.
        for _ in 0..<2 {
            openAction(app, "이동…")
            let dialog = element(app, "자료 이동")
            XCTAssertTrue(dialog.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts[fixtureName].firstMatch.exists, "The move dialog must name the generated PDF")
            let destination = element(app, "이동할 폴더")
            if destination.exists {
                XCTAssertTrue(destination.isEnabled)
                XCTAssertTrue(element(app, "이동").isEnabled)
            } else {
                XCTAssertTrue(element(app, "이동할 다른 폴더가 없습니다. 자료 목록에서 새 폴더를 만들어 주세요.").exists)
                XCTAssertFalse(element(app, "이동").isEnabled)
            }
            assertNoRuntimeFailure(app)
            tap(app, "취소")
            expectDismissed(app, dialog)
        }
        XCTAssertTrue(element(app, "자료 파일 트리").exists)
    }

    func testMaterialSharePresentsNativeSheetAndCancelReleasesIt() {
        let app = launchFixture()
        for _ in 0..<2 {
            openAction(app, "공유…")
            // UIKit replaces the activity root identifier with ActivityListView
            // on iPadOS 18. Match the observed native container in either form.
            let share = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
                ["bandal-material-share", "ActivityListView"])).firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 20), "The real native share sheet must open\n\(app.debugDescription)")
            let cancel = share.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                ["Close", "닫기", "Cancel", "취소"], ["Close", "닫기", "Cancel", "취소"])).firstMatch
            if cancel.exists && cancel.isHittable { cancel.tap() }
            else {
                // On iPad, UIActivityViewController may be a popover with no
                // cancel button. A touch outside dismisses without selecting
                // an activity or sending the file.
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16, dy: 16)).tap()
            }
            expectDismissed(app, share)
        }
    }

    func testMaterialSaveToFilesPresentsNativePickerAndCancelReleasesIt() {
        let app = launchFixture()
        for _ in 0..<2 {
            openAction(app, "파일에 저장…")
            let picker = element(app, "bandal-document-picker")
            XCTAssertTrue(picker.waitForExistence(timeout: 20), "The real export document picker must open\n\(app.debugDescription)")
            let cancel = picker.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                ["Cancel", "취소"], ["Cancel", "취소"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The native picker must offer cancellation\n\(app.debugDescription)")
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
            expectDismissed(app, picker)
        }
    }
}
