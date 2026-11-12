import XCTest

final class NativeRichMarkdownTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testRichFormattingSourceRoundTripTableAndNativeFormula() throws {
        let app = XCUIApplication(), editor = openNewNote(app)
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["native-markdown-format-h2"].tap()
        XCTAssertFalse((editor.value as? String ?? "").contains("##"))
        app.toggleNativeMarkdownSource()
        XCTAssertTrue((editor.value as? String ?? "").contains("##"))
        app.toggleNativeMarkdownSource()
        app.buttons["native-markdown-more"].tap(); app.buttons["표"].tap()
        XCTAssertFalse((editor.value as? String ?? "").contains("---"))
        capture("Native rich Markdown table", app: app)
        app.toggleNativeMarkdownSource()
        editor.tap(); editor.typeText("\n$\\frac{a}{b}+x^2$\n")
        XCTAssertTrue((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"), app.debugDescription)
        app.toggleNativeMarkdownSource()
        XCTAssertFalse((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"))
        capture("Native SwiftMath attachment", app: app)
        editor.tap(); app.typeKey("w", modifierFlags: .command)
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "Rich note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.toggleNativeMarkdownSource()
        XCTAssertTrue((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"))
        XCTAssertEqual(app.webViews.count, 0)
    }
    /// Every format of the desktop's bar is a button of its own; each one writes its Markdown.
    @MainActor
    func testFormattingBarButtonsWriteMarkdown() throws {
        let app = XCUIApplication(), editor = openNewNote(app)
        func button(_ id: String) -> XCUIElement { app.buttons["native-markdown-format-" + id] }
        func expectSelected(_ id: String, _ selected: Bool = true) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: button(id))
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, id + (selected ? " is the active format" : " is no longer active"))
        }
        func up(_ lines: Int = 1) { for _ in 0..<lines { app.typeKey(.upArrow, modifierFlags: []) } }
        for id in ["paragraph", "h1", "h2", "h3", "bold", "italic", "strike", "bullet", "number", "task", "quote", "link", "image", "code", "codeblock"] {
            XCTAssertTrue(button(id).isHittable, id + " is a button of the bar")
        }
        editor.tap(); app.typeKey("a", modifierFlags: .command); editor.typeText("one\ntwo\nthree\nfour\nfive\nsix\nseven")
        // From the last line up, one format per line. The rich view may or may not give a fence a line of its own.
        button("codeblock").tap(); expectSelected("codeblock"); up(2)
        button("strike").tap(); expectSelected("strike"); up()
        button("code").tap(); expectSelected("code"); up()
        button("task").tap(); expectSelected("task"); up()
        button("quote").tap(); expectSelected("quote"); up()
        button("h2").tap(); expectSelected("h2"); expectSelected("paragraph", false)
        button("paragraph").tap(); expectSelected("paragraph"); expectSelected("h2", false)
        XCTAssertEqual(button("link").label, "링크")
        button("link").tap()
        let address = app.textFields["native-markdown-link"]
        XCTAssertTrue(address.waitForExistence(timeout: 5), app.debugDescription); address.typeText("example.com"); app.buttons["native-markdown-link-submit"].tap()
        expectSelected("link"); XCTAssertEqual(button("link").label, "링크 해제")
        app.toggleNativeMarkdownSource()
        let source = editor.value as? String ?? "", shown = source.replacingOccurrences(of: "\n", with: "⏎")
        for markdown in ["```\n코드\n```", "~~텍스트~~", "`텍스트`", "- [ ] ", "> ", "](https://example.com)"] {
            XCTAssertTrue(source.contains(markdown), markdown + " is missing from: " + shown)
        }
        XCTAssertFalse(source.contains("## "), "본문 removes the heading: " + shown)
    }
    @MainActor private func openNewNote(_ app: XCUIApplication) -> XCUIElement {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 20), app.debugDescription); courseMenu.tap()
        let course = app.textFields["native-course-name"]; XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Rich Markdown")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap(); app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]; XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Rich note")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        return editor
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
