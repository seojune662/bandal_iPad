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
    private var attemptID = UUID().uuidString.lowercased()
    private var dirty: Set<String> = []
    private var flushToken: UUID?
    private var flushTask: Task<Void, Error>?
    private var debounce: Task<Void, Never>?
    private var readRevision = 0
    private var detailRevision = 0
    private var retired = false
    private let detailID: String?
    init(store: NativeWorkspaceStore, binding: NativeLearningBinding, detailID: String? = nil) { self.store = store; self.binding = binding; self.detailID = detailID }
    func rebind(_ binding: NativeLearningBinding) async {
        guard self.binding != binding else { return }
        debounce?.cancel()
        do { if !retired { try await flush() } }
        catch { self.error = error.localizedDescription; store.errorMessage = error.localizedDescription; return }
        if let flushToken { store.unregisterDocumentFlush(flushToken); self.flushToken = nil }
        self.binding = binding; retired = false; frozen = false
    }
    func rows(_ key: String) -> [[String: Any]] { snapshot[key] as? [[String: Any]] ?? [] }
    var name: String { snapshot["name"] as? String ?? "학습 공간" }
    var attempt: [String: Any]? { rows("quizAttempts").first { $0["id"] as? String == attemptID } }
    var submitted: Bool { attempt?["submittedAt"] as? String != nil }
    func start() async {
        if flushToken == nil {
            flushToken = store.registerDocumentFlush(id: detailID ?? binding.id + ":learning", document: .init(courseID: binding.courseID, relativePath: binding.rootRelPath, title: name, kind: "learning"), freeze: { [weak self] in self?.frozen = true }, resume: { [weak self] in self?.frozen = false }, retire: { [weak self] in self?.retired = true; self?.frozen = true }, flush: { [self] in try await flush() })
        }
        await store.waitForExternalMutation()
        guard !retired, !Task.isCancelled else { return }
        await reload()
    }
    func reload() async {
        guard !retired else { return }; readRevision += 1; let revision = readRevision; loading = snapshot.isEmpty
        defer { if readRevision == revision { loading = false } }
        do {
            let value = try await store.invoke("learning:get", ["binding": binding.request]) as? [String: Any] ?? [:]
            guard revision == readRevision, !retired else { return }
            snapshot = value; error = nil
        } catch { if revision == readRevision { self.error = error.localizedDescription } }
    }
    func receive(_ event: NativeWorkspaceEvent) {
        guard event.channel == "learning:changed" else { return }
        if let payload = event.payload as? [String: Any], let raw = payload["binding"] as? [String: Any], let course = raw["courseId"] as? String,
           course != binding.courseID || raw["rootRelPath"] as? String != binding.rootRelPath { return }
        Task { await reload() }
    }
    func openArticle(_ id: String) async {
        detailRevision += 1; let revision = detailRevision
        do {
            try await flush()
            let value = try await store.invoke("learning:getArticle", ["binding": binding.request, "id": id]) as? [String: Any]
            guard revision == detailRevision, !retired else { return }; article = value; artifact = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func openArtifact(_ id: String) async {
        detailRevision += 1; let revision = detailRevision
        do {
            try await flush()
            let value = try await store.invoke("learning:getArtifact", ["binding": binding.request, "id": id]) as? [String: Any]
            guard revision == detailRevision, !retired else { return }
            artifact = value; article = nil; answers = [:]; selfChecks = [:]; dirty = []; saved = true
            let prior = rows("quizAttempts").filter { $0["artifactId"] as? String == id }.sorted { ($0["startedAt"] as? String ?? "") > ($1["startedAt"] as? String ?? "") }.first
            attemptID = prior?["id"] as? String ?? UUID().uuidString.lowercased(); completed = prior?["completedAt"] as? String != nil
            for row in prior?["answers"] as? [[String: Any]] ?? [] { if let question = row["questionId"] as? String { answers[question] = row["answer"] as? String ?? ""; selfChecks[question] = row["selfCheck"] as? Bool } }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func clearDetail() { Task { do { try await flush(); detailRevision += 1; article = nil; artifact = nil } catch { self.error = error.localizedDescription } } }
    func answer(_ question: String, text: String, check: Bool? = nil) {
        guard !completed, !frozen, !retired else { return }
        if artifact?["generationMode"] as? String == "expected-exam" {
            if submitted && (check == nil || answers[question] != text) { return }
            if !submitted && check != nil { return }
        }
        if answers[question] != text && check == nil { selfChecks[question] = nil }; answers[question] = text; if let check { selfChecks[question] = check }; dirty.insert(question); saved = false; store.markDocumentChanged()
        debounce?.cancel(); debounce = Task { [weak self] in try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled else { return }; do { try await self?.flush() } catch { self?.error = error.localizedDescription } }
    }
    func flush() async throws {
        if let current = flushTask { try await current.value; if !dirty.isEmpty { try await flush() }; return }
        guard !dirty.isEmpty else { return }
        guard !retired, let artifactID = artifact?["id"] as? String else { throw DesktopRuntimeError("답안을 저장할 학습 자료를 확인해 주세요.") }
        let task = Task { @MainActor [self] in
            defer { flushTask = nil }
            while let question = dirty.sorted().first {
                let text = answers[question] ?? "", check = selfChecks[question]
                var request: [String: Any] = ["binding": binding.request, "artifactId": artifactID, "attemptId": attemptID, "questionId": question, "answer": text]
                if let check { request["selfCheck"] = check }
                let value = try await store.invoke("learning:saveQuizAnswer", request) as? [String: Any] ?? [:]
                if answers[question] == text && selfChecks[question] == check { dirty.remove(question) }
                readRevision += 1; snapshot = value
            }
            saved = true
        }
        flushTask = task
        try await task.value
    }
    func mutate(_ channel: String, _ input: [String: Any] = [:]) async -> Bool {
        guard !busy, !frozen, !retired else { return false }; busy = true
        defer { busy = false }
        do {
            try await flush()
            let result = try await store.invoke(channel, ["binding": binding.request].merging(input) { _, new in new })
            if let state = result as? [String: Any], state["binding"] != nil { readRevision += 1; snapshot = state } else { await reload() }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func finishQuiz() async {
        guard let id = artifact?["id"] as? String else { return }
        if await mutate("learning:finishQuiz", ["artifactId": id, "attemptId": attemptID]) { completed = true }
    }
    func submitExam() async {
        guard let id = artifact?["id"] as? String,
              await mutate("learning:submitQuiz", ["artifactId": id, "attemptId": attemptID]) else { return }
        let questions = artifact?["questions"] as? [[String: Any]] ?? []
        if !questions.contains(where: { $0["type"] as? String == "short-answer" }) { await finishQuiz() }
    }
    func retryQuiz() { completed = false; attemptID = UUID().uuidString.lowercased(); answers = [:]; selfChecks = [:]; dirty = []; saved = true }
    func close() async {
        debounce?.cancel()
        do { if !retired { try await flush() }; if let flushToken { store.unregisterDocumentFlush(flushToken); self.flushToken = nil } }
        catch { self.error = error.localizedDescription; store.errorMessage = error.localizedDescription }
    }
}
