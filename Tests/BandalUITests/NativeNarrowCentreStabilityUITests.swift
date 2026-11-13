import XCTest

/// On an 11-inch iPad a document with both side panels open leaves the centre pane 530–560 pt wide, and 444 pt
/// with the AI panel in the left slot. The 13-inch simulator the other suites run on never gets that narrow
/// (726 pt), so this suite is the one to run on an 11-inch one: with a document open and both panels pinned it
/// works the rail, the folder's windows and the folder's row, and fails when the app stops answering.
final class NativeNarrowCentreStabilityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPDFWithBothPanelsOpenKeepsAnswering() throws {
        let app = launch()
        createFolder("Alpha", app: app)
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote(title: "Narrow")
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        work(app)
    }

    @MainActor func testMarkdownWithBothPanelsOpenKeepsAnswering() throws {
        let app = launch()
        createFolder("Alpha", app: app)
        setInspector(open: true, app: app)
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription); create.tap(); app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription); title.tap(); title.typeText("Narrow Note")
        app.buttons["만들기"].tap()
        let editor = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-markdown")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        app.dismissNativeTestKeyboard()
        work(app)
    }

    /// Two panes side by side need 561 pt. With both panels open on an 11-inch iPad the centre is narrower, so
    /// the dock shows one pane at a time, and goes back to two whenever a panel folds.
    @MainActor func testSplitPDFsWithBothPanelsOpenKeepAnswering() throws {
        let app = launch()
        createFolder("Alpha", app: app)
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote(title: "One")
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), app.debugDescription); plus.tap()
        let note = app.buttons["native-new-tab-new-whiteboard"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription); note.tap(); app.confirmNewNote(title: "Two")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-"))
        XCTAssertTrue(tabs.matching(NSPredicate(format: "label CONTAINS %@", "Two")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        // Split with the right panel folded, where two panes fit.
        setInspector(open: false, app: app)
        let columns = app.buttons["native-dock-preset-columns"]
        app.openNativeDockLayoutMenu()
        if !columns.waitForExistence(timeout: 8) { app.openNativeDockLayoutMenu() }
        XCTAssertTrue(columns.waitForExistence(timeout: 8), app.debugDescription); columns.tap()
        work(app)
    }

    /// Three rounds of what was being tapped when the app froze: the rail's icons, the right panel's button,
    /// the folder's windows and the folder.
    @MainActor private func work(_ app: XCUIApplication, rounds: Int = 3) {
        setInspector(open: true, app: app)
        XCTAssertTrue(app.buttons["native-course-add-menu"].isHittable, "The left panel is open\n" + app.debugDescription)
        let centre = app.otherElements["native-workspace-controls"].frame
        print("NARROW window=\(app.windows.firstMatch.frame.size) controls=\(centre)")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)", "native-sidebar-window-",
                                                    ["native-sidebar-window-add", "native-sidebar-window-close-confirm"]))
        for round in 1...rounds {
            // The rail: AI takes the left slot, 홈 takes it back.
            step("\(round) AI rail", app) { app.buttons["native-ai-rail-toggle"].tap() }
            step("\(round) home rail", app) { app.buttons["native-section-library"].tap() }
            // The right panel folds and comes back.
            step("\(round) right panel folds", app) { app.buttons["native-toggle-materials-rail"].tap() }
            step("\(round) right panel opens", app) { app.buttons["native-toggle-materials-rail"].tap() }
            // A new window, and back to the one that holds the document.
            step("\(round) new window", app) { app.buttons["native-sidebar-window-add"].tap() }
            step("\(round) first window", app) { rows.element(boundBy: 0).tap() }
            // The folder's own row. (One folder only: it is all the free allowance gives, which a Release build keeps to.)
            step("\(round) folder row", app) { folder("Alpha", app).tap() }
        }
    }

    /// One tap, then a question the app can only answer from a live main thread. `limit` is far above what a
    /// healthy step takes (under two seconds) and far below the minute the runner waits for a hung app.
    @MainActor private func step(_ name: String, _ app: XCUIApplication, limit: TimeInterval = 12, _ action: () -> Void) {
        let start = Date()
        action()
        let rail = app.buttons["native-section-library"]
        let answered = rail.waitForExistence(timeout: 90) && rail.isHittable
        let took = Date().timeIntervalSince(start)
        print(String(format: "NARROW-STEP %@ %.2fs", name, took))
        XCTAssertTrue(answered, "The app stopped answering after: " + name)
        XCTAssertLessThan(took, limit, "The app took too long to answer after: " + name)
    }

    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-input-trace", "-native.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["native-section-library"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    @MainActor private func createFolder(_ name: String, app: XCUIApplication) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(folder(name, app).waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func folder(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-course-", name)).firstMatch
    }
    @MainActor private func setInspector(open: Bool, app: XCUIApplication) {
        let toggle = app.buttons["native-toggle-materials-rail"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        let expected = open ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기"
        if toggle.label != expected { toggle.tap() }
        let check = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in toggle.label == expected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 20), .completed, "Inspector state\n" + app.debugDescription)
    }
}
