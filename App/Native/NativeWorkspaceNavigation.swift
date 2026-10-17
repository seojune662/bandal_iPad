import Combine
import Foundation

/// Every course owns its split tree. A tab instance appears once in any one tree,
/// while the registry keeps resource titles and rename/delete identity coherent.
@MainActor
final class NativeWorkspaceNavigation: ObservableObject {
    @Published private(set) var documents: [NativeDocumentReference] = []
    @Published private(set) var layouts: [String: NativeDockLayout] = [:]
    @Published private(set) var activeCourseID: String?
    var pageNoteSourceTabIDs: [String: String] = [:]
    private var revision = 0
    var openAdjacentTab = false
    var layout: NativeDockLayout? { activeCourseID.flatMap { layouts[$0] } }
    var groups: [NativeDockGroup] { layout?.groups ?? [] }
    var focusedGroupID: String? { layout?.focusedGroupID }
    var activeID: String? { layout?.activeID }
    var companionID: String? { groups.first { $0.id != focusedGroupID && $0.activeID != nil }?.activeID }
    var active: NativeDocumentReference? { document(activeID) }
    var companion: NativeDocumentReference? { document(companionID) }
    func document(_ id: String?) -> NativeDocumentReference? { documents.first { $0.id == id } }
    func group(containing id: String) -> NativeDockGroup? { groups.first { $0.tabs.contains(id) } }

