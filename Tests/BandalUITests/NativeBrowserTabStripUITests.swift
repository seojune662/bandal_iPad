import XCTest

final class NativeBrowserTabStripUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSixWebsiteTabsShrinkTogetherAndListSelectsAndClosesTheRightPage() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-long-title-ui-fixture"]
        app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap(); app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Website tab sizes")
        app.buttons["native-create-course"].tap()
        let dockAdd = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(dockAdd.waitForExistence(timeout: 10)); dockAdd.tap(); app.buttons["native-new-tab-new-browser"].tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Native browser fixture"].waitForExistence(timeout: 15))
        let browserMenu = app.buttons["native-browser-menu"]
        XCTAssertTrue(browserMenu.waitForExistence(timeout: 5)); browserMenu.tap(); app.buttons["새 탭"].firstMatch.tap()
        expectCount(2, app: app)
        let original = try XCTUnwrap(tabs(app).first { $0.label.hasPrefix("Native browser fixture") })
        XCTAssertGreaterThan(original.label.count, 80)
        let originalID = String(original.identifier.dropFirst("native-browser-tab-".count))
        let twoTabWidth = original.frame.width
        for count in 3...6 {
            app.buttons["native-browser-add-tab"].tap()
            expectCount(count, app: app)
        }
        let six = tabs(app), first = try XCTUnwrap(six.first)
        XCTAssertLessThan(first.frame.width, twoTabWidth)
        let survivingIDs = Set(six.map(\.identifier)).subtracting([original.identifier])
        let add = app.buttons["native-browser-add-tab"]
        let list = app.buttons["native-browser-tabs-list"]
        for tab in six {
            XCTAssertEqual(tab.frame.width, first.frame.width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            XCTAssertLessThanOrEqual(tab.frame.maxX, add.frame.minX + 1)
            XCTAssertTrue(tab.isHittable)
        }
        for index in 1..<six.count { XCTAssertLessThanOrEqual(six[index - 1].frame.maxX, six[index].frame.minX + 1) }
        XCTAssertGreaterThanOrEqual(add.frame.width, 44); XCTAssertGreaterThanOrEqual(list.frame.width, 44)
        capture("Six equally sized website tabs including a long page title")

        list.tap()
        let choice = app.buttons["native-browser-tab-list-select-" + originalID]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        let selected = app.buttons["native-browser-tab-" + originalID]
        let activated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [activated], timeout: 10), .completed)
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Native browser fixture"].waitForExistence(timeout: 10))

        list.tap()
        let close = app.buttons["native-browser-tab-list-close-" + originalID]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(close.frame.width, 44); close.tap()
        expectCount(5, app: app)
        XCTAssertFalse(app.buttons["native-browser-tab-" + originalID].exists)
        XCTAssertEqual(Set(tabs(app).map(\.identifier)), survivingIDs, "Closing from the full list must preserve every other website tab")
        capture("Website tab list closes only its chosen page")
    }

    @MainActor private func tabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-browser-tab-")).allElementsBoundByIndex
            .filter { !$0.identifier.hasPrefix("native-browser-tab-list-") && $0.frame.intersects(app.frame) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
    @MainActor private func expectCount(_ count: Int, app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.tabs(app).count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
}
