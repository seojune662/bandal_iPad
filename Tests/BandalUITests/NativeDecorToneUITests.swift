import XCTest

/// The 새 노트 sheet, the ＋ menu's even rows, and a picture of each surface the decor tones: the empty
/// workspace, and a PDF, a note, a web page and an AI tab on their cards, at the default dial and at its top.
final class NativeDecorToneUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testNewNoteSheetAsksForPaperAndCancelMakesNothing() throws {
        let app = launch(extra: ["-native.appearance", "light"])
        createFolder("Tone", app: app)
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-"))
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription)
        attach(app, "1 empty workspace")

        // 새 노트 asks first; 취소 makes nothing.
        home.tap()
        let create = app.buttons["native-new-note-create"], title = app.textFields["native-new-note-title"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(title.exists)
        for id in ["blank", "lines", "grid", "dots"] { XCTAssertTrue(app.buttons["native-new-note-paper-" + id].exists, id) }
        XCTAssertTrue(app.buttons["native-new-note-paper-lines"].isSelected, "줄 is the paper a note starts with")
        XCTAssertTrue(app.buttons["native-new-note-portrait"].isSelected)
        attach(app, "2 new note sheet")
        app.buttons["native-new-note-cancel"].tap()
        XCTAssertTrue(waitForDisappearance(create), app.debugDescription)
        XCTAssertEqual(tabs.count, 0, "Cancelling makes no note")

        // The answers go into the note: a named note on grid paper, lying on its side.
        home.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["native-new-note-paper-grid"].tap(); app.buttons["native-new-note-landscape"].tap()
        XCTAssertTrue(app.buttons["native-new-note-paper-grid"].isSelected); XCTAssertTrue(app.buttons["native-new-note-landscape"].isSelected)
        title.tap(); title.typeText("Grid")
        create.tap()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(tabs.matching(NSPredicate(format: "label CONTAINS %@", "Grid")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let page = app.descendants(matching: .any)["native-pdf-workspace"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        sleep(2); attach(app, "3 pdf tab")
        app.buttons["native-pdf-pages"].tap(); sleep(1); attach(app, "4 pdf tab with thumbnails"); app.buttons["native-pdf-pages"].tap()

        // ＋ › 노트 asks the same; an untitled note takes the dated name.
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap()
        XCTAssertTrue(app.buttons["native-new-tab-new-whiteboard"].waitForExistence(timeout: 5), app.debugDescription)
        sleep(1); attach(app, "5 plus menu")
        app.buttons["native-new-tab-new-whiteboard"].tap()
        app.confirmNewNote()
        XCTAssertTrue(tabs.matching(NSPredicate(format: "label BEGINSWITH %@", "노트 20")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)

        for (index, action) in ["new-note", "new-browser", "chat"].enumerated() {
            plus.tap()
            let item = app.buttons["native-new-tab-" + action]
            XCTAssertTrue(item.waitForExistence(timeout: 5), action + app.debugDescription); item.tap()
            sleep(4); attach(app, "\(index + 6) " + action)
        }
    }

    /// The dial's top, a folder inside a folder and its guide line.
    @MainActor func testLoudestDecorAndFolderTree() throws {
        let app = launch(extra: ["-native.appearance", "light", "-native.decor.intensity", "2", "-native.decor.palette", "ocean"])
        createFolder("Semester", app: app)
        let menu = app.buttons["Semester 폴더 메뉴"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        app.buttons["native-course-add-subfolder"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Calculus")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-course-", "Calculus")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // An open folder with no favourite says what can go there.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-favorite-empty-")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1); attach(app, "1 folder tree at the dial's top")
        let home = app.buttons["native-home-new-note"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote()
        XCTAssertTrue(app.buttons["native-pdf-tool-pen"].waitForExistence(timeout: 20), app.debugDescription)
        sleep(2); attach(app, "2 pdf tab at the dial's top")
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-browser-ui-fixture"] + extra
        app.launch()
        return app
    }
    @MainActor private func createFolder(_ name: String, app: XCUIApplication) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
    }
    @MainActor private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 5) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // A landscape capture of the whole screen comes out rotated and cropped; the window does not.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
