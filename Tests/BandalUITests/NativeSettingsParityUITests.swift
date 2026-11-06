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

    /// Login is optional: the workspace opens without it and only Apple and Google remain.
    @MainActor
    func testAccountIsOptionalAndOffersOnlyAppleAndGoogle() {
        let app = launch()
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["native-section-library"].isHittable)
        account.tap()
        XCTAssertTrue(app.buttons["Apple로 로그인"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Google로 로그인"].exists)
        XCTAssertFalse(app.buttons["카카오로 로그인"].exists)
        capture("Optional account sign-in")
    }

    @MainActor
    func testSettingsSearchFindsDesktopCategoriesAndKeepsControlsUsableAfterRotation() {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let search = app.textFields["native-settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap(); search.typeText("알림")
        let general = app.buttons["native-settings-category-general"]
        XCTAssertTrue(general.waitForExistence(timeout: 5)); general.tap()
        XCTAssertTrue(app.switches["native-settings-notifications-enabled"].waitForExistence(timeout: 10), app.debugDescription)
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
        let appearance = app.buttons["native-settings-category-appearance"]
        select(appearance)
        let dark = app.buttons["native-settings-theme-dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 10)); dark.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: dark)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        capture("Native twenty category settings")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["native-section-settings"].waitForExistence(timeout: 20)); app.buttons["native-section-settings"].tap()
        select(appearance)
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

    /// Settings › 동기화 asks for nothing but iCloud: no login, no subscription. Without an iCloud
    /// account (a fresh simulator) turning it on explains how to sign in instead of connecting.
    @MainActor
    func testSyncSettingsOfferICloudWithoutLogin() {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-sync"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        let provider = app.segmentedControls["native-sync-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textFields["native-sync-device-name"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '로그인하면'")).firstMatch.exists)
        capture("Sync settings, off")
        provider.buttons["iCloud"].tap()
        XCTAssertTrue(app.buttons["설정 열기"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(provider.buttons["끔"].isSelected)
        capture("Sync settings without an iCloud account")
    }

    /// Spec v2.7: while sync is on, the other storage is reached by moving; disconnecting waits under 고급.
    @MainActor
    func testSyncSettingsWhileOnOfferAMoveAndFoldDisconnectUnderAdvanced() {
        let app = launch(extra: ["-BandalCloudSync", "icloud"])
        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-sync"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        XCTAssertTrue(app.buttons["native-sync-move"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["native-sync-disconnect"].exists, "folded under 고급")
        capture("Sync settings, on: moving")
        // Not the 고급 settings category in the sidebar.
        app.buttons.matching(NSPredicate(format: "label == '고급' AND identifier != 'native-settings-category-advanced'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["native-sync-disconnect"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Sync settings, on: advanced")
    }

    /// 1.4.0: seven sections, Cursor-like; old pages live inside them and AI shows a sign-in banner.
    @MainActor
    func testSevenSectionsHoldTheOldPages() {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let ids = ["general", "appearance", "account", "subscription", "ai", "sync", "integrations"]
        for id in ids { XCTAssertTrue(app.buttons["native-settings-category-" + id].waitForExistence(timeout: 10), id) }
        let all = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-settings-category-'"))
        XCTAssertEqual(all.count, ids.count, app.debugDescription)
        XCTAssertTrue(app.buttons["native-settings-category-general"].isSelected, "Settings opens on 일반")
        XCTAssertTrue(app.switches["native-settings-notifications-enabled"].exists, "알림 lives in 일반")
        XCTAssertTrue(app.buttons["native-settings-reset"].exists, "고급 lives in 일반")
        app.buttons["native-settings-category-account"].tap()
        XCTAssertTrue(app.textFields["native-settings-university-search"].waitForExistence(timeout: 10), "학교 lives in 계정")
        app.buttons["native-settings-category-ai"].tap()
        XCTAssertTrue(app.staticTexts["native-ai-summary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["native-ai-summary"].label, "로그인하면 바로 쓸 수 있어요")
        XCTAssertTrue(app.links["native-ai-fair-use"].exists || app.buttons["native-ai-fair-use"].exists, app.debugDescription)
        capture("Settings › AI signed out")
        app.buttons["native-settings-category-integrations"].tap()
        XCTAssertTrue(app.staticTexts["APPLE 캘린더"].waitForExistence(timeout: 10), app.debugDescription)
        capture("Settings › 통합")
    }

    /// Settings ignores taps while its first load runs; tap until the section is selected.
    @MainActor private func select(_ category: XCUIElement) {
        XCTAssertTrue(category.waitForExistence(timeout: 15))
        for _ in 0..<5 where !category.isSelected { category.tap(); _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: category)], timeout: 2) }
        XCTAssertTrue(category.isSelected)
    }
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra; app.launch()
        XCTAssertTrue(app.buttons["native-section-settings"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    @MainActor private func capture(_ title: String) { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item) }
}
