import XCTest

/// Captures of the sidebar's folder rows and windows, the PDF palette, the thumbnails button and the pages panel,
/// on a landscape lecture PDF (`--native-perf-fixture`, 960 × 540 pages with ink), in light and dark, for a
/// side-by-side report. It only drives and attaches; behaviour is asserted in the feature tests.
final class SidebarPaletteScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testSidebarPaletteThumbnailsLight() throws { try tour("light") }
    @MainActor func testSidebarPaletteThumbnailsDark() throws { try tour("dark") }

    @MainActor private func tour(_ appearance: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-perf-fixture", "-native.appearance", appearance]
        app.launch()
        createCourse("선형대수", app: app)
        createCourse("운동체역학", app: app)
        let menu = app.buttons["운동체역학 폴더 메뉴"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        app.buttons["native-course-add-subfolder"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("3주차")
        app.buttons["native-create-course"].tap()
        let parent = courseRow("운동체역학", app: app)
        XCTAssertTrue(parent.waitForExistence(timeout: 10), app.debugDescription); parent.tap()
        open("강의 1.pdf", app: app)
        let add = app.buttons["native-sidebar-window-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
        open("강의 2.pdf", app: app)
        sleep(2); attach(app, "01 sidebar + palette \(appearance)")

        let pages = app.buttons["native-pdf-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 10)); pages.tap()
        XCTAssertTrue(app.buttons["native-pdf-thumbnail-1"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(3); attach(app, "02 thumbnails \(appearance)")
        app.buttons["native-pdf-thumbnail-3"].tap(); sleep(2); attach(app, "03 thumbnails page 3 \(appearance)")

        // The palette with the highlighter, then the pen's settings.
        app.buttons["native-pdf-tool-highlighter"].tap(); sleep(1); attach(app, "04 highlighter \(appearance)")
        let pen = app.buttons["native-pdf-tool-pen"]
        pen.tap(); sleep(1)
        // The chosen cell's wash and ⌄ must not cover the button for VoiceOver's hit test (a view drawn behind it once did).
        XCTAssertTrue(pen.isHittable, "The chosen pen answers a touch")
        pen.tap()
        if app.buttons["native-pdf-style-close"].waitForExistence(timeout: 5) { sleep(1); attach(app, "05 pen settings \(appearance)"); app.buttons["native-pdf-style-close"].tap() }
        pages.tap(); sleep(1)
        let collapse = app.buttons["native-pdf-palette-collapse"]
        if collapse.waitForExistence(timeout: 5) {
            collapse.tap(); sleep(1); attach(app, "06 collapsed \(appearance)")
            app.buttons["native-pdf-palette-expand"].tap(); sleep(1)
        }
    }

    @MainActor private func open(_ file: String, app: XCUIApplication) {
        let item = app.buttons["native-material-" + file]
        XCTAssertTrue(item.waitForExistence(timeout: 60), file + " " + app.debugDescription)
        item.tap()
        let tools = app.buttons["native-pdf-drawing-tools"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", "drawings="), object: tools)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, file)
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        let menu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25)); menu.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(courseRow(name, app: app).waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func courseRow(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND label CONTAINS %@", "native-course-", "native-course-expand-", name)).firstMatch
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
