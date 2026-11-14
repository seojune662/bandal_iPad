import XCTest

/// 요금제 and the 충전 popover, with the App Store Connect KOR prices (`--native-store-fixture`: the
/// simulator has no App Store products). The PNGs attached here are the review screenshots, at the
/// simulator's native resolution, portrait: `plans-yearly-pro` for the four subscriptions and
/// `plans-credit` for AI Credit. Pressing the buttons is PlansPurchaseFlowUITests.
final class StoreScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testPlansShowStorePricesAndPickPro() throws {
        let app = launch(["--native-free-tier", "--native-store-fixture"])
        openPlans(app)
        XCTAssertEqual(app.staticTexts["membership-title"].label, "요금제")
        XCTAssertEqual(app.staticTexts["membership-current"].label, "무료 이용 중")
        XCTAssertTrue(app.buttons["membership-period-yearly"].isSelected, "yearly by default")
        XCTAssertTrue(app.staticTexts["membership-saving"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["membership-saving"].label, "최대 46% 할인")
        XCTAssertTrue(price(app, "pro").contains("₩29,000"), price(app, "pro"))
        XCTAssertTrue(price(app, "plus").contains("₩11,000"), price(app, "plus"))
        XCTAssertTrue(price(app, "free").contains("₩0"))
        XCTAssertTrue(note(app, "pro").contains("월간보다 46% 저렴"), note(app, "pro"))
        XCTAssertTrue(note(app, "plus").contains("월간보다 39% 저렴") && note(app, "plus").contains("7일 무료 체험 후 결제"), note(app, "plus"))
        XCTAssertEqual(app.buttons["membership-cta-pro"].label, "7일 무료 체험 시작")
        XCTAssertEqual(app.buttons["membership-cta-plus"].label, "7일 무료 체험 시작")
        XCTAssertFalse(app.buttons["membership-cta-free"].exists, "the free card has no button")
        XCTAssertEqual(app.descendants(matching: .any)["membership-cta-free"].label, "현재 요금제")
        XCTAssertFalse(app.staticTexts["plans-change-notice"].exists, "nothing to change yet on Free")
        for text in ["가장 인기", "AI 4배", "AI로 공부하는 학생", "작업 1회 상한 Plus의 5배"] {
            XCTAssertTrue(app.staticTexts[text].exists, text)
        }
        attachPNG(app, "plans-yearly-pro-top")

        app.buttons["membership-period-monthly"].tap()
        XCTAssertTrue(price(app, "pro").contains("₩4,500"), price(app, "pro"))
        XCTAssertTrue(price(app, "plus").contains("₩1,500"), price(app, "plus"))
        app.buttons["membership-period-yearly"].tap()
        app.otherElements["membership-card-pro"].tap()
        XCTAssertTrue(app.otherElements["membership-card-pro"].isSelected)
        sleep(1)
        attachPNG(app, "plans-yearly-pro")

        // What a subscription screen must carry, below the cards: restore, Apple's history and manage sheet,
        // terms, privacy, the auto-renew notice.
        let restore = app.buttons["membership-restore"]
        scroll(app, to: restore)
        XCTAssertEqual(restore.label, "구매 복원")
        XCTAssertEqual(app.descendants(matching: .any)["plans-purchase-history"].label, "결제 내역")
        XCTAssertEqual(app.buttons["plans-manage"].label, "App Store에서 구독 해지·관리")
        XCTAssertEqual(app.descendants(matching: .any)["plans-terms-link"].label, "이용약관")
        XCTAssertEqual(app.descendants(matching: .any)["plans-privacy-link"].label, "개인정보처리방침")
        XCTAssertTrue(app.staticTexts["membership-terms"].label.contains("24시간 전"))
        XCTAssertTrue(app.staticTexts["plans-credit-terms"].exists)
        attachPNG(app, "plans-footer")
        app.buttons["membership-close"].tap()
        XCTAssertFalse(app.staticTexts["membership-title"].waitForExistence(timeout: 2))
    }

