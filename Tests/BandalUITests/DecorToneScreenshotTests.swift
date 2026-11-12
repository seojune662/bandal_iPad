import XCTest

/// Captures of what the decor tones and of the screens around it (the 새 노트 sheet, the folder tree, a folder's
/// windows in the sidebar and on their cards), for a side-by-side report. It only drives and attaches;
/// behaviour is asserted in `NativeDecorToneUITests` and `NativeWorkspaceWindowsUITests`.
final class DecorToneScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testTour() throws {
        let app = launch(reset: true, appearance: "light", intensity: "1.0")
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        var name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("운동체역학")
        app.buttons["native-create-course"].tap()
        let menu = app.buttons["운동체역학 폴더 메뉴"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        app.buttons["native-course-add-subfolder"].firstMatch.tap()
        name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("3주차")
        app.buttons["native-create-course"].tap()
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription)
        sleep(2); attach(app, "01-home")

        home.tap()
        let create = app.buttons["native-new-note-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["native-new-note-paper-grid"].tap()
        sleep(1); attach(app, "02-new-note")
        create.tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        sleep(2); attach(app, "03-pdf")
        app.buttons["native-pdf-pages"].tap(); sleep(2); attach(app, "04-pdf-thumbnails"); app.buttons["native-pdf-pages"].tap()

        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap()
        XCTAssertTrue(app.buttons["native-new-tab-new-note"].waitForExistence(timeout: 5), app.debugDescription)
        sleep(1); attach(app, "05-plus-menu")
        app.buttons["native-new-tab-new-note"].tap(); sleep(4); attach(app, "06-markdown")
        for (shot, action) in [("07-browser", "new-browser"), ("08-ai", "chat")] {
            plus.tap()
            let item = app.buttons["native-new-tab-" + action]
            XCTAssertTrue(item.waitForExistence(timeout: 5), action + app.debugDescription); item.tap()
            sleep(4); attach(app, shot)
        }

        // A second window with its own note, then both in the sidebar and on their cards.
        app.buttons["native-sidebar-window-add"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        sleep(2); attach(app, "09-sidebar-windows")
        let overview = app.buttons["native-workspace-windows-toggle"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10)); overview.tap()
        XCTAssertTrue(app.buttons["native-window-add"].waitForExistence(timeout: 15), app.debugDescription)
        sleep(2); attach(app, "10-window-cards")
        overview.tap(); sleep(2)

        // The same note at three points of the dial, and in the dark.
        for (shot, appearance, intensity) in [("11-dial-055", "light", "0.55"), ("12-dial-100", "light", "1.0"), ("13-dial-200", "light", "2.0"), ("14-dark", "dark", "1.0")] {
            app.terminate()
            let again = launch(reset: false, appearance: appearance, intensity: intensity)
            XCTAssertTrue(again.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 30), again.debugDescription)
            sleep(2); attach(again, shot)
        }
    }

    @MainActor private func launch(reset: Bool, appearance: String, intensity: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing"] + (reset ? ["--reset-native-ui-testing"] : [])
            + ["--native-browser-ui-fixture", "-native.appearance", appearance, "-native.decor.palette", "ocean", "-native.decor.intensity", intensity]
        app.launch()
        return app
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
