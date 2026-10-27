import Combine
import Foundation

/// Resource data is shared, but every placement belongs to exactly one window.
/// Captured targets let asynchronous work finish without changing visible focus.
@MainActor
final class NativeWorkspaceNavigation: ObservableObject {
    @Published private(set) var documents: [NativeDocumentReference] = []
    @Published private(set) var windowCollections: [String: NativeWorkspaceWindowCollection] = [:]
    @Published private(set) var activeCourseID: String?
    @Published private(set) var activeWorkspace: NativeWorkspaceContext?
    @Published private(set) var persistenceError: String?
    @Published private(set) var documentDuplicateSourceIDs: [String: String] = [:]
    var pageNoteSourceTabIDs: [String: String] = [:]
    private var projectBindingsByID: [String: NativeLearningBinding] = [:]
    private var revision = 0
    private var migrationBackup: (url: URL, data: Data)?
    private var restorationBlocked = false
    var openAdjacentTab = false
    private var workspaceKey: String? { activeWorkspace?.id ?? activeCourseID.map { "course:" + $0 } }
    var currentWindowRef: NativeWorkspaceWindowRef? {
        guard let key = workspaceKey, let window = windowCollections[key]?.active else { return nil }
        return .init(workspaceID: key, windowID: window.id)
    }
    var currentWindow: NativeWorkspaceWindow? { currentWindowRef.flatMap(window) }
    var windows: [NativeWorkspaceWindow] { workspaceKey.flatMap { windowCollections[$0]?.windows } ?? [] }
    var chromeMode: NativeWorkspaceChromeMode { currentWindow?.chromeMode ?? .all }
    var layout: NativeDockLayout? { currentWindow?.layout }
    /// Read-only compatibility for callers which inspect the selected layout of
    /// a course/project. New code must use a window reference to mutate layouts.
    var layouts: [String: NativeDockLayout] {
        Dictionary(uniqueKeysWithValues: windowCollections.compactMap { key, collection in
            guard let active = collection.active else { return nil }
            return (key.hasPrefix("course:") ? String(key.dropFirst(7)) : key, active.layout)
        })
    }
    var groups: [NativeDockGroup] { layout?.groups ?? [] }
    var focusedGroupID: String? { layout?.focusedGroupID }
    var activeID: String? { layout?.activeID }
    var companionID: String? { groups.first { $0.id != focusedGroupID && $0.activeID != nil }?.activeID }
    var active: NativeDocumentReference? { document(activeID) }
    var companion: NativeDocumentReference? { document(companionID) }
    func document(_ id: String?) -> NativeDocumentReference? { documents.first { $0.id == id } }
    func group(containing id: String) -> NativeDockGroup? { groups.first { $0.tabs.contains(id) } }
    func window(_ ref: NativeWorkspaceWindowRef) -> NativeWorkspaceWindow? {
        windowCollections[ref.workspaceID]?.windows.first { $0.id == ref.windowID }
    }
    func documents(in ref: NativeWorkspaceWindowRef) -> [NativeDocumentReference] {
        (window(ref)?.layout.groups.flatMap(\.tabs) ?? []).compactMap(document)
    }
    /// A window's storage owner is independent of its first document, which may
    /// be a linked resource from another course. Never use the current selection
    /// as a fallback for a captured, possibly inactive destination.
    func courseID(for ref: NativeWorkspaceWindowRef) -> String? {
        guard window(ref) != nil else { return nil }
        if ref.workspaceID.hasPrefix("course:") {
            let id = String(ref.workspaceID.dropFirst("course:".count))
            return id.isEmpty ? nil : id
        }
        if activeWorkspace?.id == ref.workspaceID { return activeWorkspace?.courseID }
        guard ref.workspaceID.hasPrefix("project:") else { return nil }
        return projectBindingsByID[String(ref.workspaceID.dropFirst("project:".count))]?.courseID
    }
    func captureTarget(groupID: String? = nil) -> NativeWorkspaceTarget? {
        currentWindowRef.map { .init(ref: $0, groupID: groupID ?? focusedGroupID) }
    }
    func target(containing documentID: String) -> NativeWorkspaceTarget? {
        for key in windowCollections.keys.sorted() {
            for item in windowCollections[key]!.windows {
                if let group = item.layout.groups.first(where: { $0.tabs.contains(documentID) }) {
                    return .init(ref: .init(workspaceID: key, windowID: item.id), groupID: group.id)
                }
            }
        }
        return nil
    }

