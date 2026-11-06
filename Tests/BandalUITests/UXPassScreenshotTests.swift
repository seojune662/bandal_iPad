import XCTest

/// Before/after captures for the 1.4.0 UX pass (popovers, inline rename, rail, model picker, settings).
/// Each test only drives and attaches; the behaviour itself is asserted in the feature tests.
final class UXPassScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testRailSidebarAndCourseMenus() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra")
        attach(app, "01 새 과목")
        app.buttons["native-create-course"].tap()
        sleep(2); attach(app, "02 레일·사이드바")
        let menu = app.buttons["Linear Algebra 과목 메뉴"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap(); app.buttons["이름 변경"].firstMatch.tap(); sleep(1)
            attach(app, "03 과목 이름 변경")
            if app.buttons["취소"].exists { app.buttons["취소"].firstMatch.tap() } else { app.textFields.firstMatch.typeKey(.escape, modifierFlags: []) }
            sleep(1); menu.tap(); app.buttons["과목 보관"].firstMatch.tap(); sleep(1)
            attach(app, "04 과목 보관 확인")
        }
    }

    @MainActor func testAIPanelAndPicker() throws {
        let app = launch(courses: true)
        let toggle = app.buttons["native-section-ai"].exists ? app.buttons["native-section-ai"] : app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
        if toggle.label != "AI 닫기" { toggle.tap() }; sleep(2)
        attach(app, "05 AI 패널")
        let input = app.textFields["native-chat-input"].exists ? app.textFields["native-chat-input"] : app.textViews["native-chat-input"]
        if input.waitForExistence(timeout: 5) { input.tap(); input.typeText("행렬식이 뭐야?") }
        let send = app.buttons["native-chat-send"].exists ? app.buttons["native-chat-send"] : app.buttons["native-ai-connect"]
        if send.waitForExistence(timeout: 5) { send.tap(); sleep(2); attach(app, "06 로그아웃 상태에서 보내기") }
        app.buttons["native-ai-sign-in-dismiss"].firstMatch.tapIfPresent()
        let picker = app.buttons["native-ai-model-pill"].exists ? app.buttons["native-ai-model-pill"] : app.buttons["AI 모델 설정"]
        if picker.waitForExistence(timeout: 5) { picker.tap(); sleep(1); attach(app, "07 모델 선택") }
    }

    @MainActor func testModelPickerWithModels() throws {
        let app = launch(courses: true, extra: ["--native-ai-catalog-fixture"])
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20)); if toggle.label != "AI 닫기" { toggle.tap() }
        let pill = app.buttons["native-ai-model-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), app.debugDescription); pill.tap(); sleep(1)
        attach(app, "14 모델 선택 (목록)")
        app.buttons["native-ai-model-claude-sonnet-5-5"].tap(); sleep(1)
        XCTAssertEqual(pill.label, "AI 모델: Sonnet 5.5 · medium")
        pill.tap(); sleep(1)
        attach(app, "15 모델 선택 (Sonnet · effort)")
    }

    @MainActor func testProfileAndHelp() throws {
        let app = launch(courses: true)
        let account = app.buttons["native-section-account"]
        if account.waitForExistence(timeout: 20) { account.tap(); sleep(2); attach(app, "08 프로필 (로그아웃)") }
        let signedIn = launch(courses: true, extra: ["--native-account-fixture"])
        let button = signedIn.buttons["native-section-account"]
        if button.waitForExistence(timeout: 20) { button.tap(); sleep(1); attach(signedIn, "09 프로필 (로그인)") }
        let help = signedIn.buttons["native-account-help"]
        if help.waitForExistence(timeout: 3) { help.tap(); sleep(1); attach(signedIn, "10 도움말 서브메뉴") }
        else if signedIn.buttons["native-section-help"].exists { signedIn.buttons["native-section-help"].tap(); sleep(1); attach(signedIn, "10 도움말") }
    }

    @MainActor func testSettingsPages() throws {
        let app = launch(courses: true)
        app.buttons["native-section-settings"].tap()
        for (id, title) in [("general", "11 설정 일반"), ("ai", "12 설정 AI"), ("subscription", "13 설정 구독")] {
            let row = app.buttons["native-settings-category-" + id]
            if row.waitForExistence(timeout: 10) { row.tap(); sleep(1); attach(app, title) }
        }
    }

    @MainActor private func launch(courses: Bool = false, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        guard courses, app.buttons["native-course-add-menu"].waitForExistence(timeout: 25) else { return app }
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        if name.waitForExistence(timeout: 5) { name.tap(); name.typeText("Linear Algebra"); app.buttons["native-create-course"].tap() }
        sleep(1)
        return app
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}

private extension XCUIElement {
    func tapIfPresent() { if exists && isHittable { tap() } }
}
