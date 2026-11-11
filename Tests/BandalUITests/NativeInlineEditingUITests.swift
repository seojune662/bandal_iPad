import XCTest

/// 1.4.0 UX: renames happen in place (Enter commits, Esc cancels) and confirmations are anchored popovers.
final class NativeInlineEditingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testCourseRenameInPlaceAndArchiveFromAnchoredConfirm() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra")
        app.buttons["native-create-course"].tap()

        // Esc is checked on a device (docs/release/app-review-1.4.0.md §5): the simulator's synthesized
        // Esc does not reach a first responder while the software keyboard is up.
        // Enter commits, in place: no alert or sheet.
        rename(app, from: "Linear Algebra", typing: "Calculus", submit: "\n")
        XCTAssertTrue(app.buttons["Calculus 과목 메뉴"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        app.buttons["Calculus 과목 메뉴"].firstMatch.tap()
        XCTAssertTrue(app.buttons["과목 보관"].firstMatch.waitForExistence(timeout: 5)); app.buttons["과목 보관"].firstMatch.tap()
        let confirm = app.buttons["bandal-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Anchored popover, not an action sheet")
        confirm.tap()
        XCTAssertTrue(waitForAbsence(app.buttons["Calculus 과목 메뉴"]), app.debugDescription)
    }

    @MainActor private func rename(_ app: XCUIApplication, from old: String, typing name: String, submit: String) {
        let menu = app.buttons[old + " 과목 메뉴"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        let item = app.buttons["이름 변경"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
        let field = app.textFields["native-course-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
        field.typeText(submit)
        XCTAssertTrue(waitForAbsence(field), "The field closes: \(app.debugDescription)")
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }
}
