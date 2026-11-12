import XCTest

/// Captures of the first screen and the window chrome, compared by eye with Figma 129:1460, 129:1855 and 257:8827.
/// Each test only drives and attaches; behaviour is asserted in the feature tests.
final class FigmaHomeChromeScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testHomeLight() throws { home("light") }
    @MainActor func testHomeDark() throws { home("dark") }
    @MainActor func testSchoolWithoutLinksLight() throws { schoolWithoutLinks("light") }
    @MainActor func testSchoolWithoutLinksDark() throws { schoolWithoutLinks("dark") }

    @MainActor private func home(_ appearance: String) {
        let app = launch(appearance)
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
        for course in ["디자인 스튜디오", "창업론 실습", "북한학개론"] {
            add.tap()
            let name = app.textFields["native-course-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription); name.tap(); name.typeText(course)
            if course == "디자인 스튜디오" { attach(app, "new course popover \(appearance)") }
            app.buttons["native-create-course"].tap(); sleep(1)
        }
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'native-course-' AND label == '디자인 스튜디오'")).firstMatch.tap(); sleep(1)
        app.buttons["native-university-choose"].tap()
        let search = app.textFields["native-school-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription); search.tap(); search.typeText("SNU")
        let school = app.buttons["native-school-result-snu"]
        XCTAssertTrue(school.waitForExistence(timeout: 5)); school.tap(); sleep(1)
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription)
        create.tap(); sleep(1); attach(app, "add menu \(appearance)")
        app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription); title.tap()
        (title.value as? String).map { title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: $0.count)) }
        title.typeText("3주차 리서치 노트"); app.buttons["만들기"].tap()
        XCTAssertTrue(app.textViews["native-markdown-editor"].waitForExistence(timeout: 15), app.debugDescription)
        attach(app, "document \(appearance)")
        app.buttons["native-close-document"].firstMatch.tap(); sleep(2)
        attach(app, "home \(appearance)")
        app.buttons["native-section-library"].tap(); sleep(1); attach(app, "sidebar collapsed \(appearance)")
        app.buttons["native-section-library"].tap(); sleep(1)
        app.buttons["native-toggle-materials-rail"].tap(); sleep(1); attach(app, "home files closed \(appearance)")
        app.buttons["native-toggle-materials-rail"].tap(); sleep(1)
        app.buttons["native-home-site-add"].tap(); sleep(1); attach(app, "add site \(appearance)")
        app.buttons["native-home-site-add"].tap()
        app.buttons["native-course-add-menu"].press(forDuration: 1); sleep(1); attach(app, "course add long press \(appearance)")
    }

    @MainActor private func schoolWithoutLinks(_ appearance: String) {
        let app = launch(appearance)
        let choose = app.buttons["native-university-choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 25), app.debugDescription); choose.tap()
        let search = app.textFields["native-school-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription); search.tap(); search.typeText("반달대학교")
        let manual = app.buttons["native-school-manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), app.debugDescription); manual.tap()
        let submit = app.buttons["native-school-name-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), app.debugDescription); submit.tap()
        XCTAssertTrue(app.buttons["native-university-find-links"].waitForExistence(timeout: 10), app.debugDescription)
        sleep(1); attach(app, "school without links \(appearance)")
    }

    @MainActor private func launch(_ appearance: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
