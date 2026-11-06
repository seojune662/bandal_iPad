import XCTest

final class NativeToolsFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPlannerPersistsAndSettingsUsesNativeControls() throws {
        let app = launch()
        app.buttons["native-section-planner"].tap()
        let board = app.buttons["native-planner-board"]
        XCTAssertTrue(board.waitForExistence(timeout: 10)); board.tap()
        let add = app.buttons["native-task-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        let title = app.textFields["native-task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Review native workspace")
        // With the simulator keyboard up, the form sheet's reported frame (raised for the
        // keyboard) can disagree with where it is drawn, so the 저장 tap misses. Lower it first.
        app.dismissNativeTestKeyboard()
        app.buttons["native-task-save"].tap()
        XCTAssertTrue(taskEditor(in: app, title: "Review native workspace").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        closeBoard(app) // The study board is modal; its backdrop covers the navigation rail.
        app.buttons["native-section-settings"].tap()
        XCTAssertTrue(app.buttons["native-settings-theme-system"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["native-section-planner"].waitForExistence(timeout: 20))
        app.buttons["native-section-planner"].tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10)); board.tap()
        XCTAssertTrue(taskEditor(in: app, title: "Review native workspace").waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testBrowserDisplaysOnlyLocalWebsiteInsideNativeChrome() throws {
        let app = launch(extra: ["--native-browser-ui-fixture"])
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Browser tools")
        app.buttons["native-create-course"].tap()
        let addTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(addTab.waitForExistence(timeout: 10)); addTab.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let address = app.textFields["native-browser-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), app.debugDescription)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(page.staticTexts["Native browser fixture"].waitForExistence(timeout: 15), app.debugDescription)
        let input = page.textFields["Website input"]
        input.tap(); input.typeText("Native browser input")
        XCTAssertEqual(input.value as? String, "Native browser input")
        app.buttons["native-section-planner"].tap()
        XCTAssertTrue(app.buttons["native-task-add"].waitForExistence(timeout: 10))
        // The study board is a modal over the workspace (since the native rebuild), not a
        // section that replaces it: the browser tab stays mounted behind the dimmed
        // backdrop, so its page and form must survive closing the board.
        closeBoard(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Native browser fixture")).firstMatch.tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertTrue(page.staticTexts["Native browser fixture"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(page.textFields["Website input"].value as? String, "Native browser input", "The page's form survives the board")
    }

    @MainActor private func closeBoard(_ app: XCUIApplication) {
        let board = app.descendants(matching: .any)["native-board-overlay"]
        XCTAssertTrue(board.exists, app.debugDescription)
        app.buttons["native-board-overlay-close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: board); waitForExpectations(timeout: 5)
    }

    @MainActor private func taskEditor(in app: XCUIApplication, title: String) -> XCUIElement {
        // SwiftUI exposes the title as the button's label, without a separate
        // StaticText descendant. Match the edit action, not its completion peer.
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-task-edit-", title)).firstMatch
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-section-planner"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
}
