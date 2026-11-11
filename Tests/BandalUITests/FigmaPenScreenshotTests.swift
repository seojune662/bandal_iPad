import XCTest

/// Captures of the pen settings, the tool popovers, the selection menu, the memo popover and the recording bar
/// for side-by-side comparison with Figma 261:8407, 259:8469 (H2 · H4 · H5 · H6) and 268:9049.
/// Each test only drives and attaches; behaviour is asserted in the feature tests.
final class FigmaPenScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testWritingPopoversLight() throws { try popovers("light") }
    @MainActor func testWritingPopoversDark() throws { try popovers("dark") }

    @MainActor private func popovers(_ appearance: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-pencil-dispatch-fixture", "-native.appearance", appearance]
        app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("UX 리서치"); app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); sleep(1); create.tap(); app.buttons["새 노트"].firstMatch.tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("UX 리서치 방법론"); app.buttons["native-new-note-create"].tap()
        let pen = app.buttons["native-pdf-tool-pen"], close = app.buttons["native-pdf-style-close"], body = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(pen.waitForExistence(timeout: 20), app.debugDescription); sleep(2)

        // 펜 설정: 볼펜, step 5, as the frame draws it.
        pen.tap()
        let ballpoint = app.buttons["native-pdf-pen-kind-ballpoint"]
        XCTAssertTrue(ballpoint.waitForExistence(timeout: 5), app.debugDescription); ballpoint.tap()
        let width = app.descendants(matching: .any)["native-pdf-width-slider"].firstMatch
        width.coordinate(withNormalizedOffset: .init(dx: 0.38, dy: 0.5)).tap(); sleep(1)
        attach(app, "pen 01 펜 설정 \(appearance)")
        app.buttons["native-pdf-favorite-star"].tap(); sleep(1)
        attach(app, "pen 02 별표 3칸 다 참 \(appearance)")
        app.buttons["native-pdf-palette-favorite-0"].tap()
        app.buttons["native-pdf-pen-kind-brush"].tap(); sleep(1)
        attach(app, "pen 03 붓 \(appearance)")
        app.buttons["native-pdf-palette-favorite-0"].tap(); sleep(1)
        attach(app, "pen 04 즐겨찾기 고름 \(appearance)")
        close.tap(); sleep(1)

        for dy in [0.42, 0.5] {
            body.coordinate(withNormalizedOffset: .init(dx: 0.36, dy: dy)).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.56, dy: dy + 0.02)))
        }
        sleep(1)
        for (index, tool) in ["highlighter", "eraser", "lasso", "tape"].enumerated() {
            let button = app.buttons["native-pdf-tool-" + tool]
            button.tap(); button.tap()
            if close.waitForExistence(timeout: 5) { sleep(1); attach(app, "pen 0\(index + 5) \(tool) \(appearance)"); close.tap(); sleep(1) }
        }

        // 선택 메뉴 · 스타일
        app.buttons["native-pdf-tool-lasso"].tap(); app.buttons["native-pdf-tool-lasso"].tap(); app.buttons["native-pdf-lasso-mode-box"].tap(); close.tap()
        body.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.36)).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.58)), withVelocity: .slow, thenHoldForDuration: 0.05)
        let style = app.buttons["native-pdf-selection-style"]
        if style.waitForExistence(timeout: 10) {
            sleep(1); attach(app, "pen 09 선택 메뉴 \(appearance)")
            style.tap(); sleep(1); attach(app, "pen 10 선택 스타일 \(appearance)")
            app.buttons["native-pdf-selection-width-1"].tap(); sleep(1)
            app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.95)).tap(); sleep(1)
            let more = app.buttons["native-pdf-selection-more"]
            if !more.exists {
                body.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.36)).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.58)), withVelocity: .slow, thenHoldForDuration: 0.05)
            }
            if more.waitForExistence(timeout: 10) {
                more.tap(); sleep(1); attach(app, "pen 11 선택 더 보기 \(appearance)")
                app.buttons["native-pdf-clear-selection"].tap(); sleep(1)
            }
        }

        // 테이프 on the page, then 메모
        app.buttons["native-pdf-tool-tape"].tap()
        body.coordinate(withNormalizedOffset: .init(dx: 0.36, dy: 0.66)).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.56, dy: 0.66)))
        body.coordinate(withNormalizedOffset: .init(dx: 0.36, dy: 0.74)).press(forDuration: 0.05, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.56, dy: 0.74)))
        sleep(1); body.coordinate(withNormalizedOffset: .init(dx: 0.45, dy: 0.74)).tap(); sleep(1)
        attach(app, "pen 12 테이프 \(appearance)")
        app.buttons["native-pdf-tool-comment"].tap()
        body.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.3)).tap()
        let editor = app.descendants(matching: .any)["native-pdf-comment-editor"].firstMatch
        if editor.waitForExistence(timeout: 5) {
            sleep(1); attach(app, "pen 13 새 메모 \(appearance)")
            editor.tap(); editor.typeText("이 그래프 시험에 나온다고 함"); app.buttons["native-pdf-save-comment"].tap(); sleep(2)
            body.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.3)).tap()
            if app.buttons["native-pdf-delete-comment"].waitForExistence(timeout: 5) { sleep(1); attach(app, "pen 14 메모 \(appearance)"); app.buttons["native-pdf-save-comment"].tap(); sleep(1) }
        }

        // 녹음 바
        let record = app.buttons["native-pdf-record"]
        record.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons.element(boundBy: 1)
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        if app.buttons["native-pdf-record-summarize"].waitForExistence(timeout: 20) {
            sleep(2); attach(app, "pen 15 녹음 중 \(appearance)")
            app.buttons["native-pdf-record-pause"].tap(); sleep(1); attach(app, "pen 16 녹음 일시 정지 \(appearance)")
            record.tap()
        }
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
