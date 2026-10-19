import Combine
import Foundation

/// Each caller waits for its own fresh snapshot to be applied. A later refresh
/// cannot invalidate an earlier selection's awaited load or publish stale data.
@MainActor
final class NativeCourseRefreshQueue {
    private var tail: Task<Void, Error>?
    private var tailID: UUID?

    func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail, id = UUID()
        let task = Task { @MainActor in
            // A failed refresh is reported to its caller, but must not prevent
            // a later explicit retry from querying the repository again.
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        tail = task; tailID = id
        defer { if tailID == id { tail = nil; tailID = nil } }
        try await task.value
    }
}

/// Swift owns workspace navigation while the existing repositories continue to
/// own bandal.db, course folders, PDF bindings, receipts and recovery journals.
@MainActor
final class NativeWorkspaceStore: ObservableObject {
    private lazy var studyService = NativeStudyService(store: self)
    let runtime: DesktopRuntime
    var root: URL { runtime.root }
    @Published var courses: [NativeCourse] = []
    @Published var selectedCourseID: String?
    /// A newly created docked browser consumes its URL after its page exists.
    @Published var assistantDocumentIDs = Set<String>()
    @Published var documentSelections: [String: String] = [:]
    @Published var documentDuplicateSourceIDs: [String: String] = [:]
    @Published var pageNoteSourceTabIDs: [String: String] = [:]
    @Published var pendingBrowserURLs: [String:String] = [:]
    @Published var materials: [NativeMaterial] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isReady = false
    @Published private(set) var isApplyingExternalChanges = false
    @Published private(set) var documentReloadEpoch: UInt64 = 0
    private var universalReloadEpoch: UInt64 = 0
    private var courseReloadEpochs: [String:UInt64] = [:]
    /// Keyed by the editor registration id (one per tab), so a page edit
    /// rebuilds only the tabs whose file changed.
    private var documentReloadEpochs: [String: UInt64] = [:]
    let events = PassthroughSubject<NativeWorkspaceEvent, Never>()

    /// Installed by the native scene's presenter for sharing, exporting and
    /// other UIKit presentation services. Repository calls remain independent.
    var nativeChannelHandler: (@MainActor (String, [String: Any]) async throws -> Any)?

    private let sessionID = UUID().uuidString
    private var startup: Task<Void, Error>?
    private var startupError: Error?
    private var loadingCount = 0 {
        didSet { isLoading = loadingCount > 0 }
    }
    private var materialRequest = UUID()
    private let courseRefresh = NativeCourseRefreshQueue()
    private var watchedCourseID: String?
    private var eventRefresh: Task<Void, Never>?
    private var refreshCoursesPending = false
    private var flushers: [UUID: DocumentFlush] = [:]
    private var activeFlush: Task<Void, Error>?
    private var documentRevision: UInt64 = 0
    private var externalParticipants: [UUID: DocumentFlush] = [:]
    private var externalMutationActive = false
    private var externalWritesSuspended = false
    private var externalMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var materialMutationBusy = false
    private var materialMutationOwner: UUID?
    private var materialMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private enum MutationTask {
        @TaskLocal static var owner: UUID?
    }
    private struct DocumentFlush {
        let id: String
        let document: NativeDocumentReference?
        let freeze: (@MainActor () -> Void)?
        let suspendWrites: (@MainActor () -> Void)?
        let resume: (@MainActor () -> Void)?
        let retire: (@MainActor () -> Void)?
        let flush: @MainActor () async throws -> Void
        var storageID: String { document?.storageID ?? id }
        var mutation: [String: Any]? {
            if let document { return ["courseId": document.courseID, "relPath": document.relativePath, "isDirectory": document.kind == "learning"] }
            // Legacy callers have course:path IDs. An instance UUID is never a
            // storage path; new instance-aware editors pass an explicit document.
            guard !id.hasPrefix("instance:") else { return nil }
            guard let separator = id.firstIndex(of: ":") else { return nil }
            return ["courseId": String(id[..<separator]), "relPath": String(id[id.index(after: separator)...]), "isDirectory": false]
        }
    }
    private struct Selection: Codable { let courseID: String? }

