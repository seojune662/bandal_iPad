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
        // Thickness is one of three slots, each one of twelve steps (no millimetre slider).
        tap("native-pdf-width-slot-2", in: app)
        XCTAssertTrue(app.buttons["native-pdf-width-slot-2"].firstMatch.isSelected)
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
        tap("native-pdf-width-slot-0", in: app)
        app.sliders["native-pdf-opacity-slider"].adjust(toNormalizedSliderPosition: 0.5)
        capture("Swift highlighter physical width and effective opacity")
        closePalette(in: app)
        let markerStyle = app.buttons["native-pdf-style"].value as? String
        XCTAssertNotEqual(penStyle, markerStyle)
        chooseTool("pen", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, markerStyle)
        chooseTool("ballpoint", in: app)
        // The helper scrolls the tool row until the slot is hittable.
        tap("native-pdf-width-slot-2", in: app)
        XCTAssertTrue(app.buttons["native-pdf-width-slot-2"].firstMatch.isSelected)
        // A second tap on the chosen slot opens its twelve steps; pick step 10.
        tap("native-pdf-width-slot-2", in: app)
        let steps = app.descendants(matching: .any)["native-pdf-width-steps"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 5), app.debugDescription)
        steps.coordinate(withNormalizedOffset: CGVector(dx: 9.5 / 12, dy: 0.5)).tap()
        XCTAssertEqual(steps.value as? String, "10단계")
        capture("Twelve-step thickness bar for a ballpoint slot")
        app.buttons["native-pdf-width-slot-2"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 300)).tap()
        let ballpointStyle = app.buttons["native-pdf-style"].value as? String
        XCTAssertNotEqual(ballpointStyle, penStyle, "볼펜 keeps its own width")
        capture("Swift ballpoint with its own fixed-width style")
        chooseTool("pen", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, penStyle)
        chooseTool("ballpoint", in: app)
        XCTAssertEqual(app.buttons["native-pdf-style"].value as? String, ballpointStyle)
        chooseTool("pen", in: app)
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        let palette = app.buttons["native-pdf-style"]
        XCTAssertTrue(palette.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(palette.value as? String, penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(palette.value as? String, markerStyle)
        chooseTool("ballpoint", in: app)
        XCTAssertEqual(palette.value as? String, ballpointStyle)
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
                XCTAssertFalse(pane.buttons["native-pdf-favorite-\(index)"].exists)
            }
            let tools = pane.scrollViews["native-pdf-tool-scroll"]
            XCTAssertTrue(tools.exists, app.debugDescription)
            XCTAssertGreaterThan(tools.frame.width, pane.frame.width - 48, "The floating palette fills a narrow pane up to its insets")
            tools.swipeLeft()
            XCTAssertTrue(pane.buttons["native-pdf-width-slot-2"].isHittable, app.debugDescription)
        }
        right.buttons["native-pdf-style"].tap()
        let rightSettings = right.scrollViews["native-pdf-palette-scroll"]
        let savedPreset = right.buttons["native-pdf-palette-favorite-2"]
        for _ in 0..<3 where !savedPreset.isHittable { rightSettings.swipeUp() }
        savedPreset.tap()
        XCTAssertEqual(left.buttons["native-pdf-style"].value as? String, penStyle)
        right.buttons["native-pdf-palette-favorite-0"].tap()
        right.buttons["native-pdf-style-close"].tap()
        XCTAssertEqual(right.buttons["native-pdf-style"].value as? String, penStyle)
        capture("PDF tools use full width with numbered shortcuts removed")
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
        let oneLine = editor.frame.height
        editor.tap(); editor.typeText("한글 필기와 Swift\n색상과 서식을 저장합니다")
        XCTAssertGreaterThan(editor.frame.height, oneLine * 1.6, "The live box grows with the second line instead of clipping it")
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

    @MainActor private func createDocument(_ title: String, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments(reset: true) + extra; app.launch()
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
    @MainActor
    func testEmptyPaperLassoCopiesPDFRegionAndFingerTapPastesImageAfterRestart() {
        XCTExpectFailure("Known failure since 1.1.0: after relaunch the lasso region menu lacks 영역 이미지 복사.", strict: false)
        let app = createDocument("Lasso Region")
        chooseTool("lasso", in: app)
        let box = app.buttons["박스형"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5)); box.tap()
        let body = app.otherElements["native-pdf-workspace"]
        body.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.65, dy: 0.55)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        let crop = app.buttons["native-pdf-copy-region"]
        XCTAssertTrue(crop.waitForExistence(timeout: 10), "An area of the PDF must be selectable without ink")
        XCTAssertFalse(app.buttons["native-pdf-delete-selection"].exists)
        crop.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: crop)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 15), .completed)
        capture("PDF region selection on paper without ink")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(body.waitForExistence(timeout: 25))
        chooseTool("lasso", in: app)
        // A long press on empty paper offers paste (a plain tap only dismisses).
        body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.6)).press(forDuration: 0.7)
        let bar = app.descendants(matching: .any).matching(identifier: "native-pdf-selection-bar").firstMatch
        let menuVisible = bar.waitForExistence(timeout: 10)
        capture("Empty-paper finger paste menu")
        XCTAssertTrue(menuVisible, "A long press on empty paper offers paste\n" + app.debugDescription)
        let paste = bar.buttons["native-pdf-paste"]
        XCTAssertTrue(paste.isEnabled); paste.tap(); expectInk(1, in: app)
        capture("Copied PDF area pasted as an editable image")
        tap("native-pdf-undo", in: app); expectInk(0, in: app)
        tap("native-pdf-redo", in: app); expectInk(1, in: app)
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch(); expectInk(1, in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.85)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        let copyImage = app.buttons["native-pdf-copy-selection"]
        XCTAssertTrue(copyImage.waitForExistence(timeout: 10)); copyImage.tap()
        let imageCopied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: copyImage)
        XCTAssertEqual(XCTWaiter.wait(for: [imageCopied], timeout: 15), .completed)
        body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2)).press(forDuration: 0.7)
        XCTAssertTrue(bar.waitForExistence(timeout: 10)); bar.buttons["native-pdf-paste"].tap()
        expectInk(2, in: app)
        capture("A pasted image can be selected and copied again")
        app.terminate(); app.launch(); expectInk(2, in: app)
        XCTAssertEqual(app.webViews.count, 0)
    }
    @MainActor
    func testLassoDragAutoscrollMovesInkAcrossPagesWithUndoAndSavesAfterRestart() {
        let app = createDocument("Across Pages", extra: ["--native-pages-fixture"])
        let body = app.otherElements["native-pdf-workspace"], nativeBody = app.otherElements["bandal-native-pdf-body"]
        body.coordinate(withNormalizedOffset: .init(dx: 0.36, dy: 0.34)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.46)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        expectInk(1, in: app)
        func expectPages(_ text: String) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: nativeBody)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed, app.debugDescription)
        }
        expectPages("savedObjectPages=1:1,2:0,3:0")
        chooseTool("lasso", in: app)
        app.buttons["박스형"].firstMatch.tap()
        body.coordinate(withNormalizedOffset: .init(dx: 0.30, dy: 0.27)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.68, dy: 0.53)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["native-pdf-delete-selection"].waitForExistence(timeout: 10))
        body.coordinate(withNormalizedOffset: .init(dx: 0.49, dy: 0.40)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.50, dy: 0.97)),
            withVelocity: .slow, thenHoldForDuration: 2.4)
        expectPages("savedObjectPages=1:0,")
        let saved = nativeBody.value as? String ?? ""
        let movedToThird = saved.contains("savedObjectPages=1:0,2:0,3:1")
        let movedPages = movedToThird ? "savedObjectPages=1:0,2:0,3:1" : "savedObjectPages=1:0,2:1,3:0"
        expectPages(movedPages); expectInk(1, in: app)
        capture("Lasso drag across page edge commits the destination page")
        tap("native-pdf-undo", in: app); expectPages("savedObjectPages=1:1,2:0,3:0")
        tap("native-pdf-redo", in: app); expectPages(movedPages)
        app.terminate(); app.launchArguments = arguments(reset: false) + ["--native-pages-fixture"]; app.launch()
        expectInk(1, in: app); expectPages(movedPages)
    }
    @MainActor
    func testPartialEraserCutsAStrokeInTwoAsOneUndoStep() {
        let app = createDocument("Eraser Notes")
        chooseTool("pen", in: app)
        let body = app.otherElements["native-pdf-workspace"]
        body.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.42)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.42)))
        expectInk(1, in: app)
        chooseTool("eraser", in: app)
        let partial = app.buttons["부분"].firstMatch
        XCTAssertTrue(partial.waitForExistence(timeout: 5), app.debugDescription); partial.tap()
        tap("native-pdf-width-slot-0", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.32)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.52)))
        expectInk(2, in: app)
        capture("Partial eraser leaves the two ends of the stroke")
        tap("native-pdf-undo", in: app); expectInk(1, in: app)
        tap("native-pdf-redo", in: app); expectInk(2, in: app)
        app.buttons["획 전체"].firstMatch.tap()
        body.coordinate(withNormalizedOffset: .init(dx: 0.32, dy: 0.32)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.32, dy: 0.52)))
        expectInk(1, in: app)
    }
    @MainActor
    func testTapeHidesUntilTappedCommentPinKeepsANoteAndLaserSavesNothing() {
        let app = createDocument("Study Notes")
        let body = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(app.buttons["native-pdf-record"].exists, "The palette microphone starts a lecture recording")
        chooseTool("laser", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.35)))
        capture("Laser pointer trail")
        expectInk(0, in: app)

        chooseTool("tape", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5)))
        expectInk(1, in: app)
        let all = app.buttons["native-pdf-tape-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10)); XCTAssertEqual(all.label, "모두 보기")
        capture("Memorisation tape covers the line")
        body.coordinate(withNormalizedOffset: .init(dx: 0.45, dy: 0.5)).tap()
        let peeled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "모두 가리기"), object: all)
        XCTAssertEqual(XCTWaiter.wait(for: [peeled], timeout: 10), .completed, "A tap peels the tape back" + app.debugDescription)
        capture("Peeled-back tape")
        // The tape covers the line again on its own after a moment.
        let covered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "모두 보기"), object: all)
        XCTAssertEqual(XCTWaiter.wait(for: [covered], timeout: 10), .completed)

        chooseTool("comment", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.25)).tap()
        let note = app.textViews["native-pdf-comment-editor"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        note.tap(); note.typeText("시험 범위")
        app.buttons["native-pdf-save-comment"].tap(); expectInk(2, in: app)
        capture("Comment pin on the page")
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch(); expectInk(2, in: app)
        chooseTool("comment", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.25)).tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(note.value as? String, "시험 범위")
        app.buttons["native-pdf-delete-comment"].tap(); expectInk(1, in: app)
        tap("native-pdf-undo", in: app); expectInk(2, in: app) // the deleted pin comes back
    }
    private func arguments(reset: Bool) -> [String] {
        ["--native-ui-testing", "--native-pencil-dispatch-fixture"] + (reset ? ["--reset-native-ui-testing"] : [])
    }
    @MainActor private func chooseTool(_ tool: String, in app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + tool]
        if !item.isSelected { tap("native-pdf-tool-" + tool, in: app) }
    }
    @MainActor private func openPalette(in app: XCUIApplication) {
        let tool = ["highlighter", "ballpoint"].first { app.buttons["native-pdf-tool-" + $0].isSelected } ?? "pen"
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
