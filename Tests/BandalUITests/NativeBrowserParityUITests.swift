import XCTest

/// Native chrome and WKWebView behavior use inline local HTML by default. The
/// opt-in live smoke test also captures the real Google default homepage.
final class NativeBrowserParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLiveDefaultGoogleHomePage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_VERIFY_LIVE_BROWSER_HOME"] == "1",
                          "Set BANDAL_VERIFY_LIVE_BROWSER_HOME=1 to verify the real network homepage.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25)); addCourse.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Live Google browser")
        app.buttons["native-create-course"].tap()
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "The default browser must create a real WKWebView.")
        let address = app.textFields["native-browser-address"].firstMatch
        let requestedHome = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "google.com"), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [requestedHome], timeout: 15), .completed, "The unconfigured browser should request google.com.\n" + app.debugDescription)

        // Google's logo may be a seasonal doodle. Its actual search control or
        // search action remains accessible in either English or Korean.
        let searchControls = page.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Search", "검색", "Google Search", "Google 검색"]))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            searchControls.allElementsBoundByIndex.contains { $0.isHittable }
                && app.buttons["native-browser-reload"].firstMatch.label == "새로고침"
        }, object: nil)
        let result = XCTWaiter.wait(for: [loaded], timeout: 45)
        capture(result == .completed ? "Live Google homepage in the desktop browser" : "Live Google homepage failed to load")
        XCTAssertEqual(result, .completed,
                       "Live Google did not become usable. Check simulator network access, Google consent/CAPTCHA, or page loading before accepting this smoke test.\n" + app.debugDescription)
        XCTAssertFalse(app.otherElements["native-browser-start-page"].exists)
        XCTAssertFalse(page.staticTexts["Native browser fixture"].exists)
    }

    @MainActor
    func testBrowserShowsWebContentAndKeepsNavigationVisibleInTwoColumns() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25)); addCourse.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Desktop browser")
        app.buttons["native-create-course"].tap()
        for count in 1...2 {
            let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
            let page = app.webViews.staticTexts["Native browser fixture"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 15), app.debugDescription)
            if count == 1 {
                XCTAssertFalse(app.staticTexts["웹에서 학습을 이어가세요"].exists)
                XCTAssertFalse(app.otherElements["native-browser-start-page"].exists)
                XCTAssertTrue(app.buttons["native-browser-reload"].isHittable)
                capture("Browser opens a real web view under the compact desktop toolbar")
            }
        }
        let courseRail = app.buttons["native-section-library"]
        if courseRail.isSelected { courseRail.tap() }
        let materials = app.buttons["native-toggle-materials-rail"]
        if materials.isSelected { materials.tap() }
        app.buttons["native-open-documents"].tap()
        app.buttons["native-dock-preset-columns"].tap()
        let split = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.textFields.matching(identifier: "native-browser-address").allElementsBoundByIndex.filter { $0.isHittable }.count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [split], timeout: 15), .completed, app.debugDescription)
        let fields = app.textFields.matching(identifier: "native-browser-address").allElementsBoundByIndex.filter { $0.isHittable }
        for field in fields {
            XCTAssertGreaterThan(field.frame.width, 90, "The split browser needs a usable address field")
            XCTAssertLessThanOrEqual(field.frame.height, 44)
        }
        for identifier in ["native-browser-back", "native-browser-forward", "native-browser-reload", "native-browser-menu"] {
            let buttons = app.buttons.matching(identifier: identifier).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertEqual(buttons.count, 2, "Both panes must retain \(identifier)")
            for button in buttons { XCTAssertGreaterThanOrEqual(button.frame.height, 44) }
        }
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "Native browser fixture")).allElementsBoundByIndex.filter { $0.isHittable }.count, 2)
        capture("Two desktop browser panes retain back forward reload and the address field")
    }

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
        let downloads = openDownloads(app)
        XCTAssertTrue(downloads.staticTexts["browser-fixture.txt"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(downloads.buttons["native-browser-download-open"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
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
        let privateDownloads = openDownloads(app)
        XCTAssertTrue(privateDownloads.staticTexts["다운로드가 없습니다"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        // The normal download is also an imported material in the sidebar.
        // Assert isolation inside the private download sheet, not the whole app.
        XCTAssertFalse(privateDownloads.staticTexts["browser-fixture.txt"].firstMatch.exists, privateDownloads.debugDescription)
        app.buttons["완료"].firstMatch.tap()
        capture("Native browser private profile has isolated downloads")
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty, app.debugDescription)
    }
    @MainActor private func openDownloads(_ app: XCUIApplication) -> XCUIElement {
        browserMenu(app).tap()
        let item = app.buttons["native-browser-downloads-menu-item"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item.isHittable, app.debugDescription)
        item.tap()
        let sheet = app.otherElements["native-browser-downloads"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        return sheet
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
