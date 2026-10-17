import Combine
import SwiftUI
import XCTest
@testable import Bandal

@MainActor
final class NativeDuplicateDocumentTests: XCTestCase {
    private func document(_ path: String = "chapter.md") -> NativeDocumentReference { .init(courseID: "course", relativePath: path, title: path, kind: path.hasSuffix(".pdf") ? "pdf" : "note") }
    func testExplicitDuplicateHasIndependentTabIdentityAndOrdinaryOpenReusesActiveStorage() throws {
        let navigation = NativeWorkspaceNavigation(), original = document()
        navigation.open(original)
        let originalGroup = try XCTUnwrap(navigation.focusedGroupID)
        let copy = try XCTUnwrap(navigation.duplicate(original.id, direction: .right))
        XCTAssertEqual(copy.storageID, original.storageID)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.relativePath, original.relativePath)
        XCTAssertEqual(navigation.groups.count, 2)
        XCTAssertEqual(navigation.groups.first { $0.id == originalGroup }?.activeID, original.id)
        XCTAssertEqual(navigation.activeID, copy.id)
        navigation.open(original)
        XCTAssertEqual(navigation.activeID, copy.id, "Normal material opening must reuse the already focused instance")
        XCTAssertEqual(navigation.documents.count, 2)
        navigation.closeTab(copy.id)
        XCTAssertNotNil(navigation.document(original.id))
        navigation.open(original)
        XCTAssertEqual(navigation.activeID, original.id)
    }
    func testExplicitDuplicateAlwaysFollowsSourceRegardlessOfGeneralOpenPreferenceOrActiveTab() throws {
        for adjacent in [false, true] {
            let navigation = NativeWorkspaceNavigation()
            let a = document("a.md"), b = document("b.md"), c = document("c.md")
            [a, b, c].forEach { navigation.open($0) }
            navigation.openAdjacentTab = adjacent
            let copy = try XCTUnwrap(navigation.duplicate(a.id))
            XCTAssertEqual(navigation.layout?.focused?.tabs, [a.id, copy.id, b.id, c.id])
            XCTAssertEqual(navigation.activeID, copy.id)
            XCTAssertEqual(navigation.openAdjacentTab, adjacent)
        }
    }
    func testTabAssistantTargetsSelectedInstanceAndPreservesItsExistingContext() throws {
        typealias Dock = NativeDockWorkspace<EmptyView, EmptyView>
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root), navigation = NativeWorkspaceNavigation(), original = document()
        navigation.open(original)
        let group = try XCTUnwrap(navigation.focusedGroupID), copy = try XCTUnwrap(navigation.duplicate(original.id))
        store.documentSelections[original.id] = "Original selection"
        store.documentSelections[copy.id] = "Duplicate selection"
        Dock.revealDocumentAssistant(original.id, in: group, navigation: navigation, store: store)
        XCTAssertEqual(navigation.activeID, original.id)
        XCTAssertEqual(store.assistantDocumentIDs, [original.id])
        XCTAssertEqual(store.documentSelections[original.id], "Original selection")
        XCTAssertEqual(store.documentSelections[copy.id], "Duplicate selection")
        navigation.closeTab(original.id)
        store.assistantDocumentIDs.remove(original.id)
        Dock.revealDocumentAssistant(original.id, in: group, navigation: navigation, store: store)
        XCTAssertTrue(store.assistantDocumentIDs.isEmpty, "A stale context menu cannot reopen a closed document")
    }
    func testDuplicateRenameAndRestartRetainBothInstancesAndDeleteRemovesBoth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = NativeWorkspaceNavigation(), original = document("folder/chapter.md")
        navigation.open(original)
        let copy = try XCTUnwrap(navigation.duplicate(original.id, direction: .below))
        navigation.rename(courseID: "course", from: "folder", to: "renamed", isDirectory: true)
        XCTAssertEqual(navigation.documents.count, 2)
        XCTAssertEqual(Set(navigation.documents.map(\.storageID)), ["course:renamed/chapter.md"])
        XCTAssertEqual(navigation.document(copy.id)?.instanceID, copy.instanceID)
        XCTAssertNotNil(navigation.document("course:renamed/chapter.md"))
        let url = root.appendingPathComponent("workspace.json")
        try navigation.save(to: url)
        let restored = NativeWorkspaceNavigation()
        await restored.restore(from: url) { $0.relativePath == "renamed/chapter.md" }
        XCTAssertEqual(Set(restored.documents.map(\.id)), Set(navigation.documents.map(\.id)))
        XCTAssertEqual(restored.groups.count, 2)
        XCTAssertEqual(restored.activeID, copy.id)
        restored.remove(courseID: "course", path: "renamed", isDirectory: true)
        XCTAssertTrue(restored.documents.isEmpty)
        XCTAssertTrue(restored.groups.allSatisfy { $0.tabs.isEmpty })
    }
    func testOriginalClosedStillReusesDuplicateAndLegacyDocumentJSONKeepsCanonicalID() throws {
        let original = try JSONDecoder().decode(NativeDocumentReference.self, from: Data(#"{"courseID":"course","relativePath":"lecture.pdf","title":"Lecture","kind":"pdf"}"#.utf8))
        XCTAssertNil(original.instanceID); XCTAssertEqual(original.id, "course:lecture.pdf")
        let navigation = NativeWorkspaceNavigation(); navigation.open(original)
        let copy = try XCTUnwrap(navigation.duplicate(original.id))
        navigation.closeTab(original.id); navigation.open(original)
        XCTAssertEqual(navigation.activeID, copy.id)
        XCTAssertEqual(navigation.documents.count, 1)
        XCTAssertNil(navigation.duplicate("missing"))
    }
    func testPageNotePairsRestorePerSourceInstanceAndFollowRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = NativeWorkspaceNavigation(), pdf = document("lecture.pdf"), note = document("lecture-note.md")
        navigation.open(pdf)
        let pdfCopy = try XCTUnwrap(navigation.duplicate(pdf.id, direction: .right))
        navigation.openBeside(note, sourceID: pdf.id)
        let noteCopy = try XCTUnwrap(navigation.duplicate(note.id, direction: .below))
        navigation.pageNoteSourceTabIDs = [note.id: pdf.id, noteCopy.id: pdfCopy.id]
        navigation.rename(courseID: "course", from: "lecture.pdf", to: "renamed.pdf", isDirectory: false)
        XCTAssertEqual(navigation.pageNoteSourceTabIDs[note.id], "course:renamed.pdf")
        XCTAssertEqual(navigation.pageNoteSourceTabIDs[noteCopy.id], pdfCopy.id)
        let url = root.appendingPathComponent("workspace.json"); try navigation.save(to: url)
        let reopened = NativeWorkspaceNavigation(); await reopened.restore(from: url) { _ in true }
        XCTAssertEqual(reopened.pageNoteSourceTabIDs, navigation.pageNoteSourceTabIDs)
        reopened.closeTab(pdfCopy.id)
        XCTAssertNil(reopened.pageNoteSourceTabIDs[noteCopy.id])
        XCTAssertEqual(reopened.pageNoteSourceTabIDs[note.id], "course:renamed.pdf")
    }
    func testTypedDuplicateFlushBarrierUsesCanonicalPathAndRetiresEveryPane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root); await store.start(); try await store.createCourse(name: "Course")
        let course = try XCTUnwrap(store.selectedCourseID)
        let original = NativeDocumentReference(courseID: course, relativePath: "nested:notes/chapter.md", title: "Chapter", kind: "note"), copy = original.duplicated()
        var frozen = Set<String>(), flushed = Set<String>(), retired = Set<String>(), replaced: [[String: Any]] = []
        let subscription = store.events.sink { event in if event.channel == "nativeWorkspace:materialReplaced", let row = event.payload as? [String: Any] { replaced.append(row) } }
        let tokens = [original, copy].map { document in store.registerDocumentFlush(id: document.id, document: document,
            freeze: { frozen.insert(document.id) }, retire: { retired.insert(document.id) }, flush: { flushed.insert(document.id) }) }
        defer { subscription.cancel(); tokens.forEach(store.unregisterDocumentFlush) }
        _ = try await store.withExternalMutation {
            XCTAssertEqual(frozen, Set([original.id, copy.id])); XCTAssertEqual(flushed, frozen)
            return ["changedCourseIDs": [course]]
        }
        XCTAssertEqual(retired, Set([original.id, copy.id]))
        XCTAssertEqual(replaced.count, 1, "Storage replacement is broadcast once while all instance callbacks retire")
        XCTAssertEqual(replaced.first?["courseId"] as? String, course)
        XCTAssertEqual(replaced.first?["relPath"] as? String, "nested:notes/chapter.md")
        let oldIdentity = store.reloadIdentity(for: copy)
        var renamed = copy; renamed.relativePath = "new.md"
        XCTAssertEqual(renamed.id, copy.id)
        XCTAssertNotEqual(store.reloadIdentity(for: renamed), oldIdentity)
    }
    func testDockRetainsInactiveMarkdownInstancesUntilClosedWithoutRetainingInactivePDFs() throws {
        typealias Dock = NativeDockWorkspace<EmptyView, EmptyView>
        let navigation = NativeWorkspaceNavigation(), original = document(), pdf = document("lecture.pdf")
        navigation.open(original)
        let copy = try XCTUnwrap(navigation.duplicate(original.id))
        navigation.open(pdf)
        let group = try XCTUnwrap(navigation.focusedGroupID)
        let otherCourse = NativeDocumentReference(courseID: "other", relativePath: "note.md", title: "Other", kind: "note")
        let inactivePDF = document("inactive.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 640)
        func projection() throws -> [Dock.VisibleDocument] {
            let layout = try XCTUnwrap(navigation.layout)
            return Dock.projectDocuments(navigation.documents + [otherCourse, inactivePDF], geometry: layout.geometry(in: bounds), layout: layout, bounds: bounds)
        }
        let initial = try projection()
        XCTAssertEqual(Set(initial.map(\.id)), Set([original.id, copy.id, pdf.id, otherCourse.id]))
        XCTAssertEqual(initial.filter(\.visible).map(\.id), [pdf.id])
        XCTAssertTrue(initial.filter { !$0.visible }.allSatisfy { !bounds.intersects($0.frame) })
        navigation.select(copy.id, in: group)
        let selected = try projection()
        XCTAssertEqual(selected.filter(\.visible).map(\.id), [copy.id])
        XCTAssertTrue(selected.contains { $0.id == original.id && !$0.visible })
        XCTAssertFalse(selected.contains { $0.id == pdf.id }, "Inactive PDF lifetime keeps its existing checkpoint behavior")
        navigation.closeTab(original.id)
        let closed = try projection()
        XCTAssertFalse(closed.contains { $0.id == original.id })
        XCTAssertTrue(closed.contains { $0.id == copy.id && $0.visible })
    }
}
