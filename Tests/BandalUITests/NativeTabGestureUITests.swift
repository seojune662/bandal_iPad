import XCTest

/// The three-finger tab gesture after it is recognized, and the cards that introduce it. XCUITest and the
/// simulator cannot put three fingers down: `--native-tab-gesture-fixture` gives each pane two buttons that
/// hand the dock what the recognizer would have decided (`native-tab-gesture-fixture-close-<pane>` / `-open-<pane>`).
/// The recognizer's own rules are unit tests (NativeTabGestureTests).
final class NativeTabGestureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPinchClosesTheTabAndUndoPutsItBackInItsPlace() throws {
        let app = launch(["--native-tab-gesture-fixture"])
        createCourse("Gesture Course", app: app)
        for title in ["Alpha", "Beta", "Gamma"] { createNote(title, app: app) }
        let beta = tab("Beta", app: app)
        beta.tap()
        XCTAssertTrue(waitSelected(beta), app.debugDescription)
        let id = beta.identifier
        tapFixture("close", app: app)
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 10), "The pinch closes the pane's chosen tab")
        XCTAssertTrue(app.staticTexts["탭을 닫았어요"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Closed by three fingers, with 되돌리기")
        let undo = app.buttons.matching(NSPredicate(format: "label == '되돌리기' AND identifier != 'native-pdf-undo'")).firstMatch
        XCTAssertTrue(undo.exists, app.debugDescription); undo.tap()
        let back = app.buttons[id]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "되돌리기 opens the same document again")
        XCTAssertTrue(waitSelected(back), "…chosen")
        let alpha = tab("Alpha", app: app), gamma = tab("Gamma", app: app)
        XCTAssertLessThan(alpha.frame.minX, back.frame.minX, "…in its place between Alpha and Gamma")
        XCTAssertLessThan(back.frame.minX, gamma.frame.minX)
        XCTAssertFalse(app.staticTexts["탭을 닫았어요"].exists)
    }

    @MainActor
    func testSpreadOpensTheNewTabMenuOrTheKindChosenInSettings() throws {
        let app = launch(["--native-tab-gesture-fixture"])
        createCourse("Spread Course", app: app)
        createNote("Alpha", app: app)
        let before = tabs(app).count
        tapFixture("open", app: app)
        let markdown = app.buttons["native-new-tab-new-note"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 5), "매번 고르기 (the default) shows the ＋ menu: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["native-new-tab-new-browser"].exists)
        capture("Spread: the ＋ menu")
        markdown.tap()
        expectTabCount(before + 1, app: app)
        app.dismissNativeTestKeyboard()

        openGestureSettings(app)
        let toggle = app.switches["native-settings-tab-gesture"]
        XCTAssertEqual(toggle.value as? String, "1", "On by default")
        let kind = app.buttons["native-settings-tab-gesture-open"]
        XCTAssertTrue(kind.exists); XCTAssertTrue(kind.label.contains("매번 고르기"), kind.label)
        kind.tap()
        let browser = app.buttons["native-settings-tab-gesture-open-new-browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["native-settings-tab-gesture-open-choose"].exists)
        capture("Settings: what a spread opens")
        browser.tap()
        XCTAssertTrue(waitLabel(kind, contains: "브라우저"), kind.label)
        closeSettings(app)
        let browsers = tabs(app).count
        XCTAssertFalse(app.buttons["native-browser-back"].exists)
        tapFixture("open", app: app)
        // The tab takes the page's title as soon as it loads; the browser's own row says what it is.
        XCTAssertTrue(app.buttons["native-browser-back"].waitForExistence(timeout: 15), "브라우저 chosen: the spread opens it straight away: \(app.debugDescription)")
        expectTabCount(browsers + 1, app: app)
        XCTAssertFalse(app.buttons["native-new-tab-new-note"].exists, "…without the menu")
        capture("Spread with 브라우저 chosen")
        let opened = tabs(app).count

        openGestureSettings(app)
        toggle.tap()
        XCTAssertTrue(waitValue(toggle, "0"), app.debugDescription)
        XCTAssertFalse(kind.exists, "Off: nothing to choose")
        closeSettings(app)
        tapFixture("close", app: app)
        sleep(2)
        XCTAssertEqual(tabs(app).count, opened, "Off: three fingers close nothing")
        XCTAssertFalse(app.staticTexts["탭을 닫았어요"].exists)
    }

    @MainActor
    func testNewFeatureCardShowsOnceAndOpensItsSettings() throws {
        let app = launch([NativeGuideFlags.intro])
        let card = app.descendants(matching: .any)["native-tab-gesture-intro"]
        XCTAssertTrue(card.waitForExistence(timeout: 25), "The card waits for a quiet workspace, then shows: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["손가락 3개로 탭 열고 닫기"].exists)
        XCTAssertTrue(app.staticTexts["세 손가락을 모으면 탭이 닫혀요"].exists)
        XCTAssertTrue(app.staticTexts["모았다가 펴면 새 탭을 열어요"].exists)
        XCTAssertTrue(app.buttons["native-tab-gesture-intro-ok"].exists)
        capture("New feature: three-finger tabs")
        app.buttons["native-tab-gesture-intro-settings"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.switches["native-settings-tab-gesture"].waitForExistence(timeout: 10), "설정에서 열 탭 고르기 opens 일반 › 더 보기: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["native-settings-tab-gesture-open"].exists)

        app.terminate()
        app.launchArguments = ["--native-ui-testing", NativeGuideFlags.intro]
        app.launch()
        XCTAssertTrue(app.buttons["native-section-settings"].waitForExistence(timeout: 25))
        XCTAssertFalse(card.waitForExistence(timeout: 6), "Once only")
    }

    @MainActor
    func testTourWalksThroughItsPagesAndOpensAgainFromHelpAndSettings() throws {
        let app = launch([NativeGuideFlags.tour])
        let tour = app.descendants(matching: .any)["native-guide-tour"]
        XCTAssertTrue(tour.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts["반달 잘 쓰는 법"].exists)
        var pages: [String] = []
        for _ in 0..<8 {
            let page = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'native-guide-tour-page-'")).firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 5), app.debugDescription)
            pages.append(String(page.identifier.dropFirst("native-guide-tour-page-".count)))
            capture("Tour · " + pages.last!)
            if app.buttons["native-guide-tour-done"].exists { app.buttons["native-guide-tour-done"].tap(); break }
            app.buttons["native-guide-tour-next"].tap()
        }
        XCTAssertEqual(Array(pages.prefix(5)), ["pdf", "lookup", "ai", "split", "school"])
        XCTAssertTrue((4...6).contains(pages.count), "\(pages)")
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5))

        // 도움말 › 반달 잘 쓰는 법.
        app.buttons["native-section-account"].tap()
        XCTAssertTrue(app.buttons["native-account-help"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["native-account-help"].tap()
        XCTAssertTrue(app.buttons["native-help-tour"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["native-help-tour"].tap()
        XCTAssertTrue(tour.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["native-guide-tour-page-pdf"].exists, "It opens at its first page")
        app.buttons["native-guide-tour-next"].tap()
        XCTAssertTrue(app.buttons["native-guide-tour-back"].waitForExistence(timeout: 3))
        app.buttons["native-guide-tour-skip"].tap()
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5))

        // 설정 › 일반 › 더 보기 › 반달 잘 쓰는 법.
        openGestureSettings(app)
        app.buttons["native-settings-guide-tour"].tap()
        XCTAssertTrue(tour.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["native-guide-tour-skip"].tap()
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testFirstUseTipShowsOnceAndStopAllEndsTips() throws {
        let app = launch([NativeGuideFlags.tips])
        createCourse("Tips Course", app: app)
        openFromPlus("chat", app: app)
        let tip = app.descendants(matching: .any)["native-guide-tip-ai"]
        XCTAssertTrue(tip.waitForExistence(timeout: 10), "The first AI tab brings the AI tip: \(app.debugDescription)")
        capture("First-use tip: AI")
        app.buttons["native-guide-tip-stop"].tap()
        XCTAssertTrue(tip.waitForNonExistence(timeout: 5))
        openGestureSettings(app)
        let tips = app.switches["native-settings-guide-tips"]
        XCTAssertTrue(tips.waitForExistence(timeout: 5))
        XCTAssertEqual(tips.value as? String, "0", "팁 그만 보기 turns the setting off")
        tips.tap()
        XCTAssertTrue(waitValue(tips, "1"))
        closeSettings(app)
        openFromPlus("chat", app: app)
        XCTAssertTrue(tip.waitForExistence(timeout: 10), "On again: each tip once more")
        app.buttons["native-guide-tip-ok"].tap()
        XCTAssertTrue(tip.waitForNonExistence(timeout: 5))
        openFromPlus("chat", app: app)
        XCTAssertFalse(tip.waitForExistence(timeout: 4), "Once only")
    }

    /// The lasso's tip comes when a PDF's palette picks the lasso (its watcher is a view of its own, not the window's).
    @MainActor
    func testLassoTipShowsWhenThePaletteChoosesTheLasso() throws {
        let app = launch([NativeGuideFlags.tips])
        createCourse("Lasso Tip Course", app: app)
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Lasso")
        app.buttons["native-new-note-create"].tap()
        let pdfTip = app.descendants(matching: .any)["native-guide-tip-pdf"]
        XCTAssertTrue(pdfTip.waitForExistence(timeout: 20), "A first PDF brings its tip: \(app.debugDescription)")
        app.buttons["native-guide-tip-ok"].tap()
        XCTAssertTrue(pdfTip.waitForNonExistence(timeout: 5))
        let lasso = app.buttons["native-pdf-tool-lasso"]
        XCTAssertTrue(lasso.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !lasso.isHittable { app.scrollViews["native-pdf-tool-scroll"].swipeLeft() }
        lasso.tap()
        XCTAssertTrue(app.descendants(matching: .any)["native-guide-tip-lasso"].waitForExistence(timeout: 10), app.debugDescription)
    }

    // MARK: Helpers

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        return app
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func createNote(_ title: String, app: XCUIApplication) {
        let add = app.buttons["native-library-create"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["새 마크다운"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["만들기"].tap()
        XCTAssertTrue(tab(title, app: app).waitForExistence(timeout: 15), app.debugDescription)
        app.dismissNativeTestKeyboard()
    }
    @MainActor private func openFromPlus(_ item: String, app: XCUIApplication) {
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-dock-add-'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
        let row = app.buttons["native-new-tab-" + item]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription); row.tap()
    }
    @MainActor private func tab(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-document-tab-' AND label CONTAINS %@", title)).firstMatch
    }
    @MainActor private func tabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-document-tab-'")).allElementsBoundByIndex
    }
    @MainActor private func expectTabCount(_ count: Int, app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.tabs(app).count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, app.debugDescription)
    }
    @MainActor private func tapFixture(_ kind: String, pane: Int = 0, app: XCUIApplication) {
        let button = app.buttons["native-tab-gesture-fixture-\(kind)-\(pane)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription); button.tap()
    }
    @MainActor private func openGestureSettings(_ app: XCUIApplication) {
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["native-settings-category-general"].waitForExistence(timeout: 10), app.debugDescription)
        if !app.switches["native-settings-tab-gesture"].exists { app.openNativeSettingsMore() }
        XCTAssertTrue(app.switches["native-settings-tab-gesture"].waitForExistence(timeout: 10), "세 손가락 lives in 일반 › 더 보기 › 탭: \(app.debugDescription)")
    }
    @MainActor private func closeSettings(_ app: XCUIApplication) {
        let close = app.buttons["native-settings-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), app.debugDescription)
    }
    private func waitSelected(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)], timeout: 5) == .completed
    }
    private func waitValue(_ element: XCUIElement, _ value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 5) == .completed
    }
    private func waitLabel(_ element: XCUIElement, contains text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: 5) == .completed
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private enum NativeGuideFlags {
    static let intro = "--native-guide-intro"
    static let tour = "--native-guide-tour"
    static let tips = "--native-guide-tips"
}
