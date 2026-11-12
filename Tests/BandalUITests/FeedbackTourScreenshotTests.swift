import XCTest

/// Screenshots of the TestFlight feedback and UX-audit changes (2026-11-12), in landscape on a reset profile.
/// It only drives and attaches; the behaviour is asserted in the feature tests.
final class FeedbackTourScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testFeedbackTour() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        if !add.waitForExistence(timeout: 25) { app.buttons["native-section-library"].tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1); attach(app, "01-empty")

        // School → site tiles.
        app.buttons["native-university-choose"].firstMatch.tap()
        let search = app.textFields["native-school-search"]
        if search.waitForExistence(timeout: 15) {
            search.tap(); search.typeText("SNU")
            let school = app.buttons["native-school-result-snu"]
            if school.waitForExistence(timeout: 5) { school.tap() }
        }
        sleep(2)

        // Folders, one with a colour.
        for (name, color) in [("선형대수", "green"), ("일반물리", "blue")] {
            add.tap()
            let field = app.textFields["native-course-name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
            app.buttons["native-course-color-" + color].tapIfExists()
            app.buttons["native-create-course"].tap(); sleep(2)
        }
        attach(app, "02-sidebar")
        let menu = app.buttons["일반물리 폴더 메뉴"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap(); sleep(1); attach(app, "03-folder-menu")
            app.buttons["색상"].firstMatch.tapIfExists(); sleep(1); attach(app, "04-folder-colors")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap(); sleep(1)
        }

        // AI and home share the left slot.
        let ai = app.buttons["native-ai-rail-toggle"]
        if ai.waitForExistence(timeout: 5) {
            ai.tap(); sleep(2); attach(app, "05-ai-open")
            ai.tap(); sleep(1); attach(app, "06-ai-folded")
            app.buttons["native-section-library"].tap(); sleep(1)
        }

        // A new note: the palette and its sliding tool strip.
        let note = app.buttons["native-home-new-note"]
        if note.waitForExistence(timeout: 10) { note.tap() }
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        sleep(2); attach(app, "07-pdf-palette")
        let strip = app.scrollViews["native-pdf-tool-scroll"]
        if strip.exists { strip.swipeLeft(); sleep(1); attach(app, "08-tool-strip-slid"); strip.swipeRight(); sleep(1) }

        // The view menu behind the thumbnails button's ⌄.
        let pages = app.buttons["native-pdf-pages"]
        if pages.exists {
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5)).tap(); sleep(1); attach(app, "09-view-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).tap(); sleep(1)
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap(); sleep(1); attach(app, "10-pages-panel")
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap(); sleep(1)
        }

        // A text box with the keyboard up.
        app.buttons["native-pdf-tool-text"].tapIfExists(); sleep(1)
        let body = app.otherElements["native-pdf-workspace"]
        if body.exists {
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).tap(); sleep(2)
            app.typeText("반달 텍스트 상자"); sleep(1); attach(app, "11-text-box")
            app.buttons["native-pdf-save-text"].tapIfExists(); sleep(1)
        }

        // The study board's task popover.
        app.buttons["native-section-planner"].tapIfExists(); sleep(2); attach(app, "12-study-board")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}

private extension XCUIElement {
    func tapIfExists() { if waitForExistence(timeout: 3) && isHittable { tap() } }
}
