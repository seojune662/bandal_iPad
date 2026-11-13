import XCTest

/// 짚어주기 played from a fixed step list (`--native-guide-fixture`) over the search fixture's three-page lecture PDF:
/// it moves between pages, points and writes, stops for a scroll, and goes back to where the page was.
final class NativePDFGuideUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// Steps 1 → 2 play by themselves; the caption's › moves on; › on the last step ends it and the page returns.
    @MainActor func testStepsMoveAcrossPagesAndTheViewComesBack() throws {
        let app = launch()
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        sleep(1)
        let before = Viewport(body.value as? String)
        XCTAssertEqual(before.page, 1, body.value as? String ?? "")
        let note = app.descendants(matching: .any)["native-pdf-guide-note"]

        expect(note, "step=1/4 page=1 found=1", timeout: 20)
        attach(app, "guide step 1 (page 1)")
        expect(note, "step=2/4 page=3 found=1", timeout: 30)
        XCTAssertEqual(Viewport(body.value as? String).page, 3, "the view moved to page 3: \(body.value as? String ?? "")")
        expect(note, "written=1", timeout: 15)
        attach(app, "guide step 2 (page 3)")

        app.buttons["native-pdf-guide-next"].tap()
        expect(note, "step=3/4 page=2 found=0", timeout: 10)
        XCTAssertEqual(Viewport(body.value as? String).page, 2, body.value as? String ?? "")
        expect(note, "written=1", timeout: 15)
        attach(app, "guide step 3 (not found: note only)")

        note.tap()  // the whole note is up: a tap moves on
        expect(note, "step=4/4 page=2 found=1", timeout: 10)
        expect(note, "written=1", timeout: 15)
        attach(app, "guide step 4 (page 2)")

        app.buttons["native-pdf-guide-next"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "› on the last step ends it")
        sleep(2)
        let after = Viewport(body.value as? String)
        XCTAssertEqual(after.page, before.page, body.value as? String ?? "")
        XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 2, "back where the page was: \(before.scrollY) → \(after.scrollY)")
        attach(app, "guide ended, page back")
    }

    /// A finger scroll stops it at once and leaves the page where the reader took it.
    @MainActor func testAScrollStopsItWhereItIs() throws {
        let app = launch()
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        let note = app.descendants(matching: .any)["native-pdf-guide-note"]
        expect(note, "step=2/4 page=3 found=1", timeout: 40)
        sleep(1)
        let shown = Viewport(body.value as? String)
        XCTAssertEqual(shown.page, 3, body.value as? String ?? "")
        let start = clearOfNote(app, body)
        body.coordinate(withNormalizedOffset: start).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: start.dx, dy: min(0.98, start.dy + 0.3))))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 2), .completed, "the scroll stops it")
        sleep(3)
        XCTAssertFalse(note.exists, "it does not start again")
        let left = Viewport(body.value as? String)
        XCTAssertLessThan(left.scrollY, shown.scrollY - 50, "the drag moved the page up the document: \(shown.scrollY) → \(left.scrollY)")
        XCTAssertGreaterThan(left.page, 1, "not taken back to page 1: \(body.value as? String ?? "")")
        attach(app, "guide stopped by a scroll")
    }

    /// The Pencil on the page (the dispatch fixture makes a finger the Pencil) stops it before the stroke lands.
    @MainActor func testThePencilStopsIt() throws {
        let app = launch(extra: ["--native-pencil-dispatch-fixture"])
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        let note = app.descendants(matching: .any)["native-pdf-guide-note"]
        expect(note, "step=2/4 page=3 found=1", timeout: 40)
        let start = clearOfNote(app, body)
        body.coordinate(withNormalizedOffset: start).press(forDuration: 0.1, thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: start.dx + 0.15, dy: start.dy + 0.03)))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 2), .completed, "the Pencil stops it")
        sleep(2)
        XCTAssertEqual(Viewport(body.value as? String).page, 3, "the page stays where the stroke was written: \(body.value as? String ?? "")")
        attach(app, "guide stopped by the Pencil")
    }

    /// Leaving the app mid-play saves the reading position from before the guide, not the page a step scrolled to.
    @MainActor func testASaveDuringPlayKeepsTheReadingPosition() throws {
        let app = launch()
        let body = app.otherElements["bandal-native-pdf-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        let note = app.descendants(matching: .any)["native-pdf-guide-note"]
        expect(note, "step=2/4 page=3 found=1", timeout: 40)
        XCUIDevice.shared.press(.home)  // the PDF saves its position as the app resigns
        sleep(3)
        app.terminate()
        app.launchArguments = ["--native-ui-testing", "-native.appearance", "light"]
        app.launch()
        let reopened = app.otherElements["bandal-native-pdf-body"]
        if !reopened.waitForExistence(timeout: 20) {
            let lecture = app.buttons["native-material-열역학 강의자료.pdf"]
            XCTAssertTrue(lecture.waitForExistence(timeout: 20), app.debugDescription); lecture.tap()
            XCTAssertTrue(reopened.waitForExistence(timeout: 20), app.debugDescription)
        }
        sleep(2)
        XCTAssertEqual(Viewport(reopened.value as? String).page, 1, "reopens where the reader was: \(reopened.value as? String ?? "")")
        attach(app, "reopened after a save during play")
    }

    /// 짚어주기 is offered in the AI panel's popover while a PDF is open, shows a row in the composer while on,
    /// and is not offered for a Markdown note.
    @MainActor func testTheModeIsOfferedOnlyBesideAPDF() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture", "-native.appearance", "light"]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        let lecture = app.buttons["native-material-열역학 강의자료.pdf"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 40), app.debugDescription); sleep(1); lecture.tap()
        XCTAssertTrue(app.otherElements["bandal-native-pdf-body"].waitForExistence(timeout: 30), app.debugDescription)
        let assistant = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 15), app.debugDescription)
        if assistant.label == "AI 열기" { assistant.tap() }
        let pill = app.buttons["native-ai-model-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), app.debugDescription); pill.tap()
        let offer = app.buttons["native-ai-guide"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(offer.label, "PDF에서 짚어주기")
        attach(app, "guide offered in the AI popover")
        offer.tap()
        let row = app.descendants(matching: .any)["native-ai-guide-mode"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the composer says the mode is on: " + app.debugDescription)
        attach(app, "guide mode on in the composer")
        pill.tap()
        XCTAssertTrue(app.buttons["native-ai-guide"].waitForExistence(timeout: 5)); XCTAssertEqual(app.buttons["native-ai-guide"].label, "짚어주기 끄기")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.04)).tap()

        // A Markdown note: no 짚어주기 to offer, and the row leaves.
        app.buttons["native-material-2주차 정리.md"].tap(); sleep(2)
        XCTAssertFalse(row.exists, "not beside a note")
        pill.tap()
        XCTAssertTrue(app.buttons["native-ai-attach-document"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["native-ai-guide"].exists, "only with a PDF open")
        attach(app, "no guide beside a Markdown note")
    }

    /// A point on the page clear of the note (a touch on the note is the note's).
    @MainActor private func clearOfNote(_ app: XCUIApplication, _ body: XCUIElement) -> CGVector {
        let caption = app.descendants(matching: .any)["native-pdf-guide-caption"].frame.insetBy(dx: -20, dy: -20)
        return [CGVector(dx: 0.4, dy: 0.8), CGVector(dx: 0.4, dy: 0.2), CGVector(dx: 0.1, dy: 0.55)].first { offset in
            !caption.contains(CGPoint(x: body.frame.minX + body.frame.width * offset.dx, y: body.frame.minY + body.frame.height * offset.dy))
        } ?? CGVector(dx: 0.4, dy: 0.8)
    }

    private struct Viewport {
        var page = 0, scrollY = 0.0
        init(_ value: String?) {
            for part in (value ?? "").split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                if pair[0] == "page" { page = Int(pair[1]) ?? 0 }
                if pair[0] == "scrollY" { scrollY = Double(pair[1]) ?? 0 }
            }
        }
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-search-fixture", "--native-guide-fixture", "-native.appearance", "light"] + extra
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("열역학"); app.buttons["native-create-course"].tap()
        let lecture = app.buttons["native-material-열역학 강의자료.pdf"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        lecture.tap()
        return app
    }

    @MainActor private func expect(_ element: XCUIElement, _ value: String, timeout: TimeInterval) {
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: timeout), .completed, "expected " + value + ", saw " + (element.exists ? (element.value as? String ?? "?") : "nothing"))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
