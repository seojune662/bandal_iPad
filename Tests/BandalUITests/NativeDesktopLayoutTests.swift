import XCTest

/// Exercises the real native desktop-shaped chrome and linked editing, not a web mock.
final class NativeDesktopLayoutTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testDesktopRailsTabsLinkedNoteAndCompactLayout() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 20)); addCourse.tap(); app.buttons["native-new-course"].tap()
        let courseName = app.textFields["native-course-name"]; XCTAssertTrue(courseName.waitForExistence(timeout: 5))
        courseName.tap(); courseName.typeText("Native desktop layout"); app.buttons["native-create-course"].tap()
        let add = app.buttons["native-library-create"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]; XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Desktop layout"); app.buttons["native-new-note-create"].tap()
        let pageNote = app.buttons["native-pdf-page-note"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: pageNote)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        XCTAssertGreaterThanOrEqual(pageNote.frame.width, 44, "Page-note action must have a full touch target")
        let pdf = app.otherElements["native-pdf-workspace"]
        XCTAssertLessThan(addCourse.frame.maxX, pdf.frame.minX)
        XCTAssertGreaterThan(add.frame.minX, pdf.frame.maxX)
        XCTAssertTrue(app.buttons["native-close-document"].exists)
        pageNote.tap()
        let note = app.textViews["native-markdown-editor"]
        XCTAssertTrue(note.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertLessThan(pdf.frame.midX, note.frame.midX)
        note.tap(); note.typeText("Linked text keeps every line.\nSecond line survives restart.")
        XCTAssertTrue((note.value as? String ?? "").contains("Second line survives restart."))
        XCTAssertFalse((note.value as? String ?? "").contains("bandal:pdf-page-note"))
        XCTAssertEqual(app.webViews.count, 0)
        if app.buttons["완료"].firstMatch.exists { app.buttons["완료"].firstMatch.tap() }
        capture("Native desktop PDF and linked note")
        XCUIDevice.shared.orientation = .portrait
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: addCourse)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 10), .completed)
        capture("Native compact workspace")
        XCTAssertTrue(app.buttons["native-toggle-materials"].exists)
        app.buttons["native-course-picker"].tap()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 5))
        capture("Native compact course drawer")
        app.buttons["native-course-picker"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(note.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue((note.value as? String ?? "").contains("Second line survives restart."))
        app.buttons["native-section-settings"].tap()
        XCTAssertTrue(app.buttons["native-settings-category-appearance"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["native-course-add-menu"].exists, "Settings replaces the course sidebar as it does on desktop")
        capture("Native desktop settings")
        let dark = app.buttons["native-settings-theme-dark"]
        dark.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: dark)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        capture("Native desktop dark settings")
    }
    @MainActor private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
