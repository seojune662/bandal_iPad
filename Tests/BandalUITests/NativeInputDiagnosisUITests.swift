import XCTest

/// Diagnosis runs for the centre pane, not regression tests: each drives one input and prints what the app
/// reports (`[DIAG] …` lines), while the app's own input trace (`--native-input-trace`) records where every touch
/// landed and how each gesture recognizer ended. Read the trace with
/// `xcrun simctl spawn <device> log show --last 5m --predicate 'subsystem == "app.bandal" AND category == "input"'`.
///
/// They assert nothing and some of them leave the app in a floating window, so they only run when asked for:
/// `TEST_RUNNER_BANDAL_INPUT_DIAGNOSIS=1 xcodebuild test -only-testing:BandalUITests/NativeInputDiagnosisUITests/…`.
final class NativeInputDiagnosisUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_INPUT_DIAGNOSIS"] == "1", "Diagnosis runs are opt-in")
    }

    /// R1 and R2: a stroke with the pen as the document opens, then again after choosing another tool and the pen.
    @MainActor func testR1R2StrokeAfterOpenAndAfterReselectingPen() {
        let app = launch(fixturePencil: true)
        openNote("Trace Note", app: app)
        report("opened", app)
        stroke(app, from: .init(dx: 0.35, dy: 0.35), to: .init(dx: 0.6, dy: 0.45))
        sleep(3); report("R1 after first stroke", app)
        tool("highlighter", app: app); sleep(1); tool("pen", app: app); sleep(1)
        report("R2 pen reselected", app)
        stroke(app, from: .init(dx: 0.35, dy: 0.6), to: .init(dx: 0.6, dy: 0.7))
        sleep(3); report("R2 after second stroke", app)
    }

    /// R3: fingers only (no Pencil fixture, so a finger is a finger): one-finger pan, then a two-finger pinch.
    @MainActor func testR3FingerPanAndPinch() {
        let app = launch(fixturePencil: false)
        openNote("Trace Pan", app: app)
        report("opened", app)
        let body = app.otherElements["native-pdf-workspace"]
        body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.7)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(2); report("R3 after one-finger pan up", app)
        body.pinch(withScale: 1.6, velocity: 1.5)
        sleep(2); report("R3 after pinch out", app)
        body.pinch(withScale: 0.6, velocity: -1.5)
        sleep(2); report("R3 after pinch in", app)
    }


    @MainActor private func shot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    /// R8: the same note in two panes side by side: what each pane's palette looks like and whether its tools can be reached.
    @MainActor func testR8SplitPanePalettes() {
        let app = launch(fixturePencil: true)
        openNote("Trace Split", app: app)
        app.openNativeDockLayoutMenu()
        let duplicate = app.buttons["native-duplicate-right"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5)); duplicate.tap(); sleep(3)
        let panes = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-pdf-pane-"))
        print("[DIAG] R8 panes=\(panes.count)")
        for index in 0..<panes.count {
            let pane = panes.element(boundBy: index)
            let row = pane.scrollViews["native-pdf-palette-scroll"], strip = pane.scrollViews["native-pdf-tool-scroll"]
            print("[DIAG] R8 pane\(index) frame=\(pane.frame) row=\(row.exists ? "\(row.frame)" : "none") strip=\(strip.exists ? "\(strip.frame)" : "none")")
            for id in ["native-pdf-pages", "native-pdf-undo", "native-pdf-tool-pen", "native-pdf-tool-highlighter", "native-pdf-tool-eraser", "native-pdf-palette-collapse", "native-pdf-palette-expand"] {
                let item = pane.buttons[id]
                print("[DIAG] R8 pane\(index) \(id): " + (item.exists ? "frame=\(item.frame) enabled=\(item.isEnabled) hittable=\(item.isHittable) selected=\(item.isSelected)" : "missing"))
            }
            let marker = pane.buttons["native-pdf-tool-highlighter"]
            if marker.exists {
                if !marker.isHittable { (strip.exists ? strip : row).slide(toShow: marker) }
                print("[DIAG] R8 pane\(index) highlighter after sliding: hittable=\(marker.isHittable) frame=\(marker.frame)")
                if marker.isHittable { marker.tap(); sleep(1); print("[DIAG] R8 pane\(index) highlighter selected=\(marker.isSelected)") }
            }
        }
        shot("R8 split panes")
        // Real touches at the right pane's controls, whatever the accessibility hit test says.
        if panes.count > 1 {
            let pane = panes.element(boundBy: 1)
            for id in ["native-pdf-pages", "native-pdf-tool-pen", "native-pdf-tool-highlighter", "native-pdf-tool-eraser"] {
                let frame = pane.buttons[id].frame
                tap(app, x: frame.midX, y: frame.midY, label: "R8 pane1 " + id); sleep(1)
                print("[DIAG] R8 pane1 after tapping \(id): highlighterSelected=\(pane.buttons["native-pdf-tool-highlighter"].isSelected) eraserSelected=\(pane.buttons["native-pdf-tool-eraser"].isSelected) thumbnails=\(pane.buttons["native-pdf-thumbnail-1"].exists)")
            }
            // A page tap in each pane, to see both pages take touches.
            for index in 0..<2 { let frame = panes.element(boundBy: index).frame; tap(app, x: frame.midX, y: frame.midY + 100, label: "R8 pane\(index) page") }
        }
    }
    /// R9: a tab dragged out of the strip onto the page. Does the app's window move, and does the drag become a split?
    @MainActor func testR9TabDragAndTheWindow() { tabDrag(extra: []) }
    /// R9c: how deep the band is that iPadOS drags a full-screen window by: the same tab pressed at several heights.
    /// (Measured on 26.5: 32 pt. Leaves the app windowed in between and restores full screen each time.)
    @MainActor func testR9cTopBandDepth() {
        let app = launch(fixturePencil: false)
        openNote("Trace Band", app: app)
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Trace Band")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let body = app.otherElements["native-pdf-workspace"]
        for y in [20.0, 24.0, 28.0, 32.0, 36.0, 44.0] {
            let frame = tab.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: frame.midX, dy: y))
            start.press(forDuration: 1, thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(2)
            let window = app.windows.firstMatch.frame
            print("[DIAG] R9c press at y=\(y) (tab \(frame)): window after \(window) \(window.width < 1370 ? "LEFT FULL SCREEN" : "stayed full screen")")
            ensureFullScreen(app); sleep(1)
        }
    }
    @MainActor private func tabDrag(extra: [String]) {
        let app = launch(fixturePencil: false, extra: extra)
        openNote("Trace Drag A", app: app)
        let create = app.buttons["native-library-create"]
        create.tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Trace Drag B")
        app.buttons["native-new-note-create"].tap(); sleep(4)
        func windows() -> String { (0..<app.windows.count).map { "\(app.windows.element(boundBy: $0).frame)" }.joined(separator: " | ") }
        print("[DIAG] R9 windows before: \(windows())")
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-document-tab-", "Trace Drag A")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let body = app.otherElements["native-pdf-workspace"]
        print("[DIAG] R9 tab frame \(tab.frame) body \(body.frame) panes=\(app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-pdf-pane-")).count)")
        tab.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 1,
            thenDragTo: body.coordinate(withNormalizedOffset: .init(dx: 0.85, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(2)
        print("[DIAG] R9 windows after: \(windows())")
        print("[DIAG] R9 panes after drag=\(app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-pdf-pane-")).count)")
        shot("R9 after tab drag")
        // A tap near the top makes the trace log the window's bounds against the screen's.
        tap(app, x: 200, y: 30, label: "R9 top-left probe")
    }
    /// R10: four mixed tabs in one strip (the tab-sizing test's start): each tab's frame, whether the accessibility
    /// hit test finds it, and where a real tap on it lands.
    @MainActor func testR10MixedTabsHitTesting() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture", "--native-browser-long-title-ui-fixture", "--native-input-trace"]
        app.launch(); ensureFullScreen(app)
        let menu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25)); menu.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Uniform tabs")
        app.buttons["native-create-course"].tap()
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        for action in ["new-browser", "new-note", "chat", "new-whiteboard"] {
            plus.tap()
            let item = app.buttons["native-new-tab-" + action]
            if item.waitForExistence(timeout: 5) { item.tap() } else { print("[DIAG] R10 menu item \(action) missing") }
            sleep(3)
        }
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-")).allElementsBoundByIndex
        print("[DIAG] R10 tabs=\(tabs.count) popovers=\(app.popovers.count)")
        for tab in tabs {
            print("[DIAG] R10 tab '\(tab.label.prefix(24))' frame=\(tab.frame) hittable=\(tab.isHittable) selected=\(tab.isSelected)")
        }
        shot("R10 four tabs")
        // Every element whose frame covers the middle of the second tab, in hierarchy order.
        if tabs.count > 1 {
            let point = CGPoint(x: tabs[1].frame.midX, y: tabs[1].frame.midY)
            for line in app.debugDescription.split(separator: "\n") {
                guard let open = line.range(of: "{{"), let close = line.range(of: "}}", range: open.upperBound..<line.endIndex) else { continue }
                let numbers = line[open.upperBound..<close.lowerBound].replacingOccurrences(of: "}, {", with: ", ").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == 4 else { continue }
                let frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                if frame.contains(point) { print("[DIAG] R10 covers \(point): \(line.trimmingCharacters(in: .whitespaces).prefix(170))") }
            }
        }
        for tab in tabs where tab.frame.width > 0 { tap(app, x: tab.frame.midX, y: tab.frame.midY, label: "R10 tab " + String(tab.label.prefix(12))); sleep(1) }
    }
    /// R6: with the right panel open, single taps across the page column and down it, to find the edges of the
    /// region that does not reach the page; then the same taps with the panel closed.
    @MainActor func testR6MapTheBlockedRegion() {
        let app = launch(fixturePencil: false)
        openNote("Trace Map", app: app)
        let body = app.otherElements["native-pdf-workspace"]
        func sweep(_ label: String) {
            let frame = body.frame
            print("[DIAG] R6 \(label) body frame \(frame)")
            var x = frame.minX + 10
            while x < frame.maxX { tap(app, x: x, y: 520, label: label + "-row520"); x += 30 }
            x = frame.minX + 10
            while x < frame.maxX { tap(app, x: x, y: 900, label: label + "-row900"); x += 90 }
            for y in stride(from: 20.0, through: 1010.0, by: 45.0) { tap(app, x: frame.minX + 40, y: y, label: label + "-colLeft") }
            for y in stride(from: 20.0, through: 1010.0, by: 45.0) { tap(app, x: frame.midX + 60, y: y, label: label + "-colMid") }
        }
        sweep("open")
        let toggle = app.buttons["native-toggle-materials-rail"]
        if toggle.waitForExistence(timeout: 5) { toggle.tap(); sleep(2) }
        sweep("closed")
    }
    @MainActor private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat, label: String) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: x, dy: y)).tap()
        print("[DIAG] tap \(label) x=\(Int(x)) y=\(Int(y))"); usleep(400_000)
    }

    // MARK: Helpers

    @MainActor private func launch(fixturePencil: Bool, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--native-pages-fixture", "--reset-native-ui-testing", "--native-input-trace"]
            + (fixturePencil ? ["--native-pencil-dispatch-fixture"] : []) + extra
        app.launch()
        ensureFullScreen(app)
        return app
    }
    /// A drag from the top edge leaves the app in a floating window, and iPadOS keeps it that way across launches.
    /// A double tap on the window's top edge fills the screen again.
    @MainActor private func ensureFullScreen(_ app: XCUIApplication) {
        let screen = XCUIScreen.main.screenshot().image.size
        for _ in 0..<3 {
            let frame = app.windows.firstMatch.frame
            guard frame.width * frame.height < screen.width * screen.height - 100 else { print("[DIAG] full screen \(frame)"); return }
            print("[DIAG] windowed \(frame) of screen \(screen): double-tapping its top edge")
            app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: frame.midX, dy: frame.minY + 5)).doubleTap(); sleep(3)
        }
        print("[DIAG] still windowed \(app.windows.firstMatch.frame)")
    }
    @MainActor private func openNote(_ title: String, app: XCUIApplication) {
        let menu = app.buttons["native-course-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25), app.debugDescription); menu.tap()
        let course = app.textFields["native-course-name"]
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap(); course.typeText("Trace")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["native-new-note-create"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=0 pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, "the note did not open")
        sleep(2)
    }
    @MainActor private func stroke(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let body = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        print("[DIAG] stroke in \(body.frame) from \(from) to \(to)")
        body.coordinate(withNormalizedOffset: from).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func tool(_ name: String, app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + name]
        guard item.waitForExistence(timeout: 10) else { print("[DIAG] tool \(name) missing"); return }
        print("[DIAG] tool \(name) selected=\(item.isSelected) hittable=\(item.isHittable)")
        if !item.isSelected { item.tap() }
    }
    @MainActor private func report(_ label: String, _ app: XCUIApplication) {
        let ink = app.buttons["native-pdf-drawing-tools"].value as? String ?? "?"
        let body = app.otherElements["bandal-native-pdf-body"].value as? String ?? "?"
        let pen = app.buttons["native-pdf-tool-pen"]
        print("[DIAG] \(label): \(ink) penSelected=\(pen.exists ? String(pen.isSelected) : "?")")
        print("[DIAG] \(label) body: \(body)")
        let attachment = XCTAttachment(string: label + "\n" + ink + "\n" + body); attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
    }
}
