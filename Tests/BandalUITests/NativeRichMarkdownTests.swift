import XCTest

final class NativeRichMarkdownTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testRichFormattingSourceRoundTripTableAndNativeFormula() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 20), app.debugDescription); courseMenu.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]; XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Rich Markdown")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap(); app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]; XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Rich note")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["native-markdown-format-h2"].tap()
        XCTAssertFalse((editor.value as? String ?? "").contains("##"))
        app.buttons["native-markdown-source-toggle"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("##"))
        app.buttons["native-markdown-source-toggle"].tap()
        app.buttons["native-markdown-more"].tap(); app.buttons["표"].tap()
        XCTAssertFalse((editor.value as? String ?? "").contains("---"))
        capture("Native rich Markdown table", app: app)
        app.buttons["native-markdown-source-toggle"].tap()
        editor.tap(); editor.typeText("\n$\\frac{a}{b}+x^2$\n")
        XCTAssertTrue((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"), app.debugDescription)
        app.buttons["native-markdown-source-toggle"].tap()
        XCTAssertFalse((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"))
        capture("Native SwiftMath attachment", app: app)
        editor.tap(); app.typeKey("w", modifierFlags: .command)
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "Rich note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons["native-markdown-source-toggle"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("$\\frac{a}{b}+x^2$"))
        XCTAssertEqual(app.webViews.count, 0)
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
