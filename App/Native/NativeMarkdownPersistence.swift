import Combine
import CryptoKit
import Foundation

struct NativeMarkdownDraft: Codable, Equatable {
    let markdown: String
    let expectedMtime: Double
}

/// The draft is independent of the source file. Failed/conflicting repository
/// writes never overwrite that file, and process termination retains the draft.
struct NativeMarkdownDraftFile {
    let url: URL
    init(url: URL) { self.url = url }
    init(documentID: String, directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeMarkdownDrafts", isDirectory: true)
        let key = SHA256.hash(data: Data(documentID.utf8)).map { String(format: "%02x", $0) }.joined()
        url = root.appendingPathComponent(key + ".json")
    }
    func read() throws -> NativeMarkdownDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(NativeMarkdownDraft.self, from: Data(contentsOf: url))
    }
    func write(_ draft: NativeMarkdownDraft) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// The shared storage owns one draft, expected revision and write drain. Each
/// view owns this separate facade, so UIKit/IME/Undo callbacks never overwrite
/// those of another pane displaying the same resource.
@MainActor
final class NativeMarkdownSession: ObservableObject {
    typealias Invoke = @MainActor (String, [String: Any]) async throws -> Any
    private final class WeakStorage { weak var value: NativeMarkdownStorage?; init(_ value: NativeMarkdownStorage) { self.value = value } }
    private static var storages: [String: WeakStorage] = [:]
    @Published private var notificationRevision = 0
    fileprivate let token = UUID()
    private let storage: NativeMarkdownStorage
    private let draftFile: NativeMarkdownDraftFile
    private let conflictDraft: NativeMarkdownDraftFile
    private var subscription: AnyCancellable?
    private var paneError: String?
    private(set) var isComposing = false
    var prepareForFlush: (() -> Void)?
    var applyFormat: ((String) -> Void)?
    var setEditingEnabled: ((Bool) -> Void)?
    var onContentChanged: (() -> Void)?
    var applyRemoteText: ((Bool) -> Void)?

    var text: String { storage.text }
    var loading: Bool { storage.loading }
    var saving: Bool { storage.saving }
    var dirty: Bool { storage.dirty }
    var errorMessage: String? { paneError ?? storage.errorMessage ?? (storage.recoveries.isEmpty ? nil : NativeMarkdownTextChange.Conflict().localizedDescription) }
    var recoveredDraft: Bool { storage.recoveredDraft }
    var frozen: Bool { storage.frozen || storage.hasRecovery(for: conflictDraft) }
    var retired: Bool { storage.retired }
    var canEdit: Bool { storage.canEdit }

