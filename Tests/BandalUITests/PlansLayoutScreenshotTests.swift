import XCTest

/// 요금제 in each layout it meets: portrait and landscape, light and dark, a narrow window (`--plans-width`,
/// since a UI test cannot open Split View) and English. Only drives, checks nothing overlaps the screen's
/// edge, and attaches; the states themselves are StoreScreensUITests.
final class PlansLayoutScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testOrientationsAndAppearances() throws {
        for (orientation, appearance) in [(UIDeviceOrientation.portrait, "light"), (.portrait, "dark"), (.landscapeLeft, "light"), (.landscapeLeft, "dark")] {
            let app = launch(orientation, ["--plans-state", "scheduled", "--native-ai-usage-fixture", "-native.appearance", appearance])
            capture(app, "\(orientation == .portrait ? "portrait" : "landscape") \(appearance) top")
            scrollDown(app)
            capture(app, "\(orientation == .portrait ? "portrait" : "landscape") \(appearance) bottom")
            app.terminate()
        }
    }

    /// Slide Over (375) and half of a landscape 13-inch screen (678): the cards scroll sideways, the credit
    /// card stacks its button under the text, and the footer's buttons stack.
    @MainActor func testNarrowWindows() throws {
        for width in ["375", "678"] {
            let app = launch(.landscapeLeft, ["--plans-state", "trial", "--native-ai-usage-fixture", "--plans-width", width])
            capture(app, "narrow \(width) top")
            let cards = app.otherElements["membership-card-pro"]
            XCTAssertTrue(cards.exists, width)
            scrollDown(app)
            let buy = app.buttons["plans-credit-buy"]
            XCTAssertTrue(buy.exists, width)
            let window = app.windows.firstMatch.frame
            XCTAssertLessThanOrEqual(buy.frame.maxX, window.maxX, "\(width): the credit button stays on screen")
            capture(app, "narrow \(width) bottom")
            app.terminate()
        }
    }

    @MainActor func testEnglish() throws {
        let app = launch(.portrait, ["--plans-state", "plus-monthly", "--native-ai-usage-fixture", "-native.locale", "en-US"])
        XCTAssertEqual(app.staticTexts["membership-title"].label, "Plans")
        XCTAssertEqual(app.staticTexts["membership-current"].label, "Bandal Plus · Monthly")
        app.buttons["membership-period-monthly"].tap()
        XCTAssertEqual(app.buttons["membership-cta-plus"].label, "Current plan")
        capture(app, "english top")
        scrollDown(app)
        XCTAssertEqual(app.buttons["plans-manage"].label, "Cancel or manage in the App Store")
        capture(app, "english bottom")
    }

    // MARK: Helpers

    @MainActor private func launch(_ orientation: UIDeviceOrientation, _ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-store-fixture"] + extra
        app.launch()
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription); settings.tap()
        let category = app.buttons["native-settings-category-subscription"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !category.isSelected { category.tap(); _ = app.buttons["native-membership-manage"].waitForExistence(timeout: 2) }
        let open = app.buttons["native-membership-manage"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !app.staticTexts["membership-title"].exists { open.tap(); _ = app.staticTexts["membership-title"].waitForExistence(timeout: 5) }
        _ = app.buttons["membership-cta-pro"].waitForExistence(timeout: 10)
        sleep(1)
        return app
    }

    @MainActor private func scrollDown(_ app: XCUIApplication) {
        let page = app.otherElements["membership-paywall"].scrollViews.firstMatch
        for _ in 0..<3 { (page.exists ? page : app).swipeUp() }
        sleep(1)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }
}
