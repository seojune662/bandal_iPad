import XCTest

final class WorkspaceTests: XCTestCase {
    func testActualDesktopWorkspaceAndSettings() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        let settings = app.buttons["설정"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["과목"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "학업 보드 열기").firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["읽고, 기록하고, 연결하는 나만의 학습 공간"].exists)
        attach(app, name: "Original desktop workspace on iPad")
        settings.tap()
        XCTAssertTrue(app.buttons["일반"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["일반"].tap()
        attach(app, name: "Original desktop general settings on iPad")
        app.buttons["화면"].tap()
        attach(app, name: "Original desktop appearance settings on iPad")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
