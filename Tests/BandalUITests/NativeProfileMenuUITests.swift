import XCTest

/// 1.4.0: the rail's profile button. Signed out it offers sign-in in place; signed in it shows
/// email, name · plan and 설정 / 사용량 / 도움말 (화면 도우미 · 문서 · 문의하기) / 플랜 보기 / 로그아웃.
final class NativeProfileMenuUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testSignedOutOffersSignInInPlace() {
        let app = launch([])
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(account.label, "로그인")
        account.tap()
        XCTAssertTrue(app.buttons["native-account-apple"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["native-account-google"].exists)
        XCTAssertFalse(app.buttons["native-section-settings"].isSelected, "No detour through Settings")
    }

    @MainActor func testSignedInMenuShowsPlanAndOpensUsageAndHelp() {
        let app = launch(["--native-account-fixture"])
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription)
        account.tap()
        let plan = app.staticTexts["native-account-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(plan.label, "서준 · 무료")
        XCTAssertTrue(app.staticTexts["seojun@bandal.io"].exists)
        for id in ["native-account-app-settings", "native-account-usage", "native-account-help", "native-account-plans", "native-account-sign-out"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        app.buttons["native-account-help"].tap()
        XCTAssertTrue(app.buttons["native-help-guide"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["native-help-docs"].exists && app.buttons["native-help-contact"].exists)
        app.buttons["native-help-guide"].tap()
        XCTAssertTrue(app.staticTexts["도움말"].waitForExistence(timeout: 5), "화면 도우미 opens the help page")

        account.tap()
        XCTAssertTrue(app.buttons["native-account-usage"].waitForExistence(timeout: 5)); app.buttons["native-account-usage"].tap()
        XCTAssertTrue(app.buttons["native-settings-category-subscription"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-settings-category-subscription"].isSelected)
    }

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        return app
    }
}
