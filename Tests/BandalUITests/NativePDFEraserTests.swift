import XCTest

/// Actual app, PDFKit body, WK palette/editor, and canonical backend. The
/// existing DEBUG fixture substitutes XCTest fingers for Pencil in the native
/// recognizer, only inside the isolated UI-test library. This is not a physical
/// Pencil, pressure, palm-rejection, or touch-to-photon latency qualification.
final class NativePDFEraserTests: XCTestCase {
    func testHeavyNativePDFEraserSelectionDeletionUndoAndRelaunch() {
        exerciseHeavyEraser()
    }

    func testHeavyNativePDFEraserAfterTwoRecentStrokesDeletesOldInkAndUndoSurvivesRelaunch() {
        exerciseHeavyEraser(recentStrokes: 2)
    }
    func testRetainedGPURecentInkNativeErasureUndoAndRelaunch() {
        exerciseHeavyEraser(recentStrokes: 2, retained: true)
    }
    func testRetainedMixedObjectsRecentInkNativeErasureUndoAndRelaunch() {
        exerciseHeavyEraser(recentStrokes: 2, retained: true, mixed: true)
    }

    private func exerciseHeavyEraser(recentStrokes: Int = 0, retained: Bool = false, mixed: Bool = false) {
        let fixtureCount = mixed ? 204 : 200
        let totalCount = fixtureCount + recentStrokes
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture",
            "--desktop-pdf-fixture", mixed ? "--desktop-pdf-mixed-ink-fixture" : "--desktop-pdf-heavy-ink-fixture",
            "--native-pencil-dispatch-fixture", "--ipad-interaction-diagnostics",
            "-bandal.nativePDF.enabled", "YES"
        ]
        app.launch()
        openSyntheticPDF(app)

        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        let expand = app.buttons["필기 도구 펴기"]
        if expand.exists && expand.isHittable { expand.tap() }
        // WebKit can expose aria-pressed tool buttons as accessibility
        // switches. Match their stable labels without assuming a Button role.
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        let eraser = app.descendants(matching: .any).matching(identifier: "지우개").firstMatch
        let undo = app.buttons["되돌리기"]
        let redo = app.buttons["다시 실행"]
        XCTAssertTrue(pen.waitForExistence(timeout: 15))
        XCTAssertTrue(eraser.waitForExistence(timeout: 15))
        XCTAssertTrue(undo.waitForExistence(timeout: 15))
        XCTAssertTrue(redo.waitForExistence(timeout: 15))

        func metric(_ name: String) -> Double {
            (body.value as? String ?? "").split(separator: " ")
                .first(where: { $0.hasPrefix(name + "=") })
                .flatMap { Double($0.dropFirst(name.count + 1)) } ?? -1
        }
        func selected(_ button: XCUIElement) -> Bool {
            button.isSelected || (button.value as? String) == "1"
        }
        func waitUntil(_ predicate: @escaping () -> Bool, _ message: String) {
            let condition = expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: app)
            let result = XCTWaiter.wait(for: [condition], timeout: 30)
            if result != .completed {
                let state = XCTAttachment(string: message + "\n" + String(describing: body.value) + "\n" + app.debugDescription)
                state.name = "Synthetic heavy eraser failure state"
                state.lifetime = .keepAlways
                add(state)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Synthetic heavy eraser failure geometry"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            // This is a completion timeout, not an input-latency threshold.
            XCTAssertEqual(result, .completed, message + " " + String(describing: body.value))
        }

