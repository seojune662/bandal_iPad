import XCTest
@testable import Bandal

@MainActor
final class NativeWorkspaceNavigationTests: XCTestCase {
    private func document(_ path: String, course: String = "course-a") -> NativeDocumentReference {
        .init(courseID: course, relativePath: path, title: (path as NSString).lastPathComponent, kind: "note")
    }

    func testOpeningCompanionSwapsPanesWithoutDuplicatingDocument() {
        let navigation = NativeWorkspaceNavigation()
        let first = document("first.md"), second = document("second.md")
        navigation.open(first); navigation.open(second); navigation.showBeside(first)
        navigation.open(first)
        XCTAssertEqual(navigation.documents.count, 2)
        XCTAssertEqual(navigation.active, first)
        XCTAssertEqual(navigation.companion, second)
        navigation.open(first)
        XCTAssertEqual(navigation.documents.count, 2)
        XCTAssertNotEqual(navigation.activeID, navigation.companionID)
        navigation.showBeside(first)
        XCTAssertNil(navigation.companion)
    }

    func testClosingActivePromotesCompanionAndClosingCompanionKeepsActive() {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md"), c = document("c.md")
        navigation.open(a); navigation.open(b); navigation.open(c); navigation.showBeside(a)
        navigation.close(c.id)
        XCTAssertEqual(navigation.active, a)
        XCTAssertNil(navigation.companion)
        navigation.showBeside(b); navigation.close(b.id)
        XCTAssertEqual(navigation.active, a)
        XCTAssertNil(navigation.companion)
        navigation.close(a.id)
        XCTAssertTrue(navigation.documents.isEmpty)
        XCTAssertNil(navigation.activeID)
    }

    func testFolderRenameUsesWholePathComponentsAndPreservesOtherCourses() {
        let navigation = NativeWorkspaceNavigation()
        let child = document("unit/deep/note.md"), sibling = document("units/note.md")
        let otherCourse = document("unit/deep/note.md", course: "course-b")
        navigation.open(sibling); navigation.open(otherCourse); navigation.open(child); navigation.showBeside(otherCourse)
        navigation.rename(courseID: "course-a", from: "unit", to: "renamed", isDirectory: true)
        XCTAssertEqual(navigation.active?.relativePath, "renamed/deep/note.md")
        XCTAssertEqual(navigation.active?.title, "note.md")
        XCTAssertEqual(navigation.companion?.storageID, otherCourse.storageID)
        XCTAssertNotEqual(navigation.companion?.id, otherCourse.id, "A second workspace placement owns an independent panel")
        XCTAssertTrue(navigation.documents.contains(sibling))
        navigation.remove(courseID: "course-a", path: "renamed", isDirectory: true)
        XCTAssertEqual(navigation.active?.storageID, otherCourse.storageID)
        XCTAssertTrue(navigation.documents.contains(sibling))
        XCTAssertFalse(navigation.documents.contains(where: { $0.relativePath.hasPrefix("renamed/") }))
    }

    func testExactFileRenameAndDeleteDoNotModifyPrefixMatches() {
        let navigation = NativeWorkspaceNavigation()
        let a = document("note.md"), b = document("note.md/child.md"), c = document("note.md", course: "course-b")
        navigation.open(a); navigation.open(b); navigation.open(c)
        navigation.rename(courseID: "course-a", from: "note.md", to: "changed.md", isDirectory: false)
        XCTAssertTrue(navigation.documents.contains(document("changed.md")))
        XCTAssertTrue(navigation.documents.contains(b))
        XCTAssertTrue(navigation.documents.contains(c))
        navigation.remove(courseID: "course-a", path: "changed.md", isDirectory: false)
        XCTAssertEqual(navigation.documents, [b, c])
    }

