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
        // 1.4.0: the task editor is a popover; Enter adds the task (no sheet, no 저장 under the keyboard).
        title.typeText("\n")
        XCTAssertTrue(taskEditor(in: app, title: "Review native workspace").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        closeBoard(app) // The study board is modal; its backdrop covers the navigation rail.
        app.buttons["native-section-settings"].tap()
        // Settings opens on 일반 (1.4.0); the theme lives under 화면.
        let appearance = app.buttons["native-settings-category-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !app.buttons["native-settings-theme-system"].exists { appearance.tap(); _ = app.buttons["native-settings-theme-system"].waitForExistence(timeout: 2) }
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
        app.buttons["native-course-add-menu"].tap()
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

    /// The redesigned board: a card's popover moves it between the status columns and deletes it,
    /// 완료 숨기기 drops the last column, and a course chip leaves only that course's tasks.
    @MainActor
    func testBoardCardMovesBetweenColumnsHidesWhenDoneFiltersByCourseAndDeletes() throws {
        let app = launch()
        app.buttons["native-course-add-menu"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Board course")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["Board course 과목 메뉴"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["native-section-planner"].tap()
        let list = app.buttons["native-planner-board"]
        XCTAssertTrue(list.waitForExistence(timeout: 10)); list.tap()

        // A new task takes the open course; the second is added without one.
        addTask("Course task", in: app)
        addTask("Loose task", in: app) { app.buttons["과목 Board course"].tap() }
        XCTAssertTrue(card("Course task", column: "todo", in: app).exists, app.debugDescription)

        // The popover's status control moves the card.
        card("Course task", column: "todo", in: app).tap()
        let done = app.buttons["native-task-status-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(done.label, "상태 완료", "Not another 완료 button")
        done.tap()
        XCTAssertTrue(card("Course task", column: "done", in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(card("Course task", column: "todo", in: app).exists)

        // 완료 숨기기 takes the 완료 column away and brings it back.
        let hide = app.switches["native-planner-hide-done"]
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() // the switch itself, not its label
        let doneColumn = app.descendants(matching: .any)["native-planner-column-done"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: doneColumn); waitForExpectations(timeout: 5)
        XCTAssertFalse(taskEditor(in: app, title: "Course task").exists)
        XCTAssertTrue(card("Loose task", column: "todo", in: app).exists)
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() // the switch itself, not its label
        XCTAssertTrue(card("Course task", column: "done", in: app).waitForExistence(timeout: 5), app.debugDescription)

        // A course chip filters; tapping it again shows everything.
        let chip = app.buttons["Board course 과목만 보기"]
        chip.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: taskEditor(in: app, title: "Loose task")); waitForExpectations(timeout: 5)
        XCTAssertTrue(taskEditor(in: app, title: "Course task").exists)
        chip.tap()
        XCTAssertTrue(taskEditor(in: app, title: "Loose task").waitForExistence(timeout: 5))

        // 할 일 삭제 asks once, then the card is gone.
        taskEditor(in: app, title: "Loose task").tap()
        let delete = app.buttons["native-task-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription); delete.tap()
        let confirm = app.buttons["native-task-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: taskEditor(in: app, title: "Loose task")); waitForExpectations(timeout: 10)
        XCTAssertTrue(app.descendants(matching: .any)["native-board-overlay"].exists, "Deleting leaves the board open")
    }

    /// The calendar's + adds a task due on the chosen day; the day's cell and panel then show it.
    @MainActor
    func testBoardCalendarAddsATaskDueOnTheChosenDay() throws {
        let app = launch()
        app.buttons["native-section-planner"].tap()
        let calendar = app.buttons["native-planner-calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10)); calendar.tap()
        // Tomorrow, unless that is next month's page: then today.
        let now = Date(), tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let day = Calendar.current.isDate(tomorrow, equalTo: now, toGranularity: .month) ? tomorrow : now
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let cell = app.buttons["native-planner-day-" + formatter.string(from: day)]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), app.debugDescription); cell.tap()
        XCTAssertTrue(app.staticTexts["이 날은 일정이 없어요"].waitForExistence(timeout: 5), app.debugDescription)

        addTask("Due on the chosen day", in: app)

        let added = taskEditor(in: app, title: "Due on the chosen day")
        XCTAssertTrue(added.exists, app.debugDescription)
        XCTAssertTrue((added.value as? String ?? "").contains(day == now ? "D-DAY" : "D-1"), "The card counts the days to the chosen day: \(String(describing: added.value))")
        XCTAssertFalse(app.staticTexts["이 날은 일정이 없어요"].exists)
        XCTAssertTrue(cell.label.contains("일정 1개"), cell.label)
    }

    /// Opens 새 할 일 from the visible add control, types the title and adds with Enter.
    @MainActor private func addTask(_ title: String, in app: XCUIApplication, before submit: () -> Void = {}) {
        let add = app.buttons["native-task-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
        let field = app.textFields["native-task-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap(); field.typeText(title)
        submit()
        field.typeText("\n")
        XCTAssertTrue(taskEditor(in: app, title: title).waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func card(_ title: String, column: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["native-planner-column-" + column].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-task-edit-", title)).firstMatch
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