    /// AI 충전 on 요금제, signed in (the server's status: a Pro account out of AI): the price, the one line,
    /// the balance, and the button. This is AI Credit's review screenshot.
    @MainActor func testPlansSellAICreditToASignedInAccount() throws {
        let app = launch(["--native-store-fixture", "--native-ai-usage-fixture", "--plans-state", "pro"])
        openPlans(app)
        XCTAssertEqual(app.staticTexts["membership-current"].label, "반달 프로 · 월간")
        let buy = app.buttons["plans-credit-buy"]
        scroll(app, to: buy)
        XCTAssertEqual(buy.label, "₩5,500 충전")
        XCTAssertTrue(buy.isEnabled)
        XCTAssertEqual(app.staticTexts["plans-credit-price"].label, "₩5,500")
        XCTAssertTrue(app.staticTexts["이번 달 AI 사용량에 더해지고, 만료되지 않아요."].exists)
        XCTAssertEqual(app.staticTexts["plans-credit-balance"].label, "남은 충전 잔액: AI 약 0회")
        sleep(1)
        attachPNG(app, "plans-credit")
    }

    /// Signed out, the credit is shown with its price, and bought after signing in (the server holds it).
    @MainActor func testSignedOutCreditSaysToSignIn() throws {
        let app = launch(["--native-free-tier", "--native-store-fixture"])
        openPlans(app)
        let buy = app.buttons["plans-credit-buy"]
        scroll(app, to: buy)
        XCTAssertFalse(buy.isEnabled)
        XCTAssertEqual(app.staticTexts["plans-credit-signin"].label, "로그인한 계정에 충전돼요. 로그인하면 살 수 있어요.")
        XCTAssertFalse(app.staticTexts["plans-credit-balance"].exists)
    }

