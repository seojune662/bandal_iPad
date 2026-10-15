import XCTest

final class PencilInputTests: XCTestCase {
    func testPDFPenControlsAndFingerNavigationDoNotShowRuntimeFailure() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture"]
        app.launch()
        openMaterials(app)
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30))
        file.tap()
        closeMaterials(app)
        let paper = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1 페이지,")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 30))
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 10))
        XCTAssertTrue(pen.isSelected || (pen.value as? String) == "1", "A newly opened PDF must be ready to write")
        XCTAssertFalse(failure.exists, failure.exists ? failure.label : "")
        app.descendants(matching: .any).matching(identifier: "필기 스타일").firstMatch.tap()
        let color = app.descendants(matching: .any).matching(identifier: "파랑").firstMatch
        XCTAssertTrue(color.waitForExistence(timeout: 10))
        color.tap()
        pen.tap()
        let visible = paper.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 36, dy: 36)
        XCTAssertGreaterThan(visible.height, 180)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + 180))
        let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + 30))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertFalse(failure.exists, failure.exists ? failure.label : "")
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Finger navigation must not draw")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPDFRegionPinchViaMaterialRowChangesOnlyDocumentScale() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--desktop-gesture-diagnostics"]
        app.launch()
        openMaterials(app)
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), app.debugDescription)
        file.tap()
        closeMaterials(app)
        // WebKit localizes the role suffix ("region" / "영역") to the device
        // language. Match the application's page label, not that OS suffix.
        let paper = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "1 페이지,")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 30), app.debugDescription)
        let koreanText = expectation(for: NSPredicate { _, _ in
            paper.staticTexts.allElementsBoundByIndex.map(\.label).joined().replacingOccurrences(of: " ", with: "").contains("한글표시검증")
        }, evaluatedWith: paper)
        wait(for: [koreanText], timeout: 10)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch.exists)
        let documentTools = app.buttons["PDF 문서 도구"]
        XCTAssertTrue(documentTools.waitForExistence(timeout: 15)); documentTools.tap()
        let zoom = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "현재 배율 ")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 15), app.debugDescription)
        let toolbarButton = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(toolbarButton.exists)
        let originalPaper = paper.frame, originalButton = toolbarButton.frame, originalZoom = zoom.label
        app.buttons["도구 메뉴 닫기"].tap()
        print("PDF before pinch: paper=\(originalPaper), zoom=\(originalZoom)")
        XCTAssertGreaterThan(originalPaper.width, 200)
        paper.pinch(withScale: 1.6, velocity: 0.8)
        let enlarged = expectation(for: NSPredicate { _, _ in
            paper.exists && paper.frame.width > originalPaper.width * 1.15
        }, evaluatedWith: paper)
        wait(for: [enlarged], timeout: 10)
        documentTools.tap()
        let zoomChanged = expectation(for: NSPredicate { _, _ in zoom.exists && zoom.label != originalZoom }, evaluatedWith: app)
        wait(for: [zoomChanged], timeout: 5)
        print("PDF after pinch: paper=\(paper.frame), zoom=\(zoom.label)")
        app.buttons["도구 메뉴 닫기"].tap()
        let trace = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Gesture diagnostic: ")).firstMatch
        if trace.exists { print(trace.label) }
        XCTAssertEqual(toolbarButton.frame.width, originalButton.width, accuracy: 1)
        XCTAssertEqual(toolbarButton.frame.minX, originalButton.minX, accuracy: 1)
        XCTAssertEqual(toolbarButton.frame.minY, originalButton.minY, accuracy: 1)
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Original desktop PDF after actual two-finger pinch"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testActualTwoFingerPinchScalesWhiteboardPaperWithoutZoomingDesktopChrome() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        openMaterials(app)
        let create = app.buttons["새 화이트보드 만들기"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), app.debugDescription)
        create.tap()
        closeMaterials(app)
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 15), app.debugDescription)
        pen.tap()
        let paper = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "1페이지 캔버스")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 10), app.debugDescription)
        let originalPaper = paper.frame, originalPen = pen.frame
        XCTAssertGreaterThan(originalPaper.width, 200)
        paper.pinch(withScale: 1.6, velocity: 0.8)
        let enlarged = expectation(for: NSPredicate { _, _ in
            paper.exists && paper.frame.width > originalPaper.width * 1.2
        }, evaluatedWith: paper)
        wait(for: [enlarged], timeout: 8)
        // Whole-WK viewport zoom would enlarge and move the original toolbar.
        // These two independent observations prove canvas-specific zoom.
        XCTAssertEqual(pen.frame.width, originalPen.width, accuracy: 1)
        XCTAssertEqual(pen.frame.minX, originalPen.minX, accuracy: 1)
        XCTAssertEqual(pen.frame.minY, originalPen.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Two fingers must not create ink")
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Original desktop whiteboard after actual two-finger pinch"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    /// XCUITest synthesizes fingers, not Apple Pencil pressure. Pressure and
    /// coalesced samples are covered by the real InkLayer WebKit fixture;
    /// physical Pencil input remains a separate device acceptance check.
    func testFingerPanMovesDesktopWhiteboardWithoutCreatingInk() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        openMaterials(app)
        let create = app.buttons["새 화이트보드 만들기"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), app.debugDescription)
        create.tap()
        closeMaterials(app)
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 15), app.debugDescription)
        pen.tap()
        let undo = app.buttons["되돌리기"]
        XCTAssertTrue(undo.exists)
        XCTAssertFalse(undo.isEnabled, "A new board has no ink history")
        let paper = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "1페이지 캔버스")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 10), app.debugDescription)
        let before = paper.frame
        let window = app.windows.firstMatch
        let visible = before.intersection(window.frame).insetBy(dx: 24, dy: 24)
        XCTAssertGreaterThan(visible.height, 140)
        XCTAssertGreaterThan(visible.width, 100)
        // Use the actual paper bounds; window-relative guesses previously
        // missed the paper entirely and falsely passed a no-crash assertion.
        let x = visible.midX
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - window.frame.minX, dy: visible.minY + min(visible.height - 100, 330) - window.frame.minY))
        let end = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - window.frame.minX, dy: visible.minY + 40 - window.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        let moved = expectation(for: NSPredicate { _, _ in
            paper.exists && paper.frame.minY < before.minY - 60
        }, evaluatedWith: paper)
        wait(for: [moved], timeout: 5)
        XCTAssertFalse(undo.isEnabled, "A finger drag while the pen tool is selected must not create ink")
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Original desktop whiteboard after actual finger pan"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMaterials(_ app: XCUIApplication) {
        let open = app.descendants(matching: .any).matching(identifier: "자료 사이드바 펼치기").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.buttons["자료 닫기"].waitForExistence(timeout: 10))
    }

    private func closeMaterials(_ app: XCUIApplication) {
        let close = app.buttons["자료 닫기"]
        if close.exists && close.isHittable { close.tap() }
    }
}
