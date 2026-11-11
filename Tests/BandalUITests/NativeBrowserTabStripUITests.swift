import XCTest

/// Chrome has one tab strip: "새 탭" and target=_blank links in a dock
/// browser tab open new dock tabs, never a nested browser strip.
final class NativeBrowserTabStripUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testNewTabAndBlankLinksOpenDockTabsWithoutNestedStrip() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-popup-ui-fixture"]
        app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Chrome tabs")
        app.buttons["native-create-course"].tap()
        let dockAdd = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(dockAdd.waitForExistence(timeout: 10)); dockAdd.tap(); app.buttons["native-new-tab-new-browser"].tap()
        XCTAssertTrue(app.webViews.firstMatch.links["Open blank tab"].waitForExistence(timeout: 15))
        expectDockTabs(1, app: app)

        app.webViews.firstMatch.links["Open blank tab"].tap()
        expectDockTabs(2, app: app)
        XCTAssertFalse(app.buttons["native-browser-add-tab"].exists, "No nested browser tab strip")
        capture("target=_blank opens a dock tab")

        let browserMenu = app.buttons["native-browser-menu"]
        XCTAssertTrue(browserMenu.waitForExistence(timeout: 5)); browserMenu.tap(); app.buttons["새 탭"].firstMatch.tap()
        expectDockTabs(3, app: app)
        XCTAssertFalse(app.buttons["native-browser-add-tab"].exists, "No nested browser tab strip")

        tapFixtureButton("Open popup", app: app)
        expectDockTabs(4, app: app)
        dockTabs(app)[2].tap() // back to the opener, as the popup took focus
        tapFixtureButton("Close popup", app: app)
        expectDockTabs(3, app: app) // window.close() took the popup's dock tab with it
        capture("A popup that closes itself leaves no tab behind")
    }

    /// Every fixture page has the same layout and hidden tabs keep their web
    /// views, so tap by coordinate: it lands on the visible page's button.
    @MainActor private func tapFixtureButton(_ label: String, app: XCUIApplication) {
        let button = app.webViews.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func dockTabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-")).allElementsBoundByIndex
            .filter { $0.frame.intersects(app.frame) }.sorted { $0.frame.minX < $1.frame.minX }
    }
    @MainActor private func expectDockTabs(_ count: Int, app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.dockTabs(app).count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
}
