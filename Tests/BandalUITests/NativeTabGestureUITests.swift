import XCTest

/// The three-finger tab gesture after it is recognized. XCUITest and the
/// simulator cannot put three fingers down: `--native-tab-gesture-fixture` gives each pane two buttons that
/// hand the dock what the recognizer would have decided (`native-tab-gesture-fixture-close-<pane>` / `-open-<pane>`).
/// The recognizer's own rules are unit tests (NativeTabGestureTests).
final class NativeTabGestureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPinchClosesTheTabAndUndoPutsItBackInItsPlace() throws {
        let app = launch(["--native-tab-gesture-fixture"])
        createCourse("Gesture Course", app: app)
        for title in ["Alpha", "Beta", "Gamma"] { createNote(title, app: app) }
        let beta = tab("Beta", app: app)
        beta.tap()
        XCTAssertTrue(waitSelected(beta), app.debugDescription)
        let id = beta.identifier
        tapFixture("close", app: app)
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 10), "The pinch closes the pane's chosen tab")
        XCTAssertTrue(app.staticTexts["탭을 닫았어요"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Closed by three fingers, with 되돌리기")
        let undo = app.buttons.matching(NSPredicate(format: "label == '되돌리기' AND identifier != 'native-pdf-undo'")).firstMatch
        XCTAssertTrue(undo.exists, app.debugDescription); undo.tap()
        let back = app.buttons[id]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "되돌리기 opens the same document again")
        XCTAssertTrue(waitSelected(back), "…chosen")
        let alpha = tab("Alpha", app: app), gamma = tab("Gamma", app: app)
        XCTAssertLessThan(alpha.frame.minX, back.frame.minX, "…in its place between Alpha and Gamma")
        XCTAssertLessThan(back.frame.minX, gamma.frame.minX)
        XCTAssertFalse(app.staticTexts["탭을 닫았어요"].exists)
    }

    @MainActor
    func testSpreadOpensTheNewTabMenuOrTheKindChosenInSettings() throws {
        let app = launch(["--native-tab-gesture-fixture"])
        createCourse("Spread Course", app: app)
        createNote("Alpha", app: app)
        let before = tabs(app).count
        tapFixture("open", app: app)
        let markdown = app.buttons["native-new-tab-new-note"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 5), "매번 고르기 (the default) shows the ＋ menu: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["native-new-tab-new-browser"].exists)
        capture("Spread: the ＋ menu")
        markdown.tap()
        expectTabCount(before + 1, app: app)
        app.dismissNativeTestKeyboard()

        openGestureSettings(app)
        let toggle = app.switches["native-settings-tab-gesture"]
        XCTAssertEqual(toggle.value as? String, "1", "On by default")
        let kind = app.buttons["native-settings-tab-gesture-open"]
        XCTAssertTrue(kind.exists); XCTAssertTrue(kind.label.contains("매번 고르기"), kind.label)
        kind.tap()
        let browser = app.buttons["native-settings-tab-gesture-open-new-browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["native-settings-tab-gesture-open-choose"].exists)
        capture("Settings: what a spread opens")
        browser.tap()
        XCTAssertTrue(waitLabel(kind, contains: "브라우저"), kind.label)
        closeSettings(app)
        let browsers = tabs(app).count
        XCTAssertFalse(app.buttons["native-browser-back"].exists)
        tapFixture("open", app: app)
        // The tab takes the page's title as soon as it loads; the browser's own row says what it is.
        XCTAssertTrue(app.buttons["native-browser-back"].waitForExistence(timeout: 15), "브라우저 chosen: the spread opens it straight away: \(app.debugDescription)")
        expectTabCount(browsers + 1, app: app)
        XCTAssertFalse(app.buttons["native-new-tab-new-note"].exists, "…without the menu")
        capture("Spread with 브라우저 chosen")
        let opened = tabs(app).count

        openGestureSettings(app)
        toggle.tap()
        XCTAssertTrue(waitValue(toggle, "0"), app.debugDescription)
        XCTAssertFalse(kind.exists, "Off: nothing to choose")
        closeSettings(app)
        tapFixture("close", app: app)
        sleep(2)
        XCTAssertEqual(tabs(app).count, opened, "Off: three fingers close nothing")
        XCTAssertFalse(app.staticTexts["탭을 닫았어요"].exists)
    }

    // MARK: Helpers

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        return app
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func createNote(_ title: String, app: XCUIApplication) {
        let add = app.buttons["native-library-create"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["새 마크다운"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["만들기"].tap()
        XCTAssertTrue(tab(title, app: app).waitForExistence(timeout: 15), app.debugDescription)
        app.dismissNativeTestKeyboard()
    }
    @MainActor private func openFromPlus(_ item: String, app: XCUIApplication) {
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-dock-add-'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
        let row = app.buttons["native-new-tab-" + item]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription); row.tap()
    }
    @MainActor private func tab(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-document-tab-' AND label CONTAINS %@", title)).firstMatch
    }
    @MainActor private func tabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-document-tab-'")).allElementsBoundByIndex
    }
    @MainActor private func expectTabCount(_ count: Int, app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.tabs(app).count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, app.debugDescription)
    }
    @MainActor private func tapFixture(_ kind: String, pane: Int = 0, app: XCUIApplication) {
        let button = app.buttons["native-tab-gesture-fixture-\(kind)-\(pane)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription); button.tap()
    }
    @MainActor private func openGestureSettings(_ app: XCUIApplication) {
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["native-settings-category-general"].waitForExistence(timeout: 10), app.debugDescription)
        if !app.switches["native-settings-tab-gesture"].exists { app.openNativeSettingsMore() }
        XCTAssertTrue(app.switches["native-settings-tab-gesture"].waitForExistence(timeout: 10), "세 손가락 lives in 일반 › 더 보기 › 탭: \(app.debugDescription)")
    }
    @MainActor private func closeSettings(_ app: XCUIApplication) {
        let close = app.buttons["native-settings-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), app.debugDescription)
    }
    private func waitSelected(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)], timeout: 5) == .completed
    }
    private func waitValue(_ element: XCUIElement, _ value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 5) == .completed
    }
    private func waitLabel(_ element: XCUIElement, contains text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: 5) == .completed
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
