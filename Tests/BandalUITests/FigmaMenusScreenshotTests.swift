import XCTest

/// Captures of the menus and small popovers, compared by eye with Figma 129:2809 (새 탭), 129:3094 (길게 누르기),
/// 129:3309 (새 과목), 130:4009 (공유), 130:5623 (프로필 · 도움말) and their dark twins.
/// Each test only drives and attaches; behaviour is asserted in the feature tests.
final class FigmaMenusScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testLight() throws { capture("light") }
    @MainActor func testDark() throws { capture("dark") }

    @MainActor private func capture(_ appearance: String) {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-account-fixture", "-native.appearance", appearance]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25), app.debugDescription)
        for course in ["창업론 실습", "북한학개론", "디자인 스튜디오"] {
            addCourse.tap()
            let name = app.textFields["native-course-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription); name.tap(); name.typeText(course)
            if course == "디자인 스튜디오" { sleep(1); attach(app, "new course \(appearance)") }
            app.buttons["native-create-course"].tap(); sleep(1)
        }
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), app.debugDescription); plus.tap()
        let note = app.buttons["native-new-tab-new-whiteboard"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription); note.tap(); app.confirmNewNote(); sleep(4)
        plus.tap(); sleep(1); attach(app, "new tab \(appearance)")
        app.closeBandalPopover()

        let share = app.buttons["native-dock-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), app.debugDescription); share.tap()
        XCTAssertTrue(app.buttons["native-dock-export-pdf"].waitForExistence(timeout: 5), app.debugDescription)
        sleep(1); attach(app, "share \(appearance)")
        app.closeBandalPopover()

        let account = app.buttons["native-section-account"]
        account.tap()
        let help = app.buttons["native-account-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5), app.debugDescription); sleep(1); attach(app, "profile \(appearance)")
        help.tap()
        XCTAssertTrue(app.buttons["native-help-contact"].waitForExistence(timeout: 5), app.debugDescription); sleep(1); attach(app, "profile help \(appearance)")
        app.closeBandalPopover(); app.closeBandalPopover()

        app.buttons["native-close-document"].firstMatch.tap(); sleep(2)
        let card = app.buttons["native-home-continue"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription); card.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["이름 변경"].waitForExistence(timeout: 5), app.debugDescription); sleep(1); attach(app, "long press \(appearance)")
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
