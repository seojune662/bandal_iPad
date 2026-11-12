import XCTest
import UIKit

/// Separate storage from the existing native suites. Every scenario creates its
/// resources through production UI; only the browser page uses local HTML.
final class NativeWorkspaceWindowsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEmptyOverviewEscapeReturnsWithoutOpeningAnEditor() throws {
        let app = launch()
        createCourse("Empty Escape", app: app)
        openOverview(app); expectCards(1, app: app)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        wait(app, "Escape closes an overview with no editor or browser session") { !self.overview(app).exists }
        XCTAssertTrue(app.buttons["native-workspace-windows-toggle"].isEnabled)
        openOverview(app); expectCards(1, app: app)
    }

    @MainActor
    func testWindowCardCloseButtonAsksThenClosesAndTheLastWindowHasNone() throws {
        let app = launch()
        createCourse("Close Course", app: app)
        let closers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-window-close-"))
        openOverview(app); expectCards(1, app: app)
        XCTAssertEqual(closers.count, 0, "The only window cannot be closed, so its card has no ✕")
        addWindow(app)
        openOverview(app); expectCards(2, app: app)
        XCTAssertEqual(closers.count, 2, app.debugDescription)
        capture(app, "Window cards with their close buttons")
        closers.element(boundBy: 1).tap()
        let confirm = app.buttons["native-window-close-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        // Tapping away keeps the window.
        app.closeBandalPopover(); expectCards(2, app: app)
        closers.element(boundBy: 1).tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
        expectCards(1, app: app)
        XCTAssertEqual(closers.count, 0)
    }

    @MainActor
    func testSidebarListsTheFolderWindowsAndSwitchesAndClosesThem() throws {
        let app = launch()
        createCourse("Sidebar Windows", app: app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)", "native-sidebar-window-",
                                                    ["native-sidebar-window-add", "native-sidebar-window-close-confirm"]))
        wait(app, "The folder's one window is listed under it") { rows.count == 1 && rows.element(boundBy: 0).isSelected }
        // ＋ makes a window and goes to it.
        app.buttons["native-sidebar-window-add"].tap()
        wait(app, "The new window is listed and current") { rows.count == 2 && rows.element(boundBy: 1).isSelected && !rows.element(boundBy: 0).isSelected }
        // A tap goes back to the first.
        rows.element(boundBy: 0).tap()
        wait(app, "The first window is current again") { rows.element(boundBy: 0).isSelected && !rows.element(boundBy: 1).isSelected }
        capture(app, "The folder's windows in the sidebar")
        // The overview stays, with the same windows.
        openOverview(app); expectCards(2, app: app)
        app.buttons["native-workspace-windows-toggle"].tap()
        wait(app, "The overview closes") { !self.overview(app).exists }
        // Long press › 윈도우 닫기 asks, then closes it.
        rows.element(boundBy: 1).press(forDuration: 1)
        let close = app.buttons["윈도우 닫기"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription); close.tap()
        let confirm = app.buttons["native-sidebar-window-close-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
        wait(app, "One window is left") { rows.count == 1 && rows.element(boundBy: 0).isSelected }
    }

    /// A tab's menu makes every move a tab drag does.
    /// (Moving to another window is covered in `NativeWorkspaceWindowTests`: while a tab's menu is up the test
    /// runner waits a minute for the app to idle before every step, so this taps only one item.)
    @MainActor
    func testTabMenuOffersTheMovesAndSplitsTheTabOut() throws {
        let app = launch()
        createCourse("Tab Moves", app: app)
        let home = app.buttons["native-home-new-note"], pen = app.buttons["native-pdf-tool-pen"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription); home.tap(); app.confirmNewNote(title: "One")
        XCTAssertTrue(pen.waitForExistence(timeout: 20), app.debugDescription)
        let plus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap(); app.buttons["native-new-tab-new-whiteboard"].tap(); app.confirmNewNote(title: "Two")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-document-tab-"))
        let strips = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-tab-strip-"))
        wait(app, "Two tabs in one pane") { tabs.count == 2 && strips.count == 1 }

        tabs.element(boundBy: 1).press(forDuration: 1)
        let split = app.buttons["native-tab-split-right"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), app.debugDescription)
        for item in ["native-tab-split-below", "다른 윈도우로 이동", "왼쪽으로 옮기기", "즐겨찾기에 추가"] { XCTAssertTrue(app.buttons[item].exists, item) }
        split.tap()
        wait(app, "The tab took a pane of its own") { strips.count == 2 && tabs.count == 2 }
    }

    @MainActor
    func testWindowManagementCourseProjectIsolationAndRestartKeepSidebarState() throws {
        let app = launch()
        createCourse("Windows Course", app: app)
        openOverview(app); expectCards(1, app: app)
        renameWindow("윈도우 1", to: "강의", app: app)
        addWindow(app)
        openOverview(app); expectCards(2, app: app)
        renameWindow("윈도우 2", to: "문제 풀이", app: app)
        app.buttons["문제 풀이 열기"].press(forDuration: 1); app.buttons["앞으로 이동"].tap()
        wait(app, "Reordered window is first") { self.cards(app).firstMatch.label == "문제 풀이 열기" }
        app.buttons["강의 열기"].press(forDuration: 1); app.buttons["윈도우 닫기"].tap()
        expectCards(1, app: app)
        XCTAssertEqual(cards(app).firstMatch.label, "문제 풀이 열기")
        chooseWindow("문제 풀이", app: app)

        openHome(app)
        app.buttons["native-course-add-menu"].tap()
        let projectName = app.textFields["native-course-name"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 5)); projectName.tap(); projectName.typeText("Window Project")
        app.buttons["native-create-course"].tap()
        waitEnabled(app.buttons["native-workspace-windows-toggle"], app: app)
        openOverview(app); expectCards(1, app: app)
        XCTAssertEqual(cards(app).firstMatch.label, "윈도우 1 열기")
        addWindow(app)
        openOverview(app); expectCards(2, app: app)
        renameWindow("윈도우 2", to: "프로젝트 작업", app: app)
        chooseWindow("프로젝트 작업", app: app)

        openHome(app)
        let course = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "native-course-", "Windows Course")).firstMatch
        XCTAssertTrue(course.waitForExistence(timeout: 5)); course.tap()
        openOverview(app); expectCards(1, app: app)
        XCTAssertEqual(cards(app).firstMatch.label, "문제 풀이 열기")
        chooseWindow("문제 풀이", app: app)
        setInspector(open: false, app: app)
        changeMode("탭만 숨김", app: app)
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        waitEnabled(app.buttons["native-workspace-windows-toggle"], app: app)
        XCTAssertEqual(app.buttons["native-toggle-materials-rail"].label, "오른쪽 패널 펼치기")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch.exists)
        openOverview(app); expectCards(1, app: app)
        XCTAssertEqual(cards(app).firstMatch.label, "문제 풀이 열기")
        capture(app, "Restored course window with closed inspector")
    }

    @MainActor
    func testThreeChromeModesRecoverSpaceKeepPencilToolsAndFixedControls() throws {
        let app = launch()
        createCourse("Chrome Course", app: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let title = app.textFields["native-new-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Window Pencil Notes")
        app.buttons["native-new-note-create"].tap()
        // The general PDF tools are the thumbnails button (and the menu its long press opens).
        let pen = app.buttons["native-pdf-tool-pen"], general = app.buttons["native-pdf-pages"]
        waitEnabled(pen, app: app)
        XCTAssertTrue(general.exists)
        let fixedFrame = controls(app).frame
        let pdf = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        let originalTop = pdf.frame.minY
        XCTAssertTrue(app.buttons["native-close-document"].exists)

        changeMode("탭만 숨김", app: app)
        wait(app, "Tab controls leave the accessibility tree") { !app.buttons["native-close-document"].exists }
        XCTAssertTrue(general.exists, "General PDF tools remain in tabs-only mode")
        XCTAssertTrue(pen.isHittable)
        XCTAssertLessThan(pdf.frame.minY, originalTop)
        assertFixedControls(fixedFrame, app: app)
        changeMode("탭·일반 도구 숨김", app: app)
        wait(app, "General PDF tools leave in immersion mode") { !general.exists }
        XCTAssertFalse(app.buttons["native-close-document"].exists)
        XCTAssertTrue(pen.isHittable, "Writing tools remain directly reachable in immersion mode")
        XCTAssertTrue(app.buttons["native-pdf-tool-eraser"].exists)
        assertFixedControls(fixedFrame, app: app)
        setInspector(open: false, app: app); assertFixedControls(fixedFrame, app: app)
        setInspector(open: true, app: app); assertFixedControls(fixedFrame, app: app)
        changeMode("모두 표시", app: app)
        wait(app, "Restored toolbar and tab") { general.exists && app.buttons["native-close-document"].exists }
        XCTAssertEqual(pdf.frame.minY, originalTop, accuracy: 1)
        XCTAssertTrue(pen.isHittable)
        capture(app, "PDF controls restored without moving the fixed capsule")

        let trailingInset = app.frame.maxX - controls(app).frame.maxX
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            wait(app, "Rotation finishes before checking the fixed controls") {
                orientation == .portrait ? app.frame.height > app.frame.width : app.frame.width > app.frame.height
            }
            setInspector(open: true, app: app)
            waitEnabled(app.buttons["native-toggle-materials-rail"], app: app)
            XCTAssertEqual(app.frame.maxX - controls(app).frame.maxX, trailingInset, accuracy: 1,
                           "The capsule keeps the same inset from the screen's right edge")
            // The design's group is 128 × 40: cells of 36 · 36 · 34.
            for id in ["native-workspace-chrome-menu", "native-workspace-windows-toggle", "native-toggle-materials-rail"] {
                let button = app.buttons[id]
                XCTAssertGreaterThanOrEqual(button.frame.width, 34, id)
                XCTAssertGreaterThanOrEqual(button.frame.height, 40, id)
                XCTAssertTrue(button.isHittable, id)
            }
            let inspectorHeader = app.buttons["native-inspector-materials"]
            XCTAssertTrue(inspectorHeader.isHittable)
            XCTAssertGreaterThanOrEqual(inspectorHeader.frame.minY, controls(app).frame.maxY,
                                        "The open inspector starts below the fixed capsule")
            capture(app, orientation == .portrait ? "Portrait fixed controls above inspector" : "Landscape fixed controls above inspector")
        }
    }

    @MainActor
    func testSameNoteSharesContentButKeepsIndependentPanelModeAcrossWindows() throws {
        let app = launch()
        createCourse("Shared Note Course", app: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let title = app.textFields["native-name-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Shared Window Note")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); editor.tap(); editor.typeText("\nOriginal shared content.")
        app.dismissNativeTestKeyboard()
        // The bar's value names the pane's mode; the toggle itself is in the ⋯ menu.
        let sourceMode = app.descendants(matching: .any).matching(identifier: "native-markdown-toolbar").firstMatch
        app.toggleNativeMarkdownSource()
        XCTAssertEqual(sourceMode.value as? String, "Markdown 원문")
        changeMode("탭만 숨김", app: app)
        openOverview(app); expectCards(1, app: app)
        XCTAssertFalse(app.textViews.matching(identifier: "native-markdown-editor").allElementsBoundByIndex.contains { $0.isHittable }, "The overview cannot type into retained editors")
        addWindow(app)
        setInspector(open: true, app: app)
        let material = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "Shared Window Note")).firstMatch
        XCTAssertTrue(material.waitForExistence(timeout: 10)); material.tap()
        wait(app, "Second panel reads the same resource") { editor.exists && (editor.value as? String ?? "").contains("Original shared content.") }
        XCTAssertEqual(sourceMode.value as? String, "서식 편집", "Source mode belongs to the panel, not the shared document")
        XCTAssertTrue(app.buttons["native-close-document"].exists, "The second window starts with its own all-visible mode")
        editor.tap(); editor.typeText("\nEdited in the second window.")
        app.dismissNativeTestKeyboard()
        openOverview(app); chooseWindow("윈도우 1", app: app)
        wait(app, "Original panel observes the shared edit") { editor.exists && (editor.value as? String ?? "").contains("Edited in the second window.") }
        XCTAssertEqual(sourceMode.value as? String, "Markdown 원문")
        XCTAssertFalse(app.buttons["native-close-document"].exists)
        openOverview(app); chooseWindow("윈도우 2", app: app)
        XCTAssertEqual(sourceMode.value as? String, "서식 편집")
        app.terminate(); app.launchArguments = arguments(reset: false); app.launch()
        wait(app, "Shared content and selected window restore") { editor.exists && (editor.value as? String ?? "").contains("Edited in the second window.") }
        openOverview(app); expectCards(2, app: app)
        capture(app, "Two views of one saved Markdown resource")
    }

    @MainActor
    func testBrowserOverviewEscapePreservesLiveForm() throws {
        let (app, input) = launchBrowserForm()
        let originalWorkTabCount = app.buttons.matching(identifier: "native-close-document").count
        openOverview(app)
        XCTAssertFalse(app.webViews.allElementsBoundByIndex.contains { $0.isHittable }, "The overview must hide the live website and its input")
        expectCards(1, app: app)
        // Keep Escape as a required independent scenario, so a keyboard
        // regression cannot prevent the privacy and preview checks below.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        wait(app, "Escape returns to the existing working window") { !self.overview(app).exists }
        XCTAssertEqual(app.buttons.matching(identifier: "native-close-document").count, originalWorkTabCount)
        wait(app, "Escape preserves the live website form") {
            input.exists && (input.value as? String) == "Keep the live website form"
        }
        openOverview(app); expectCards(1, app: app)
    }

    @MainActor
    func testBrowserOverviewRetainsFormsAndMasksPrivatePreview() throws {
        let extra = ["--native-browser-ui-fixture"]
        let (app, input) = launchBrowserForm()
        let originalWorkTabCount = app.buttons.matching(identifier: "native-close-document").count
        openOverview(app)
        XCTAssertFalse(app.webViews.allElementsBoundByIndex.contains { $0.isHittable }, "The overview must hide the live website and its input")
        expectCards(1, app: app)
        app.typeKey("q", modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        expectCards(1, app: app)
        XCTAssertTrue(overview(app).exists, "Command-W cannot close the hidden working document from the overview")
        app.buttons["native-workspace-windows-toggle"].tap()
        wait(app, "Close returns after blocked overview input") { !self.overview(app).exists }
        XCTAssertEqual(app.buttons.matching(identifier: "native-close-document").count, originalWorkTabCount)
        wait(app, "The work tab and website form survive Command-W in the overview") {
            input.exists && (input.value as? String) == "Keep the live website form"
        }
        openOverview(app); expectCards(1, app: app)
        capture(app, "Public website composed into the actual window preview")
        chooseWindow("윈도우 1", app: app)
        wait(app, "Original WebKit form survives overview") { input.exists && (input.value as? String) == "Keep the live website form" }
        let profile = app.buttons["native-browser-profile"].firstMatch
        if profile.exists && profile.isHittable { profile.tap() }
        else {
            app.buttons["native-browser-menu"].firstMatch.tap()
            let item = app.buttons["native-browser-profile-menu-item"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        }
        app.buttons["native-browser-private-toggle"].tap()
        wait(app, "Private page becomes active") {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-browser-profile", "개인정보 보호")).firstMatch.exists
        }
        openOverview(app); expectCards(1, app: app)
        XCTAssertFalse(app.webViews.allElementsBoundByIndex.contains { $0.isHittable })
        let image = cards(app).firstMatch.screenshot().image
        let color = try XCTUnwrap(previewPatch(image))
        // The capture's opaque secondarySystemBackground is (242,242,247) in
        // the forced light fixture. The central upper patch avoids the mask's
        // label and card letterboxing; white website pixels must not remain.
        XCTAssertTrue((236...248).contains(color.red), "Private preview is not masked: \(color)")
        XCTAssertTrue((236...248).contains(color.green), "Private preview is not masked: \(color)")
        XCTAssertTrue((240...252).contains(color.blue), "Private preview is not masked: \(color)")
        capture(app, "Private website content covered in the persisted preview")
        app.terminate(); app.launchArguments = arguments(reset: false, extra: extra); app.launch()
        waitEnabled(app.buttons["native-workspace-windows-toggle"], app: app)
        openOverview(app); expectCards(1, app: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    @MainActor private func launchBrowserForm() -> (XCUIApplication, XCUIElement) {
        let app = launch(extra: ["--native-browser-ui-fixture"])
        createCourse("Browser Windows", app: app)
        setInspector(open: false, app: app)
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Native browser fixture"].waitForExistence(timeout: 15), app.debugDescription)
        let input = page.textFields["Website input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Keep the live website form")
        app.dismissNativeTestKeyboard()
        return (app, input)
    }

    @MainActor private func arguments(reset: Bool, extra: [String] = []) -> [String] {
        ["--native-ui-testing", "--native-workspace-windows-ui-suite", "-native.appearance", "light"] + (reset ? ["--reset-native-ui-testing"] : []) + extra
    }
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = arguments(reset: true, extra: extra); app.launch()
        XCTAssertTrue(app.buttons["native-section-library"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    @MainActor private func createCourse(_ name: String, app: XCUIApplication) {
        openHome(app)
        app.buttons["native-course-add-menu"].tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        setInspector(open: true, app: app)
        waitEnabled(app.buttons["native-library-create"], app: app)
    }
    @MainActor private func openHome(_ app: XCUIApplication) {
        if !app.buttons["native-course-add-menu"].isHittable { app.buttons["native-section-library"].tap() }
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func setInspector(open: Bool, app: XCUIApplication) {
        let toggle = app.buttons["native-toggle-materials-rail"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let expected = open ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기"
        if toggle.label != expected { toggle.tap() }
        wait(app, "Inspector state") { toggle.label == expected }
        if open {
            let materials = app.buttons["native-inspector-materials"]
            XCTAssertTrue(materials.waitForExistence(timeout: 5)); materials.tap()
        }
    }
    @MainActor private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-window-open-"))
    }
    @MainActor private func overview(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "native-windows-overview").firstMatch
    }
    @MainActor private func controls(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "native-workspace-controls").firstMatch
    }
    @MainActor private func openOverview(_ app: XCUIApplication) {
        if !overview(app).exists {
            let toggle = app.buttons["native-workspace-windows-toggle"]
            waitEnabled(toggle, app: app); toggle.tap()
        }
        XCTAssertTrue(overview(app).waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func expectCards(_ count: Int, app: XCUIApplication) {
        wait(app, "Expected \(count) window cards") { self.cards(app).count == count }
    }
    @MainActor private func addWindow(_ app: XCUIApplication) {
        app.buttons["native-window-add"].tap()
        wait(app, "New window opens immediately") { !self.overview(app).exists }
    }
    @MainActor private func chooseWindow(_ name: String, app: XCUIApplication) {
        let card = cards(app).matching(NSPredicate(format: "label == %@", name + " 열기")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription); card.tap()
        wait(app, "Selected window opens") { !self.overview(app).exists }
    }
    @MainActor private func renameWindow(_ old: String, to name: String, app: XCUIApplication) {
        app.buttons[old + " 이름 변경"].tap()
        let field = app.textFields["native-window-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let previous = field.value as? String ?? old
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        field.typeText(name)
        XCTAssertEqual(field.value as? String, name)
        field.typeText("\n")
        XCTAssertTrue(app.buttons[name + " 이름 변경"].waitForExistence(timeout: 5), app.debugDescription)
    }
    @MainActor private func changeMode(_ title: String, app: XCUIApplication) {
        let menu = app.buttons["native-workspace-chrome-menu"]
        waitEnabled(menu, app: app); menu.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription); choice.tap()
    }
    @MainActor private func assertFixedControls(_ expected: CGRect, app: XCUIApplication) {
        XCTAssertTrue(controls(app).exists)
        XCTAssertEqual(controls(app).frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(controls(app).frame.minY, expected.minY, accuracy: 1)
        for id in ["native-workspace-chrome-menu", "native-workspace-windows-toggle", "native-toggle-materials-rail"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
        }
    }
    @MainActor private func waitEnabled(_ element: XCUIElement, app: XCUIApplication) {
        wait(app, "Control is enabled") { element.exists && element.isEnabled && element.isHittable }
    }
    @MainActor private func wait(_ app: XCUIApplication, _ message: String, condition: @escaping () -> Bool) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 20), .completed, message + "\n" + app.debugDescription)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func previewPatch(_ image: UIImage) -> (red: Int, green: Int, blue: Int)? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let pixels = normalized.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = pixels.width, height = pixels.height
        guard width > 20, height > 20 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard decoded else { return nil }
        var red = 0, green = 0, blue = 0, count = 0
        for y in (height * 25 / 100)..<(height * 35 / 100) {
            for x in (width * 46 / 100)..<(width * 54 / 100) {
                let offset = (y * width + x) * 4
                red += Int(rgba[offset]); green += Int(rgba[offset + 1]); blue += Int(rgba[offset + 2]); count += 1
            }
        }
        guard count > 0 else { return nil }
        return (red / count, green / count, blue / count)
    }
}
