import XCTest

/// The AI answer drawn from Markdown (`--native-ai-markdown-fixture`): headings, lists, a table,
/// TeX and code on screen, and a link that opens a browser tab of the app instead of Safari.
/// The captures are attached for a look; `--native-ai-markdown-stream-fixture` types the same answer in.
final class NativeAssistantMarkdownUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testRichAnswerDrawsAndItsLinkOpensAnAppTab() {
        let app = launch("light", ["--native-ai-answer-fixture", "--native-ai-markdown-fixture"])
        openNoteAndPanel(app)
        XCTAssertTrue(math(app).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["코드 복사"].exists, "The code block has its copy button")
        XCTAssertTrue(app.staticTexts["3주차 인터뷰 요약"].exists, "The heading is its own text: " + app.debugDescription)
        XCTAssertTrue(app.staticTexts["응답"].exists && app.staticTexts["80%"].exists, "The table's cells")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label BEGINSWITH %@", "**", "](", "|")).firstMatch.exists, "No raw Markdown on screen")
        sleep(1); attach(app, "answer-light")

        let link = app.links["팔레트 디자인 검색"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        link.tap()
        let address = app.textFields["native-browser-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15), "The link opened a browser tab in the app: " + app.debugDescription)
        XCTAssertEqual(app.state, .runningForeground, "Not handed to Safari")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "google.com"), object: address)], timeout: 15), .completed, "The search link's page: " + app.debugDescription)
        // The strip names its tabs' count; the note stays open beside the page.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-dock-tabs-", "2개")).firstMatch.exists, app.debugDescription)
        sleep(2); attach(app, "link-opened")
    }

    @MainActor func testRichAnswerDark() {
        let app = launch("dark", ["--native-ai-answer-fixture", "--native-ai-markdown-fixture"])
        openNoteAndPanel(app)
        XCTAssertTrue(math(app).waitForExistence(timeout: 15), app.debugDescription)
        sleep(1); attach(app, "answer-dark")
    }

    @MainActor func testRichAnswerInTheFullTab() {
        let app = launch("light", ["--native-ai-answer-fixture", "--native-ai-markdown-fixture"])
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription); add.tap()
        app.buttons["native-new-tab-chat"].tap()
        XCTAssertTrue(math(app).waitForExistence(timeout: 15), app.debugDescription)
        sleep(1); attach(app, "tab-bottom")
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "만족도 평균")).firstMatch.swipeDown(velocity: .fast)
        sleep(1); attach(app, "tab-top")
        // The text stays selectable: a long press offers the system's copy (복사하기 on a Korean simulator).
        let item = app.staticTexts["팔레트 위치는 의견이 갈림"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.press(forDuration: 1.2)
        let copy = app.menuItems.matching(NSPredicate(format: "label IN %@", ["복사하기", "복사", "Copy"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Selection and copy stay: " + app.debugDescription)
        attach(app, "tab-copy-menu")
    }

    /// Captures while the answer is typed in, for a look at half-written tables, lists and code.
    @MainActor func testStreamingAnswerCaptures() {
        let app = launch("light", ["--native-ai-markdown-stream-fixture"])
        openNoteAndPanel(app)
        let stop = app.buttons["native-chat-send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        // The fixture types the answer in again every few seconds; catch a run.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "보내기"), object: stop)], timeout: 30), .completed, app.debugDescription)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "응답 중지"), object: stop)], timeout: 30), .completed, app.debugDescription)
        var frame = 0
        while stop.label == "응답 중지" && frame < 40 {
            attach(app, String(format: "stream-%02d", frame)); frame += 1
            usleep(250_000)
        }
        XCTAssertGreaterThan(frame, 4, "Several captures while the answer was arriving")
        XCTAssertTrue(math(app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.links["팔레트 디자인 검색"].waitForExistence(timeout: 5), app.debugDescription)
        sleep(1); attach(app, "stream-finished")
    }

    /// A message row's identifier covers its children, so the display formula is found by its TeX.
    @MainActor private func math(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\\sigma")).firstMatch
    }

    @MainActor private func launch(_ appearance: String, _ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "-native.appearance", appearance, "--native-ai-catalog-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("디자인 스튜디오")
        app.buttons["native-create-course"].tap(); sleep(1)
        return app
    }

    @MainActor private func openNoteAndPanel(_ app: XCUIApplication) {
        let note = app.buttons["native-home-new-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription); note.tap(); app.confirmNewNote()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        let toggle = app.buttons["native-ai-rail-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if toggle.label == "AI 열기" { toggle.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-input"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