    private struct Snapshot: Codable {
        var version: Int?
        var documents: [NativeDocumentReference]
        var activeID: String?
        var companionID: String?
        var layouts: [String: NativeDockLayout]?
        var windowCollections: [String: NativeWorkspaceWindowCollection]?
        var activeCourseID: String?
        var pageNoteSourceTabIDs: [String: String]?
        var activeWorkspace: NativeWorkspaceContext?
        var projectBindings: [String: NativeLearningBinding]?
        var documentDuplicateSourceIDs: [String: String]?
    }
    struct Checkpoint {
        fileprivate let documents: [NativeDocumentReference]
        fileprivate let windowCollections: [String: NativeWorkspaceWindowCollection]
        fileprivate let activeCourseID: String?
        fileprivate let activeWorkspace: NativeWorkspaceContext?
        fileprivate let pageNoteSourceTabIDs: [String: String]
        fileprivate let duplicateSourceIDs: [String: String]
        fileprivate let projectBindings: [String: NativeLearningBinding]
    }
    func checkpoint() -> Checkpoint {
        .init(documents: documents, windowCollections: windowCollections, activeCourseID: activeCourseID,
              activeWorkspace: activeWorkspace, pageNoteSourceTabIDs: pageNoteSourceTabIDs,
              duplicateSourceIDs: documentDuplicateSourceIDs, projectBindings: projectBindingsByID)
    }
    func restoreCheckpoint(_ saved: Checkpoint) {
        revision += 1
        documents = saved.documents; windowCollections = saved.windowCollections
        activeCourseID = saved.activeCourseID; activeWorkspace = saved.activeWorkspace
        pageNoteSourceTabIDs = saved.pageNoteSourceTabIDs; documentDuplicateSourceIDs = saved.duplicateSourceIDs
        projectBindingsByID = saved.projectBindings
    }
    /// No suspension is allowed between a mutation and its durable publication.
    /// The caller performs document/browser close checks before entering here.
    func performPersistedChange<T>(to url: URL, _ action: () throws -> T) throws -> T {
        let before = checkpoint()
        do { let result = try action(); try save(to: url); return result }
        catch { restoreCheckpoint(before); throw error }
    }
    @discardableResult
    private func edit(in ref: NativeWorkspaceWindowRef? = nil, _ action: (inout NativeDockLayout) -> Void) -> Bool {
        guard let ref = ref ?? currentWindowRef, var collection = windowCollections[ref.workspaceID],
              let index = collection.windows.firstIndex(where: { $0.id == ref.windowID }) else { return false }
        revision += 1; action(&collection.windows[index].layout); windowCollections[ref.workspaceID] = collection
        return true
    }
    private func forEachLayout(_ action: (inout NativeDockLayout) -> Void) {
        for key in Array(windowCollections.keys) {
            var collection = windowCollections[key]!
            for index in collection.windows.indices { action(&collection.windows[index].layout) }
            windowCollections[key] = collection
        }
    }
    private func ensureWorkspace(_ key: String) {
        if windowCollections[key] == nil { windowCollections[key] = NativeWorkspaceWindowCollection() }
    }
    func activateCourse(_ id: String) {
        guard activeCourseID != id || activeWorkspace?.kind == .project || currentWindowRef == nil else { return }
        revision += 1; activeWorkspace = nil; activeCourseID = id
        ensureWorkspace("course:" + id)
    }
    func activateWorkspace(_ context: NativeWorkspaceContext) {
        if let projectID = context.projectID, let binding = context.binding { projectBindingsByID[projectID] = binding }
        guard activeWorkspace != context || currentWindowRef == nil else { return }
        revision += 1; activeCourseID = context.courseID; activeWorkspace = context
        ensureWorkspace(context.id)
    }
    func deactivateWorkspace() { revision += 1; activeWorkspace = nil; activeCourseID = nil }

