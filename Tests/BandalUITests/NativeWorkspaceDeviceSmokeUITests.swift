import XCTest

/// Opt-in physical-device smoke test against the ordinary profile. Never seeds,
/// resets, creates, deletes, or edits user resources. Screenshots remain only in
/// the test result bundle; they must not be copied into repository artifacts.
final class NativeWorkspaceDeviceSmokeUITests: XCTestCase {
    @MainActor
    func testPhysicalDeviceFixedControlsAndExistingWindowOverview() throws {
        let app = try launchOrdinaryProfile()
        let capsule = app.descendants(matching: .any).matching(identifier: "native-workspace-controls").firstMatch
        let chrome = app.buttons["native-workspace-chrome-menu"]
        let windows = app.buttons["native-workspace-windows-toggle"]
        let inspector = app.buttons["native-toggle-materials-rail"]
        let originalFrame = capsule.frame
        for control in [chrome, windows, inspector] {
            XCTAssertTrue(control.exists, "고정 버튼이 존재해야 합니다.")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            if control.isEnabled { XCTAssertTrue(control.isHittable, "활성 고정 버튼을 직접 누를 수 있어야 합니다.") }
        }

        // Settings and unselected spaces intentionally disable the first two
        // controls. Do not navigate away from the user's current screen there.
        guard chrome.isEnabled, windows.isEnabled else { return }
        let overview = app.descendants(matching: .any).matching(identifier: "native-windows-overview").firstMatch
        let initiallyInOverview = overview.exists
        let initialInspectorLabel = inspector.label
        defer {
            if inspector.exists, inspector.isEnabled, inspector.isHittable, inspector.label != initialInspectorLabel {
                inspector.tap()
            }
            if overview.exists != initiallyInOverview, windows.exists, windows.isEnabled, windows.isHittable {
                windows.tap()
            }
        }

        if !initiallyInOverview { windows.tap() }
        try wait("기존 윈도우 관리 화면 표시") { overview.exists }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-window-open-"))
        try wait("선택된 공간에 기존 윈도우 카드가 존재") { cards.count >= 1 }
        assertFixed(capsule, frame: originalFrame)
        attach(app, name: "Physical iPad existing window overview")
        if !initiallyInOverview {
            try wait("관리 화면 닫기 버튼 활성") { windows.isEnabled && windows.isHittable }
            windows.tap()
            try wait("기존 작업 화면으로 복귀") { !overview.exists }
            XCTAssertEqual(windows.label, "윈도우 관리")
        }

        try wait("오른쪽 사이드바 버튼 활성") { inspector.isEnabled && inspector.isHittable }
        inspector.tap()
        try wait("사이드바 표시 상태 전환") { inspector.label != initialInspectorLabel }
        assertFixed(capsule, frame: originalFrame)
        inspector.tap()
        try wait("원래 사이드바 표시 상태 복원") { inspector.label == initialInspectorLabel }
        assertFixed(capsule, frame: originalFrame)
        XCTAssertEqual(overview.exists, initiallyInOverview)
    }

    /// Keyboard delivery is verified independently so it cannot prevent the
    /// ordinary profile's fixed controls, existing cards and sidebar checks.
    @MainActor
    func testPhysicalDeviceOverviewEscapePreservesExistingWindows() throws {
        let app = try launchOrdinaryProfile()
        let capsule = app.descendants(matching: .any).matching(identifier: "native-workspace-controls").firstMatch
        let chrome = app.buttons["native-workspace-chrome-menu"]
        let windows = app.buttons["native-workspace-windows-toggle"]
        let inspector = app.buttons["native-toggle-materials-rail"]
        guard chrome.isEnabled, windows.isEnabled else { return }
        let overview = app.descendants(matching: .any).matching(identifier: "native-windows-overview").firstMatch
        let initiallyInOverview = overview.exists
        let initialInspectorLabel = inspector.label
        let originalFrame = capsule.frame
        defer {
            if inspector.exists, inspector.isEnabled, inspector.isHittable, inspector.label != initialInspectorLabel {
                inspector.tap()
            }
            if overview.exists != initiallyInOverview, windows.exists, windows.isEnabled, windows.isHittable {
                windows.tap()
            }
        }

        if !initiallyInOverview { windows.tap() }
        try wait("기존 윈도우 관리 화면 표시") { overview.exists }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-window-open-"))
        try wait("선택된 공간에 기존 윈도우 카드가 존재") { cards.count >= 1 }
        let originalCardCount = cards.count
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        try wait("Escape로 기존 작업 화면 복귀") { !overview.exists }
        try wait("윈도우 관리 재진입 버튼 활성") { windows.isEnabled && windows.isHittable }
        windows.tap()
        try wait("Escape 후 기존 윈도우 목록 유지") { overview.exists && cards.count == originalCardCount }
        assertFixed(capsule, frame: originalFrame)
    }

    @MainActor private func launchOrdinaryProfile() throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("실제 iPad의 일반 프로필을 확인하는 전용 검사입니다.")
        #else
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        let capsule = app.descendants(matching: .any).matching(identifier: "native-workspace-controls").firstMatch
        guard capsule.waitForExistence(timeout: 40) else {
            throw XCTSkip("로그인 또는 시스템 화면을 먼저 완료해야 화면 제어를 확인할 수 있습니다.")
        }
        return app
        #endif
    }

    @MainActor private func assertFixed(_ capsule: XCUIElement, frame: CGRect) {
        XCTAssertEqual(capsule.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(capsule.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(capsule.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(capsule.frame.height, frame.height, accuracy: 1)
    }

    private enum SmokeFailure: Error { case timeout }
    @MainActor private func wait(_ message: String, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
            XCTFail(message)
            throw SmokeFailure.timeout
        }
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
