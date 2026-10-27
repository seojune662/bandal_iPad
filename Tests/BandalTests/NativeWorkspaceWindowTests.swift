import XCTest
@testable import Bandal

@MainActor
final class NativeWorkspaceWindowTests: XCTestCase {
    private func document(_ path: String = "chapter.pdf", course: String = "course", kind: String = "pdf") -> NativeDocumentReference {
        .init(courseID: course, relativePath: path, title: path, kind: kind)
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-windows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func legacyWindowData() throws -> Data {
        struct Legacy: Encodable {
            var documents: [NativeDocumentReference]
            var layouts: [String: NativeDockLayout]
            var activeCourseID: String
        }
        let pdf = document()
        return try JSONEncoder().encode(Legacy(documents: [pdf], layouts: ["course": NativeDockLayout(group: NativeDockGroup(tabs: [pdf.id], activeID: pdf.id))], activeCourseID: "course"))
    }
    func testWindowsKeepIndependentLayoutsChromeAndFocusAfterRestart() async throws {
        let url = try temporaryRoot().appendingPathComponent("workspace.json")
        let nav = NativeWorkspaceNavigation(), firstDocument = document()
        nav.open(firstDocument)
        let first = try XCTUnwrap(nav.currentWindowRef)
        nav.apply(.grid); nav.setChromeMode(.tabsHidden)
        let firstLayout = nav.layout
        let second = try XCTUnwrap(nav.createWindow())
        XCTAssertTrue(nav.documents(in: second).isEmpty)
        XCTAssertEqual(nav.groups.count, 1)
        nav.setChromeMode(.toolsHidden); nav.renameWindow(second, name: "문제 풀이")
        let secondDocument = try XCTUnwrap(nav.open(firstDocument, target: XCTUnwrap(nav.captureTarget())))
        XCTAssertNotEqual(secondDocument.id, firstDocument.id)
        XCTAssertEqual(secondDocument.storageID, firstDocument.storageID)
        nav.moveWindow(second, to: 0)
        try nav.save(to: url)

        let restored = NativeWorkspaceNavigation()
        await restored.restore(from: url) { _ in true }
        XCTAssertEqual(restored.currentWindowRef, second)
        XCTAssertEqual(restored.windows.map(\.id), [second.windowID, first.windowID])
        XCTAssertEqual(restored.chromeMode, .toolsHidden)
        XCTAssertEqual(restored.currentWindow?.name, "문제 풀이")
        XCTAssertEqual(restored.activeID, secondDocument.id)
        XCTAssertTrue(restored.selectWindow(first))
        XCTAssertEqual(restored.layout, firstLayout)
        XCTAssertEqual(restored.chromeMode, .tabsHidden)
        XCTAssertEqual(restored.activeID, firstDocument.id)
    }
    func testDefaultNamesSkipRenamedNamesAndDoNotRecycleClosedNumbers() throws {
        let nav = NativeWorkspaceNavigation(); nav.activateCourse("course")
        let first = try XCTUnwrap(nav.currentWindowRef)
        XCTAssertTrue(nav.renameWindow(first, name: " 윈도우 2 \n"))
        let third = try XCTUnwrap(nav.createWindow())
        XCTAssertEqual(nav.currentWindow?.name, "윈도우 3")
        let close = try XCTUnwrap(nav.prepareWindowClose(third)); XCTAssertTrue(nav.commitWindowClose(close))
        _ = nav.createWindow()
        XCTAssertEqual(nav.currentWindow?.name, "윈도우 4")
        XCTAssertFalse(nav.renameWindow(first, name: "  \n"))
    }
    func testCourseAndProjectWindowSelectionsAreIndependent() throws {
        let nav = NativeWorkspaceNavigation()
        let project = NativeWorkspaceContext(kind: .project, courseID: "storage", projectID: "p", rootRelPath: "project", title: "Project")
        nav.activateCourse("course"); let courseWindow = try XCTUnwrap(nav.createWindow())
        nav.activateWorkspace(project); let projectWindow = try XCTUnwrap(nav.createWindow())
        XCTAssertNotEqual(projectWindow.workspaceID, courseWindow.workspaceID)
        XCTAssertFalse(nav.selectWindow(courseWindow), "A stale card cannot silently change the sidebar's workspace")
        nav.activateCourse("course"); XCTAssertEqual(nav.currentWindowRef, courseWindow)
        nav.activateWorkspace(project); XCTAssertEqual(nav.currentWindowRef, projectWindow)
        XCTAssertEqual(nav.windows.count, 2)
    }
    func testCapturedWindowOwnerSurvivesEmptyInactiveAndForeignDocumentWindows() async throws {
        let nav = NativeWorkspaceNavigation()
        nav.activateCourse("original-course")
        let courseWindow = try XCTUnwrap(nav.currentWindowRef)
        let project = NativeWorkspaceContext(kind: .project, courseID: "project-storage", projectID: "project", rootRelPath: "root", title: "Project")
        nav.activateWorkspace(project)
        let emptyProjectWindow = try XCTUnwrap(nav.currentWindowRef)
        let foreignDocumentWindow = try XCTUnwrap(nav.createWindow())
        nav.open(document("linked.pdf", course: "foreign-course"), workspace: project)
        nav.activateCourse("current-course")
        XCTAssertEqual(nav.courseID(for: courseWindow), "original-course")
        XCTAssertEqual(nav.courseID(for: emptyProjectWindow), "project-storage")
        XCTAssertEqual(nav.courseID(for: foreignDocumentWindow), "project-storage")
        let url = try temporaryRoot().appendingPathComponent("workspace.json")
        try nav.save(to: url)
        let restored = NativeWorkspaceNavigation(); await restored.restore(from: url) { _ in true }
        XCTAssertEqual(restored.courseID(for: emptyProjectWindow), "project-storage")
        XCTAssertEqual(restored.courseID(for: foreignDocumentWindow), "project-storage")
        let plan = try XCTUnwrap(restored.prepareWindowClose(emptyProjectWindow))
        XCTAssertTrue(restored.commitWindowClose(plan))
        XCTAssertNil(restored.courseID(for: emptyProjectWindow), "A closed destination cannot fall back to the visible course")
    }
    func testDisablingInitialSelectionRestorePreservesAllWindowCollections() async throws {
        let nav = NativeWorkspaceNavigation(); nav.open(document())
        let first = try XCTUnwrap(nav.currentWindowRef)
        let second = try XCTUnwrap(nav.createWindow()); nav.setChromeMode(.toolsHidden)
        nav.open(document("notes.md", kind: "note"))
        let originalWindows = nav.windowCollections[first.workspaceID]
        let url = try temporaryRoot().appendingPathComponent("workspace.json")
        try nav.save(to: url)
        let restored = NativeWorkspaceNavigation(); await restored.restore(from: url) { _ in true }
        restored.deactivateWorkspace()
        XCTAssertNil(restored.currentWindowRef)
        restored.activateCourse("startup-course")
        try restored.save(to: url)
        let reopened = NativeWorkspaceNavigation(); await reopened.restore(from: url) { _ in true }
        XCTAssertEqual(reopened.windowCollections[first.workspaceID], originalWindows)
        XCTAssertEqual(reopened.documents(in: second).first?.relativePath, "notes.md")
        reopened.activateCourse("course")
        XCTAssertEqual(reopened.currentWindowRef, second)
        XCTAssertEqual(reopened.chromeMode, .toolsHidden)
    }
    func testDelayedOpenTargetsOriginalWindowWithoutStealingCurrentFocus() async throws {
        let nav = NativeWorkspaceNavigation(); nav.open(document("first.pdf"))
        let target = try XCTUnwrap(nav.captureTarget())
        let waiting = expectation(description: "Resource load suspended")
        var continuation: CheckedContinuation<Void, Never>?
        let delayed = Task { @MainActor in
            await withCheckedContinuation { continuation = $0; waiting.fulfill() }
            return nav.open(self.document("loaded.pdf"), target: target)
        }
        await fulfillment(of: [waiting], timeout: 2)
        let next = try XCTUnwrap(nav.createWindow()); nav.open(document("visible.pdf"))
        let selected = nav.activeID
        continuation?.resume()
        let inserted = await delayed.value
        XCTAssertEqual(nav.currentWindowRef, next)
        XCTAssertEqual(nav.activeID, selected)
        XCTAssertTrue(nav.documents(in: target.ref).contains { $0.id == inserted?.id })
        XCTAssertFalse(nav.documents(in: next).contains { $0.id == inserted?.id })
    }
    func testClosedAsyncTargetDoesNotResurrectWindowOrRegisterOrphanDocument() throws {
        let nav = NativeWorkspaceNavigation(); nav.open(document())
        let target = try XCTUnwrap(nav.captureTarget())
        let next = try XCTUnwrap(nav.createWindow())
        let close = try XCTUnwrap(nav.prepareWindowClose(target.ref))
        XCTAssertTrue(nav.commitWindowClose(close))
        XCTAssertNil(nav.open(document("late.pdf"), target: target))
        XCTAssertNil(nav.openBeside(document("late-note.md", kind: "note"), sourceID: nil, target: target))
        XCTAssertNil(nav.window(target.ref))
        XCTAssertEqual(nav.currentWindowRef, next)
        XCTAssertTrue(nav.documents.isEmpty)
    }
    func testMissingCapturedPaneFallsBackOnlyInsideOriginalWindow() throws {
        let nav = NativeWorkspaceNavigation(); nav.activateCourse("course"); nav.apply(.columns)
        let target = try XCTUnwrap(nav.captureTarget(groupID: nav.groups.last?.id))
        nav.removeEmptyGroup(try XCTUnwrap(target.groupID))
        let second = try XCTUnwrap(nav.createWindow())
        let opened = nav.open(document(), target: target)
        XCTAssertNotNil(opened)
        XCTAssertEqual(nav.documents(in: target.ref).count, 1)
        XCTAssertTrue(nav.documents(in: second).isEmpty)
        XCTAssertEqual(nav.currentWindowRef, second)
    }
    func testSupportedResourcesHaveDistinctPanelsInDifferentWindows() throws {
        let documents = [document(), document("note.md", kind: "note"), document("board", kind: "whiteboard"), document("movie.mp4", kind: "video"), document("recording.m4a", kind: "audio"),
            NativeLearningDocumentTarget(projectID: "project", binding: .init(courseID: "course", rootRelPath: "project"), kind: .artifact, entityID: "quiz").document(title: "Quiz")]
        for original in documents {
            let nav = NativeWorkspaceNavigation(); nav.open(original)
            let first = try XCTUnwrap(nav.currentWindowRef)
            let second = try XCTUnwrap(nav.createWindow())
            let copy = try XCTUnwrap(nav.open(original, target: XCTUnwrap(nav.captureTarget())))
            XCTAssertTrue(original.supportsDuplicate)
            XCTAssertNotEqual(copy.id, original.id)
            XCTAssertEqual(copy.storageID, original.storageID)
            XCTAssertEqual(nav.target(containing: original.id)?.ref, first)
            XCTAssertEqual(nav.target(containing: copy.id)?.ref, second)
            nav.open(original)
            XCTAssertEqual(nav.documents.count, 2, "Repeated opening reuses this window's instance")
        }
    }
    func testBrowserCopyGetsIndependentStableScopeAndRepeatedOpenReusesIt() throws {
        let nav = NativeWorkspaceNavigation(), browser = document("browser-scope", kind: "browser")
        nav.open(browser); let first = try XCTUnwrap(nav.currentWindowRef)
        let second = try XCTUnwrap(nav.createWindow())
        let target = try XCTUnwrap(nav.captureTarget())
        let copy = try XCTUnwrap(nav.open(browser, target: target))
        XCTAssertNotEqual(copy.id, browser.id)
        XCTAssertNotEqual(copy.relativePath, browser.relativePath)
        XCTAssertNotNil(UUID(uuidString: copy.relativePath))
        XCTAssertEqual(nav.open(browser, target: target), copy)
        XCTAssertEqual(nav.documents(in: first), [browser])
        XCTAssertEqual(nav.documents(in: second), [copy])
    }
    func testRenameAndDeleteAffectEveryWindowWithoutChangingSelection() throws {
        let nav = NativeWorkspaceNavigation(), original = document("unit/chapter.pdf")
        nav.open(original); let first = try XCTUnwrap(nav.currentWindowRef)
        let second = try XCTUnwrap(nav.createWindow())
        let copy = try XCTUnwrap(nav.open(original, target: XCTUnwrap(nav.captureTarget())))
        nav.rename(courseID: "course", from: "unit", to: "renamed", isDirectory: true)
        XCTAssertEqual(nav.currentWindowRef, second)
        XCTAssertEqual(Set(nav.documents.map(\.storageID)), ["course:renamed/chapter.pdf"])
        XCTAssertEqual(nav.document(copy.id)?.instanceID, copy.instanceID)
        XCTAssertEqual(nav.documentDuplicateSourceIDs[copy.id], "course:renamed/chapter.pdf")
        XCTAssertEqual(nav.documents(in: first).count, 1)
        nav.remove(courseID: "course", path: "renamed", isDirectory: true)
        XCTAssertTrue(nav.documents.isEmpty)
        XCTAssertTrue(nav.windows.allSatisfy { $0.layout.groups.allSatisfy { $0.tabs.isEmpty } })
        XCTAssertEqual(nav.currentWindowRef, second)
    }
    func testClosePlanRejectsLastWindowAndStalePlans() throws {
        let nav = NativeWorkspaceNavigation(); nav.open(document())
        let first = try XCTUnwrap(nav.currentWindowRef)
        XCTAssertNil(nav.prepareWindowClose(first))
        let second = try XCTUnwrap(nav.createWindow())
        let plan = try XCTUnwrap(nav.prepareWindowClose(second))
        nav.open(document("new-draft.md", kind: "note"))
        XCTAssertFalse(nav.canCommitWindowClose(plan))
        XCTAssertFalse(nav.commitWindowClose(plan))
        XCTAssertNotNil(nav.window(second))
        XCTAssertNotNil(nav.active)
    }
    func testRenameIntoStaleTargetInAnotherWindowKeepsDistinctPanels() throws {
        let nav = NativeWorkspaceNavigation(), source = document("source.pdf"), stale = document("destination.pdf")
        nav.open(source); let first = try XCTUnwrap(nav.currentWindowRef)
        let second = try XCTUnwrap(nav.createWindow()); nav.open(stale)
        nav.rename(courseID: "course", from: "source.pdf", to: "destination.pdf", isDirectory: false)
        let a = try XCTUnwrap(nav.documents(in: first).first), b = try XCTUnwrap(nav.documents(in: second).first)
        XCTAssertEqual(a.storageID, b.storageID)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(nav.documents.count, 2)
        XCTAssertEqual(nav.currentWindowRef, second)
    }
    func testPersistFailureRollsBackWindowCloseAndLeavesOriginalDiskState() throws {
        let root = try temporaryRoot(), url = root.appendingPathComponent("workspace.json")
        let nav = NativeWorkspaceNavigation(); nav.open(document()); _ = nav.createWindow()
        nav.open(document("draft.md", kind: "note"))
        try nav.save(to: url)
        let before = try Data(contentsOf: url), windows = nav.windowCollections, documents = nav.documents
        let selected = nav.currentWindowRef, plan = try XCTUnwrap(nav.prepareWindowClose(XCTUnwrap(selected)))
        let blocked = root.appendingPathComponent("not-a-directory"); try Data("blocked".utf8).write(to: blocked)
        XCTAssertThrowsError(try nav.performPersistedChange(to: blocked.appendingPathComponent("workspace.json")) { nav.commitWindowClose(plan) })
        XCTAssertEqual(nav.windowCollections, windows)
        XCTAssertEqual(nav.documents, documents)
        XCTAssertEqual(nav.currentWindowRef, selected)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotNil(nav.persistenceError)
    }
    func testLegacyMigrationBacksUpOriginalAndSeparatesSharedPlacements() async throws {
        let root = try temporaryRoot(), url = root.appendingPathComponent("workspace.json")
        let pdf = document(), note = document("notes.md", kind: "note")
        let layout = NativeDockLayout(group: NativeDockGroup(tabs: [pdf.id, note.id], activeID: note.id))
        let project = NativeWorkspaceContext(kind: .project, courseID: "course", projectID: "p", rootRelPath: "project", title: "Project")
        struct Legacy: Encodable {
            var documents: [NativeDocumentReference]
            var layouts: [String: NativeDockLayout]
            var activeCourseID: String
            var activeWorkspace: NativeWorkspaceContext
            var pageNoteSourceTabIDs: [String: String]
        }
        let original = try JSONEncoder().encode(Legacy(documents: [pdf, note], layouts: ["course": layout, project.id: layout], activeCourseID: "course", activeWorkspace: project, pageNoteSourceTabIDs: [note.id: pdf.id]))
        try original.write(to: url)
        let nav = NativeWorkspaceNavigation(); await nav.restore(from: url) { _ in true }
        XCTAssertEqual(nav.windows.count, 1)
        XCTAssertEqual(nav.windows.first?.name, "윈도우 1")
        XCTAssertEqual(nav.documents.count, 4)
        let placements = nav.windowCollections.values.flatMap(\.windows).flatMap { $0.layout.groups.flatMap(\.tabs) }
        XCTAssertEqual(placements.count, Set(placements).count)
        let projectDocuments = nav.documents(in: try XCTUnwrap(nav.currentWindowRef))
        let projectPDF = try XCTUnwrap(projectDocuments.first { $0.kind == "pdf" }), projectNote = try XCTUnwrap(projectDocuments.first { $0.kind == "note" })
        XCTAssertEqual(nav.pageNoteSourceTabIDs[projectNote.id], projectPDF.id)
        try nav.save(to: url)
        XCTAssertEqual(try Data(contentsOf: NativeWorkspaceNavigation.migrationBackupURL(for: url)), original)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(current["version"] as? Int, 2)
        XCTAssertNotNil(current["windowCollections"])
        let reopened = NativeWorkspaceNavigation(); await reopened.restore(from: url) { _ in true }
        XCTAssertEqual(reopened.windowCollections, nav.windowCollections)
        XCTAssertEqual(reopened.documents, nav.documents)
        _ = reopened.createWindow(); try reopened.save(to: url)
        XCTAssertEqual(try Data(contentsOf: NativeWorkspaceNavigation.migrationBackupURL(for: url)), original)
    }
    func testPendingMigrationPersistsImmediatelyWithOriginalBackupAndStableWindowIDs() async throws {
        let url = try temporaryRoot().appendingPathComponent("workspace.json"), original = try legacyWindowData()
        try original.write(to: url)
        let nav = NativeWorkspaceNavigation(); await nav.restore(from: url) { _ in true }
        let firstWindow = try XCTUnwrap(nav.currentWindowRef)
        XCTAssertEqual(try Data(contentsOf: url), original, "Restoration itself is read-only")
        try nav.persistPendingMigration(to: url)
        let migrated = try Data(contentsOf: url)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertEqual(snapshot["version"] as? Int, 2)
        XCTAssertNotNil(snapshot["windowCollections"])
        XCTAssertEqual(try Data(contentsOf: NativeWorkspaceNavigation.migrationBackupURL(for: url)), original)
        let restarted = NativeWorkspaceNavigation(); await restarted.restore(from: url) { _ in true }
        XCTAssertEqual(restarted.currentWindowRef, firstWindow)
        XCTAssertEqual(restarted.windowCollections, nav.windowCollections)
        nav.setChromeMode(.toolsHidden)
        try nav.persistPendingMigration(to: url)
        XCTAssertEqual(try Data(contentsOf: url), migrated, "With no pending migration this API must not publish other edits")
    }
    func testPendingMigrationFailurePreservesOriginalAndCanRetryWithSameWindowIDs() async throws {
        let root = try temporaryRoot(), url = root.appendingPathComponent("workspace.json"), original = try legacyWindowData()
        try original.write(to: url)
        let nav = NativeWorkspaceNavigation(); await nav.restore(from: url) { _ in true }
        let firstWindow = try XCTUnwrap(nav.currentWindowRef)
        let blocked = NativeWorkspaceNavigation.previousSnapshotURL(for: url)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertThrowsError(try nav.persistPendingMigration(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(nav.currentWindowRef, firstWindow)
        XCTAssertNotNil(nav.persistenceError)
        try FileManager.default.removeItem(at: blocked)
        try nav.persistPendingMigration(to: url)
        XCTAssertNil(nav.persistenceError)
        XCTAssertEqual(try Data(contentsOf: NativeWorkspaceNavigation.migrationBackupURL(for: url)), original)
        let restarted = NativeWorkspaceNavigation(); await restarted.restore(from: url) { _ in true }
        XCTAssertEqual(restarted.currentWindowRef, firstWindow, "A failed migration remains pending until successfully saved")
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(snapshot["version"] as? Int, 2)
    }
    func testCorruptCurrentSnapshotRestoresPreviousAndFutureFormatIsNeverOverwritten() async throws {
        let url = try temporaryRoot().appendingPathComponent("workspace.json")
        let nav = NativeWorkspaceNavigation(); nav.open(document("first.pdf")); try nav.save(to: url)
        nav.open(document("second.pdf")); try nav.save(to: url)
        try Data("broken".utf8).write(to: url)
        let recovered = NativeWorkspaceNavigation(); await recovered.restore(from: url) { _ in true }
        XCTAssertEqual(recovered.active?.relativePath, "first.pdf")
        XCTAssertNotNil(recovered.persistenceError)
        let future = Data(#"{"version":99,"documents":[],"windowCollections":{"unknown":"format"}}"#.utf8)
        try future.write(to: url)
        let older = NativeWorkspaceNavigation(); await older.restore(from: url) { _ in true }
        older.deactivateWorkspace(); older.activateCourse("startup-course")
        try older.persistPendingMigration(to: url)
        XCTAssertThrowsError(try older.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), future)
    }
}
