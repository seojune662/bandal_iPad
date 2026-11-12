import XCTest

/// Folders inside folders, 폴더 삭제 to 최근 삭제 and back, and no group feature left in the sidebar.
final class NativeFolderTreeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSubfolderDeleteAndRestore() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]; app.launch()
        createFolder("Semester", app: app)
        let menu = app.buttons["Semester 폴더 메뉴"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        XCTAssertFalse(app.buttons["그룹으로 이동"].exists, "groups are gone; folders hold folders")
        XCTAssertFalse(app.buttons["그룹 만들기"].exists)
        app.buttons["native-course-add-subfolder"].firstMatch.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Calculus")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(row("Calculus", app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["native-course-expand-" + (row("Semester", app).identifier.replacingOccurrences(of: "native-course-", with: ""))].waitForExistence(timeout: 10),
                      "a folder holding a folder shows its chevron")
        attach(app, "folder tree")

        row("Semester", app).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["폴더 삭제"].firstMatch.tap()
        let confirm = app.buttons["native-course-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row("Calculus", app))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the subtree goes with its folder")
        XCTAssertFalse(row("Semester", app).exists)

        app.buttons["native-course-add-menu"].press(forDuration: 1)
        app.buttons["폴더 관리"].firstMatch.tap()
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-manager-restore-course-")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "recently deleted")
        restore.tap()
        XCTAssertTrue(row("Semester", app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row("Calculus", app).waitForExistence(timeout: 10), "restoring the folder restores what was deleted with it")
    }

    @MainActor private func createFolder(_ name: String, app: XCUIApplication) {
        let add = app.buttons["native-course-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription); add.tap()
        let field = app.textFields["native-course-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(row(name, app).waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func row(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND label CONTAINS %@", "native-course-", "native-course-expand-", name)).firstMatch
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
