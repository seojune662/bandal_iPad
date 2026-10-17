import XCTest

/// Real UIKit editors and native drag sessions exercise flush, layout restoration
/// and stable editor identity across tab moves. No web docking fixture is used.
final class NativeDockingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNestedDockingDragResizeMergeAndRestorePreserveAllNotes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 20)); addCourse.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Docking Course")
        app.buttons["native-create-course"].tap()
        let leftRail = app.otherElements["native-course-rail-resizer"]
        let rightRail = app.otherElements["native-materials-rail-resizer"]
        XCTAssertTrue(leftRail.waitForExistence(timeout: 10)); XCTAssertTrue(rightRail.exists)
        XCTAssertGreaterThanOrEqual(leftRail.frame.width, 44)
        leftRail.doubleTap(); rightRail.doubleTap()
        let leftX = leftRail.frame.midX, rightX = rightRail.frame.midX
        let leftStart = leftRail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        leftStart.press(forDuration: 0.1, thenDragTo: leftStart.withOffset(CGVector(dx: 32, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let rightStart = rightRail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        rightStart.press(forDuration: 0.1, thenDragTo: rightStart.withOffset(CGVector(dx: -32, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertGreaterThan(leftRail.frame.midX, leftX + 15)
        XCTAssertLessThan(rightRail.frame.midX, rightX - 15)
        // Restore the default rails before verifying four panes, including on
        // the 11-inch iPad where expanded rails correctly trigger focus mode.
        leftRail.doubleTap(); rightRail.doubleTap()
        XCTAssertEqual(leftRail.frame.midX, leftX, accuracy: 1)
        XCTAssertEqual(rightRail.frame.midX, rightX, accuracy: 1)
        for title in ["Alpha", "Beta", "Gamma", "Delta"] { createNote(title, app: app) }
        chooseLayout("grid", app: app)
        expectEditorCount(4, app: app)
        for title in ["Alpha", "Beta", "Gamma", "Delta"] { XCTAssertTrue(editor(title, app: app).exists, app.debugDescription) }
        let originalText = Dictionary(uniqueKeysWithValues: ["Alpha", "Beta", "Gamma", "Delta"].map { ($0, editor($0, app: app).value as? String ?? "") })
        capture("Native four pane document docking")

        let alphaTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Alpha")).firstMatch
        let draggedDocumentID = String(alphaTab.identifier.dropFirst("native-document-tab-".count))
        let betaEditor = editor("Beta", app: app)
        let destination = betaEditor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let windowBeforeDrag = app.windows.firstMatch.frame
        alphaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.5)
        let windowAfterDrag = app.windows.firstMatch.frame
        XCTAssertEqual(windowAfterDrag.minX, windowBeforeDrag.minX, accuracy: 1, "Dragging a tab must not move the iPad window")
        XCTAssertEqual(windowAfterDrag.minY, windowBeforeDrag.minY, accuracy: 1, "Dragging a tab must not move the iPad window")
        XCTAssertEqual(windowAfterDrag.width, windowBeforeDrag.width, accuracy: 1, "Dragging a tab must not resize the iPad window")
        XCTAssertEqual(windowAfterDrag.height, windowBeforeDrag.height, accuracy: 1, "Dragging a tab must not resize the iPad window")
        expectEditorCount(3, app: app)
        XCTAssertTrue(editor("Alpha", app: app).exists)
        let emptyClose = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-close-empty-")).firstMatch
        XCTAssertTrue(emptyClose.waitForExistence(timeout: 10), app.debugDescription); emptyClose.tap()
        let divider = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-divider-")).firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThanOrEqual(min(divider.frame.width, divider.frame.height), 44)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        capture("Native tab moved across groups and resized")
        chooseLayout("grid", app: app)
        expectEditorCount(4, app: app)
        for (title, original) in originalText {
            let current = editor(title, app: app).value as? String ?? ""
            XCTAssertEqual(current, original, "A tab drop must not paste its identifier into \(title)")
            XCTAssertFalse(current.contains(draggedDocumentID))
        }
        app.terminate()
        app.launchArguments = ["--native-ui-testing"]; app.launch()
        expectEditorCount(4, app: app, timeout: 25)
        for (title, original) in originalText {
            XCTAssertTrue(editor(title, app: app).exists, app.debugDescription)
            XCTAssertEqual(editor(title, app: app).value as? String, original, "Tab dragging must preserve the entire saved note through restart")
        }
        capture("Native split tree restored after restart")

        // Nest another column inside a cell: when it cannot meet minimum touch
        // sizes, the selector keeps the focused and all other panes reachable.
        app.buttons["native-open-documents"].tap()
        app.buttons["native-dock-split-right"].tap()
        let selector = app.buttons["native-dock-pane-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10), app.debugDescription)
        selector.tap()
        app.buttons["native-dock-select-group-0"].tap()
        XCTAssertTrue(app.buttons["native-open-documents"].waitForExistence(timeout: 5))
        capture("Native compact pane selector")
        chooseLayout("single", app: app)
        expectEditorCount(1, app: app)
        for title in ["Alpha", "Beta", "Gamma", "Delta"] {
            let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", title)).firstMatch
            if tab.exists && tab.isHittable { tab.tap() }
            else {
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tabs-")).firstMatch.tap()
                let choice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-dock-tab-list-select-", title)).firstMatch
                XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
            }
            XCTAssertTrue(editor(title, app: app).waitForExistence(timeout: 10), app.debugDescription)
        }
    }
    @MainActor private func createNote(_ title: String, app: XCUIApplication) {
        let add = app.buttons["native-library-create"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["새 마크다운"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["만들기"].tap()
        let note = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15)); note.tap(); note.typeText("\nKeep \(title) across docking.")
        app.dismissNativeTestKeyboard()
    }
    @MainActor private func editor(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "native-markdown-editor", "Keep \(title) across docking.")).firstMatch
    }
    @MainActor private func chooseLayout(_ preset: String, app: XCUIApplication) {
        let menu = app.buttons["native-open-documents"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let choice = app.buttons["native-dock-preset-" + preset]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription); choice.tap()
    }
    @MainActor private func expectEditorCount(_ count: Int, app: XCUIApplication, timeout: TimeInterval = 15) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.textViews.matching(identifier: "native-markdown-editor").allElementsBoundByIndex.filter { !$0.frame.isEmpty && $0.frame.intersects(app.frame) }.count == count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}


extension XCUIApplication {
    /// The device's AssistiveTouch button can overlap the accessory Done action.
    /// Prefer the system keyboard's visible dismiss key and verify dismissal.
    @MainActor func dismissNativeTestKeyboard() {
        guard keyboards.firstMatch.exists else { return }
        let hide = keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Hide keyboard", "키보드 가리기", "키보드 숨기기"])).firstMatch
        if hide.exists && hide.isHittable { hide.tap() }
        else {
            let done = buttons["완료"].firstMatch
            if done.exists && done.isHittable { done.tap() }
        }
        // iPad can retain a collapsed keyboard accessory in the accessibility tree.
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: hide)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
}
