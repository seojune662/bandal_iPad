import XCTest

/// Pictures of the chosen pane among two side by side, for each candidate look (`NativeDockFocusStyle`) in light and
/// dark and in several decor palettes, so the owner can choose. The left pane (a web page) is the chosen one.
final class NativeFocusStyleScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testFocusStylesAcrossThemes() throws {
        // Set up in landscape (room for two panes beside the sidebar), photographed upright: the simulator's landscape
        // captures come out cropped.
        XCUIDevice.shared.orientation = .landscapeLeft
        let base = ["--native-ui-testing", "--native-browser-ui-fixture", "--native-chrome-favicon-fixture"]
        let setup = XCUIApplication()
        setup.launchArguments = base + ["--reset-native-ui-testing", "-native.appearance", "light"]
        setup.launch()
        XCTAssertTrue(setup.buttons["native-section-library"].waitForExistence(timeout: 25))
        setup.buttons["native-course-add-menu"].tap()
        let field = setup.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Focus Looks")
        setup.buttons["native-create-course"].tap()
        let home = setup.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15)); home.tap(); setup.confirmNewNote(title: "강의 노트")
        let note = setup.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "native-document-tab-", "강의 노트")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        let plus = setup.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        plus.tap(); setup.buttons["native-new-tab-new-browser"].tap()
        let browser = setup.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-document-tab-", "Favicon fixture")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 20))
        browser.press(forDuration: 1)
        let left = setup.buttons["native-dock-move-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 5)); left.tap()
        let strips = setup.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-"))
        let split = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in strips.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [split], timeout: 20), .completed, setup.debugDescription)
        // The right panel closed, as on the owner's screen: the window buttons sit over the right pane.
        let panel = setup.buttons["native-toggle-materials-rail"]
        if panel.label == "오른쪽 패널 접기" { panel.tap() }
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panel.label == "오른쪽 패널 펼치기" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        setup.terminate()
        XCUIDevice.shared.orientation = .portrait

        for palette in ["dawn", "forest", "mono"] {
            for appearance in ["light", "dark"] {
                for style in ["legacy", "rim", "bar", "both"] {
                    let app = XCUIApplication()
                    app.launchArguments = base + ["-native.appearance", appearance, "-native.decor.palette", palette, "-native.chrome.focusStyle", style]
                    app.launch()
                    let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-document-tab-", "Favicon fixture")).firstMatch
                    XCTAssertTrue(tab.waitForExistence(timeout: 25), app.debugDescription)
                    tab.tap()
                    Thread.sleep(forTimeInterval: 1.5)
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "focus-\(style)-\(palette)-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
                    app.terminate()
                }
            }
        }
    }
}