    private struct Snapshot: Codable {
        var documents: [NativeDocumentReference]
        var activeID: String?
        var companionID: String?
        var layouts: [String: NativeDockLayout]?
        var activeCourseID: String?
        var pageNoteSourceTabIDs: [String: String]?
    }
    private func edit(_ action: (inout NativeDockLayout) -> Void) {
        guard let course = activeCourseID else { return }
        revision += 1
        var next = layouts[course] ?? NativeDockLayout(); action(&next); layouts[course] = next
    }
    func activateCourse(_ id: String) {
        guard activeCourseID != id else { return }
        revision += 1; activeCourseID = id
        if layouts[id] == nil {
            let tabs = documents.filter { $0.courseID == id }.map(\.id)
            layouts[id] = NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.last))
        }
    }
    private func existingInstance(for document: NativeDocumentReference) -> NativeDocumentReference {
        guard document.instanceID == nil else { return document }
        if let active, active.storageID == document.storageID { return active }
        return documents.first { $0.storageID == document.storageID && $0.instanceID == nil }
            ?? documents.first { $0.storageID == document.storageID } ?? document
    }
    func open(_ requested: NativeDocumentReference, inGroup groupID: String? = nil) {
        let document = existingInstance(for: requested)
        revision += 1
        if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
        if groupID == nil { activateCourse(document.courseID) }
        else if activeCourseID == nil { activateCourse(document.courseID) }
        edit { layout in
            if let existing = layout.root.groups.first(where: { $0.tabs.contains(document.id) }) {
                layout.focusedGroupID = existing.id; layout.updateGroup(existing.id) { $0.activeID = document.id }
            } else {
                let target = groupID.flatMap { id in layout.root.groups.first { $0.id == id } } ?? layout.focused!
                layout.updateGroup(target.id) { group in
                    let index = openAdjacentTab ? group.activeID.flatMap { group.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? group.tabs.count : group.tabs.count
                    group.tabs.insert(document.id, at: index); group.activeID = document.id
                }
                layout.focusedGroupID = target.id
            }
        }
    }
    @discardableResult
    func duplicate(_ documentID: String, inGroup groupID: String? = nil, direction: NativeDockDirection = .within) -> NativeDocumentReference? {
        guard let source = document(documentID), source.supportsDuplicate,
              let group = groupID.flatMap({ id in groups.first { $0.id == id } }) ?? self.group(containing: documentID) else { return nil }
        let copy = source.duplicated()
        if let linked = pageNoteSourceTabIDs[source.id] { pageNoteSourceTabIDs[copy.id] = linked }
        revision += 1; documents.append(copy)
        edit { layout in
            if direction == .within {
                layout.updateGroup(group.id) { target in
                    let index = target.tabs.firstIndex(of: source.id).map { $0 + 1 } ?? target.tabs.count
                    target.tabs.insert(copy.id, at: index); target.activeID = copy.id
                }
                layout.focusedGroupID = group.id
            } else { _ = layout.split(group.id, direction: direction, tabs: [copy.id]) }
        }
        return copy
    }
    func select(_ documentID: String, in groupID: String) {
        edit { layout in
            guard layout.root.groups.contains(where: { $0.id == groupID && $0.tabs.contains(documentID) }) else { return }
            layout.updateGroup(groupID) { $0.activeID = documentID }; layout.focusedGroupID = groupID
        }
    }
    func focus(_ groupID: String) {
        guard focusedGroupID != groupID else { return }
        edit { if $0.root.groups.contains(where: { $0.id == groupID }) { $0.focusedGroupID = groupID } }
    }
    func split(_ groupID: String, direction: NativeDockDirection) { edit { _ = $0.split(groupID, direction: direction) } }
    func move(_ documentID: String, to groupID: String, direction: NativeDockDirection = .within, index: Int? = nil) {
        edit { _ = $0.move(documentID, to: groupID, direction: direction, index: index) }
    }
    func resize(_ splitID: String, fraction: Double) { edit { $0.root = $0.root.resizing(splitID, fraction: fraction) } }
    func apply(_ preset: NativeDockPreset) { edit { $0.apply(preset) } }
    func removeEmptyGroup(_ id: String) { edit { $0.removeEmptyGroup(id) } }
    func merge(_ id: String, into target: String) { edit { $0.merge(id, into: target) } }
    func openBeside(_ requested: NativeDocumentReference, sourceID: String?, reuseExisting: Bool = true) {
        let document = reuseExisting ? existingInstance(for: requested) : requested
        guard let source = sourceID.flatMap({ group(containing: $0) }) ?? layout?.focused else { open(document); return }
        if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
        edit { layout in
            if let existing = layout.root.groups.first(where: { $0.tabs.contains(document.id) }) {
                layout.updateGroup(existing.id) { $0.activeID = document.id }
                if existing.id == source.id, source.tabs.count > 1 { _ = layout.move(document.id, to: source.id, direction: .right) }
            } else { _ = layout.split(source.id, direction: .right, tabs: [document.id]) }
            // Linked notes open beside their PDF while the source keeps navigation focus.
            layout.focusedGroupID = source.id
        }
    }
    /// Compatibility for pre-docking callers and version-one saved workspaces.
    func showBeside(_ document: NativeDocumentReference?) {
        let selected = activeID
        edit { layout in
            layout.apply(.single)
            guard let document, document.id != selected, documents.contains(where: { $0.id == document.id }) else { return }
            let primaryID = layout.focusedGroupID
            layout.updateGroup(primaryID) { group in group.remove(document.id); group.activeID = selected }
            _ = layout.split(primaryID, direction: .right, tabs: [document.id])
            layout.focusedGroupID = primaryID; layout.legacyPair = true
        }
    }
    func close(_ id: String) {
        revision += 1; documents.removeAll { $0.id == id }; pageNoteSourceTabIDs = pageNoteSourceTabIDs.filter { $0.key != id && $0.value != id }
        for course in Array(layouts.keys) {
            var layout = layouts[course]!
            let wasActive = layout.activeID == id
            let other = layout.groups.first { $0.id != layout.focusedGroupID && $0.activeID != nil }?.activeID
            let wasVisible = layout.root.groups.contains { $0.activeID == id }
            layout.root = layout.root.mapGroups { item in var group = item; group.remove(id); return group }
            if layout.legacyPair && wasVisible {
                layout.apply(.single)
                if wasActive, let other, let groupID = layout.focused?.id { layout.updateGroup(groupID) { if $0.tabs.contains(other) { $0.activeID = other } } }
            }
            layouts[course] = layout
        }
    }
    /// Closing a tab affects this course's placement. Another course may refer
    /// to the same material; only a material deletion removes every placement.
    func closeTab(_ id: String) {
        edit { layout in
            layout.root = layout.root.mapGroups { item in var group = item; group.remove(id); return group }
        }
        if !layouts.values.contains(where: { $0.root.groups.contains { $0.tabs.contains(id) } }) {
            documents.removeAll { $0.id == id }; pageNoteSourceTabIDs = pageNoteSourceTabIDs.filter { $0.key != id && $0.value != id }
        }
    }
    func closeOthers(keeping id: String, groupID: String? = nil) {
        let ids = groupID.flatMap { wanted in groups.first { $0.id == wanted }?.tabs } ?? groups.flatMap(\.tabs)
        ids.filter { $0 != id }.forEach(closeTab)
    }
    func closeToRight(of id: String, in groupID: String) {
        guard let tabs = groups.first(where: { $0.id == groupID })?.tabs, let index = tabs.firstIndex(of: id) else { return }
        Array(tabs.dropFirst(index + 1)).forEach(closeTab)
    }
    func updateTitle(_ title: String, for id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].title != title else { return }
        revision += 1; documents[index].title = title
    }
    @discardableResult
    func updateToolTitle(workspaceID: String, title: String) -> Bool {
        let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !workspaceID.isEmpty, !cleaned.isEmpty else { return false }
        var changed = false
        for index in documents.indices where documents[index].isWorkspaceTool && documents[index].relativePath == workspaceID {
            guard documents[index].title != cleaned else { continue }
            documents[index].title = cleaned; changed = true
        }
        if changed { revision += 1 }
        return changed
    }
    func rename(courseID: String, from: String, to: String, isDirectory: Bool) {
        revision += 1; var replacements: [String: String] = [:]
        for index in documents.indices {
            let item = documents[index]
            guard !item.isWorkspaceTool, item.courseID == courseID, item.relativePath == from || (isDirectory && item.relativePath.hasPrefix(from + "/")) else { continue }
            let path = to + item.relativePath.dropFirst(from.count)
            documents[index] = NativeDocumentReference(courseID: courseID, relativePath: path, title: (path as NSString).lastPathComponent, kind: item.kind, instanceID: item.instanceID)
            replacements[item.id] = documents[index].id
        }
        pageNoteSourceTabIDs = Dictionary(uniqueKeysWithValues: pageNoteSourceTabIDs.map { (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value) })
        var seen = Set<String>(); documents = documents.filter { seen.insert($0.id).inserted }
        let valid = Set(documents.map(\.id))
        for course in Array(layouts.keys) { layouts[course]?.reconcile(validIDs: valid, replacements: replacements) }
    }
    func remove(courseID: String, path: String, isDirectory: Bool) {
        documents.filter { !$0.isWorkspaceTool && $0.courseID == courseID && ($0.relativePath == path || (isDirectory && $0.relativePath.hasPrefix(path + "/"))) }.map(\.id).forEach(close)
    }
    func restore(from url: URL, exists: (NativeDocumentReference) async -> Bool) async {
        let initialRevision = revision
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        var restored: [NativeDocumentReference] = []
        for item in saved.documents where !restored.contains(where: { $0.id == item.id }) { if await exists(item) { restored.append(item) } }
        guard revision == initialRevision else { return }
        documents = restored
        let valid = Set(restored.map(\.id))
        layouts = saved.layouts ?? [:]
        pageNoteSourceTabIDs = (saved.pageNoteSourceTabIDs ?? [:]).filter { valid.contains($0.key) && valid.contains($0.value) }
        for course in Array(layouts.keys) { layouts[course]?.reconcile(validIDs: valid) }
        for course in Set(restored.map(\.courseID)) where layouts[course] == nil {
            let tabs = restored.filter { $0.courseID == course }.map(\.id)
            layouts[course] = NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.contains(saved.activeID ?? "") ? saved.activeID : tabs.last))
        }
        let selected = valid.contains(saved.activeID ?? "") ? saved.activeID : restored.last?.id
        activeCourseID = saved.activeCourseID.flatMap { layouts[$0] == nil ? nil : $0 } ?? document(selected)?.courseID
        if saved.layouts == nil, let companion = document(saved.companionID), companion.id != selected { showBeside(companion) }
    }
    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Snapshot(documents: documents, activeID: activeID, companionID: companionID, layouts: layouts, activeCourseID: activeCourseID, pageNoteSourceTabIDs: pageNoteSourceTabIDs))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
