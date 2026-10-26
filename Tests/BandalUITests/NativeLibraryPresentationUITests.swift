import XCTest

final class NativeLibraryPresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMaterialViewsPersistAndSourceTrayStaysAvailable() throws {
        XCTExpectFailure("Known failure since 1.1.0: column view's nested item is not hittable on first open.", strict: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-course-add-menu"].tap()
        app.buttons["native-new-course"].tap()
        let courseName = app.textFields["native-course-name"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5))
        courseName.tap(); courseName.typeText("Library Views")
        app.buttons["native-create-course"].tap()
        let create = app.buttons["native-library-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), app.debugDescription)
        chooseView("icons", title: "아이콘", in: app)
        createFolder("Parent", path: "Parent", in: app)
        app.buttons["native-material-Parent"].tap()
        createFolder("Child", path: "Parent/Child", in: app)
        app.buttons["native-material-Parent/Child"].tap()
        create.tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("View Preview")
        app.buttons["native-new-note-create"].tap()
        XCTAssertTrue(app.otherElements["native-pdf-workspace"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-close-document"].tap()

        chooseView("icons", title: "아이콘", in: app)
        let material = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "native-material-", "View Preview")).firstMatch
        XCTAssertTrue(material.waitForExistence(timeout: 10), app.debugDescription)
        screenshot("자료 아이콘 보기")
        chooseView("columns", title: "열", in: app)
        XCTAssertTrue(material.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(material.isHittable, "Column mode should initially reveal the current nested folder")
        screenshot("자료 열 보기")
        chooseView("list", title: "목록", in: app)
        XCTAssertTrue(material.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(material.isHittable, "Switching to the tree must expand Parent/Child instead of hiding the current folder")
        chooseView("gallery", title: "갤러리", in: app)
        XCTAssertTrue(app.buttons["native-library-gallery-preview"].waitForExistence(timeout: 10), app.debugDescription)
        screenshot("자료 갤러리 보기")
        XCTAssertTrue(app.buttons["native-library-source-photos"].isHittable)
        XCTAssertTrue(app.buttons["native-library-source-files"].isHittable)
        app.buttons["native-library-sources-toggle"].tap()
        XCTAssertTrue(app.staticTexts["사진이나 파일을 선택한 뒤\n문서로 끌어다 놓으세요."].waitForExistence(timeout: 5))
        screenshot("사진 파일 소스 보관함")
        app.terminate()
        app.launchArguments = ["--native-ui-testing"]
        app.launch()
        let viewMenu = app.buttons["native-library-view-menu"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(viewMenu.label.contains("갤러리"), "View choice must survive restart")
        let parentFolder = app.buttons["native-material-Parent"]
        XCTAssertTrue(parentFolder.waitForExistence(timeout: 10)); parentFolder.tap()
        let childFolder = app.buttons["native-material-Parent/Child"]
        XCTAssertTrue(childFolder.waitForExistence(timeout: 5)); childFolder.tap()
        XCTAssertTrue(app.buttons["native-library-gallery-preview"].waitForExistence(timeout: 10), app.debugDescription)
        chooseView("list", title: "목록", in: app)
    }

    @MainActor
    func testSourceTrayImageDragsIntoPDFAndMarkdown() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-library-source-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].tap()
        let courseName = app.textFields["native-course-name"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5))
        courseName.tap(); courseName.typeText("Media Drops")
        app.buttons["native-create-course"].tap()
        XCTAssertTrue(app.buttons["native-library-create"].waitForExistence(timeout: 20))
        chooseView("list", title: "목록", in: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Image PDF")
        app.buttons["native-new-note-create"].tap()
        let pdf = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: app.buttons["native-pdf-tool-pen"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        let source = app.descendants(matching: .any).matching(identifier: "native-library-source-asset-Drag Fixture.png").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "drawings=1 pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 20), .completed, app.debugDescription)
        screenshot("사진 보관함에서 PDF로 드래그")
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let noteName = app.textFields["native-name-input"]
        XCTAssertTrue(noteName.waitForExistence(timeout: 5)); noteName.tap(); noteName.typeText("Image Markdown")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-markdown-source-toggle"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: editor.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "![Drag Fixture.png](assets/"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 20), .completed, app.debugDescription)
        screenshot("사진 보관함에서 Markdown으로 드래그")
        let droppedSource = try XCTUnwrap(editor.value as? String)
        let tokenRange = try XCTUnwrap(droppedSource.range(of: #"!\[Drag Fixture\.png\]\(assets/[^)]+\)"#, options: .regularExpression))
        let imageToken = String(droppedSource[tokenRange])
        // Keep a line on either side so the image's real position controls have
        // a meaningful destination. The image still uses the dragged asset.
        editor.tap(); app.typeKey("a", modifierFlags: .command)
        editor.typeText("Before\n" + imageToken + "\nAfter\n")
        app.dismissNativeTestKeyboard()
        app.buttons["native-markdown-source-toggle"].tap()
        let projectedImage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\u{FFFC}"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [projectedImage], timeout: 10), .completed, "The Markdown image link must project to an inline attachment: " + app.debugDescription)
        screenshot("드래그한 사진의 Markdown 서식 이미지 표시")
        // The inline image follows one body line, inside the editor's 28pt
        // horizontal and 40pt top inset. Tap its pixels to open the inspector.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: 100)).tap()
        let imageSize = app.sliders["native-markdown-image-size"]
        XCTAssertTrue(imageSize.waitForExistence(timeout: 5), app.debugDescription)
        imageSize.adjust(toNormalizedSliderPosition: 0.375)
        let alignment = app.segmentedControls["native-markdown-image-alignment"]
        XCTAssertTrue(alignment.waitForExistence(timeout: 5), app.debugDescription)
        alignment.buttons.element(boundBy: 1).tap()
        app.buttons["위로"].firstMatch.tap()
        screenshot("Markdown 이미지 크기 정렬 위치 조절")
        app.buttons["완료"].firstMatch.tap()
        app.buttons["native-markdown-source-toggle"].tap()
        let adjusted = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(adjusted.hasPrefix(imageToken), "Move up must place the image before the first text line: " + adjusted)
        XCTAssertTrue(adjusted.contains("align=center"), adjusted)
        XCTAssertNotNil(adjusted.range(of: #"width=(45|50|55) "#, options: .regularExpression), "The actual slider must persist a smaller image: " + adjusted)
        XCTAssertTrue(adjusted.hasSuffix("Before\nAfter\n"), adjusted)
        app.buttons["native-markdown-source-toggle"].tap()
        app.terminate(); app.launchArguments = ["--native-ui-testing"]; app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-markdown-source-toggle"].tap()
        XCTAssertEqual(editor.value as? String, adjusted, "Image size, alignment and position must survive restart")
    }

    @MainActor
    func testCompactSourceTrayDragsThroughOverlayIntoPDFAndMarkdown() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-library-source-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["native-section-library"].waitForExistence(timeout: 20), app.debugDescription)
        guard app.frame.width < 900 else {
            throw XCTSkip("Requires an iPad window narrower than 900 points, such as an 11-inch iPad in portrait.")
        }
        XCTAssertLessThan(app.frame.width, 900, "This test must exercise the compact overlay, not the fixed desktop sidebar")
        XCTAssertLessThan(app.frame.width, app.frame.height, "The compact drag regression must run in portrait")
        app.buttons["native-section-library"].tap()
        XCTAssertTrue(app.buttons["native-course-add-menu"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["native-course-add-menu"].tap(); app.buttons["native-new-course"].tap()
        let courseName = app.textFields["native-course-name"]
        XCTAssertTrue(courseName.waitForExistence(timeout: 5))
        courseName.tap(); courseName.typeText("Compact Media Drops")
        app.buttons["native-create-course"].tap()
        openCompactMaterials(in: app)
        app.buttons["native-library-create"].tap(); app.buttons["새 노트"].tap()
        let name = app.textFields["native-new-note-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Compact Image PDF")
        app.buttons["native-new-note-create"].tap()
        let pdf = app.otherElements["native-pdf-workspace"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: app.buttons["native-pdf-tool-pen"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        openCompactMaterials(in: app)
        let source = app.descendants(matching: .any).matching(identifier: "native-library-source-asset-Drag Fixture.png").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        let sourceIdentity = try XCTUnwrap(source.value as? String)
        XCTAssertNotNil(UUID(uuidString: sourceIdentity), "Test mode exposes the selected source's stable identity")
        let pdfDropPoint = CGPoint(x: pdf.frame.minX + pdf.frame.width * 0.35, y: pdf.frame.midY)
        XCTAssertLessThan(pdfDropPoint.x, app.buttons["native-library-source-photos"].frame.minX, "Drop must land on the editor exposed to the left of the overlay")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pdfDropPoint.x - app.frame.minX, dy: pdfDropPoint.y - app.frame.minY)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "drawings=1 pending=0"), object: app.buttons["native-pdf-drawing-tools"])
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 20), .completed, "The compact overlay must pass the drop through to PDF: " + app.debugDescription)
        screenshot("세로 화면의 자료 패널에서 PDF로 드래그")
        let close = app.buttons["native-library-close"]
        XCTAssertTrue(close.isHittable); close.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        openCompactMaterials(in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Reopening the panel must reveal its previously selected sources")
        XCTAssertEqual(source.value as? String, sourceIdentity, "Closing the panel must retain the same staged asset, not create another one")
        app.buttons["native-library-create"].tap(); app.buttons["새 마크다운"].tap()
        let noteName = app.textFields["native-name-input"]
        XCTAssertTrue(noteName.waitForExistence(timeout: 5)); noteName.tap(); noteName.typeText("Compact Image Markdown")
        app.buttons["만들기"].tap()
        let editor = app.textViews["native-markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["native-markdown-source-toggle"].tap()
        openCompactMaterials(in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(source.value as? String, sourceIdentity, "Opening another document must retain the selected source")
        let markdownDropPoint = CGPoint(x: editor.frame.minX + editor.frame.width * 0.3, y: editor.frame.minY + editor.frame.height * 0.4)
        XCTAssertLessThan(markdownDropPoint.x, app.buttons["native-library-source-photos"].frame.minX)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: markdownDropPoint.x - app.frame.minX, dy: markdownDropPoint.y - app.frame.minY)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "![Drag Fixture.png](assets/"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 20), .completed, "The compact overlay must pass the drop through to Markdown: " + app.debugDescription)
        close.tap()
        app.buttons["native-markdown-source-toggle"].tap()
        let projectedImage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\u{FFFC}"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [projectedImage], timeout: 10), .completed, app.debugDescription)
        screenshot("세로 화면에서 드래그한 사진의 Markdown 서식 표시")
    }

    @MainActor
    func testSystemPhotoPickerStagesSelectedPhotoInSourceTray() throws {
        guard ProcessInfo.processInfo.environment["BANDAL_PHOTOS_UI_FIXTURE"] == "1" else {
            throw XCTSkip("Requires a simulator Photos library seeded with BANDAL_PHOTOS_UI_FIXTURE=1 by the UI test runner.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // Deliberately omit the source-fixture flag: only the system picker can
        // create the tray item verified below. The simulator Photos library is
        // seeded by the test runner with a real PNG before this test is run.
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"]
        app.launch()
        let photos = app.buttons["native-library-source-photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 20), app.debugDescription)
        let assets = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-library-source-asset-"))
        XCTAssertEqual(assets.count, 0)
        photos.tap()
        let pickerImages = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(pickerImages.firstMatch.waitForExistence(timeout: 15), "System photo grid must be present: " + app.debugDescription)
        screenshot("선택 전 시스템 사진 선택기")
        let pickerHierarchy = XCTAttachment(string: app.debugDescription)
        pickerHierarchy.name = "선택 전 시스템 사진 선택기 AX hierarchy"
        pickerHierarchy.lifetime = .keepAlways
        add(pickerHierarchy)
        let grids = app.scrollViews.containing(.image, identifier: "PXGGridLayout-Info").allElementsBoundByIndex
        let grid = try XCTUnwrap(grids.filter {
            let visible = $0.frame.intersection(app.frame)
            return !visible.isNull && visible.width > 0 && visible.height > 0
        }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }, "A visible scroll viewport containing the system photos must exist: " + app.debugDescription)
        let viewport = grid.frame.intersection(app.frame)
        let visiblePhotos = grid.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex.compactMap { photo -> CGRect? in
            let frame = photo.frame
            let visible = frame.intersection(viewport)
            // The accessibility tree includes rows beyond the sheet's clipped
            // viewport. Require at least half the real tile to be visible.
            guard !visible.isNull, visible.width > 8, visible.height > 8,
                  visible.width * visible.height >= frame.width * frame.height * 0.5 else { return nil }
            return visible.insetBy(dx: 2, dy: 2)
        }
        let visiblePhoto = try XCTUnwrap(visiblePhotos.first, "The picker must expose a photo inside its actual scroll viewport: " + app.debugDescription)
        // Photos' grid exposes a passive Image accessibility node: XCTest can
        // report a -1/-1 hit point even while its owning tile is visible. Tap
        // only the verified viewport-clipped portion of that observed tile.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visiblePhoto.midX - app.frame.minX, dy: visiblePhoto.midY - app.frame.minY)).tap()
        XCTAssertTrue(grid.exists, "Selecting a visible photo must keep the multi-select picker open: " + app.debugDescription)
        let confirm = app.navigationBars.buttons.matching(identifier: "Add").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The observed system picker Add button must exist: " + app.debugDescription)
        let confirmationReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmationReady], timeout: 10), .completed, "Picker confirmation must become enabled: " + app.debugDescription)
        XCTAssertTrue(confirm.isHittable, app.debugDescription)
        confirm.tap()
        XCTAssertTrue(assets.firstMatch.waitForExistence(timeout: 20), "PHPicker file representation must be copied into the tray: " + app.debugDescription)
        XCTAssertTrue(assets.firstMatch.isHittable)
        XCTAssertFalse(assets.firstMatch.identifier.contains("Drag Fixture"), "This test must use the picker result, not the debug tray fixture")
        screenshot("사진 선택기에서 실제 사진을 소스 보관함으로 가져오기")
    }

    @MainActor private func openCompactMaterials(in app: XCUIApplication) {
        let toggle = app.buttons["native-toggle-materials-rail"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
        toggle.tap()
        let close = app.buttons["native-library-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Compact sidebar must expose its close action: " + app.debugDescription)
        XCTAssertTrue(close.isHittable)
    }

    @MainActor private func createFolder(_ name: String, path: String, in app: XCUIApplication) {
        app.buttons["native-library-create"].tap(); app.buttons["새 폴더"].tap()
        let field = app.textFields["native-name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["만들기"].tap()
        XCTAssertTrue(app.buttons["native-material-" + path].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func chooseView(_ id: String, title: String, in app: XCUIApplication) {
        let menu = app.buttons["native-library-view-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let choice = app.buttons["native-library-view-" + id]
        if choice.waitForExistence(timeout: 2) { choice.tap() }
        else { app.buttons[title].firstMatch.tap() }
        XCTAssertTrue(menu.label.contains(title), app.debugDescription)
    }
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
