import XCTest

/// Chrome-style password flow: sign in → "save?" bar → no repeat prompt once saved.
final class NativeBrowserLoginUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSubmittedLoginOffersSaveOnce() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-login-ui-fixture"]
        app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap(); app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Login")
        app.buttons["native-create-course"].tap()
        let dockAdd = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(dockAdd.waitForExistence(timeout: 10)); dockAdd.tap(); app.buttons["native-new-tab-new-browser"].tap()

        let web = app.webViews.firstMatch
        let username = web.textFields["Fixture username"], password = web.secureTextFields["Fixture password"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        username.tap(); username.typeText("student")
        // Enter submits without blurring the field: tapping a page button hides
        // the keyboard, which crashes XCTAutomationSupport's os_log hook on iOS 18.3.
        password.tap(); password.typeText("fixture-secret"); app.typeText("\n")

        let save = app.buttons["native-browser-login-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Submitting a login offers to save it")
        capture("Save password prompt")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))

        // Autofill on return is covered by NativeBrowserCredentialsIntegrationTests:
        // reloading here would blur the field and hit the same XCTest crash.
        password.tap(); app.typeText("\n")
        XCTAssertFalse(save.waitForExistence(timeout: 3), "A login that is already saved is not offered again")
        capture("No second prompt for a saved login")
    }

    @MainActor private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
}
