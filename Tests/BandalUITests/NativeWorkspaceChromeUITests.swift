import XCTest

/// Panes side by side and the window buttons over them: which pane 공유 acts on, what the buttons cover with the
/// tabs and tools hidden, the scrolling tab strip and the page icons of web tabs.
final class NativeWorkspaceChromeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The owner's report: with the left pane chosen, 공유 at the top right offered the right pane's tab, because
    /// pressing it chose the pane under it. It acts on the pane chosen before it now, either way round.
    @MainActor func testShareActsOnThePaneChosenBeforeIt() throws {
        let app = launch()
        createCourse("Share Panes", app: app)
        setInspector(open: false, app: app)
        openFromHome("Left Ink", app: app)
        openNote("Right Ink", app: app)
        splitRight(tab("Right Ink", app: app), app: app)
        let left = tab("Left Ink", app: app), right = tab("Right Ink", app: app)
        XCTAssertLessThan(left.frame.midX, right.frame.midX)
        let controls = element("native-workspace-controls", app: app)
        XCTAssertGreaterThan(controls.frame.minX, right.frame.minX, "The buttons sit over the right pane's strip")

        for (chosen, title) in [(left, "Left Ink"), (right, "Right Ink"), (left, "Left Ink")] {
            chosen.tap()
            share(expecting: title, app: app)
            // 공유 again closes it, and once more opens it on the same tab. (A tap elsewhere would close it too, but
            // this popover lets that tap through to what is under it: on the other pane, it chooses that pane.)
            closeShare(app)
            share(expecting: title, app: app)
            closeShare(app)
        }
        capture(app, "Share target follows the chosen pane")
    }

    /// The owner's screen: a web page on the left, a handwritten note on the right, and 탭·일반 도구 숨김. The note's
    /// palette rose into the top row and lay under the window buttons. In every mode and layout, and upright too, the
    /// palette keeps clear of them.
    @MainActor func testPaletteKeepsClearOfTheWindowButtonsInEveryModeAndLayout() throws {
        let app = launch(["--native-browser-ui-fixture"])
        createCourse("Hidden Chrome", app: app)
        setInspector(open: false, app: app)
        openFromHome("Right Ink", app: app)
        open("new-browser", app: app)
        let browser = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (label CONTAINS %@)", "native-document-tab-", "Right Ink")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 15))
        browser.press(forDuration: 1)
        let left = app.buttons["native-dock-move-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 5), app.debugDescription); left.tap()
        wait(app, "Browser on the left, note on the right") { self.strips(app).count == 2 && browser.frame.midX < self.tab("Right Ink", app: app).frame.midX }
        tab("Right Ink", app: app).tap()

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            wait(app, "Rotated") { orientation == .portrait ? app.frame.height > app.frame.width : app.frame.width > app.frame.height }
            // Side by side, then one pane, then stacked (the note on top, under the buttons).
            for layout in ["columns", "single", "rows"] {
                if layout != "columns" { applyLayout(layout, app: app) }
                for mode in ["탭만 숨김", "탭·일반 도구 숨김"] {
                    changeMode(mode, app: app)
                    assertPaletteClearsControls(app, "\(orientation.rawValue) \(layout) \(mode)")
                    if layout == "columns" && mode == "탭·일반 도구 숨김" { capture(app, "Owner's screen: browser left, note right, everything hidden (\(orientation == .portrait ? "portrait" : "landscape"))") }
                }
                changeMode("모두 표시", app: app)
                assertPaletteClearsControls(app, "\(orientation.rawValue) \(layout) all")
            }
            applyLayout("columns", app: app)
        }
    }

    /// Twenty tabs: every one keeps its ✕ and its icon, none is hidden, the strip scrolls and the chosen tab stays in view.
    @MainActor func testTwentyTabsKeepTheirCloseButtonsAndTheStripScrolls() throws {
        let app = launch()
        createCourse("Twenty Tabs", app: app)
        setInspector(open: true, app: app)
        for _ in 0..<20 { open("new-note", app: app) }
        let all = documentTabs(app)
        XCTAssertEqual(all.count, 20, "No tab is left out of the strip")
        let scroller = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-scroll-")).firstMatch
        XCTAssertTrue(scroller.exists, app.debugDescription)
        let viewport = scroller.frame
        for tab in all {
            let id = String(tab.identifier.dropFirst("native-document-tab-".count))
            let close = tab.isSelected ? app.buttons["native-close-document"] : app.buttons["native-close-tab-" + id]
            XCTAssertTrue(close.exists, "Every tab has its ✕: " + tab.label)
            XCTAssertGreaterThanOrEqual(close.frame.width, 44); XCTAssertGreaterThanOrEqual(close.frame.height, 44)
            XCTAssertGreaterThanOrEqual(tab.frame.width + close.frame.width, 76 - 0.5, "Icon and ✕ at the least")
        }
        let selected = try XCTUnwrap(all.first { $0.isSelected })
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(selected.frame), "The chosen (newest) tab is in view")
        XCTAssertFalse(viewport.intersects(all[0].frame), "The first tab is scrolled out of sight")
        capture(app, "Twenty tabs: icon and ✕ each, scrolled to the newest")

        // Back to the start by sliding the strip; the first tab is in view and takes a tap.
        for _ in 0..<6 where !viewport.insetBy(dx: -1, dy: -1).contains(all[0].frame) { scroller.swipeRight() }
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(documentTabs(app)[0].frame), "Sliding the strip brings the first tab into view")
        let first = documentTabs(app)[0]
        first.tap()
        wait(app, "The first tab is chosen") { first.isSelected }
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(first.frame))
        capture(app, "Twenty tabs: slid back and the first one chosen")

        // Choosing a tab from the list scrolls the strip to it. (The open list hides the strip from the accessibility tree.)
        let lastTab = documentTabs(app)[19], lastID = String(lastTab.identifier.dropFirst("native-document-tab-".count)), lastTitle = lastTab.label
        let last = app.buttons["native-document-tab-" + lastID]
        let list = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tabs-")).firstMatch
        list.tap()
        let search = app.textFields["native-dock-tabs-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(lastTitle)
        let row = app.buttons["native-dock-tab-list-select-" + lastID]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription); row.tap()
        wait(app, "The last tab is chosen and in view") { last.isSelected && viewport.insetBy(dx: -1, dy: -1).contains(last.frame) }

        // A tab's ✕ closes that tab, chosen or not.
        let other = documentTabs(app)[18], otherID = String(other.identifier.dropFirst("native-document-tab-".count))
        app.buttons["native-close-tab-" + otherID].tap()
        wait(app, "Nineteen tabs left") { self.documentTabs(app).count == 19 }
        XCTAssertTrue(last.isSelected, "Closing another tab leaves the chosen one chosen")
    }

    /// A web tab shows its page's own icon instead of the globe, and still does straight after the app restarts,
    /// before the page is loaded again.
    @MainActor func testWebTabShowsItsPagesIconAndKeepsItAfterARestart() throws {
        let app = launch(["--native-browser-ui-fixture", "--native-chrome-favicon-fixture"])
        createCourse("Favicons", app: app)
        open("new-browser", app: app)
        let browser = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-document-tab-", "Favicon fixture")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 20), app.debugDescription)
        wait(app, "The page's icon replaces the globe") { browser.value as? String == "favicon" }
        let id = browser.identifier
        open("new-note", app: app)
        XCTAssertEqual(app.buttons[id].value as? String, "favicon", "Still shown when the tab is not the chosen one")
        capture(app, "Web tab with its page icon")

        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["--native-ui-testing", "--native-browser-ui-fixture", "--native-chrome-favicon-fixture", "-native.appearance", "dark"]
        again.launch()
        let restored = again.buttons[id]
        XCTAssertTrue(restored.waitForExistence(timeout: 25), again.debugDescription)
        XCTAssertFalse(restored.isSelected, "The web tab is in the background, its page not loaded again")
        wait(again, "The icon from the cache, at once") { restored.value as? String == "favicon" }
        capture(again, "Web tab icon after a restart (dark)")
    }

    // MARK: Helpers

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", "light", "--native-input-trace"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-section-library"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        if !app.buttons["native-course-add-menu"].isHittable { app.buttons["native-section-library"].tap() }
        let menu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch.waitForExistence(timeout: 15))
    }
    @MainActor private func setInspector(open: Bool, app: XCUIApplication) {
        let toggle = app.buttons["native-toggle-materials-rail"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let expected = open ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기"
        if toggle.label != expected { toggle.tap() }
        wait(app, "Inspector state") { toggle.label == expected }
    }
    @MainActor private func openFromHome(_ title: String, app: XCUIApplication) {
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote(title: title)
        XCTAssertTrue(tab(title, app: app).waitForExistence(timeout: 20), app.debugDescription)
    }
    @MainActor private func openNote(_ title: String, app: XCUIApplication) {
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap()
        let item = app.buttons["native-new-tab-new-whiteboard"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap(); app.confirmNewNote(title: title)
        XCTAssertTrue(tab(title, app: app).waitForExistence(timeout: 20), app.debugDescription)
    }
    @MainActor private func open(_ action: String, app: XCUIApplication) {
        let previous = documentTabs(app).first { $0.isSelected }?.identifier, count = documentTabs(app).count
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap()
        let item = app.buttons["native-new-tab-" + action]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        wait(app, "A new tab opened and is chosen") {
            self.documentTabs(app).count == count + 1 && self.documentTabs(app).first { $0.isSelected }?.identifier != previous
        }
    }
    @MainActor private func splitRight(_ tab: XCUIElement, app: XCUIApplication) {
        tab.press(forDuration: 1)
        let split = app.buttons["native-tab-split-right"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), app.debugDescription); split.tap()
        wait(app, "Two panes") { self.strips(app).count == 2 }
    }
    @MainActor private func applyLayout(_ preset: String, app: XCUIApplication) {
        changeMode("모두 표시", app: app)
        if preset == "single" {
            app.openNativeDockLayoutMenu()
            let merge = app.buttons["native-dock-merge-all"]
            XCTAssertTrue(merge.waitForExistence(timeout: 5), app.debugDescription); merge.tap()
            wait(app, "One pane") { self.strips(app).count == 1 }
            tab("Right Ink", app: app).tap()
            return
        }
        app.openNativeDockLayoutMenu()
        let item = app.buttons["native-dock-preset-" + preset]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
        wait(app, "Two panes") { self.strips(app).count == 2 }
        tab("Right Ink", app: app).tap()
    }
    @MainActor private func changeMode(_ title: String, app: XCUIApplication) {
        let menu = app.buttons["native-workspace-chrome-menu"]
        wait(app, "Mode menu ready") { menu.exists && menu.isEnabled && menu.isHittable }
        menu.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription); choice.tap()
        XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
    }
    /// Nothing of the PDF's palette, and no visible note toolbar, lies under the window buttons.
    @MainActor private func assertPaletteClearsControls(_ app: XCUIApplication, _ label: String) {
        let controls = element("native-workspace-controls", app: app).frame
        let palette = element("native-pdf-palette", app: app)
        let pen = app.buttons["native-pdf-tool-pen"]
        wait(app, "The palette shows: " + label) { pen.exists && pen.isHittable }
        if palette.exists { XCTAssertFalse(palette.frame.intersects(controls), "Palette \(palette.frame) under the buttons \(controls): " + label) }
        for id in ["native-pdf-tool-pen", "native-pdf-palette-collapse", "native-pdf-palette-expand", "native-pdf-pages"] where app.buttons[id].exists {
            XCTAssertFalse(app.buttons[id].frame.intersects(controls), id + " under the buttons: " + label)
        }
        // The web tab's address row, when it shows, ends left of them too.
        let address = app.textFields["native-browser-address"]
        if address.exists, address.isHittable { XCTAssertFalse(address.frame.intersects(controls), "Address row under the buttons: " + label) }
    }
    @MainActor private func share(expecting title: String, app: XCUIApplication) {
        let button = app.buttons["native-dock-share"].firstMatch
        wait(app, "공유 ready") { button.exists && button.isEnabled && button.isHittable }
        button.tap()
        let target = element("native-dock-share-target", app: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        // The popover's first row names the tab it acts on.
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "native-dock-share-target", title)).firstMatch
        XCTAssertTrue(named.exists, "공유 names \(title): " + app.debugDescription)
    }
    @MainActor private func closeShare(_ app: XCUIApplication) {
        let target = element("native-dock-share-target", app: app)
        guard target.exists else { return }
        app.buttons["native-dock-share"].firstMatch.tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5), app.debugDescription)
    }
    @MainActor private func tab(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "native-document-tab-", title)).firstMatch
    }
    @MainActor private func documentTabs(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-")).allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }
    @MainActor private func strips(_ app: XCUIApplication) -> XCUIElementQuery {
        app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-"))
    }
    @MainActor private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func wait(_ app: XCUIApplication, _ message: String, timeout: TimeInterval = 20, condition: @escaping () -> Bool) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: timeout), .completed, message + "\n" + app.debugDescription)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