    init(storageRoot: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let arguments = ProcessInfo.processInfo.arguments
        let testing = arguments.contains("--native-ui-testing") || NSClassFromString("XCTestCase") != nil
        var initializationFailure: Error?
        var selectedRoot: URL?
        // A new profile selects new storage; the previous root is never erased.
        if storageRoot == nil, !testing {
            do { selectedRoot = try DesktopProfileService.selectedRoot(in: documents) } catch { initializationFailure = error }
        }
        let folder = storageRoot ?? selectedRoot ?? documents.appendingPathComponent(testing ? "BandalDesktop-Native-UI-Tests" : "BandalDesktop", isDirectory: true)
        // An explicit test directory is never reset implicitly, so restart tests
        // and existing course data use exactly the same startup path.
        if storageRoot == nil, testing, arguments.contains("--reset-native-ui-testing") {
            do { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
            catch { initializationFailure = error }
            #if DEBUG
            // Each explicitly reset UI fixture starts with visible desktop rails.
            // Normal launches and restart tests preserve the user's preference.
            for key in ["native.desktop.courseRail", "native.desktop.materialsRail"] { UserDefaults.standard.removeObject(forKey: key) }
            #endif
        }
        let legacy = storageRoot != nil ? folder.appendingPathComponent("Legacy", isDirectory: true)
            : testing ? documents.appendingPathComponent("Bandal-Native-UI-Tests", isDirectory: true)
            : DesktopProfileService.legacyRoot(documents: documents, root: folder)
        NativePDFPreferenceScope.registerPreviousRoot(root: folder, documentsRoot: documents)
        runtime = DesktopRuntime(root: folder, legacyRoot: legacy)
        startupError = initializationFailure
        errorMessage = initializationFailure?.localizedDescription
        if storageRoot == nil, !testing,
           let configurationURL = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
           let data = try? Data(contentsOf: configurationURL),
           let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
            UserDefaults.standard.register(defaults: configuration)
        }
        runtime.onEmit = { [weak self] channel, payload in
            Task { @MainActor [weak self] in self?.receive(channel, payload: payload) }
        }
        runtime.onNativeCall = { [weak self] channel, request in
            guard let self else { throw CancellationError() }
            return try await self.performNativeChannel(channel, request)
        }
    }

    func start() async {
        do { try await ensureStarted() }
        catch { errorMessage = error.localizedDescription }
    }

    private func ensureStarted() async throws {
        if let startupError { throw startupError }
        if let startup { return try await startup.value }
        let task = Task { @MainActor in
            self.loadingCount += 1
            defer { self.loadingCount -= 1 }
            do {
                try await DesktopSignpost.measure(DesktopSignpost.launch, "runtime") { try await self.runtime.start() }
                _ = try await self.runtime.invokePrivate("nativeRuntime:workspaceReady", request: ["workspaceSessionId": self.sessionID])
                if let data = try? Data(contentsOf: self.selectionURL), let saved = try? JSONDecoder().decode(Selection.self, from: data) {
                    self.selectedCourseID = saved.courseID
                }
                try await DesktopSignpost.measure(DesktopSignpost.launch, "courses") { try await self.loadCourses() }
                try await DesktopSignpost.measure(DesktopSignpost.launch, "materials") { try await self.loadMaterials() }
                self.isReady = true
                self.errorMessage = nil
                // Folder-walking recovery runs after the first screen is interactive.
                Task { _ = try? await self.runtime.invokePrivate("nativeRuntime:recoverDeferred", request: [:]) }
            } catch {
                self.startupError = error
                throw error
            }
        }
        startup = task
        try await task.value
    }

    func invoke(_ channel: String, _ request: [String: Any] = [:]) async throws -> Any {
        try await ensureStarted()
        if ["study:listTools", "study:generate", "learning:addArticle", "learning:runCancel"].contains(channel) { return try await studyService.handle(channel, request) }
        if Self.presentationChannels.contains(channel) {
            return try await performNativeChannel(channel, request)
        }
        return try await runtime.invoke(channel, request: request)
    }

    func invokePrivate(_ channel: String, _ request: [String: Any] = [:]) async throws -> Any {
        try await ensureStarted()
        return try await runtime.invokePrivate(channel, request: request)
    }

    func openPDFPageNote(courseID: String, relativePath: String) async throws -> NativeDocumentReference {
        try await withMaterialMutationLease {
            try await flushDocuments()
            return try Self.decode(try await invoke("pdf:openPageNote", ["courseId": courseID, "relPath": relativePath]))
        }
    }