    init(courseID: String, relativePath: String, draftFile: NativeMarkdownDraftFile, sharedKey: String? = nil, paneID: String? = nil, debounceNanoseconds: UInt64 = 450_000_000, invoke: @escaping Invoke) {
        self.draftFile = draftFile
        let paneKey = SHA256.hash(data: Data((paneID ?? UUID().uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        conflictDraft = .init(url: draftFile.url.deletingPathExtension().appendingPathExtension("pane-\(paneKey).json"))
        if let sharedKey, let existing = Self.storages[sharedKey]?.value, !existing.retired { storage = existing }
        else {
            storage = NativeMarkdownStorage(courseID: courseID, relativePath: relativePath, draftFile: draftFile, debounceNanoseconds: debounceNanoseconds, invoke: invoke)
            if let sharedKey {
                Self.storages = Self.storages.filter { $0.value.value != nil }
                Self.storages[sharedKey] = WeakStorage(storage)
            }
        }
        storage.attach(self)
        subscription = storage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    init(sharing session: NativeMarkdownSession, paneID: String) {
        storage = session.storage; draftFile = session.draftFile
        let key = SHA256.hash(data: Data(paneID.utf8)).map { String(format: "%02x", $0) }.joined()
        conflictDraft = .init(url: draftFile.url.deletingPathExtension().appendingPathExtension("pane-\(key).json"))
        storage.attach(self)
        subscription = storage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func load() async {
        await storage.load()
    }
    func reportProjectionError(_ message: String) { objectWillChange.send(); paneError = message }
    func preserveUnmergedText(_ value: String) {
        guard !retired else { return }
        objectWillChange.send()
        defer { setEditingEnabled?(false) }
        do { try storage.preserveRecovery(value, file: conflictDraft)
            paneError = nil
        } catch { paneError = "겹친 편집을 임시 저장하지 못했어요. 사본으로 보관해 주세요. \(error.localizedDescription)" }
    }
    @discardableResult
    func update(_ value: String, isComposing: Bool, base: String? = nil) -> Bool {
        guard canEdit, !frozen, !retired else { return false }
        self.isComposing = isComposing
        do {
            let merged = try NativeMarkdownTextChange.rebase(from: base ?? text, to: value, onto: text)
            let changed = merged != text
            storage.origin = token; defer { storage.origin = nil }
            storage.update(merged, isComposing: isComposing)
            if changed { onContentChanged?() }
            return true
        } catch { preserveUnmergedText(value); return false }
    }
    fileprivate func receiveSharedText(reset: Bool) { applyRemoteText?(reset) }
    func flush(commitComposition: Bool = true) async throws {
        try await storage.flush(commitComposition: commitComposition)
        if !storage.recoveries.isEmpty { throw NativeMarkdownTextChange.Conflict() }
    }
    func freezeForMaterialMutation() { storage.freezeForMaterialMutation() }
    func suspendWritesForMaterialMutation() { storage.suspendWritesForMaterialMutation() }
    func cancelMaterialMutation() { storage.cancelMaterialMutation() }
    func retireAfterMaterialMutation() { storage.retireAfterMaterialMutation() }
    func reloadDiscardingDraft() async throws {
        try await storage.reloadDiscardingDraft()
        try storage.removeAllRecoveries()
        objectWillChange.send(); paneError = nil
    }
    func keepCopy(using create: @MainActor () async throws -> NativeDocumentReference) async throws {
        let recovery = recoveryToResolve
        try await storage.keepCopy(value: recovery?.value.markdown, using: create)
        if let recovery { try storage.removeRecovery(recovery.key, expected: recovery.value); objectWillChange.send(); paneError = nil }
    }
    private var recoveryToResolve: (key: String, value: NativeMarkdownDraft)? {
        if let own = storage.recoveries[conflictDraft.url.path] { return (conflictDraft.url.path, own) }
        if let variant = storage.recoveries.sorted(by: { $0.key < $1.key }).first(where: { $0.key.hasPrefix(conflictDraft.url.deletingPathExtension().path + ".") }) { return variant }
        return storage.recoveries.sorted { $0.key < $1.key }.first
    }
}

@MainActor
private final class NativeMarkdownStorage: ObservableObject {
    typealias Invoke = @MainActor (String, [String: Any]) async throws -> Any
    @Published private(set) var text = "" { didSet { if text != oldValue || resetsEditors { publishTextChange() } } }
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published private(set) var dirty = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveredDraft = false
    @Published private(set) var frozen = false
    @Published private(set) var retired = false
    @Published private(set) var recoveries: [String: NativeMarkdownDraft] = [:]
    var prepareForFlush: (() -> Void)?
    var applyFormat: ((String) -> Void)?
    var setEditingEnabled: ((Bool) -> Void)?
    var onContentChanged: (() -> Void)?

    private let courseID: String
    private let relativePath: String
    private let invoke: Invoke
    private let draftFile: NativeMarkdownDraftFile
    private let debounceNanoseconds: UInt64
    private var expectedMtime: Double?
    private var savedText = ""
    private var loaded = false
    private var composing: Bool { clients.values.contains { $0.value?.isComposing == true } }
    private var conflict = false
    private var writesSuspended = false
    private var loadFlight: Task<Void, Error>?
    private var saveFlight: Task<Void, Error>?
    private var debounce: Task<Void, Never>?
    var canEdit: Bool { loaded }
    var recoveryMtime: Double { expectedMtime ?? 0 }
    func hasRecovery(for file: NativeMarkdownDraftFile) -> Bool {
        recoveries.keys.contains { $0 == file.url.path || $0.hasPrefix(file.url.deletingPathExtension().path + ".") }
    }
    func preserveRecovery(_ markdown: String, file: NativeMarkdownDraftFile) throws {
        let value = NativeMarkdownDraft(markdown: markdown, expectedMtime: recoveryMtime)
        let prefix = file.url.deletingPathExtension().path + "."
        if recoveries.contains(where: { ($0.key == file.url.path || $0.key.hasPrefix(prefix)) && $0.value.markdown == markdown }) { return }
        // UIKit may finish an already-marked composition while a lifecycle
        // barrier is freezing this pane. Retain both candidates; never replace
        // the first unresolved recovery with a later flush callback.
        let target = recoveries[file.url.path] == nil ? file : NativeMarkdownDraftFile(url: file.url.deletingPathExtension().appendingPathExtension(UUID().uuidString + ".json"))
        recoveries[target.url.path] = value
        try target.write(value)
    }
    func removeRecovery(_ path: String, expected: NativeMarkdownDraft) throws {
        guard recoveries[path] == expected else { return }
        try NativeMarkdownDraftFile(url: URL(fileURLWithPath: path)).remove()
        recoveries.removeValue(forKey: path)
        for client in clients.values.compactMap(\.value) { client.setEditingEnabled?(!client.frozen && !client.retired) }
    }
    func removeAllRecoveries() throws {
        for (path, value) in recoveries { try removeRecovery(path, expected: value) }
    }
    private func loadRecoveries() throws {
        let directory = draftFile.url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let prefix = draftFile.url.deletingPathExtension().lastPathComponent + ".pane-"
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            if let value = try NativeMarkdownDraftFile(url: url).read() { recoveries[url.path] = value }
        }
    }
    private final class Client { weak var value: NativeMarkdownSession?; init(_ value: NativeMarkdownSession) { self.value = value } }
    private var clients: [UUID: Client] = [:]
    var origin: UUID?
    var resetsEditors = false
    func attach(_ session: NativeMarkdownSession) {
        clients = clients.filter { $0.value.value != nil }
        clients[session.token] = Client(session)
        prepareForFlush = { [weak self] in self?.clients.values.compactMap(\.value).forEach { $0.prepareForFlush?() } }
        setEditingEnabled = { [weak self] enabled in self?.clients.values.compactMap(\.value).forEach { $0.setEditingEnabled?(enabled) } }
    }
    private func publishTextChange() {
        for client in clients.values.compactMap(\.value) where client.token != origin { client.receiveSharedText(reset: resetsEditors) }
    }

    init(courseID: String, relativePath: String, draftFile: NativeMarkdownDraftFile, debounceNanoseconds: UInt64 = 450_000_000, invoke: @escaping Invoke) {
        self.courseID = courseID; self.relativePath = relativePath; self.draftFile = draftFile
        self.debounceNanoseconds = debounceNanoseconds; self.invoke = invoke
    }

    func load() async {
        do { try await ensureLoaded() }
        catch { errorMessage = error.localizedDescription; loading = false }
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        if let loadFlight { return try await loadFlight.value }
        loading = true
        let task = Task { @MainActor [self] in
            guard let result = try await invoke("notes:read", identity) as? [String: Any],
                  let markdown = result["markdown"] as? String,
                  let mtime = (result["mtime"] as? NSNumber)?.doubleValue, mtime.isFinite else {
                throw DesktopRuntimeError("노트 내용을 읽지 못했습니다.")
            }
            let draft = try draftFile.read()
            try loadRecoveries()
            resetsEditors = true; defer { resetsEditors = false }
            savedText = markdown; expectedMtime = mtime; text = markdown
            if let draft, draft.markdown != markdown {
                text = draft.markdown; dirty = true; recoveredDraft = true
                expectedMtime = draft.expectedMtime
                if draft.expectedMtime != mtime {
                    conflict = true
                    errorMessage = "저장하지 못한 내용과 파일의 새 버전이 모두 있어요. 내용을 사본으로 보관하거나 파일을 다시 읽어 주세요."
                }
            } else { try? draftFile.remove() }
            loaded = true; loading = false
            if dirty && !conflict && !frozen && !retired { scheduleSave() }
        }
        loadFlight = task
        do { try await task.value; loadFlight = nil }
        catch { loadFlight = nil; loading = false; throw error }
    }

    func reportProjectionError(_ message: String) { errorMessage = message }

    func update(_ value: String, isComposing: Bool) {
        guard loaded, !frozen, !retired else { return }
        let changed = value != text
        text = value; dirty = text != savedText
        if changed {
            onContentChanged?()
            do {
                // Undo can return to savedText while an older edit is still
                // being written. Keep that intent until the in-flight write
                // is acknowledged, even though it currently looks clean.
                if dirty || saveFlight != nil, let expectedMtime { try draftFile.write(.init(markdown: text, expectedMtime: expectedMtime)) }
                else { try draftFile.remove() }
            } catch { errorMessage = "임시 저장하지 못했어요. \(error.localizedDescription)" }
        }
        debounce?.cancel(); debounce = nil
        if dirty && !composing && !conflict { scheduleSave() }
    }

    private func scheduleSave() {
        guard !frozen, !retired, !writesSuspended else { return }
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            guard !composing, !frozen, !retired, !writesSuspended else { return }
            debounce = nil
            do { try await flush(commitComposition: false) } catch { /* Kept in the status and durable draft. */ }
        }
    }

    /// Every caller joins the same drain. A revision is advanced only after its
    /// matching write succeeds; edits arriving during an await become the next
    /// write, never a parallel write with a stale expectedMtime.
    func flush(commitComposition: Bool = true) async throws {
        guard !retired, !writesSuspended else { return }
        if commitComposition { prepareForFlush?() }
        debounce?.cancel(); debounce = nil
        if !loaded {
            if let loadFlight { _ = try? await loadFlight.value }
            // A failed read has no edits to save and must not trap navigation.
            guard loaded else { return }
        }
        if let saveFlight {
            try await saveFlight.value
            if dirty { try await flush(commitComposition: false) }
            return
        }
        guard dirty else { return }
        guard !conflict else { throw DesktopRuntimeError(errorMessage ?? "파일이 다른 곳에서 변경되었습니다.") }
        let task = Task { @MainActor [self] in
            saving = true
            defer { saving = false; saveFlight = nil }
            do { while dirty {
                let value = text
                guard let expectedMtime else { throw DesktopRuntimeError("노트의 저장 버전을 확인하지 못했습니다.") }
                var request = identity
                request["markdown"] = value; request["expectedMtime"] = expectedMtime
                let response: Any
                do { response = try await invoke("notes:write", request) }
                catch {
                    if (error as? DesktopRuntimeError)?.code == "CONFLICT" || error.localizedDescription.localizedCaseInsensitiveContains("changed on disk") || error.localizedDescription.localizedCaseInsensitiveContains("conflict") { conflict = true }
                    throw error
                }
                guard let result = response as? [String: Any], let next = (result["mtime"] as? NSNumber)?.doubleValue, next.isFinite else {
                    throw DesktopRuntimeError("저장 결과를 확인하지 못했습니다. 임시 저장한 내용은 보관되어 있어요.")
                }
                self.expectedMtime = next; savedText = value; dirty = text != value
                if dirty { try draftFile.write(.init(markdown: text, expectedMtime: next)) }
                else { try? draftFile.remove() }
            }
                errorMessage = nil; recoveredDraft = false
            } catch { errorMessage = error.localizedDescription; throw error }
        }
        saveFlight = task
        try await task.value
    }

    /// Material mutations first freeze UIKit synchronously, then the store
    /// awaits flush(). After rename/delete, this owner must never write its old
    /// relativePath again, including a delayed dismantle/background callback.
    func freezeForMaterialMutation() {
        guard !retired, !frozen else { return }
        prepareForFlush?()
        frozen = true
        debounce?.cancel(); debounce = nil
        setEditingEnabled?(false)
    }
    func suspendWritesForMaterialMutation() {
        writesSuspended = true
        debounce?.cancel(); debounce = nil
    }
    func cancelMaterialMutation() {
        guard !retired, frozen else { return }
        writesSuspended = false
        frozen = false
        setEditingEnabled?(true)
        if loaded && dirty && !conflict && !composing { scheduleSave() }
    }
    func retireAfterMaterialMutation() {
        guard !retired else { return }
        writesSuspended = true
        frozen = true; retired = true
        debounce?.cancel(); debounce = nil
        setEditingEnabled?(false)
        prepareForFlush = nil
    }

    /// Called only after an explicit discard confirmation. Read first so a read
    /// failure cannot destroy the last local copy.
    func reloadDiscardingDraft() async throws {
        guard !frozen, !retired else { throw DesktopRuntimeError("자료를 변경하는 중입니다. 잠시 후 다시 시도해 주세요.") }
        debounce?.cancel(); debounce = nil
        if let saveFlight { _ = try? await saveFlight.value }
        guard let result = try await invoke("notes:read", identity) as? [String: Any],
              let markdown = result["markdown"] as? String,
              let mtime = (result["mtime"] as? NSNumber)?.doubleValue, mtime.isFinite else { throw DesktopRuntimeError("노트를 다시 읽지 못했습니다.") }
        try draftFile.remove()
        resetsEditors = true; defer { resetsEditors = false }
        text = markdown; savedText = markdown; expectedMtime = mtime
        conflict = false; dirty = false; errorMessage = nil; recoveredDraft = false; loaded = true; loading = false
    }

    func keepCopy(value: String? = nil, using create: @MainActor () async throws -> NativeDocumentReference) async throws {
        guard !frozen, !retired else { throw DesktopRuntimeError("자료를 변경하는 중입니다. 잠시 후 다시 시도해 주세요.") }
        prepareForFlush?()
        let value = value ?? text
        let copy = try await create()
        let identity: [String: Any] = ["courseId": copy.courseID, "relPath": copy.relativePath]
        guard let current = try await invoke("notes:read", identity) as? [String: Any], let mtime = current["mtime"] as? NSNumber else { throw DesktopRuntimeError("사본의 저장 위치를 확인하지 못했습니다.") }
        var request = identity; request["markdown"] = value; request["expectedMtime"] = mtime
        _ = try await invoke("notes:write", request)
    }

    private var identity: [String: Any] { ["courseId": courseID, "relPath": relativePath] }
}
