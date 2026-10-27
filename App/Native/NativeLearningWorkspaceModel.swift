import Combine
import Foundation

@MainActor
final class NativeLearningWorkspaceModel: ObservableObject {
    let store: NativeWorkspaceStore
    private(set) var binding: NativeLearningBinding
    @Published var snapshot: [String: Any] = [:]
    @Published var article: [String: Any]?
    @Published var artifact: [String: Any]?
    @Published var loading = false
    @Published var busy = false
    @Published var frozen = false
    @Published var error: String?
    @Published var answers: [String: String] = [:]
    @Published var selfChecks: [String: Bool] = [:]
    @Published var completed = false
    @Published var saved = true
    private var quizSession: NativeLearningQuizSession?
    private var quizChanges: AnyCancellable?
    private var events: AnyCancellable?
    private var eventReload: Task<Void, Never>?
    private var eventReloadID: UUID?
    private var eventReloadPending = false
    private var acceptsEvents = false
    private var flushToken: UUID?
    private var readRevision = 0
    private var detailRevision = 0
    private var lifecycleRevision = 0
    private var retired = false
    private let detailID: String?
    init(store: NativeWorkspaceStore, binding: NativeLearningBinding, detailID: String? = nil) {
        self.store = store; self.binding = binding; self.detailID = detailID
        events = store.events.sink { [weak self] in self?.receive($0) }
    }
    func rebind(_ binding: NativeLearningBinding) async {
        guard self.binding != binding else { return }
        lifecycleRevision += 1; readRevision += 1; detailRevision += 1
        do { if !retired { try await flush() } }
        catch { self.error = error.localizedDescription; store.errorMessage = error.localizedDescription; return }
        if let flushToken { store.unregisterDocumentFlush(flushToken); self.flushToken = nil }
        quizChanges = nil; quizSession = nil; article = nil; artifact = nil; snapshot = [:]
        readRevision += 1; detailRevision += 1
        self.binding = binding; retired = false; frozen = false
    }
    var panelID: String { detailID ?? binding.id + ":learning" }
    func rows(_ key: String) -> [[String: Any]] { snapshot[key] as? [[String: Any]] ?? [] }
    var name: String { snapshot["name"] as? String ?? "학습 공간" }
    var attempt: [String: Any]? { quizSession?.attempt }
    var submitted: Bool { attempt?["submittedAt"] as? String != nil }
    func start() async {
        lifecycleRevision += 1; acceptsEvents = true
        if flushToken == nil {
            flushToken = store.registerDocumentFlush(id: detailID ?? binding.id + ":learning", document: .init(courseID: binding.courseID, relativePath: binding.rootRelPath, title: name, kind: "learning"), freeze: { [weak self] in self?.frozen = true }, resume: { [weak self] in self?.frozen = false }, retire: { [weak self] in self?.retired = true; self?.frozen = true; self?.quizSession?.retire() }, flush: { [self] in try await flush() })
        }
        await store.waitForExternalMutation()
        guard !retired, !Task.isCancelled else { return }
        await reload()
    }
    func reload() async {
        guard !retired, !Task.isCancelled else { return }; readRevision += 1; let revision = readRevision; loading = snapshot.isEmpty
        defer { if readRevision == revision { loading = false } }
        do {
            let value = try await store.invoke("learning:get", ["binding": binding.request]) as? [String: Any] ?? [:]
            guard revision == readRevision, !retired, !Task.isCancelled else { return }
            snapshot = value; error = nil
            await reloadDetail()
        } catch { if revision == readRevision { self.error = error.localizedDescription } }
    }
    func receive(_ event: NativeWorkspaceEvent) {
        guard event.channel == "learning:changed", acceptsEvents, !retired else { return }
        if let payload = event.payload as? [String: Any], let raw = payload["binding"] as? [String: Any], let course = raw["courseId"] as? String,
           course != binding.courseID || raw["rootRelPath"] as? String != binding.rootRelPath { return }
        eventReloadPending = true
        guard eventReload == nil else { return }
        let id = UUID(); eventReloadID = id
        eventReload = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if eventReloadID == id { eventReload = nil; eventReloadID = nil } }
            repeat {
                eventReloadPending = false
                guard acceptsEvents, !retired, !Task.isCancelled else { return }
                await reload()
            } while eventReloadPending
        }
    }
    private func reloadDetail() async {
        guard !Task.isCancelled else { return }
        let revision = detailRevision, read = readRevision
        do {
            if let id = article?["id"] as? String {
                let value = try await store.invoke("learning:getArticle", ["binding": binding.request, "id": id]) as? [String: Any]
                guard revision == detailRevision, read == readRevision, !retired, !Task.isCancelled else { return }; article = value.map(articleWithProgress)
            } else if let id = artifact?["id"] as? String {
                let value = try await store.invoke("learning:getArtifact", ["binding": binding.request, "id": id]) as? [String: Any]
                guard revision == detailRevision, read == readRevision, !retired, !Task.isCancelled else { return }; artifact = value
                if let value { quizSession?.update(artifact: value, snapshot: snapshot) }
            }
        } catch { if revision == detailRevision, !retired { self.error = error.localizedDescription } }
    }
    private func articleWithProgress(_ value: [String: Any]) -> [String: Any] {
        let reference = rows("articles").first { $0["id"] as? String == value["id"] as? String } ?? [:]
        return value.merging(reference) { _, current in current }
    }
    private func bindQuiz(_ artifact: [String: Any]) {
        quizChanges = nil
        quizSession = artifact["kind"] as? String == "quiz" ? store.learningSessions.quiz(binding: binding, artifact: artifact, snapshot: snapshot) : nil
        if let quizSession {
            quizChanges = quizSession.changes.sink { [weak self] in self?.applyQuiz() }
        }
        applyQuiz()
    }
    private func applyQuiz() {
        answers = quizSession?.answers ?? [:]; selfChecks = quizSession?.selfChecks ?? [:]
        completed = quizSession?.completed ?? false; saved = quizSession?.saved ?? true
        if let quizSession { busy = quizSession.busy; error = quizSession.error }
    }
    func openArticle(_ id: String) async {
        detailRevision += 1; let revision = detailRevision
        do {
            try await flush()
            let value = try await store.invoke("learning:getArticle", ["binding": binding.request, "id": id]) as? [String: Any]
            guard revision == detailRevision, !retired else { return }; quizChanges = nil; quizSession = nil; article = value.map(articleWithProgress); artifact = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func openArtifact(_ id: String) async {
        detailRevision += 1; let revision = detailRevision
        do {
            try await flush()
            let value = try await store.invoke("learning:getArtifact", ["binding": binding.request, "id": id]) as? [String: Any]
            guard revision == detailRevision, !retired else { return }
            artifact = value; article = nil
            if let value { bindQuiz(value) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func clearDetail() { Task { do { try await flush(); detailRevision += 1; quizChanges = nil; quizSession = nil; article = nil; artifact = nil } catch { self.error = error.localizedDescription } } }
    func answer(_ question: String, text: String, check: Bool? = nil) {
        guard !frozen, !retired else { return }
        quizSession?.answer(question, text: text, check: check)
    }
    func flush() async throws { try await quizSession?.flush() }
    func mutate(_ channel: String, _ input: [String: Any] = [:]) async -> Bool {
        guard !busy, !frozen, !retired else { return false }; busy = true
        defer { busy = false }
        do {
            try await flush()
            let result = try await store.invoke(channel, ["binding": binding.request].merging(input) { _, new in new })
            if let state = result as? [String: Any], state["binding"] != nil { readRevision += 1; snapshot = state; await reloadDetail() } else { await reload() }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func finishQuiz() async { guard !frozen, !retired else { return }; await quizSession?.finish() }
    func submitExam() async { guard !frozen, !retired else { return }; await quizSession?.submit() }
    func retryQuiz() { guard !frozen, !retired else { return }; quizSession?.retry() }
    func close() async {
        let lifecycle = lifecycleRevision
        acceptsEvents = false; eventReloadPending = false
        let pendingRead = eventReload
        eventReload = nil; eventReloadID = nil
        pendingRead?.cancel()
        // Cancellation does not interrupt an in-flight SQLite read. Await its
        // completion before the pane and its profile can be released.
        if let pendingRead { await pendingRead.value }
        do {
            if !retired { try await flush() }
            // A retained pane may become visible again while its old close is
            // awaiting a shared answer save. Its new registration must survive.
            if lifecycle == lifecycleRevision, let flushToken { store.unregisterDocumentFlush(flushToken); self.flushToken = nil }
        }
        catch { self.error = error.localizedDescription; store.errorMessage = error.localizedDescription }
    }
}