        waitUntil({ metric("drawings") == Double(fixtureCount) && metric("pending") == 0 && metric("navActive") == 0 &&
            (!mixed || (metric("retainedObjects") == 4 && metric("nonInkObjects") == 3 && metric("retainedActive") == 1)) },
            "The isolated fixture must load all \(fixtureCount) canonical rows and settle its scene")
        pen.tap()
        waitUntil({ selected(pen) && !selected(eraser) }, "The WK palette must visibly select the pen")
        parkPaletteAboveErasingArea(app, body)
        XCTAssertFalse(undo.isEnabled, "Backend fixture seeding must not invent a local undo action")
        XCTAssertFalse(redo.isEnabled)
        let initialAppends = metric("sceneAppend")
        let initialRetainedInstalls = metric("retainedInstalls")
        if retained { XCTAssertGreaterThan(initialRetainedInstalls, 0) }
        for index in 0..<recentStrokes {
            // Use the existing native-dispatch fixture, below the central
            // eraser diagonal (y=.35...65) and away from the parked palette.
            let y = 0.70 + Double(index) * 0.045
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y)).press(forDuration: 0.1,
                thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: y + 0.02)))
            waitUntil({
                metric("drawings") == Double(fixtureCount + 1 + index) && metric("pending") == 0 &&
                    metric("navActive") == 0 &&
                    (retained ? metric("retainedInstalls") > initialRetainedInstalls : metric("sceneAppend") >= initialAppends + Double(index + 1)) && undo.isEnabled
            }, "Each recent native stroke must reach canonical storage and the committed scene before erasing")
        }
        XCTAssertEqual(metric("drawings"), Double(totalCount))
        if mixed {
            XCTAssertEqual(metric("retainedObjects"), 4)
            XCTAssertEqual(metric("nonInkObjects"), 3)
        }
        XCTAssertEqual(undo.isEnabled, recentStrokes > 0, "Only the recent pen contacts may contribute prior undo history")
        let timing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "iPad interaction timing:")).firstMatch
        if timing.exists { print("[HEAVY_INK_TOOL_TIMING_BEFORE] \(timing.label)") }
        let clickTiming = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "iPad tool click timing:")).firstMatch
        XCTAssertTrue(clickTiming.waitForExistence(timeout: 10))
        func clickSequence() -> Int {
            clickTiming.label.split(separator: " ").first { $0.hasPrefix("seq=") }
                .flatMap { Int($0.dropFirst(4)) } ?? -1
        }
        let beforeEraserClick = clickSequence()
        let beforeEraseOperations = metric("nativeEraseOperations")
        XCTAssertGreaterThan(beforeEraserClick, 0)

        // Observe the selection change independently of erasing. This checks
        // the palette's accessibility-selected state, not a native tool ACK or
        // the instant its final CSS transition reaches the display.
        eraser.tap()
        waitUntil({ selected(eraser) && !selected(pen) }, "Tapping the eraser must update the visible WK selection")
        // Aggregate pointer-event to next RAF opportunities, including earlier
        // navigation buttons. This is not isolated eraser or display latency.
        if timing.exists { print("[HEAVY_INK_TOOL_TIMING_AFTER] \(timing.label)") }
        waitUntil({ clickSequence() > beforeEraserClick && clickTiming.label.contains("latest=true") },
            "The timing sample must belong to the new eraser click, not the preceding pen click")
        print("[HEAVY_INK_TOOL_CLICK_TIMING] \(clickTiming.label) (click to RAF DOM observation, not native ACK or physical display)")
        XCTAssertEqual(metric("drawings"), Double(totalCount), "Selecting a tool must not alter saved ink")
        XCTAssertEqual(metric("pending"), 0)
        let selectedPicture = XCTAttachment(screenshot: app.screenshot())
        selectedPicture.name = "Eraser selected before synthetic heavy-ink contact"
        selectedPicture.lifetime = .keepAlways
        add(selectedPicture)

        // The fixture is a dense 8-column, 25-row grid. One central diagonal
        // crosses existing strokes without relying on a private PDFKit page
        // view or fabricating a JS pointer. Do not retry strokes until a hit:
        // a lost first contact or stale native tool must fail this regression.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65)))
        waitUntil({
            let count = metric("drawings")
            return count > Double(recentStrokes) && count < Double(totalCount) && metric("pending") == 0 && metric("navActive") == 0 && undo.isEnabled &&
                (!mixed || (metric("retainedObjects") >= 0 && metric("retainedObjects") < 4 &&
                    metric("nonInkObjects") >= 0 && metric("nonInkObjects") < 3 && metric("retainedActive") == 1))
        }, "The first eraser gesture must delete existing canonical strokes and create a completed undo action")
        let afterErase = metric("drawings")
        if retained {
            XCTAssertGreaterThan(metric("nativeEraseOperations"), beforeEraseOperations, "The contact must commit native targets without relaying Pencil moves to the SVG eraser")
        }
        if mixed {
            // Textbox interior crosses the known central contact. The separate
            // accepted texture count and canonical non-ink count establish a
            // textbox/rect/image deletion, not just modern or legacy ink loss.
            XCTAssertLessThan(metric("retainedObjects"), 4)
            XCTAssertLessThan(metric("nonInkObjects"), 3)
            print("[MIXED_NATIVE_ERASE] retainedObjects=\(metric("retainedObjects")) nonInkObjects=\(metric("nonInkObjects")) retainedActive=\(metric("retainedActive"))")
        }
        XCTAssertTrue(selected(eraser))
        print("[HEAVY_INK_ERASE] drawings=\(afterErase) pending=\(metric("pending"))")

        // pending counts native ink journal work, not the eraser's JS write
        // queue. With no prior strokes, enabled undo also proves delete-history
        // completion. With recent strokes it is already enabled: the production
        // nativePDF.flush wrapper awaits the drawing write queue before undo,
        // so it must undo this deletion, not one of the preceding pen contacts.
        // removeInternal records history after drawings:delete resolves;
        // runHistory awaits restore/create before finishUndo and historyBusy
        // clears. PdfPalette disables redo while busy.
        undo.tap()
        waitUntil({ metric("drawings") == Double(totalCount) && metric("pending") == 0 && metric("navActive") == 0 && redo.isEnabled &&
            (!mixed || (metric("retainedObjects") == 4 && metric("nonInkObjects") == 3 && metric("retainedActive") == 1)) },
            "One undo must durably restore the whole eraser gesture before relaunch")
        XCTAssertEqual(undo.isEnabled, recentStrokes > 0,
            "One undo restores the deletion and preserves the prior pen undo availability")
        print("[HEAVY_INK_ERASE_UNDO] drawings=\(metric("drawings")) pending=\(metric("pending")) redoEnabled=\(redo.isEnabled)")

        app.terminate()
        // Keep the isolated library; neither reset it nor regenerate/import
        // the PDF or its seeded strokes. The second count must come from storage.
        app.launchArguments.removeAll {
            ["--reset-ui-testing", "--desktop-pdf-fixture", "--desktop-pdf-heavy-ink-fixture", "--desktop-pdf-mixed-ink-fixture"].contains($0)
        }
        app.launch()
        if !body.waitForExistence(timeout: 10) { openSyntheticPDF(app) }
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        waitUntil({ metric("drawings") == Double(totalCount) && metric("pending") == 0 && metric("navActive") == 0 &&
            (!mixed || (metric("retainedObjects") == 4 && metric("nonInkObjects") == 3 && metric("retainedActive") == 1)) },
            "All \(totalCount) canonical strokes, including the recent contacts, must survive a process relaunch")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch.exists)
        // Counts cannot establish original drawing IDs, raw sample bits,
        // exact pixels, or physical Pencil tool-button behavior. Those require
        // the separate data/rendering regressions and hardware qualification.
        // retainedObjects counts texture-backed rows (including legacy ink),
        // not successful decoding or pixel correctness of the imported image.
    }

    private func openSyntheticPDF(_ app: XCUIApplication) {
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let materials = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
            XCTAssertTrue(materials.waitForExistence(timeout: 60))
            materials.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 60))
        file.tap()
        let close = app.buttons["자료 닫기"]
        if close.exists && close.isHittable { close.tap() }
    }

    private func parkPaletteAboveErasingArea(_ app: XCUIApplication, _ body: XCUIElement) {
        // Palette position preferences intentionally survive UI-library reset.
        let handle = app.descendants(matching: .any).matching(identifier: "필기 도구 이동").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.07)))
        XCTAssertLessThan(handle.frame.maxY, body.frame.minY + body.frame.height * 0.25,
            "The palette must not intercept the central eraser gesture")
    }
}
