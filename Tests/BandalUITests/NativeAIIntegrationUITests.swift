import XCTest

/// Where the AI features meet: the floating card draws the formatted answer and keeps its buttons findable, and
/// the floating bar steps aside while 짚어주기 points into the PDF. Each feature's own flow is in its own class
/// (NativeAssistantFloatingUITests, NativeAssistantMarkdownUITests, NativePDFGuideUITests).
final class NativeAIIntegrationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// 플로팅 shows the same rich answer as the sidebar, and the answer's own buttons answer to their identifiers.
    @MainActor func testFloatingCardDrawsTheFormattedAnswerWithItsButtons() {
        let app = launch(["--native-ai-catalog-fixture", "--native-ai-answer-fixture", "--native-ai-markdown-fixture"])
        createCourse(app, "플로팅 서식")
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap(); app.confirmNewNote()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        openAI(app)
        XCTAssertTrue(app.otherElements["native-ai-floating-bar"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["3주차 인터뷰 요약"].waitForExistence(timeout: 15), "The heading is its own text: " + app.debugDescription)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "**", "](")).firstMatch.exists, "No raw Markdown in the card")
        // The answer row is a container: 복사 and 노트에 넣기 keep their own identifiers inside it.
        XCTAssertTrue(app.buttons["native-ai-copy-answer"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["native-ai-insert-note"].exists, app.debugDescription)
        attach("floating card with the formatted answer")
    }

    /// 짚어주기 playing: the floating card and bar are out of the way; closing the steps brings the bar back.
    @MainActor func testFloatingBarStepsAsideWhileTheGuidePlays() {
        let app = launch(["--native-search-fixture", "--native-guide-fixture"])
        createCourse(app, "열역학")
        let lecture = app.buttons["native-material-열역학 강의자료.pdf"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 40), app.debugDescription); sleep(1)
        lecture.tap()
        let step = app.descendants(matching: .any)["native-pdf-guide-note"]
        expect(step, "step=1/4", timeout: 25)
        // Held on this step (the note stops being written too), so the screen stops changing under the queries below.
        app.buttons["native-pdf-guide-pause"].tap()
        openAI(app)
        sleep(2)
        XCTAssertTrue(step.exists, "The steps are still up: " + app.debugDescription)
        XCTAssertFalse(app.otherElements["native-ai-floating-bar"].exists, "The bar is out of the way: " + app.debugDescription)
        attach("guide playing, floating bar stepped aside")
        app.buttons["native-pdf-guide-close"].tap()
        XCTAssertTrue(app.otherElements["native-ai-floating-bar"].waitForExistence(timeout: 10), "The bar is back: " + app.debugDescription)
        XCTAssertFalse(step.exists, app.debugDescription)
        attach("guide closed, floating bar back")
    }

    /// 플로팅 for the whole run: the argument domain answers the `@AppStorage` read that the reset would clear.
    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", "light", "-native.ai.presentation", "floating"] + extra
        app.launch()
        return app
    }
    @MainActor private func createCourse(_ app: XCUIApplication, _ title: String) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["native-create-course"].tap(); sleep(1)
    }
    @MainActor private func openAI(_ app: XCUIApplication) {
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if toggle.label == "AI 열기" { toggle.tap() }
    }
    @MainActor private func expect(_ element: XCUIElement, _ value: String, timeout: TimeInterval) {
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: timeout), .completed, "expected " + value + ", saw " + (element.exists ? (element.value as? String ?? "?") : "nothing"))
    }
    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
