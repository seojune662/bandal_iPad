import XCTest

/// 노트에 넣기 and draw_diagram on a real PDF page: where the insertion lands, its toast, and 되돌리기.
/// `--native-pages-fixture` makes the new note a printed page ("Page One" across the middle);
/// the screenshots are the evidence for placement, the assertions for the flow.
final class NativeAINotePlacementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testNoteLandsInFreeSpaceAndUndoes() {
        let app = launch(["--native-pages-fixture"])
        XCTAssertEqual(drawings(app), 0)
        insert(app)
        XCTAssertTrue(app.staticTexts["노트에 넣었어요"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitForDrawings(app, 1), "one text box")
        attach(app, "note-inserted")
        undo(app)
        XCTAssertTrue(waitForDrawings(app, 0), "one undo takes it back")
        attach(app, "note-undone")
    }

    @MainActor func testDiagramIsDrawnAsShapesAndUndoesInOneStep() {
        let app = launch(["--native-pages-fixture", "--native-ai-diagram-fixture"])
        insert(app)
        XCTAssertTrue(app.staticTexts["도식을 넣었어요"].waitForExistence(timeout: 15), app.debugDescription)
        // Five boxes (text box + outline each), the title, five arrows (one routed in three pieces) and a label.
        let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", ".* drawings=(1[5-9]|2[0-9]) .*"), object: body(app))
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 10), .completed, "\(body(app).value ?? "")")
        attach(app, "diagram-inserted")
        undo(app)
        XCTAssertTrue(waitForDrawings(app, 0), "the whole diagram goes in one undo")
        attach(app, "diagram-undone")
    }

    @MainActor func testAnswerTooLongForThePageGoesToThePageNote() {
        let app = launch(["--native-ai-long-answer-fixture"])
        insert(app)
        XCTAssertTrue(app.staticTexts["빈 곳이 없어 페이지 필기에 넣었어요"].waitForExistence(timeout: 20), app.debugDescription)
        attach(app, "page-note-toast")
        let first = openPageNote(app)
        XCTAssertTrue((first.value as? String ?? "").contains("인터뷰 5명 중 4명"), "\(first.value ?? "")")
        attach(app, "page-note-content")
    }

    @MainActor func testPageNoteInsertionUndoesFromItsToast() {
        let app = launch(["--native-ai-long-answer-fixture"])
        insert(app)
        XCTAssertTrue(app.staticTexts["빈 곳이 없어 페이지 필기에 넣었어요"].waitForExistence(timeout: 20), app.debugDescription)
        undo(app); sleep(2)
        XCTAssertFalse(app.staticTexts["페이지 필기가 바뀌어 되돌리지 못했어요."].exists)
        let first = openPageNote(app)
        XCTAssertFalse((first.value as? String ?? "").contains("인터뷰 5명 중 4명"), "\(first.value ?? "")")
        attach(app, "page-note-undone")
    }

    // MARK: Steps

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", "light", "--native-ai-catalog-fixture", "--native-ai-answer-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("선형대수")
        app.buttons["native-create-course"].tap(); sleep(1)
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap(); app.confirmNewNote()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if toggle.label == "AI 열기" { toggle.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }
    @MainActor private func insert(_ app: XCUIApplication) {
        // The answer row's identifier covers its buttons' own (`native-ai-insert-note`): find it by its label.
        let insert = app.buttons.matching(NSPredicate(format: "label == %@", "노트에 넣기")).firstMatch
        XCTAssertTrue(insert.waitForExistence(timeout: 15), app.debugDescription); sleep(2)
        attach(app, "before")
        insert.tap()
    }
    /// The toast's 되돌리기 (its container's identifier covers the button's own), not the palette's.
    @MainActor private func undo(_ app: XCUIApplication) {
        let action = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "되돌리기", "native-pdf-undo")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription); action.tap()
    }
    @MainActor private func body(_ app: XCUIApplication) -> XCUIElement { app.otherElements["bandal-native-pdf-body"].firstMatch }
    /// The page's saved objects, from its accessibility value (` drawings=N `).
    @MainActor private func drawings(_ app: XCUIApplication) -> Int? {
        let value = body(app).value as? String ?? ""
        guard let range = value.range(of: #"drawings=\d+"#, options: .regularExpression) else { return nil }
        return Int(value[range].dropFirst("drawings=".count))
    }
    @MainActor private func waitForDrawings(_ app: XCUIApplication, _ count: Int) -> Bool {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", " drawings=\(count) "), object: body(app))
        return XCTWaiter.wait(for: [done], timeout: 10) == .completed
    }
    @MainActor private func openPageNote(_ app: XCUIApplication) -> XCUIElement {
        app.openNativePDFViewMenu()
        let row = app.buttons["native-pdf-page-note"]
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        let first = app.textViews["native-markdown-page-editor-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription); sleep(1)
        return first
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
