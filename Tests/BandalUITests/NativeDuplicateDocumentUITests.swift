import XCTest

final class NativeDuplicateDocumentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testMarkdownDuplicateSharesSavedTextButKeepsLocalUndoAndBothTabsAfterRestart() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap(); app.buttons["native-new-course"].firstMatch.tap()
        let course = app.textFields["native-course-name"]; XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Shared document")
        app.buttons["native-create-course"].tap()
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap(); app.buttons["native-new-tab-new-note"].tap()
        let initial = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(initial.waitForExistence(timeout: 15)); initial.tap(); app.typeKey("a", modifierFlags: .command); initial.typeText("Shared opening paragraph.")
        dismissKeyboard(app)
        let originalTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-")).firstMatch
        let originalID = originalTab.identifier
        app.buttons["native-open-documents"].tap()
        let duplicate = app.buttons["native-duplicate-right"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), app.debugDescription); duplicate.tap()
        expectEditors(2, app: app)
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-"))
        XCTAssertEqual(tabs.count, 2)
        let tabIDs = Set(tabs.allElementsBoundByIndex.map(\.identifier))
        XCTAssertTrue(tabIDs.contains(originalID)); XCTAssertEqual(tabIDs.count, 2)
        XCTAssertTrue(tabIDs.contains { $0.hasPrefix("native-document-tab-instance:") })
        expectBothContain("Shared opening paragraph.", app: app)
        let first = editors(app)[0]; first.tap(); app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: .command); first.typeText("\nFirst pane edit.")
        expectBothContain("First pane edit.", app: app)
        let beforeSecond = try XCTUnwrap(editors(app)[1].value as? String)
        let second = editors(app)[1]; second.tap(); app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: .command); second.typeText("\nSecond pane edit.")
        expectBothContain("Second pane edit.", app: app)
        app.typeKey("z", modifierFlags: .command)
        let undo = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.editors(app).allSatisfy { $0.value as? String == beforeSecond } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [undo], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue((editors(app)[0].value as? String ?? "").contains("First pane edit."), "Undo in the second pane must retain the peer's edit")
        capture("Shared Markdown immediately after Undo, before new input")
        second.typeText("\nFinal second pane text.")
        capture("Shared Markdown new input after Undo")
        expectBothContain("Final second pane text.", app: app)
        dismissKeyboard(app)
        let savedText = try XCTUnwrap(editors(app)[0].value as? String)
        capture("Two instances of one Markdown document share edits")
        // A real navigation barrier must save the shared writer before termination.
        app.buttons["native-section-learning"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native-learning-home").firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        expectEditors(2, app: app, timeout: 25)
        XCTAssertEqual(Set(tabs.allElementsBoundByIndex.map(\.identifier)), tabIDs)
        for editor in editors(app) { XCTAssertEqual(editor.value as? String, savedText) }
        capture("Independent duplicate tabs restored with one exact saved document")
        let material = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "새 마크다운")).firstMatch
        XCTAssertTrue(material.waitForExistence(timeout: 10)); material.tap()
        XCTAssertEqual(tabs.count, 2, "Ordinary opening must select an existing storage instance")
    }
    @MainActor private func editors(_ app: XCUIApplication) -> [XCUIElement] {
        app.textViews.matching(identifier: "native-markdown-editor").allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }
    @MainActor private func expectEditors(_ count: Int, app: XCUIApplication, timeout: TimeInterval = 15) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.editors(app).count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: timeout), .completed, app.debugDescription)
    }
    @MainActor private func expectBothContain(_ text: String, app: XCUIApplication) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let items = self.editors(app); return items.count == 2 && items.allSatisfy { ($0.value as? String ?? "").contains(text) } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 12), .completed, "Actual editor values: " + self.editors(app).map { String(describing: $0.value) }.joined(separator: " | ") + "\n" + app.debugDescription)
    }
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) { app.dismissNativeTestKeyboard() }
    @MainActor private func capture(_ name: String) { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item) }
}
