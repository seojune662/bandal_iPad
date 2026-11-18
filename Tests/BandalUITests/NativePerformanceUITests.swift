import XCTest

/// Times what the owner waits for: switching between two full courses and opening their tabs.
/// The app writes the timings (`perf.*`) to its input trace; this test drives the flow and checks that each
/// switch lands on a usable PDF.
final class NativePerformanceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testCourseSwitchLandsOnAUsablePDF() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-perf-fixture", "--native-input-trace"]
        app.launch()
        createCourse("Course A", app: app)
        open(["정리.md", "강의 1.pdf", "강의 2.pdf"], app: app)
        createCourse("Course B", app: app)
        open(["강의 1.pdf", "강의 2.pdf"], app: app)
        for round in 0..<4 {
            for name in ["Course A", "Course B"] {
                let row = courseRow(name, app: app)
                XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
                let started = Date()
                row.tap()
                XCTAssertTrue(waitForUsablePDF(app: app, timeout: 20), "round \(round) \(name): " + app.debugDescription)
                print(String(format: "[PERF_UI] switch round=%d to=%@ seconds=%.2f", round, name, Date().timeIntervalSince(started)))
            }
        }
    }

    /// A browser tab coming back with its course shows its page at once, not "열린 탭이 없습니다" first.
    @MainActor
    func testCourseSwitchBackToABrowserTab() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-perf-fixture", "--native-input-trace", "--native-browser-ui-fixture"]
        app.launch()
        createCourse("Course A", app: app)
        open(["정리.md", "강의 1.pdf"], app: app)
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), app.debugDescription)
        createCourse("Course B", app: app)
        open(["강의 1.pdf"], app: app)
        for round in 0..<3 {
            // No XCUITest waits while the app settles: each one builds the app's accessibility tree on its main
            // thread, which the trace would count as the app's own work.
            courseRow("Course A", app: app).tap(); sleep(3)
            XCTAssertTrue(page.exists && app.buttons["native-browser-back"].exists, "round \(round): " + app.debugDescription)
            courseRow("Course B", app: app).tap(); sleep(3)
            XCTAssertTrue(waitForUsablePDF(app: app, timeout: 20), "round \(round)")
        }
    }

    /// Real sites over the network: set `TEST_RUNNER_BANDAL_LIVE_BROWSER=1`. The app traces each page's start, commit and
    /// finish (`perf.browser.nav.*`) to compare with a bare WKWebView on the same simulator.
    @MainActor
    func testLiveBrowserPageLoads() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_LIVE_BROWSER"] == "1", "Set TEST_RUNNER_BANDAL_LIVE_BROWSER=1 to load real sites.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-perf-fixture", "--native-input-trace"]
        app.launch()
        createCourse("Browsing", app: app)
        open(["정리.md", "강의 1.pdf"], app: app)
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        waitUntilLoaded(app: app)
        for url in Self.liveURLs + Self.liveURLs {
            let address = app.textFields["native-browser-address"].firstMatch
            XCTAssertTrue(address.waitForExistence(timeout: 10)); address.tap()
            address.typeText(url + "\n")
            waitUntilLoaded(app: app)
        }
    }
    static let liveURLs = ["https://en.wikipedia.org/wiki/Entropy", "https://www.naver.com", "https://www.snu.ac.kr", "https://developer.apple.com/documentation/pdfkit"]
    @MainActor private func waitUntilLoaded(app: XCUIApplication) {
        sleep(1)
        let reload = app.buttons["native-browser-reload"].firstMatch
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "새로고침"), object: reload)
        _ = XCTWaiter.wait(for: [idle], timeout: 40)
    }

    @MainActor private func waitForUsablePDF(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let tools = app.buttons["native-pdf-drawing-tools"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", "drawings="), object: tools)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }
    @MainActor private func open(_ names: [String], app: XCUIApplication) {
        for name in names {
            let item = app.buttons["native-material-" + name]
            XCTAssertTrue(item.waitForExistence(timeout: 60), name + " " + app.debugDescription)
            item.tap()
            let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", (name as NSString).deletingPathExtension)).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 20), name + " " + app.debugDescription)
            if name.hasSuffix(".pdf") { XCTAssertTrue(waitForUsablePDF(app: app, timeout: 30), name) }
        }
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        let menu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(courseRow(name, app: app).waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func courseRow(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND label CONTAINS %@", "native-course-", "native-course-expand-", name)).firstMatch
    }
}
