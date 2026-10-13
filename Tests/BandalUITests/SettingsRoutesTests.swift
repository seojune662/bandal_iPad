import XCTest

/// Opens every actual desktop SettingsApp route in the installed iPad shell.
/// Category descriptions are from the unchanged upstream locale source.
final class SettingsRoutesTests: XCTestCase {
    func testAllTwentyOriginalSettingsRoutesRenderWithoutStartupError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--desktop-parity-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["설정"].tap()
        XCTAssertTrue(app.buttons["일반"].waitForExistence(timeout: 15), app.debugDescription)
        let routes: [(String, String)] = [
            ("AI 엔진", "학습을 도와줄 AI 도구의 연결 상태를 확인합니다."),
            ("화면 도우미", "AI의 화면 도우미 동작을 관리합니다."),
            ("계정", "반달 프로필과 로그인 상태를 관리합니다."),
            ("일반", "언어와 기본 동작을 관리합니다."),
            ("학교", "학교 학사 사이트 바로가기를 관리합니다."),
            ("플러그인", "학습 도구, 확장과 외부 서비스를 한곳에서 관리합니다."),
            ("달력", "Apple 캘린더와 반달 일정을 연결합니다."),
            ("브라우저", "홈페이지·검색·확대/축소와 링크 동작을 관리합니다."),
            ("화면", "반달이 보이는 방식을 선택합니다."),
            ("탭", "마크다운·브라우저·AI·녹음·화이트보드·학업 보드의 기본 동작을 관리합니다."),
            ("위젯", "우측 사이드바의 위젯을 선택하고 정렬합니다."),
            ("알림", "마감·AI 응답·다운로드를 OS 알림으로 받습니다."),
            ("단축키", "반달과 웹뷰에서 사용할 키 조합을 관리합니다."),
            ("사용 통계", "제공자별 AI 사용량을 확인합니다."),
            ("시스템 권한", "반달 기능에 필요한 기기 권한을 확인합니다."),
            ("개인정보·진단", "데이터 처리와 진단 파일을 확인합니다."),
            ("고급", "데이터 위치와 로그·캐시·초기화를 관리합니다."),
            ("실험실", "아직 다듬고 있는 기능을 켜거나 끕니다."),
            ("과목", "반달에 등록된 과목을 한눈에 확인합니다."),
            ("정보", "반달의 버전을 확인하고 업데이트합니다.")
        ]
        for (label, description) in routes {
            let candidates = app.buttons.matching(identifier: label).allElementsBoundByIndex
            let button = try XCTUnwrap(candidates.last, "Missing original route: \(label)")
            // The settings navigation has its own scroller, separate from the
            // content panel. XCUITest first brings offscreen HTML buttons in view.
            if !button.isHittable || button.frame.maxY > app.frame.maxY - 110 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.82))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.30))
                for _ in 0..<4 where !button.isHittable || button.frame.maxY > app.frame.maxY - 110 { start.press(forDuration: 0.05, thenDragTo: end) }
            }
            button.tap()
            XCTAssertTrue(app.staticTexts[description].waitForExistence(timeout: 8), "Original route did not render: \(label)\n\(app.debugDescription)")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "반달 실행 연결을 확인해 주세요.")).firstMatch.exists, app.debugDescription)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "All 20 original settings routes completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
