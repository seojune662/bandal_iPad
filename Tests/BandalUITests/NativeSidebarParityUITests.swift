import XCTest

/// Exercises the unified iPad shell in an isolated test profile. No live AI key
/// or network response is required to verify drafting, navigation and capture.
final class NativeSidebarParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testHomeProjectsInspectorAndDraftSurviveModesAndRelaunch() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        openHome(app)
        XCTAssertTrue(app.buttons["native-home-courses"].exists)
        XCTAssertTrue(app.buttons["native-home-projects"].exists)
        for removed in ["learning", "assistant", "tools"] { XCTAssertFalse(app.buttons["native-section-" + removed].exists) }
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let courseName = app.textFields["native-course-name"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5)); courseName.tap(); courseName.typeText("Physics")
        app.buttons["native-create-course"].tap()
        openHome(app); app.buttons["native-home-projects"].tap()
        app.buttons["native-project-create"].tap()
        let projectName = app.textFields["native-name-input"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 5), app.debugDescription); projectName.tap(); projectName.typeText("Exam preparation")
        app.buttons["만들기"].tap()
        openInspector(app)
        app.buttons["native-inspector-materials"].tap()
        for action in ["native-library-view-menu", "native-library-import", "native-library-create"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 15), app.debugDescription)
        }
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let noteName = app.textFields["native-name-input"]
        XCTAssertTrue(noteName.waitForExistence(timeout: 5)); noteName.tap(); noteName.typeText("Revision notes")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        editor.tap(); editor.typeText("A project keeps its original notes.")
        app.dismissNativeTestKeyboard()
        openInspector(app); app.buttons["native-inspector-assistant"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "native-chat-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), app.debugDescription)
        input.tap(); input.typeText("Explain this material")
        app.dismissNativeTestKeyboard()
        app.buttons["native-ai-mode-quiz"].tap()
        XCTAssertTrue((input.value as? String ?? "").contains("Explain this material"))
        app.buttons["native-ai-mode-expected-exam"].tap()
        XCTAssertTrue((input.value as? String ?? "").contains("Explain this material"))
        XCTAssertTrue(app.buttons["native-ai-connect"].exists, "No key is required to compose a request")
        XCTAssertFalse(app.otherElements["native-document-assistant"].exists)
        capture("Project notes and unified AI with exam mode")
        app.buttons["native-inspector-materials"].tap()
        app.buttons["native-inspector-assistant"].tap()
        XCTAssertTrue((input.value as? String ?? "").contains("Explain this material"))
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        openInspector(app); app.buttons["native-inspector-assistant"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue((input.value as? String ?? "").contains("Explain this material"), app.debugDescription)
        XCTAssertTrue(editor.exists, "The project's document tab is restored")
        app.buttons["native-inspector-materials"].tap()
        openHome(app); app.buttons["native-home-courses"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-course-", "Physics")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-course-", "Exam preparation")).firstMatch.exists)
        capture("Courses and projects keep separate lists")
    }

    @MainActor func testAnnotationCaptureCancelAndPanelRotationKeepEditor() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        openHome(app); app.buttons["native-home-projects"].tap(); app.buttons["native-project-create"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription); name.tap(); name.typeText("Annotation project")
        app.buttons["만들기"].tap()
        openInspector(app); app.buttons["native-inspector-materials"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 15))
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let note = app.textFields["native-name-input"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("Capture note")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription); editor.tap(); editor.typeText("This paragraph stays editable after annotation.")
        app.dismissNativeTestKeyboard()
        openInspector(app); app.buttons["native-inspector-assistant"].tap()
        let annotate = app.buttons["native-ai-annotate"]
        XCTAssertTrue(annotate.waitForExistence(timeout: 10)); annotate.tap()
        let toolbar = app.descendants(matching: .any).matching(identifier: "native-ai-annotation-toolbar").firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["native-ai-annotation-cancel"].tap()
        XCTAssertTrue(annotate.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(editor.exists)
        editor.tap(); editor.typeText(" Still editable.")
        XCTAssertTrue((editor.value as? String ?? "").contains("Still editable."))
        app.dismissNativeTestKeyboard()
        annotate.tap()
        let region = app.descendants(matching: .any).matching(identifier: "native-ai-annotation-region").firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 10), app.debugDescription)
        region.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.1))
            .press(forDuration: 0.05, thenDragTo: region.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.4)))
        XCTAssertTrue(annotate.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(toolbar.exists)
        XCTAssertTrue(app.buttons["첨부 제거"].waitForExistence(timeout: 10), "The selected region is retained as an attachment")
        capture("Captured note is attached in the unified AI panel")
        let toggle = app.buttons["native-toggle-materials-rail"]
        XCTAssertEqual(app.buttons.matching(identifier: "native-toggle-materials-rail").count, 1)
        toggle.tap(); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(annotate.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(toggle.isHittable)
        XCTAssertTrue(annotate.isEnabled, app.debugDescription)
        XCTAssertGreaterThan(annotate.frame.midX, app.frame.midX, "The inspector stays against the right edge in portrait")
        XCTAssertEqual(app.buttons.matching(identifier: "native-toggle-materials-rail").count, 1)
        capture("Portrait inspector keeps annotation attachment and controls available")
        // Exercise a real touch at the visible control after the drawer moves
        // across the pinned/overlay boundary, then assert its actual behavior.
        annotate.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        app.buttons["native-ai-annotation-cancel"].tap()
        XCTAssertTrue(annotate.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        capture("Inspector stays available after rotation")
    }

    @MainActor private func openHome(_ app: XCUIApplication) {
        let home = app.buttons["native-section-library"]
        XCTAssertTrue(home.waitForExistence(timeout: 25), app.debugDescription)
        if !app.buttons["native-home-projects"].isHittable { home.tap() }
        XCTAssertTrue(app.buttons["native-home-projects"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func openInspector(_ app: XCUIApplication) {
        if !app.buttons["native-inspector-materials"].isHittable {
            let toggle = app.buttons["native-toggle-materials-rail"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription); toggle.tap()
        }
        XCTAssertTrue(app.buttons["native-inspector-materials"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
