import XCTest

/// Produces the five App Store screenshots from real flows with Korean demo content.
/// Export with `xcrun xcresulttool export attachments --path X.xcresult --output-path DIR`.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testCaptureStoreScreenshots() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--native-pencil-dispatch-fixture", "--reset-native-ui-testing"]
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25), app.debugDescription)
        addCourse.tap(); app.buttons["native-new-course"].tap()
        let courseName = app.textFields["native-course-name"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5)); paste("선형대수학", into: courseName, app: app)
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        waitEnabled(create, app: app)

        // 1. Handwriting note on grid paper: a highlighted heading, "Av = λv" with
        // a 2×2 matrix, and an axes diagram showing v and Av (lines approximate ink).
        create.tap(); app.buttons["새 노트"].tap()
        let noteTitle = app.textFields["native-new-note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5)); paste("3주차 고유값과 고유벡터", into: noteTitle, app: app)
        app.buttons["모눈"].tap(); app.buttons["native-new-note-create"].tap()
        let pdf = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), app.debugDescription)
        waitEnabled(app.buttons["native-pdf-tool-pen"], app: app)
        var inkCount = 0
        func ink(_ segments: [((Double, Double), (Double, Double))]) {
            for segment in segments { stroke(pdf, from: segment.0, to: segment.1); inkCount += 1 }
        }
        tool("highlighter", app: app)
        ink([((0.12, 0.12), (0.46, 0.12))])
        tool("pen", app: app)
        // Heading underline + "Av = λv": A (two legs + bar), v, =, λ, v
        ink([((0.12, 0.15), (0.46, 0.15))])
        ink([((0.14, 0.30), (0.17, 0.22)), ((0.17, 0.22), (0.20, 0.30)), ((0.155, 0.27), (0.185, 0.27))])   // A
        ink([((0.22, 0.25), (0.24, 0.30)), ((0.24, 0.30), (0.26, 0.25))])                                   // v
        ink([((0.29, 0.255), (0.33, 0.255)), ((0.29, 0.275), (0.33, 0.275))])                               // =
        ink([((0.36, 0.22), (0.41, 0.30)), ((0.385, 0.26), (0.355, 0.30))])                                 // λ
        ink([((0.43, 0.25), (0.45, 0.30)), ((0.45, 0.30), (0.47, 0.25))])                                   // v
        // 2×2 matrix with brackets and a fraction-style eigenvalue note
        ink([((0.14, 0.38), (0.14, 0.52)), ((0.14, 0.38), (0.16, 0.38)), ((0.14, 0.52), (0.16, 0.52))])    // [
        ink([((0.30, 0.38), (0.30, 0.52)), ((0.28, 0.38), (0.30, 0.38)), ((0.28, 0.52), (0.30, 0.52))])    // ]
        ink([((0.18, 0.41), (0.21, 0.41)), ((0.21, 0.41), (0.18, 0.45)), ((0.18, 0.45), (0.21, 0.45))])    // 2
        ink([((0.245, 0.41), (0.265, 0.41)), ((0.265, 0.41), (0.245, 0.45)), ((0.245, 0.45), (0.265, 0.45)), ((0.245, 0.43), (0.26, 0.43))]) // 3-ish
        ink([((0.18, 0.47), (0.19, 0.51)), ((0.19, 0.51), (0.21, 0.47))])                                   // v entry
        ink([((0.245, 0.47), (0.265, 0.47)), ((0.265, 0.47), (0.245, 0.51))])                               // 7-ish
        ink([((0.34, 0.44), (0.40, 0.44)), ((0.36, 0.40), (0.38, 0.40)), ((0.37, 0.46), (0.37, 0.50))])    // fraction bar, numerator, denominator
        // Axes diagram on the right: x/y axes with arrowheads, v, Av and a dashed-looking projection
        ink([((0.56, 0.52), (0.90, 0.52)), ((0.90, 0.52), (0.87, 0.50)), ((0.90, 0.52), (0.87, 0.54))])    // x axis
        ink([((0.60, 0.56), (0.60, 0.18)), ((0.60, 0.18), (0.58, 0.21)), ((0.60, 0.18), (0.62, 0.21))])    // y axis
        ink([((0.60, 0.52), (0.72, 0.42)), ((0.72, 0.42), (0.69, 0.42)), ((0.72, 0.42), (0.72, 0.45))])    // v
        ink([((0.60, 0.52), (0.86, 0.30)), ((0.86, 0.30), (0.82, 0.31)), ((0.86, 0.30), (0.85, 0.34))])    // Av
        ink([((0.72, 0.42), (0.72, 0.52)), ((0.86, 0.30), (0.86, 0.52))])                                   // projections
        ink([((0.74, 0.40), (0.76, 0.36)), ((0.76, 0.36), (0.78, 0.40))])                                   // label tick near v
        ink([((0.64, 0.60), (0.88, 0.60)), ((0.64, 0.64), (0.80, 0.64))])                                   // caption lines
        expectInk(inkCount, app: app)
        capture("01-pdf-handwriting", app: app)

        // 2. Markdown note with a table and a formula
        create.tap(); app.buttons["새 마크다운"].tap()
        let mdTitle = app.textFields["native-name-input"]
        XCTAssertTrue(mdTitle.waitForExistence(timeout: 5)); paste("3주차 정리", into: mdTitle, app: app)
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["native-markdown-source-toggle"].tap()
        paste(Self.markdown, into: editor, app: app)
        app.buttons["native-markdown-source-toggle"].tap()
        app.dismissNativeTestKeyboard()
        let done = app.buttons["완료"].firstMatch
        if done.exists && done.isHittable { done.tap() }
        capture("02-markdown-note", app: app)

        // 3. Handwriting and note side by side
        let menu = app.buttons["native-open-documents"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let columns = app.buttons["native-dock-preset-columns"]
        XCTAssertTrue(columns.waitForExistence(timeout: 5), app.debugDescription); columns.tap()
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].waitForExistence(timeout: 10))
        capture("03-split-workspace", app: app)

        // 4. Planner board
        app.buttons["native-section-planner"].tap()
        let board = app.buttons["native-planner-board"]
        XCTAssertTrue(board.waitForExistence(timeout: 10)); board.tap()
        for task in ["선형대수 과제 2장 제출", "고유값 증명 복습", "중간고사 범위 정리"] {
            let add = app.buttons["native-task-add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription); add.tap()
            let title = app.textFields["native-task-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5)); paste(task, into: title, app: app)
            app.buttons["native-task-save"].tap()
        }
        app.dismissNativeTestKeyboard()
        capture("04-planner", app: app)

        // 5. Settings (close the board overlay first)
        app.buttons["native-section-planner"].tap()
        app.buttons["native-section-settings"].tap()
        XCTAssertTrue(app.buttons["native-settings-theme-system"].waitForExistence(timeout: 10), app.debugDescription)
        capture("05-settings", app: app)
    }

    private static let markdown = #"""
    ## 고유값과 고유벡터

    - 정의: $Av = \lambda v$, $v \neq 0$
    - 특성방정식 $\det(A - \lambda I) = 0$ 의 근이 고유값
    - 대칭행렬은 항상 직교 대각화 가능

    | 행렬 | 고유값 | 고유벡터 |
    | --- | --- | --- |
    | 대각행렬 diag(2, 3) | 2, 3 | $e_1$, $e_2$ |
    | 교환행렬 | 1, −1 | (1, 1), (1, −1) |

    > 중간고사 범위: 3장 전체, 과제 2번 다시 풀기
    """#

    @MainActor private func paste(_ text: String, into element: XCUIElement, app: XCUIApplication) {
        element.tap()
        element.typeText(text)
    }
    @MainActor private func waitEnabled(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 20) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, app.debugDescription)
    }
    @MainActor private func tool(_ name: String, app: XCUIApplication) {
        let item = app.buttons["native-pdf-tool-" + name]
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        if item.isSelected { return }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        item.tap()
    }
    @MainActor private func stroke(_ pdf: XCUIElement, from: (Double, Double), to: (Double, Double)) {
        let start = pdf.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let end = pdf.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    @MainActor private func expectInk(_ count: Int, app: XCUIApplication) {
        let status = app.buttons["native-pdf-drawing-tools"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "drawings=\(count) pending=0"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1.5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
