import XCTest

/// The chips under an answer name the materials it read. A chip opens its material at the page it read;
/// one whose material is gone says so. 설정 › AI › AI 답변 출처 표시 hides them.
final class NativeAssistantSourcesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSourceChipsOpenTheMaterialAtItsPageAndCanBeHidden() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // The fixture stores one finished answer that read 새 노트.pdf p.2 and 강의자료.pdf p.12 (which does not exist).
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-ai-catalog-fixture", "--native-ai-answer-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Sources")
        app.buttons["native-create-course"].tap()
        let note = app.buttons["native-home-new-note"]
        // The fixture's answer cites 새 노트.pdf, so the note takes that name rather than the dated default.
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap(); app.confirmNewNote(title: "새 노트")
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        // A second page, so the chip's page has somewhere to go.
        app.buttons["native-pdf-pages"].tap()
        let add = app.buttons["native-pdf-page-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription); add.tap()
        // The thumbnails button's value is the reader's position ("1 / 2").
        let pages = app.buttons["native-pdf-pages"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "/ 2"), object: pages)], timeout: 15), .completed, app.debugDescription)
        app.buttons["native-close-document"].firstMatch.tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForNonExistence(timeout: 10), app.debugDescription)

        app.buttons["native-ai-rail-toggle"].tap()
        let chips = app.buttons.matching(identifier: "native-ai-source")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(chips.allElementsBoundByIndex.map(\.label), ["출처: 새 노트 p.2", "출처: 강의자료 p.12"])

        app.buttons["출처: 새 노트 p.2"].tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "2 /"), object: pages)], timeout: 15), .completed, "The note opens at the page the answer read: " + app.debugDescription)

        let tabs = app.buttons.matching(identifier: "native-close-document").count
        app.buttons["출처: 강의자료 p.12"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "자료를 찾을 수 없어요")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "native-close-document").count, tabs, "A missing material opens no tab")

        app.buttons["설정"].firstMatch.tap()
        let category = app.buttons["native-settings-category-ai"]
        XCTAssertTrue(category.waitForExistence(timeout: 5), app.debugDescription); category.tap()
        let toggle = app.switches["native-settings-ai-sources"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        toggle.tap()
        app.buttons["native-settings-close"].tap()
        XCTAssertTrue(chips.firstMatch.waitForNonExistence(timeout: 10), "출처 표시를 끄면 칩이 사라진다: " + app.debugDescription)
        XCTAssertTrue(app.buttons["native-ai-copy-answer"].exists, "The answer and its actions stay")
    }
}
