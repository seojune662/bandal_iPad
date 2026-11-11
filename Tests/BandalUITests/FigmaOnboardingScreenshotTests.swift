import XCTest

/// Captures for the side-by-side comparison with the Figma onboarding (254:8303), school picker
/// (257:8299) and English (258:8327) frames. Each test only drives and attaches; behaviour is
/// asserted in `NativeOnboardingUITests`.
final class FigmaOnboardingScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testOnboardingLight() { onboarding("light", english: false) }
    @MainActor func testOnboardingDark() { onboarding("dark", english: false) }
    @MainActor func testOnboardingEnglishLight() { onboarding("light", english: true) }
    @MainActor func testOnboardingEnglishDark() { onboarding("dark", english: true) }
    @MainActor func testPickerLight() { picker("light") }
    @MainActor func testPickerDark() { picker("dark") }

    @MainActor private func onboarding(_ appearance: String, english: Bool) {
        let app = launch(["--native-onboarding", "-native.appearance", appearance])
        let next = app.buttons["native-onboarding-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 25), app.debugDescription)
        if english { app.buttons["native-onboarding-language-en-US"].tap(); XCTAssertTrue(app.staticTexts["Welcome to Bandal"].waitForExistence(timeout: 5)) }
        let prefix = appearance + (english ? " E" : " O")
        sleep(1); attach(app, prefix + "1")
        next.tap()
        let search = app.textFields["native-school-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap(); search.typeText(english ? "Seoul" : "서울")
        let school = app.buttons["native-school-result-snu"]
        XCTAssertTrue(school.waitForExistence(timeout: 5), app.debugDescription); school.tap()
        sleep(1); attach(app, prefix + "2")
        next.tap()
        let skip = app.buttons["native-referral-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1); attach(app, prefix + "2b invite")
        skip.tap()
        XCTAssertTrue(app.buttons["native-onboarding-finish"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(1); attach(app, prefix + "3")
        if english { app.buttons["native-onboarding-back"].tap(); app.buttons["native-onboarding-back"].tap(); app.buttons["native-onboarding-back"].tap(); app.buttons["native-onboarding-language-ko-KR"].tap() }
    }

    @MainActor private func picker(_ appearance: String) {
        // One AI search already used today: a search that finds nothing offers "오늘 2번 남음".
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        let app = launch(["-native.appearance", appearance, "-native.school.aiSearches", today + ":1"])
        let choose = app.buttons["native-university-choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 25), app.debugDescription); choose.tap()
        let search = app.textFields["native-school-search"], ai = app.buttons["native-school-ai"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        type("서울", into: search, app: app)
        XCTAssertTrue(app.buttons["native-school-result-snu"].waitForExistence(timeout: 5)); sleep(1)
        attach(app, appearance + " S1")
        type("반달대학교", into: search, app: app)
        XCTAssertTrue(ai.waitForExistence(timeout: 5), app.debugDescription); sleep(1)
        attach(app, appearance + " S2")
        type("느린대학교", into: search, app: app)
        XCTAssertTrue(ai.waitForExistence(timeout: 5)); ai.tap()
        XCTAssertTrue(app.staticTexts["native-school-finding"].waitForExistence(timeout: 5), app.debugDescription); sleep(1)
        attach(app, appearance + " S3")
        XCTAssertTrue(app.buttons["native-school-wait"].waitForExistence(timeout: 25), app.debugDescription); sleep(1)
        attach(app, appearance + " S3 slow")
        app.buttons["native-school-stop"].tap()
        type("반달대학교", into: search, app: app)
        XCTAssertTrue(ai.waitForExistence(timeout: 5)); ai.tap()
        XCTAssertTrue(app.buttons["native-school-confirm"].waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        attach(app, appearance + " S4")
        app.buttons["native-school-back"].tap()
        type("없는대학교", into: search, app: app)
        XCTAssertTrue(ai.waitForExistence(timeout: 5)); ai.tap()
        XCTAssertTrue(app.staticTexts["native-school-not-found"].waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        attach(app, appearance + " S5")
        app.buttons["native-school-close"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); sleep(1); choose.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        type("한도대학교", into: search, app: app)
        XCTAssertTrue(ai.waitForExistence(timeout: 5)); ai.tap()
        XCTAssertTrue(app.staticTexts["native-school-notice"].waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        attach(app, appearance + " S5 limit")
    }

    @MainActor private func type(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let clear = app.buttons["지우기"]
        if clear.exists { clear.tap() }
        field.tap(); field.typeText(text)
    }
    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-school-fixture"] + extra + ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        return app
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
