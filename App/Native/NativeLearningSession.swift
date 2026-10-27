import Combine
import Foundation

/// All instances of one quiz share an attempt and one answer writer. Scrolling,
/// focus, article selection and card disclosure remain in the presenting pane.
@MainActor
final class NativeLearningQuizSession {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    let changes = PassthroughSubject<Void, Never>()
    private(set) var answers: [String: String] = [:]
    private(set) var selfChecks: [String: Bool] = [:]
    private(set) var completed = false
    private(set) var saved = true
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retired = false
    private(set) var snapshot: [String: Any]
    private(set) var attemptID: String
    private var artifact: [String: Any]
    private let binding: NativeLearningBinding
    private weak var store: NativeWorkspaceStore?
    private let invoke: Invoke
    private var dirty = Set<String>()
    private var flushTask: Task<Void, Error>?
    private var debounce: Task<Void, Never>?
    private var freshAttempt = false

    init(store: NativeWorkspaceStore, binding: NativeLearningBinding, artifact: [String: Any], snapshot: [String: Any], invoke: Invoke? = nil) {
        self.store = store; self.binding = binding; self.artifact = artifact; self.snapshot = snapshot
        self.invoke = invoke ?? { [weak store] channel, input in
            guard let store else { throw DesktopRuntimeError("학습 저장 연결이 닫혔습니다.") }
            return try await store.invoke(channel, input)
        }
        let id = artifact["id"] as? String ?? ""
        let prior = (snapshot["quizAttempts"] as? [[String: Any]] ?? []).enumerated().filter { $0.element["artifactId"] as? String == id }
            .max { first, second in
                let firstTime = first.element["startedAt"] as? String ?? "", secondTime = second.element["startedAt"] as? String ?? ""
                return firstTime == secondTime ? first.offset < second.offset : firstTime < secondTime
            }?.element
        attemptID = prior?["id"] as? String ?? UUID().uuidString.lowercased()
        restoreAttempt(prior)
    }
    var attempt: [String: Any]? { (snapshot["quizAttempts"] as? [[String: Any]] ?? []).first { $0["id"] as? String == attemptID } }
    var submitted: Bool { attempt?["submittedAt"] as? String != nil }
    private func restoreAttempt(_ value: [String: Any]?) {
        completed = value?["completedAt"] as? String != nil
        answers = [:]; selfChecks = [:]
        for row in value?["answers"] as? [[String: Any]] ?? [] {
            guard let question = row["questionId"] as? String else { continue }
            answers[question] = row["answer"] as? String ?? ""; selfChecks[question] = row["selfCheck"] as? Bool
        }
    }
    /// A background detail reload must not replace a locally edited answer with
    /// a snapshot that began before that edit or abandon an unpersisted retry.
    func update(artifact: [String: Any], snapshot: [String: Any]) {
        guard !retired else { return }
        self.artifact = artifact
        guard dirty.isEmpty, flushTask == nil, !busy, (snapshot["revision"] as? Int ?? 0) >= (self.snapshot["revision"] as? Int ?? 0) else { return }
        self.snapshot = snapshot
        if !freshAttempt, let attempt { restoreAttempt(attempt) }
        changes.send()
    }
    func answer(_ question: String, text: String, check: Bool?) {
        guard !completed, !retired, !busy else { return }
        if artifact["generationMode"] as? String == "expected-exam" {
            if submitted && (check == nil || answers[question] != text) { return }
            if !submitted && check != nil { return }
        }
        if answers[question] != text && check == nil { selfChecks[question] = nil }
        answers[question] = text; if let check { selfChecks[question] = check }
        dirty.insert(question); saved = false; error = nil; store?.markDocumentChanged(); changes.send()
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled else { return }
            do { try await self?.flush() } catch { self?.setError(error) }
        }
    }
    func flush() async throws {
        if let flushTask { try await flushTask.value; if !dirty.isEmpty { try await flush() }; return }
        guard !dirty.isEmpty else { return }
        guard !retired, store != nil, let artifactID = artifact["id"] as? String else { throw DesktopRuntimeError("답안을 저장할 학습 자료를 확인해 주세요.") }
        let task = Task { @MainActor [self] in
            defer { flushTask = nil }
            while let question = dirty.sorted().first {
                let text = answers[question] ?? "", check = selfChecks[question], capturedAttempt = attemptID
                var request: [String: Any] = ["binding": binding.request, "artifactId": artifactID, "attemptId": capturedAttempt, "questionId": question, "answer": text]
                if let check { request["selfCheck"] = check }
                let value = try await invoke("learning:saveQuizAnswer", request) as? [String: Any] ?? [:]
                guard capturedAttempt == attemptID else { continue }
                if answers[question] == text && selfChecks[question] == check { dirty.remove(question) }
                snapshot = value; freshAttempt = false; changes.send()
            }
            saved = true; error = nil; changes.send()
        }
        flushTask = task; try await task.value
    }
    func finish() async { _ = await mutate("learning:finishQuiz") }
    func submit() async {
        guard await mutate("learning:submitQuiz") else { return }
        if !(artifact["questions"] as? [[String: Any]] ?? []).contains(where: { $0["type"] as? String == "short-answer" }) { await finish() }
    }
    @discardableResult private func mutate(_ channel: String) async -> Bool {
        guard !busy, !retired, store != nil, let id = artifact["id"] as? String else { return false }
        busy = true; changes.send()
        defer { busy = false; changes.send() }
        do {
            try await flush()
            snapshot = try await invoke(channel, ["binding": binding.request, "artifactId": id, "attemptId": attemptID]) as? [String: Any] ?? snapshot
            completed = attempt?["completedAt"] as? String != nil; error = nil; return true
        } catch { setError(error); return false }
    }
    func retry() {
        // A retry must not silently drop an answer still waiting for persistence.
        guard !busy, !retired, dirty.isEmpty, flushTask == nil else { return }
        debounce?.cancel(); completed = false; attemptID = UUID().uuidString.lowercased(); freshAttempt = true
        answers = [:]; selfChecks = [:]; saved = true; error = nil; changes.send()
    }
    func retire() { retired = true; debounce?.cancel() }
    private func setError(_ error: Error) { self.error = error.localizedDescription; changes.send() }
}

@MainActor
final class NativeLearningSessionRegistry {
    private weak var store: NativeWorkspaceStore?
    private var quizzes: [String: NativeLearningQuizSession] = [:]
    init(store: NativeWorkspaceStore) { self.store = store }
    func quiz(binding: NativeLearningBinding, artifact: [String: Any], snapshot: [String: Any]) -> NativeLearningQuizSession? {
        guard let store, let id = artifact["id"] as? String else { return nil }
        let key = binding.id + ":" + id
        if let existing = quizzes[key], !existing.retired { existing.update(artifact: artifact, snapshot: snapshot); return existing }
        let session = NativeLearningQuizSession(store: store, binding: binding, artifact: artifact, snapshot: snapshot)
        quizzes[key] = session; return session
    }
}
