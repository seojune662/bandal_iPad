import XCTest

/// Exercises responsive panels against an actual native PDF in an isolated library.
final class IPadVisualDesignTests: XCTestCase {
    private func target(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: label).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ label: String) {
        let item = target(app, label)
        XCTAssertTrue(item.waitForExistence(timeout: 20), "Missing \(label)\n\(app.debugDescription)")
        XCTAssertTrue(item.isHittable, "Unreachable \(label)\n\(app.debugDescription)")
        item.tap()
    }

    private func wait(_ app: XCUIApplication, _ description: String, until condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: app)
        ready.expectationDescription = description
        wait(for: [ready], timeout: 20)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // App-frame cropping can lag rotation in XCTest. Capture the screen so
        // evidence includes the complete landscape/portrait presentation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDualSidebarsRestoreAcrossRotationAndShareRightSideWithAI() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        XCTAssertTrue(target(app, "내 공간 열기").waitForExistence(timeout: 30))
        // This acceptance scenario intentionally requires a landscape 13-inch iPad.
        guard app.frame.width >= 1216 else { throw XCTSkip("Dual-docked panels need 1216 points; use a 13-inch iPad simulator") }
        tap(app, "자료 사이드바 펼치기")
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 20)); file.tap()
        tap(app, "내 공간 열기")
        let settings = target(app, "설정"), materialsClose = target(app, "자료 닫기")
        let navigationClose = target(app, "내 공간 닫기"), navigationOpen = target(app, "내 공간 열기")
        wait(app, "Both independent sidebars are usable") {
            navigationClose.isHittable && settings.isHittable && materialsClose.isHittable
        }
        let body = target(app, "bandal-native-pdf-body")
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        XCTAssertGreaterThanOrEqual(body.frame.width, 560)
        capture(app, "Redesign - both sidebars with native PDF")

        // Promote materials before shrinking, so they retain priority.
        tap(app, "자료 닫기")
        tap(app, "자료 사이드바 펼치기")
        XCUIDevice.shared.orientation = .portrait
        wait(app, "Narrow window suspends navigation and retains materials") {
            // The 56-point icon rail keeps Settings available independently
            // of the 280-point navigation body that is suspended here.
            !navigationClose.exists && navigationOpen.isHittable && materialsClose.isHittable && settings.isHittable
        }
        XCTAssertGreaterThanOrEqual(body.frame.width, 560)
        capture(app, "Redesign - portrait material panel")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app, "Growing the window restores requested panels") {
            navigationClose.isHittable && settings.isHittable && materialsClose.isHittable
        }

        tap(app, "현재 문서 AI 열기")
        // WKWebView does not consistently expose a complementary landmark as
        // an XCUIElement. Its visible pin control verifies the actual surface.
        let assistant = target(app, "AI 고정 해제")
        wait(app, "Document AI replaces materials while navigation stays open") {
            assistant.isHittable && !materialsClose.exists && navigationClose.isHittable && settings.isHittable
        }
        XCTAssertTrue(body.exists)
        XCTAssertGreaterThanOrEqual(body.frame.width, 560)
        capture(app, "Redesign - document AI beside PDF and navigation")
        tap(app, "자료 사이드바 펼치기")
        wait(app, "Returning to materials releases the assistant surface") { materialsClose.isHittable && !assistant.exists }
        tap(app, "내 공간 닫기")
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app, "An explicitly closed panel stays closed") {
            navigationOpen.isHittable && !navigationClose.exists && settings.isHittable
        }
        XCTAssertFalse(target(app, "작업 오류").exists)
        XCTAssertFalse(target(app, "시작 오류").exists)
    }
}
