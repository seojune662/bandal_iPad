import XCTest

/// Original workspace chrome above the native website, using an isolated
/// library. Public-page appearance and authentication are separate checks.
final class BrowserWorkspaceTests: XCTestCase {
    func testFailedPageRetriesInsideAppAndKeepsItsAddressEditable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["내 공간 열기"].waitForExistence(timeout: 30), app.debugDescription)
        let newTab = app.buttons["새 탭 열기"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 10)); newTab.tap()
        let browser = app.buttons["새 브라우저 탭"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            browser.exists && browser.isHittable && browser.frame.minY >= 0 && browser.frame.height < 80
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
        browser.tap()
        let addresses = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "주소 또는 검색어"))
        XCTAssertTrue(addresses.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let address = try XCTUnwrap(addresses.allElementsBoundByIndex.first { $0.elementType == .textField || $0.elementType == .searchField }, app.debugDescription)
        address.tap()
        address.typeText("http://127.0.0.1:59998/browser-recovery\n")
        let edit = app.buttons["주소 수정"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["기본 브라우저에서 열기"].exists)
        let retry = app.buttons["다시 시도"].firstMatch
        XCTAssertTrue(retry.exists); XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThan(app.frame.height, app.frame.width, "Keep recovery usable in a portrait workspace")
        edit.tap()
        XCTAssertTrue((address.value as? String)?.contains("127.0.0.1:59998/browser-recovery") == true, app.debugDescription)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Failed browser navigation remains in app with editable target address"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testBrowserTouchMenuRemainsAboveNativePageAndFindCanBeOpenedWithoutKeyboard() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["내 공간 열기"].waitForExistence(timeout: 30), app.debugDescription)
        // The canonical fixture includes starter documents, so use the normal
        // tab command rather than relying on an empty-workspace welcome action.
        let newTab = app.buttons["새 탭 열기"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), app.debugDescription)
        newTab.tap()
        let browser = app.buttons["새 브라우저 탭"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 10), app.debugDescription)
        // The keyboard moves this low-anchored menu. Wait for the actual AX
        // target, and reject the old WebKit translated-scroll bounds regression
        // (a visible 44pt row was exposed as y=-326, height=624).
        let started = ProcessInfo.processInfo.systemUptime
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            browser.exists && browser.isHittable && browser.frame.minY >= 0 &&
                browser.frame.height >= 44 && browser.frame.height < 80 &&
                browser.frame.maxY <= app.frame.maxY
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        print("Browser new-tab AX readiness: \(ProcessInfo.processInfo.systemUptime - started)s, frame=\(browser.frame), hittable=\(browser.isHittable)")
        if result != .completed {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "New-tab menu accessibility bounds failure"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(result, .completed, app.debugDescription)
        browser.tap()
        let more = app.descendants(matching: .any).matching(identifier: "브라우저 도구 더 보기").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertGreaterThanOrEqual(more.frame.width, 44); XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        more.tap()
        let find = app.buttons["페이지에서 찾기"]
        XCTAssertTrue(find.waitForExistence(timeout: 10)); XCTAssertTrue(find.isHittable)
        let share = app.buttons["페이지 공유"]
        XCTAssertTrue(share.exists); XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.buttons["페이지 확대"].exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Use the requested landscape workspace")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad browser touch menu above native website"
        screenshot.lifetime = .keepAlways; add(screenshot)
        find.tap()
        let input = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "페이지에서 찾기")).allElementsBoundByIndex.first { $0.elementType == .textField || $0.elementType == .searchField }
        XCTAssertNotNil(input, app.debugDescription)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier IN %@ OR label IN %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            ["bandal-operation-notice", "bandal-native-diagnostic"], ["작업 오류", "시작 오류"],
            "반달 실행 연결을 확인해 주세요.", "반달 화면을 열지 못했어요", "작업을 완료하지 못했어요")).firstMatch
        XCTAssertFalse(failure.exists)
    }
}
