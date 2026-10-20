import XCTest

/// Drives the App Review walkthrough at a human pace for a screen recording.
/// Runs only with TEST_RUNNER_BANDAL_REVIEW_RECORDING=1. Needs the sample lecture PDF
/// in the app's Documents (Files › On My iPad › app) and the Zipformer model under
/// Documents/Bandal-Native-UI-Tests/SpeechModels/zipformer-ko.
final class ReviewRecordingTests: XCTestCase {
    private let sample = "선형대수학_3주차_강의자료"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_REVIEW_RECORDING"] == "1", "Review recording only")
        continueAfterFailure = false
        ReviewStroke.skipQuiescenceWaits()
    }

    @MainActor func testReviewWalkthrough() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.press(.home); pause(3)
        app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--native-pencil-dispatch-fixture", "--reset-native-ui-testing"]
        app.launch()

        createCourse(); snap("createCourse")
        importAndOpenPDF(); snap("importAndOpenPDF")
        writeOnPDF(); snap("writeOnPDF")
        splitWithNote(); snap("splitWithNote")
        recordLecture(); snap("recordLecture")
        openBrowser(); snap("openBrowser")
        showAIConsent(); snap("showAIConsent")
        showSettings(); snap("showSettings")
    }

    // MARK: Steps

    @MainActor private func createCourse() {
        tap(app.buttons["native-course-add-menu"], wait: 30)
        tap(app.buttons["native-new-course"])
        type("선형대수학", into: app.textFields["native-course-name"])
        tap(app.buttons["native-create-course"]); pause(2)
    }

    @MainActor private func importAndOpenPDF() {
        tap(app.buttons["native-library-import"]); pause(2)
        // System document picker: On My iPad › app folder. The picker opens on iCloud Drive, so the
        // seconds before the app folder shows are blurred in the exported video (personal file names).
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", sample)).firstMatch
        if !file.waitForExistence(timeout: 2) {
            tap(app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["나의 iPad", "On My iPad"])).firstMatch, wait: 10)
            tap(app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["반달", "Bandal"])).firstMatch, wait: 10)
        }
        tap(file, wait: 10)
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["열기", "Open"])).firstMatch
        if open.waitForExistence(timeout: 3), open.isEnabled { tap(open) }
        let material = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-material-" + sample)).firstMatch
        tap(material, wait: 20)
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].waitForExistence(timeout: 20), app.debugDescription)
        pause(2)
    }

    @MainActor private func writeOnPDF() {
        let pdf = app.otherElements["native-pdf-workspace"]
        tool("pen")
        let style = app.buttons["native-pdf-style"]
        if style.exists, style.isHittable {
            tap(style); tap(app.buttons["native-pdf-color-blue"], wait: 5)
            let close = app.buttons["native-pdf-style-close"].firstMatch
            if close.exists, close.isHittable { tap(close) }
        }
        let page = pageFrame(pdf)
        // Write the worked example inside the page's "풀이" box (x 0.094–0.906, y 0.387–0.613 of the page).
        let block = CGRect(x: page.minX + page.width * 0.14, y: page.minY + page.height * 0.425, width: page.width * 0.5, height: page.width * 0.5 * ReviewHandwriting.aspect)
        for stroke in ReviewHandwriting.strokes {
            let points = stroke.map { CGPoint(x: block.minX + $0.x * block.width, y: block.minY + $0.y * block.height) }
            draw(points)
        }
        pause(1.5)
        // Highlight the characteristic equation in section 2.
        tool("highlighter"); pause(1)
        draw([CGPoint(x: page.minX + page.width * 0.094, y: page.minY + page.height * 0.281), CGPoint(x: page.minX + page.width * 0.6, y: page.minY + page.height * 0.281)], duration: 0.7)
        pause(2)
        tool("pen")
    }

    @MainActor private func splitWithNote() {
        // A Markdown note in a new tab, then the PDF and the note side by side.
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch)
        tap(app.buttons["native-new-tab-new-note"])
        let editor = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        pause(1)
        focus(editor, at: CGVector(dx: 0.5, dy: 0.15))
        for line in ["3주차 고유값 정리", "\n정의: Av = λv (v ≠ 0)", "\n특성방정식: det(A − λI) = 0", "\n예제 A = [2 1; 1 2]의 고유값은 1과 3"] {
            editor.typeText(line); pause(0.8)
        }
        app.dismissNativeTestKeyboard()
        let done = app.buttons["완료"].firstMatch
        if done.exists && done.isHittable { done.tap() }
        pause(1.5)
        tap(app.buttons["native-open-documents"])
        // iPadOS 27 drops SwiftUI identifiers on menu items; match the title too.
        tap(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "native-dock-preset-columns", "좌우 2분할")).firstMatch)
        pause(2.5)
    }

    @MainActor private func recordLecture() {
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch)
        tap(app.buttons["native-new-tab-recording"]); pause(2)
        type("3주차 강의", into: app.textFields["native-recording-title"])
        app.dismissNativeTestKeyboard()
        tap(app.buttons["native-recording-start"])
        allowSystemAlert()
        // The Mac plays a short Korean lecture through its speaker; the on-device model transcribes it.
        pause(16)
        tap(app.buttons["native-recording-stop"]); pause(3)
    }

    @MainActor private func openBrowser() {
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch)
        tap(app.buttons["native-new-tab-new-browser"]); pause(2)
        let address = app.textFields["native-browser-address"]
        tap(address, wait: 10)
        address.typeText("ko.wikipedia.org/wiki/고윳값과_고유_벡터\n")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        pause(5)
        app.webViews.firstMatch.swipeUp(velocity: .slow); pause(2.5)
    }

    @MainActor private func showAIConsent() {
        tap(app.buttons["native-section-assistant"]); pause(2)
        type("예제 행렬의 고유값을 단계별로 설명해 줘", into: app.textFields["native-chat-input"])
        tap(app.buttons["native-chat-send"])
        XCTAssertTrue(app.buttons["native-ai-consent-cancel"].waitForExistence(timeout: 10), app.debugDescription)
        pause(6)
        tap(app.buttons["native-ai-consent-cancel"]); pause(2.5)
    }

    @MainActor private func showSettings() {
        tap(app.buttons["native-section-settings"]); pause(2.5)
        tap(app.buttons["native-settings-category-ai"]); pause(3)
        tap(app.buttons["native-settings-category-privacy"]); pause(3.5)
        tap(app.buttons["native-settings-category-tabs"]); pause(3)
    }

    // MARK: Helpers

    @MainActor private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }
    @MainActor private func tap(_ element: XCUIElement, wait: TimeInterval = 15) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: wait), .completed, "\(element)\n\(app.debugDescription)")
        element.tap(); pause(1.2)
    }
    @MainActor private func type(_ text: String, into field: XCUIElement) {
        focus(field); field.typeText(text); pause(1)
    }
    /// Quiescence waits are off, so wait for the keyboard focus the tap gives before typing.
    @MainActor private func focus(_ field: XCUIElement, at offset: CGVector = CGVector(dx: 0.5, dy: 0.5)) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "\(field)")
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            field.coordinate(withNormalizedOffset: offset).tap()
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 6) == .completed { break }
        }
        pause(0.8)
    }
    @MainActor private func tool(_ name: String) {
        let item = app.buttons["native-pdf-tool-" + name]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if !item.isSelected { tap(item) }
    }
    @MainActor private func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["허용", "Allow", "확인", "OK"])).firstMatch
        if allow.waitForExistence(timeout: 5) { pause(1.5); allow.tap(); pause(1) }
    }
    /// The visible page: at 100 % the A4 page fills the PDF body's width from its top edge.
    @MainActor private func pageFrame(_ pdf: XCUIElement) -> CGRect {
        let bodyElement = app.otherElements["bandal-native-pdf-body"]
        let body = bodyElement.exists ? bodyElement.frame : pdf.frame
        NSLog("[review] pdf=%@ body=%@", NSCoder.string(for: pdf.frame), NSCoder.string(for: body))
        return CGRect(x: body.minX, y: body.minY, width: body.width, height: body.width * 842 / 595)
    }
    @MainActor private func draw(_ points: [CGPoint], duration: TimeInterval? = nil) {
        guard points.count > 1 else { return }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // The synthesizer takes device (portrait) coordinates; this maps the landscape app's frame point (home button right).
        let height = app.frame.height
        if let failure = ReviewStroke.drawPoints(points.map { NSValue(cgPoint: CGPoint(x: height - $0.y, y: $0.x)) }, duration: duration ?? max(0.18, Double(length) / 260),
                                                 orientation: .landscapeRight) { XCTFail("stroke: \(failure)") }
        pause(0.08)
    }
}
