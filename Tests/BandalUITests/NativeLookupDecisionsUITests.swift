import XCTest

/// 찾아보기's decision step against the seeded Markdown note (`--native-search-fixture`), with Wikipedia answered by
/// `--native-auto-lookup-fixture` and the decision by `--lookup-decisions-fixture` (NativeQuickLookupDecideFixture):
/// no network is used. Each passage is one whose card the decision changes: without it the search's own pick differs.
final class NativeLookupDecisionsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The decision picks 열역학 제2법칙 (the search alone finds no article for its key term "않는다").
    private static let lawPassage = "고립계에서 엔트로피가 줄지 않는다는 법칙을 말한다."
    /// The decision says none of the articles fits (the search alone shows the 엔트로피 article).
    private static let unrelatedPassage = "엔트로피 경제학이라는 말은 경제를 엔트로피에 빗댄 표현이다."
    /// Not worth a card (the search alone shows a 웹에서 검색 line).
    private static let noticePassage = "과제는 다음 주 금요일까지 제출하세요."

    @MainActor
    func testTheDecisionChoosesTheArticleASearchLinkOrNoCard() throws {
        let app = launch()
        let editor = openNote(in: app)

        selectNewLine(Self.lawPassage, in: editor, app: app)
        var card = expectCard("auto-wikipedia-ko", in: app)
        let open = card.buttons["native-quick-lookup-open"]
        XCTAssertTrue(open.label.contains("열역학 제2법칙") && open.label.contains("ko.wikipedia.org"), open.label)
        XCTAssertFalse(card.descendants(matching: .any)["native-quick-lookup-ai"].exists, "a decision writes nothing: no AI 설명 badge")
        attach(app, "Decision: the article it chose")
        close(card, in: app)

        selectNewLine(Self.unrelatedPassage, in: editor, app: app)
        card = expectCard("auto-search", in: app)
        XCTAssertTrue(card.buttons["native-quick-lookup-open"].label.contains("웹에서 검색"), card.buttons["native-quick-lookup-open"].label)
        XCTAssertFalse(app.webViews["native-quick-lookup-preview"].exists, "a search link loads nothing by itself")
        attach(app, "Decision: none of the articles, a search link")
        close(card, in: app)

        selectNewLine(Self.noticePassage, in: editor, app: app)
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-card"].exists, "not worth a card\n" + app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-consent"].exists)
        attach(app, "Decision: not worth a card")
    }

    /// 설정 › AI › 찾아보기 has the switch, on by default and following the automatic lookup; off, a passage gets the
    /// search's own pick again.
    @MainActor
    func testTheDecisionIsASwitchInSettings() throws {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-ai"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        let toggle = app.switches["native-settings-lookup-decide"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        XCTAssertTrue(toggle.isEnabled)
        attach(app, "Settings › AI › 찾아보기 with the decision switch")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let auto = app.switches["native-settings-auto-lookup"]
        auto.tap()
        XCTAssertFalse(toggle.isEnabled, "follows the automatic lookup")
        auto.tap()
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["native-section-library"].tap()
        XCTAssertTrue(app.buttons["native-material-2주차 정리.md"].waitForExistence(timeout: 10), app.debugDescription)

        let editor = openNote(in: app)
        selectNewLine(Self.lawPassage, in: editor, app: app)
        let card = expectCard("auto-search", in: app)
        XCTAssertFalse(card.buttons["native-quick-lookup-open"].label.contains("열역학 제2법칙"), card.buttons["native-quick-lookup-open"].label)
        attach(app, "Decision off: the search's own pick")
    }

    // MARK: helpers

    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture", "--native-auto-lookup-fixture",
                               "--native-auto-lookup-on", "--lookup-decisions-fixture"]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-material-노트"].waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        return app
    }

    @MainActor private func openNote(in app: XCUIApplication) -> XCUIElement {
        app.buttons["native-material-2주차 정리.md"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        return editor
    }

    /// Types `text` as a new last line of the note, waits a moment and selects that line with the keyboard.
    @MainActor private func selectNewLine(_ text: String, in editor: XCUIElement, app: XCUIApplication) {
        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n" + text)
        // A selection right after typing counts as part of the typing.
        sleep(1)
        editor.typeKey(.leftArrow, modifierFlags: [.shift, .command])
    }

    @discardableResult
    @MainActor private func expectCard(_ state: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let card = app.descendants(matching: .any)["native-quick-lookup-card"]
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", state), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: timeout), .completed, "card: \(card.exists ? (card.value as? String ?? "") : "none")\n" + app.debugDescription)
        return card
    }

    @MainActor private func close(_ card: XCUIElement, in app: XCUIApplication) {
        app.buttons["native-quick-lookup-close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), app.debugDescription)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