    func selectCourse(_ id: String) async {
        do {
            try await ensureStarted()
            if !courses.contains(where: { $0.id == id }) { try await loadCourses() }
            guard courses.contains(where: { $0.id == id }) else { throw DesktopRuntimeError("선택한 과목을 찾을 수 없습니다.") }
            if selectedCourseID != id { try await flushDocuments() }
            selectedCourseID = id
            materials = []
            try saveSelection()
            try await loadMaterials()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshMaterials() async {
        do { try await ensureStarted(); try await loadMaterials() }
        catch { errorMessage = error.localizedDescription }
    }

    func createCourse(name: String) async throws {
        let name = try nonEmpty(name, label: "과목 이름")
        try await flushDocuments()
        let created: NativeCourse = try Self.decode(try await invoke("courses:create", ["name": name, "color": "blue"]))
        try await loadCourses()
        selectedCourseID = created.id
        try saveSelection()
        try await loadMaterials()
    }

    func importFiles(_ urls: [URL], parentPath: String = "") async throws {
        let courseID = try await currentCourse()
        guard !urls.isEmpty else { return }
        // Copy file-provider URLs on a worker while security scope and the
        // coordination lease are held. Only our own staging folder is removed.
        let stagingRoot = root.appendingPathComponent("Temporary/NativeImports", isDirectory: true)
        let task = Task.detached(priority: .userInitiated) { try Self.stage(urls, under: stagingRoot) }
        let staged = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        try Task.checkCancellation()
        let result = try await invoke("materials:import", ["courseId": courseID, "dirRelPath": parentPath, "paths": staged.files.map(\.path)])
        guard let response = result as? [String: Any], let imported = response["imported"] as? [String],
              let failures = response["failed"] as? [[String: Any]], imported.count + failures.count == urls.count else {
            throw DesktopRuntimeError("파일 가져오기 결과를 확인하지 못했습니다. 자료 목록을 새로고침해 주세요.")
        }
        try await loadMaterials()
        if !failures.isEmpty {
            let reasons = failures.map { entry in
                let name = (entry["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "파일"
                return "\(name): \(entry["reason"] as? String ?? "가져오지 못했습니다.")"
            }.joined(separator: "\n")
            throw DesktopRuntimeError(reasons)
        }
    }

    func createNote(title: String, paper: String, orientation: String, parentPath: String = "") async throws -> NativeDocumentReference {
        let courseID = try await currentCourse()
        let value = try await invoke("pdfNotes:create", ["courseId": courseID, "title": try nonEmpty(title, label: "노트 제목"), "paper": paper, "orientation": orientation,"dirRelPath":parentPath])
        let reference = try document(value, courseID: courseID, kind: "pdf")
        try await loadMaterials()
        return reference
    }

    func createMarkdown(title: String, courseID requestedCourseID: String? = nil, parentPath: String = "") async throws -> NativeDocumentReference {
        try await ensureStarted()
        let courseID: String
        if let requestedCourseID {
            guard courses.contains(where: { $0.id == requestedCourseID }) else { throw DesktopRuntimeError("노트를 저장할 과목을 찾을 수 없습니다.") }
            courseID = requestedCourseID
        } else { courseID = try await currentCourse() }
        let value = try await invoke("notes:create", ["courseId": courseID, "dirRelPath": parentPath, "title": try nonEmpty(title, label: "노트 제목")])
        let reference = try document(value, courseID: courseID, kind: "note")
        try await loadMaterials()
        return reference
    }

    func rename(_ material: NativeMaterial, to name: String) async throws {
        let courseID = try await currentCourse()
        var name = try nonEmpty(name, label: "이름")
        let oldExtension = (material.name as NSString).pathExtension
        if !material.isDirectory, !oldExtension.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + oldExtension }
        let channel = material.kind == "note" ? "notes:rename" : "materials:rename"
        // PDF paths also live in linked Markdown, including notes in other
        // courses. Freeze and retire those owners before their source changes.
        if material.isDirectory || material.kind == "pdf" || oldExtension.lowercased() == "pdf" {
            _ = try await withExternalMutation {
                let value = try await self.invoke(channel, ["courseId": courseID, "relPath": material.relPath, "newName": name])
                let renamed = try self.document(value, courseID: courseID, kind: material.kind)
                self.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialRenamed", payload: ["courseId": courseID, "fromRelPath": material.relPath, "toRelPath": renamed.relativePath, "isDirectory": material.isDirectory]))
                // Navigation consumes the rename before the barrier rebuilds
                // editors. An unchanged path does not invalidate their state.
                // Only the renamed file (and notes whose links were rewritten) change; other tabs stay.
                let rewritten = (value as? [String: Any])?["changedDocuments"] as? [[String: Any]] ?? []
                let result: [String: Any] = renamed.relativePath == material.relPath ? ["changedCourseIDs": [String](), "changedDocuments": [[String: Any]]()]
                    : ["changedCourseIDs": [courseID], "changedDocuments": [["courseId": courseID, "relPath": material.relPath, "isDirectory": material.isDirectory]] + rewritten]
                return result
            }
            return
        }
        try await withMaterialMutationLease {
            let mutation: [String: Any] = ["courseId": courseID, "relPath": material.relPath, "isDirectory": material.isDirectory]
            events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialWillMutate", payload: mutation))
            let value: Any
            do {
                try await flushDocuments()
                value = try await invoke(channel, ["courseId": courseID, "relPath": material.relPath, "newName": name])
            } catch {
                events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialMutationCancelled", payload: mutation))
                throw error
            }
            let renamed = try document(value, courseID: courseID, kind: material.kind)
            events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialRenamed", payload: ["courseId": courseID, "fromRelPath": material.relPath, "toRelPath": renamed.relativePath, "isDirectory": material.isDirectory]))
            try await loadMaterials()
        }
    }

    func move(_ material: NativeMaterial, to parentPath: String) async throws {
        let courseID = try await currentCourse()
        if material.isDirectory || material.kind == "pdf" || (material.name as NSString).pathExtension.lowercased() == "pdf" {
            _ = try await withExternalMutation {
                guard let result = try await self.invoke("materials:move", ["courseId": courseID, "fromRelPath": material.relPath, "toDirRelPath": parentPath]) as? [String: Any],
                      let path = result["relPath"] as? String else { throw DesktopRuntimeError("자료 이동 결과를 확인하지 못했습니다.") }
                self.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialRenamed", payload: ["courseId": courseID, "fromRelPath": material.relPath, "toRelPath": path, "isDirectory": material.isDirectory]))
                let rewritten = result["changedDocuments"] as? [[String: Any]] ?? []
                let changes: [String: Any] = path == material.relPath ? ["changedCourseIDs": [String](), "changedDocuments": [[String: Any]]()]
                    : ["changedCourseIDs": [courseID], "changedDocuments": [["courseId": courseID, "relPath": material.relPath, "isDirectory": material.isDirectory]] + rewritten]
                return changes
            }
            return
        }
        try await withMaterialMutationLease {
            let mutation: [String:Any] = ["courseId":courseID,"relPath":material.relPath,"isDirectory":material.isDirectory]
            events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:materialWillMutate",payload:mutation))
            do {
                try await flushDocuments()
                guard let result = try await invoke("materials:move",["courseId":courseID,"fromRelPath":material.relPath,"toDirRelPath":parentPath]) as? [String:Any], let path = result["relPath"] as? String else { throw DesktopRuntimeError("자료 이동 결과를 확인하지 못했습니다.") }
                events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:materialRenamed",payload:["courseId":courseID,"fromRelPath":material.relPath,"toRelPath":path,"isDirectory":material.isDirectory]))
                try await loadMaterials()
            } catch {
                events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:materialMutationCancelled",payload:mutation)); throw error
            }
        }
    }

    func delete(_ material: NativeMaterial) async throws {
        let courseID = try await currentCourse()
        try await withMaterialMutationLease {
            let mutation: [String: Any] = ["courseId": courseID, "relPath": material.relPath, "isDirectory": material.isDirectory]
            events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialWillMutate", payload: mutation))
            do {
                try await flushDocuments()
                _ = try await invoke("materials:delete", ["courseId": courseID, "relPath": material.relPath])
            } catch {
                events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialMutationCancelled", payload: mutation))
                throw error
            }
            events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialDeleted", payload: ["courseId": courseID, "relPath": material.relPath, "isDirectory": material.isDirectory]))
            try await loadMaterials()
        }
    }

    func createFolder(name: String, parentPath: String) async throws {
        let courseID = try await currentCourse()
        _ = try await invoke("materials:createFolder", ["courseId": courseID, "dirRelPath": parentPath, "name": try nonEmpty(name, label: "폴더 이름")])
        try await loadMaterials()
    }

    func registerDocumentFlush(id: String, document: NativeDocumentReference? = nil, freeze: (@MainActor () -> Void)? = nil,
                               suspendWrites: (@MainActor () -> Void)? = nil,
                               resume: (@MainActor () -> Void)? = nil, retire: (@MainActor () -> Void)? = nil,
                               flush: @escaping @MainActor () async throws -> Void) -> UUID {
        let token = UUID()
        let entry = DocumentFlush(id: id, document: document, freeze: freeze, suspendWrites: suspendWrites, resume: resume, retire: retire, flush: flush)
        flushers[token] = entry
        if externalMutationActive { joinExternalMutation(token, entry: entry) }
        markDocumentChanged()
        return token
    }

    func unregisterDocumentFlush(_ token: UUID) { flushers.removeValue(forKey: token) }

    /// Newly mounted editors must not read or recover a journal halfway through
    /// an import. Register first, then await this gate before opening the file.
    func waitForExternalMutation() async {
        // During the preparing phase, open/recovery must still run so the
        // initial flush can await it. Only the actual replacement is gated.
        while externalWritesSuspended {
            await withCheckedContinuation { externalMutationWaiters.append($0) }
        }
    }

    func reloadIdentity(for document: NativeDocumentReference) -> String {
        // Browser/assistant/recordings/planner tabs hold no file; nothing on disk can invalidate them.
        guard !document.isWorkspaceTool else { return document.id }
        return document.id + ":" + document.storageID + ":\(universalReloadEpoch):\(courseReloadEpochs[document.courseID] ?? 0):\(documentReloadEpochs[document.id] ?? 0)"
    }
    /// Which registered editors a finished mutation invalidates. `changedDocuments`
    /// (course + path, directories by prefix) is the narrow scope; `changedCourseIDs`
    /// the old course scope; neither means everything.
    static func affects(changedDocuments: [[String: Any]]?, changedCourseIDs: Set<String>?, _ mutation: [String: Any]?) -> Bool {
        guard let mutation, let course = mutation["courseId"] as? String else { return changedDocuments == nil && changedCourseIDs == nil }
        if let changedDocuments {
            let path = mutation["relPath"] as? String ?? "", directory = mutation["isDirectory"] as? Bool == true
            return changedDocuments.contains { changed in
                guard changed["courseId"] as? String == course, let changedPath = changed["relPath"] as? String else { return false }
                return changedPath == path || (changed["isDirectory"] as? Bool == true && path.hasPrefix(changedPath + "/"))
                    || (directory && changedPath.hasPrefix(path + "/"))
            }
        }
        if let changedCourseIDs { return changedCourseIDs.contains(course) }
        return true
    }

    private func joinExternalMutation(_ token: UUID, entry: DocumentFlush) {
        externalParticipants[token] = entry
        entry.freeze?()
        if externalWritesSuspended { entry.suspendWrites?() }
        if let mutation = entry.mutation {
            events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:materialWillMutate", payload: mutation))
        }
    }

    /// Serialize path mutations and external replacement across every await.
    /// A caller cancelled in the queue hands its turn to the next caller.
    private func withMaterialMutationLease<T>(_ action: @MainActor () async throws -> T) async throws -> T {
        if let materialMutationOwner, MutationTask.owner == materialMutationOwner {
            throw DesktopRuntimeError("다른 자료 변경 작업 안에서 새 변경을 시작할 수 없습니다.")
        }
        try Task.checkCancellation()
        if materialMutationBusy {
            await withCheckedContinuation { materialMutationWaiters.append($0) }
        } else { materialMutationBusy = true }
        let owner = UUID()
        materialMutationOwner = owner
        defer {
            materialMutationOwner = nil
            if materialMutationWaiters.isEmpty { materialMutationBusy = false }
            else { materialMutationWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await MutationTask.$owner.withValue(owner) { try await action() }
    }

    /// A sync import or folder reattachment must hold input stopped from the
    /// last local flush until old editor instances have been retired.
    /// `reopening` is the registration of the editor that started the mutation
    /// (a page edit of its own file); it is resumed, not retired, and reopens itself.
    func withExternalMutation(_ action: @escaping @MainActor () async throws -> Any, reopening: UUID? = nil) async throws -> Any {
        try await ensureStarted()
        return try await withMaterialMutationLease { try await performExternalMutation(action, reopening: reopening) }
    }

    private func performExternalMutation(_ action: @MainActor () async throws -> Any, reopening: UUID? = nil) async throws -> Any {
        externalMutationActive = true
        isApplyingExternalChanges = true
        var succeeded = false
        var changedCourseIDs: Set<String>?
        var changedDocuments: [[String: Any]]?
        defer {
            // Retain even unregistered participants until completion: a view
            // disappearing during an await still owns its old file identity.
            var finalized = Set<UUID>(), notified = Set<String>()
            var didApply = succeeded && changedCourseIDs == nil && changedDocuments == nil
            while let (token, entry) = externalParticipants.first(where: { !finalized.contains($0.key) }) {
                finalized.insert(token)
                let affected = succeeded && Self.affects(changedDocuments: changedDocuments, changedCourseIDs: changedCourseIDs, entry.mutation)
                if affected {
                    didApply = true
                    if token == reopening { entry.resume?() }
                    else {
                        entry.retire?()
                        if changedDocuments != nil { documentReloadEpochs[entry.id, default: 0] &+= 1 }
                    }
                } else { entry.resume?() }
                if notified.insert(entry.storageID).inserted, let mutation = entry.mutation {
                    events.send(NativeWorkspaceEvent(channel: affected ? "nativeWorkspace:materialReplaced" : "nativeWorkspace:materialMutationCancelled", payload: mutation))
                }
            }
            externalParticipants.removeAll()
            externalWritesSuspended = false
            externalMutationActive = false
            isApplyingExternalChanges = false
            if didApply {
                if changedDocuments != nil {
                    // Per-tab epochs were bumped above; the course keeps its identity.
                } else if let changedCourseIDs {
                    for courseID in changedCourseIDs { courseReloadEpochs[courseID,default:0] &+= 1 }
                } else { universalReloadEpoch &+= 1 }
                documentReloadEpoch &+= 1
                events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:externalMutationFinished",payload:[:]))
            }
            let waiters = externalMutationWaiters
            externalMutationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        for (token, entry) in flushers { joinExternalMutation(token, entry: entry) }
        try await flushDocuments()
        externalWritesSuspended = true
        for entry in externalParticipants.values { entry.suspendWrites?() }
        let result: Any
        do { result = try await action() }
        catch let failure as NativeSyncImportFailure {
            // A batch may commit earlier records before a later record needs
            // recovery. Those editors must never resume against stale bytes.
            changedCourseIDs = failure.changedCourseIDs
            succeeded = !failure.changedCourseIDs.isEmpty
            if succeeded { try? await loadCourses(); try? await loadMaterials() }
            throw failure
        }
        succeeded = true
        let payload = result as? [String: Any]
        changedCourseIDs = (payload?["changedCourseIDs"] as? [String]).map(Set.init)
        changedDocuments = payload?["changedDocuments"] as? [[String: Any]]
        // An explicitly empty course scope changed nothing the lists show.
        if changedCourseIDs?.isEmpty != true { try await loadCourses(); try await loadMaterials() }
        return result
    }

    /// Editors call this whenever new local content needs to become durable.
    /// A transition already awaiting another editor must include that content.
    func markDocumentChanged() { documentRevision &+= 1 }

    func flushDocuments() async throws {
        markDocumentChanged()
        if let activeFlush { return try await activeFlush.value }
        let task = Task { @MainActor in
            defer { self.activeFlush = nil }
            var firstError: Error?
            while true {
                let revision = self.documentRevision
                let entries = self.flushers.sorted { $0.value.id < $1.value.id }
                for entry in entries where self.flushers[entry.key] != nil {
                    do { try await entry.value.flush() }
                    catch { if firstError == nil { firstError = error } }
                }
                if revision == self.documentRevision { break }
            }
            if let firstError { throw firstError }
        }
        activeFlush = task
        try await task.value
    }

    private func currentCourse() async throws -> String {
        try await ensureStarted()
        guard let selectedCourseID, courses.contains(where: { $0.id == selectedCourseID }) else { throw DesktopRuntimeError("먼저 과목을 선택해 주세요.") }
        return selectedCourseID
    }

    private func performNativeChannel(_ channel: String, _ request: [String: Any]) async throws -> Any {
        guard let nativeChannelHandler else { throw DesktopRuntimeError("파일 창을 아직 열 수 없습니다. 잠시 후 다시 시도해 주세요.") }
        return try await nativeChannelHandler(channel, request)
    }

    private func loadCourses() async throws {
        // Selection must await a published snapshot, including when the
        // creation event starts another refresh during its explicit reload.
        try await courseRefresh.run { [self] in
            let loaded: [NativeCourse] = try Self.decode(try await runtime.invoke("courses:list"))
            courses = loaded
            if !loaded.contains(where: { $0.id == selectedCourseID }) {
                selectedCourseID = loaded.first?.id
                materials = []
                try saveSelection()
            }
        }
    }

    private func loadMaterials() async throws {
        let token = UUID(); materialRequest = token
        loadingCount += 1
        defer { loadingCount -= 1 }
        let courseID = selectedCourseID
        if let old = watchedCourseID, old != courseID {
            _ = try await runtime.invoke("materials:unwatch", request: ["courseId": old, "workspaceSessionId": sessionID, "subscriptionId": "native-library"])
            watchedCourseID = nil
        }
        guard let courseID else { materials = []; return }
        let loaded: [NativeMaterial] = try Self.decode(try await runtime.invoke("materials:tree", request: ["courseId": courseID]))
        guard materialRequest == token, selectedCourseID == courseID else { return }
        materials = loaded
        if watchedCourseID != courseID {
            _ = try await runtime.invoke("materials:watch", request: ["courseId": courseID, "workspaceSessionId": sessionID, "subscriptionId": "native-library"])
            // A course switch can happen while the initial watch scan awaits.
            if selectedCourseID == courseID { watchedCourseID = courseID }
            else { _ = try await runtime.invoke("materials:unwatch", request: ["courseId": courseID, "workspaceSessionId": sessionID, "subscriptionId": "native-library"]) }
        }
    }

    private func receive(_ channel: String, payload: Any) {
        events.send(NativeWorkspaceEvent(channel: channel, payload: payload))
        let courseID = (payload as? [String: Any])?["courseId"] as? String
        guard channel == "courses:changed" || channel == "materials:changed" && courseID == selectedCourseID else { return }
        if channel == "courses:changed" { refreshCoursesPending = true }
        guard isReady, eventRefresh == nil else { return }
        eventRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            self.eventRefresh = nil
            do {
                if self.refreshCoursesPending { self.refreshCoursesPending = false; try await self.loadCourses() }
                try await self.loadMaterials()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    private var selectionURL: URL { root.appendingPathComponent("native-workspace-selection.json") }
    private func saveSelection() throws { try JSONEncoder().encode(Selection(courseID: selectedCourseID)).write(to: selectionURL, options: .atomic) }
    private func nonEmpty(_ text: String, label: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DesktopRuntimeError("\(label)을 입력해 주세요.") }
        return value
    }
    private func document(_ value: Any, courseID: String, kind: String) throws -> NativeDocumentReference {
        guard let result = value as? [String: Any], let path = result["relPath"] as? String, !path.isEmpty else { throw DesktopRuntimeError("저장된 자료 경로를 확인하지 못했습니다.") }
        return NativeDocumentReference(courseID: courseID, relativePath: path, title: (path as NSString).lastPathComponent, kind: kind)
    }
    private static func decode<T: Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
    private static let presentationChannels: Set<String> = ["materials:share", "materials:export", "materials:preview", "materials:reveal", "native:saveFile", "native:revealFile", "print:pdf", "print:savePdfAs"]

    private struct StagedFiles: Sendable { let directory: URL; let files: [URL] }
    nonisolated private static func stage(_ sources: [URL], under root: URL) throws -> StagedFiles {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var files: [URL] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                guard source.isFileURL else { throw DesktopRuntimeError("가져올 파일을 확인해 주세요.") }
                let scope = source.startAccessingSecurityScopedResource()
                defer { if scope { source.stopAccessingSecurityScopedResource() } }
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(source.lastPathComponent)
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { available in
                    do {
                        let values = try available.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DesktopRuntimeError("일반 파일만 가져올 수 있습니다.") }
                        try FileManager.default.copyItem(at: available, to: target)
                    } catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                files.append(target)
            }
            try Task.checkCancellation()
            return StagedFiles(directory: directory, files: files)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
