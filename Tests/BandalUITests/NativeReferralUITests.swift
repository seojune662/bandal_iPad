import XCTest

/// 친구 초대. `--native-referral-fixture` puts the in-memory invitation server behind the app (a code
/// that starts with X does not exist, BANDA2 is the account's own), signed in unless
/// `--native-referral-signed-out` is there too; without it the app is signed out and has no server
/// to ask. `-native.referral.link <address>` stands in for opening an invite link.
final class NativeReferralUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private static let applied = "코드 적용됨 — 로그인하고 첫 과목을 만들면 AI 100회가 들어와요"
    private static let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6)

    /// Onboarding's third step: a code that does not exist, one that does, and going on without one.
    @MainActor
    func testOnboardingInviteStepRefusesAMissingCodeAppliesARealOneAndCanBeSkipped() {
        for name in ["light", "dark"] {
            let app = launch(["--native-onboarding", "--native-referral-fixture", "--native-referral-signed-out", "-native.appearance", name])
            let field = reachInviteStep(app)
            XCTAssertTrue(app.staticTexts["초대 코드가 있나요?"].exists)
            XCTAssertEqual(app.descendants(matching: .any)["native-onboarding-dots"].label, "4단계 중 3단계")
            XCTAssertEqual(field.placeholderValue, "6자리 코드"); XCTAssertEqual(field.label, "초대 코드")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The field has the keyboard from the start")
            let skip = app.buttons["native-referral-skip"], next = app.buttons["native-onboarding-next"]
            XCTAssertTrue(skip.exists); XCTAssertFalse(next.exists)
            XCTAssertTrue(paste(in: app).exists, app.debugDescription)
            capture("온보딩 3 초대 코드 (\(name))")

            // A code nobody has: one red line under the field, and skipping stays the way on.
            field.typeText("xxxxxx")
            XCTAssertTrue(wait(for: field) { $0.value as? String == "XXXXXX" }, "Small letters become capitals")
            let error = app.staticTexts["native-referral-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(error.label, "없는 초대 코드예요.")
            XCTAssertTrue(skip.exists); XCTAssertFalse(app.staticTexts["native-referral-applied"].exists)
            capture("온보딩 3 없는 코드 (\(name))")

            // A real one, typed carelessly: applied, and the step goes on with 다음. Nothing asks to sign in.
            field.typeText(Self.delete + "abc-234")
            XCTAssertTrue(wait(for: field) { $0.value as? String == "ABC234" }, "\(String(describing: field.value))")
            let applied = app.staticTexts["native-referral-applied"]
            XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(applied.label, Self.applied)
            XCTAssertTrue(next.waitForExistence(timeout: 5)); XCTAssertFalse(skip.exists); XCTAssertFalse(error.exists)
            XCTAssertFalse(app.buttons["Apple로 로그인"].exists || app.buttons["Google로 로그인"].exists, "Onboarding never asks to sign in")
            capture("온보딩 3 코드 적용 (\(name))")

            let finish = app.buttons["native-onboarding-finish"], banner = app.staticTexts["native-referral-banner"]
            if name == "light" {
                next.tap()
                XCTAssertTrue(finish.waitForExistence(timeout: 10), app.debugDescription); finish.tap()
                XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertEqual(banner.label, "첫 과목을 만들면 AI 100회가 들어와요")
                XCTAssertTrue(app.buttons["native-new-course-empty"].isHittable, "The reminder leaves the course list on screen")
                // It waits on this iPad: still there after a relaunch.
                app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-referral-fixture", "--native-referral-signed-out"] + Self.korean; app.launch()
                XCTAssertTrue(banner.waitForExistence(timeout: 25), app.debugDescription)
            } else {
                // Second thoughts: a code taken out of the field no longer waits, and the step is skipped.
                field.typeText(Self.delete)
                XCTAssertTrue(skip.waitForExistence(timeout: 5), app.debugDescription); XCTAssertFalse(applied.exists)
                skip.tap()
                XCTAssertTrue(finish.waitForExistence(timeout: 10), app.debugDescription); finish.tap()
                XCTAssertTrue(app.buttons["native-new-course-empty"].waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertFalse(banner.exists, "No code, no reminder")
            }
            app.terminate()
        }
    }

    /// The inviter's popover from the profile menu: the code, what it has brought, and copying.
    /// The copied link then goes through the paste control, and one's own code is refused.
    @MainActor
    func testInviterPopoverShowsTheCodeAndCountsAndCopiesAndOnesOwnCodeIsRefused() {
        for name in ["light", "dark"] {
            let app = launch(["--native-account-fixture", "--native-referral-fixture", "-native.appearance", name])
            let account = app.buttons["native-section-account"]
            XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription); account.tap()
            let row = app.buttons["native-referral-menu"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(row.label, "친구 초대"); row.tap()
            let code = app.buttons["native-referral-code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(code.label, "내 초대 코드 BANDA2 복사")
            XCTAssertEqual(app.staticTexts["native-referral-count"].label, "초대 3 / 5 · 받은 AI 300회")
            XCTAssertTrue(app.staticTexts["친구가 로그인하고 첫 과목을 만들면 둘 다 AI 100회"].exists)
            XCTAssertTrue(app.staticTexts["5명까지"].exists)
            let link = app.buttons["native-referral-copy-link"], share = app.descendants(matching: .any)["native-referral-share"]
            XCTAssertEqual(link.label, "링크 복사"); XCTAssertEqual(share.label, "공유")
            for control in [code, link, share] { XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.identifier) }
            capture("친구 초대 팝오버 (\(name))")

            code.tap()
            let toast = app.staticTexts["bandal-toast"]
            XCTAssertTrue(toast.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(toast.label, "복사했어요")
            capture("친구 초대 복사했어요 (\(name))")
            guard name == "light" else {
                // 공유 hands the invitation, in the app's language, to the system share sheet.
                share.tap()
                XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10), app.debugDescription)
                let message = "반달에서 같이 공부하자. 초대 코드 BANDA2 넣으면 둘 다 AI 100회 받아요. bandal.io/r/BANDA2"
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", message)).firstMatch.exists, app.debugDescription)
                capture("친구 초대 공유 시트 (\(name))")
                app.terminate(); continue
            }

            // 링크 복사, then 설정 › 계정 › 친구 초대: the same popover opens there, and the paste control
            // turns the copied link into its code. It is this account's own, so the claim is refused.
            link.tap()
            let settings = app.buttons["native-section-settings"], category = app.buttons["native-settings-category-account"]
            // The first tap outside only closes the popover.
            for _ in 0..<3 where !category.exists { settings.tap(); _ = category.waitForExistence(timeout: 5) }
            select(category)
            let open = app.buttons["native-referral-settings-open"]
            XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(open.label, "초대하기"); open.tap()
            XCTAssertTrue(code.waitForExistence(timeout: 10), "The same popover: " + app.debugDescription)
            capture("설정 › 계정 › 친구 초대 팝오버 (\(name))")
            let field = app.textFields["native-referral-field"]
            dismissPopover(showing: code, byTapping: field)
            let paste = paste(in: app)
            XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription); paste.tap()
            XCTAssertTrue(wait(for: field) { $0.value as? String == "BANDA2" }, "The pasted link gives its code: \(String(describing: field.value))")
            let error = app.staticTexts["native-referral-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(error.label, "내 초대 코드는 내가 쓸 수 없어요.")
            capture("설정 › 계정 › 내 코드는 못 써요 (\(name))")
            app.terminate()
        }
    }

    /// Signed out, the invite popover offers sign-in right there, from the profile menu and from
    /// Settings; in portrait. With no server to ask, the code field says so and offers another try.
    @MainActor
    func testSignedOutTheInvitePopoverOffersSignInAndAnUnreachableServerIsSaidPlainly() {
        let app = launch([], orientation: .portrait)
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription); account.tap()
        let row = app.buttons["native-referral-menu"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription); row.tap()
        let apple = app.buttons["native-referral-sign-in-apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-referral-sign-in-google"].exists)
        XCTAssertTrue(app.staticTexts["로그인하면 내 초대 코드를 받을 수 있어요"].exists)
        XCTAssertFalse(app.buttons["native-referral-code"].exists)
        capture("친구 초대: 로그인 (세로)")

        let settings = app.buttons["native-section-settings"], category = app.buttons["native-settings-category-account"]
        for _ in 0..<3 where !category.exists { settings.tap(); _ = category.waitForExistence(timeout: 5) }
        select(category)
        let open = app.buttons["native-referral-settings-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription); open.tap()
        XCTAssertTrue(apple.waitForExistence(timeout: 10), app.debugDescription)
        capture("설정 › 계정 › 친구 초대: 로그인 (세로)")

        let field = app.textFields["native-referral-field"]
        dismissPopover(showing: apple, byTapping: field)
        field.tap(); field.typeText("abc234")
        let error = app.staticTexts["native-referral-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(error.label, "코드를 확인하지 못했어요. 연결을 확인해 주세요.")
        XCTAssertTrue(app.buttons["native-referral-check-again"].exists)
        XCTAssertFalse(app.staticTexts["native-referral-applied"].exists, "A code that could not be checked is not kept")
        capture("설정 › 계정 › 코드 확인 실패 (세로)")
    }

    /// The invitee's side, signed in: a code applied in Settings, the reminder in the sidebar, the
    /// first course, the reward toast, and what Settings shows afterwards.
    @MainActor
    func testAnAppliedCodeShowsTheSidebarReminderUntilTheFirstCourseBringsTheReward() {
        for name in ["light", "dark"] {
            let app = launch(["--native-referral-fixture", "-native.appearance", name])
            let settings = app.buttons["native-section-settings"], account = app.buttons["native-settings-category-account"]
            let banner = app.staticTexts["native-referral-banner"]
            XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription)
            XCTAssertFalse(banner.exists)
            settings.tap(); select(account)
            let field = app.textFields["native-referral-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["초대 코드 입력"].exists)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Settings does not take the keyboard by itself")
            capture("설정 › 계정 › 친구 초대 (\(name))")
            field.tap(); field.typeText("abc234")
            let applied = app.staticTexts["native-referral-applied"]
            XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(applied.label, Self.applied)
            XCTAssertTrue(waitForAbsence(field), "Claimed: there is no field any more")
            capture("설정 › 계정 › 코드 적용 (\(name))")

            app.buttons["native-settings-close"].tap()
            XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(banner.label, "첫 과목을 만들면 AI 100회가 들어와요")
            XCTAssertTrue(app.buttons["native-new-course-empty"].isHittable)
            capture("사이드바 배너 (\(name))")

            let add = app.buttons["native-course-add-menu"]
            add.tap(); app.buttons["native-new-course"].firstMatch.tap()
            let course = app.textFields["native-course-name"]
            XCTAssertTrue(course.waitForExistence(timeout: 5), app.debugDescription); course.tap(); course.typeText("물리\n")
            let toast = app.staticTexts["bandal-toast"]
            XCTAssertTrue(toast.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertEqual(toast.label, "AI 100회가 들어왔어요")
            capture("보상 토스트 (\(name))")
            XCTAssertTrue(waitForAbsence(banner), "Paid: the reminder is gone")

            settings.tap(); select(app.buttons["native-settings-category-subscription"])
            let credit = app.staticTexts["native-referral-credit"]
            XCTAssertTrue(credit.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(credit.label, "AI 400회", "What invitations have brought in total")
            XCTAssertTrue(app.staticTexts["초대 크레딧"].exists && app.staticTexts["친구 초대로 지금까지 받은 양이에요"].exists)
            capture("설정 › 구독·사용량 › 초대 크레딧 (\(name))")
            select(account)
            XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(applied.label, "코드 적용됨 — AI 100회를 받았어요")
            XCTAssertFalse(field.exists)
            capture("설정 › 계정 › 보상 받음 (\(name))")
            app.terminate()
        }
    }

    /// An invite link fills onboarding's invite step while onboarding shows, and otherwise opens
    /// 설정 › 계정 › 친구 초대 with the code in the field. A malformed one only opens the app.
    @MainActor
    func testAnInviteLinkFillsOnboardingOrSettingsAndAMalformedOneOnlyOpensTheApp() {
        let fixture = ["--native-referral-fixture", "--native-referral-signed-out"], link = ["-native.referral.link", "https://bandal.io/r/abc234"]
        // New install: onboarding opens on its third step.
        var app = launch(["--native-onboarding"] + fixture + link)
        let field = app.textFields["native-referral-field"], applied = app.staticTexts["native-referral-applied"], apply = app.buttons["native-referral-apply"]
        XCTAssertTrue(field.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(wait(for: field) { $0.value as? String == "ABC234" }, "\(String(describing: field.value))")
        // A link only fills the field: the code is used when the person says so.
        XCTAssertTrue(apply.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(apply.label, "이 코드 적용")
        XCTAssertFalse(applied.exists); XCTAssertTrue(app.buttons["native-referral-skip"].exists)
        capture("초대 링크 → 온보딩 3: 적용 전")
        apply.tap()
        XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(apply.exists)
        XCTAssertEqual(app.descendants(matching: .any)["native-onboarding-dots"].label, "4단계 중 3단계")
        XCTAssertTrue(app.buttons["native-onboarding-back"].exists && app.buttons["native-onboarding-next"].exists)
        XCTAssertFalse(app.buttons["native-settings-category-account"].exists, "Onboarding, not Settings")
        capture("초대 링크 → 온보딩 3")
        // The step holds in portrait too, keyboard up.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait(for: app.buttons["native-onboarding-next"]) { $0.isHittable }, app.debugDescription)
        XCTAssertTrue(field.isHittable && paste(in: app).isHittable)
        capture("초대 링크 → 온보딩 3 (세로)")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.terminate()

        // Onboarding is behind this iPad: Settings opens on 계정 with the code in the field.
        app = launch(fixture + link)
        let account = app.buttons["native-settings-category-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(wait(for: account) { $0.isSelected }, app.debugDescription)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(wait(for: field) { $0.value as? String == "ABC234" }, "\(String(describing: field.value))")
        XCTAssertTrue(apply.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(applied.exists, "Not used until asked")
        XCTAssertFalse(app.staticTexts["native-referral-banner"].exists)
        capture("초대 링크 → 설정 › 계정 › 친구 초대: 적용 전")
        apply.tap()
        XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(applied.label, Self.applied)
        capture("초대 링크 → 설정 › 계정 › 친구 초대")
        app.buttons["native-settings-close"].tap()
        XCTAssertTrue(app.staticTexts["native-referral-banner"].waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()

        // A link whose code is not one: the app opens, and that is all.
        app = launch(fixture + ["-native.referral.link", "https://bandal.io/r/abc"])
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(wait(for: settings) { $0.isHittable })
        XCTAssertFalse(account.waitForExistence(timeout: 4), "Settings stays closed")
        XCTAssertFalse(app.staticTexts["bandal-toast"].exists || app.staticTexts["native-referral-banner"].exists)
    }

    /// The same screens with the app in English.
    @MainActor
    func testTheInvitationFollowsTheAppLanguage() {
        let english = ["-native.locale", "en-US"]
        var app = launch(["--native-onboarding", "--native-referral-fixture", "--native-referral-signed-out", "-native.referral.link", "https://bandal.io/r/abc234"] + english)
        let field = app.textFields["native-referral-field"], applied = app.staticTexts["native-referral-applied"], apply = app.buttons["native-referral-apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(apply.label, "Apply this code"); apply.tap()
        XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(applied.label, "Code applied — sign in and create your first course to get 100 AI uses")
        XCTAssertTrue(app.staticTexts["Do you have an invite code?"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["native-onboarding-dots"].label, "Step 3 of 4")
        XCTAssertEqual(field.label, "Invite code")
        field.tap(); field.typeText(Self.delete)
        XCTAssertTrue(wait(for: field) { $0.placeholderValue == "6-character code" && ($0.value as? String ?? "") != "ABC234" })
        XCTAssertEqual(app.buttons["native-referral-skip"].label, "I don't have one, skip")
        field.typeText("xxxxxx")
        XCTAssertTrue(app.staticTexts["That invite code doesn't exist."].waitForExistence(timeout: 10), app.debugDescription)
        capture("Onboarding 3 in English")
        app.terminate()

        app = launch(["--native-account-fixture", "--native-referral-fixture"] + english)
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription); account.tap()
        let row = app.buttons["native-referral-menu"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(row.label, "Invite a friend"); row.tap()
        let code = app.buttons["native-referral-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(code.label, "Copy my invite code BANDA2")
        XCTAssertEqual(app.staticTexts["native-referral-count"].label, "Invited 3 of 5 · 300 AI uses received")
        XCTAssertTrue(app.staticTexts["When a friend signs in and creates their first course, you both get 100 AI uses"].exists)
        XCTAssertTrue(app.staticTexts["Up to 5 friends"].exists)
        XCTAssertEqual(app.buttons["native-referral-copy-link"].label, "Copy link")
        XCTAssertEqual(app.descendants(matching: .any)["native-referral-share"].label, "Share")
        code.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Invite popover in English")

        let settings = app.buttons["native-section-settings"], category = app.buttons["native-settings-category-account"]
        for _ in 0..<3 where !category.exists { settings.tap(); _ = category.waitForExistence(timeout: 5) }
        select(category)
        XCTAssertTrue(app.buttons["native-referral-settings-open"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["native-referral-settings-open"].label, "Invite")
        XCTAssertTrue(app.staticTexts["Enter an invite code"].exists)
        let entry = app.textFields["native-referral-field"]
        entry.tap(); entry.typeText("abc234")
        XCTAssertTrue(applied.waitForExistence(timeout: 10), app.debugDescription)
        capture("Settings › Account › Invite a friend in English")
        app.buttons["native-settings-close"].tap()
        let banner = app.staticTexts["native-referral-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(banner.label, "Create your first course to get 100 AI uses")
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5), app.debugDescription); course.tap(); course.typeText("Physics\n")
        XCTAssertTrue(app.staticTexts["100 AI uses added"].waitForExistence(timeout: 20), app.debugDescription)
        capture("Reward toast in English")
        settings.tap(); select(app.buttons["native-settings-category-subscription"])
        let credit = app.staticTexts["native-referral-credit"]
        XCTAssertTrue(credit.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(credit.label, "400 AI uses")
        XCTAssertTrue(app.staticTexts["Invite credit"].exists && app.staticTexts["What you've received from invites so far"].exists)
    }

    // MARK: Helpers

    private static let korean = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]

    @MainActor private func launch(_ extra: [String], orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra + Self.korean
        app.launch()
        return app
    }
    /// 언어 → 학교 (a school the app ships) → 초대 코드.
    @MainActor private func reachInviteStep(_ app: XCUIApplication) -> XCUIElement {
        let next = app.buttons["native-onboarding-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 25), app.debugDescription); next.tap()
        let school = app.buttons["native-school-result-snu"]
        XCTAssertTrue(school.waitForExistence(timeout: 10), app.debugDescription); school.tap()
        let field = app.textFields["native-referral-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        return field
    }
    /// The system's paste control draws its own label, in the device's language.
    @MainActor private func paste(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'native-referral-paste' OR label == '붙여넣기' OR label == 'Paste'")).firstMatch
    }
    /// A tap outside a popover closes it. What is under the popover's dimming is not hittable to
    /// XCUITest, so the tap goes to its place on screen.
    @MainActor private func dismissPopover(showing content: XCUIElement, byTapping outside: XCUIElement) {
        for _ in 0..<3 where content.exists { outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); _ = waitForAbsence(content) }
        XCTAssertFalse(content.exists, "The popover is closed")
    }
    /// Settings ignores taps while its first load runs; tap until the section is selected.
    @MainActor private func select(_ category: XCUIElement) {
        XCTAssertTrue(category.waitForExistence(timeout: 15))
        for _ in 0..<5 where !category.isSelected { category.tap(); _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: category)], timeout: 2) }
        XCTAssertTrue(category.isSelected)
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
