import XCTest

/// Production Swift controls + PDFKit/Metal + durable storage. XCTest touches
/// enter the DEBUG Pencil fixture; physical Pencil pressure/latency are separate.
final class NativePDFWritingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPaletteFavoritesIndependentToolsAndNarrowPanesPersist() {
        let app = createDocument("Palette Notes")
        chooseTool("pen", in: app)
        openPalette(in: app)
        for color in ["ink", "red", "orange", "yellow", "green", "blue", "violet"] {
            let button = app.buttons["native-pdf-color-" + color].firstMatch
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        app.buttons["native-pdf-color-blue"].firstMatch.tap()
        app.buttons["native-pdf-palette-width-2"].firstMatch.tap()
        app.sliders["native-pdf-opacity-slider"].adjust(toNormalizedSliderPosition: 0.8)
        let saveFavorite = app.buttons["native-pdf-save-favorite-0"]
        let settingsScroll = app.scrollViews["native-pdf-palette-scroll"]
        for _ in 0..<3 where !saveFavorite.isHittable { settingsScroll.swipeUp() }
        saveFavorite.tap()
        settingsScroll.swipeDown()
        capture("Swift pen palette and saved blue favorite")
        closePalette(in: app)
        let penStyle = app.buttons["native-pdf-style"].value as? String
        XCTAssertNotNil(penStyle)
        chooseTool("highlighter", in: app)
        openPalette(in: app)
        app.buttons["native-pdf-color-green"].firstMatch.tap()
        app.buttons["native-pdf-palette-width-0"].firstMatch.tap()
        app.sliders["native-pdf-opacity-slider"].adjust(toNormalizedSliderPosition: 0.5)
        capture("Swift highlighter physical width and effective opacity")
        closePalette(in: app)
        let markerStyle = app.buttons["native-pdf-style"].value as? String
        XCTAssertNotEqual(penStyle, markerStyle)
        chooseTool("pen", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, markerStyle)
        chooseTool("pen", in: app)
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        let palette = app.buttons["native-pdf-style"]
        XCTAssertTrue(palette.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(palette.value as? String, penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(palette.value as? String, markerStyle)
        chooseTool("pen", in: app)

        let originalTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Palette Notes")).firstMatch
        let originalID = String(originalTab.identifier.dropFirst("native-document-tab-".count))
        app.buttons["native-open-documents"].tap()
        let duplicate = app.buttons["native-duplicate-right"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5)); duplicate.tap()
        let copyTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-instance:")).firstMatch
        XCTAssertTrue(copyTab.waitForExistence(timeout: 15))
        let copyID = String(copyTab.identifier.dropFirst("native-document-tab-".count))
        let left = app.otherElements["native-pdf-pane-" + originalID]
        let right = app.otherElements["native-pdf-pane-" + copyID]
        XCTAssertTrue(left.waitForExistence(timeout: 15)); XCTAssertTrue(right.waitForExistence(timeout: 15))
        for pane in [left, right] {
            for index in 0..<3 {
                let favorite = pane.buttons["native-pdf-favorite-\(index)"]
                XCTAssertTrue(favorite.isHittable, app.debugDescription)
                XCTAssertGreaterThanOrEqual(favorite.frame.width, 44)
                XCTAssertGreaterThanOrEqual(favorite.frame.height, 44)
                XCTAssertGreaterThanOrEqual(favorite.frame.minX, pane.frame.minX)
                XCTAssertLessThanOrEqual(favorite.frame.maxX, pane.frame.maxX)
            }
        }
        right.buttons["native-pdf-favorite-2"].tap()
        XCTAssertEqual(left.buttons["native-pdf-style"].value as? String, penStyle)
        right.buttons["native-pdf-favorite-0"].tap()
        XCTAssertEqual(right.buttons["native-pdf-style"].value as? String, penStyle)
        capture("Swift favorites remain reachable in two narrow PDF panes")
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testHoldShapeUndoAndFormattedKoreanTextSurviveRestart() {
        let app = createDocument("Writing Notes")
        chooseTool("pen", in: app)
        openPalette(in: app)
        let correction = app.switches["native-pdf-shape-recognition"]
        XCTAssertTrue(correction.exists)
        for _ in 0..<3 where !correction.isHittable { app.scrollViews["native-pdf-palette-scroll"].swipeUp() }
        if correction.value as? String == "0" { correction.tap() }
        closePalette(in: app)
        let body = app.otherElements["native-pdf-workspace"]
        body.coordinate(withNormalizedOffset: .init(dx: 0.32, dy: 0.28)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.66, dy: 0.37)),
            withVelocity: .slow, thenHoldForDuration: 0.9)
        expectInk(1, in: app)
        tap("native-pdf-undo", in: app); expectInk(1, in: app)
        capture("Undo correction restores exactly one original stroke")
        tap("native-pdf-undo", in: app); expectInk(0, in: app)
        tap("native-pdf-redo", in: app); expectInk(1, in: app)
        tap("native-pdf-redo", in: app); expectInk(1, in: app)
        chooseTool("text", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.58)).tap()
        let editor = app.textViews["native-pdf-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let size = app.textFields["native-pdf-text-size-input"]
        size.tap(); size.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "24")
        app.buttons["native-pdf-text-bold"].tap()
        app.buttons["native-pdf-text-color-blue"].tap()
        app.buttons["native-pdf-text-align-center"].tap()
        app.buttons["native-pdf-text-more"].tap()
        app.buttons["native-pdf-text-fill-yellow"].tap()
        app.sliders["native-pdf-text-width"].adjust(toNormalizedSliderPosition: 0.55)
        app.buttons["native-pdf-text-format-close"].tap()
        editor.tap(); editor.typeText("한글 필기와 Swift\n색상과 서식을 저장합니다")
        capture("Native Korean text editor with formatting and width preview")
        app.buttons["native-pdf-save-text"].tap(); expectInk(2, in: app)
        let edit = app.buttons["native-pdf-edit-text"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Saved text stays selected for movement, resize and editing")
        capture("Native corrected line and formatted Korean text on paper")
        edit.tap(); XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("한글 필기와 Swift"))
        XCTAssertEqual(size.value as? String, "24")
        XCTAssertTrue(app.buttons["native-pdf-text-bold"].isSelected)
        XCTAssertTrue(app.buttons["native-pdf-text-align-center"].isSelected)
        app.buttons["native-pdf-cancel-text"].tap()
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        expectInk(2, in: app)
        chooseTool("text", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.58)).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((editor.value as? String ?? "").contains("색상과 서식을 저장합니다"))
        XCTAssertEqual(size.value as? String, "24")
        XCTAssertTrue(app.buttons["native-pdf-text-bold"].isSelected)
        capture("Formatted Korean text restored after full process restart")
        app.buttons["native-pdf-cancel-text"].tap()
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor private func createDocument(_ title: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments(reset: true); app.launch()
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25)); add.tap(); app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Writing Integration")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        create.tap(); app.buttons["새 노트"].tap()
        let note = app.textFields["native-new-note-title"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText(title)
        app.buttons["native-new-note-create"].tap()
        let pen = app.buttons["native-pdf-tool-pen"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: pen)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, app.debugDescription)
        return app
    }
    private func arguments(reset: Bool) -> [String] {
        ["--native-ui-testing", "--native-pencil-dispatch-fixture"] + (reset ? ["--reset-native-ui-testing"] : [])
    }
    @MainActor private func chooseTool(_ tool: String, in app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + tool]
        if !item.isSelected { tap("native-pdf-tool-" + tool, in: app) }
    }
    @MainActor private func openPalette(in app: XCUIApplication) {
        let tool = app.buttons["native-pdf-tool-highlighter"].isSelected ? "highlighter" : "pen"
        tap("native-pdf-tool-" + tool, in: app)
        XCTAssertTrue(app.buttons["native-pdf-style-close"].waitForExistence(timeout: 5), app.debugDescription)
    }
    @MainActor private func closePalette(in app: XCUIApplication) { app.buttons["native-pdf-style-close"].tap() }
    @MainActor private func tap(_ identifier: String, in app: XCUIApplication) {
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        let scroll = app.scrollViews["native-pdf-tool-scroll"]
        if !item.isHittable, scroll.exists { scroll.swipeRight(); for _ in 0..<5 where !item.isHittable { scroll.swipeLeft() } }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription); item.tap()
    }
    @MainActor private func expectInk(_ count: Int, in app: XCUIApplication) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 25), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
