import XCTest

/// 1.4.0: the chat's AI picker lists the proxy's models (only Auto while signed out or offline) with
/// effort for chosen models, and Settings › AI has no API key fields.
final class NativeAIModelPickerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPickerOffersAutoAndSettingsHaveNoKeys() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra")
        app.buttons["native-create-course"].tap()

        let assistant = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 15), app.debugDescription)
        if assistant.label == "AI 열기" { assistant.tap() }
        let pill = app.buttons["native-ai-model-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(pill.label, "AI 모델: Auto")
        pill.tap()
        let auto = app.buttons["native-ai-model-default"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["반달이 제공 · 키 입력 필요 없음"].exists, "No key entry")
        XCTAssertTrue(app.staticTexts["native-ai-effort-fixed"].exists, "Auto: effort is low, fixed")
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "A popover, not a titled sheet")
        XCTAssertFalse(app.buttons["취소"].exists || app.buttons["적용"].exists, "Applies at once")
        attach(app, "AI picker (signed out: Auto only)")
        auto.tap()
        XCTAssertTrue(waitForAbsence(auto), "Picking closes the popover")

        // Signed out, 보내기 asks for sign-in right there and keeps the text.
        let input = app.descendants(matching: .any)["native-chat-input"]
        input.tap(); input.typeText("행렬식이 뭐야?")
        app.buttons["native-chat-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["native-ai-sign-in-prompt"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-ai-sign-in-apple"].exists && app.buttons["native-ai-sign-in-google"].exists)
        XCTAssertFalse(app.buttons["native-settings-category-ai"].exists, "Stays in the panel, no detour to Settings")
        XCTAssertEqual(input.value as? String, "행렬식이 뭐야?")
        attach(app, "Signed-out send asks for sign-in in place")
        app.dismissNativeTestKeyboard()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.04)).tap()

        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-ai"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        XCTAssertTrue(app.staticTexts["native-ai-summary"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.secureTextFields.count, 0, "No API key fields")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'API 키를'")).firstMatch.exists)
        attach(app, "Settings AI (no keys)")
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 5) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
