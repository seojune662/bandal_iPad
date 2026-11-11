import XCTest

/// Captures of the note / PDF screen for side-by-side comparison with Figma 269:9222 and 130:4614.
/// Each test only drives and attaches; behaviour is asserted in the feature tests.
final class FigmaNoteScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testNoteScreenLight() throws { try noteScreen("light") }
    @MainActor func testNoteScreenDark() throws { try noteScreen("dark") }

    @MainActor private func noteScreen(_ appearance: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("UX 리서치"); app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); sleep(1); create.tap(); app.buttons["새 노트"].firstMatch.tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("UX 리서치 방법론"); app.buttons["native-new-note-create"].tap()
        let pen = app.buttons["native-pdf-tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 20), app.debugDescription); sleep(2)
        attach(app, "note 01 펜 \(appearance)")

        app.buttons["native-pdf-tool-comment"].tap()
        app.otherElements["native-pdf-workspace"].coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.35)).tap()
        let editor = app.textViews["native-pdf-comment-editor"]
        if editor.waitForExistence(timeout: 5) { editor.tap(); editor.typeText("메모"); app.buttons["native-pdf-save-comment"].tap(); sleep(1) }
        attach(app, "note 02 댓글 표시 \(appearance)")

        pen.tap(); sleep(1)
        app.buttons["native-pdf-palette-collapse"].tap(); sleep(1)
        attach(app, "note 03 팔레트 접힘 \(appearance)")
        app.buttons["native-pdf-palette-expand"].tap()
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
