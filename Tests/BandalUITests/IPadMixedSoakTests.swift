import XCTest

/// Opt-in, isolated-library endurance coverage of the installed WK shell and
/// native PDF host. UIKit synthetic contacts are not physical Pencil samples.
/// Browser networking, service sign-in and hardware latency are excluded.
final class IPadMixedSoakTests: XCTestCase {
    private let noteTitle = "새 필기"
    private let pdfTitle = "PDF pinch fixture.pdf"
    private let initialMarker = "IPAD-SOAK-BEGIN"

    func testOptInMixedWorkspaceSoak() throws {
        let environment = ProcessInfo.processInfo.environment
        // xcodebuild forwards TEST_RUNNER_ variables to the test runner.
        let fullRun = (environment["BANDAL_IPAD_SOAK"] ?? environment["TEST_RUNNER_BANDAL_IPAD_SOAK"]) == "1"
        let requested = Double(environment["BANDAL_IPAD_SOAK_SECONDS"] ?? environment["TEST_RUNNER_BANDAL_IPAD_SOAK_SECONDS"] ?? "")
        guard fullRun || (requested?.isFinite == true && (requested ?? 0) >= 1) else {
            throw XCTSkip("Opt in with BANDAL_IPAD_SOAK_SECONDS=<seconds>; BANDAL_IPAD_SOAK=1 requires at least 7200 seconds.")
        }
        let duration = fullRun ? max(7200, requested?.isFinite == true ? (requested ?? 7200) : 7200) : requested!
        executionTimeAllowance = duration + 900
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture", "--desktop-pdf-fixture", "--native-pencil-dispatch-fixture", "--ipad-interaction-diagnostics", "-bandal.nativePDF.enabled", "YES"]
        app.launch()
        tap(app, "자료 사이드바 펼치기")
        if element(app, "패널 고정 해제").exists { tap(app, "패널 고정 해제") }
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pdfTitle)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), app.debugDescription)
        file.tap()
        tap(app, "자료 닫기")
        expectDrawings(app, 0)
        parkPalette(app)
        if element(app, "필기 도구 펴기").exists { tap(app, "필기 도구 펴기") }
        expectDrawings(app, 0)
        XCTAssertTrue(element(app, "필기 도구 이동").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "주석 도구").exists)
        XCTAssertFalse(app.statusBars.firstMatch.exists)
        // The first stroke occurs before any pen/annotation-tool toggle.
        drawSyntheticStroke(app, cycle: 0)
        expectDrawings(app, 1)
        if element(app, "필기 도구 펴기").exists { tap(app, "필기 도구 펴기") }
        XCTAssertTrue(element(app, "펜").waitForExistence(timeout: 15))

        // NewTabMenu's query becomes the new note's title for this command.
        tap(app, "새 탭 열기")
        let query = element(app, "새 탭 검색")
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap(); query.typeText(noteTitle)
        tap(app, "새 마크다운")
        appendNote(app, marker: initialMarker)
        selectTab(app, title: pdfTitle)
        expectDrawings(app, 1)

        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + duration
        var cycles = 0, drawings = 1, restarts = 0
        var latestMarker = initialMarker
        print("[IPAD_MIXED_SOAK] start duration=\(duration)s input=UIKit-synthetic browser=excluded services=excluded")
        repeat {
            cycles += 1
            parkPalette(app)
            expectDrawings(app, drawings)
            drawSyntheticStroke(app, cycle: cycles)
            drawings += 1
            expectDrawings(app, drawings)
            movePaletteWithoutDrawing(app, count: drawings)

            tap(app, "내 공간 열기")
            tap(app, "설정")
            XCTAssertTrue(element(app, "앱으로 돌아가기").waitForExistence(timeout: 20))
            XCTAssertFalse(element(app, "bandal-native-pdf-body").exists, "Settings must cover native paper")
            XCTAssertFalse(element(app, "필기 도구 이동").exists, "Palette must not cover settings")
            let back = element(app, "설정 목록으로")
            if back.exists && back.isHittable { back.tap() }
            tap(app, "일반")
            assertHealthy(app)
            tap(app, "앱으로 돌아가기")
            expectDrawings(app, drawings)

            tap(app, "자료 사이드바 펼치기")
            XCTAssertTrue(element(app, "자료 닫기").waitForExistence(timeout: 10))
            XCTAssertFalse(element(app, "bandal-native-pdf-body").exists, "Unpinned materials sheet must block native paper")
            tap(app, "자료 닫기")
            expectDrawings(app, drawings)

            selectTab(app, title: noteTitle)
            XCTAssertFalse(element(app, "bandal-native-pdf-body").exists, "Inactive PDF must not cover Markdown")
            XCTAssertFalse(element(app, "필기 도구 이동").exists)
            expectNote(app, contains: latestMarker)
            latestMarker = "IPAD-SOAK-CYCLE-\(cycles)"
            appendNote(app, marker: latestMarker)
            selectTab(app, title: pdfTitle)
            expectDrawings(app, drawings)

            XCUIDevice.shared.orientation = cycles.isMultiple(of: 2) ? .landscapeLeft : .portrait
            waitUntil("Requested orientation") {
                cycles.isMultiple(of: 2) ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
            }
            expectDrawings(app, drawings)
            let handle = element(app, "필기 도구 이동")
            XCTAssertTrue(handle.waitForExistence(timeout: 10))
            XCTAssertTrue(app.frame.contains(handle.frame), "Palette must remain inside rotated app bounds")
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            expectDrawings(app, drawings)
            if cycles.isMultiple(of: 3) {
                restartAndVerify(app, drawings: drawings, noteMarker: latestMarker)
                restarts += 1
            }
            assertHealthy(app)
            print("[IPAD_MIXED_SOAK] cycle=\(cycles) elapsed=\(Int(ProcessInfo.processInfo.systemUptime - start))s target=\(Int(duration))s canonicalDrawings=\(drawings) pending=0 noteMarker=\(latestMarker) restarts=\(restarts) input=UIKit-synthetic")
        } while ProcessInfo.processInfo.systemUptime < deadline

        // A final cold app launch validates committed data, even in a short run.
        restartAndVerify(app, drawings: drawings, noteMarker: latestMarker)
        restarts += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, duration)
        let summary = "elapsed=\(elapsed)s requested=\(duration)s cycles=\(cycles) canonicalDrawings=\(drawings) pending=0 restarts=\(restarts); UIKit synthetic contacts; browser, remote services, physical Pencil and display latency excluded"
        print("[IPAD_MIXED_SOAK] completed \(summary)")
        let report = XCTAttachment(string: summary)
        report.name = "Mixed workspace soak metrics"; report.lifetime = .keepAlways; add(report)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Mixed workspace soak final restored PDF"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        // WebKit may expose aria-pressed controls as Switch rather than Button.
        app.descendants(matching: .any).matching(identifier: label).firstMatch
    }
    private func tap(_ app: XCUIApplication, _ label: String) {
        let target = element(app, label)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "Missing \(label)\n\(app.debugDescription)")
        target.tap()
    }
    private func waitUntil(_ description: String, timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, description)
    }
    private func expectDrawings(_ app: XCUIApplication, _ count: Int) {
        let body = element(app, "bandal-native-pdf-body")
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        waitUntil("Canonical drawing ACK \(count)") {
            let value = body.value as? String ?? ""
            return value.contains("drawings=\(count) ") && value.contains("pending=0")
        }
    }
    private func parkPalette(_ app: XCUIApplication) {
        let body = element(app, "bandal-native-pdf-body")
        let handle = element(app, "필기 도구 이동")
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        // Palette preferences outlive the isolated library; clear the writing
        // area without changing the default pen or asserting a reset preference.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.07)))
        XCTAssertLessThan(handle.frame.maxY, body.frame.minY + body.frame.height * 0.25)
    }
    private func drawSyntheticStroke(_ app: XCUIApplication, cycle: Int) {
        let body = element(app, "bandal-native-pdf-body")
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        // Spread strokes over lower paper, away from either palette position.
        let y = 0.58 + Double(cycle % 5) * 0.035
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y)).press(forDuration: 0.15,
            thenDragTo: body.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y + 0.025)))
    }
    private func movePaletteWithoutDrawing(_ app: XCUIApplication, count: Int) {
        let handle = element(app, "필기 도구 이동")
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        let before = handle.frame
        let y = before.midY < app.frame.midY ? min(app.frame.midY, before.midY + 100) : max(90, before.midY - 100)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: before.midX, dy: y)))
        XCTAssertGreaterThan(abs(handle.frame.minY - before.minY), 20)
        expectDrawings(app, count)
    }
    private func selectTab(_ app: XCUIApplication, title: String) {
        let list = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "열린 탭 ", "개 목록")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15)); list.tap()
        XCTAssertTrue(element(app, "탭 목록 닫기").waitForExistence(timeout: 10))
        // The portal is later in the tree than the same title in the tab strip.
        let matches = app.buttons.matching(identifier: title).allElementsBoundByIndex
        guard let target = matches.last(where: { $0.isHittable }) else {
            XCTFail("Missing tab \(title)\n\(app.debugDescription)"); return
        }
        target.tap()
        waitUntil("Tab menu closes after selecting \(title)") { !self.element(app, "탭 목록 닫기").exists }
    }
    private func appendNote(_ app: XCUIApplication, marker: String) {
        let editor = element(app, "마크다운 필기 편집기")
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        editor.tap(); editor.typeText("\n\(marker)\n")
        expectNote(app, contains: marker)
        XCTAssertTrue(element(app, "저장됨").waitForExistence(timeout: 15), "Markdown save must finish")
        XCTAssertFalse(element(app, "저장 실패").exists)
        XCTAssertFalse(element(app, "충돌").exists)
    }
    private func expectNote(_ app: XCUIApplication, contains marker: String) {
        let editor = element(app, "마크다운 필기 편집기")
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        waitUntil("Saved Markdown includes \(marker)") {
            (editor.value as? String ?? "").contains(marker) || editor.debugDescription.contains(marker)
        }
    }
    private func restartAndVerify(_ app: XCUIApplication, drawings: Int, noteMarker: String) {
        app.terminate()
        app.launchArguments.removeAll { ["--reset-ui-testing", "--desktop-pdf-fixture"].contains($0) }
        app.launch()
        expectDrawings(app, drawings)
        XCTAssertFalse(element(app, "내 공간 닫기").exists, "Navigation must remain closed after restart")
        XCTAssertFalse(element(app, "자료 닫기").exists, "Materials must remain closed after restart")
        selectTab(app, title: noteTitle)
        expectNote(app, contains: initialMarker)
        expectNote(app, contains: noteMarker)
        selectTab(app, title: pdfTitle)
        expectDrawings(app, drawings)
        assertHealthy(app)
    }
    private func assertHealthy(_ app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground)
        let failure = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier IN %@ OR label IN %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            ["bandal-operation-notice", "bandal-native-diagnostic"], ["작업 오류", "시작 오류"],
            "반달 실행 연결을 확인해 주세요.", "반달 화면을 열지 못했어요", "작업을 완료하지 못했어요")).firstMatch
        XCTAssertFalse(failure.exists, app.debugDescription)
    }
}
