import XCTest

final class WorkspaceTests: XCTestCase {
    func testActualDesktopWorkspaceAndSettings() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        let navigation = app.buttons["내 공간 열기"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 30), app.debugDescription)
        // Starter documents may already occupy the workspace. Navigation and
        // settings must work without an empty-tab welcome screen.
        XCTAssertTrue(app.buttons["새 탭 열기"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(navigation.frame.width, 44)
        XCTAssertGreaterThanOrEqual(navigation.frame.height, 44)
        XCTAssertFalse(app.buttons["설정"].exists, "Navigation starts closed at launch")
        XCTAssertFalse(runtimeFailure(app).exists, app.debugDescription)
        attach(app, name: "Document-first iPad workspace")
        navigation.tap()
        let settings = app.buttons["설정"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["과목"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "학업 보드 열기").firstMatch.exists, app.debugDescription)
        attach(app, name: "iPad workspace navigation sheet")
        settings.tap()
        XCTAssertTrue(app.buttons["일반"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["일반"].tap()
        attach(app, name: "iPad general settings")
        let back = app.buttons["설정 목록으로"]
        if back.exists && back.isHittable { back.tap() }
        app.buttons["화면"].tap()
        XCTAssertFalse(runtimeFailure(app).exists, app.debugDescription)
        attach(app, name: "iPad appearance settings")
    }

    private func runtimeFailure(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier IN %@ OR label IN %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            ["bandal-operation-notice", "bandal-native-diagnostic"], ["작업 오류", "시작 오류"],
            "반달 실행 연결을 확인해 주세요.", "반달 화면을 열지 못했어요", "작업을 완료하지 못했어요")).firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
