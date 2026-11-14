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
        // The last page of the note is read a little after the first.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-search-handwriting-", "2곳")).firstMatch.waitForExistence(timeout: 300), app.debugDescription)
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
        // The page field moved into the view menu (529c94c); the thumbnails button's value is the reader's position ("3 / 3").
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "3 /"), object: app.buttons["native-pdf-pages"].firstMatch)], timeout: 10), .completed, "The match's page")
        attach(app, "text match flash \(appearance)")

        // A handwritten line opens at its page with the recognised box dashed.
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-search-handwriting-")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription); note.tap()
        let line = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "native-search-hit-handwriting-", "필기 노트.pdf-2")).firstMatch
        // The second page's lines arrive when its recognition ends.
        XCTAssertTrue(line.waitForExistence(timeout: 300), app.debugDescription); line.tap()
        expect(app.otherElements["bandal-native-pdf-body"], "searchMarks=1 handwritingMarks=1", "The handwritten line's box is marked")
        attach(app, "handwriting match flash \(appearance)")

        // An empty field brings the file list back. (Esc does the same; the simulator cannot send that key to a field.)
        app.buttons["검색어 지우기"].firstMatch.tap(); field.tap()
        XCTAssertTrue(app.buttons["native-material-2주차 정리.md"].waitForExistence(timeout: 5), "The file list comes back")
        // A word nobody wrote.
        field.typeText("zzqq")
        XCTAssertTrue(app.staticTexts["native-search-empty"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor func testDocumentSearchLight() throws { document("light") }
    @MainActor func testDocumentSearchDark() throws { document("dark") }

    /// ⌘F in the viewer: matches are counted and stepped through, and the thumbnails keep only the pages that have one.
    @MainActor private func document(_ appearance: String) {
        let app = launch(appearance)
        app.buttons["native-material-열역학 강의자료.pdf"].tap()
        // The fixture is still writing its note and conversations when the first rows appear.
        XCTAssertTrue(app.buttons["native-pdf-pages"].firstMatch.waitForExistence(timeout: 30), app.debugDescription); sleep(4)
        let field = find(in: app); field.typeText("엔트로피")
        // Page 1 has it once and page 3 twice; the PDF's text is extracted in the background first.
        let count = app.staticTexts["native-pdf-search-count"]
        expect(count, label: "1 / 3", timeout: 120)
        let body = app.otherElements["bandal-native-pdf-body"]
        expect(body, "searchMarks=3 handwritingMarks=0 currentMarks=1", "Every match is marked and one is current")
        field.typeText("\n"); expect(count, label: "2 / 3", timeout: 10)
        XCTAssertEqual((app.buttons["native-pdf-pages"].firstMatch.value as? String)?.components(separatedBy: " / ").first, "3", "Return moves to the next match")
        app.buttons["native-pdf-search-previous"].tap(); expect(count, label: "1 / 3", timeout: 10)
        app.buttons["native-pdf-search-next"].tap(); app.buttons["native-pdf-search-next"].tap(); expect(count, label: "3 / 3", timeout: 10)

        app.buttons["native-pdf-pages"].firstMatch.tap()
        XCTAssertTrue(app.buttons["native-pdf-thumbnail-3"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-pdf-thumbnail-1"].exists)
        XCTAssertFalse(app.buttons["native-pdf-thumbnail-2"].exists, "A page without a match leaves the thumbnails")
        XCTAssertEqual(app.buttons["native-pdf-thumbnail-3"].value as? String, "일치 2곳")
        hideKeyboard(app); sleep(1); attach(app, "document search \(appearance)")
        app.buttons["native-pdf-pages-search-clear"].tap()
        XCTAssertTrue(app.buttons["native-pdf-thumbnail-2"].waitForExistence(timeout: 10), "An empty field brings every page back")
        XCTAssertFalse(count.exists)

        // A note: the recognised lines are the matches, drawn dashed.
        app.buttons["native-material-노트"].tap()
        let note = app.buttons["native-material-노트/필기 노트.pdf"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription); note.tap(); sleep(2)
        let noteField = find(in: app); noteField.typeText("엔트로피")
        expect(app.staticTexts["native-pdf-search-count"], label: "1 / 2", timeout: 600)
        expect(app.otherElements["bandal-native-pdf-body"], "searchMarks=2 handwritingMarks=2 currentMarks=1", "Handwritten matches are marked as such")
        hideKeyboard(app); sleep(1); attach(app, "handwriting search \(appearance)")
        app.buttons["native-pdf-search-close"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: noteField)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Closing takes the search capsule away")
    }

    /// ⌘F opens the search field. In a UI test the key does not reach a viewer that was only just opened
    /// (docs/known-issues.md #4; the same on main d10f033): that is recorded as an expected failure, and the view
    /// menu's PDF에서 찾기 opens the same field, so the rest of the flow is still checked.
    @MainActor private func find(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["native-pdf-search-field"]
        if field.waitForExistence(timeout: 5) { return field }
        XCTExpectFailure("⌘F does not open the search field in a UI test (docs/known-issues.md #4)") { XCTFail("⌘F shows the field") }
        app.openNativePDFViewMenu()
        app.descendants(matching: .any)["native-pdf-search"].firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "PDF에서 찾기 shows the field: " + app.debugDescription)
        return field
    }

    @MainActor private func expect(_ element: XCUIElement, label: String, timeout: TimeInterval) {
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: timeout), .completed, "expected " + label + ", saw " + (element.exists ? element.label : "nothing"))
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

    /// Screenshots show the whole window; the on-screen keyboard covers half of it.
    @MainActor private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "hide", "dismiss")).firstMatch
        if hide.exists { hide.tap() }
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
