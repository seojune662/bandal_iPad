import XCTest

/// Original workspace chrome above the native website, using an isolated
/// library. Public-page appearance and authentication are separate checks.
final class BrowserWorkspaceTests: XCTestCase {
    func testBrowserTouchMenuRemainsAboveNativePageAndFindCanBeOpenedWithoutKeyboard() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        let open = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "웹 탐색")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), app.debugDescription); open.tap()
        let more = app.descendants(matching: .any).matching(identifier: "브라우저 도구 더 보기").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertGreaterThanOrEqual(more.frame.width, 44); XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        more.tap()
        let find = app.buttons["페이지에서 찾기"]
        XCTAssertTrue(find.waitForExistence(timeout: 10)); XCTAssertTrue(find.isHittable)
        let share = app.buttons["페이지 공유"]
        XCTAssertTrue(share.exists); XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.buttons["페이지 확대"].exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Use the requested landscape workspace")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad browser touch menu above native website"
        screenshot.lifetime = .keepAlways; add(screenshot)
        find.tap()
        let input = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "페이지에서 찾기")).allElementsBoundByIndex.first { $0.elementType == .textField || $0.elementType == .searchField }
        XCTAssertNotNil(input, app.debugDescription)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
    }
}
