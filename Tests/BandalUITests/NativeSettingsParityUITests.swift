import XCTest

final class NativeSettingsParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSchoolSelectionAppearsAboveCoursesAndSurvivesRestart() {
        let app = launch()
        app.buttons["native-university-choose"].tap()
        let search = app.textFields["native-settings-university-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap(); search.typeText("SNU")
        let school = app.buttons["native-settings-university-snu"]
        XCTAssertTrue(school.waitForExistence(timeout: 5)); school.tap()
        XCTAssertTrue(app.buttons["선택 해제"].waitForExistence(timeout: 10))
        app.buttons["native-section-library"].tap()
        let heading = app.buttons["native-university-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(heading.label.contains("서울대학교"))
        let portal = app.buttons["native-university-service-snu.portal"]
        XCTAssertTrue(portal.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["native-ai-web-chatgpt"].exists)
        capture("Configured university shortcuts above courses")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(portal.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(heading.label.contains("서울대학교"))
    }

    @MainActor
    func testSettingsSearchFindsDesktopCategoriesAndKeepsControlsUsableAfterRotation() {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let search = app.textFields["native-settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap(); search.typeText("시스템 권한")
        let permissions = app.buttons["native-settings-category-permissions"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 5)); permissions.tap()
        XCTAssertTrue(app.buttons["시스템 설정 열기"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        search.tap()
        let existing = search.value as? String ?? ""
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        search.typeText("글자 크기")
        app.buttons["native-settings-category-appearance"].tap()
        XCTAssertTrue(app.buttons["native-settings-theme-system"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["native-settings-theme-system"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["native-settings-theme-dark"].isHittable, app.debugDescription)
        capture("Native desktop settings in portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    @MainActor
    func testSettingsThemePersistsAndTwentyCategoryNavigationRemainsNative() {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let dark = app.buttons["native-settings-theme-dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 10)); dark.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: dark)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        capture("Native twenty category settings")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["native-section-settings"].waitForExistence(timeout: 20)); app.buttons["native-section-settings"].tap()
        XCTAssertTrue(dark.waitForExistence(timeout: 10)); XCTAssertTrue(dark.isSelected)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testTwoDockedBrowsersKeepLocalWebsiteInputsIndependent() {
        let app = launch(extra: ["--native-browser-ui-fixture"])
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Browser Docking")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch.tap()
        app.buttons["native-new-tab-new-browser"].tap()
        let firstInput = app.webViews.firstMatch.textFields["Website input"]
        XCTAssertTrue(firstInput.waitForExistence(timeout: 15)); firstInput.tap(); firstInput.typeText("Left draft")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch.tap()
        app.buttons["native-new-tab-new-browser"].tap()
        let secondInput = app.webViews.firstMatch.textFields["Website input"]
        XCTAssertTrue(secondInput.waitForExistence(timeout: 15)); secondInput.tap(); secondInput.typeText("Right draft")
        app.buttons["native-open-documents"].tap()
        app.buttons["native-dock-preset-columns"].tap()
        // WebKit exposes nested WebView accessibility nodes for one website.
        // Count the native page containers, whose stable IDs identify ownership.
        let pages = app.webViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "desktop-browser-native-scope."))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pages.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed, app.debugDescription)
        let values = pages.allElementsBoundByIndex.map { $0.textFields["Website input"].value as? String ?? "" }
        XCTAssertEqual(Set(values), Set(["Left draft", "Right draft"]))
        capture("Two independent native browser panes")
        app.buttons["native-open-documents"].tap(); app.buttons["native-dock-preset-single"].tap()
        XCTAssertEqual(pages.count, 1)
        let retained = pages.firstMatch.textFields["Website input"].value as? String ?? ""
        XCTAssertTrue(["Left draft", "Right draft"].contains(retained))
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra; app.launch()
        XCTAssertTrue(app.buttons["native-section-settings"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    @MainActor private func capture(_ title: String) { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item) }
}
