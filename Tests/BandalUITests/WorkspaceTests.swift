import XCTest

final class WorkspaceTests: XCTestCase {
    func testNativeWorkspaceAndSplit() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["새 탭"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["화면 분할"].exists)
        app.buttons["새 탭"].tap(); app.buttons["new-tab-board"].tap()
        XCTAssertTrue(app.staticTexts["한 걸음씩, 차근차근"].waitForExistence(timeout: 10))
        let field = app.textFields["새로운 할 일"]; field.tap(); field.typeText("UI test assignment")
        app.buttons["할 일 추가"].tap()
        XCTAssertTrue(app.staticTexts["UI test assignment"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["설정"].tap()
        XCTAssertTrue(app.staticTexts["AI 연결 · 사용자 API 키"].waitForExistence(timeout: 5))
        app.navigationBars["설정"].buttons["완료"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Bandal iPad workspace"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLocalEditorAndBrowserTabs() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["새 탭"].waitForExistence(timeout: 20))
        app.buttons["새 탭"].tap(); app.buttons["new-tab-note"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        app.buttons["새 탭"].tap()
        let browser = app.buttons["new-tab-browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5)); browser.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
    }
}
