import XCTest

/// Real native chrome and WKWebView behavior, backed by inline local HTML. The
/// address suggestion is inspected without navigating to its example URL.
final class NativeBrowserParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLocalBrowserSuggestionsFindZoomDownloadsAndProfileIsolation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-parity-ui-fixture", "--native-browser-long-title-ui-fixture"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25)); addCourse.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Browser parity")
        app.buttons["native-create-course"].tap()
        let addTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(addTab.waitForExistence(timeout: 10)); addTab.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Native browser fixture"].waitForExistence(timeout: 15), app.debugDescription)
        let address = app.textFields["native-browser-address"].firstMatch
        XCTAssertTrue(address.exists); address.tap(); address.typeText("fixture")
        let historySuggestion = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-browser-suggestion-", "Local fixture history")).firstMatch
        XCTAssertTrue(historySuggestion.waitForExistence(timeout: 8), app.debugDescription)
        capture("Native browser address suggestions and long title")
        app.buttons["native-browser-address-cancel"].tap()

        browserMenu(app).tap(); app.buttons["native-browser-show-find"].tap()
        let find = app.textFields["native-browser-find"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.tap(); find.typeText("Bandal needle")
        expectLabel("native-browser-find-count", contains: "1 / 3", app: app)
        app.buttons["native-browser-find-next"].tap()
        expectLabel("native-browser-find-count", contains: "2 / 3", app: app)
        app.buttons["native-browser-find-previous"].tap()
        expectLabel("native-browser-find-count", contains: "1 / 3", app: app)
        app.buttons["native-browser-find-close"].tap()
        browserMenu(app).tap(); app.buttons["native-browser-show-find"].tap()
        XCTAssertEqual(find.value as? String, "Bandal needle")
        expectLabel("native-browser-find-count", contains: "1 / 3", app: app)
        app.buttons["native-browser-find-next"].tap()
        expectLabel("native-browser-find-count", contains: "2 / 3", app: app)
        app.buttons["native-browser-find-close"].tap()
        browserMenu(app).tap(); app.buttons["native-browser-zoom-menu"].tap(); app.buttons["native-browser-zoom-in"].tap()
        let zoom = app.buttons["native-browser-zoom-reset"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 5)); XCTAssertTrue(zoom.label.contains("120"), zoom.label)
        capture("Native browser local search and zoom")
        zoom.tap(); XCTAssertFalse(zoom.exists)

        let download = page.buttons["Download local fixture"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), app.debugDescription); download.tap()
        browserMenu(app).tap(); app.buttons["native-browser-downloads-button"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["browser-fixture.txt"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["native-browser-download-open"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture("Native browser local download completed")
        app.buttons["완료"].firstMatch.tap()

        let profile = app.buttons["native-browser-profile"].firstMatch
        profile.tap(); app.buttons["native-browser-new-profile"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Local study")
        app.buttons["만들기"].tap()
        let profileChanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Local study"), object: profile)
        XCTAssertEqual(XCTWaiter.wait(for: [profileChanged], timeout: 15), .completed, app.debugDescription)
        profile.tap(); app.buttons["native-browser-private-toggle"].tap()
        let privateMode = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "개인정보 보호"), object: profile)
        XCTAssertEqual(XCTWaiter.wait(for: [privateMode], timeout: 15), .completed, app.debugDescription)
        browserMenu(app).tap(); app.buttons["native-browser-downloads-button"].firstMatch.tap()
        let privateDownloads = app.otherElements["native-browser-downloads"].firstMatch
        XCTAssertTrue(privateDownloads.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(privateDownloads.staticTexts["다운로드가 없습니다"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        // The normal download is also an imported material in the sidebar.
        // Assert isolation inside the private download sheet, not the whole app.
        XCTAssertFalse(privateDownloads.staticTexts["browser-fixture.txt"].firstMatch.exists, privateDownloads.debugDescription)
        app.buttons["완료"].firstMatch.tap()
        capture("Native browser private profile has isolated downloads")
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty, app.debugDescription)
    }
    @MainActor private func browserMenu(_ app: XCUIApplication) -> XCUIElement { app.buttons["native-browser-menu"].firstMatch }
    @MainActor private func expectLabel(_ identifier: String, contains value: String, app: XCUIApplication) {
        let element = app.staticTexts[identifier].firstMatch
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
