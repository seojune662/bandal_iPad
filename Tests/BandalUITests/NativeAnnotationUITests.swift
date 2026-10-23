import XCTest

/// Exercises real document capture through the shared AI panel. Pencil input is
/// dispatched through the existing isolated DEBUG fixture; web content is inline
/// HTML. No API key, AI response, remote page, or photo-library access is required.
final class NativeAnnotationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPDFCompositeAttachmentAndCancelRestorePencilTool() {
        let app = launchCourse("PDF annotation", extra: ["--native-pencil-dispatch-fixture"])
        openInspector(app)
        app.buttons["native-inspector-materials"].tap()
        let create = app.buttons["native-library-create"]
        waitUntilReady(create, in: app); create.tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Annotation composite")
        app.buttons["native-new-note-create"].tap()
        waitUntilReady(app.buttons["native-pdf-tool-pen"], in: app)
        closeInspector(app)
        let body = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(body.waitForExistence(timeout: 15), app.debugDescription)
        draw(in: body, from: .init(dx: 0.35, dy: 0.28), to: .init(dx: 0.65, dy: 0.36))
        expectInk(1, in: app)
        let highlighter = app.buttons["native-pdf-tool-highlighter"]
        waitUntilReady(highlighter, in: app); highlighter.tap()
        draw(in: body, from: .init(dx: 0.36, dy: 0.32), to: .init(dx: 0.63, dy: 0.32))
        expectInk(2, in: app)
        capture("PDF original with pen and highlighter before annotation")

