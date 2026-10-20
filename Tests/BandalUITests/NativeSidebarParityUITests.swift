import XCTest

/// Assertions follow the desktop source's information hierarchy, not the old
/// native screen. This fixture stays in the isolated UI-test data directory.
final class NativeSidebarParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testSourceBasedSidebarFavoritesNewTabMenuAndLearning() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
        let rail = ["library", "learning", "planner", "assistant", "tools", "help", "settings"]  // account rail is hidden in the local-only 1.0 build
        for section in rail { XCTAssertTrue(app.buttons["native-section-" + section].exists, section) }
        for section in ["browser", "recordings", "marketplace"] { XCTAssertFalse(app.buttons["native-section-" + section].exists, section) }
        XCTAssertTrue(app.buttons["native-university-choose"].exists)
        for ai in ["chatgpt", "claude", "gemini"] { XCTAssertTrue(app.buttons["native-ai-web-" + ai].exists, app.debugDescription) }
        capture("Desktop source rail and university AI shortcuts")
        add.tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Source parity")
        app.buttons["native-create-course"].tap()
        let favoriteAdd = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-favorite-add-")).firstMatch
        XCTAssertTrue(favoriteAdd.waitForExistence(timeout: 10), app.debugDescription)
        favoriteAdd.tap(); app.buttons["링크 추가"].tap()
        let url = app.textFields["native-favorite-url"]; XCTAssertTrue(url.waitForExistence(timeout: 5)); url.tap(); url.typeText("https://example.com/study")
        let label = app.textFields["native-favorite-name"]; label.tap(); label.typeText("Course reference")
        app.buttons["native-favorite-save"].tap()
        let favorite = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-favorite-", "Course reference")).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), app.debugDescription)
        capture("Course children are persisted favorites")
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.exists); plus.tap()
        for id in ["new-browser", "new-whiteboard", "new-note", "chat"] {
            XCTAssertTrue(app.buttons["native-new-tab-" + id].waitForExistence(timeout: 5), id + app.debugDescription)
        }
        XCTAssertFalse(app.buttons["새 화이트보드"].exists)
        // Lecture recording is hidden in the iPad 1.0 build (NativeReleaseFlags.showsRecording).
        for id in ["learning", "board", "add-link", "recording"] { XCTAssertFalse(app.buttons["native-new-tab-" + id].exists, id) }
        capture("Tab plus source order and note naming")
        app.buttons["native-new-tab-new-note"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        editor.tap(); editor.typeText("Current document context persists.")
        app.dismissNativeTestKeyboard()
        app.buttons["native-section-assistant"].tap()
        XCTAssertTrue(app.otherElements["native-document-assistant"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(editor.exists, "Contextual AI retains the active document")
        capture("Document assistant preserves current editor")
        app.buttons["native-document-assistant-close"].tap()
        app.buttons["native-section-planner"].tap()
        let boardClose = app.buttons["native-board-overlay-close"]
        XCTAssertTrue(boardClose.waitForExistence(timeout: 10), app.debugDescription)
        capture("Global academic board overlays the current document")
        boardClose.tap()
        XCTAssertTrue(editor.exists, "Closing the global board restores the same document")
        app.buttons["native-section-tools"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native-study-tools").firstMatch.waitForExistence(timeout: 10))
        for pack in ["vocab-chain-en", "quiz", "flashcards", "summary"] { XCTAssertTrue(app.buttons["native-study-tool-" + pack].waitForExistence(timeout: 10)) }
        capture("Native document tool launcher")
        app.buttons["native-section-learning"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native-learning-home").firstMatch.waitForExistence(timeout: 10))
        app.buttons["native-learning-start-english"].tap()
        let projectName = app.textFields["native-learning-create-name"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 5)); projectName.tap(); projectName.typeText("My English")
        let topic = app.textFields["native-learning-create-topic"]; topic.tap(); topic.typeText("Science")
        app.buttons["native-learning-create-confirm"].tap()
        let learningWorkspace = app.descendants(matching: .any).matching(identifier: "native-learning-workspace").firstMatch
        XCTAssertTrue(learningWorkspace.waitForExistence(timeout: 15), "A newly created standalone project must open, not merely appear behind an error alert.\n" + app.debugDescription)
        XCTAssertTrue(learningWorkspace.staticTexts["My English"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        XCTAssertFalse(learningWorkspace.descendants(matching: .any).matching(identifier: "native-tool-error").firstMatch.exists, app.debugDescription)
        capture("Real portable learning project created and opened")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(learningWorkspace.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(learningWorkspace.staticTexts["My English"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["native-section-library"].waitForExistence(timeout: 25)); app.buttons["native-section-library"].tap()
        if !favorite.waitForExistence(timeout: 5) { app.buttons["native-section-library"].tap() }
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-course-", "My English")).firstMatch.exists, "Standalone learning projects are not course folders")
        capture("Favorites restored and learning separated from course list")
    }
    @MainActor private func capture(_ name: String) { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item) }
}
