import XCTest

/// Captures of the preview, the windows overview and the Markdown bar for side-by-side comparison with
/// Figma 130:4297, 132:2517 and 129:2615. The preview test also checks that its pages turn and it closes.
final class FigmaViewsScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testPreviewLight() throws { preview("light") }
    @MainActor func testPreviewDark() throws { preview("dark") }
    @MainActor func testWindowsOverviewLight() throws { windows("light") }
    @MainActor func testWindowsOverviewDark() throws { windows("dark") }
    @MainActor func testMarkdownLight() throws { markdown("light") }
    @MainActor func testMarkdownDark() throws { markdown("dark") }

    @MainActor private func preview(_ appearance: String) {
        let app = launch(appearance, course: "디자인 스튜디오")
        newNote("3주차 리서치 노트", app: app)
        app.buttons["native-pdf-pages"].firstMatch.tap()
        let addPage = app.buttons["native-pdf-page-add"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5), app.debugDescription); addPage.tap(); sleep(1); addPage.tap(); sleep(1)
        app.buttons["native-dock-preview"].firstMatch.tap()
        let count = app.staticTexts["native-document-preview-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 20), app.debugDescription); sleep(1)
        attach(app, "preview \(appearance)")
        let pages = Int(count.label.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        XCTAssertEqual(pages, 3, "The preview shows every page of the note")
        app.buttons["native-document-preview-thumbnail-1"].tap(); sleep(1)
        attach(app, "preview first page \(appearance)")
        app.buttons["native-document-preview-thumbnail-2"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 5), "A thumbnail turns the page")
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 5), "A swipe turns the page")
        app.buttons["native-document-preview-share"].tap()
        XCTAssertTrue(app.buttons["native-dock-export-pdf"].waitForExistence(timeout: 5), "공유 lists the tab strip's share actions")
        sleep(1); attach(app, "preview share \(appearance)")
        app.buttons["native-dock-export-pdf"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 4)).tap()
        app.buttons["native-document-preview-close"].tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 5), "닫기 returns to the note")
        XCTAssertFalse(count.exists)
    }

    @MainActor private func windows(_ appearance: String) {
        let app = launch(appearance, course: "디자인 스튜디오")
        newNote("3주차 노트", app: app)
        let toggle = app.buttons["native-workspace-windows-toggle"]
        toggle.tap()
        let add = app.buttons["native-window-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription); add.tap(); sleep(2)
        toggle.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription); sleep(1)
        attach(app, "windows \(appearance)")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-window-open-")).firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["윈도우 닫기"].waitForExistence(timeout: 5), "A long press keeps the window actions")
        sleep(1); attach(app, "windows card menu \(appearance)")
    }

    @MainActor private func markdown(_ appearance: String) {
        let app = launch(appearance, course: "디자인 스튜디오", extra: ["--native-keyboard-folds-panels"])
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription); title.tap()
        (title.value as? String).map { title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: $0.count)) }
        title.typeText("회의 메모"); app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription); editor.tap()
        editor.typeText("\n다음 주 할 일"); app.buttons["native-markdown-format-h2"].tap()
        // The heading command leaves its line selected: put the caret at the end of the note before the next line.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.42)).tap(); editor.typeText("\n")
        XCTAssertTrue((editor.value as? String ?? "").contains("다음 주 할 일"), "H2 keeps the line it is applied to: " + (editor.value as? String ?? "").replacingOccurrences(of: "\n", with: "⏎"))
        app.buttons["native-markdown-format-bullet"].tap()
        editor.typeText("인터뷰 질문 다시 정리하기\n떠 있는 팔레트 시안 2종 비교\n금요일까지 발표 자료 초안\n과목 폴더 구조")
        sleep(1); attach(app, "markdown \(appearance)")
        app.buttons["native-markdown-format-bold"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["native-markdown-format-strike"].waitForExistence(timeout: 5), "A long press on B keeps 취소선 and code")
        sleep(1); attach(app, "markdown B menu \(appearance)")
    }

    @MainActor private func newNote(_ name: String, app: XCUIApplication) {
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); sleep(1); create.tap(); app.buttons["새 노트"].firstMatch.tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText(name); app.buttons["native-new-note-create"].tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription); sleep(2)
    }

    @MainActor private func launch(_ appearance: String, course: String, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance] + extra
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(course); app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 20), app.debugDescription); sleep(1)
        return app
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
