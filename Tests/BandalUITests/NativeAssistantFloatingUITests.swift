import XCTest

/// The AI panel's 표시 방식 (사이드바 · 플로팅): one conversation in either place. Switching keeps the draft and an
/// answer still streaming; the choice survives a relaunch; floating, the page still takes the pen around the bar,
/// and the bar steps aside for the page's selection menu and toast. Each step attaches what was on screen.
final class NativeAssistantFloatingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSwitchingKeepsTheDraftAndIsRemembered() {
        let app = launch(extra: ["--native-ai-catalog-fixture"])
        openNoteAndAI(app)
        // The header: no mark or "AI 도우미", the model and the 표시 방식 menu.
        XCTAssertFalse(app.staticTexts["AI 도우미"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["native-ai-model-pill"].exists, app.debugDescription)
        XCTAssertEqual(menu(app).value as? String, "사이드바")
        attach("1 sidebar header")
        let draft = "초안이 그대로 남아야 해요"
        let input = app.descendants(matching: .any)["native-chat-input"]
        input.tap(); input.typeText(draft); app.dismissNativeTestKeyboard()
        choose("플로팅", in: app, checking: "사이드바")
        XCTAssertTrue(app.otherElements["native-ai-floating-bar"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(menu(app).value as? String, "플로팅")
        XCTAssertEqual(input.value as? String, draft)
        attach("2 floating with the draft")
        // Remembered: the next launch opens floating, with the draft.
        app.terminate(); app.launchArguments = arguments(reset: false, extra: ["--native-ai-catalog-fixture"]); app.launch()
        XCTAssertTrue(app.otherElements["native-ai-floating-bar"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(menu(app).value as? String, "플로팅")
        XCTAssertEqual(app.descendants(matching: .any)["native-chat-input"].value as? String, draft)
        attach("3 relaunched floating")
        choose("사이드바", in: app, checking: "플로팅")
        XCTAssertTrue(app.otherElements["native-ai-floating-bar"].waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.descendants(matching: .any)["native-chat-input"].value as? String, draft)
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].isHittable, app.debugDescription)
        attach("4 back in the sidebar")
    }

    @MainActor func testSwitchingWhileTheAnswerStreams() {
        let app = launch(extra: ["--native-ai-catalog-fixture", "--native-ai-stream-fixture"])
        openNoteAndAI(app)
        // The fixture's sixteen numbered paragraphs are drawn as a numbered list: one "N." marker per item that has arrived.
        func item(_ number: Int, in scope: XCUIElement) -> XCUIElement { scope.staticTexts["\(number)."].firstMatch }
        XCTAssertTrue(item(1, in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(item(2, in: app).waitForExistence(timeout: 20), app.debugDescription)
        attach("1 streaming in the sidebar")
        choose("플로팅", in: app, checking: "사이드바")
        let card = app.otherElements["native-ai-floating-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        // The answer is the same one, from its first item, and still coming in.
        XCTAssertTrue(item(1, in: card).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(item(2, in: card).exists, app.debugDescription)
        let atSwitch = (1...16).last { item($0, in: card).exists } ?? 0
        XCTAssertEqual(app.buttons["native-chat-send"].label, "응답 중지")
        attach("2 streaming in the card")
        XCTAssertLessThan(atSwitch, 15, "still on its way at the switch")
        XCTAssertTrue(item(atSwitch + 2, in: card).waitForExistence(timeout: 40), "it carries on in the card past item \(atSwitch): " + app.debugDescription)
        attach("3 still streaming in the card")
        choose("사이드바", in: app, checking: "플로팅")
        XCTAssertTrue(item(16, in: app).waitForExistence(timeout: 90), app.debugDescription)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "보내기"), object: app.buttons["native-chat-send"])
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["복사"].waitForExistence(timeout: 10), app.debugDescription)
        attach("4 finished in the sidebar")
    }

    /// In dark: the glass over a white page.
    @MainActor func testThePageTakesThePenAroundTheBar() {
        let app = launch(extra: ["--native-ai-catalog-fixture", "--native-pencil-dispatch-fixture", "--native-ai-answer-fixture", "-native.appearance", "dark"])
        openNoteAndAI(app)
        choose("플로팅", in: app, checking: "사이드바")
        let bar = app.otherElements["native-ai-floating-bar"], card = app.otherElements["native-ai-floating-card"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(card.buttons["복사"].waitForExistence(timeout: 10), app.debugDescription)
        let pen = app.buttons["native-pdf-tool-pen"]
        if !pen.isSelected { pen.tap() }
        // Beside the bar (the page starts some 60 pt left of it), just above the card, and in the middle of the page.
        stroke(app, from: CGPoint(x: bar.frame.minX - 50, y: bar.frame.midY - 15), by: CGVector(dx: 34, dy: 30))
        stroke(app, from: CGPoint(x: card.frame.midX - 60, y: card.frame.minY - 30), by: CGVector(dx: 120, dy: 10))
        stroke(app, from: CGPoint(x: card.frame.midX - 80, y: card.frame.minY - 180), by: CGVector(dx: 160, dy: 40))
        expectInk(3, in: app)
        // On the card itself nothing reaches the page.
        stroke(app, from: CGPoint(x: card.frame.midX - 40, y: card.frame.minY + 14), by: CGVector(dx: 60, dy: 0))
        sleep(2); expectInk(3, in: app)
        attach("1 three strokes around the bar")
        // 노트에 넣기 from the card: the page's toast comes up under the bar, and the bar rises above it.
        card.buttons["노트에 넣기"].tap()
        let toast = app.descendants(matching: .any)["bandal-toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        XCTAssertLessThan(bar.frame.maxY, toast.frame.minY, "The bar sits above the toast\n" + app.debugDescription)
        attach("2 the bar above the note toast")
    }

    @MainActor func testTheBarStepsAsideForTheSelectionMenu() {
        let app = launch(extra: ["--native-ai-catalog-fixture", "--native-pencil-dispatch-fixture"])
        openNoteAndAI(app)
        choose("플로팅", in: app, checking: "사이드바")
        let bar = app.otherElements["native-ai-floating-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        let pen = app.buttons["native-pdf-tool-pen"]
        if !pen.isSelected { pen.tap() }
        // A stroke low on the page, just above the card, then a box round it.
        let card = app.otherElements["native-ai-floating-card"]
        let low = CGPoint(x: card.frame.minX + 40, y: card.frame.minY - 70)
        stroke(app, from: low, by: CGVector(dx: 50, dy: 20))
        expectInk(1, in: app)
        // The lasso, as a box (its options open on a second tap).
        let lasso = app.buttons["native-pdf-tool-lasso"]
        XCTAssertTrue(lasso.waitForExistence(timeout: 10), app.debugDescription)
        if !lasso.isSelected { lasso.tap() }
        lasso.tap()
        let box = app.buttons["native-pdf-lasso-mode-box"]
        XCTAssertTrue(box.waitForExistence(timeout: 5), app.debugDescription); box.tap()
        app.buttons["native-pdf-style-close"].tap()
        stroke(app, from: CGPoint(x: low.x - 30, y: low.y - 30), by: CGVector(dx: 110, dy: 80))
        XCTAssertTrue(app.buttons["native-pdf-delete-selection"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "The bar steps aside while the selection menu is up\n" + app.debugDescription)
        attach("1 selection menu, no bar")
        app.buttons["native-pdf-selection-more"].tap()
        let clear = app.buttons["native-pdf-clear-selection"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), app.debugDescription); clear.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        attach("2 selection cleared, bar back")
    }

    /// Landscape, portrait, the keyboard, a fold, the model popover and two panes side by side.
    @MainActor func testFloatingLayouts() {
        let app = launch(extra: ["--native-ai-catalog-fixture", "--native-ai-answer-fixture"])
        openNoteAndAI(app)
        choose("플로팅", in: app, checking: "사이드바")
        let bar = app.otherElements["native-ai-floating-bar"], card = app.otherElements["native-ai-floating-card"]
        XCTAssertTrue(card.buttons["복사"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThanOrEqual(bar.frame.width, 561); XCTAssertLessThanOrEqual(card.frame.height, 381)
        attach("1 landscape")
        let input = app.descendants(matching: .any)["native-chat-input"]
        input.tap(); input.typeText("키보드 위로")
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            XCTAssertLessThanOrEqual(bar.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, app.debugDescription)
        }
        attach("2 keyboard")
        app.dismissNativeTestKeyboard()
        app.buttons["native-ai-floating-fold"].tap(); sleep(1)
        XCTAssertFalse(card.buttons["복사"].exists, app.debugDescription)
        attach("3 folded")
        app.buttons["native-ai-floating-fold"].tap()
        XCTAssertTrue(card.buttons["복사"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["native-ai-model-pill"].tap()
        XCTAssertTrue(app.buttons["native-ai-model-default"].waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        // Low on the screen it opens where the whole list fits, down to the last model.
        XCTAssertTrue(app.buttons["native-ai-model-gpt-6-astra"].isHittable, app.debugDescription)
        attach("4 model popover")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(bar.frame.minX, app.windows.firstMatch.frame.minX)
        attach("5 portrait")
        // Two panes: the bar floats over the document area as a whole.
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), app.debugDescription); plus.tap()
        app.buttons["native-new-tab-new-whiteboard"].tap(); app.confirmNewNote(title: "Two")
        let columns = app.buttons["native-dock-preset-columns"]
        app.openNativeDockLayoutMenu()
        if !columns.waitForExistence(timeout: 8) { app.openNativeDockLayoutMenu() }
        XCTAssertTrue(columns.waitForExistence(timeout: 8), app.debugDescription); columns.tap(); sleep(2)
        attach("6 portrait two panes")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        attach("7 landscape two panes")
        app.buttons["native-ai-close"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["native-ai-rail-toggle"].label, "AI 열기")
        attach("8 closed")
    }

    // MARK: Helpers

    @MainActor private func launch(extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments(reset: true, extra: extra); app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Floating")
        app.buttons["native-create-course"].tap(); sleep(1)
        return app
    }
    private func arguments(reset: Bool, extra: [String]) -> [String] {
        ["--native-ui-testing"] + (reset ? ["--reset-native-ui-testing"] : []) + extra
    }
    @MainActor private func openNoteAndAI(_ app: XCUIApplication) {
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap(); app.confirmNewNote(title: "Float")
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if toggle.label == "AI 열기" { toggle.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].waitForExistence(timeout: 15), app.debugDescription); sleep(1)
    }
    @MainActor private func menu(_ app: XCUIApplication) -> XCUIElement { app.buttons["native-ai-presentation"].firstMatch }
    /// Opens 표시 방식, checks that `current` is the one ticked, and picks `option`.
    @MainActor private func choose(_ option: String, in app: XCUIApplication, checking current: String) {
        let button = menu(app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription); button.tap()
        let item = app.buttons[option], ticked = app.buttons[current]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(ticked.isSelected, "\(current) is ticked\n" + app.debugDescription)
        XCTAssertFalse(item.isSelected, app.debugDescription)
        attach("menu: \(current) → \(option)")
        item.tap(); sleep(1)
    }
    @MainActor private func waitFor(_ element: XCUIElement, _ format: String, _ text: String, timeout: TimeInterval = 20) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, element.debugDescription)
    }
    /// A press-drag in window points (with the pencil fixture a finger draws).
    @MainActor private func stroke(_ app: XCUIApplication, from point: CGPoint, by offset: CGVector) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: point.x, dy: point.y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset), withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func expectInk(_ count: Int, in app: XCUIApplication) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 25), .completed, app.debugDescription)
    }
    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
