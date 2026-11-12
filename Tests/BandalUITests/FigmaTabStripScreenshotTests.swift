import XCTest

/// Captures for the side-by-side comparison with the Figma tab strip and split frames
/// (155:7541, 269:8463, 129:1460, 130:5933, 130:6038, 130:6137 and their dark twins).
/// Each test only drives and attaches; behaviour is asserted in the docking tests.
final class FigmaTabStripScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testLight() throws { try capture("light") }
    @MainActor func testDark() throws { try capture("dark") }

    @MainActor private func capture(_ appearance: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "-native.appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Design Studio"); app.buttons["native-create-course"].tap()
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); sleep(1)
        XCTAssertFalse(app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-")).firstMatch.exists, "The home screen has no tab strip")
        attach(app, appearance + " 1 home")

        for action in ["new-note", "new-browser", "new-browser"] { open(action, app: app) }
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-"))
        tabs.element(boundBy: 0).tap(); sleep(2)
        attach(app, appearance + " 2 single")
        for (index, preset) in ["columns", "rows", "grid"].enumerated() {
            let choice = app.buttons["native-dock-preset-" + preset]
            app.openNativeDockLayoutMenu()
            if !choice.waitForExistence(timeout: 8) { app.openNativeDockLayoutMenu() }
            XCTAssertTrue(choice.waitForExistence(timeout: 8), app.debugDescription); choice.tap(); sleep(2)
            tabs.element(boundBy: 0).tap(); sleep(1)
            attach(app, appearance + " \(index + 3) " + preset)
        }
    }
    @MainActor private func open(_ action: String, app: XCUIApplication) {
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let item = app.buttons["native-new-tab-" + action]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription); item.tap()
        if action == "new-whiteboard" { app.confirmNewNote() }
        sleep(3)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
