import XCTest

/// 자동 찾아보기 against the seeded lecture PDF and Markdown note (`--native-search-fixture`), with Wikipedia and
/// the model answered by `--native-auto-lookup-fixture` / `--native-auto-lookup-ai-fixture`: no network is used.
final class NativeAutoLookupUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private static let sentence = "Entropy of an isolated system never decreases."

    /// The first lasso asks once; after 켜기 the card comes, stays about five seconds and leaves by itself.
    /// The same lasso again shows it from the cache; a finger dragged on it keeps it; ✕ closes it.
    @MainActor
    func testALassoAroundPrintedTextShowsACardThatLeavesByItself() throws {
        let app = launch(["--native-pencil-dispatch-fixture"])
        openLecture(in: app)
        selectTool("lasso", in: app)
        lassoOption("native-pdf-lasso-mode-box", in: app)

        lasso(around: app.staticTexts["열역학 제2법칙"], in: app)
        let consent = app.descendants(matching: .any)["native-quick-lookup-consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10), "the first automatic lookup asks first\n" + app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-card"].exists, "nothing is looked up before the answer")
        attach(app, "First lasso: the one-time question")
        app.buttons["native-quick-lookup-consent-on"].tap()

        var card = expectCard("auto-wikipedia-ko", in: app)
        let shown = Date()
        let open = card.buttons["native-quick-lookup-open"]
        XCTAssertTrue(open.label.contains("열역학 제2법칙") && open.label.contains("ko.wikipedia.org"), open.label)
        XCTAssertFalse(app.webViews["native-quick-lookup-preview"].exists, "a card by itself never loads a page")
        assertBottomLeft(card, of: app.otherElements["native-pdf-workspace"], in: app)
        attach(app, "Lasso over the heading: the small card")
        sleep(3)
        XCTAssertTrue(card.exists, "still there after three seconds")
        XCTAssertTrue(card.waitForNonExistence(timeout: 8), "leaves by itself")
        XCTAssertLessThan(Date().timeIntervalSince(shown), 10.5)
        XCTAssertFalse(consent.exists, "asked once")

        // Again: from the cache, and a finger left on it keeps it without opening anything.
        app.otherElements["native-pdf-workspace"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        lasso(around: app.staticTexts["열역학 제2법칙"], in: app)
        card = expectCard("auto-wikipedia-ko", in: app, timeout: 5)
        card.buttons["native-quick-lookup-open"].press(forDuration: 1.2)
        sleep(9)
        XCTAssertTrue(card.exists, "a touched card is being read and stays")
        XCTAssertFalse(app.textFields["native-browser-address"].exists, "holding is not opening")
        app.buttons["native-quick-lookup-close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
    }

    /// A lasso that catches ink is only a selection, as before.
    @MainActor
    func testALassoAroundInkOnlySelects() throws {
        let app = launch(["--native-pencil-dispatch-fixture", "--native-auto-lookup-on"])
        openLecture(in: app)
        let pdf = app.otherElements["native-pdf-workspace"]
        selectTool("pen", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 0.05,
            thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.62)), withVelocity: .slow, thenHoldForDuration: 0.3)
        selectTool("lasso", in: app)
        lassoOption("native-pdf-lasso-mode-box", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)).press(forDuration: 0.05,
            thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.68)), withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["native-pdf-selection-more"].waitForExistence(timeout: 10), "the ink is selected\n" + app.debugDescription)
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-card"].exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-consent"].exists)
        attach(app, "Lasso around ink: selection only")

        // Printed text on the same page still looks itself up.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        lasso(around: app.staticTexts[Self.sentence], in: app)
        let card = expectCard("auto-wikipedia-en", in: app)
        XCTAssertTrue(card.buttons["native-quick-lookup-open"].label.contains("Entropy"), card.buttons["native-quick-lookup-open"].label)
        attach(app, "Lasso over an English line: English Wikipedia")
    }

    /// A Markdown selection that rests looks itself up; the card opens its article in a browser tab.
    @MainActor
    func testAMarkdownSelectionShowsACardThatOpensInTheBrowser() throws {
        let app = launch(["--native-auto-lookup-on"])
        app.buttons["native-material-2주차 정리.md"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)

        selectNewLine("엔트로피", in: editor, app: app)
        let card = expectCard("auto-wikipedia-ko", in: app)
        assertBottomLeft(card, of: editor, in: app)
        attach(app, "Markdown selection: the small card")
        card.buttons["native-quick-lookup-open"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        let address = app.textFields["native-browser-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), app.debugDescription)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "wikipedia.org"), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, "address: \(address.value as? String ?? "")")
        attach(app, "Card tapped: the article in a browser tab")

        // Typing never brings a card: the line typed last is not looked up while it is being written.
        backToTab("2주차 정리.md", in: app)
        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n카르노")
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-card"].exists, app.debugDescription)

        // Nothing found: one line to search the web, no page loaded by itself.
        sleep(1)
        editor.typeKey(.leftArrow, modifierFlags: [.shift, .command])
        let search = expectCard("auto-search", in: app)
        XCTAssertTrue(search.buttons["native-quick-lookup-open"].label.contains("웹에서 검색"), search.buttons["native-quick-lookup-open"].label)
        XCTAssertFalse(app.webViews["native-quick-lookup-preview"].exists)
        attach(app, "Markdown selection with no article: 웹에서 검색")
    }

    /// Off in Settings › AI › 찾아보기, nothing comes by itself; the 찾아보기 button still works.
    @MainActor
    func testTurnedOffInSettingsNothingComesByItself() throws {
        let app = launch(["--native-pencil-dispatch-fixture", "--native-auto-lookup-on"])
        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-ai"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        let toggle = app.switches["native-settings-auto-lookup"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1", "on from the launch argument")
        attach(app, "Settings › AI › 찾아보기")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.switches["native-settings-auto-lookup-ai"].isEnabled, "AI 설명 follows the automatic lookup")
        app.buttons["native-section-library"].tap()
        XCTAssertTrue(app.buttons["native-material-열역학 강의자료.pdf"].waitForExistence(timeout: 10), app.debugDescription)

        openLecture(in: app)
        selectTool("lasso", in: app)
        lassoOption("native-pdf-lasso-mode-box", in: app)
        lasso(around: app.staticTexts["열역학 제2법칙"], in: app)
        XCTAssertTrue(app.buttons["native-pdf-ask-ai"].waitForExistence(timeout: 10), "the empty lasso is still a selection\n" + app.debugDescription)
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-card"].exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["native-quick-lookup-consent"].exists)
        attach(app, "Turned off: the lasso only selects")
    }

    /// A Pro member who agreed to both providers: a passage gets AI 설명 (the fixed reply) with its formula,
    /// linked to the topic's article.
    @MainActor
    func testAPassageGetsAnAIExplanationWithItsFormula() throws {
        let app = launch(["--native-auto-lookup-on", "--native-auto-lookup-ai-fixture", "--native-pencil-dispatch-fixture"])
        app.buttons["native-material-2주차 정리.md"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        selectNewLine("엔트로피는 무질서도의 척도이고 볼츠만 식 S = k ln W 로 쓴다.", in: editor, app: app)
        let card = expectCard("auto-ai-wikipedia-ko", in: app)
        XCTAssertTrue(card.descendants(matching: .any)["native-quick-lookup-ai"].exists, app.debugDescription)
        XCTAssertTrue(card.descendants(matching: .any)["native-quick-lookup-formula"].exists, "the formula is in the text, so it is shown\n" + app.debugDescription)
        XCTAssertTrue(card.buttons["native-quick-lookup-open"].label.contains("ko.wikipedia.org"), card.buttons["native-quick-lookup-open"].label)
        attach(app, "Markdown passage: AI 설명 with a formula")
        app.buttons["native-quick-lookup-close"].tap()

        // Two lines of the PDF: AI 설명 without a formula (the reply's formula line is empty).
        app.buttons["native-material-열역학 강의자료.pdf"].tap()
        openLecture(in: app)
        selectTool("lasso", in: app)
        lassoOption("native-pdf-lasso-mode-box", in: app)
        let first = app.staticTexts["고립계의 엔트로피는 감소하지 않는다."].frame, second = app.staticTexts[Self.sentence].frame
        screen(app, first.minX - 12, first.minY - 8).press(forDuration: 0.05, thenDragTo: screen(app, max(first.maxX, second.maxX) + 12, second.maxY + 8),
                                                           withVelocity: .slow, thenHoldForDuration: 0.05)
        let pdfCard = expectCard("auto-ai-wikipedia-ko", in: app)
        XCTAssertFalse(pdfCard.descendants(matching: .any)["native-quick-lookup-formula"].exists)
        attach(app, "PDF passage: AI 설명")
    }

    // MARK: helpers

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture", "--native-auto-lookup-fixture"] + extra
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-material-노트"].waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        return app
    }

    @MainActor private func openLecture(in app: XCUIApplication) {
        app.buttons["native-material-열역학 강의자료.pdf"].tap()
        let tool = app.buttons["native-pdf-tool-select"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: tool)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        XCTAssertTrue(app.staticTexts[Self.sentence].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// A box lasso a little larger than the line.
    @MainActor private func lasso(around line: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(line.waitForExistence(timeout: 10), app.debugDescription)
        let frame = line.frame
        screen(app, frame.minX - 12, frame.minY - 8).press(forDuration: 0.05, thenDragTo: screen(app, frame.maxX + 12, frame.maxY + 8),
                                                           withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    @discardableResult
    @MainActor private func expectCard(_ state: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let card = app.descendants(matching: .any)["native-quick-lookup-card"]
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", state), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: timeout), .completed, "card: \(card.exists ? (card.value as? String ?? "") : "none")\n" + app.debugDescription)
        return card
    }

    /// At the bottom left of the part of the document that shows (above the keyboard when it is up).
    @MainActor private func assertBottomLeft(_ card: XCUIElement, of pane: XCUIElement, in app: XCUIApplication) {
        let area = pane.frame, keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists && keyboard.frame.height > 0 ? min(area.maxY, keyboard.frame.minY) : area.maxY
        let place = "card \(card.frame) in \(area), bottom \(bottom)"
        XCTAssertGreaterThan(card.frame.midY, (area.minY + bottom) / 2, place)
        XCTAssertLessThanOrEqual(card.frame.maxY, bottom + 1, place)
        XCTAssertLessThan(card.frame.minX, area.midX, place)
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

    @MainActor private func backToTab(_ title: String, in app: XCUIApplication) {
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-document-tab-", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription); tab.tap()
        sleep(1)
    }

    @MainActor private func selectTool(_ name: String, in app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + name]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if item.isSelected { return }
        if !item.isHittable { app.scrollViews["native-pdf-tool-scroll"].slide(toShow: item) }
        if !item.isHittable { app.scrollViews["native-pdf-palette-scroll"].slide(toShow: item) }
        item.tap()
    }

    @MainActor private func lassoOption(_ identifier: String, in app: XCUIApplication) {
        app.buttons["native-pdf-tool-lasso"].tap()
        let option = app.buttons[identifier]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription); option.tap()
        app.buttons["native-pdf-style-close"].tap()
    }

    @MainActor private func screen(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
