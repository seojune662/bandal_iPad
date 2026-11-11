import XCTest

/// 끝내고 요약 on the recording bar: the recording stops and the AI panel opens with the transcript
/// attached and a summary request. Signed out, sending asks for sign-in in place and keeps the request.
final class NativeRecordingSummaryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testFinishAndSummarizeHandsTheTranscriptToTheAIPanel() {
        let app = launch(["--native-recording-transcript-fixture"])
        startRecording(app)
        app.buttons["native-pdf-record-summarize"].tap()
        let toggle = app.buttons["native-ai-rail-toggle"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "AI 닫기"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["native-pdf-record-summarize"].exists, "The recording bar leaves with the recording")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-ai-attachment-")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "The transcript rides along as an attachment: " + app.debugDescription)
        XCTAssertTrue(chip.label.contains("녹음"), chip.label)
        // No account in UI tests: the send stops at the in-place sign-in and the request stays in the composer.
        XCTAssertTrue(app.descendants(matching: .any)["native-ai-sign-in-prompt"].waitForExistence(timeout: 10), app.debugDescription)
        let input = app.descendants(matching: .any)["native-chat-input"]
        XCTAssertTrue((input.value as? String ?? "").contains("요약"), String(describing: input.value))
    }

    @MainActor func testNothingHeardSaysSoAndKeepsTheAIPanelClosed() {
        let app = launch([])
        startRecording(app)
        app.buttons["native-pdf-record-summarize"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "받아쓴 내용이 없어")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.buttons["native-ai-rail-toggle"].label, "AI 열기")
        XCTAssertFalse(app.buttons["native-pdf-record-summarize"].exists)
    }

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Lecture")
        app.buttons["native-create-course"].tap()
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }
    @MainActor private func startRecording(_ app: XCUIApplication) {
        let record = app.buttons["native-pdf-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), app.debugDescription)
        if !record.isHittable { app.scrollViews["native-pdf-tool-scroll"].swipeLeft() }
        record.tap()
        // The microphone permission alert belongs to the system.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons.element(boundBy: 1)
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["native-pdf-record-summarize"].waitForExistence(timeout: 20), app.debugDescription)
    }
}
