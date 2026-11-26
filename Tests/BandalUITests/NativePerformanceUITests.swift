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

    /// Handwriting and palette taps with synthesized touches only (no XCUITest queries in the measured window), so
    /// every `perf.main.busy` line in the trace is the app's own work. `TEST_RUNNER_INK_WARM=0` opens one PDF only.
    @MainActor
    func testInkAndPaletteResponsiveness() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-perf-fixture", "--native-input-trace", "--native-pencil-dispatch-fixture"]
        app.launch()
        let warm = ProcessInfo.processInfo.environment["INK_WARM"] != "0"
        createCourse("Course A", app: app)
        if warm { open(["강의 2.pdf"], app: app); createCourse("Course B", app: app); open(["강의 2.pdf"], app: app) }
        open(["강의 1.pdf"], app: app)
        let pen = app.buttons["native-pdf-tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 10))
        if !pen.isSelected { pen.tap(); sleep(1) }
        func centre(_ id: String) -> CGPoint? {
            let item = app.buttons[id]; guard item.exists, item.isHittable else { return nil }
            return CGPoint(x: item.frame.midX, y: item.frame.midY)
        }
        // Never a tap on what is already chosen: that opens the tool's options instead of changing anything.
        let swatches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-pdf-quick-color-")).allElementsBoundByIndex.filter { $0.isHittable }
        let colours = swatches.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let chosenColour = swatches.firstIndex { $0.isSelected } ?? 0
        let penPoint = try XCTUnwrap(centre("native-pdf-tool-pen")), highlighter = try XCTUnwrap(centre("native-pdf-tool-highlighter"))
        let widths = (0..<3).compactMap { centre("native-pdf-width-slot-\($0)") }
        let chosenWidth = (0..<3).first { app.buttons["native-pdf-width-slot-\($0)"].isSelected } ?? 0
        let frame = app.otherElements["bandal-native-pdf-body"].firstMatch.frame
        print("[INK_UI] colours=\(colours.count) chosen=\(chosenColour) widths=\(widths.count) chosen=\(chosenWidth) body=\(frame)")
        let height = app.frame.height
        func send(_ points: [CGPoint], duration: TimeInterval) {
            if let failure = ReviewStroke.drawPoints(points.map { NSValue(cgPoint: CGPoint(x: height - $0.y, y: $0.x)) }, duration: duration,
                                                     orientation: .landscapeRight) { XCTFail("stroke: \(failure)") }
        }
        ReviewStroke.skipQuiescenceWaits()
        sleep(3)
        let loop = Int(ProcessInfo.processInfo.environment["INK_LOOP"] ?? "") ?? 0
        print("[INK_UI] loop start \(loop)")
        // Thirty handwriting-like strokes, three lines of ten words (or INK_LOOP strokes for a profiler).
        for index in 0..<(loop > 0 ? loop : 30) {
            let x0 = frame.minX + frame.width * (0.2 + 0.06 * Double(index % 10)), y0 = frame.minY + frame.height * (0.35 + 0.08 * Double((index / 10) % 4))
            let points = (0...36).map { step -> CGPoint in
                let t = Double(step) / 36
                return CGPoint(x: x0 + frame.width * 0.045 * t + 6 * cos(t * 6 * .pi), y: y0 - 10 * sin(t * 6 * .pi))
            }
            send(points, duration: 0.45)
            usleep(180_000)
        }
        print("[INK_UI] loop end")
        if loop > 0 { return }
        sleep(3)
        // Palette: tools, then colours and widths of the pen, each tap left to settle and each one a change.
        var taps = [highlighter, penPoint, highlighter, penPoint]
        if colours.count > 1 {
            let other = colours[(chosenColour + 1) % colours.count], back = colours[chosenColour]
            taps += [other, back, other, back]
        }
        if widths.count == 3 {
            taps += [widths[(chosenWidth + 1) % 3], widths[chosenWidth], widths[(chosenWidth + 2) % 3], widths[chosenWidth]]
        }
        for point in taps { send([point, point], duration: 0.06); usleep(900_000) }
        sleep(2)
        // Strokes right after a colour change, as when writing in a new colour.
        for index in 0..<6 where colours.count > 1 {
            let colour = colours[index % 2 == 0 ? (chosenColour + 1) % colours.count : chosenColour]
            send([colour, colour], duration: 0.06); usleep(120_000)
            let x0 = frame.minX + frame.width * (0.2 + 0.1 * Double(index)), y0 = frame.minY + frame.height * 0.65
            send((0...24).map { CGPoint(x: x0 + Double($0) * 3, y: y0 - 8 * sin(Double($0) / 24 * 4 * .pi)) }, duration: 0.3)
            usleep(300_000)
        }
        sleep(4)
        print("[INK_UI] body=\(app.otherElements["bandal-native-pdf-body"].firstMatch.value ?? "")")
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
