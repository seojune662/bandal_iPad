import XCTest

final class NativePDFNavigationTests: XCTestCase {
    func testFingerNavigationAcrossTwoHundredSavedStrokesKeepsInkAndZoom() {
        exerciseNavigation(retained: false)
    }

    func testRetainedGPUFingerNavigationAcrossTwoHundredSavedStrokes() {
        exerciseNavigation(retained: true)
    }

    private func exerciseNavigation(retained: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture",
            "--desktop-pdf-fixture", "--desktop-pdf-heavy-ink-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let materials = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
            XCTAssertTrue(materials.waitForExistence(timeout: 60)); materials.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 60)); file.tap()
        let closeMaterials = app.buttons["자료 닫기"]
        if closeMaterials.exists && closeMaterials.isHittable { closeMaterials.tap() }
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 15)); pen.tap()
        let paletteHandle = app.descendants(matching: .any).matching(identifier: "필기 도구 이동").firstMatch
        XCTAssertTrue(paletteHandle.waitForExistence(timeout: 10))
        paletteHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.07)))
        XCTAssertLessThan(paletteHandle.frame.maxY, body.frame.minY + body.frame.height * 0.25)
        func metric(_ name: String) -> Double {
            (body.value as? String ?? "").split(separator: " ").first { $0.hasPrefix(name + "=") }
                .flatMap { Double($0.dropFirst(name.count + 1)) } ?? -1
        }
        func waitUntil(_ predicate: @escaping () -> Bool, _ message: String) {
            let condition = expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: app)
            XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 15), .completed, message + " " + String(describing: body.value))
        }
        waitUntil({ metric("drawings") == 200 && metric("pending") == 0 }, "Fixture must load all200 canonical strokes")
        waitUntil({ metric("navActive") == 0 }, "Initial ink image must settle")
        let initialZoom = metric("zoom")
        let initialRefreshes = metric("navRefresh")
        let initialInstalls = metric("retainedInstalls")
        let initialBuilds = metric("retainedMeshBuilds")
        if retained {
            XCTAssertEqual(metric("retainedActive"), 1)
            XCTAssertEqual(metric("countMesh"), 200)
            XCTAssertGreaterThan(initialInstalls, 0)
        }
        XCTAssertGreaterThan(initialZoom, 0)
        let beforeFirstPan = metric("scrollY")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78)).press(forDuration: 0.05,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)))
        waitUntil({ abs(metric("scrollY") - beforeFirstPan) > 20 }, "A finger must scroll before zooming")
        waitUntil({ metric("navActive") == 0 }, "Initial finger pan must settle")
        print("[HEAVY_INK_FIRST_PAN] \(body.value ?? "")")
        body.pinch(withScale: 1.7, velocity: 2)
        waitUntil({ metric("zoom") > initialZoom * 1.15 }, "Native pinch must zoom the actual PDF")
        let enlargedZoom = metric("zoom")
        let originalPage = metric("page")
        let initialScrollY = metric("scrollY")
        // These are real fingers, not the Pencil-dispatch test substitution.
        for _ in 0..<3 {
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78)).press(forDuration: 0.05,
                thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3)))
        }
        waitUntil({ abs(metric("zoom") - enlargedZoom) < 0.03 }, "Scrolling must retain zoom")
        waitUntil({ metric("navActive") == 0 }, "Asynchronous ink image must settle after scrolling")
        XCTAssertGreaterThan(abs(metric("scrollY") - initialScrollY), 20, "Finger pan must actually move the document")
        XCTAssertEqual(metric("page"), originalPage)
        XCTAssertEqual(metric("drawings"), 200)
        XCTAssertEqual(metric("pending"), 0)
        let lowerPage = XCTAttachment(screenshot: app.screenshot())
        lowerPage.name = "Heavy ink lower page after real finger pan"; lowerPage.lifetime = .keepAlways; add(lowerPage)
        body.pinch(withScale: 0.65, velocity: -2)
        waitUntil({ metric("zoom") < enlargedZoom * 0.9 }, "Native pinch must zoom out after scrolling")
        waitUntil({ metric("navActive") == 0 }, "Asynchronous ink image must settle after pinch")
        XCTAssertGreaterThan(metric("navRefresh"), initialRefreshes)
        if retained {
            XCTAssertEqual(metric("retainedActive"), 1)
            XCTAssertGreaterThan(metric("retainedInstalls"), initialInstalls)
            XCTAssertEqual(metric("retainedMeshBuilds"), initialBuilds, "Pan and zoom must reuse immutable GPU meshes")
            XCTAssertEqual(metric("navRenders"), 0, "Retained ink must not return to the CPU navigation raster")
        } else {
            XCTAssertGreaterThan(metric("navRenders"), 0)
        }
        XCTAssertLessThan(metric("navMaxms"), 50, "Viewport updates must not replay200 strokes on the main thread")
        XCTAssertEqual(metric("drawings"), 200)
        XCTAssertGreaterThanOrEqual(metric("pinchFallbacks"), 0)
        if metric("pinchFallbacks") > 0 {
            XCTAssertGreaterThan(metric("pinchAnchorChecks"), 0, "At least one zoom must exercise an unclamped page anchor")
            XCTAssertLessThan(metric("pinchAnchorError"), 1, "Zoom must retain the page point under the fingers")
        }
        print("[HEAVY_INK_NAVIGATION] \(body.value ?? "")")
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Heavy ink after pan and zoom out"; restored.lifetime = .keepAlways; add(restored)
        let fullScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fullScreen.name = "Full display after heavy ink navigation"; fullScreen.lifetime = .keepAlways; add(fullScreen)
        print("[HEAVY_INK_WINDOW] app=\(app.frame) body=\(body.frame) orientation=\(XCUIDevice.shared.orientation.rawValue)")
        app.terminate()
        app.launchArguments.removeAll { ["--reset-ui-testing", "--desktop-pdf-fixture", "--desktop-pdf-heavy-ink-fixture"].contains($0) }
        app.launch()
        if !body.waitForExistence(timeout: 10) {
            XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        }
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        waitUntil({ metric("drawings") == 200 && metric("pending") == 0 }, "Navigation must not alter saved ink")
    }
}
