import XCTest

/// Requires a simulator with the signed/ad-hoc app + extension installed and a
/// recent photo imported by `simctl addmedia` (Bandal Share Fixture.png). This
/// exercises Photos' real system share sheet, not an internal test-only sender.
final class NativeExternalShareUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPhotosShareChoosesCourseAndFolderAndImportsOnForeground() throws {
        guard ProcessInfo.processInfo.environment["BANDAL_PHOTOS_UI_FIXTURE"] == "1" else {
            throw XCTSkip("외부 Photos 공유 검증에는 App Group을 포함해 서명한 시뮬레이터 빌드, simctl addmedia 사진 fixture, BANDAL_PHOTOS_UI_FIXTURE=1 명시 opt-in이 필요합니다.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Share Destination")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 20))
        app.buttons["native-library-view-menu"].tap()
        let list = app.buttons["native-library-view-list"]
        if list.exists { list.tap() } else { app.buttons["목록"].tap() }
        app.buttons["native-library-create"].tap(); app.buttons["새 폴더"].tap()
        let folderName = app.textFields["native-name-input"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5)); folderName.tap(); folderName.typeText("Shared Photos")
        app.buttons["만들기"].tap()
        XCTAssertTrue(app.buttons["native-material-Shared Photos"].waitForExistence(timeout: 10))

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for title in ["Continue", "계속", "Start Using Photos", "사진 사용 시작"] {
            let button = photos.buttons[title]
            if button.waitForExistence(timeout: 2), button.isHittable { button.tap() }
        }
        for title in ["Library", "보관함", "All Photos", "모든 사진"] {
            let button = photos.buttons[title]
            if button.exists, button.isHittable { button.tap() }
        }
        let library = photos.cells["LibraryTab"]
        if library.exists, library.isHittable { library.tap() }
        // Photos can restore the previously opened photo across app launches.
        // Return through its observed Back control before selecting the fixture.
        let backToLibrary = photos.buttons["PUOneUpBarButtonItemIdentifierDone"]
        if backToLibrary.exists, backToLibrary.isHittable { backToLibrary.tap() }
        // On iPad the first collection cell belongs to the navigation sidebar.
        // Photos exposes the actual grid items as images, newest fixture last.
        let gridPhotos = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(gridPhotos.firstMatch.waitForExistence(timeout: 15), photos.debugDescription)
        let photo = gridPhotos.element(boundBy: gridPhotos.count - 1)
        let window = photos.windows.firstMatch
        let visible = photo.frame.intersection(window.frame)
        XCTAssertFalse(visible.isNull || visible.isEmpty, "Fixture photo must intersect the visible Photos window: \(photo.frame), \(window.frame)")
        XCTAssertGreaterThan(visible.width, 20)
        XCTAssertGreaterThan(visible.height, 20)
        // Photos' virtualized Image accessibility node can report not hittable
        // despite a fully visible thumbnail. Tap its observed on-screen center.
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.midX - window.frame.minX, dy: visible.midY - window.frame.minY)).tap()
        let share = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), photos.debugDescription)
        diagnostics("Photos 공유 버튼 선택 전", application: photos)
        share.tap()
        let activityList = photos.otherElements["ActivityListView"]
        let shareSheetAppeared = activityList.waitForExistence(timeout: 10)
        diagnostics("Photos 시스템 공유 시트", application: photos)
        XCTAssertTrue(shareSheetAppeared, "Photos must present the actual system share sheet")

        // The observed system share sheet exposes app icons as shareCell cells.
        // A Photos-wide button query instead finds the underlying photo's More
        // toolbar button and dismisses the share sheet before opening Bandal.
        let bandal = activityList.cells.matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR label == %@ OR label == %@)",
            "shareCell", "반달", "반달 노트", "Bandal")).firstMatch
        XCTAssertTrue(bandal.waitForExistence(timeout: 10), activityList.debugDescription)
        bandal.tap()
        let save = photos.buttons["bandal-share-save"]
        let extensionAppeared = save.waitForExistence(timeout: 15)
        diagnostics("반달 공유 확장 진입", application: photos)
        XCTAssertTrue(extensionAppeared, photos.debugDescription)
        let coursePicker = photos.buttons["bandal-share-course"]
        XCTAssertTrue(coursePicker.waitForExistence(timeout: 5)); coursePicker.tap()
        let courseDestination = photos.buttons["Share Destination"]
        XCTAssertTrue(courseDestination.waitForExistence(timeout: 5), photos.debugDescription)
        courseDestination.tap()
        let folderPicker = photos.buttons["bandal-share-folder"]
        XCTAssertTrue(folderPicker.waitForExistence(timeout: 5)); folderPicker.tap()
        let destination = photos.buttons["Shared Photos"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5), photos.debugDescription); destination.tap()
        screenshot("사진 앱에서 반달 과목과 폴더 선택")
        save.tap()
        XCTAssertTrue(photos.staticTexts["공유 자료를 보관했어요"].waitForExistence(timeout: 20), photos.debugDescription)
        photos.buttons["완료"].tap()

        app.activate()
        let folder = app.buttons["native-material-Shared Photos"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15), app.debugDescription); folder.tap()
        let imported = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-material-Shared Photos/")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20), app.debugDescription)
        let importedID = imported.identifier
        screenshot("외부 공유 자료가 선택한 폴더에 저장됨")
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 20))
        if !app.buttons[importedID].exists, app.buttons["native-material-Shared Photos"].exists { app.buttons["native-material-Shared Photos"].tap() }
        XCTAssertTrue(app.buttons[importedID].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-material-Shared Photos/")).count, 1, "Foreground/relaunch must not duplicate the shared photo")
    }

    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func diagnostics(_ name: String, application: XCUIApplication) {
        screenshot(name)
        let hierarchy = XCTAttachment(string: application.debugDescription)
        hierarchy.name = "\(name) 접근성 계층"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
