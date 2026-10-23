import Combine
import Foundation

/// Every course owns its split tree. A tab instance appears once in any one tree,
/// while the registry keeps resource titles and rename/delete identity coherent.
@MainActor
final class NativeWorkspaceNavigation: ObservableObject {
    @Published private(set) var documents: [NativeDocumentReference] = []
    @Published private(set) var layouts: [String: NativeDockLayout] = [:]
    @Published private(set) var activeCourseID: String?
    @Published private(set) var activeWorkspace: NativeWorkspaceContext?
    var pageNoteSourceTabIDs: [String: String] = [:]
    private var projectBindingsByID: [String: NativeLearningBinding] = [:]
    private var revision = 0
    var openAdjacentTab = false
    private var layoutKey: String? { activeWorkspace?.kind == .project ? activeWorkspace?.id : activeCourseID }
    var layout: NativeDockLayout? { layoutKey.flatMap { layouts[$0] } }
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
        var activeWorkspace: NativeWorkspaceContext?
        var projectBindings: [String: NativeLearningBinding]?
    }
    private func edit(_ action: (inout NativeDockLayout) -> Void) {
        guard let course = layoutKey else { return }
        revision += 1
        var next = layouts[course] ?? NativeDockLayout(); action(&next); layouts[course] = next
    }
    func activateCourse(_ id: String) {
        guard activeCourseID != id || activeWorkspace?.kind == .project else { return }
        activeWorkspace = nil
        revision += 1; activeCourseID = id
        if layouts[id] == nil {
            let tabs = documents.filter { $0.courseID == id }.map(\.id)
            layouts[id] = NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.last))
        }
    }
    func activateWorkspace(_ context: NativeWorkspaceContext) {
        if context.kind == .course {
            activateCourse(context.courseID)
            activeWorkspace = context
            return
        }
        if let projectID = context.projectID, let binding = context.binding { projectBindingsByID[projectID] = binding }
        guard activeWorkspace != context else { return }
        revision += 1; activeCourseID = context.courseID; activeWorkspace = context
        if layouts[context.id] == nil {
            // A legacy learning workspace was one tab inside its storage course.
            // Copy its placement without stealing unrelated course documents.
            let tabs = documents.filter { document in
                document.learningTarget.map { $0.projectID == context.projectID } == true ||
                    document.kind == "learning" && document.courseID == context.courseID && document.relativePath == context.rootRelPath
            }.map(\.id)
            layouts[context.id] = NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.last))
        }
    }
    func deactivateWorkspace() {
        revision += 1; activeWorkspace = nil; activeCourseID = nil
    }
    private func existingInstance(for document: NativeDocumentReference) -> NativeDocumentReference {
        guard document.instanceID == nil else { return document }
        if let active, active.storageID == document.storageID { return active }
        return documents.first { $0.storageID == document.storageID && $0.instanceID == nil }
            ?? documents.first { $0.storageID == document.storageID } ?? document
    }
    func open(_ requested: NativeDocumentReference, inGroup groupID: String? = nil, workspace: NativeWorkspaceContext? = nil) {
        if let workspace { activateWorkspace(workspace) }
        let document = existingInstance(for: requested)
        revision += 1
        if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
        if workspace == nil && groupID == nil && activeWorkspace?.kind != .project { activateCourse(document.courseID) }
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
            var renamed = item
            renamed.relativePath = path
            if var target = renamed.learningTarget {
                target.binding = NativeLearningBinding(courseID: courseID, rootRelPath: path)
                renamed.learningTarget = target
            } else { renamed.title = (path as NSString).lastPathComponent }
            documents[index] = renamed
            replacements[item.id] = documents[index].id
        }
        pageNoteSourceTabIDs = Dictionary(uniqueKeysWithValues: pageNoteSourceTabIDs.map { (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value) })
        var seen = Set<String>(); documents = documents.filter { seen.insert($0.id).inserted }
        let valid = Set(documents.map(\.id))
        for course in Array(layouts.keys) { layouts[course]?.reconcile(validIDs: valid, replacements: replacements) }
        if var workspace = activeWorkspace, workspace.courseID == courseID,
           workspace.rootRelPath == from || isDirectory && workspace.rootRelPath.hasPrefix(from + "/") {
            workspace.rootRelPath = to + workspace.rootRelPath.dropFirst(from.count)
            activeWorkspace = workspace
        }
        for (projectID, binding) in projectBindingsByID where binding.courseID == courseID &&
            (binding.rootRelPath == from || isDirectory && binding.rootRelPath.hasPrefix(from + "/")) {
            projectBindingsByID[projectID] = .init(courseID: courseID, rootRelPath: to + binding.rootRelPath.dropFirst(from.count))
        }
    }
    func remove(courseID: String, path: String, isDirectory: Bool) {
        documents.filter { !$0.isWorkspaceTool && $0.courseID == courseID && ($0.relativePath == path || (isDirectory && $0.relativePath.hasPrefix(path + "/"))) }.map(\.id).forEach(close)
    }
    func restore(from url: URL, projectBindings: [String: NativeLearningBinding] = [:], exists: @escaping @Sendable (NativeDocumentReference) async -> Bool) async {
        let initialRevision = revision
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        // Older snapshots only know the active project and generated targets.
        // Retain every visited project's previous root in newer snapshots so a
        // moved, inactive project's ordinary files can also retain their panes.
        var previousBindings = saved.projectBindings ?? [:]
        if let context = saved.activeWorkspace, let projectID = context.projectID, let binding = context.binding {
            previousBindings[projectID] = binding
        }
        for target in saved.documents.compactMap(\.learningTarget) where previousBindings[target.projectID] == nil {
            previousBindings[target.projectID] = target.binding
        }
        let roots = previousBindings.sorted {
            if $0.value.rootRelPath.count != $1.value.rootRelPath.count { return $0.value.rootRelPath.count > $1.value.rootRelPath.count }
            return $0.key < $1.key
        }
        // One storage call per saved tab, in parallel instead of one after another.
        var unique: [NativeDocumentReference] = [], replacements: [String: String] = [:]
        for var item in saved.documents {
            let previousID = item.id
            if var target = item.learningTarget, let binding = projectBindings[target.projectID] {
                target.binding = binding; item.learningTarget = target
                item.courseID = binding.courseID; item.relativePath = binding.rootRelPath
            } else if item.learningTarget == nil, !item.isWorkspaceTool,
                      let previous = roots.first(where: { entry in
                          let binding = entry.value
                          return item.courseID == binding.courseID && (binding.rootRelPath.isEmpty || item.relativePath == binding.rootRelPath || item.relativePath.hasPrefix(binding.rootRelPath + "/"))
                      }), let binding = projectBindings[previous.key], binding != previous.value {
                let oldRoot = previous.value.rootRelPath
                let suffix = oldRoot.isEmpty ? item.relativePath : String(item.relativePath.dropFirst(oldRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                item.courseID = binding.courseID
                item.relativePath = [binding.rootRelPath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
            }
            if previousID != item.id { replacements[previousID] = item.id }
            if !unique.contains(where: { $0.id == item.id }) { unique.append(item) }
        }
        let present = await withTaskGroup(of: (Int, Bool).self, returning: Set<Int>.self) { group in
            for (index, item) in unique.enumerated() { group.addTask { (index, await exists(item)) } }
            var result = Set<Int>()
            for await (index, ok) in group where ok { result.insert(index) }
            return result
        }
        let restored = unique.enumerated().filter { present.contains($0.offset) }.map(\.element)
        guard revision == initialRevision else { return }
        documents = restored
        projectBindingsByID = previousBindings
        for projectID in Array(projectBindingsByID.keys) {
            if let binding = projectBindings[projectID] { projectBindingsByID[projectID] = binding }
        }
        let valid = Set(restored.map(\.id))
        layouts = saved.layouts ?? [:]
        pageNoteSourceTabIDs = Dictionary((saved.pageNoteSourceTabIDs ?? [:]).map {
            (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value)
        }, uniquingKeysWith: { first, _ in first }).filter { valid.contains($0.key) && valid.contains($0.value) }
        for course in Array(layouts.keys) { layouts[course]?.reconcile(validIDs: valid, replacements: replacements) }
        let savedActiveID = saved.activeID.map { replacements[$0] ?? $0 }
        for course in Set(restored.map(\.courseID)) where layouts[course] == nil {
            let tabs = restored.filter { $0.courseID == course }.map(\.id)
            layouts[course] = NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.contains(savedActiveID ?? "") ? savedActiveID : tabs.last))
        }
        let selected = valid.contains(savedActiveID ?? "") ? savedActiveID : restored.last?.id
        activeCourseID = saved.activeCourseID.flatMap { layouts[$0] == nil ? nil : $0 } ?? document(selected)?.courseID
        if var context = saved.activeWorkspace {
            if let projectID = context.projectID, let binding = projectBindings[projectID] {
                context.courseID = binding.courseID; context.rootRelPath = binding.rootRelPath
            }
            activeWorkspace = context
            activeCourseID = context.courseID
            if layouts[context.id] == nil && context.kind == .project { layouts[context.id] = NativeDockLayout() }
        }
        if saved.layouts == nil, let companion = document(saved.companionID.map { replacements[$0] ?? $0 }), companion.id != selected { showBeside(companion) }
    }
    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Snapshot(documents: documents, activeID: activeID, companionID: companionID, layouts: layouts, activeCourseID: activeCourseID, pageNoteSourceTabIDs: pageNoteSourceTabIDs, activeWorkspace: activeWorkspace, projectBindings: projectBindingsByID))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