    @MainActor func testPlansSayWhenProductsDoNotLoad() throws {
        let app = launch(["--native-free-tier", "--native-store-unavailable"])
        openPlans(app, waitForPrices: false)
        XCTAssertTrue(app.staticTexts["membership-unavailable"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["membership-unavailable"].label, "요금제를 불러오지 못했어요")
        XCTAssertTrue(app.buttons["membership-retry"].exists)
        let retry = app.buttons["plans-credit-retry"]
        scroll(app, to: retry)
        XCTAssertEqual(app.staticTexts["plans-credit-unavailable"].label, "가격을 불러오지 못했어요")
        XCTAssertFalse(app.buttons["plans-credit-buy"].exists, "no button without a price")
        // Restore, terms and the way to cancel stay even without prices.
        XCTAssertTrue(app.buttons["membership-restore"].exists && app.buttons["plans-manage"].exists)
        attachPNG(app, "plans-unavailable")
    }

    /// Each state of the plan in effect, as 요금제 says it (`--plans-state`).
    @MainActor func testEachPlanStateIsSaid() throws {
        let cases: [(String, String, [String], [String: String])] = [
            // A subscriber has had the group's one trial, so an upgrade is offered without one.
            ("plus-monthly", "반달 플러스 · 월간", ["다음 결제일"], ["plus": "현재 요금제", "pro": "업그레이드"]),
            ("plus-yearly", "반달 플러스 · 연간", ["다음 결제일"], ["plus": "현재 요금제", "pro": "업그레이드"]),
            ("pro", "반달 프로 · 월간", ["다음 결제일"], ["plus": "다음 갱신일에 변경", "pro": "현재 요금제"]),
            ("trial", "반달 프로 · 월간", ["무료 체험 중 · 5일 남음", "에 첫 결제"], ["pro": "현재 요금제"]),
            ("canceled", "반달 플러스 · 연간", ["자동 갱신 꺼짐", "에 끝나요"], ["plus": "현재 요금제"]),
            ("scheduled", "반달 프로 · 연간", ["다음 결제일", "부터 프로 월간"], ["pro": "현재 요금제"]),
            ("billing", "반달 플러스 · 월간", ["결제가 되지 않았어요"], [:]),
        ]
        for (state, name, lines, buttons) in cases {
            let app = launch(["--native-store-fixture", "--plans-state", state])
            openPlans(app)
            XCTAssertEqual(app.staticTexts["membership-current"].label, name, state)
            let said = (0..<2).map { app.staticTexts["plans-current-line-\($0)"] }.filter(\.exists).map(\.label).joined(separator: " | ")
            for line in lines { XCTAssertTrue(said.contains(line), "\(state): \(said)") }
            XCTAssertTrue(app.staticTexts["plans-change-notice"].exists, state)
            app.buttons[state == "plus-yearly" || state == "canceled" || state == "scheduled" ? "membership-period-yearly" : "membership-period-monthly"].tap()
            for (card, label) in buttons { XCTAssertEqual(app.buttons["membership-cta-" + card].label, label, "\(state) \(card)") }
            if state == "scheduled" {
                app.buttons["membership-period-monthly"].tap()
                XCTAssertEqual(app.buttons["membership-cta-pro"].label, "변경 예약됨")
                XCTAssertFalse(app.buttons["membership-cta-pro"].isEnabled)
            }
            if state == "plus-monthly" {
                app.buttons["membership-period-yearly"].tap()
                XCTAssertEqual(app.buttons["membership-cta-plus"].label, "연간으로 변경")
            }
            attachPNG(app, "state-\(state)")
            app.terminate()
        }
    }

    /// 설정 › 구독·사용량: one button, 요금제 보기, free or subscribed; 더 보기's 충전 goes to 요금제's credit.
    @MainActor func testSettingsOpensPlansFromOneButton() throws {
        for state in ["free", "plus-yearly"] {
            let app = launch(["--native-store-fixture", "--plans-state", state])
            openSubscription(app)
            let open = app.buttons["native-membership-manage"]
            XCTAssertEqual(open.label, "요금제 보기", state)
            for gone in ["구독 관리", "플랜 보기", "플랜 변경"] { XCTAssertFalse(app.buttons[gone].exists, gone) }
            app.terminate()
        }
        let app = launch(["--native-store-fixture", "--native-ai-usage-fixture"])
        openSubscription(app)
        app.openNativeSettingsMore()
        for gone in ["native-membership-open", "구매 복원", "구독 관리", "플랜 변경"] { XCTAssertFalse(app.buttons[gone].exists, gone) }
        let credit = app.buttons["native-settings-credit"]
        XCTAssertTrue(credit.waitForExistence(timeout: 10), app.debugDescription)
        credit.tap()
        let buy = app.buttons["plans-credit-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1)
        XCTAssertTrue(buy.isHittable, "scrolled to the credit")
    }

    /// The profile menu's row is 요금제 보기 too, and opens the same screen.
    @MainActor func testProfileMenuOpensPlans() throws {
        let app = launch(["--native-account-fixture", "--native-store-fixture"])
        let account = app.buttons["native-section-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 25), app.debugDescription); account.tap()
        let row = app.buttons["native-account-plans"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(row.label, "요금제 보기")
        row.tap()
        XCTAssertTrue(app.staticTexts["membership-title"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["membership-title"].label, "요금제")
    }

    @MainActor func testModelChoiceIsOnlyThePopover() throws {
        let app = launch(["--native-ai-catalog-fixture"])
        // The composer (and its pill) needs a course.
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra"); app.buttons["native-create-course"].tap()
        sleep(1)
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20)); if toggle.label != "AI 닫기" { toggle.tap() }
        let pill = app.buttons["native-ai-model-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), app.debugDescription)
        pill.tap()
        XCTAssertTrue(app.textFields["native-ai-model-search"].waitForExistence(timeout: 5) || app.buttons["native-ai-model-default"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.navigationBars["AI 선택"].exists)
        XCTAssertFalse(app.buttons["적용"].exists, "no apply button: choices apply at once")
        sleep(1)
        attachPNG(app, "model-popover")
    }

    // MARK: Helpers

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        return app
    }

    @MainActor private func openSubscription(_ app: XCUIApplication) {
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription); settings.tap()
        let category = app.buttons["native-settings-category-subscription"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        // Settings ignores taps while its first load runs.
        for _ in 0..<5 where !category.isSelected { category.tap(); _ = app.buttons["native-membership-manage"].waitForExistence(timeout: 2) }
        XCTAssertTrue(app.buttons["native-membership-manage"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func openPlans(_ app: XCUIApplication, waitForPrices: Bool = true) {
        openSubscription(app)
        let open = app.buttons["native-membership-manage"]
        for _ in 0..<3 where !app.staticTexts["membership-title"].exists { open.tap(); _ = app.staticTexts["membership-title"].waitForExistence(timeout: 5) }
        XCTAssertTrue(app.staticTexts["membership-title"].waitForExistence(timeout: 10), app.debugDescription)
        if waitForPrices { _ = app.buttons["membership-cta-pro"].waitForExistence(timeout: 10); sleep(1) }
    }

    @MainActor private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        let page = app.otherElements["membership-paywall"].scrollViews.firstMatch
        for _ in 0..<6 where !element.isHittable { (page.exists ? page : app).swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor private func price(_ app: XCUIApplication, _ plan: String) -> String {
        let element = app.descendants(matching: .any)["membership-price-" + plan].firstMatch
        _ = element.waitForExistence(timeout: 5)
        return element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }

    @MainActor private func note(_ app: XCUIApplication, _ plan: String) -> String {
        let element = app.descendants(matching: .any)["membership-note-" + plan].firstMatch
        _ = element.waitForExistence(timeout: 5)
        return element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }

    @MainActor private func attachPNG(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
