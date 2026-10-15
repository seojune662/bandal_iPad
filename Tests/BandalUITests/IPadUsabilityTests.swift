import XCTest

/// These exercise the installed WK shell and native paper together. Direct
/// UIKit contacts stand in for Pencil only in the isolated DEBUG fixture.
final class IPadUsabilityTests: XCTestCase {
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: label).firstMatch
    }
    private func tap(_ app: XCUIApplication, _ label: String) {
        let target = element(app, label)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "Missing \(label)\n\(app.debugDescription)")
        target.tap()
    }
    private func expectDrawings(_ app: XCUIApplication, _ count: Int) {
        let body = element(app, "bandal-native-pdf-body")
        let saved = expectation(for: NSPredicate { _, _ in
            let value = body.value as? String ?? ""
            return value.contains("drawings=\(count) ") && value.contains("pending=0")
        }, evaluatedWith: app)
        wait(for: [saved], timeout: 15)
    }
    private func attach(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func expectSelected(_ app: XCUIApplication, _ label: String) {
        let selected = element(app, label)
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        let ready = expectation(for: NSPredicate { _, _ in
            selected.isSelected || (selected.value as? String) == "1"
        }, evaluatedWith: app)
        wait(for: [ready], timeout: 10)
    }
    private func dragSlider(_ slider: XCUIElement, minimum: Double, maximum: Double, to fraction: CGFloat) {
        XCTAssertTrue(slider.exists)
        let previousValue = String(describing: slider.value)
        // WebKit's slider value text is "N / 25" or "N%". Grab the current
        // thumb rather than asking UIKit to begin a drag on empty track.
        let scanner = Scanner(string: slider.value as? String ?? "")
        guard let value = scanner.scanDouble(), value.isFinite else {
            XCTFail("Missing numeric slider value: \(String(describing: slider.value))"); return
        }
        let width = slider.frame.width, inset = min(14, width / 2)
        let current = CGFloat(min(1, max(0, (value - minimum) / (maximum - minimum))))
        // Preferences survive fixture resets. Always request a distinct value
        // so this contact, rather than a preceding color/preset click, is tested.
        let target: CGFloat = abs(current - fraction) < 0.1 ? (current > 0.5 ? 0.25 : 0.75) : fraction
        let start = (inset + (width - 2 * inset) * current) / width
        let end = (inset + (width - 2 * inset) * target) / width
        slider.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)))
        XCTAssertNotEqual(String(describing: slider.value), previousValue, "The individual slider drag must change its accessible value")
    }

    func testSettingsCoverInkedPDFAndPaletteMoveDoesNotDraw() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--native-pencil-dispatch-fixture", "--ipad-interaction-diagnostics", "--ipad-renderer-reload-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        tap(app, "자료 사이드바 펼치기")
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 20)); file.tap()
        tap(app, "자료 닫기")
        let body = element(app, "bandal-native-pdf-body")
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        // A retained collapsed preference must still be ready to write. Do
        // not expand or select any drawing tool before the first contact.
        XCTAssertTrue(element(app, "필기 도구 이동").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "주석 도구").exists)
        XCTAssertFalse(app.statusBars.firstMatch.exists)
        expectDrawings(app, 0)
        // No annotation/pen toggle precedes the first saved stroke.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        expectDrawings(app, 1)
        if element(app, "필기 도구 펴기").exists { tap(app, "필기 도구 펴기") }
        expectSelected(app, "펜")
        let handle = element(app, "필기 도구 이동")
        XCTAssertTrue(handle.exists)
        let initial = handle.frame
        // Palette preferences survive fixture-library resets. Move relative to
        // the current position so a repeated run cannot drag to the same point.
        let targetY = initial.midY < app.frame.midY ? initial.midY + 130 : initial.midY - 130
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: initial.midX, dy: targetY)))
        XCTAssertGreaterThan(abs(handle.frame.minY - initial.minY), 20)
        expectDrawings(app, 1)
        tap(app, "필기 스타일")
        tap(app, "파랑")
        let thickness = app.sliders["선 굵기"], opacity = app.sliders["불투명도"]
        dragSlider(thickness, minimum: 1, maximum: 25, to: 0.65)
        dragSlider(opacity, minimum: 10, maximum: 100, to: 0.75)
        let favoriteWidth = String(describing: thickness.value), favoriteOpacity = String(describing: opacity.value)
        tap(app, "즐겨찾는 펜 1에 현재 펜 저장")
        XCTAssertTrue(element(app, "즐겨찾는 펜 1: 파랑").waitForExistence(timeout: 10))
        tap(app, "빨강")
        dragSlider(thickness, minimum: 1, maximum: 25, to: 0.2)
        dragSlider(opacity, minimum: 10, maximum: 100, to: 0.3)
        XCTAssertNotEqual(String(describing: thickness.value), favoriteWidth)
        XCTAssertNotEqual(String(describing: opacity.value), favoriteOpacity)
        XCTAssertTrue(element(app, "즐겨찾는 펜 1: 파랑").exists, "Editing the current pen must not overwrite a favorite")
        tap(app, "즐겨찾는 펜 1: 파랑")
        expectSelected(app, "파랑")
        XCTAssertEqual(String(describing: thickness.value), favoriteWidth)
        XCTAssertEqual(String(describing: opacity.value), favoriteOpacity)
        tap(app, "도구 메뉴 닫기")
        expectDrawings(app, 1)
        let collapse = element(app, "필기 도구 접기")
        XCTAssertGreaterThanOrEqual(collapse.frame.width, 44)
        XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
        collapse.tap()
        XCTAssertTrue(element(app, "필기 도구 펴기").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "펜").exists)
        XCTAssertTrue(handle.exists)
        expectDrawings(app, 1)
        // The folded palette preserves the selected pen, so its next original
        // UIKit contact must still produce exactly one canonical drawing.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.72)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.76)))
        let expectedDrawings = 2
        expectDrawings(app, expectedDrawings)
        tap(app, "필기 도구 펴기")
        expectSelected(app, "펜")
        attach("Single top row and movable PDF palette")
        for index in 0..<5 {
            tap(app, "내 공간 열기")
            tap(app, "설정")
            XCTAssertTrue(element(app, "앱으로 돌아가기").waitForExistence(timeout: 20))
            XCTAssertFalse(body.exists, "Native paper must not cover settings or accept contacts")
            XCTAssertFalse(element(app, "필기 도구 이동").exists, "The document palette must not remain over settings")
            tap(app, "일반")
            if index == 0 { attach("Settings fully cover an inked native PDF") }
            tap(app, "앱으로 돌아가기")
            XCTAssertTrue(body.waitForExistence(timeout: 15))
            XCTAssertTrue(element(app, "필기 도구 이동").waitForExistence(timeout: 10))
            expectDrawings(app, expectedDrawings)
        }
        XCTAssertFalse(element(app, "작업 오류").exists)
        XCTAssertFalse(element(app, "시작 오류").exists)
        let timing = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "iPad interaction timing:")).firstMatch
        XCTAssertTrue(timing.exists)
        print(timing.label + " (UIKit synthetic contact; event to next render opportunity, not physical display latency)")
        tap(app, "필기 도구 접기")
        XCTAssertTrue(element(app, "필기 도구 펴기").waitForExistence(timeout: 10))
        tap(app, "화면 다시 불러오기 검사 1")
        XCTAssertTrue(element(app, "화면 다시 불러오기 검사 2").waitForExistence(timeout: 30))
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").count, 1)
        expectDrawings(app, expectedDrawings)
        XCTAssertTrue(element(app, "필기 도구 펴기").waitForExistence(timeout: 15), "Renderer reload preserves the collapsed preference")
        XCTAssertFalse(element(app, "작업 오류").exists)
        app.terminate()
        app.launchArguments.removeAll { ["--reset-ui-testing", "--desktop-pdf-fixture"].contains($0) }
        app.launch()
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        expectDrawings(app, expectedDrawings)
        XCTAssertTrue(element(app, "필기 도구 펴기").waitForExistence(timeout: 15), "Cold launch preserves the collapsed preference")
        tap(app, "필기 도구 펴기")
        expectSelected(app, "펜")
        tap(app, "필기 스타일")
        XCTAssertTrue(element(app, "즐겨찾는 펜 1: 파랑").exists)
        expectSelected(app, "파랑")
        XCTAssertEqual(String(describing: app.sliders["선 굵기"].value), favoriteWidth)
        XCTAssertEqual(String(describing: app.sliders["불투명도"].value), favoriteOpacity)
        tap(app, "도구 메뉴 닫기")
        expectDrawings(app, expectedDrawings)
    }
}
