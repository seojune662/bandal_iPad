import XCTest

final class NativePagedMarkdownUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testContinuousPDFNotesPreserveBothPagesAndIndependentScrollAfterRestart() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-pages-fixture"]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25)); add.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Linked pages")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap(); app.buttons["새 필기 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Lecture")
        app.buttons["native-new-note-create"].tap()
        let note = app.buttons["native-pdf-page-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 20)); note.tap()
        let first = app.textViews["native-markdown-page-editor-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        first.tap(); first.typeText("First page keeps its own notes.")
        dismissKeyboard(app)
        jump(2, app)
        let second = app.textViews["native-markdown-page-editor-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 15)); second.tap(); second.typeText("Second page has a different explanation.")
        dismissKeyboard(app)
        let page = app.textFields["native-pdf-page"]
        let linked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [linked], timeout: 15), .completed, app.debugDescription)
        let sync = app.buttons["native-markdown-page-sync"]
        XCTAssertTrue(sync.exists); sync.tap()
        jump(1, app)
        XCTAssertEqual(page.value as? String, "2", "An unlinked note must not navigate its paired PDF")
        XCTAssertTrue((first.value as? String ?? "").contains("First page keeps its own notes."))
        XCTAssertFalse(app.staticTexts["native-pdf-save-status"].exists)
        XCTAssertFalse(app.staticTexts["손가락으로 이동 · Apple Pencil로 필기"].exists)
        XCTAssertFalse(app.staticTexts["native-markdown-save-status"].exists)
        let topTab = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-")).firstMatch
        XCTAssertLessThanOrEqual(topTab.frame.minY, 1, "The workspace starts at the top after hiding the system status bar")
        let toolbar = app.descendants(matching: .any)["native-markdown-toolbar"]
        XCTAssertEqual(toolbar.frame.height, 44, accuracy: 1)
        XCTAssertEqual(toolbar.frame.minY, topTab.frame.maxY, accuracy: 1, "No duplicate filename/save row above the formatting controls")
        capture("Continuous paper notes beside their source PDF")
        app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-pages-fixture"]; app.launch()
        XCTAssertTrue(sync.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(sync.isSelected)
        jump(1, app)
        XCTAssertTrue((first.value as? String ?? "").contains("First page keeps its own notes."))
        jump(2, app)
        XCTAssertTrue((second.value as? String ?? "").contains("Second page has a different explanation."))
        XCTAssertEqual(app.webViews.count, 0)
        capture("Linked note pages and scroll independence restored")
    }
    @MainActor private func jump(_ page: Int, _ app: XCUIApplication) {
        app.buttons["native-markdown-page-picker"].tap()
        let destination = app.buttons["native-markdown-page-choice-\(page)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.tap()
        XCTAssertTrue(app.textViews["native-markdown-page-editor-\(page)"].waitForExistence(timeout: 15))
    }
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        app.dismissNativeTestKeyboard()
    }
    @MainActor private func capture(_ title: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item)
    }
}
