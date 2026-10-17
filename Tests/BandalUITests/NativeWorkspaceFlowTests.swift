import XCTest
import UIKit

final class NativeWorkspaceFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTextNotePersistsAcrossCloseAndRelaunchWithoutWebView() throws {
        let app = launch(reset: true)
        createCourse(in: app)
        app.buttons["native-library-create"].tap()
        app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Study Note")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        editor.tap(); editor.typeText("\nA native note survives restart.")
        app.buttons["native-close-document"].tap()
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "Study Note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("A native note survives restart."))
        app.terminate()
        app.launchArguments = ["--native-ui-testing"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue((editor.value as? String ?? "").contains("A native note survives restart."))
        XCTAssertEqual(app.webViews.count, 0)
        attachScreenshot(app, name: "Native text note after restart")
    }

    @MainActor
    func testHandwritingNoteUsesNativePDFAndSurvivesRotation() throws {
        let app = launch(reset: true)
        createCourse(in: app)
        app.buttons["native-library-create"].tap()
        app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Calculus")
        app.buttons["모눈"].tap()
        app.buttons["native-new-note-create"].tap()
        XCTAssertTrue(app.buttons["native-close-document"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
        let pdf = app.otherElements["native-pdf-workspace"]
        let pen = app.buttons["native-pdf-tool-pen"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: pen)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        let start = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        expectInkCount(1, in: app)
        tapPDFControl("native-pdf-undo", in: app)
        expectInkCount(0, in: app)
        tapPDFControl("native-pdf-redo", in: app)
        expectInkCount(1, in: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].exists)
        attachScreenshot(app, name: "Native handwriting note landscape")
        app.terminate()
        app.launchArguments = ["--native-ui-testing", "--native-pencil-dispatch-fixture"]
        app.launch()
        expectInkCount(1, in: app)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testNativeShapeLassoHistoryAndTextPersistAcrossRelaunch() throws {
        let app = launch(reset: true)
        createCourse(in: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Object Notes")
        app.buttons["native-new-note-create"].tap()
        let tools = app.buttons["native-pdf-tool-pen"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: tools)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        let pdf = app.otherElements["native-pdf-workspace"]
        // Draw-and-hold is the production shape path; no separate insertion tool.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.32))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.52)), withVelocity: .slow, thenHoldForDuration: 0.9)
        expectInkCount(1, in: app)
        selectObjectTool("lasso", in: app)
        // Lasso selects actual stroke/polygon-edge intersections, not overlapping
        // bounding boxes. Cross the corrected line instead of tracing beside it.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.56))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.28)), withVelocity: .slow, thenHoldForDuration: 0.05)
        let remove = app.buttons["native-pdf-delete-selection"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.42))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.54)), withVelocity: .slow, thenHoldForDuration: 0.05)
        // A move keeps the selection (notebook behaviour); the bar is disabled
        // while the update commits and the user releases it with ✕.
        expectInkCount(1, in: app)
        let moveCommitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [moveCommitted], timeout: 15), .completed, "Selection survives a move" + app.debugDescription)
        app.buttons["선택 해제"].tap()
        let released = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 10), .completed, app.debugDescription)
        // This crossing is below the original line's endpoint (y=0.52), so
        // selection also proves the move changed geometry, not merely its count.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.60))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.60)), withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-pdf-selection-style"].exists, "Floating bar offers restyle")
        tapPDFControl("native-pdf-copy-selection", in: app)
        remove.tap(); expectInkCount(0, in: app)
        // Paste lives in the lasso row so a copy can land on any page without a selection.
        tapPDFControl("native-pdf-paste", in: app); expectInkCount(1, in: app)
        attachScreenshot(app, name: "Pasted stroke from the clipboard")
        let boxMode = app.buttons["박스형"].firstMatch
        XCTAssertTrue(boxMode.waitForExistence(timeout: 5), app.debugDescription); boxMode.tap()
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.72)), withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Box lasso selects the pasted stroke" + app.debugDescription)
        attachScreenshot(app, name: "Box lasso selection with floating action bar")
        remove.tap(); expectInkCount(0, in: app)
        app.buttons["자유형"].firstMatch.tap()
        tapPDFControl("native-pdf-undo", in: app); expectInkCount(1, in: app)
        selectObjectTool("text", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.72)).tap()
        let editor = app.textViews["native-pdf-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        editor.tap(); editor.typeText("Swift object text survives restart")
        app.buttons["native-pdf-save-text"].tap(); expectInkCount(2, in: app)
        attachScreenshot(app, name: "Native shape and text after lasso history")
        app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-pencil-dispatch-fixture"]; app.launch()
        expectInkCount(2, in: app)
        attachScreenshot(app, name: "Restored native PDF object geometry before editing")
        selectObjectTool("text", in: app)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.72)).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((editor.value as? String ?? "").contains("Swift object text survives restart"), app.debugDescription)
        app.buttons["취소"].tap()
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor private func selectObjectTool(_ name: String, in app: XCUIApplication) {
        tapPDFControl("native-pdf-tool-" + name, in: app)
    }

    @MainActor private func tapPDFControl(_ identifier: String, in app: XCUIApplication) {
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if identifier.hasPrefix("native-pdf-tool-"), item.isSelected { return }
        let tools = app.scrollViews["native-pdf-tool-scroll"]
        if !item.isHittable, tools.exists {
            tools.swipeRight(); tools.swipeRight()
            for _ in 0..<4 where !item.isHittable { tools.swipeLeft() }
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        item.tap()
    }

    @MainActor
    func testSourceSelectionCommentSurvivesRelaunch() throws {
        // Real PDF text, rather than a textbox drawing, exercises PDFKit's
        // selection coordinates and the canonical annotation persistence path.
        let app = launch(reset: true, pencil: false, extra: ["--native-text-selection-fixture"])
        createCourse(in: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Source Annotations")
        app.buttons["native-new-note-create"].tap()
        let select = app.buttons["native-pdf-tool-select"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: select)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        select.tap()
        app.buttons["페이지 맞춤"].tap()
        let pdf = app.otherElements["native-pdf-workspace"]
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)).press(forDuration: 1.2)
        let comment = app.buttons["native-pdf-comment-source"]
        XCTAssertTrue(comment.waitForExistence(timeout: 10), app.debugDescription); comment.tap()
        let editor = app.textViews["native-pdf-annotation-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        editor.tap(); editor.typeText("Source comment survives restart")
        app.buttons["native-pdf-save-annotation"].tap()
        let count = app.buttons["native-pdf-annotations"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "1"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed, app.debugDescription)
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["native-pdf-annotations"].waitForExistence(timeout: 20), app.debugDescription)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "1"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed, app.debugDescription)
        app.buttons["native-pdf-annotations"].tap()
        let annotation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-pdf-annotation-")).firstMatch
        XCTAssertTrue(annotation.waitForExistence(timeout: 10), app.debugDescription); annotation.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((editor.value as? String ?? "").contains("Source comment survives restart"))
        XCTAssertEqual(app.webViews.count, 0)
        attachScreenshot(app, name: "Native PDF original source annotation after restart")
    }

    @MainActor
    func testPDFPageReorderDeleteUndoAndRecoveryPersistAcrossRelaunch() throws {
        let app = launch(reset: true, extra: ["--native-pages-fixture"])
        createCourse(in: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Page History")
        app.buttons["native-new-note-create"].tap()
        tapPDFControl("native-pdf-tool-pen", in: app)
        let pdf = app.otherElements["native-pdf-workspace"]
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.32))
            .press(forDuration: 0.05, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.61, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.05)
        expectInkCount(1, in: app)
        app.buttons["native-pdf-pages"].tap(); expectPageCount(3, in: app)
        // Drop below the second thumbnail midpoint: page one and its ink
        // move after page two, and the reader follows that original page.
        let first = app.buttons["native-pdf-thumbnail-1"], second = app.buttons["native-pdf-thumbnail-2"]
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2"), object: app.textFields["native-pdf-page"])
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 20), .completed, app.debugDescription)
        expectPageCount(3, in: app); expectInkCount(1, in: app)
        deleteFirstPage(in: app)
        expectPageCount(2, in: app); expectInkCount(1, in: app)
        deleteFirstPage(in: app)
        expectPageCount(1, in: app); expectInkCount(0, in: app)
        app.buttons["native-pdf-pages-undo"].tap(); expectPageCount(2, in: app); expectInkCount(1, in: app)
        app.buttons["native-pdf-pages-redo"].tap(); expectPageCount(1, in: app); expectInkCount(0, in: app)
        app.buttons["native-pdf-pages-undo"].tap(); expectPageCount(2, in: app); expectInkCount(1, in: app)
        attachScreenshot(app, name: "Native PDF page panel after reorder deletion and undo")
        app.terminate(); app.launchArguments = ["--native-ui-testing", "--native-pencil-dispatch-fixture"]; app.launch()
        expectPageCount(2, in: app); expectInkCount(1, in: app)
        XCTAssertTrue(app.buttons["native-pdf-thumbnail-2"].exists)
        // The retained before-snapshot also remains available after restart.
        app.buttons["native-pdf-pages-recovery"].tap(); app.buttons["변경 전 복구 사본 만들기"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "페이지 복구")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor private func deleteFirstPage(in app: XCUIApplication) {
        let menu = app.buttons["native-pdf-page-menu-1"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        menu.tap(); app.buttons["native-pdf-page-delete"].tap()
        let confirm = app.alerts.buttons.matching(identifier: "native-pdf-confirm-page-delete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
    }

    @MainActor private func expectPageCount(_ count: Int, in app: XCUIApplication) {
        let value = app.staticTexts["native-pdf-page-count"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "/ \(count)"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 20), .completed, app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: app.buttons["native-pdf-pages"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
    }

    @MainActor private func expectBoardCount(_ count: Int, in app: XCUIApplication) {
        let status = app.buttons["native-whiteboard-style"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed, app.debugDescription)
    }

    /// Inspect the composited canvas, not a database count or renderer input.
    /// Element screenshots avoid global screen coordinates and iPad PNG rotation.
    @MainActor private func expectBoardPixels(in app: XCUIApplication, phase: String, highlighter: Bool, pen: Bool,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let canvas = app.otherElements["native-whiteboard-workspace"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), file: file, line: line)
        var latest: NativeWhiteboardPixelSummary?
        var latestImage: UIImage?
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let image = canvas.screenshot().image
            latestImage = image
            latest = NativeWhiteboardPixelSummary(image: image)
            guard let pixels = latest else { return false }
            return pixels.matches(highlighter: highlighter, pen: pen)
        }, object: nil)
        let result = XCTWaiter.wait(for: [rendered], timeout: 6)
        if let image = latestImage {
            let attachment = XCTAttachment(image: image)
            attachment.name = "Whiteboard pixels — " + phase; attachment.lifetime = .keepAlways; add(attachment)
        }
        let pixels = try XCTUnwrap(latest, "Unable to decode the actual canvas screenshot", file: file, line: line)
        print("WHITEBOARD_PIXELS \(phase): \(pixels)")
        XCTAssertEqual(result, .completed, "\(phase): \(pixels)", file: file, line: line)
        XCTAssertGreaterThan(pixels.whiteFraction, 0.85, "Paper must remain white: \(pixels)", file: file, line: line)
        XCTAssertLessThan(pixels.redFraction, 0.001, "Rendering must not turn the paper red: \(pixels)", file: file, line: line)
        if highlighter { XCTAssertGreaterThanOrEqual(pixels.yellow, 12, "The retained stroke must be visibly yellow: \(pixels)", file: file, line: line) }
        else { XCTAssertLessThanOrEqual(pixels.yellow, 5, "No highlighter has been drawn yet: \(pixels)", file: file, line: line) }
        if pen { XCTAssertGreaterThanOrEqual(pixels.dark, 8, "The pen stroke must be visible: \(pixels)", file: file, line: line) }
        else { XCTAssertLessThanOrEqual(pixels.dark, 5, "The erased pen must not remain visible: \(pixels)", file: file, line: line) }
    }

    @MainActor private func launch(reset: Bool, pencil: Bool = true, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing"] + (pencil ? ["--native-pencil-dispatch-fixture"] : []) + (reset ? ["--reset-native-ui-testing"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    @MainActor private func createCourse(in app: XCUIApplication) {
        app.buttons["native-course-add-menu"].tap()
        app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Mathematics")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        expectation(for: ready, evaluatedWith: create)
        waitForExpectations(timeout: 20)
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func expectInkCount(_ count: Int, in app: XCUIApplication) {
        let status = app.buttons["native-pdf-drawing-tools"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed, app.debugDescription)
    }
}

