import XCTest

/// Page add, delete and move never block the page with the "[conflict] …" banner, scrolling fast past
/// the last page adds nothing, and a page edit that fails leaves the page writable with a toast.
final class NativePDFPageSafetyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The owner's case: flicking to the end of a lecture PDF. Only a pull held past the line adds a
    /// page; the toast's 되돌리기 takes it back.
    @MainActor
    func testFastScrollToTheEndAddsNothingAndAHeldPullAddsAPageThatUndoes() {
        // No pencil fixture: a finger scrolls the PDF.
        let app = createDocument("Pull Pages", arguments: ["--native-ui-testing", "--reset-native-ui-testing", "--native-pages-fixture"])
        expectPageCount(3, in: app)
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        for _ in 0..<10 { body.swipeUp(velocity: .fast) }
        // Any add would have reached the store by now.
        sleep(3)
        expectPageCount(3, in: app)
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists)
        capture("After fast scrolling past the end")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 1.0)
        expectPageCount(4, in: app)
        let undo = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "되돌리기", "native-pdf-undo")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["페이지를 추가했어요"].exists || app.otherElements["bandal-toast"].exists)
        capture("Page added toast")
        undo.tap()
        expectPageCount(3, in: app)
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists)
    }

    @MainActor
    func testPagePanelAddDeleteMoveKeepThePageWritable() {
        let app = createDocument("Panel Pages", arguments: pencil(["--native-pages-fixture"]))
        draw(at: 0.32, in: app); expectInk(1, in: app)
        app.buttons["native-pdf-pages"].tap(); expectPageCount(3, in: app)
        tapWhenReady(app.buttons["native-pdf-page-add"], in: app); expectPageCount(4, in: app)
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists)
        let menu = app.buttons["native-pdf-page-menu-4"]
        tapWhenReady(menu, in: app); app.buttons["native-pdf-page-delete"].tap()
        let confirm = app.buttons.matching(identifier: "native-pdf-confirm-page-delete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
        expectPageCount(3, in: app); expectInk(1, in: app)
        let first = app.buttons["native-pdf-thumbnail-1"], second = app.buttons["native-pdf-thumbnail-2"]
        // The reader follows the moved page; start on page 1 (deleting page 4 left it on page 3).
        tapWhenReady(first, in: app)
        let onFirst = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "1 /"), object: app.buttons["native-pdf-pages"])
        XCTAssertEqual(XCTWaiter.wait(for: [onFirst], timeout: 15), .completed, app.debugDescription)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "2 /"), object: app.buttons["native-pdf-pages"])
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 20), .completed, app.debugDescription)
        expectInk(1, in: app)
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists)
        app.buttons["native-pdf-pages"].tap()
        draw(at: 0.6, in: app); expectInk(2, in: app)
        capture("Page panel edits then writing")
    }

    /// A page edit that cannot be saved (`--native-page-edit-failure` fails every one) says so in a
    /// toast and the page stays as it was, writable at once: no banner, no blocked input.
    @MainActor
    func testFailedPageEditShowsAToastAndThePageStaysWritable() {
        let app = createDocument("Failing Pages", arguments: pencil(["--native-pages-fixture", "--native-page-edit-failure"]))
        draw(at: 0.32, in: app); expectInk(1, in: app)
        app.buttons["native-pdf-pages"].tap(); expectPageCount(3, in: app)
        tapWhenReady(app.buttons["native-pdf-page-add"], in: app)
        let toast = app.staticTexts["이 PDF는 페이지를 바꿀 수 없어 원래대로 두었어요."]
        XCTAssertTrue(toast.waitForExistence(timeout: 15), app.debugDescription)
        capture("Failed page edit toast")
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists, "no blocking banner")
        expectPageCount(3, in: app)
        // Again, as 다시 저장 used to repeat the same failure: still a toast, still writable.
        tapWhenReady(app.buttons["native-pdf-page-add"], in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["native-pdf-pages"].tap()
        draw(at: 0.6, in: app); expectInk(2, in: app)
        XCTAssertFalse(app.buttons["native-pdf-retry"].exists)
    }

    // MARK: helpers

    private func pencil(_ extra: [String]) -> [String] { ["--native-ui-testing", "--reset-native-ui-testing", "--native-pencil-dispatch-fixture"] + extra }
    @MainActor private func createDocument(_ title: String, arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25)); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Page Safety")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        create.tap(); app.buttons["새 노트"].tap()
        let note = app.textFields["native-new-note-title"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText(title)
        app.buttons["native-new-note-create"].tap()
        let pen = app.buttons["native-pdf-tool-pen"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: pen)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, app.debugDescription)
        if !pen.isSelected { pen.tap() }
        return app
    }
    @MainActor private func draw(at x: CGFloat, in app: XCUIApplication) {
        let body = app.otherElements["native-pdf-workspace"]
        body.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.34)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: x + 0.18, dy: 0.44)), withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func tapWhenReady(_ item: XCUIElement, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription); item.tap()
    }
    @MainActor private func expectPageCount(_ count: Int, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value ENDSWITH %@", "/ \(count)"), object: app.buttons["native-pdf-pages"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
    }
    @MainActor private func expectInk(_ count: Int, in app: XCUIApplication) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 25), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
