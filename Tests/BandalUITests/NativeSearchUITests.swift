import XCTest

/// Search across a seeded course: the files panel lists 자료, 손글씨 and 대화, and a result opens at its match.
final class NativeSearchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testSidebarSearchLight() throws { sidebar("light") }
    @MainActor func testSidebarSearchDark() throws { sidebar("dark") }

    @MainActor private func sidebar(_ appearance: String) {
        let app = launch(appearance)
        let field = app.textFields["native-library-search"]
        field.tap(); field.typeText("엔트\n")
        // Recognition of the seeded ink runs after its two-second wait; the list refreshes when it ends.
        let handwriting = app.staticTexts["native-search-section-handwriting"]
        XCTAssertTrue(handwriting.waitForExistence(timeout: 600), app.debugDescription)
        XCTAssertTrue(app.staticTexts["native-search-section-material"].exists, "PDF and Markdown text")
        XCTAssertTrue(app.staticTexts["native-search-section-chat"].exists, "conversations")
        XCTAssertTrue(app.buttons["native-search-scope"].isSelected, "이 과목만 is on while a course is open")
        sleep(1); attach(app, "sidebar search \(appearance)")

        // The lecture PDF matches on several pages: one row with a count that opens to its pages.
        let lecture = app.buttons["native-search-material-열역학 강의자료.pdf"]
        XCTAssertTrue(lecture.exists, app.debugDescription); lecture.tap()
        let page = app.buttons["native-search-hit-material-열역학 강의자료.pdf-3"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1); attach(app, "sidebar search expanded \(appearance)")
        page.tap()
        // The viewer publishes what it marks through its body's value.
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 20), app.debugDescription)
        expect(body, "searchMarks=1 handwritingMarks=0 currentMarks=1", "The opened page marks its match")
        XCTAssertEqual(app.textFields["native-pdf-page"].value as? String, "3")
        attach(app, "text match flash \(appearance)")

        // A handwritten line opens at its page with the recognised box dashed.
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-search-handwriting-")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription); note.tap()
        let line = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "native-search-hit-handwriting-", "필기 노트.pdf-2")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), app.debugDescription); line.tap()
        expect(app.otherElements["bandal-native-pdf-body"], "searchMarks=1 handwritingMarks=1", "The handwritten line's box is marked")
        attach(app, "handwriting match flash \(appearance)")

        // Esc empties the field and the file list returns.
        field.tap(); app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["native-material-2주차 정리.md"].waitForExistence(timeout: 5), "The file list comes back")
        // A word nobody wrote.
        field.typeText("zzqq")
        XCTAssertTrue(app.staticTexts["native-search-empty"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor func testConversationResultOpensItsMessage() throws {
        let app = launch("light")
        let field = app.textFields["native-library-search"]
        field.tap(); field.typeText("카르노 순환 효율\n")
        let chat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-search-chat-")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), app.debugDescription); chat.tap()
        let opened = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-search-hit-chat-")).firstMatch
        if opened.waitForExistence(timeout: 3) { opened.tap() }
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-assistant-message-")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "The conversation opens in the AI panel")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "카르노 효율은")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "conversation result")
    }

    @MainActor private func launch(_ appearance: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture", "-native.appearance", appearance]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        // The seeded note lands in the course's 노트 folder, after the lecture PDF and the Markdown file.
        XCTAssertTrue(app.buttons["native-material-노트"].waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        return app
    }

    @MainActor private func expect(_ element: XCUIElement, _ value: String, _ message: String) {
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 20), .completed, message + ": " + (element.value as? String ?? ""))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