private struct NativeWhiteboardPixelSummary: CustomStringConvertible {
    let samples: Int, white: Int, red: Int, yellow: Int, dark: Int
    var whiteFraction: Double { Double(white) / Double(samples) }
    var redFraction: Double { Double(red) / Double(samples) }
    var description: String { "samples=\(samples) white=\(white) red=\(red) yellow=\(yellow) dark=\(dark)" }

    @MainActor init?(image: UIImage) {
        // draw(in:) applies UIImage.imageOrientation before measuring pixels.
        // Standard range and an explicit RGBA context avoid grayscale/channel
        // assumptions, including the R8 conversion that caused this regression.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let image = normalized.cgImage else { return nil }
        self.init(cgImage: image)
    }

    init?(cgImage image: CGImage) {
        let scale = min(1, 800 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard width >= 20, height >= 20, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }
        var samples = 0, white = 0, red = 0, yellow = 0, dark = 0
        // This central paper rectangle includes both test strokes and excludes
        // scroll gutters, toolbars, sidebars, shadows, and system window controls.
        for y in (height / 5)..<(height * 4 / 5) {
            for x in (width / 5)..<(width * 4 / 5) {
                let index = (y * width + x) * 4
                let r = Int(rgba[index]), g = Int(rgba[index + 1]), b = Int(rgba[index + 2])
                samples += 1
                if min(r, g, b) >= 230 && max(r, g, b) - min(r, g, b) <= 16 { white += 1 }
                if r >= 200 && g < 110 && b < 110 { red += 1 }
                if r >= 200 && g >= 170 && b < 235 && r - b >= 20 && g - b >= 12 { yellow += 1 }
                if max(r, g, b) < 110 { dark += 1 }
            }
        }
        self.samples = samples; self.white = white; self.red = red; self.yellow = yellow; self.dark = dark
    }
    func matches(highlighter: Bool, pen: Bool) -> Bool {
        whiteFraction > 0.85 && redFraction < 0.001 && (highlighter ? yellow >= 12 : yellow <= 5) && (pen ? dark >= 8 : dark <= 5)
    }
}