    @discardableResult
    func createWindow() -> NativeWorkspaceWindowRef? {
        guard let key = workspaceKey, var collection = windowCollections[key] else { return nil }
        let usedNames = Set(collection.windows.map(\.name))
        while usedNames.contains("윈도우 \(collection.nextWindowNumber)") {
            guard collection.nextWindowNumber < Int.max else { return nil }; collection.nextWindowNumber += 1
        }
        guard collection.nextWindowNumber < Int.max else { return nil }
        let window = NativeWorkspaceWindow(name: "윈도우 \(collection.nextWindowNumber)")
        collection.nextWindowNumber += 1; collection.windows.append(window); collection.activeWindowID = window.id
        revision += 1; windowCollections[key] = collection
        return .init(workspaceID: key, windowID: window.id)
    }
    @discardableResult
    func selectWindow(_ ref: NativeWorkspaceWindowRef) -> Bool {
        // Selecting a card is scoped to the visible workspace; it cannot change
        // the shared sidebar context as a side effect of a stale UI callback.
        guard ref.workspaceID == workspaceKey, var collection = windowCollections[ref.workspaceID],
              collection.windows.contains(where: { $0.id == ref.windowID }) else { return false }
        guard collection.activeWindowID != ref.windowID else { return true }
        revision += 1; collection.activeWindowID = ref.windowID; windowCollections[ref.workspaceID] = collection
        return true
    }
    @discardableResult
    func renameWindow(_ ref: NativeWorkspaceWindowRef, name: String) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !name.isEmpty, var collection = windowCollections[ref.workspaceID],
              let index = collection.windows.firstIndex(where: { $0.id == ref.windowID }) else { return false }
        revision += 1; collection.windows[index].name = name; windowCollections[ref.workspaceID] = collection
        return true
    }
    @discardableResult
    func moveWindow(_ ref: NativeWorkspaceWindowRef, to index: Int) -> Bool {
        guard var collection = windowCollections[ref.workspaceID],
              let old = collection.windows.firstIndex(where: { $0.id == ref.windowID }) else { return false }
        let window = collection.windows.remove(at: old)
        collection.windows.insert(window, at: min(max(0, index), collection.windows.count))
        revision += 1; windowCollections[ref.workspaceID] = collection; return true
    }
    @discardableResult
    func setChromeMode(_ mode: NativeWorkspaceChromeMode, for ref: NativeWorkspaceWindowRef? = nil) -> Bool {
        guard let ref = ref ?? currentWindowRef, var collection = windowCollections[ref.workspaceID],
              let index = collection.windows.firstIndex(where: { $0.id == ref.windowID }) else { return false }
        revision += 1; collection.windows[index].chromeMode = mode; windowCollections[ref.workspaceID] = collection; return true
    }
    func prepareWindowClose(_ ref: NativeWorkspaceWindowRef) -> NativeWorkspaceWindowClosePlan? {
        guard window(ref) != nil, (windowCollections[ref.workspaceID]?.windows.count ?? 0) > 1 else { return nil }
        return .init(ref: ref, documents: documents(in: ref), revision: revision)
    }
    func canCommitWindowClose(_ plan: NativeWorkspaceWindowClosePlan) -> Bool {
        plan.matches(revision: revision) && window(plan.ref) != nil && (windowCollections[plan.ref.workspaceID]?.windows.count ?? 0) > 1
    }
    @discardableResult
    func commitWindowClose(_ plan: NativeWorkspaceWindowClosePlan) -> Bool {
        guard canCommitWindowClose(plan), var collection = windowCollections[plan.ref.workspaceID],
              let index = collection.windows.firstIndex(where: { $0.id == plan.ref.windowID }) else { return false }
        collection.windows.remove(at: index)
        if collection.activeWindowID == plan.ref.windowID { collection.activeWindowID = collection.windows[min(index, collection.windows.count - 1)].id }
        revision += 1; windowCollections[plan.ref.workspaceID] = collection
        removeUnplacedDocuments(); return true
    }
    private func removeUnplacedDocuments() {
        let valid = Set(windowCollections.values.flatMap(\.windows).flatMap { $0.layout.groups.flatMap(\.tabs) })
        documents.removeAll { !valid.contains($0.id) }
        pageNoteSourceTabIDs = pageNoteSourceTabIDs.filter { valid.contains($0.key) && valid.contains($0.value) }
        documentDuplicateSourceIDs = documentDuplicateSourceIDs.filter { valid.contains($0.key) }
    }
    private func instance(for requested: NativeDocumentReference, in ref: NativeWorkspaceWindowRef, reuseExisting: Bool = true) -> NativeDocumentReference {
        let local = documents(in: ref)
        if reuseExisting {
            if requested.isWorkspaceTool, let existing = local.first(where: { documentDuplicateSourceIDs[$0.id] == requested.id }) { return existing }
            if requested.instanceID == nil {
                let activeID = window(ref)?.layout.activeID
                if let active = local.first(where: { $0.id == activeID && $0.storageID == requested.storageID }) { return active }
                if let exact = local.first(where: { $0.id == requested.id }) { return exact }
                if let existing = local.first(where: { $0.storageID == requested.storageID }) { return existing }
            } else if let exact = local.first(where: { $0.id == requested.id }) { return exact }
        }
        // Retain legacy IDs for the first placement; every additional placement
        // gets its own ID, including generated learning documents and tool scopes.
        if documents.contains(where: { $0.id == requested.id }) {
            let copy = requested.duplicated()
            documentDuplicateSourceIDs[copy.id] = requested.id
            return copy
        }
        return requested
    }
    func open(_ requested: NativeDocumentReference, inGroup groupID: String? = nil, workspace: NativeWorkspaceContext? = nil) {
        if let workspace { activateWorkspace(workspace) }
        else if groupID == nil && activeWorkspace?.kind != .project { activateCourse(requested.courseID) }
        else if activeCourseID == nil { activateCourse(requested.courseID) }
        guard let target = captureTarget(groupID: groupID) else { return }
        _ = open(requested, target: target)
    }
    @discardableResult
    func open(_ requested: NativeDocumentReference, target: NativeWorkspaceTarget) -> NativeDocumentReference? {
        guard window(target.ref) != nil else { return nil }
        let document = instance(for: requested, in: target.ref)
        if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
        let adjacent = openAdjacentTab
        edit(in: target.ref) { layout in
            if let existing = layout.root.groups.first(where: { $0.tabs.contains(document.id) }) {
                layout.focusedGroupID = existing.id; layout.updateGroup(existing.id) { $0.activeID = document.id }
            } else {
                let group = target.groupID.flatMap { id in layout.root.groups.first { $0.id == id } } ?? layout.focused!
                layout.updateGroup(group.id) { pane in
                    let index = adjacent ? pane.activeID.flatMap { pane.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? pane.tabs.count : pane.tabs.count
                    pane.tabs.insert(document.id, at: index); pane.activeID = document.id
                }
                layout.focusedGroupID = group.id
            }
        }
        return document
    }
    @discardableResult
    func duplicate(_ documentID: String, inGroup groupID: String? = nil, direction: NativeDockDirection = .within) -> NativeDocumentReference? {
        guard let source = document(documentID), source.supportsDuplicate,
              let group = groupID.flatMap({ id in groups.first { $0.id == id } }) ?? self.group(containing: documentID) else { return nil }
        let copy = source.duplicated(); documentDuplicateSourceIDs[copy.id] = source.id
        if let linked = pageNoteSourceTabIDs[source.id] { pageNoteSourceTabIDs[copy.id] = linked }
        documents.append(copy)
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
        guard let target = sourceID.flatMap({ self.target(containing: $0) }) ?? captureTarget() else { open(requested); return }
        _ = openBeside(requested, sourceID: sourceID, target: target, reuseExisting: reuseExisting)
    }
    @discardableResult
    func openBeside(_ requested: NativeDocumentReference, sourceID: String?, target: NativeWorkspaceTarget, reuseExisting: Bool = true) -> NativeDocumentReference? {
        guard let layout = window(target.ref)?.layout else { return nil }
        let source = sourceID.flatMap { id in layout.groups.first { $0.tabs.contains(id) } } ?? target.groupID.flatMap { id in layout.groups.first { $0.id == id } } ?? layout.focused!
        let document = instance(for: requested, in: target.ref, reuseExisting: reuseExisting || documents(in: target.ref).contains { $0.id == requested.id })
        if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
        edit(in: target.ref) { layout in
            if let existing = layout.root.groups.first(where: { $0.tabs.contains(document.id) }) {
                layout.updateGroup(existing.id) { $0.activeID = document.id }
                if existing.id == source.id, source.tabs.count > 1 { _ = layout.move(document.id, to: source.id, direction: .right) }
            } else { _ = layout.split(source.id, direction: .right, tabs: [document.id]) }
            layout.focusedGroupID = source.id
        }
        return document
    }
    /// Compatibility for the original two-pane API and its old snapshots.
    func showBeside(_ requested: NativeDocumentReference?) {
        let selected = activeID
        let companion = requested.flatMap { item -> NativeDocumentReference? in
            guard item.id != selected, document(item.id) != nil, let ref = currentWindowRef else { return nil }
            return instance(for: item, in: ref)
        }
        if let companion, document(companion.id) == nil { documents.append(companion) }
        edit { layout in
            layout.apply(.single)
            guard let companion else { return }
            let primaryID = layout.focusedGroupID
            layout.updateGroup(primaryID) { group in group.remove(companion.id); group.activeID = selected }
            _ = layout.split(primaryID, direction: .right, tabs: [companion.id])
            layout.focusedGroupID = primaryID; layout.legacyPair = true
        }
    }
    func close(_ id: String) {
        revision += 1; documents.removeAll { $0.id == id }
        pageNoteSourceTabIDs = pageNoteSourceTabIDs.filter { $0.key != id && $0.value != id }
        documentDuplicateSourceIDs[id] = nil
        forEachLayout { layout in
            let wasActive = layout.activeID == id
            let other = layout.groups.first { $0.id != layout.focusedGroupID && $0.activeID != nil }?.activeID
            let wasVisible = layout.root.groups.contains { $0.activeID == id }
            layout.root = layout.root.mapGroups { item in var group = item; group.remove(id); return group }
            if layout.legacyPair && wasVisible {
                layout.apply(.single)
                if wasActive, let other, let groupID = layout.focused?.id { layout.updateGroup(groupID) { if $0.tabs.contains(other) { $0.activeID = other } } }
            }
        }
    }
    func closeTab(_ id: String) {
        guard let ref = currentWindowRef else { return }
        closeTab(id, in: ref)
    }
    func closeTab(_ id: String, in ref: NativeWorkspaceWindowRef) {
        guard window(ref)?.layout.groups.contains(where: { $0.tabs.contains(id) }) == true else { return }
        edit(in: ref) { layout in layout.root = layout.root.mapGroups { item in var group = item; group.remove(id); return group } }
        removeUnplacedDocuments()
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
            guard documents[index].title != cleaned else { continue }; documents[index].title = cleaned; changed = true
        }
        if changed { revision += 1 }; return changed
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
        pageNoteSourceTabIDs = Dictionary(pageNoteSourceTabIDs.map { (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value) }, uniquingKeysWith: { first, _ in first })
        documentDuplicateSourceIDs = Dictionary(documentDuplicateSourceIDs.map { (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(); documents = documents.filter { seen.insert($0.id).inserted }
        let valid = Set(documents.map(\.id))
        forEachLayout { $0.reconcile(validIDs: valid, replacements: replacements) }
        normalizePlacementIdentities()
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
    static func migrationBackupURL(for url: URL) -> URL { url.appendingPathExtension("pre-windows.backup") }
    static func previousSnapshotURL(for url: URL) -> URL { url.appendingPathExtension("previous") }
    private static func failure(_ message: String) -> NSError { NSError(domain: "NativeWorkspaceNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func restore(from url: URL, projectBindings: [String: NativeLearningBinding] = [:], exists: @escaping @Sendable (NativeDocumentReference) async -> Bool) async {
        let initialRevision = revision
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let data: Data, saved: Snapshot
        do {
            let current = try Data(contentsOf: url)
            if let raw = try? JSONSerialization.jsonObject(with: current) as? [String: Any], let version = raw["version"] as? Int, version > 2 {
                throw Self.failure("더 최신 버전에서 저장한 작업 화면입니다. 원본을 보존하려면 앱을 업데이트해 주세요.")
            }
            if let decoded = try? JSONDecoder().decode(Snapshot.self, from: current) { data = current; saved = decoded }
            else {
                let previous = try Data(contentsOf: Self.previousSnapshotURL(for: url))
                data = previous; saved = try JSONDecoder().decode(Snapshot.self, from: previous)
                persistenceError = "작업 화면 저장 파일을 읽지 못해 직전 상태를 복원했어요."
            }
            guard (saved.version ?? 1) <= 2 else { throw Self.failure("더 최신 버전에서 저장한 작업 화면입니다. 원본을 보존하려면 앱을 업데이트해 주세요.") }
        } catch {
            restorationBlocked = true; persistenceError = error.localizedDescription; return
        }
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
        documents = restored; restorationBlocked = false
        projectBindingsByID = previousBindings
        for projectID in Array(projectBindingsByID.keys) { if let binding = projectBindings[projectID] { projectBindingsByID[projectID] = binding } }
        let valid = Set(restored.map(\.id))
        documentDuplicateSourceIDs = Dictionary((saved.documentDuplicateSourceIDs ?? [:]).map {
            (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value)
        }, uniquingKeysWith: { first, _ in first })
        pageNoteSourceTabIDs = Dictionary((saved.pageNoteSourceTabIDs ?? [:]).map {
            (replacements[$0.key] ?? $0.key, replacements[$0.value] ?? $0.value)
        }, uniquingKeysWith: { first, _ in first }).filter { valid.contains($0.key) && valid.contains($0.value) }
        if let collections = saved.windowCollections {
            windowCollections = collections
        } else {
            windowCollections = Dictionary(uniqueKeysWithValues: (saved.layouts ?? [:]).map { key, layout in
                (key.hasPrefix("project:") ? key : "course:" + key, NativeWorkspaceWindowCollection(layout: layout))
            })
        }
        let savedActiveID = saved.activeID.map { replacements[$0] ?? $0 }
        // Only the oldest ungrouped format needs to reconstruct course layouts.
        // New snapshots must never invent extra course placements for project files.
        if saved.layouts == nil && saved.windowCollections == nil {
            for course in Set(restored.map(\.courseID)) {
                let tabs = restored.filter { $0.courseID == course }.map(\.id)
                windowCollections["course:" + course] = NativeWorkspaceWindowCollection(layout: NativeDockLayout(group: NativeDockGroup(tabs: tabs, activeID: tabs.contains(savedActiveID ?? "") ? savedActiveID : tabs.last)))
            }
        }
        for key in Array(windowCollections.keys) {
            var collection = windowCollections[key]!
            if collection.windows.isEmpty { collection = NativeWorkspaceWindowCollection() }
            var windowIDs = Set<String>()
            for index in collection.windows.indices {
                if !windowIDs.insert(collection.windows[index].id).inserted || collection.windows[index].id.isEmpty { collection.windows[index].id = UUID().uuidString.lowercased() }
                if collection.windows[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { collection.windows[index].name = "윈도우 \(index + 1)" }
                collection.windows[index].layout.reconcile(validIDs: valid, replacements: replacements)
            }
            if !collection.windows.contains(where: { $0.id == collection.activeWindowID }) { collection.activeWindowID = collection.windows[0].id }
            collection.nextWindowNumber = max(collection.nextWindowNumber, collection.windows.count + 1)
            windowCollections[key] = collection
        }
        normalizePlacementIdentities()
        let selected = valid.contains(savedActiveID ?? "") ? savedActiveID : restored.last?.id
        activeCourseID = saved.activeCourseID.flatMap { windowCollections["course:" + $0] == nil ? nil : $0 } ?? document(selected)?.courseID
        activeWorkspace = nil
        if var context = saved.activeWorkspace {
            if let projectID = context.projectID, let binding = projectBindings[projectID] { context.courseID = binding.courseID; context.rootRelPath = binding.rootRelPath }
            activeWorkspace = context; activeCourseID = context.courseID; ensureWorkspace(context.id)
        } else if let activeCourseID { ensureWorkspace("course:" + activeCourseID) }
        if saved.layouts == nil && saved.windowCollections == nil, let companion = document(saved.companionID.map { replacements[$0] ?? $0 }), companion.id != selected { showBeside(companion) }
        if saved.windowCollections == nil { migrationBackup = (url, data) }
    }
    /// The old format permitted one editor ID in both course and project layouts.
    /// Preserve its first placement and seed later panels from its preferences.
    private func normalizePlacementIdentities() {
        var seen = Set<String>()
        for key in windowCollections.keys.sorted() {
            var collection = windowCollections[key]!
            for index in collection.windows.indices {
                var replacements: [String: String] = [:]
                for id in collection.windows[index].layout.groups.flatMap(\.tabs) {
                    guard let original = document(id) else { continue }
                    if seen.insert(id).inserted { continue }
                    let copy = original.duplicated(); documents.append(copy); seen.insert(copy.id)
                    replacements[id] = copy.id; documentDuplicateSourceIDs[copy.id] = original.id
                }
                if !replacements.isEmpty {
                    collection.windows[index].layout.reconcile(validIDs: Set(documents.map(\.id)), replacements: replacements)
                    let previousLinks = pageNoteSourceTabIDs
                    for (old, copy) in replacements {
                        if let source = previousLinks[old] { pageNoteSourceTabIDs[copy] = replacements[source] ?? source }
                    }
                }
            }
            windowCollections[key] = collection
        }
    }
    /// Publish IDs allocated during legacy restoration before previews or user
    /// interaction can refer to them. A failed write retains the pending backup
    /// so the same in-memory migration can be retried without changing IDs.
    func persistPendingMigration(to url: URL) throws {
        guard let pending = migrationBackup else { return }
        guard pending.url == url else { throw Self.failure("이전 작업 화면을 불러온 경로에 저장해 주세요.") }
        try save(to: url)
    }
    func save(to url: URL) throws {
        guard !restorationBlocked else { throw Self.failure(persistenceError ?? "기존 작업 화면을 안전하게 읽지 못해 덮어쓰지 않았습니다.") }
        let snapshot = Snapshot(version: 2, documents: documents, activeID: activeID, companionID: companionID,
            layouts: nil, windowCollections: windowCollections, activeCourseID: activeCourseID, pageNoteSourceTabIDs: pageNoteSourceTabIDs,
            activeWorkspace: activeWorkspace, projectBindings: projectBindingsByID, documentDuplicateSourceIDs: documentDuplicateSourceIDs)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let backup = migrationBackup, backup.url == url {
                let target = Self.migrationBackupURL(for: url)
                if !FileManager.default.fileExists(atPath: target.path) { try backup.data.write(to: target, options: .atomic) }
            }
            if let current = try? Data(contentsOf: url), (try? JSONDecoder().decode(Snapshot.self, from: current)) != nil {
                try current.write(to: Self.previousSnapshotURL(for: url), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            migrationBackup = nil; persistenceError = nil
        } catch { persistenceError = error.localizedDescription; throw error }
    }
}