        beginAnnotation(app)
        app.buttons["native-ai-annotation-cancel"].tap()
        XCTAssertTrue(app.buttons["native-ai-annotate"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(highlighter.isSelected, "Cancel must restore the actual previous Pencil tool")
        XCTAssertFalse(app.buttons["첨부 제거"].exists, "Cancel must not produce an attachment")
        closeInspector(app)
        // A new persisted stroke verifies drawing is functional after cancellation,
        // rather than checking only that the toolbar has returned.
        draw(in: body, from: .init(dx: 0.37, dy: 0.40), to: .init(dx: 0.62, dy: 0.40))
        expectInk(3, in: app)

        beginAnnotation(app)
        let region = annotationRegion(app)
        draw(in: region, from: .init(dx: 0.28, dy: 0.17), to: .init(dx: 0.75, dy: 0.55))
        expectAttachment(app)
        openAttachment(app)
        XCTAssertTrue(app.images["native-ai-attachment-preview-image"].waitForExistence(timeout: 10),
                      "Handwritten regions must attach as a composited image without requiring PDF text")
        capture("AI PDF attachment includes pen and highlighter on the original page")
        app.buttons["닫기"].tap()
        closeInspector(app)
        expectInk(3, in: app)
        XCTAssertTrue(highlighter.isSelected, "Successful capture must restore the Pencil tool too")
    }

    @MainActor
    func testBrowserElementAndRegionCaptureAndCancelRestorePageInteraction() {
        let app = launchBrowser()
        let page = app.webViews.firstMatch
        let field = page.textFields["Website input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("Before annotation")
        app.dismissNativeTestKeyboard()

        beginAnnotation(app)
        app.buttons["native-ai-annotation-cancel"].tap()
        XCTAssertTrue(app.buttons["native-ai-annotate"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["첨부 제거"].exists)
        closeInspector(app)
        field.tap(); field.typeText(" after cancel")
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "after cancel"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 5), .completed,
                       "The original webpage must be interactive after cancelling annotation")
        app.dismissNativeTestKeyboard()

        beginAnnotation(app)
        // Tap the visible DOM heading through the selection overlay. The element
        // path should attach both its text and an image cropped to its DOM bounds.
        let heading = page.staticTexts["Native browser fixture"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        heading.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        expectAttachment(app)
        openAttachment(app)
        let previewText = app.staticTexts["native-ai-attachment-preview-text"]
        XCTAssertTrue(previewText.waitForExistence(timeout: 10))
        XCTAssertEqual(previewText.label, "Native browser fixture")
        XCTAssertTrue(app.images["native-ai-attachment-preview-image"].exists)
        capture("AI web element attachment keeps its text and cropped appearance")
        app.buttons["닫기"].tap()
        app.buttons["첨부 제거"].tap()

        beginAnnotation(app)
        draw(in: annotationRegion(app), from: .init(dx: 0.04, dy: 0.03), to: .init(dx: 0.80, dy: 0.43))
        expectAttachment(app)
        openAttachment(app)
        XCTAssertTrue(app.images["native-ai-attachment-preview-image"].waitForExistence(timeout: 10))
        XCTAssertFalse(previewText.exists, "A free rectangle is an image attachment, not unrelated page text")
        capture("AI web rectangle attachment captures only the chosen page area")
    }

    @MainActor
    func testBrowserTextSelectionCreatesTextAttachment() {
        let app = launchBrowser()
        beginAnnotation(app)
        let toolbar = app.descendants(matching: .any).matching(identifier: "native-ai-annotation-toolbar").firstMatch
        toolbar.buttons["텍스트"].tap()
        let paragraph = app.webViews.firstMatch.staticTexts["Bandal needle one."]
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), app.debugDescription)
        paragraph.coordinate(withNormalizedOffset: .init(dx: 0.45, dy: 0.5)).press(forDuration: 1.2)
        let attach = app.buttons["native-ai-annotation-attach-text"]
        waitUntilReady(attach, in: app); attach.tap()
        expectAttachment(app)
        openAttachment(app)
        let text = app.staticTexts["native-ai-attachment-preview-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(["Bandal", "needle", "one"].contains(where: text.label.contains), text.label)
        XCTAssertFalse(app.images["native-ai-attachment-preview-image"].exists,
                       "Selecting text must not silently attach the whole webpage")
        capture("AI browser selected text attachment with its source")
    }

    @MainActor private func launchCourse(_ title: String, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + extra
        app.launch()
        let home = app.buttons["native-section-library"]
        XCTAssertTrue(home.waitForExistence(timeout: 25), app.debugDescription)
        if !app.buttons["native-home-courses"].isHittable { home.tap() }
        app.buttons["native-home-courses"].tap()
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["native-create-course"].tap()
        return app
    }
    @MainActor private func launchBrowser() -> XCUIApplication {
        let app = launchCourse("Browser annotation", extra: ["--native-browser-ui-fixture", "--native-browser-parity-ui-fixture"])
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        waitUntilReady(add, in: app); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Native browser fixture"].waitForExistence(timeout: 15), app.debugDescription)
        closeInspector(app)
        return app
    }
    @MainActor private func openInspector(_ app: XCUIApplication) {
        if !app.buttons["native-inspector-materials"].isHittable {
            let toggle = app.buttons["native-toggle-materials-rail"]
            waitUntilReady(toggle, in: app); toggle.tap()
        }
        XCTAssertTrue(app.buttons["native-inspector-materials"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func closeInspector(_ app: XCUIApplication) {
        if app.buttons["native-inspector-materials"].isHittable { app.buttons["native-toggle-materials-rail"].tap() }
    }
    @MainActor private func beginAnnotation(_ app: XCUIApplication) {
        openInspector(app); app.buttons["native-inspector-assistant"].tap()
        let annotate = app.buttons["native-ai-annotate"]
        waitUntilReady(annotate, in: app); annotate.tap()
        waitUntilReady(app.buttons["native-ai-annotation-cancel"], in: app)
    }
    @MainActor private func annotationRegion(_ app: XCUIApplication) -> XCUIElement {
        let region = app.descendants(matching: .any).matching(identifier: "native-ai-annotation-region").firstMatch
        waitUntilReady(region, in: app)
        return region
    }
    @MainActor private func expectAttachment(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["첨부 제거"].waitForExistence(timeout: 15),
                      "Capture must create an actual draft attachment, not merely close selection mode.\n" + app.debugDescription)
        XCTAssertFalse(app.buttons["native-ai-annotation-cancel"].exists)
        XCTAssertTrue(app.buttons["native-ai-annotate"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "첨부 제거")).count, 1,
                       "Each gesture should create exactly one attachment")
    }
    @MainActor private func openAttachment(_ app: XCUIApplication) {
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-ai-attachment-")).firstMatch
        waitUntilReady(chip, in: app); chip.tap()
        XCTAssertTrue(app.buttons["닫기"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func draw(in element: XCUIElement, from start: CGVector, to end: CGVector) {
        element.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
            thenDragTo: element.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    @MainActor private func expectInk(_ count: Int, in app: XCUIApplication) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"),
                                             object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 25), .completed, app.debugDescription)
    }
    @MainActor private func waitUntilReady(_ element: XCUIElement, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
