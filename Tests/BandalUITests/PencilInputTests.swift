import XCTest

final class PencilInputTests: XCTestCase {
    func testRealFingerDrawingGestureDoesNotRecurseInCanvasDelegate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["새 탭"].waitForExistence(timeout: 30))
        app.buttons["새 탭"].tap()
        app.buttons["new-tab-whiteboard"].tap()
        XCTAssertTrue(app.buttons["보드 전체 보기"].waitForExistence(timeout: 10))
        if app.buttons["크게 보기"].firstMatch.exists { app.buttons["크게 보기"].firstMatch.tap() }
        let canvas = app.descendants(matching: .any).matching(identifier: "bandal-ink-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.buttons["필기 설정"].firstMatch.tap()
        let fingerToggle = app.descendants(matching: .any).matching(identifier: "손가락으로 필기").firstMatch
        XCTAssertTrue(fingerToggle.waitForExistence(timeout: 5))
        fingerToggle.tap()
        // SwiftUI Menu toggles may keep their popover open. Dismiss it outside
        // the paper so a subsequent drag cannot be consumed by the menu.
        app.buttons["보드 전체 보기"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.contains("손가락 필기") == true)
        // A real touch sequence exercises PencilKit's internal drawing event
        // forwarding, which programmatic PKDrawing assignment never reaches.
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        let hasStroke = NSPredicate { _, _ in
            guard let value = canvas.value as? String, let count = Int(value.components(separatedBy: "개")[0]) else { return false }
            return count > 0
        }
        let drew = expectation(for: hasStroke, evaluatedWith: canvas)
        wait(for: [drew], timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["보드 전체 보기"].waitForExistence(timeout: 5))
        app.buttons["필기 실행 취소"].firstMatch.tap()
        let undone = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "0개의 획"), evaluatedWith: canvas)
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Whiteboard after actual PencilKit input"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
