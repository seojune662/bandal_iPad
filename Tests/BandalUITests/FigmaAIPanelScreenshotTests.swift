import XCTest

/// Captures of the AI panel (Figma A1–A6), the model picker and AI as a full tab (F1–F2), light and dark,
/// for a side-by-side comparison with the design. Each test only drives and attaches.
final class FigmaAIPanelScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testPanelEmptyTypingAndPickerLight() { panelEmptyTypingAndPicker("light") }
    @MainActor func testPanelEmptyTypingAndPickerDark() { panelEmptyTypingAndPicker("dark") }
    @MainActor func testPanelAnswerAndInsertLight() { panelAnswerAndInsert("light") }
    @MainActor func testPanelAnswerAndInsertDark() { panelAnswerAndInsert("dark") }
    @MainActor func testFullTabLight() { fullTab("light") }
    @MainActor func testFullTabDark() { fullTab("dark") }

    @MainActor private func panelEmptyTypingAndPicker(_ appearance: String) {
        let app = launch(appearance, extra: ["--native-ai-catalog-fixture", "--native-ai-usage-fixture"])
        openNoteAndPanel(app)
        attach(app, "A1-" + appearance)
        let pill = app.buttons["native-ai-model-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), app.debugDescription); pill.tap()
        XCTAssertTrue(app.buttons["native-ai-model-default"].waitForExistence(timeout: 10), app.debugDescription); sleep(1)
        attach(app, "picker-" + appearance)
        app.buttons["native-ai-model-claude-sonnet-5-5"].tap(); sleep(1)
        let input = app.descendants(matching: .any)["native-chat-input"]
        input.tap(); input.typeText("3주차 인터뷰 결과 핵심만 정리해 줘"); sleep(1)
        attach(app, "A2-" + appearance)
    }

    @MainActor private func panelAnswerAndInsert(_ appearance: String) {
        let app = launch(appearance, extra: ["--native-ai-catalog-fixture", "--native-ai-answer-fixture"])
        openNoteAndPanel(app)
        let insert = app.buttons["native-ai-insert-note"]
        XCTAssertTrue(insert.waitForExistence(timeout: 15), app.debugDescription); sleep(3)
        attach(app, "A4-" + appearance)
        insert.tap()
        let undo = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "되돌리기", "native-pdf-undo")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "A5-" + appearance)
        undo.tap(); sleep(1)
        attach(app, "A5-undone-" + appearance)
    }

    @MainActor private func fullTab(_ appearance: String) {
        for (name, extra) in [("F1", [String]()), ("F2", ["--native-ai-answer-fixture"])] {
            let app = launch(appearance, extra: ["--native-ai-catalog-fixture"] + extra)
            let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription); add.tap()
            app.buttons["native-new-tab-chat"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].waitForExistence(timeout: 15), app.debugDescription); sleep(2)
            attach(app, name + "-" + appearance)
            app.terminate()
        }
    }

    @MainActor private func launch(_ appearance: String, extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("디자인 스튜디오")
        app.buttons["native-create-course"].tap(); sleep(1)
        return app
    }

    @MainActor private func openNoteAndPanel(_ app: XCUIApplication) {
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if toggle.label == "AI 열기" { toggle.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].waitForExistence(timeout: 15), app.debugDescription); sleep(2)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
