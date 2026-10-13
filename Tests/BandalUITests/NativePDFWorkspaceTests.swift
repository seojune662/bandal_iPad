import XCTest

/// Tests the actual native body inside the original desktop workspace. XCTest
/// synthesizes fingers; these checks make no claim about physical Pencil feel.
final class NativePDFWorkspaceTests: XCTestCase {
    func testNativePDFRegainsActiveSplitFromPageNotesOnFirstBodyContact() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        app.buttons["페이지 필기"].tap()
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
    func testNativePDFFindOpensSystemSearchInsideOriginalWorkspace() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
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
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
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
        app.buttons["축소"].tap()
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
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "PDF pinch fixture.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
        let body = app.descendants(matching: .any).matching(identifier: "bandal-native-pdf-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "반달 실행 연결을 확인해 주세요.")).firstMatch
        XCTAssertFalse(failure.exists)
        let controls = app.descendants(matching: .any).matching(identifier: "주석 도구").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10)); controls.tap()
        let pen = app.descendants(matching: .any).matching(identifier: "펜").firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 10)); pen.tap()
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
        // by adjust(). Exercise their real touch path instead.
        thickness.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: thickness.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertNotEqual(String(describing: thickness.value), previousThickness, "Dragging thickness must update the original range value")
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Style changes must not create a drawing beneath the menu")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65)).tap()
        let paletteClosed = expectation(for: NSPredicate { _, _ in !blue.exists }, evaluatedWith: app)
        wait(for: [paletteClosed], timeout: 5)
        let zoom = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "현재 배율 ")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        let before = zoom.label, toolbar = app.buttons["축소"].frame
        print("Native PDF before pinch: frame=\(body.frame), value=\(String(describing: body.value)), hittable=\(body.isHittable)")
        body.pinch(withScale: 1.5, velocity: 0.8)
        let changed = expectation(for: NSPredicate { _, _ in zoom.label != before }, evaluatedWith: app)
        wait(for: [changed], timeout: 10)
        print("Native PDF after pinch: frame=\(body.frame), value=\(String(describing: body.value)), toolbar=\(zoom.label)")
        XCTAssertEqual(app.buttons["축소"].frame.width, toolbar.width, accuracy: 1)
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled, "Finger zoom must not create drawings")
        for tool in ["형광펜", "지우개", "텍스트", "펜"] {
            let button = app.descendants(matching: .any).matching(identifier: tool).firstMatch
            XCTAssertTrue(button.exists, tool); button.tap()
            XCTAssertTrue(body.exists, "Native PDF must remain open for \(tool)")
            XCTAssertFalse(failure.exists)
        }
        XCTAssertFalse(app.buttons["되돌리기"].isEnabled)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Use the requested landscape workspace")
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "Native PDF body with original toolbar after finger zoom and tool changes"
        picture.lifetime = .keepAlways; add(picture)
    }
}
