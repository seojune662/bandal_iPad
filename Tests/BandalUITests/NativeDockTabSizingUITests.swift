import XCTest

final class NativeDockTabSizingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testMixedTabsShrinkUniformlyAndOverflowListSelectsAndClosesHiddenBrowser() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-long-title-ui-fixture"]
        app.launch()
        let courseMenu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(courseMenu.waitForExistence(timeout: 25)); courseMenu.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Uniform tabs")
        app.buttons["native-create-course"].tap()
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        open("new-browser", app: app)
        let browser = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "native-document-tab-", "Native browser fixture")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(browser.label.count, 80)
        let browserID = String(browser.identifier.dropFirst("native-document-tab-".count))
        for action in ["new-note", "chat", "new-whiteboard"] { open(action, app: app) }
        // With room to spare every tab hugs its own title (Figma 155:7541); the long browser title stops at the cap.
        assertTabsFit(app, expectedVisibleCount: 4)
        let roomy = tabs(app)
        XCTAssertGreaterThan(try XCTUnwrap(roomy.max { $0.frame.width < $1.frame.width }).frame.width, try XCTUnwrap(roomy.min { $0.frame.width < $1.frame.width }).frame.width + 20)
        let wider = try XCTUnwrap(roomy.first).frame.width
        XCTAssertLessThanOrEqual(wider, 209)
        for _ in 0..<11 { open("new-note", app: app) }
        let shrunk = tabs(app)
        XCTAssertLessThan(shrunk.count, 16, "Overflow remains in the full tab list, without horizontal scrolling")
        XCTAssertLessThan(try XCTUnwrap(shrunk.first).frame.width, wider)
        XCTAssertTrue(shrunk.contains { $0.isSelected }, "The selected tab remains visible when earlier tabs overflow")
        assertUniformTabs(app)
        capture("Uniform compressed mixed tabs with a long browser title")

        let list = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tabs-")).firstMatch
        list.tap()
        let search = app.textFields["native-dock-tabs-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Native browser fixture")
        let choice = app.buttons["native-dock-tab-list-select-" + browserID]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        let selected = app.buttons["native-document-tab-" + browserID]
        XCTAssertTrue(selected.waitForExistence(timeout: 10)); XCTAssertTrue(selected.isSelected)
        XCTAssertTrue(app.textFields["native-browser-address"].waitForExistence(timeout: 10))
        assertUniformTabs(app)
        list.tap(); XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); app.typeKey("a", modifierFlags: .command); search.typeText("Native browser fixture")
        let close = app.buttons["native-dock-tab-list-close-" + browserID]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(close.frame.width, 44); close.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["native-document-tab-" + browserID].exists)
        capture("Overflow list can close an icon-only browser tab")
    }

    @MainActor private func open(_ action: String, app: XCUIApplication) {
        let previous = tabs(app).first { $0.isSelected }?.identifier
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let item = app.buttons["native-new-tab-" + action]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        if action == "new-whiteboard" { app.confirmNewNote() }
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let selected = self.tabs(app).first(where: { $0.isSelected }) else { return false }
            return selected.identifier != previous
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)
    }
    @MainActor private func tabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-")).allElementsBoundByIndex.filter { $0.frame.intersects(app.frame) }.sorted { $0.frame.minX < $1.frame.minX }
    }
    @MainActor private func assertUniformTabs(_ app: XCUIApplication) { assertTabsFit(app, uniform: true) }
    @MainActor private func assertTabsFit(_ app: XCUIApplication, expectedVisibleCount: Int? = nil, uniform: Bool = false) {
        let values = tabs(app)
        if let expectedVisibleCount { XCTAssertEqual(values.count, expectedVisibleCount) }
        XCTAssertFalse(values.isEmpty)
        guard let first = values.first else { return }
        let strip = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-")).firstMatch
        // Full screen: flush with the top before iPadOS 26; from 26 on, 24 pt under the band the system drags the window by.
        var expected: CGFloat = 52
        if #available(iOS 26, *) { expected = 76 }
        XCTAssertTrue(strip.exists); XCTAssertEqual(strip.frame.height, expected, accuracy: 1, "A strip at the top of a full-screen window keeps clear of the system's drag band, and of nothing else")
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        for tab in values {
            if uniform { XCTAssertEqual(tab.frame.width, first.frame.width, accuracy: 1) }
            XCTAssertGreaterThanOrEqual(tab.frame.minX, strip.frame.minX)
            XCTAssertLessThanOrEqual(tab.frame.maxX, add.frame.minX + 1)
            XCTAssertTrue(tab.isHittable)
        }
        for index in 1..<values.count { XCTAssertLessThanOrEqual(values[index - 1].frame.maxX, values[index].frame.minX + 1) }
        // ＋ and ∨ sit 6 points apart as drawn; the strip gives them its full height to touch.
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
    }
    @MainActor private func capture(_ title: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item)
    }
}
