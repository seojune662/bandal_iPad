import XCTest

/// 찾아보기 and AI에게 묻기 against the seeded lecture PDF and Markdown note (`--native-search-fixture`).
/// The word and offline cases need no network; the Wikipedia and search cases reach the real sites.
final class NativeQuickLookupUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private static let sentence = "Entropy of an isolated system never decreases."

    @MainActor
    func testPDFWordTermAndSentenceCardsOpenInTheBrowser() throws {
        let app = launch()
        openLecture(in: app)

        // A word: the bundled dictionary, no network.
        pressWord(app.staticTexts[Self.sentence], in: app)
        expectQuote("Entropy", in: app)
        let card = lookUp(in: app, expecting: "dictionary")
        XCTAssertTrue(card.staticTexts["entropy"].exists, app.debugDescription)
        attach(app, "PDF word: dictionary card")
        openInBrowser(app, expecting: "wiktionary.org")
        backToTab("열역학 강의자료.pdf", in: app)

        // A short term: the Korean Wikipedia summary.
        pressWord(app.staticTexts["열역학 제2법칙"], in: app)
        expectQuote("열역학", in: app)
        let term = lookUp(in: app, expecting: "wikipedia-ko")
        XCTAssertTrue(term.staticTexts["위키백과"].exists, app.debugDescription)
        attach(app, "PDF term: Korean Wikipedia card")
        openInBrowser(app, expecting: "wikipedia.org")
        backToTab("열역학 강의자료.pdf", in: app)

        // A sentence: the search engine's results in a small preview.
        pressLine(app.staticTexts[Self.sentence], in: app)
        expectQuote("Entropy of an isolated system never decrease", prefix: true, in: app)
        let search = lookUp(in: app, expecting: "search")
        XCTAssertTrue(search.staticTexts["Google 검색"].exists, app.debugDescription)
        XCTAssertTrue(app.webViews["native-quick-lookup-preview"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(2)
        attach(app, "PDF sentence: search preview card")
        openInBrowser(app, expecting: "google.com")
        XCTAssertFalse(app.webViews["native-quick-lookup-preview"].exists, "the preview web view goes with its card")
    }

    /// The search runs on the browser's engine. Naver answers a mobile page from another host
    /// (m.search.naver.com): the preview follows it and the card stays.
    @MainActor
    func testTheBrowsersSearchEngineAnswersInThePreview() throws {
        let app = launch()
        app.buttons["native-section-settings"].tap()
        let integrations = app.buttons["native-settings-category-integrations"]
        XCTAssertTrue(integrations.waitForExistence(timeout: 15), app.debugDescription); integrations.tap()
        let more = app.buttons["native-settings-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription); more.tap()
        let engine = app.descendants(matching: .any)["native-settings-search-engine"].firstMatch
        XCTAssertTrue(engine.waitForExistence(timeout: 10), app.debugDescription)
        if !engine.isHittable { app.swipeUp() }
        engine.tap()
        let naver = app.buttons["네이버"].firstMatch
        XCTAssertTrue(naver.waitForExistence(timeout: 5), app.debugDescription); naver.tap()
        sleep(1)
        app.buttons["native-section-library"].tap()
        let lecture = app.buttons["native-material-열역학 강의자료.pdf"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 10), app.debugDescription)
        openLecture(in: app)

        pressLine(app.staticTexts[Self.sentence], in: app)
        let card = lookUp(in: app, expecting: "search")
        XCTAssertTrue(card.staticTexts["네이버 검색"].exists, app.debugDescription)
        XCTAssertTrue(app.webViews["native-quick-lookup-preview"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(4)
        XCTAssertEqual(card.value as? String, "search", "the redirect to the mobile page neither closed the card nor failed it")
        attach(app, "Naver search preview card")
        openInBrowser(app, expecting: "naver.com")
    }

    @MainActor
    func testACardLeavesAfterAFewSecondsUnlessItIsTouched() throws {
        let app = launch()
        openLecture(in: app)
        pressWord(app.staticTexts[Self.sentence], in: app)
        expectQuote("Entropy", in: app)
        var card = lookUp(in: app, expecting: "dictionary")
        XCTAssertTrue(card.waitForNonExistence(timeout: 9), "an untouched card leaves after about five seconds")

        card = lookUp(in: app, expecting: "dictionary")
        card.staticTexts["entropy"].tap()
        sleep(9)
        XCTAssertTrue(card.exists, "a touched card is being read and stays")
        app.buttons["native-quick-lookup-close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))

        // A finger on the search preview scrolls the results and holds the card too.
        pressLine(app.staticTexts[Self.sentence], in: app)
        card = lookUp(in: app, expecting: "search")
        let preview = app.webViews["native-quick-lookup-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); sleep(2)
        let link = preview.links.element(boundBy: 2)
        XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
        let before = link.frame.minY
        preview.swipeUp()
        sleep(1)
        XCTAssertLessThan(link.frame.minY, before - 20, "the results scroll inside the card")
        sleep(11)
        XCTAssertTrue(card.exists, "a scrolled preview is being read and stays")
        attach(app, "Search preview scrolled and held")
        app.buttons["native-quick-lookup-close"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3), "closing the card releases its web view")
    }

    @MainActor
    func testMarkdownWordTermAndSentenceCardsOpenInTheBrowser() throws {
        let app = launch()
        app.buttons["native-material-2주차 정리.md"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)

        selectNewLine("matrix", in: editor, app: app)
        let word = lookUp(in: app, expecting: "dictionary")
        XCTAssertTrue(word.staticTexts["matrix"].exists, app.debugDescription)
        attach(app, "Markdown word: dictionary card")
        openInBrowser(app, expecting: "wiktionary.org")
        backToTab("2주차 정리.md", in: app)

        selectNewLine("linear algebra", in: editor, app: app)
        let term = lookUp(in: app, expecting: "wikipedia-en")
        XCTAssertTrue(term.staticTexts["Linear algebra"].exists, app.debugDescription)
        attach(app, "Markdown term: English Wikipedia card")
        openInBrowser(app, expecting: "wikipedia.org")
        backToTab("2주차 정리.md", in: app)

        selectNewLine("The determinant of a singular matrix is zero.", in: editor, app: app)
        _ = lookUp(in: app, expecting: "search")
        XCTAssertTrue(app.webViews["native-quick-lookup-preview"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(2)
        attach(app, "Markdown sentence: search preview card")
        openInBrowser(app, expecting: "google.com")
    }

    @MainActor
    func testOfflineTheDictionaryStillAnswersAndTheRestSaySo() throws {
        let app = launch(["--native-quick-lookup-offline"])
        openLecture(in: app)

        pressWord(app.staticTexts[Self.sentence], in: app)
        expectQuote("Entropy", in: app)
        _ = lookUp(in: app, expecting: "dictionary")
        attach(app, "Offline PDF word: dictionary card")
        app.buttons["native-quick-lookup-close"].tap()

        pressWord(app.staticTexts["열역학 제2법칙"], in: app)
        expectQuote("열역학", in: app)
        let term = lookUp(in: app, expecting: "unreachable")
        XCTAssertTrue(term.buttons["native-quick-lookup-retry"].exists, app.debugDescription)
        XCTAssertFalse(term.buttons["native-quick-lookup-open"].exists)
        attach(app, "Offline PDF term: unreachable card")
        term.buttons["native-quick-lookup-retry"].tap()
        _ = lookUp(in: app, expecting: "unreachable", tap: false)
        app.buttons["native-quick-lookup-close"].tap()

        pressLine(app.staticTexts[Self.sentence], in: app)
        expectQuote("Entropy of an isolated system", prefix: true, in: app)
        let sentence = lookUp(in: app, expecting: "unreachable")
        XCTAssertFalse(app.webViews["native-quick-lookup-preview"].exists, app.debugDescription)
        XCTAssertTrue(sentence.buttons["native-quick-lookup-retry"].exists)
        attach(app, "Offline PDF sentence: unreachable card")
        app.buttons["native-quick-lookup-close"].tap()

        app.buttons["native-material-2주차 정리.md"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        selectNewLine("linear algebra", in: editor, app: app)
        _ = lookUp(in: app, expecting: "unreachable")
        attach(app, "Offline Markdown term: unreachable card")
    }

    @MainActor
    func testLassoAskAIPutsTheAreaInTheComposer() throws {
        let app = launch(["--native-pencil-dispatch-fixture"])
        openLecture(in: app, select: false)
        let pdf = app.otherElements["native-pdf-workspace"]
        selectTool("lasso", in: app)
        lassoOption("native-pdf-lasso-mode-box", in: app)
        // An empty lasso over printed text: its bar has 이미지로 복사 and AI에게 묻기, no ⋯.
        let line = app.staticTexts["열역학 제2법칙"].frame
        screen(app, line.minX - 12, line.minY - 12).press(forDuration: 0.05, thenDragTo: screen(app, line.maxX + 12, line.maxY + 12),
                                                          withVelocity: .slow, thenHoldForDuration: 0.05)
        let ask = app.buttons["native-pdf-ask-ai"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "Empty lasso bar with AI에게 묻기")
        ask.tap()
        XCTAssertTrue(app.buttons["첨부 제거"].waitForExistence(timeout: 15), "the area is a draft attachment\n" + app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "첨부 제거")).count, 1)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-ai-attachment-")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5)); chip.tap()
        XCTAssertTrue(app.images["native-ai-attachment-preview-image"].waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "AI panel with the lasso area attached")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.04)).tap()

        // A lasso around ink: AI에게 묻기 is in its ⋯ menu.
        selectTool("pen", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 0.05,
            thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.62)), withVelocity: .slow, thenHoldForDuration: 0.3)
        selectTool("lasso", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)).press(forDuration: 0.05,
            thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.68)), withVelocity: .slow, thenHoldForDuration: 0.05)
        let more = app.buttons["native-pdf-selection-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription); more.tap()
        let row = app.buttons["native-pdf-ask-ai"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "Lasso ⋯ menu with AI에게 묻기")
        row.tap()
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: app.buttons.matching(NSPredicate(format: "label == %@", "첨부 제거")))
        XCTAssertEqual(XCTWaiter.wait(for: [two], timeout: 15), .completed, app.debugDescription)
        // Nothing was sent: the question is still the reader's to write.
        XCTAssertTrue(app.buttons["첨부 제거"].exists)
        attach(app, "Two lasso areas waiting in the composer")
    }

    // MARK: helpers

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture"] + extra
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-material-노트"].waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        return app
    }

    @MainActor private func openLecture(in app: XCUIApplication, select: Bool = true) {
        app.buttons["native-material-열역학 강의자료.pdf"].tap()
        let tool = app.buttons["native-pdf-tool-select"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: tool)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        if select { tool.tap() }
        XCTAssertTrue(app.staticTexts[Self.sentence].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// A long press on the first word of a PDF line (PDFKit exposes each line with its frame).
    @MainActor private func pressWord(_ line: XCUIElement, in app: XCUIApplication) {
        primeQuoteBar(in: app)
        let frame = line.frame
        screen(app, frame.minX + 16, frame.midY).press(forDuration: 0.7)
    }

    /// A long press on a line's first word dragged to its end selects the whole line.
    @MainActor private func pressLine(_ line: XCUIElement, in app: XCUIApplication) {
        primeQuoteBar(in: app)
        let frame = line.frame
        screen(app, frame.minX + 16, frame.midY).press(forDuration: 0.7, thenDragTo: screen(app, frame.maxX + 4, frame.midY))
    }

    /// The quote bar a selection brings sits above the page and pushes it down 44 pt; a finger still on the page
    /// then drags the new selection up a line (the app's behaviour before 찾아보기, reported with this change).
    /// A first selection brings the bar, so the selection that is measured happens on a page that stays put.
    @MainActor private func primeQuoteBar(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts[Self.sentence].waitForExistence(timeout: 10), app.debugDescription)
        guard !app.buttons["native-quick-lookup"].exists else { return }
        let frame = app.staticTexts["열역학 제2법칙"].frame
        screen(app, frame.maxX - 16, frame.midY).press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["native-quick-lookup"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(1)
    }

    /// The selected-quote bar above the page shows `text` (or text starting with it).
    @MainActor private func expectQuote(_ text: String, prefix: Bool = false, in app: XCUIApplication) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.buttons["native-quick-lookup"])
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, app.debugDescription)
        let top = app.otherElements["native-pdf-workspace"].frame.minY
        let bar = app.staticTexts.allElementsBoundByIndex.filter { $0.frame.maxY <= top + 1 && $0.frame.minY > top - 50 }.map(\.label)
        XCTAssertTrue(bar.contains { prefix ? $0.hasPrefix(text) : $0 == text }, "quote bar: \(bar)")
    }

    /// Taps 찾아보기 and waits for the card to say which answer it holds.
    @discardableResult
    @MainActor private func lookUp(in app: XCUIApplication, expecting state: String, tap: Bool = true) -> XCUIElement {
        if tap {
            let button = app.buttons["native-quick-lookup"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription); button.tap()
        }
        let card = app.descendants(matching: .any)["native-quick-lookup-card"]
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", state), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 20), .completed, "card: \(card.exists ? (card.value as? String ?? "") : "none")\n" + app.debugDescription)
        return card
    }

    /// 브라우저에서 열기 opens a tab of the in-app browser on the card's page.
    @MainActor private func openInBrowser(_ app: XCUIApplication, expecting host: String) {
        let open = app.buttons["native-quick-lookup-open"]
        XCTAssertTrue(open.exists, app.debugDescription); open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["native-quick-lookup-card"].waitForNonExistence(timeout: 5))
        let address = app.textFields["native-browser-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), app.debugDescription)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", host), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, "address: \(address.value as? String ?? "")")
        sleep(1)
        attach(app, "Browser tab on " + host)
    }

    @MainActor private func backToTab(_ title: String, in app: XCUIApplication) {
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-document-tab-", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription); tab.tap()
        sleep(1)
    }

    /// Types `text` as a new last line of the note and selects that line with the keyboard.
    @MainActor private func selectNewLine(_ text: String, in editor: XCUIElement, app: XCUIApplication) {
        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n" + text)
        editor.typeKey(.leftArrow, modifierFlags: [.shift, .command])
        let button = app.buttons["native-quick-lookup"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "selecting the line shows 찾아보기\n" + app.debugDescription)
    }

    @MainActor private func selectTool(_ name: String, in app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + name]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if item.isSelected { return }
        if !item.isHittable { app.scrollViews["native-pdf-tool-scroll"].slide(toShow: item) }
        if !item.isHittable { app.scrollViews["native-pdf-palette-scroll"].slide(toShow: item) }
        item.tap()
    }

    /// The lasso's options open on a second tap of the chosen tool.
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
