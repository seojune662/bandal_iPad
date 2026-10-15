import XCTest

/// Tests the actual native body inside the original desktop workspace. XCTest
/// synthesizes fingers; these checks make no claim about physical Pencil feel.
final class NativePDFWorkspaceTests: XCTestCase {
    func testTwentyConsecutiveStrokesKeepTheCommittedPrefixWithoutGrowingRedrawWork() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--native-pencil-dispatch-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let materials = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
            XCTAssertTrue(materials.waitForExistence(timeout: 30)); materials.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        let closeMaterials = app.buttons["자료 닫기"]
        if closeMaterials.exists && closeMaterials.isHittable { closeMaterials.tap() }
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 15)); pen.tap()
        parkPaletteAboveWritingArea(app, body)
        func metric(_ name: String) -> Double {
            (body.value as? String ?? "").split(separator: " ").first(where: { $0.hasPrefix(name + "=") })
                .flatMap { Double($0.dropFirst(name.count + 1)) } ?? -1
        }
        var firstFullRenders = -1.0
        for index in 0..<20 {
            let x = 0.3 + Double(index / 8) * 0.12, y = 0.3 + Double(index % 8) * 0.045
            body.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).press(forDuration: 0.1,
                thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: x + 0.08, dy: y + 0.02)))
            let saved = expectation(for: NSPredicate { _, _ in
                let value = body.value as? String ?? ""
                return value.contains("drawings=\(index + 1) ") && value.contains("pending=0") && metric("sceneAppend") >= Double(index + 1)
            }, evaluatedWith: app)
            let outcome = XCTWaiter.wait(for: [saved], timeout: 15)
            if outcome != .completed {
                let palette = app.descendants(matching: .any).matching(identifier: "PDF 필기 도구").firstMatch
                let bodyExists = body.exists, paletteExists = palette.exists
                let bodyFrame = bodyExists ? String(describing: body.frame) : "absent"
                let bodyValue = bodyExists ? String(describing: body.value) : "absent"
                let paletteFrame = paletteExists ? String(describing: palette.frame) : "absent"
                let details = "stroke=\(index + 1) bodyExists=\(bodyExists) bodyFrame=\(bodyFrame) bodyValue=\(bodyValue) paletteExists=\(paletteExists) paletteFrame=\(paletteFrame) normalizedStart=(\(x),\(y)) normalizedEnd=(\(x + 0.08),\(y + 0.02))"
                print("[NATIVE_PDF_20_FAILURE] \(details)")
                let diagnostic = XCTAttachment(string: details + "\n" + app.debugDescription)
                diagnostic.name = "Repeated native stroke failure state"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Repeated native stroke failure geometry"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
            XCTAssertEqual(outcome, .completed, "Stroke \(index + 1) must save, clear pending work and append its scene within15 seconds")
            if index == 0 { firstFullRenders = metric("sceneFull") }
            XCTAssertEqual(metric("sceneFull"), firstFullRenders,
                "Saving/acknowledging later strokes must not rasterize the earlier strokes again")
        }
        #if !targetEnvironment(simulator)
        XCTAssertEqual(metric("liveStrokes"), 20, "Every repeated contact must appear before lift")
        XCTAssertEqual(metric("lateStrokes"), 0)
        #endif
        print("Twenty consecutive UIKit contacts (not physical Pencil): \(body.value ?? "")")
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "Twenty consecutive saved native ink strokes"
        picture.lifetime = .keepAlways; add(picture)
    }
    /// Real XCTest touch dispatch through the production recognizer and PDFKit
    /// hierarchy. A DEBUG-only isolated fixture accepts direct touches in place
    /// of Pencil; this does not validate physical Pencil pressure or palm rejection.
    func testNativeInkSurvivesUIKitGestureArbitrationAndCanonicalSave() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--native-pencil-dispatch-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let materials = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
            XCTAssertTrue(materials.waitForExistence(timeout: 30)); materials.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        let closeMaterials = app.buttons["자료 닫기"]
        if closeMaterials.exists && closeMaterials.isHittable { closeMaterials.tap() }
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        func saved(_ count: Int) {
            let state = expectation(for: NSPredicate { _, _ in
                let value = body.value as? String ?? ""
                return value.contains("drawings=\(count) ") && value.contains("pending=0")
            }, evaluatedWith: app)
            wait(for: [state], timeout: 15)
        }
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 15)); pen.tap()
        parkPaletteAboveWritingArea(app, body)
        saved(0)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
            .press(forDuration: 0.2, thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        saved(1)
        let displayState = body.value as? String ?? ""
        func metric(_ name: String) -> Double {
            displayState.split(separator: " ").first(where: { $0.hasPrefix(name + "=") })
                .flatMap { Double($0.dropFirst(name.count + 1)) } ?? -1
        }
        #if !targetEnvironment(simulator)
        XCTAssertGreaterThan(metric("liveFrames"), 1, "Hardware drawable presentation must happen while contact remains down")
        XCTAssertEqual(metric("liveStrokes"), 1)
        XCTAssertEqual(metric("lateStrokes"), 0)
        XCTAssertGreaterThan(metric("firstPresentP95ms"), 0)
        XCTAssertLessThan(metric("firstPresentP95ms"), 100,
            "A stationary first point must not wait for the 200ms press to move")
        print("Real UIKit ink frame timing: \(displayState)")
        #endif
        XCTAssertTrue(app.buttons["되돌리기"].isEnabled)
        app.buttons["되돌리기"].tap(); saved(0)
        app.buttons["다시 실행"].tap(); saved(1)
        // A second contact must work after UIKit resets the recognizer.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.65)).tap()
        saved(2)
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "Native ink line and dot through real UIKit dispatch"
        picture.lifetime = .keepAlways; add(picture)
        app.terminate()
        // Retain fixture data without regenerating/reimporting its PDF.
        app.launchArguments.removeAll { ["--reset-ui-testing", "--desktop-pdf-fixture"].contains($0) }
        app.launch()
        if !body.waitForExistence(timeout: 10) {
            XCTAssertTrue(file.waitForExistence(timeout: 20)); file.tap()
        }
        XCTAssertTrue(body.waitForExistence(timeout: 20)); saved(2)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch.exists)
    }
    func testNativePDFRegainsActiveSplitFromPageNotesOnFirstBodyContact() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        try XCTSkipUnless(app.frame.width >= 1128, "Two visible documents require 560 points each plus the divider; compact tab presentation has separate coverage")
        openFixturePDF(app)
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        let documentTools = app.buttons["PDF 문서 도구"]
        XCTAssertTrue(documentTools.waitForExistence(timeout: 10)); documentTools.tap()
        let pageNotes = app.descendants(matching: .any).matching(identifier: "페이지 필기").firstMatch
        XCTAssertTrue(pageNotes.waitForExistence(timeout: 10)); pageNotes.tap()
        let create = app.buttons["만들고 나란히 열기"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        // WebKit exposes the section's role in its label ("1 페이지 필기, 영역").
        // Do not match the PDF's separate "1 페이지 필기 레이어" canvas.
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1 페이지 필기,")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let inactive = expectation(for: NSPredicate { _, _ in (body.value as? String)?.contains("active=0") == true }, evaluatedWith: app)
        wait(for: [inactive], timeout: 10)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let active = expectation(for: NSPredicate { _, _ in (body.value as? String)?.contains("active=1") == true }, evaluatedWith: app)
        wait(for: [active], timeout: 10)
        XCTAssertTrue(note.exists, "The note remains open beside the PDF")
        XCTAssertTrue(body.exists)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
    }
    func testFirstPencilContactInInactiveSplitSavesWithoutPriorToolToggle() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--native-pencil-dispatch-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        try XCTSkipUnless(app.frame.width >= 1128, "Two visible documents require 560 points each plus the divider")
        openFixturePDF(app)
        let expand = app.buttons["필기 도구 펴기"]
        if expand.exists { expand.tap() }
        app.buttons["PDF 문서 도구"].tap()
        let notes = app.descendants(matching: .any).matching(identifier: "페이지 필기").firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10)); notes.tap()
        let create = app.buttons["만들고 나란히 열기"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1 페이지 필기,")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        let inactive = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (body.value as? String)?.contains("active=0") == true
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [inactive], timeout: 10), .completed)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65)))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = body.value as? String ?? ""
            return value.contains("active=1") && value.contains("drawings=1 ") && value.contains("pending=0")
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
            "The very first synthetic Pencil contact in the inactive split must activate and save: \(body.value ?? "")")
        XCTAssertTrue(note.exists)
    }
    func testNativePDFFindOpensSystemSearchInsideOriginalWorkspace() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        openFixturePDF(app)
        let actions = app.buttons["bandal-native-pdf-page-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30)); actions.tap()
        let find = app.buttons["PDF에서 찾기"]
        XCTAssertTrue(find.waitForExistence(timeout: 10)); find.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap(); search.typeText("PDF")
        XCTAssertEqual(search.value as? String, "PDF")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch.exists)
    }
    func testNativePageActionsReachOriginalImageMenuAndDeliverIntoWhiteboard() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        openFixturePDF(app)
        let actions = app.buttons["bandal-native-pdf-page-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30)); actions.tap()
        let imageMenu = app.buttons["페이지 이미지 복사"]
        XCTAssertTrue(imageMenu.waitForExistence(timeout: 10)); imageMenu.tap()
        let originalOnly = app.descendants(matching: .any).matching(identifier: "원본만 이미지로 복사").firstMatch
        XCTAssertTrue(originalOnly.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(originalOnly.isHittable, "Original web image actions must remain above the native PDF")
        let includeInk = app.descendants(matching: .any).matching(identifier: "이미지로 복사").firstMatch
        XCTAssertTrue(includeInk.exists); XCTAssertTrue(includeInk.isEnabled)
        // Dismiss without changing the device clipboard.
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
        let menuClosed = expectation(for: NSPredicate { _, _ in !originalOnly.exists }, evaluatedWith: app)
        wait(for: [menuClosed], timeout: 5)
        actions.tap()
        let send = app.buttons["화이트보드로 보내기"]
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        // The isolated fixture has no board, so the original delivery flow
        // creates one and inserts its clip using the normal canvas history.
        let canvas = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "1페이지 캔버스")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), app.debugDescription)
        let delivered = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "에 붙였어요")).firstMatch
        XCTAssertTrue(delivered.exists, "The canonical delivery callback must complete")
        XCTAssertTrue(app.buttons["되돌리기"].isEnabled)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
    }
    func testNativeBodyKeepsToolbarAndFingerZoomWithoutCreatingInk() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        openFixturePDF(app)
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 10))
        XCTAssertTrue(pen.isSelected || (pen.value as? String) == "1", "A newly opened PDF must be ready to write")
        XCTAssertTrue(body.exists); XCTAssertFalse(failure.exists)
        let style = app.descendants(matching: .any).matching(identifier: "필기 스타일").firstMatch
        XCTAssertTrue(style.exists); style.tap()
        let blue = app.descendants(matching: .any).matching(identifier: "파랑").firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(blue.isHittable, "The floating style menu must receive input above the native PDF")
        XCTAssertTrue(body.exists, "A style popover must leave the native PDF visible")
        blue.tap()
        XCTAssertTrue(blue.isSelected || (blue.value as? String) == "1", "Choosing blue must update the original tool style")
        let thickness = app.sliders["선 굵기"]
        XCTAssertTrue(thickness.isHittable, "Native PDF must leave the original slider reachable")
        let previousThickness = String(describing: thickness.value)
        // WK range inputs do not expose the native min/max attributes required
        // by adjust(). Start the real contact on their current thumb.
        let scanner = Scanner(string: thickness.value as? String ?? "")
        guard let currentWidth = scanner.scanDouble(), currentWidth.isFinite else {
            XCTFail("Missing numeric width: \(previousThickness)"); return
        }
        let rangeWidth = thickness.frame.width, thumbInset = min(14, rangeWidth / 2)
        let currentFraction = CGFloat(min(1, max(0, (currentWidth - 1) / 24)))
        let targetFraction: CGFloat = currentFraction > 0.5 ? 0.25 : 0.75
        let startFraction = (thumbInset + (rangeWidth - 2 * thumbInset) * currentFraction) / rangeWidth
        let endFraction = (thumbInset + (rangeWidth - 2 * thumbInset) * targetFraction) / rangeWidth
        thickness.coordinate(withNormalizedOffset: CGVector(dx: startFraction, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: thickness.coordinate(withNormalizedOffset: CGVector(dx: endFraction, dy: 0.5)))
        XCTAssertNotEqual(String(describing: thickness.value), previousThickness, "Dragging thickness must update the original range value")
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Style changes must not create a drawing beneath the menu")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65)).tap()
        let paletteClosed = expectation(for: NSPredicate { _, _ in !blue.exists }, evaluatedWith: app)
        wait(for: [paletteClosed], timeout: 5)
        let documentTools = app.buttons["PDF 문서 도구"]
        documentTools.tap()
        let zoom = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "현재 배율 ")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        let before = zoom.label, toolbar = pen.frame
        app.buttons["도구 메뉴 닫기"].tap()
        func nativeZoom() -> String? {
            (body.value as? String)?.split(separator: " ").first(where: { $0.hasPrefix("zoom=") }).map(String.init)
        }
        let beforeNativeZoom = nativeZoom()
        XCTAssertNotNil(beforeNativeZoom)
        print("Native PDF before pinch: frame=\(body.frame), value=\(String(describing: body.value)), hittable=\(body.isHittable)")
        body.pinch(withScale: 1.5, velocity: 0.8)
        let changed = expectation(for: NSPredicate { _, _ in nativeZoom() != beforeNativeZoom }, evaluatedWith: app)
        wait(for: [changed], timeout: 10)
        documentTools.tap()
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        let toolbarZoomChanged = expectation(for: NSPredicate { _, _ in zoom.label != before }, evaluatedWith: app)
        wait(for: [toolbarZoomChanged], timeout: 5)
        print("Native PDF after pinch: frame=\(body.frame), value=\(String(describing: body.value)), toolbar=\(zoom.label)")
        app.buttons["도구 메뉴 닫기"].tap()
        XCTAssertEqual(pen.frame.width, toolbar.width, accuracy: 1)
        XCTAssertEqual(pen.frame.minX, toolbar.minX, accuracy: 1)
        XCTAssertEqual(pen.frame.minY, toolbar.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Finger zoom must not create drawings")
        for tool in ["형광펜", "지우개", "텍스트", "펜"] {
            if tool == "텍스트" { app.buttons["추가 필기 도구"].tap() }
            let button = app.descendants(matching: .any).matching(identifier: tool).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), tool); button.tap()
            XCTAssertTrue(body.exists, "Native PDF must remain open for \(tool)")
            XCTAssertFalse(failure.exists)
        }
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Use the requested landscape workspace")
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "Native PDF body with floating palette after finger zoom and tool changes"
        picture.lifetime = .keepAlways; add(picture)
    }

    private func openFixturePDF(_ app: XCUIApplication) {
        let materials = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
        XCTAssertTrue(materials.waitForExistence(timeout: 30)); materials.tap()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        let close = app.buttons["자료 닫기"]
        if close.exists && close.isHittable { close.tap() }
    }

    private func parkPaletteAboveWritingArea(_ app: XCUIApplication, _ body: XCUIElement) {
        // iPad palette preferences intentionally outlive a fixture library.
        // Keep real stroke coordinates clear of a previously moved toolbar.
        let handle = app.descendants(matching: .any).matching(identifier: "필기 도구 이동").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.07)))
        XCTAssertLessThan(handle.frame.maxY, body.frame.minY + body.frame.height * 0.25)
    }
}
