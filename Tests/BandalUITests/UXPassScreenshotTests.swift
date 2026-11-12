import XCTest

/// Before/after captures for the 1.4.0 UX pass (popovers, inline rename, rail, model picker, settings).
/// Each test only drives and attaches; the behaviour itself is asserted in the feature tests.
final class UXPassScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testRailSidebarAndCourseMenus() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra")
        attach(app, "01 새 과목")
        app.buttons["native-create-course"].tap()
        sleep(2); attach(app, "02 레일·사이드바")
        let menu = app.buttons["Linear Algebra 폴더 메뉴"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap(); app.buttons["이름 변경"].firstMatch.tap(); sleep(1)
            attach(app, "03 과목 이름 변경")
            if app.buttons["취소"].exists { app.buttons["취소"].firstMatch.tap() } else { app.textFields.firstMatch.typeKey(.escape, modifierFlags: []) }
            sleep(1); menu.tap(); app.buttons["폴더 보관"].firstMatch.tap(); sleep(1)
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

    @MainActor func testSheetsBecomePopovers() throws {
        let app = launch(courses: true)
        let create = app.buttons["native-library-create"]
        if create.waitForExistence(timeout: 15) {
            create.tap(); app.buttons["새 노트"].firstMatch.tap(); sleep(1); attach(app, "16 새 노트")
            dismiss(app)
            create.tap(); app.buttons["새 폴더"].firstMatch.tap(); sleep(1); attach(app, "17 새 폴더")
            dismiss(app)
        }
        app.buttons["native-course-add-menu"].press(forDuration: 1); app.buttons["폴더 관리"].firstMatch.tap(); sleep(1); attach(app, "18 폴더 관리")
        dismiss(app)
        app.buttons["native-section-planner"].tap()
        let add = app.buttons["native-task-add"]
        if add.waitForExistence(timeout: 10) { add.tap(); sleep(1); attach(app, "19 할 일 추가") }
    }

    @MainActor private func dismiss(_ app: XCUIApplication) {
        if app.buttons["취소"].exists { app.buttons["취소"].firstMatch.tap() }
        else if app.buttons["완료"].exists { app.buttons["완료"].firstMatch.tap() }
        else { app.closeBandalPopover() }
        sleep(1)
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

    /// The window's glass: rail, sidebar, tab strip, paper and the right panel over the backdrop, then the AI panel.
    @MainActor func testGlassChromeLight() throws { try glassChrome(appearance: "light") }
    @MainActor func testGlassChromeDark() throws { try glassChrome(appearance: "dark") }
    @MainActor private func glassChrome(appearance: String) throws {
        let app = launch(courses: true, extra: ["-native.appearance", appearance], orientation: .landscapeLeft)
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription); create.tap(); app.buttons["새 노트"].firstMatch.tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("3주차 리서치 노트"); app.buttons["native-new-note-create"].tap()
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].waitForExistence(timeout: 20), app.debugDescription)
        sleep(2); attach(app, "glass 01 메인 \(appearance)")
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.tap(); sleep(2)
        attach(app, "glass 02 AI 패널 \(appearance)")
    }

    @MainActor private func launch(courses: Bool = false, extra: [String] = [], orientation: UIDeviceOrientation = .portrait) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        guard courses, app.buttons["native-course-add-menu"].waitForExistence(timeout: 25) else { return app }
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        if name.waitForExistence(timeout: 5) { name.tap(); name.typeText("Linear Algebra"); app.buttons["native-create-course"].tap() }
        sleep(1)
        return app
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: name.hasPrefix("glass") ? app.windows.firstMatch.screenshot() : app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}

private extension XCUIElement {
    func tapIfPresent() { if exists && isHittable { tap() } }
}
