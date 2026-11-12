import XCTest

/// Production Swift controls + PDFKit/Metal + durable storage. XCTest touches
/// enter the DEBUG Pencil fixture; physical Pencil pressure/latency are separate.
final class NativePDFWritingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPaletteIndependentToolsAndNarrowPanesPersist() {
        let app = createDocument("Palette Notes")
        // A new note starts with the plain pen, the first of the three pen types; the palette has no favourite pens.
        XCTAssertEqual(style(in: app)?.hasPrefix("pen ink "), true, String(describing: style(in: app)))
        XCTAssertFalse(app.buttons["native-pdf-quick-favorite-0"].exists)
        openPalette(in: app)
        XCTAssertTrue(app.buttons["native-pdf-pen-kind-pen"].isSelected); XCTAssertEqual(app.buttons["native-pdf-pen-kind-pen"].label, "펜")
        XCTAssertFalse(app.buttons["native-pdf-favorite-star"].exists); XCTAssertFalse(app.buttons["native-pdf-palette-favorite-0"].exists)
        // The pen settings show the palette's colours (the rest are behind +) on the design's 36 pt cells.
        for color in ["ink", "blue", "red", "green"] {
            let button = app.buttons["native-pdf-color-" + color].firstMatch
            XCTAssertTrue(button.exists, color)
            XCTAssertGreaterThanOrEqual(button.frame.width, 36)
            XCTAssertGreaterThanOrEqual(button.frame.height, 36)
        }
        app.buttons["native-pdf-color-blue"].firstMatch.tap()
        // Thickness is one of twelve steps on a slider (no millimetre value).
        setSlider("native-pdf-width-slider", to: 8.0 / 11, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["native-pdf-width-slider"].firstMatch.value as? String, "9단계")
        setSlider("native-pdf-opacity-slider", to: 0.8, in: app)
        capture("Swift pen settings with a blue pen")
        closePalette(in: app)
        let penStyle = style(in: app)
        XCTAssertEqual(penStyle?.hasPrefix("pen blue 9단계"), true, String(describing: penStyle))
        chooseTool("highlighter", in: app)
        openPalette(in: app)
        app.buttons["native-pdf-color-green"].firstMatch.tap()
        setSlider("native-pdf-width-slider", to: 0, in: app)
        setSlider("native-pdf-opacity-slider", to: 0.5, in: app)
        capture("Swift highlighter physical width and effective opacity")
        closePalette(in: app)
        let markerStyle = style(in: app)
        XCTAssertNotEqual(penStyle, markerStyle)
        chooseTool("pen", in: app)
        XCTAssertEqual(style(in: app), penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(style(in: app), markerStyle)
        chooseTool("ballpoint", in: app)
        // Each pen type keeps its own thickness; pick step 10 for 볼펜.
        openPalette(in: app)
        setSlider("native-pdf-width-slider", to: 9.0 / 11, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["native-pdf-width-slider"].firstMatch.value as? String, "10단계")
        capture("Twelve-step thickness slider for 볼펜")
        closePalette(in: app)
        let ballpointStyle = style(in: app)
        XCTAssertNotEqual(ballpointStyle, penStyle, "볼펜 keeps its own width")
        capture("Swift ballpoint with its own fixed-width style")
        chooseTool("pen", in: app)
        XCTAssertEqual(style(in: app), penStyle)
        chooseTool("ballpoint", in: app)
        XCTAssertEqual(style(in: app), ballpointStyle)
        chooseTool("brush", in: app)
        XCTAssertEqual(style(in: app)?.hasPrefix("brush ink "), true, "붓 is a third pen type with its own style")
        // The plain pen comes back from 붓 with its own style.
        chooseTool("pen", in: app)
        XCTAssertEqual(style(in: app), penStyle)
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(style(in: app), penStyle)
        chooseTool("highlighter", in: app)
        XCTAssertEqual(style(in: app), markerStyle)
        chooseTool("ballpoint", in: app)
        XCTAssertEqual(style(in: app), ballpointStyle)
        chooseTool("pen", in: app)
        XCTAssertEqual(style(in: app), penStyle)

        let originalTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Palette Notes")).firstMatch
        let originalID = String(originalTab.identifier.dropFirst("native-document-tab-".count))
        app.openNativeDockLayoutMenu()
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
                XCTAssertFalse(pane.buttons["native-pdf-quick-favorite-\(index)"].exists)
                XCTAssertTrue(pane.buttons["native-pdf-width-slot-\(index)"].exists, "The row ends with the three thickness dots")
            }
            let tools = pane.scrollViews["native-pdf-tool-scroll"]
            XCTAssertTrue(tools.exists, app.debugDescription)
            XCTAssertGreaterThan(tools.frame.width, pane.frame.width - 48, "The floating palette fills a narrow pane up to its insets")
            // The thumbnails button stands alone under the palette, clear of it at any pane width.
            let pages = pane.buttons["native-pdf-pages"]
            XCTAssertTrue(pages.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(pages.frame.minY, tools.frame.maxY, "The thumbnails button never overlaps the palette")
            // The row ends with the collapse button; the pen is back at its start.
            for _ in 0..<5 where !pane.buttons["native-pdf-palette-collapse"].isHittable { tools.swipeLeft() }
            XCTAssertTrue(pane.buttons["native-pdf-palette-collapse"].isHittable, app.debugDescription)
            for _ in 0..<5 where !pane.buttons["native-pdf-tool-pen"].isHittable { tools.swipeRight() }
        }
        // The pen settings open under the pane's own 펜 button; a colour picked there changes that pane only.
        right.buttons["native-pdf-tool-pen"].tap()
        let other = app.buttons["native-pdf-color-red"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5), app.debugDescription); other.tap()
        closePalette(in: app)
        XCTAssertNotEqual(right.buttons["native-pdf-tool-pen"].value as? String, penStyle)
        XCTAssertEqual(left.buttons["native-pdf-tool-pen"].value as? String, penStyle)
        right.buttons["native-pdf-tool-pen"].tap()
        XCTAssertTrue(app.buttons["native-pdf-color-blue"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["native-pdf-color-blue"].firstMatch.tap()
        closePalette(in: app)
        XCTAssertEqual(right.buttons["native-pdf-tool-pen"].value as? String, penStyle)
        capture("PDF tools use full width in narrow panes")
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testPaletteThicknessDotsPickASlotOpenItsTwelveStepsAndReturnToThePen() {
        let app = createDocument("Thickness Notes")
        let dots = (0..<3).map { app.buttons["native-pdf-width-slot-\($0)"] }
        XCTAssertTrue(dots[1].isSelected, "The pen starts on the middle dot")
        XCTAssertEqual(dots.map { $0.value as? String }, ["3단계", "6단계", "9단계"])
        tap("native-pdf-width-slot-2", in: app)
        XCTAssertTrue(dots[2].isSelected); XCTAssertEqual(style(in: app)?.hasPrefix("pen ink 9단계"), true, String(describing: style(in: app)))
        // A second tap on the chosen dot opens its twelve steps; the step picked there stays in that dot.
        tap("native-pdf-width-slot-2", in: app)
        let steps = app.descendants(matching: .any)["native-pdf-width-steps"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 5), app.debugDescription)
        steps.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "12단계"), object: steps)], timeout: 5), .completed, app.debugDescription)
        capture("Twelve steps of the palette's third thickness dot")
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5)).tap()
        XCTAssertTrue(steps.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(dots[2].value as? String, "12단계"); XCTAssertEqual(style(in: app)?.hasPrefix("pen ink 12단계"), true)
        // With a tool that has no thickness the dots are the pen's: a tap returns to the pen with that thickness.
        tap("native-pdf-tool-select", in: app)
        XCTAssertFalse(dots[2].isSelected)
        tap("native-pdf-width-slot-0", in: app)
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].isSelected); XCTAssertEqual(style(in: app)?.hasPrefix("pen ink 3단계"), true, String(describing: style(in: app)))
    }

    @MainActor
    func testHoldShapeUndoAndFormattedKoreanTextSurviveRestart() {
        let app = createDocument("Writing Notes")
        chooseTool("pen", in: app)
        openPalette(in: app)
        let correction = app.switches["native-pdf-shape-recognition"]
        XCTAssertTrue(correction.exists)
        if correction.value as? String == "0" { correction.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
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
        // 텍스트 편집 is behind the selection menu's ⋯.
        let more = app.buttons["native-pdf-selection-more"], edit = app.buttons["native-pdf-edit-text"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Saved text stays selected for movement, resize and editing")
        capture("Native corrected line and formatted Korean text on paper")
        more.tap(); XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
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
        XCTAssertTrue(add.waitForExistence(timeout: 25)); add.tap()
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
        chooseOption("native-pdf-lasso-mode-box", of: "lasso", in: app)
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
        chooseOption("native-pdf-lasso-mode-box", of: "lasso", in: app)
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
        // The eraser's options open on a second tap: 부분, the smallest of the three sizes.
        tap("native-pdf-tool-eraser", in: app)
        let partial = app.buttons["native-pdf-eraser-mode-partial"]
        XCTAssertTrue(partial.waitForExistence(timeout: 5), app.debugDescription); partial.tap()
        // A tap on the size already chosen would open its twelve steps (the palette is shared across documents).
        let smallest = app.buttons["native-pdf-option-width-slot-0"]
        if !smallest.isSelected { smallest.tap() }
        closePalette(in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.32)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.52)))
        expectInk(2, in: app)
        capture("Partial eraser leaves the two ends of the stroke")
        tap("native-pdf-undo", in: app); expectInk(1, in: app)
        tap("native-pdf-redo", in: app); expectInk(2, in: app)
        chooseOption("native-pdf-eraser-mode-stroke", of: "eraser", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.32, dy: 0.32)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.32, dy: 0.52)))
        expectInk(1, in: app)
        // 형광펜만 지우기: the eraser crosses the pen stroke's other half and a highlighter line, and takes only the line.
        chooseTool("highlighter", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.55, dy: 0.47)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.72, dy: 0.47)))
        expectInk(2, in: app)
        chooseTool("eraser", in: app)
        tap("native-pdf-tool-eraser", in: app)
        let highlighterOnly = app.switches["native-pdf-eraser-highlighter-only"]
        XCTAssertTrue(highlighterOnly.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(highlighterOnly.value as? String, "0")
        highlighterOnly.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() // the switch itself, not its label
        XCTAssertEqual(highlighterOnly.value as? String, "1")
        capture("Eraser options with 형광펜만 지우기")
        closePalette(in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.63, dy: 0.34)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.63, dy: 0.54)))
        sleep(2); capture("Only the highlighter line is erased")
        expectInk(1, in: app)
        tap("native-pdf-undo", in: app); expectInk(2, in: app)
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
        // The 테이프 button says whether the tape covers its text.
        let tape = app.buttons["native-pdf-tool-tape"]
        func expectTape(_ state: String, _ message: String) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: tape)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed, message + app.debugDescription)
        }
        expectTape("covered", "New tape covers the line")
        capture("Memorisation tape covers the line")
        body.coordinate(withNormalizedOffset: .init(dx: 0.45, dy: 0.5)).tap()
        expectTape("revealed", "A tap peels the tape back")
        capture("Peeled-back tape")
        // The tape covers the line again on its own after a moment.
        expectTape("covered", "The tape returns")
        // 모두 보이기 / 모두 가리기 are in the tape's options.
        chooseOption("native-pdf-tape-reveal-all", of: "tape", in: app); expectTape("revealed", "모두 보이기")
        chooseOption("native-pdf-tape-cover-all", of: "tape", in: app); expectTape("covered", "모두 가리기")

        chooseTool("comment", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.25)).tap()
        let note = app.descendants(matching: .any)["native-pdf-comment-editor"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        note.tap(); note.typeText("시험 범위")
        app.buttons["native-pdf-save-comment"].tap(); expectInk(2, in: app)
        capture("Comment pin on the page")
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch(); expectInk(2, in: app)
        chooseTool("comment", in: app)
        body.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.25)).tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(note.value as? String, "시험 범위")
        // 이어서 메모하기 adds a line to the same memo.
        let more = app.descendants(matching: .any)["native-pdf-comment-input"].firstMatch
        more.tap(); more.typeText("2장 참고"); app.buttons["native-pdf-comment-send"].tap()
        XCTAssertEqual(note.value as? String, "시험 범위\n2장 참고")
        capture("Memo popover with a second line")
        app.buttons["native-pdf-delete-comment"].tap(); expectInk(1, in: app)
        tap("native-pdf-undo", in: app); expectInk(2, in: app) // the deleted pin comes back
    }
    private func arguments(reset: Bool) -> [String] {
        ["--native-ui-testing", "--native-pencil-dispatch-fixture"] + (reset ? ["--reset-native-ui-testing"] : [])
    }
    @MainActor private func chooseTool(_ tool: String, in app: XCUIApplication) {
        // 펜 ("pen"), 볼펜 and 붓 share the palette's 펜 button; the type is picked in the pen settings.
        let name = ["ballpoint", "brush"].contains(tool) ? "pen" : tool, item = app.buttons["native-pdf-tool-" + name]
        if !item.isSelected { tap("native-pdf-tool-" + name, in: app) }
        guard name == "pen", style(in: app)?.hasPrefix(tool + " ") != true else { return }
        openPalette(in: app); tap("native-pdf-pen-kind-" + tool, in: app); closePalette(in: app)
    }
    /// The chosen ink tool's button carries "<tool> <colour> <step> <opacity>".
    @MainActor private func style(in app: XCUIApplication) -> String? {
        ["pen", "highlighter"].map { app.buttons["native-pdf-tool-" + $0] }.first { $0.isSelected }?.value as? String
    }
    @MainActor private func openPalette(in app: XCUIApplication) {
        let tool = app.buttons["native-pdf-tool-highlighter"].isSelected ? "highlighter" : "pen"
        tap("native-pdf-tool-" + tool, in: app)
        XCTAssertTrue(app.buttons["native-pdf-style-close"].waitForExistence(timeout: 5), app.debugDescription)
    }
    @MainActor private func closePalette(in app: XCUIApplication) { app.buttons["native-pdf-style-close"].tap() }
    /// A second tap on the chosen tool opens its options; picks one and closes them.
    @MainActor private func chooseOption(_ identifier: String, of tool: String, in app: XCUIApplication) {
        tap("native-pdf-tool-" + tool, in: app)
        let option = app.buttons[identifier]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription); option.tap()
        closePalette(in: app)
    }
    /// Taps the design's slider at a fraction of its track (the thumb travels 11 pt inside each end).
    @MainActor private func setSlider(_ identifier: String, to fraction: CGFloat, in app: XCUIApplication) {
        let slider = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription)
        let inset = 11 / max(1, slider.frame.width)
        slider.coordinate(withNormalizedOffset: CGVector(dx: inset + (1 - 2 * inset) * fraction, dy: 0.5)).tap()
    }
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
