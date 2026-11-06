import XCTest

/// 플랜 선택 and the 충전 popover, with the App Store Connect KOR prices (`--native-store-fixture`: the
/// simulator has no App Store products). The PNGs attached here are the review screenshots, at the
/// simulator's native resolution, portrait.
final class StoreScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testPaywallShowsStorePricesAndPicksPro() throws {
        let app = launch(["--native-free-tier", "--native-store-fixture"])
        openSubscription(app)
        app.buttons["native-membership-open"].tap()
        XCTAssertTrue(app.staticTexts["membership-title"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["membership-title"].label, "플랜 선택")
        XCTAssertEqual(app.staticTexts["membership-current"].label, "무료 이용 중")
        XCTAssertTrue(app.buttons["membership-period-yearly"].isSelected, "yearly by default")
        XCTAssertTrue(app.staticTexts["membership-saving"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["membership-saving"].label, "최대 46% 할인")
        XCTAssertTrue(price(app, "pro").contains("₩29,000"), price(app, "pro"))
        XCTAssertTrue(price(app, "plus").contains("₩11,000"), price(app, "plus"))
        XCTAssertTrue(price(app, "free").contains("₩0"))
        XCTAssertEqual(app.buttons["membership-cta-pro"].label, "7일 무료로 시작")
        XCTAssertFalse(app.buttons["membership-cta-free"].exists, "no button on the free card")
        for text in ["가장 인기", "AI 4배", "AI로 공부하는 학생", "작업 1회 상한 $0.50", "구매 복원", "이용약관", "개인정보처리방침"] {
            XCTAssertTrue(app.descendants(matching: .any)[text].exists || app.staticTexts.containing(NSPredicate(format: "label == %@", text)).firstMatch.exists, text)
        }
        XCTAssertTrue(app.staticTexts["membership-terms"].label.contains("24시간 전"))

        app.buttons["membership-period-monthly"].tap()
        XCTAssertTrue(price(app, "pro").contains("₩4,500"), price(app, "pro"))
        XCTAssertTrue(price(app, "plus").contains("₩1,500"), price(app, "plus"))
        app.buttons["membership-period-yearly"].tap()
        app.otherElements["membership-card-pro"].tap()
        XCTAssertTrue(app.otherElements["membership-card-pro"].isSelected)
        sleep(1)
        attachPNG(app, "paywall-yearly-pro")
        app.buttons["membership-close"].tap()
        XCTAssertFalse(app.staticTexts["membership-title"].waitForExistence(timeout: 2))
    }

    @MainActor func testPaywallSaysWhenProductsDoNotLoad() throws {
        let app = launch(["--native-free-tier", "--native-store-unavailable"])
        openSubscription(app)
        app.buttons["native-membership-open"].tap()
        XCTAssertTrue(app.staticTexts["membership-unavailable"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["membership-unavailable"].label, "불러오지 못했어요")
        XCTAssertTrue(app.buttons["membership-retry"].exists)
    }

    @MainActor func testCreditIsAPopoverWithTheStorePrice() throws {
        let app = launch(["--native-store-fixture", "--native-ai-usage-fixture"])
        openSubscription(app)
        let open = app.buttons["native-ai-credit-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(open.label, "충전")
        open.tap()
        let buy = app.buttons["credit-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(buy.label, "₩5,500 충전")
        XCTAssertTrue(app.staticTexts["이번 달 사용량을 다 쓴 뒤 쓰여요. 만료 없음."].exists)
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'AI 충전'")).count, 0, "no repeated AI 충전 title")
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "not a sheet")
        sleep(1)
        attachPNG(app, "credit-popover")
    }

    @MainActor func testModelChoiceIsOnlyThePopover() throws {
        let app = launch(["--native-ai-catalog-fixture"])
        // The composer (and its pill) needs a course.
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
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
        for _ in 0..<5 where !app.buttons["native-membership-open"].waitForExistence(timeout: 2) { category.tap() }
        XCTAssertTrue(app.buttons["native-membership-open"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func price(_ app: XCUIApplication, _ plan: String) -> String {
        let element = app.descendants(matching: .any)["membership-price-" + plan].firstMatch
        _ = element.waitForExistence(timeout: 5)
        return element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }

    @MainActor private func attachPNG(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