    func testRenameIntoStaleOpenTargetDeduplicatesBothPanes() {
        let navigation = NativeWorkspaceNavigation()
        let source = document("source.md"), staleTarget = document("destination.md")
        // The target tab can outlive an external file deletion. Renaming a
        // different existing file to that now-free path must merge identities.
        navigation.open(source); navigation.open(staleTarget); navigation.showBeside(source)
        navigation.rename(courseID: "course-a", from: "source.md", to: "destination.md", isDirectory: false)
        XCTAssertEqual(navigation.documents.map(\.id), [staleTarget.id])
        XCTAssertEqual(navigation.activeID, staleTarget.id)
        XCTAssertNil(navigation.companionID)
    }

    func testCompanionMustBelongToOpenDocuments() {
        let navigation = NativeWorkspaceNavigation()
        navigation.open(document("a.md"))
        navigation.showBeside(document("never-opened.md"))
        XCTAssertTrue(navigation.companionID == nil || navigation.documents.contains(where: { $0.id == navigation.companionID }))
        XCTAssertNotEqual(navigation.activeID, navigation.companionID)
    }

    func testCourseSwitchRestoresItsOwnLastDocumentAndEmptyCourseHasNoForeignEditor() {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md"), foreign = document("foreign.md", course: "course-b")
        navigation.open(a); navigation.open(b); navigation.open(foreign); navigation.showBeside(b)
        navigation.activateCourse("course-a")
        XCTAssertEqual(navigation.active, b)
        XCTAssertNil(navigation.companion)
        navigation.close(b.id)
        XCTAssertEqual(navigation.active, a)
        navigation.close(a.id)
        XCTAssertNil(navigation.active, "Closing a course's last tab must not open another course")
        navigation.activateCourse("course-b")
        XCTAssertEqual(navigation.active, foreign)
        navigation.activateCourse("empty-course")
        XCTAssertNil(navigation.active)
        XCTAssertTrue(navigation.documents.contains(foreign))
    }

    func testRestoreFiltersUnavailableAndDuplicateDocumentsAndInvalidPaneIDs() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-navigation-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = document("a.md"), last = document("z.md", course: "course-b"), missing = document("missing.md")
        try writeSnapshot(file, documents: [first, first, missing, last], active: missing.id, companion: last.id)
        let navigation = NativeWorkspaceNavigation()
        await navigation.restore(from: file) { $0.id != missing.id }
        XCTAssertEqual(navigation.documents, [first, last])
        XCTAssertEqual(navigation.active, last)
        XCTAssertNil(navigation.companionID, "Fallback active and restored companion must not show one editor twice")
        try navigation.save(to: file)
        let reopened = NativeWorkspaceNavigation()
        await reopened.restore(from: file) { _ in true }
        XCTAssertEqual(reopened.documents, navigation.documents)
        XCTAssertEqual(reopened.activeID, navigation.activeID)
        XCTAssertEqual(reopened.companionID, navigation.companionID)
    }

    func testUserNavigationWinsOverSuspendedRestoration() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-navigation-race-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let restored = document("previous.md"), current = document("opened-now.md")
        try writeSnapshot(file, documents: [restored], active: restored.id, companion: nil)
        let navigation = NativeWorkspaceNavigation()
        let checking = expectation(description: "Restoration is checking a file")
        var resume: CheckedContinuation<Bool, Never>?
        let restoration = Task { @MainActor in
            await navigation.restore(from: file) { _ in
                await withCheckedContinuation { continuation in resume = continuation; checking.fulfill() }
            }
        }
        await fulfillment(of: [checking], timeout: 2)
        navigation.open(current)
        resume?.resume(returning: true)
        await restoration.value
        XCTAssertEqual(navigation.documents, [current])
        XCTAssertEqual(navigation.active, current)
    }

    private func writeSnapshot(_ url: URL, documents: [NativeDocumentReference], active: String?, companion: String?) throws {
        struct Snapshot: Encodable { let documents: [NativeDocumentReference]; let activeID: String?; let companionID: String? }
        try JSONEncoder().encode(Snapshot(documents: documents, activeID: active, companionID: companion)).write(to: url, options: .atomic)
    }
}
