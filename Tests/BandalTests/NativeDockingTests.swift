import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import Bandal

@MainActor
final class NativeDockingTests: XCTestCase {
    private func document(_ name: String, course: String = "a") -> NativeDocumentReference {
        .init(courseID: course, relativePath: name + ".md", title: name, kind: "note")
    }
    func testDocumentProjectionMatchesTopAndLowerPaneHeadersAndFocusSelector() throws {
        typealias Dock = NativeDockWorkspace<EmptyView, EmptyView>
        let navigation = NativeWorkspaceNavigation(), documents = (0..<4).map { document("\($0)") }
        documents.forEach { navigation.open($0) }
        navigation.apply(.grid)
        let layout = try XCTUnwrap(navigation.layout)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let geometry = layout.geometry(in: bounds)
        let projected = Dock.projectDocuments(documents, geometry: geometry, layout: layout, bounds: bounds)
        XCTAssertEqual(projected.filter(\.visible).count, 4)
        for pane in geometry.panes {
            let editor = try XCTUnwrap(projected.first { $0.groupID == pane.id })
            let expectedHeader: CGFloat = pane.frame.minY == 0 ? 60 : 44
            XCTAssertEqual(editor.frame.minY - pane.frame.minY, expectedHeader)
            XCTAssertEqual(editor.frame.maxY, pane.frame.maxY)
            XCTAssertEqual(editor.frame.width, pane.frame.width)
        }
        let focused = try XCTUnwrap(layout.focused)
        let focusBounds = CGRect(x: 0, y: 44, width: 600, height: 700)
        let focusGeometry = NativeDockGeometry(panes: [.init(group: focused, frame: focusBounds)])
        let focusProjection = Dock.projectDocuments(documents, geometry: focusGeometry, layout: layout, bounds: focusBounds)
        let activeEditor = try XCTUnwrap(focusProjection.first(where: \.visible))
        XCTAssertEqual(activeEditor.frame.minY, 88, "The selector already separates the tab row from the system edge")
        XCTAssertEqual(activeEditor.frame.maxY, focusBounds.maxY)
        XCTAssertEqual(focusProjection.filter(\.visible).count, 1)
        XCTAssertTrue(focusProjection.filter { !$0.visible }.allSatisfy { !focusBounds.intersects($0.frame) })
    }
    func testNestedDirectionsKeepIndependentActiveTabsAndStableGroups() throws {
        let nav = NativeWorkspaceNavigation(), a = document("a"), b = document("b"), c = document("c")
        nav.open(a); nav.open(b); nav.open(c)
        let original = try XCTUnwrap(nav.focusedGroupID)
        nav.move(b.id, to: original, direction: .right)
        let right = try XCTUnwrap(nav.focusedGroupID)
        nav.move(c.id, to: original, direction: .below)
        let below = try XCTUnwrap(nav.focusedGroupID)
        XCTAssertEqual(nav.groups.count, 3)
        XCTAssertEqual(Set(nav.groups.flatMap(\.tabs)), Set([a.id, b.id, c.id]))
        XCTAssertEqual(nav.groups.first { $0.id == original }?.activeID, a.id)
        XCTAssertEqual(nav.groups.first { $0.id == right }?.activeID, b.id)
        XCTAssertEqual(nav.groups.first { $0.id == below }?.activeID, c.id)
        let frames = try XCTUnwrap(nav.layout).geometry(in: CGRect(x: 0, y: 0, width: 1200, height: 900)).panes
        let first = try XCTUnwrap(frames.first { $0.id == original }?.frame)
        let second = try XCTUnwrap(frames.first { $0.id == right }?.frame)
        let third = try XCTUnwrap(frames.first { $0.id == below }?.frame)
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertLessThan(first.maxY, third.minY)
        XCTAssertEqual(first.minX, third.minX)
        XCTAssertEqual(first.width, third.width)
        nav.select(a.id, in: original)
        XCTAssertEqual(nav.active, a)
        XCTAssertEqual(nav.groups.first { $0.id == right }?.activeID, b.id)
    }
    func testReorderUsesDestinationIndexBeforeRemovalAndMoveRetainsEmptyPane() throws {
        let nav = NativeWorkspaceNavigation(), docs = (0..<4).map { document("\($0)") }
        docs.forEach { nav.open($0) }
        let first = try XCTUnwrap(nav.focusedGroupID)
        nav.move(docs[0].id, to: first, index: 3)
        XCTAssertEqual(nav.groups[0].tabs, [docs[1].id, docs[2].id, docs[0].id, docs[3].id])
        nav.move(docs[3].id, to: first, index: 0)
        XCTAssertEqual(nav.groups[0].tabs, [docs[3].id, docs[1].id, docs[2].id, docs[0].id])
        nav.move(docs[0].id, to: first, direction: .left)
        let left = try XCTUnwrap(nav.focusedGroupID)
        nav.move(docs[0].id, to: first, index: 0)
        XCTAssertEqual(nav.groups.count, 2)
        XCTAssertTrue(try XCTUnwrap(nav.groups.first { $0.id == left }).tabs.isEmpty)
        nav.removeEmptyGroup(left)
        XCTAssertEqual(nav.groups.count, 1)
        XCTAssertEqual(nav.focusedGroupID, first)
        XCTAssertEqual(nav.groups[0].tabs.count, 4)
    }
    func testPresetGridUsesBalancedVisualRowOrderAndMergePreservesEveryTab() throws {
        let nav = NativeWorkspaceNavigation(), docs = (0..<9).map { document("\($0)") }
        docs.forEach { nav.open($0) }
        nav.apply(.grid)
        XCTAssertEqual(nav.groups.map { $0.tabs.count }, [3, 2, 2, 2])
        XCTAssertEqual(nav.groups.flatMap(\.tabs), docs.map(\.id))
        XCTAssertEqual(nav.active, docs.last)
        let first = nav.groups[0], second = nav.groups[1]
        nav.merge(second.id, into: first.id)
        XCTAssertEqual(nav.groups.count, 3)
        XCTAssertEqual(Set(nav.groups.flatMap(\.tabs)), Set(docs.map(\.id)))
        nav.apply(.single)
        XCTAssertEqual(nav.groups.count, 1)
        XCTAssertEqual(nav.groups[0].tabs.count, 9)
    }
    func testPerCourseLayoutAndResizeSurvivePersistenceWithMissingDocument() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dock-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let nav = NativeWorkspaceNavigation(), a = document("a"), b = document("b"), c = document("c", course: "b")
        nav.open(a); nav.open(b)
        let first = try XCTUnwrap(nav.focusedGroupID)
        nav.move(b.id, to: first, direction: .below)
        guard case .split(let split) = nav.layout?.root else { return XCTFail("Expected split") }
        nav.resize(split.id, fraction: 0.7)
        let savedA = nav.layout
        nav.open(c); nav.apply(.columns)
        nav.activateCourse("a")
        XCTAssertEqual(nav.layout, savedA)
        try nav.save(to: file)
        let restored = NativeWorkspaceNavigation()
        await restored.restore(from: file) { $0.id != b.id }
        XCTAssertEqual(restored.activeCourseID, "a")
        XCTAssertEqual(restored.groups.count, 2, "An unavailable tab does not discard a saved empty pane")
        XCTAssertEqual(restored.groups.flatMap(\.tabs), [a.id])
        guard case .split(let persisted) = restored.layout?.root else { return XCTFail("Expected saved split") }
        XCTAssertEqual(persisted.fraction, 0.7)
        restored.activateCourse("b")
        XCTAssertEqual(restored.groups.count, 2)
        XCTAssertEqual(restored.groups.flatMap(\.tabs), [c.id])
    }
    func testAdjacentPreferenceAndClosingCurrentTabDoNotDestroyOtherCoursePlacement() throws {
        let nav = NativeWorkspaceNavigation(), a = document("a"), b = document("b"), c = document("c"), foreign = document("foreign", course: "b")
        nav.open(a); nav.open(b)
        let first = try XCTUnwrap(nav.focusedGroupID)
        nav.select(a.id, in: first); nav.openAdjacentTab = true; nav.open(c)
        XCTAssertEqual(nav.groups[0].tabs, [a.id, c.id, b.id])
        nav.open(foreign)
        nav.openBeside(a, sourceID: foreign.id)
        nav.closeTab(a.id)
        XCTAssertTrue(nav.documents.contains(a))
        XCTAssertFalse(nav.groups.flatMap(\.tabs).contains(a.id))
        nav.activateCourse("a")
        XCTAssertTrue(nav.groups.flatMap(\.tabs).contains(a.id))
        nav.remove(courseID: "a", path: a.relativePath, isDirectory: false)
        XCTAssertFalse(nav.documents.contains(a))
        XCTAssertFalse(nav.layouts.values.flatMap { $0.groups.flatMap(\.tabs) }.contains(a.id))
    }
    func testRenameAndCloseOthersKeepAllGroupReferencesValid() throws {
        let nav = NativeWorkspaceNavigation(), a = document("folder/a"), b = document("folder/b"), c = document("folders/c")
        nav.open(a); nav.open(b); nav.open(c); nav.apply(.grid)
        nav.rename(courseID: "a", from: "folder", to: "renamed", isDirectory: true)
        XCTAssertEqual(Set(nav.groups.flatMap(\.tabs)), Set(nav.documents.map(\.id)))
        XCTAssertTrue(nav.documents.contains(c))
        let keep = try XCTUnwrap(nav.documents.first { $0.relativePath == "renamed/a.md" })
        nav.closeOthers(keeping: keep.id)
        XCTAssertEqual(nav.documents, [keep])
        XCTAssertEqual(nav.groups.flatMap(\.tabs), [keep.id])
        XCTAssertEqual(nav.groups.count, 4)
        nav.groups.filter { $0.tabs.isEmpty }.forEach { nav.removeEmptyGroup($0.id) }
        XCTAssertEqual(nav.groups.count, 1)
        XCTAssertEqual(nav.active, keep)
    }
    func testDividerClampAndGeometryDoNotCreateNegativeOrOverlappingPanes() throws {
        var layout = NativeDockLayout(group: NativeDockGroup(tabs: ["a"], activeID: "a"))
        _ = layout.split(layout.focusedGroupID, direction: .right, tabs: ["b"])
        guard case .split(let split) = layout.root else { return XCTFail("Expected split") }
        layout.root = layout.root.resizing(split.id, fraction: .infinity)
        guard case .split(let unchanged) = layout.root else { return XCTFail("Expected split") }
        XCTAssertEqual(unchanged.fraction, 0.5)
        layout.root = layout.root.resizing(split.id, fraction: 0.99)
        let geometry = layout.geometry(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(geometry.panes[1].frame.width, 280)
        XCTAssertEqual(geometry.panes[0].frame.maxX + 8, geometry.panes[1].frame.minX)
        XCTAssertEqual(geometry.panes[1].frame.maxX, 800)
        XCTAssertGreaterThanOrEqual(geometry.panes[0].frame.width, 280)
        let divider = try XCTUnwrap(geometry.dividers.first)
        XCTAssertEqual(divider.frame.width, 8)
        XCTAssertEqual(divider.hitFrame.width, 44)
        XCTAssertEqual(divider.hitFrame.height, 600)
        XCTAssertEqual(divider.hitFrame.midX, divider.frame.midX)
        XCTAssertEqual(divider.displayedFraction, geometry.panes[0].frame.width / 792, accuracy: 0.000001)
        XCTAssertLessThan(divider.displayedFraction, 0.9, "Resize must begin at the clamped seam, not the stored requested fraction")
        var vertical = NativeDockLayout(group: NativeDockGroup(tabs: ["a"], activeID: "a"))
        _ = vertical.split(vertical.focusedGroupID, direction: .below, tabs: ["b"])
        let rowDivider = try XCTUnwrap(vertical.geometry(in: CGRect(x: 10, y: 20, width: 800, height: 600)).dividers.first)
        XCTAssertEqual(rowDivider.frame.height, 8)
        XCTAssertEqual(rowDivider.hitFrame.height, 44)
        XCTAssertEqual(rowDivider.hitFrame.width, 800)
        XCTAssertEqual(rowDivider.hitFrame.midY, rowDivider.frame.midY)
        XCTAssertEqual(rowDivider.displayedFraction, 0.5)
    }
    func testDesktopRailLimitsKeepEditorUsableAfterWindowResize() {
        XCTAssertEqual(NativeDockRailSide.left.clamp(900), 400)
        XCTAssertEqual(NativeDockRailSide.right.clamp(0), 220)
        XCTAssertEqual(NativeDockRailSide.left.clamp(.nan), 240)
        XCTAssertEqual(NativeDockRailSide.right.clamp(.infinity), 288)
        let widths = NativeDockRailWidths.resolve(windowWidth: 1100, leftRequested: 400, rightRequested: 520, showLeft: true, showRight: true)
        XCTAssertGreaterThanOrEqual(1100 - 48 - 2 - widths.left - widths.right, 280)
        XCTAssertGreaterThanOrEqual(widths.left, 176)
        XCTAssertGreaterThanOrEqual(widths.right, 220)
        let single = NativeDockRailWidths.resolve(windowWidth: 900, leftRequested: 400, rightRequested: 520, showLeft: false, showRight: true)
        XCTAssertEqual(single.left, 0)
        XCTAssertEqual(single.right, 520)
    }
    func testLocalTabDragCannotBeConsumedAsEditorText() {
        let provider = NativeDockDragPayload.provider(documentID: "course:document.md")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(NativeDockDragPayload.contentType.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertEqual(provider.registeredTypeIdentifiers, [NativeDockDragPayload.contentType.identifier])
    }
    func testLateToolTitleUpdatesOnlyMatchingWorkspaceAndPreservesLayoutIdentity() async throws {
        let navigation = NativeWorkspaceNavigation()
        let first = NativeDocumentReference(courseID: "a", relativePath: "browser-a", title: "브라우저", kind: "browser")
        let second = NativeDocumentReference(courseID: "b", relativePath: "browser-b", title: "브라우저", kind: "browser")
        let material = NativeDocumentReference(courseID: "b", relativePath: "browser-a", title: "Original PDF", kind: "pdf")
        navigation.open(first); navigation.open(second); navigation.open(material)
        let layouts = navigation.layouts, selected = navigation.activeID
        XCTAssertTrue(navigation.updateToolTitle(workspaceID: "browser-a", title: "Older course page"))
        XCTAssertEqual(navigation.document(first.id)?.title, "Older course page")
        XCTAssertEqual(navigation.document(second.id)?.title, "브라우저")
        XCTAssertEqual(navigation.document(material.id)?.title, "Original PDF")
        XCTAssertEqual(navigation.layouts, layouts)
        XCTAssertEqual(navigation.activeID, selected)
        XCTAssertFalse(navigation.updateToolTitle(workspaceID: "browser-a", title: "   "))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dock-titles-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try navigation.save(to: file)
        let restored = NativeWorkspaceNavigation()
        await restored.restore(from: file) { _ in true }
        XCTAssertEqual(restored.document(first.id)?.title, "Older course page")
        navigation.close(first.id)
        XCTAssertFalse(navigation.updateToolTitle(workspaceID: "browser-a", title: "Page finished after close"))
        XCTAssertNil(navigation.document(first.id))
    }

}
