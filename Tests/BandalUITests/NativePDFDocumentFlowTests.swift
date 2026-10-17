import XCTest

/// Runs the production document, PDFKit/Metal, journal and SQLite path on an
/// iPad simulator or device. XCTest direct touches are routed through the
/// DEBUG Pencil-dispatch fixture; this does not measure real Pencil pressure,
/// palm rejection, hover or latency, which require a separate hardware pass.
final class NativePDFDocumentFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMultiplePDFsMarkdownDockingAndRestartPreserveInkToolsAndViewport() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: true)
        app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 20)); courseMenu.tap()
        app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("PDF Workflow")
        app.buttons["native-create-course"].tap()

        createPDF("Lecture A", app: app)
        tapControl("native-pdf-tool-pen", app: app)
        stroke(app, from: .init(dx: 0.35, dy: 0.35), to: .init(dx: 0.6, dy: 0.45))
        expectInk(1, app: app)
        tapControl("native-pdf-tool-highlighter", app: app)
        chooseColor("green", app: app)
        stroke(app, from: .init(dx: 0.35, dy: 0.65), to: .init(dx: 0.6, dy: 0.65))
        expectInk(2, app: app)
        tapControl("native-pdf-tool-eraser", app: app)
        stroke(app, from: .init(dx: 0.35, dy: 0.65), to: .init(dx: 0.6, dy: 0.65))
        expectInk(1, app: app)
        tapControl("native-pdf-undo", app: app); expectInk(2, app: app)
        tapControl("native-pdf-redo", app: app); expectInk(1, app: app)
        tapControl("native-pdf-undo", app: app); expectInk(2, app: app)
        tapControl("native-pdf-tool-highlighter", app: app)
        tapControl("native-pdf-pages", app: app)
        let secondPage = app.buttons["native-pdf-thumbnail-2"]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 10)); secondPage.tap()
        tapControl("native-pdf-pages", app: app)
        tapControl("native-pdf-zoom-in", app: app)
        expectPage(2, app: app)

        // Creation changes the active tab through the same document flush
        // barrier used for normal tab selection, while A remains open.
        createPDF("Lecture B", app: app)
        tapControl("native-pdf-tool-pen", app: app); chooseColor("blue", app: app)
        stroke(app, from: .init(dx: 0.3, dy: 0.4), to: .init(dx: 0.65, dy: 0.55))
        expectInk(1, app: app); tapControl("native-pdf-tool-eraser", app: app)
        createMarkdown(app: app)
        switchTab("Lecture A", app: app); expectInk(2, app: app); expectPage(2, app: app)
        XCTAssertTrue(app.buttons["native-pdf-tool-highlighter"].isSelected)
        expectZoom(1.1, app: app)
        // A recreated PDF editor still has its committed undo/redo stack.
        tapControl("native-pdf-undo", app: app); expectInk(1, app: app)
        tapControl("native-pdf-redo", app: app); expectInk(2, app: app)
        switchTab("Lecture B", app: app); expectInk(1, app: app); expectPage(1, app: app)
        XCTAssertTrue(app.buttons["native-pdf-tool-eraser"].isSelected)
        switchTab("Summary", app: app); expectMarkdown(app)
        chooseLayout("grid", app: app)
        let markdown = app.textViews["native-markdown-editor"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 15), app.debugDescription)
        let aTab = tab("Lecture A", app: app)
        aTab.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 1,
            thenDragTo: markdown.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.4)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        let merged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: markdown)
        XCTAssertEqual(XCTWaiter.wait(for: [merged], timeout: 15), .completed, app.debugDescription)
        capture("PDF and note workflow after cross-pane document drag")
        chooseLayout("single", app: app)
        switchTab("Summary", app: app); expectMarkdown(app)
        switchTab("Lecture A", app: app); expectInk(2, app: app); expectPage(2, app: app)
        XCTAssertEqual(app.webViews.count, 0)

        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        expectInk(2, app: app, timeout: 25); expectPage(2, app: app)
        XCTAssertTrue(app.buttons["native-pdf-tool-highlighter"].isSelected); expectZoom(1.1, app: app)
        switchTab("Lecture B", app: app); expectInk(1, app: app)
        XCTAssertTrue(app.buttons["native-pdf-tool-eraser"].isSelected)
        switchTab("Summary", app: app); expectMarkdown(app)
        capture("Two PDFs and Markdown preserved after process restart")
    }
    @MainActor
    func testDuplicatePDFPanesShareInkButKeepIndependentUndoToolsAndPages() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments(reset: true); app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap(); app.buttons["native-new-course"].tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Duplicate PDF")
        app.buttons["native-create-course"].tap()
        createPDF("Shared lecture", app: app)
        stroke(app, from: .init(dx: 0.35, dy: 0.35), to: .init(dx: 0.6, dy: 0.4)); expectInk(1, app: app)
        let originalTab = tab("Shared lecture", app: app), originalID = originalTab.identifier
        app.buttons["native-open-documents"].tap()
        let duplicate = app.buttons["native-duplicate-right"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5)); duplicate.tap()
        let copyTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-instance:")).firstMatch
        XCTAssertTrue(copyTab.waitForExistence(timeout: 15)); let copyID = copyTab.identifier
        let a = app.otherElements["native-pdf-pane-" + String(originalID.dropFirst("native-document-tab-".count))]
        let b = app.otherElements["native-pdf-pane-" + String(copyID.dropFirst("native-document-tab-".count))]
        XCTAssertTrue(a.waitForExistence(timeout: 15)); XCTAssertTrue(b.waitForExistence(timeout: 15))
        expectPaneInk(1, pane: a); expectPaneInk(1, pane: b)
        tapPaneControl("native-pdf-tool-highlighter", pane: b)
        paneStroke(b, from: .init(dx: 0.3, dy: 0.6), to: .init(dx: 0.6, dy: 0.6))
        expectPaneInk(2, pane: a); expectPaneInk(2, pane: b)
        tapPaneControl("native-pdf-undo", pane: a)
        expectPaneInk(1, pane: a); expectPaneInk(1, pane: b)
        tapPaneControl("native-pdf-undo", pane: b)
        expectPaneInk(0, pane: a); expectPaneInk(0, pane: b)
        tapPaneControl("native-pdf-redo", pane: b); tapPaneControl("native-pdf-redo", pane: a)
        expectPaneInk(2, pane: a); expectPaneInk(2, pane: b)
        tapPaneControl("native-pdf-tool-pen", pane: a)
        tapPaneControl("native-pdf-tool-highlighter", pane: b)
        tapPaneControl("native-pdf-pages", pane: a)
        let pageTwo = a.buttons["native-pdf-thumbnail-2"]
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 10)); pageTwo.tap()
        tapPaneControl("native-pdf-pages", pane: a)
        expectPanePage(2, pane: a); expectPanePage(1, pane: b)
        capture("One PDF in two panes with independent page and undo state")
        app.buttons["native-section-learning"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native-learning-home").firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        XCTAssertTrue(a.waitForExistence(timeout: 25)); XCTAssertTrue(b.waitForExistence(timeout: 25))
        expectPaneInk(2, pane: a); expectPaneInk(2, pane: b)
        expectPanePage(2, pane: a); expectPanePage(1, pane: b)
        XCTAssertTrue(a.buttons["native-pdf-tool-pen"].isSelected)
        XCTAssertTrue(b.buttons["native-pdf-tool-highlighter"].isSelected)
        app.buttons[copyID].tap(); app.buttons["native-close-document"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: b)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
        expectPaneInk(2, pane: a); expectPanePage(2, pane: a)
        paneStroke(a, from: .init(dx: 0.3, dy: 0.4), to: .init(dx: 0.6, dy: 0.5)); expectPaneInk(3, pane: a)
        tapPaneControl("native-pdf-undo", pane: a); expectPaneInk(2, pane: a)
        capture("Closing one PDF instance preserves the other editable view")
    }
    @MainActor private func tapPaneControl(_ id: String, pane: XCUIElement) {
        let item = pane.buttons[id]
        XCTAssertTrue(item.waitForExistence(timeout: 15))
        if id.hasPrefix("native-pdf-tool-"), item.isSelected { return }
        let scroll = pane.scrollViews["native-pdf-tool-scroll"]
        if !item.isHittable, scroll.exists { scroll.swipeRight(); scroll.swipeRight(); for _ in 0..<5 where !item.isHittable { scroll.swipeLeft() } }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed); item.tap()
    }
    @MainActor private func paneStroke(_ pane: XCUIElement, from: CGVector, to: CGVector) {
        let body = pane.otherElements["native-pdf-workspace"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        body.coordinate(withNormalizedOffset: from).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func expectPaneInk(_ count: Int, pane: XCUIElement) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: pane.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
    }
    @MainActor private func expectPanePage(_ page: Int, pane: XCUIElement) {
        let current = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(page)), object: pane.textFields["native-pdf-page"])
        XCTAssertEqual(XCTWaiter.wait(for: [current], timeout: 10), .completed)
    }
    private func arguments(reset: Bool) -> [String] {
        ["--native-ui-testing", "--native-pencil-dispatch-fixture", "--native-pages-fixture"] + (reset ? ["--reset-native-ui-testing"] : [])
    }
    @MainActor private func createPDF(_ title: String, app: XCUIApplication) {
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["native-new-note-create"].tap()
        expectInk(0, app: app)
    }
    @MainActor private func createMarkdown(app: XCUIApplication) {
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let name = app.textFields["native-name-input"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Summary")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); editor.tap()
        editor.typeText("\nBoth lecture PDFs keep their own handwritten notes.")
        app.dismissNativeTestKeyboard()
    }
    @MainActor private func expectMarkdown(_ app: XCUIApplication) {
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("Both lecture PDFs keep their own handwritten notes."))
        XCTAssertFalse((editor.value as? String ?? "").contains(".pdf"), "Tab dragging must not paste its payload into a note")
    }
    @MainActor private func tab(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", title)).firstMatch
    }
    @MainActor private func switchTab(_ title: String, app: XCUIApplication) {
        let item = tab(title, app: app)
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if !item.isHittable {
            let tabScroll = app.scrollViews.containing(.button, identifier: item.identifier).firstMatch
            if tabScroll.exists { tabScroll.swipeRight(); for _ in 0..<3 where !item.isHittable { tabScroll.swipeLeft() } }
        }
        XCTAssertTrue(item.isHittable, app.debugDescription); item.tap()
    }
    @MainActor private func chooseLayout(_ preset: String, app: XCUIApplication) {
        app.buttons["native-open-documents"].tap()
        let item = app.buttons["native-dock-preset-" + preset]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    @MainActor private func chooseColor(_ color: String, app: XCUIApplication) {
        tapControl("native-pdf-style", app: app)
        let item = app.buttons["native-pdf-color-" + color]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap(); app.buttons["native-pdf-style-close"].firstMatch.tap()
    }
    @MainActor private func stroke(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let body = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        body.coordinate(withNormalizedOffset: from).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func expectInk(_ count: Int, app: XCUIApplication, timeout: TimeInterval = 20) {
        let item = app.buttons["native-pdf-drawing-tools"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: timeout), .completed, app.debugDescription)
    }
    @MainActor private func expectPage(_ page: Int, app: XCUIApplication) {
        let current = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(page)), object: app.textFields["native-pdf-page"])
        XCTAssertEqual(XCTWaiter.wait(for: [current], timeout: 10), .completed, app.debugDescription)
    }
    @MainActor private func expectZoom(_ zoom: Double, app: XCUIApplication) {
        let current = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", String(format: "zoom=%.4f", zoom)), object: app.otherElements["bandal-native-pdf-body"])
        XCTAssertEqual(XCTWaiter.wait(for: [current], timeout: 10), .completed, app.debugDescription)
    }
    @MainActor private func tapControl(_ identifier: String, app: XCUIApplication) {
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if identifier.hasPrefix("native-pdf-tool-"), item.isSelected { return }
        let tools = app.scrollViews["native-pdf-tool-scroll"]
        if !item.isHittable, tools.exists { tools.swipeRight(); tools.swipeRight(); for _ in 0..<4 where !item.isHittable { tools.swipeLeft() } }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription); item.tap()
    }
    @MainActor private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
