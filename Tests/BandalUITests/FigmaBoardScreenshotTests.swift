import XCTest

/// Captures of the study board in the states of Figma 학업 보드 P1–P9 (233:10943), light and dark, for a
/// side-by-side comparison with the frames. Each test only drives and attaches; behaviour is asserted in `NativeToolsFlowTests`.
final class FigmaBoardScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testBoardLight() throws { try capture("light") }
    @MainActor func testBoardDark() throws { try capture("dark") }

    @MainActor private func capture(_ appearance: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance, "-AppleLocale", "ko_KR", "-AppleLanguages", "(ko)"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 30), app.debugDescription)
        for (name, color) in [("디자인 스튜디오", "blue"), ("창업론 실습", "orange"), ("북한학개론", "green")] {
            app.buttons["native-course-add-menu"].tap()
            let field = app.textFields["native-course-name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
            app.buttons["native-course-color-" + color].tap(); app.buttons["native-create-course"].tap()
            XCTAssertTrue(app.buttons[name + " 폴더 메뉴"].waitForExistence(timeout: 10), app.debugDescription)
        }
        app.buttons["native-section-planner"].tap()
        let list = app.buttons["native-planner-board"]
        XCTAssertTrue(list.waitForExistence(timeout: 10)); list.tap()

        add("3주차 리서치 정리", course: "디자인 스튜디오", days: 1, timed: true, in: app)
        add("사업계획서 초안", course: "창업론 실습", days: 4, in: app)
        add("2장 읽고 요약", course: "북한학개론", days: 6, in: app)
        add("인터뷰 녹취 요약", course: "디자인 스튜디오", days: 2, column: "in-progress", in: app)
        add("시장 조사 표 만들기", course: "창업론 실습", days: 3, column: "in-progress", in: app)
        for (title, course) in [("시안 2종 비교", "디자인 스튜디오"), ("1장 퀴즈 풀기", "북한학개론"), ("팀 역할 나누기", "창업론 실습")] {
            add(title, course: course, days: nil, in: app)
            card(title, in: app).tap()
            XCTAssertTrue(app.buttons["native-task-status-done"].waitForExistence(timeout: 5)); app.buttons["native-task-status-done"].tap(); sleep(1)
        }
        attach(app, "P1 목록 \(appearance)")

        app.buttons["디자인 스튜디오 과목만 보기"].tap(); sleep(1)
        attach(app, "P4 과목 선택 \(appearance)")
        app.buttons["디자인 스튜디오 과목만 보기"].tap()

        card("3주차 리서치 정리", in: app).tap(); sleep(1)
        attach(app, "P5 카드 팝오버 \(appearance)")
        app.closeBandalPopover()

        fill("중간 발표 자료 만들기", course: "디자인 스튜디오", days: 3, in: app)
        app.buttons["native-task-reminder"].tap(); app.buttons["native-task-reminder-dayBefore"].tap(); sleep(1)
        attach(app, "P6 할 일 추가 \(appearance)")
        app.buttons["native-task-cancel"].tap()

        let hide = app.switches["native-planner-hide-done"]
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); sleep(1)
        attach(app, "P9 완료 숨기기 \(appearance)")
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        app.buttons["native-planner-calendar"].tap(); sleep(1)
        attach(app, "P2 달력 \(appearance)")
        app.buttons["native-planner-day-" + day(1)].tap(); sleep(1)
        attach(app, "P3 날짜 선택 \(appearance)")
        list.tap()

        XCUIDevice.shared.orientation = .portrait; sleep(2)
        attach(app, "P7 세로 \(appearance)")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)

        for title in ["발표 리허설", "인터뷰 질문지 수정", "재무 계획 표", "3장 읽고 요약", "기말 과제 주제 정하기", "팀 회의록 정리"] { add(title, course: "창업론 실습", days: 7, in: app) }
        attach(app, "P8 스크롤 \(appearance)")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        attach(app, "P8 스크롤 세로 \(appearance)")
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Opens 새 할 일 from a column and fills it in, leaving it open.
    @MainActor private func fill(_ title: String, course: String, days: Int?, column: String = "todo", timed: Bool = false, in app: XCUIApplication) {
        let add = app.buttons[column == "todo" ? "native-task-add" : "native-task-add-" + column]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
        let field = app.textFields["native-task-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription); field.tap(); field.typeText(title)
        let chip = app.buttons["과목 " + course]
        if !chip.isSelected { chip.tap() }
        if let days { app.buttons["native-task-due-" + day(days)].tap() }
        if timed {
            app.buttons["native-task-time"].tap()
            app.switches["native-task-all-day"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons["native-task-time"].tap()
            app.buttons["native-task-reminder"].tap(); app.buttons["native-task-reminder-dayBefore"].tap()
        }
    }
    @MainActor private func add(_ title: String, course: String, days: Int?, column: String = "todo", timed: Bool = false, in app: XCUIApplication) {
        fill(title, course: course, days: days, column: column, timed: timed, in: app)
        app.buttons["native-task-save"].tap()
        XCTAssertTrue(card(title, in: app).waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func card(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-task-edit-", title)).firstMatch
    }
    private func day(_ offset: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
