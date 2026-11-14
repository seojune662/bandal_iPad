import XCTest

/// Pressing 요금제's buttons: upgrade, downgrade, a change of period, Ask to Buy, cancel, and 충전 paid by the
/// server, missed by it and paid at the next launch, never twice. The App Store is the app's simulated one
/// (`--plans-state`, PlansStoreSimulator: Apple's rules for the group's levels) with the ASC KOR prices
/// (`--native-store-fixture`); the server is the app's stand-in (`--plans-server`), whose counts the credit card
/// reports as "redeems=N paid=M". StoreKit's own part is the sandbox check in docs/release/ai-credit-submission.md.
final class PlansPurchaseFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Free → Plus monthly with the trial → Pro at once → Plus booked for renewal → Pro yearly booked instead.
    @MainActor func testUpgradeDowngradeAndPeriodChange() throws {
        let app = launch(["--plans-state", "free"])
        openPlans(app)
        XCTAssertEqual(app.staticTexts["membership-current"].label, "무료 이용 중")
        app.buttons["membership-period-monthly"].tap()
        XCTAssertEqual(app.buttons["membership-cta-plus"].label, "7일 무료 체험 시작")

        app.buttons["membership-cta-plus"].tap()
        expectToast(app, "Plus 시작됐어요")
        expectCurrent(app, "반달 플러스 · 월간", line: "무료 체험 중 · 7일 남음")
        XCTAssertTrue(wait(app.buttons["membership-cta-plus"], label: "현재 요금제"))
        attachPNG(app, "flow-1-plus-trial")

        // The trial is used, so Pro offers none; an upgrade is in effect at once.
        XCTAssertTrue(wait(app.buttons["membership-cta-pro"], label: "업그레이드"), app.buttons["membership-cta-pro"].label)
        app.buttons["membership-cta-pro"].tap()
        expectToast(app, "Pro 시작됐어요")
        expectCurrent(app, "반달 프로 · 월간", line: "다음 결제일")
        XCTAssertTrue(app.staticTexts["plans-change-notice"].exists)

        // A downgrade waits for the next renewal; Pro stays.
        XCTAssertTrue(wait(app.buttons["membership-cta-plus"], label: "다음 갱신일에 변경"))
        app.buttons["membership-cta-plus"].tap()
        expectToast(app, "다음 갱신일부터 플러스 월간으로 바뀌어요")
        expectCurrent(app, "반달 프로 · 월간", line: "부터 플러스 월간")
        XCTAssertTrue(wait(app.buttons["membership-cta-plus"], label: "변경 예약됨"))
        XCTAssertFalse(app.buttons["membership-cta-plus"].isEnabled)
        attachPNG(app, "flow-2-downgrade-booked")

        // Monthly to yearly also waits, and replaces the booked downgrade.
        app.buttons["membership-period-yearly"].tap()
        XCTAssertTrue(wait(app.buttons["membership-cta-pro"], label: "연간으로 변경"))
        app.buttons["membership-cta-pro"].tap()
        expectToast(app, "다음 갱신일부터 프로 연간으로 바뀌어요")
        expectCurrent(app, "반달 프로 · 월간", line: "부터 프로 연간")
        XCTAssertTrue(wait(app.buttons["membership-cta-pro"], label: "변경 예약됨"))
        app.buttons["membership-period-monthly"].tap()
        XCTAssertTrue(wait(app.buttons["membership-cta-plus"], label: "다음 갱신일에 변경"), "the downgrade is no longer booked")
        attachPNG(app, "flow-3-period-booked")
    }

    /// Ask to Buy: the purchase waits and nothing changes. A cancel in Apple's sheet says nothing.
    @MainActor func testAskToBuyWaitsAndACancelSaysNothing() throws {
        var app = launch(["--plans-state", "free", "--plans-store-mode", "ask"])
        openPlans(app)
        app.buttons["membership-cta-plus"].tap()
        expectToast(app, "승인을 기다리고 있어요. 승인되면 바로 적용돼요.")
        XCTAssertEqual(app.staticTexts["membership-current"].label, "무료 이용 중", "nothing until approved")
        XCTAssertTrue(app.buttons["membership-cta-plus"].isEnabled)
        app.terminate()

        app = launch(["--plans-state", "plus-monthly", "--plans-store-mode", "cancel"])
        openPlans(app)
        app.buttons["membership-period-monthly"].tap()
        app.buttons["membership-cta-pro"].tap()
        XCTAssertFalse(app.staticTexts["bandal-toast"].waitForExistence(timeout: 3), app.staticTexts["bandal-toast"].label)
        XCTAssertEqual(app.staticTexts["membership-current"].label, "반달 플러스 · 월간")
        XCTAssertTrue(app.buttons["membership-cta-pro"].isEnabled)
    }

    /// 충전: bought, paid by the server, finished. Relaunched, the finished pack is not sent again.
    @MainActor func testCreditIsPaidByTheServerThenFinished() throws {
        var app = launch(["--plans-state", "pro", "--plans-server", "ok"])
        openPlans(app)
        let buy = app.buttons["plans-credit-buy"]
        scroll(app, to: buy)
        XCTAssertTrue(wait(app.staticTexts["plans-credit-balance"], label: "남은 충전 잔액: AI 약 0회"), app.debugDescription)
        XCTAssertEqual(buy.label, "₩5,500 충전")
        buy.tap()
        XCTAssertTrue(wait(app.staticTexts["plans-credit-outcome"], label: "충전했어요"), app.debugDescription)
        XCTAssertTrue(wait(app.staticTexts["plans-credit-balance"], label: "남은 충전 잔액: AI 약 2,857회"))
        XCTAssertEqual(serverCounts(app), "redeems=1 paid=1")
        attachPNG(app, "flow-credit-paid")

        app.terminate()
        app = launch(["--plans-state", "pro", "--plans-server", "ok"], reset: false)
        openPlans(app)
        scroll(app, to: app.buttons["plans-credit-buy"])
        sleep(2)
        XCTAssertEqual(serverCounts(app), "redeems=1 paid=1", "a finished pack is not redeemed again")
        XCTAssertTrue(wait(app.staticTexts["plans-credit-balance"], label: "남은 충전 잔액: AI 약 2,857회"))
    }

    /// The server is down at the purchase: paid at the store, kept open, paid at the next launch once; the
    /// launch after that sends nothing.
    @MainActor func testCreditTheServerMissedIsPaidAtTheNextLaunch() throws {
        var app = launch(["--plans-state", "pro", "--plans-server", "fail"])
        openPlans(app)
        let buy = app.buttons["plans-credit-buy"]
        scroll(app, to: buy)
        buy.tap()
        XCTAssertTrue(wait(app.staticTexts["plans-credit-outcome"], label: "결제됐어요. 곧 사용량에 더해져요."), app.debugDescription)
        XCTAssertTrue(serverCounts(app).hasSuffix("paid=0"), serverCounts(app))

        app.terminate()
        app = launch(["--plans-state", "pro", "--plans-server", "ok"], reset: false)
        openPlans(app)
        scroll(app, to: app.buttons["plans-credit-buy"])
        XCTAssertTrue(wait(app.staticTexts["plans-credit-balance"], label: "남은 충전 잔액: AI 약 2,857회"), serverCounts(app))
        XCTAssertTrue(serverCounts(app).hasSuffix("paid=1"), serverCounts(app))
        let sent = serverCounts(app)
        attachPNG(app, "flow-credit-paid-next-launch")

        app.terminate()
        app = launch(["--plans-state", "pro", "--plans-server", "ok"], reset: false)
        openPlans(app)
        scroll(app, to: app.buttons["plans-credit-buy"])
        sleep(2)
        XCTAssertEqual(serverCounts(app), sent, "finished after it was paid: not sent again")
    }

    /// The model picker's 충전 buys the same way, in its popover.
    @MainActor func testModelPickerCreditBuysTheSameWay() throws {
        let app = launch(["--plans-state", "pro", "--plans-server", "ok", "--native-ai-catalog-fixture"])
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
        let open = app.buttons["native-ai-credit-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        let buy = app.buttons["credit-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(wait(buy, label: "₩5,500 충전"), buy.label)
        attachPNG(app, "flow-credit-popover")
        buy.tap()
        XCTAssertTrue(wait(app.staticTexts["credit-outcome"], label: "충전했어요"), app.debugDescription)
    }

    // MARK: Helpers

    @MainActor private func launch(_ extra: [String], reset: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--native-store-fixture"] + (reset ? ["--reset-native-ui-testing"] : []) + extra
        app.launch()
        return app
    }

    @MainActor private func openPlans(_ app: XCUIApplication) {
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription); settings.tap()
        let category = app.buttons["native-settings-category-subscription"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !category.isSelected { category.tap(); _ = app.buttons["native-membership-manage"].waitForExistence(timeout: 2) }
        let open = app.buttons["native-membership-manage"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !app.staticTexts["membership-title"].exists { open.tap(); _ = app.staticTexts["membership-title"].waitForExistence(timeout: 5) }
        XCTAssertTrue(app.staticTexts["membership-title"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["membership-cta-pro"].waitForExistence(timeout: 15), app.debugDescription)
        sleep(1)
    }

    @MainActor private func expectToast(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let toast = app.staticTexts["bandal-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        XCTAssertTrue(toast.label.contains(text), toast.label, file: file, line: line)
    }

    /// The current plan's name and a line under it containing `line`.
    @MainActor private func expectCurrent(_ app: XCUIApplication, _ name: String, line: String, file: StaticString = #filePath, lineNumber: UInt = #line) {
        let current = app.staticTexts["membership-current"]
        XCTAssertTrue(wait(current, label: name), current.label, file: file, line: lineNumber)
        let deadline = Date().addingTimeInterval(10)
        var said = ""
        repeat {
            said = (0..<2).map { app.staticTexts["plans-current-line-\($0)"] }.filter(\.exists).map(\.label).joined(separator: " | ")
            if said.contains(line) { return }
            usleep(300_000)
        } while Date() < deadline
        XCTFail("\(line) not in: \(said)", file: file, line: lineNumber)
    }

    @MainActor private func wait(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label == label { return true }
            usleep(300_000)
        } while Date() < deadline
        return false
    }

    @MainActor private func serverCounts(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["plans-credit"].firstMatch.value as? String ?? ""
    }

    @MainActor private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        let page = app.otherElements["membership-paywall"].scrollViews.firstMatch
        for _ in 0..<6 where !element.isHittable { (page.exists ? page : app).swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor private func attachPNG(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
