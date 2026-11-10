import XCTest

/// First-run onboarding and the school picker. `--native-onboarding` lets a UI test see onboarding at
/// all; `--native-school-fixture` puts a fake directory behind the picker, so no server or account is used.
final class NativeOnboardingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// 언어 → 학교 (search, AI result, edited links) → 완료 → home, in light and in dark.
    @MainActor
    func testOnboardingWalksLanguageSchoolAndDoneInLightAndDark() {
        for name in ["light", "dark"] {
            // The app's own theme setting, as a launch default.
            let theme = ["-native.appearance", name]
            let app = launch(["--native-onboarding", "--native-school-fixture"] + theme)

            // 1. 언어: the device's language is picked, and the other one applies at once.
            let korean = app.buttons["native-onboarding-language-ko-KR"], english = app.buttons["native-onboarding-language-en-US"]
            XCTAssertTrue(korean.waitForExistence(timeout: 25), app.debugDescription)
            XCTAssertTrue(korean.isSelected); XCTAssertFalse(english.isSelected)
            XCTAssertTrue(app.staticTexts["반달에 오신 걸 환영해요"].exists)
            XCTAssertFalse(app.buttons["native-section-settings"].isHittable, "Onboarding covers the workspace")
            XCTAssertEqual(app.navigationBars.count, 0, "Our own chrome: no system navigation bar")
            capture("1 언어 (\(name))")
            english.tap()
            XCTAssertTrue(app.staticTexts["Welcome to Bandal"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(english.isSelected)
            XCTAssertEqual(app.buttons["native-onboarding-next"].label, "Next step")
            XCTAssertEqual(app.buttons["native-onboarding-later"].label, "Set up later")
            capture("1 Language in English (\(name))")
            if name == "light" {
                // The picker follows the language too.
                app.buttons["native-onboarding-next"].tap()
                XCTAssertTrue(app.staticTexts["Which school do you go to?"].waitForExistence(timeout: 5), app.debugDescription)
                let search = app.textFields["native-school-search"]
                XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertEqual(search.placeholderValue, "Search by school name")
                search.tap(); search.typeText("Bandal")
                XCTAssertTrue(app.buttons["Find with AI"].waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(app.buttons["Enter it myself"].exists)
                capture("2 School in English (\(name))")
                app.buttons["native-onboarding-back"].tap()
                // On a small iPad the keyboard that is leaving still covers the language cards.
                XCTAssertTrue(waitForAbsence(app.keyboards.firstMatch), "Leaving the search field puts the keyboard away")
            }
            korean.tap()
            XCTAssertTrue(app.staticTexts["반달에 오신 걸 환영해요"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["native-onboarding-next"].tap()

            // 2. 학교: the bundled list first, then a search.
            let search = app.textFields["native-school-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["다니는 학교를 알려 주세요"].exists)
            XCTAssertTrue(app.buttons["native-school-result-snu"].waitForExistence(timeout: 5), "Korea starts on the bundled schools")
            XCTAssertTrue(app.buttons["native-school-country"].label.contains("대한민국"), "The chip starts on the device's region")
            capture("2 학교 (\(name))")
            search.tap(); search.typeText("서울")
            XCTAssertTrue(app.buttons["native-school-result-snu"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["native-school-result-yonsei"].exists)
            XCTAssertTrue(app.buttons["native-school-ai"].waitForExistence(timeout: 5), "AI and 직접 입력 stay within reach")
            capture("2 학교 검색 (\(name))")

            // No match → AI. A search that takes long says so, and can be stopped.
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "느린대학교")
            XCTAssertTrue(app.staticTexts["native-school-no-match"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["native-school-manual"].exists)
            capture("2 학교 없음 (\(name))")
            app.buttons["native-school-ai"].tap()
            let finding = app.staticTexts["native-school-finding"]
            XCTAssertTrue(finding.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(finding.label, "느린대학교 사이트를 찾는 중…")
            if name == "light" {
                XCTAssertFalse(app.staticTexts["native-school-slow"].exists)
                XCTAssertTrue(app.staticTexts["native-school-slow"].waitForExistence(timeout: 25), "조금 더 걸려요 after 15 s")
            }
            capture("AI로 찾는 중 (\(name))")
            app.buttons["native-school-stop"].tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(search.value as? String, "느린대학교", "Stopping goes back to what was typed")

            // The links to confirm.
            search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "반달대학교")
            XCTAssertTrue(app.buttons["native-school-ai"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["native-school-ai"].tap()
            let confirm = app.buttons["native-school-confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(app.staticTexts["native-school-found-name"].label, "반달대학교")
            XCTAssertEqual(app.staticTexts["native-school-unverified"].label, "AI가 찾은 정보 · 검토 전")
            for id in ["home", "portal", "lms", "library"] { XCTAssertTrue(app.buttons["native-school-link-edit-" + id].exists, id) }
            XCTAssertTrue(app.staticTexts["https://lms.bandal.example"].exists)
            capture("AI 결과 확인 (\(name))")
            if name == "light" {
                // A row left open, then back to the search and the same school again: the new result is not stuck behind it.
                app.buttons["native-school-link-add"].tap()
                XCTAssertTrue(app.textFields["native-school-link-title"].waitForExistence(timeout: 5), app.debugDescription)
                app.buttons["native-school-back"].tap()
                XCTAssertTrue(app.buttons["native-school-ai"].waitForExistence(timeout: 5), app.debugDescription)
                app.buttons["native-school-ai"].tap()
                XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertFalse(app.textFields["native-school-link-title"].exists)
            }

            // Inline edit, delete and add.
            app.buttons["native-school-link-edit-lms"].tap()
            let title = app.textFields["native-school-link-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
            title.tap(); title.typeText(" LMS")
            app.buttons["native-school-link-done"].tap()
            XCTAssertTrue(app.staticTexts["강의실 LMS"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["native-school-link-delete-library"].tap()
            XCTAssertFalse(app.buttons["native-school-link-edit-library"].exists)
            app.buttons["native-school-link-add"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("학사일정")
            let address = app.textFields["native-school-link-url"]
            address.tap(); address.typeText("bandal")
            confirm.tap()
            XCTAssertTrue(app.staticTexts["이름과 웹 주소를 확인해 주세요."].waitForExistence(timeout: 5), "A link without a real address is not saved")
            address.tap(); address.typeText(".example/calendar")
            capture("AI 결과 편집 (\(name))")
            confirm.tap()

            // 3. 완료, then home with the school in the sidebar.
            let finish = app.buttons["native-onboarding-finish"]
            XCTAssertTrue(finish.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["준비됐어요"].exists)
            XCTAssertFalse(app.buttons["native-onboarding-later"].exists, "Nothing left to put off")
            capture("3 완료 (\(name))")
            finish.tap()
            let heading = app.buttons["native-university-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(heading.label.contains("반달대학교"))
            XCTAssertFalse(finish.exists)
            XCTAssertTrue(app.buttons["native-section-settings"].isHittable)
            XCTAssertTrue(app.buttons["native-university-service-custom:fixture-school:lms"].label.contains("강의실 LMS"), "The edit is in this user's settings")
            XCTAssertFalse(app.buttons["native-university-service-custom:fixture-school:library"].exists)
            XCTAssertFalse(app.buttons["native-university-find-links"].exists)
            capture("홈 (\(name))")

            // Shown once.
            app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-onboarding", "--native-school-fixture"] + theme + Self.korean; app.launch()
            XCTAssertTrue(heading.waitForExistence(timeout: 25), app.debugDescription)
            XCTAssertTrue(app.buttons["native-section-settings"].isHittable); XCTAssertFalse(korean.exists)
            app.terminate()
        }
    }

    /// "나중에" leaves at once; the sidebar then has the same picker. Signed out, AI asks to sign in
    /// right there, and 직접 입력 saves the name alone, which the sidebar offers to complete with AI.
    @MainActor
    func testLaterSkipsAndTheSidebarPickerOffersSignInForAIAndTheNameAlone() {
        let app = launch(["--native-onboarding"])
        let later = app.buttons["native-onboarding-later"]
        XCTAssertTrue(later.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(later.label, "첫 설정 나중에 하기")
        later.tap()
        let choose = app.buttons["native-university-choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-section-settings"].isHittable); XCTAssertFalse(later.exists)

        choose.tap()
        let search = app.textFields["native-school-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap(); search.typeText("반달예술대")
        XCTAssertTrue(app.staticTexts["native-school-offline"].waitForExistence(timeout: 15), "No server in tests: the bundled list answers, quietly")
        XCTAssertTrue(app.staticTexts["native-school-no-match"].exists)
        capture("사이드바 학교 고르기: 오프라인, 없음")
        app.buttons["native-school-ai"].tap()
        let apple = app.buttons["native-school-sign-in-apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["AI로 찾으려면 로그인이 필요해요"].exists)
        XCTAssertTrue(app.buttons["native-school-sign-in-google"].exists)
        capture("AI로 찾기: 로그인")
        // Tapping the picker outside the prompt closes only the prompt.
        search.tap()
        XCTAssertTrue(waitForAbsence(apple), app.debugDescription)

        app.buttons["native-school-manual"].tap()
        let name = app.textFields["native-school-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(name.value as? String, "반달예술대", "직접 입력 starts from what was typed")
        name.tap(); name.typeText("학교")
        capture("직접 입력")
        app.buttons["native-school-name-submit"].tap()
        let heading = app.buttons["native-university-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(heading.label.contains("반달예술대학교"))
        XCTAssertTrue(waitForAbsence(search), "Saving ends the picker")

        // A school with a name only: the sidebar offers the AI search, which opens the same flow.
        let findLinks = app.buttons["native-university-find-links"]
        XCTAssertTrue(findLinks.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(findLinks.label, "AI로 링크 찾기")
        capture("사이드바: AI로 링크 찾기")
        findLinks.tap()
        XCTAssertTrue(apple.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["native-school-search"].value as? String, "반달예술대학교")
    }

    /// Someone who already has a course is an existing user: the first launch that could show onboarding does not.
    @MainActor
    func testSomeoneWhoAlreadyHasACourseNeverSeesOnboarding() {
        let app = launch([])
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
        add.tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        // Return creates the course. Tapping 만들기 did not on an iPad mini in landscape (why was not looked into).
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Physics\n")
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 15), app.debugDescription)

        app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-onboarding"] + Self.korean; app.launch()
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(wait(for: settings) { $0.isHittable }, "The workspace is uncovered once the store has answered")
        XCTAssertFalse(app.buttons["native-onboarding-later"].exists)
        XCTAssertTrue(app.buttons["native-university-choose"].exists, "No school yet, and still no onboarding")
    }

    /// 설정 › 일반 › 언어 switches the app at once, and 계정 › 학교 opens the same picker with a country chip.
    @MainActor
    func testSettingsLanguageAppliesAtOnceAndSettingsHostsThePicker() {
        let app = launch(["--native-school-fixture"])
        let choose = app.buttons["native-university-choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(app.buttons["native-onboarding-later"].exists, "Tests that did not ask never see onboarding")
        XCTAssertEqual(choose.label, "학교 고르기")
        app.buttons["native-section-settings"].tap()
        let language = app.buttons["native-settings-locale"]
        XCTAssertTrue(language.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !app.buttons["English"].exists { language.tap(); _ = app.buttons["English"].waitForExistence(timeout: 2) }
        app.buttons["English"].tap()
        XCTAssertTrue(wait(for: choose) { $0.label == "Choose school" }, "The sidebar behind Settings is already in English: " + choose.label)

        app.buttons["native-settings-category-account"].tap()
        let pick = app.buttons["native-settings-school-choose"]
        XCTAssertTrue(pick.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(pick.label, "Choose my school")
        pick.tap()
        let search = app.textFields["native-school-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        // The country chip: Korea by region, then Japan, then any ISO code.
        let country = app.buttons["native-school-country"]
        XCTAssertEqual(country.label, "Country: South Korea")
        search.tap() // lets the keyboard settle: the popover moves with it
        capture("Settings: school picker (English)")
        country.tap()
        XCTAssertTrue(app.buttons["native-school-country-JP"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Settings: school picker and country (English)")
        app.buttons["native-school-country-JP"].tap()
        XCTAssertTrue(wait(for: country) { $0.label == "Country: Japan" }, country.label)
        XCTAssertTrue(waitForAbsence(app.buttons["native-school-result-snu"]), "The bundled list is Korea's")
        country.tap()
        app.buttons["native-school-country-other"].tap()
        let code = app.textFields["native-school-country-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5), app.debugDescription)
        code.tap(); code.typeText("zz\n")
        XCTAssertTrue(app.staticTexts["No such country code. Try DE, FR or CN."].waitForExistence(timeout: 5), app.debugDescription)
        code.tap(); code.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "kr\n")
        XCTAssertTrue(wait(for: country) { $0.label == "Country: South Korea" }, country.label)

        search.tap(); search.typeText("kaist")
        let school = app.buttons["native-school-result-kaist"]
        XCTAssertTrue(school.waitForExistence(timeout: 5), app.debugDescription); school.tap()
        XCTAssertTrue(app.staticTexts["native-settings-school-name"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(pick.label, "Change my school")
        XCTAssertTrue(app.buttons["선택 해제"].exists, "The sites below are still managed here")
        capture("Settings: school chosen (English)")

        app.buttons["native-settings-category-general"].tap()
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        for _ in 0..<5 where !app.buttons["한국어"].exists { language.tap(); _ = app.buttons["한국어"].waitForExistence(timeout: 2) }
        app.buttons["한국어"].tap()
        app.buttons["native-settings-category-account"].tap()
        XCTAssertTrue(wait(for: pick) { $0.label == "내 학교 바꾸기" }, pick.label)
    }

    private static let korean = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra + Self.korean
        app.launch()
        return app
    }
    @MainActor private func wait(for element: XCUIElement, until condition: @escaping (XCUIElement) -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(element) }, object: nil)], timeout: 10) == .completed
    }
    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 5) == .completed
    }
    @MainActor private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
