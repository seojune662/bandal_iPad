import XCTest
@testable import Bandal

@MainActor
final class NativeProjectWorkspaceTests: XCTestCase {
    private func project(_ id: String, root: String = "projects/first") -> NativeWorkspaceContext {
        .init(kind: .project, courseID: "storage", projectID: id, rootRelPath: root, title: id, linkedCourseID: "physics")
    }
    func testProjectKeepsSourceCourseSeparateAndRestoresSplitAcrossRestart() async throws {
        let navigation = NativeWorkspaceNavigation(), first = project("first"), second = project("second", root: "projects/second")
        let source = NativeDocumentReference(courseID: "physics", relativePath: "chapter.pdf", title: "Chapter", kind: "pdf")
        let note = NativeDocumentReference(courseID: "storage", relativePath: "projects/first/note.md", title: "Note", kind: "note")
        navigation.activateWorkspace(first); navigation.open(note); navigation.open(source)
        let group = try XCTUnwrap(navigation.focusedGroupID)
        navigation.move(source.id, to: group, direction: .right)
        XCTAssertEqual(navigation.activeWorkspace, first)
        XCTAssertEqual(navigation.activeCourseID, "storage")
        XCTAssertEqual(navigation.groups.count, 2)
        navigation.activateWorkspace(second)
        XCTAssertTrue(navigation.groups.allSatisfy { $0.tabs.isEmpty })
        navigation.activateWorkspace(first)
        XCTAssertEqual(navigation.groups.flatMap(\.tabs).sorted(), [note.id, source.id].sorted())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try navigation.save(to: file)
        let restored = NativeWorkspaceNavigation(); await restored.restore(from: file) { _ in true }
        XCTAssertEqual(restored.activeWorkspace, first)
        XCTAssertEqual(restored.groups.count, 2)
        XCTAssertEqual(restored.groups.flatMap(\.tabs).sorted(), [note.id, source.id].sorted())
    }
    func testGeneratedTargetsHaveIndependentStableIDsAndSurviveFolderRename() throws {
        let context = project("same-project")
        let binding = try XCTUnwrap(context.binding)
        let first = NativeLearningDocumentTarget(projectID: "same-project", binding: binding, kind: .artifact, entityID: "quiz-a").document(title: "Quiz A")
        let second = NativeLearningDocumentTarget(projectID: "same-project", binding: binding, kind: .artifact, entityID: "quiz-b").document(title: "Quiz B")
        XCTAssertNotEqual(first.id, second.id)
        var markdownNamedRoot = first
        markdownNamedRoot.relativePath = "Review.md"
        XCTAssertFalse(markdownNamedRoot.supportsDuplicate, "A project folder extension must not allow duplicate quiz editors")
        let navigation = NativeWorkspaceNavigation()
        navigation.activateWorkspace(context); navigation.open(first); navigation.open(second); navigation.open(first)
        XCTAssertEqual(navigation.documents.count, 2)
        navigation.rename(courseID: "storage", from: "projects", to: "moved", isDirectory: true)
        XCTAssertEqual(navigation.document(first.id)?.learningTarget?.binding.rootRelPath, "moved/first")
        XCTAssertEqual(navigation.document(first.id)?.title, "Quiz A")
        XCTAssertEqual(navigation.activeWorkspace?.id, context.id)
        XCTAssertEqual(navigation.activeWorkspace?.rootRelPath, "moved/first")
        XCTAssertEqual(navigation.groups.flatMap(\.tabs), [first.id, second.id])
    }
    func testRestorationRelocatesProjectTargetsBeforeCheckingTheirExistence() async throws {
        let context = project("moved-project"), navigation = NativeWorkspaceNavigation()
        let binding = try XCTUnwrap(context.binding)
        let result = NativeLearningDocumentTarget(projectID: "moved-project", binding: binding, kind: .artifact, entityID: "quiz").document(title: "Quiz")
        navigation.open(result, workspace: context)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try navigation.save(to: file)
        let relocated = NativeLearningBinding(courseID: "storage", rootRelPath: "relocated/project")
        let reopened = NativeWorkspaceNavigation()
        await reopened.restore(from: file, projectBindings: ["moved-project": relocated]) { $0.learningTarget?.binding == relocated }
        XCTAssertEqual(reopened.activeID, result.id)
        XCTAssertEqual(reopened.activeWorkspace?.rootRelPath, relocated.rootRelPath)
        XCTAssertEqual(reopened.active?.learningTarget?.binding, relocated)
    }
    func testInactiveProjectMoveRestoresOrdinaryDocumentsSplitAndLinkedSource() async throws {
        let first = project("inactive"), second = project("active", root: "projects/second")
        let pdf = NativeDocumentReference(courseID: "storage", relativePath: "projects/first/chapter.pdf", title: "Chapter", kind: "pdf")
        let note = NativeDocumentReference(courseID: "storage", relativePath: "projects/first/notes/page.md", title: "Page", kind: "note")
        let source = NativeDocumentReference(courseID: "physics", relativePath: pdf.relativePath, title: "Original course source", kind: "pdf")
        let outside = NativeDocumentReference(courseID: "storage", relativePath: "projects/first-neighbor/kept.md", title: "Outside project", kind: "note")
        let navigation = NativeWorkspaceNavigation()
        navigation.open(pdf, workspace: first); navigation.open(note)
        navigation.move(note.id, to: try XCTUnwrap(navigation.focusedGroupID), direction: .right)
        navigation.open(source); navigation.open(outside)
        navigation.pageNoteSourceTabIDs[note.id] = source.id
        var expected = try XCTUnwrap(navigation.layout)
        navigation.activateWorkspace(second)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try navigation.save(to: file)

        let relocated = NativeLearningBinding(courseID: "storage", rootRelPath: "archive/first")
        var movedPDF = pdf, movedNote = note
        movedPDF.relativePath = "archive/first/chapter.pdf"; movedNote.relativePath = "archive/first/notes/page.md"
        let available = Set([movedPDF.id, movedNote.id, source.id, outside.id])
        let reopened = NativeWorkspaceNavigation()
        await reopened.restore(from: file, projectBindings: ["inactive": relocated]) { available.contains($0.id) }
        XCTAssertEqual(reopened.activeWorkspace, second, "Moving an inactive project must not change the selected project")
        expected.reconcile(validIDs: available, replacements: [pdf.id: movedPDF.id, note.id: movedNote.id])
        XCTAssertEqual(reopened.layouts[first.id], expected, "Split groups, active tabs, and pane focus must survive ID relocation")
        XCTAssertEqual(reopened.document(movedPDF.id), movedPDF)
        XCTAssertEqual(reopened.document(movedNote.id), movedNote)
        XCTAssertEqual(reopened.document(source.id), source, "The linked course owns the original even when its relative path matches")
        XCTAssertEqual(reopened.document(outside.id), outside, "Prefix neighbors are outside the moved project")
        XCTAssertEqual(reopened.pageNoteSourceTabIDs, [movedNote.id: source.id])
        // The updated inactive binding must survive another save and move.
        try reopened.save(to: file)
        var movedAgainPDF = movedPDF, movedAgainNote = movedNote
        movedAgainPDF.relativePath = "archive/second/chapter.pdf"; movedAgainNote.relativePath = "archive/second/notes/page.md"
        let availableAgain = Set([movedAgainPDF.id, movedAgainNote.id, source.id, outside.id])
        let reopenedAgain = NativeWorkspaceNavigation()
        await reopenedAgain.restore(from: file, projectBindings: ["inactive": .init(courseID: "storage", rootRelPath: "archive/second")]) { availableAgain.contains($0.id) }
        XCTAssertEqual(reopenedAgain.layouts[first.id]?.groups.flatMap(\.tabs).sorted(), availableAgain.sorted())
    }
    func testLegacySnapshotsRelocateFilesUsingActiveContextOrLearningTarget() async throws {
        for inferredFromTarget in [false, true] {
            let context = project("legacy"), navigation = NativeWorkspaceNavigation()
            let note = NativeDocumentReference(courseID: "storage", relativePath: "projects/first/page.md", title: "Page", kind: "note")
            let pdf = NativeDocumentReference(courseID: "storage", relativePath: "projects/first/book.pdf", title: "Book", kind: "pdf")
            navigation.open(note, workspace: context); navigation.open(pdf)
            navigation.pageNoteSourceTabIDs[note.id] = pdf.id
            var available: Set<String> = ["storage:moved/page.md", "storage:moved/book.pdf"]
            if inferredFromTarget {
                let target = NativeLearningDocumentTarget(projectID: "legacy", binding: try XCTUnwrap(context.binding), kind: .artifact, entityID: "quiz").document(title: "Quiz")
                navigation.open(target); available.insert(target.id)
                navigation.activateWorkspace(project("other", root: "other"))
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: file) }
            try navigation.save(to: file)
            var oldSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            oldSnapshot.removeValue(forKey: "projectBindings")
            try JSONSerialization.data(withJSONObject: oldSnapshot).write(to: file)
            let expectedIDs = available
            let reopened = NativeWorkspaceNavigation()
            await reopened.restore(from: file, projectBindings: ["legacy": .init(courseID: "storage", rootRelPath: "moved")]) { expectedIDs.contains($0.id) }
            XCTAssertEqual(reopened.layouts[context.id]?.groups.flatMap(\.tabs).sorted(), expectedIDs.sorted())
            XCTAssertEqual(reopened.pageNoteSourceTabIDs, ["storage:moved/page.md": "storage:moved/book.pdf"])
            if !inferredFromTarget {
                XCTAssertEqual(reopened.activeID, "storage:moved/book.pdf")
                XCTAssertEqual(reopened.activeWorkspace?.rootRelPath, "moved")
            }
        }
    }
    func testLegacyDocumentDecodingAndCourseLayoutsStayCompatible() throws {
        let raw = Data(#"{"courseID":"course","relativePath":"notes.md","title":"Notes","kind":"note"}"#.utf8)
        let document = try JSONDecoder().decode(NativeDocumentReference.self, from: raw)
        XCTAssertNil(document.learningTarget); XCTAssertEqual(document.id, "course:notes.md")
        let navigation = NativeWorkspaceNavigation(); navigation.open(document)
        let first = project("first"); navigation.activateWorkspace(first); navigation.open(document)
        navigation.closeTab(document.id)
        navigation.activateCourse("course")
        XCTAssertEqual(navigation.active, document, "Closing a project placement must not remove its course placement")
    }
    func testCourseScopeKeepsLinkedReviewArtifactInItsCurrentLayout() {
        let navigation = NativeWorkspaceNavigation()
        let course = NativeWorkspaceContext(kind: .course, courseID: "physics", title: "Physics")
        let review = NativeLearningDocumentTarget(projectID: "review", binding: .init(courseID: "separate-storage", rootRelPath: ""), kind: .artifact, entityID: "quiz").document(title: "Quiz")
        navigation.open(review, workspace: course)
        XCTAssertEqual(navigation.activeWorkspace, course)
        XCTAssertEqual(navigation.activeCourseID, "physics")
        XCTAssertEqual(navigation.active?.courseID, "separate-storage")
        XCTAssertEqual(navigation.activeID, review.id)
    }
    func testProjectLibraryOpensArticleAndArtifactsWithoutExposingJSON() throws {
        let context = project("project")
        let snapshot: [String: Any] = ["projectId": "project", "articles": [["id": "article", "title": "Reading", "relPath": ".bandal-learning/articles/article.json"]], "artifacts": [["id": "exam", "kind": "quiz", "title": "Final practice", "generationMode": "expected-exam"]]]
        let materials = NativeProjectLibrary.materials(snapshot: snapshot, scope: context)
        XCTAssertEqual(materials.map(\.name), ["Reading", "Final practice"])
        XCTAssertEqual(materials.map(\.kind), ["learning-article", "learning-exam"])
        XCTAssertEqual(materials.map { $0.document(in: "incorrect-owner").courseID }, ["storage", "storage"])
        XCTAssertEqual(materials.last?.document(in: "storage").learningTarget?.entityID, "exam")
        XCTAssertFalse(context.contains(path: "projects/first-neighbor/secret.md"))
        XCTAssertTrue(context.contains(path: "projects/first/notes.md"))
        let withWords = snapshot.merging(["words": [["id": "word", "surface": "vector"]]]) { _, new in new }
        let overview = try XCTUnwrap(NativeProjectLibrary.materials(snapshot: withWords, scope: context).first { $0.kind == "learning-overview" })
        XCTAssertEqual(overview.name, "표현·학습 기록")
        XCTAssertEqual(overview.document(in: "storage").learningTarget?.kind, .overview)
    }
    func testBrowsingStateDoesNotLeakAcrossProjectsOrEscapeRoot() throws {
        let suite = "project-browser-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let first = NativeLibraryBrowsingState(folder: "Study/Notes", query: "vectors", expanded: ["Study/Notes"])
        first.save(scopeID: "project:first", defaults: defaults)
        XCTAssertEqual(NativeLibraryBrowsingState.load(scopeID: "project:first", root: "Study", defaults: defaults), first)
        XCTAssertEqual(NativeLibraryBrowsingState.load(scopeID: "project:second", root: "Other", defaults: defaults), .init(folder: "Other", query: "", expanded: []))
        XCTAssertEqual(NativeLibraryBrowsingState.load(scopeID: "project:first", root: "Moved", defaults: defaults).folder, "Moved")
    }
}
