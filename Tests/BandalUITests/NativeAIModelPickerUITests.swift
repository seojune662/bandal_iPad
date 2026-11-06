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
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Linear Algebra")
        app.buttons["native-create-course"].tap()

        let assistant = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 15), app.debugDescription); assistant.tap()
        let picker = app.buttons["AI 모델 설정"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(picker.label.isEmpty, false)
        picker.tap()
        let auto = app.buttons["native-ai-model-default"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "AI picker (signed out: Auto only)")
        XCTAssertFalse(app.segmentedControls["native-ai-effort"].exists, "Auto has no effort choice: \(app.debugDescription)")
        app.buttons["취소"].firstMatch.tap()

        app.buttons["native-section-settings"].tap()
        let category = app.buttons["native-settings-category-ai"]
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription); category.tap()
        XCTAssertTrue(app.staticTexts["native-ai-summary"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.secureTextFields.count, 0, "No API key fields")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'API 키를'")).firstMatch.exists)
        attach(app, "Settings AI (no keys)")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
