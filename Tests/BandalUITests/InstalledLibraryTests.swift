import XCTest

/// Explicit, local acceptance check for the user's reported welcome.pdf issue.
/// Never runs in the ordinary test suite and never resets or edits documents.
final class InstalledLibraryTests: XCTestCase {
    func testOpenExistingWelcomePDFWithoutResettingLibrary() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_VERIFY_INSTALLED_LIBRARY"] == "1",
                          "Opt-in check for the already installed library")
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "welcome.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), "The existing welcome.pdf must be available")
        file.tap()
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1 페이지,")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "The existing PDF page must render")
        let koreanText = expectation(for: NSPredicate { _, _ in
            page.staticTexts.allElementsBoundByIndex.map(\.label).joined().replacingOccurrences(of: " ", with: "").contains("반달에서시작하는")
        }, evaluatedWith: page)
        wait(for: [koreanText], timeout: 10)
        let ink = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "1 페이지 필기 레이어")).firstMatch
        XCTAssertTrue(ink.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Installed welcome.pdf after update, existing library retained"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
