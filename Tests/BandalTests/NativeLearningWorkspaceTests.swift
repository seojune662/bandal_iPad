import XCTest
@testable import Bandal

@MainActor
final class NativeLearningWorkspaceTests: XCTestCase {
    private var root: URL!
    private var store: NativeWorkspaceStore!
    private var binding: NativeLearningBinding!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-learning-editor-" + UUID().uuidString)
        store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "Original")
        let course = try XCTUnwrap(store.selectedCourseID)
        _ = try await store.invoke("materials:writeFile", ["courseId": course, "dirRelPath": "", "fileName": "source.md", "encoding": "utf8", "data": "A vector has magnitude and direction."])
        let raw = try await store.invoke("learning:create", ["placement": "in-course", "courseId": course, "name": "Review", "topic": "Physics"]) as? [String: Any]
        binding = try NativeToolJSON.decode(try XCTUnwrap(raw?["binding"]))
        let source: [String: Any] = ["kind": "material", "pathScope": "course", "sourceCourseId": course, "relPath": "source.md", "quote": "A vector has magnitude and direction."]
        for id in ["quiz-a", "quiz-b"] {
            _ = try await store.invokePrivate("nativeLearning:putArtifact", ["binding": binding.request, "artifact": ["id": id, "kind": "quiz", "title": id, "sourceRefs": [source], "questions": [["id": "short", "type": "short-answer", "prompt": "Explain a vector", "answer": "Magnitude and direction", "explanation": "Both parts matter."]]]])
        }
    }
    override func tearDown() async throws {
        try await store.flushDocuments()
        store = nil
        try FileManager.default.removeItem(at: root)
    }
    func testNewStandaloneLearningCanBeSelectedBeforeCourseNotificationRefresh() async throws {
        let value = try await store.invoke("learning:create", ["placement": "standalone", "name": "Fresh", "topic": "Science", "purpose": "english-reading"]) as! [String: Any]
        let binding = try XCTUnwrap(value["binding"] as? [String: Any]), id = try XCTUnwrap(binding["courseId"] as? String)
        store.courses.removeAll { $0.id == id }
        await store.selectCourse(id)
        XCTAssertEqual(store.selectedCourseID, id)
        XCTAssertNil(store.errorMessage)
    }
    func testOverlappingCourseRefreshWaitsForSelectionSnapshotBeforePublishingNext() async throws {
        let queue = NativeCourseRefreshQueue()
        var courses = ["original"], selected: String?
        var explicitRead: CheckedContinuation<Void, Never>?
        var backgroundStarted = false
        let selecting = Task { @MainActor in
            try await queue.run {
                await withCheckedContinuation { explicitRead = $0 }
                courses = ["original", "new-learning"]
            }
            // This is selectCourse's existence check after its awaited load.
            XCTAssertTrue(courses.contains("new-learning"))
            selected = "new-learning"
        }
        while explicitRead == nil { await Task.yield() }
        let refreshing = Task { @MainActor in
            try await queue.run {
                backgroundStarted = true
                courses = ["original", "new-learning", "later-course"]
            }
        }
        await Task.yield()
        XCTAssertFalse(backgroundStarted, "A notification refresh must wait for the selection's snapshot publication")
        explicitRead?.resume()
        try await selecting.value
        try await refreshing.value
        XCTAssertEqual(selected, "new-learning")
        XCTAssertEqual(courses, ["original", "new-learning", "later-course"])
    }
    func testFailedCourseRefreshDoesNotPoisonQueuedRetry() async throws {
        let queue = NativeCourseRefreshQueue()
        var failedRead: CheckedContinuation<Void, Never>?
        var published = false
        let failing = Task { @MainActor in
            try await queue.run {
                await withCheckedContinuation { failedRead = $0 }
                throw DesktopRuntimeError("fixture refresh failure")
            }
        }
        while failedRead == nil { await Task.yield() }
        let retry = Task { @MainActor in try await queue.run { published = true } }
        await Task.yield()
        XCTAssertFalse(published)
        failedRead?.resume()
        do { try await failing.value; XCTFail("The failed refresh must report its error") }
        catch { XCTAssertEqual(error.localizedDescription, "fixture refresh failure") }
        try await retry.value
        XCTAssertTrue(published)
    }
    func testSwitchingQuizFlushesDraftAndReopeningKeepsExactAnswerAndSelfCheck() async throws {
        let model = NativeLearningWorkspaceModel(store: store, binding: binding)
        await model.start(); await model.openArtifact("quiz-a")
        model.answer("short", text: "방향과 크기\nOriginal answer", check: true)
        await model.openArtifact("quiz-b")
        XCTAssertTrue(model.answers.isEmpty)
        model.answer("short", text: "Second answer")
        try await store.flushDocuments()
        await model.close()
        let reopened = NativeLearningWorkspaceModel(store: store, binding: binding)
        await reopened.start(); await reopened.openArtifact("quiz-a")
        XCTAssertEqual(reopened.answers["short"], "방향과 크기\nOriginal answer")
        XCTAssertEqual(reopened.selfChecks["short"], true)
        XCTAssertTrue(reopened.saved)
        await reopened.openArtifact("quiz-b")
        XCTAssertEqual(reopened.answers["short"], "Second answer")
        XCTAssertNil(reopened.selfChecks["short"])
        await reopened.close()
    }
    func testChangingSelfCheckedTextRequiresNewCheckBeforeCompletionAndFreezeRejectsTyping() async throws {
        let model = NativeLearningWorkspaceModel(store: store, binding: binding)
        await model.start(); await model.openArtifact("quiz-a")
        model.answer("short", text: "Magnitude and direction", check: true)
        try await model.flush()
        model.answer("short", text: "Changed answer")
        XCTAssertNil(model.selfChecks["short"])
        await model.finishQuiz()
        XCTAssertFalse(model.completed)
        XCTAssertNotNil(model.error)
        model.answer("short", text: "Changed answer", check: false)
        await model.finishQuiz()
        XCTAssertTrue(model.completed)
        model.answer("short", text: "A completed answer must be immutable")
        XCTAssertEqual(model.answers["short"], "Changed answer")
        model.retryQuiz(); model.frozen = true
        model.answer("short", text: "External replacement in progress")
        XCTAssertTrue(model.answers.isEmpty)
        model.frozen = false
        await model.close()
    }
}

extension NativeLearningWorkspaceTests {
    func testIndependentArtifactTabsFlushBothAnswersWithoutReplacingEachOther() async throws {
        let first = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "artifact-tab-a")
        let second = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "artifact-tab-b")
        await first.start(); await first.openArtifact("quiz-a")
        await second.start(); await second.openArtifact("quiz-b")
        first.answer("short", text: "First independent draft", check: true)
        second.answer("short", text: "Second independent draft", check: false)
        try await store.flushDocuments()
        XCTAssertEqual(first.answers["short"], "First independent draft")
        XCTAssertEqual(second.answers["short"], "Second independent draft")
        await first.close(); await second.close()
        let reopened = NativeLearningWorkspaceModel(store: store, binding: binding)
        await reopened.start(); await reopened.openArtifact("quiz-a")
        XCTAssertEqual(reopened.answers["short"], "First independent draft")
        XCTAssertEqual(reopened.selfChecks["short"], true)
        await reopened.openArtifact("quiz-b")
        XCTAssertEqual(reopened.answers["short"], "Second independent draft")
        XCTAssertEqual(reopened.selfChecks["short"], false)
        await reopened.close()
    }
}

extension NativeLearningWorkspaceTests {
    func testDeleteAfterFlushAndRestorePreservesPendingQuizDraft() async throws {
        let model = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "deleting-project-quiz")
        await model.start(); await model.openArtifact("quiz-a")
        model.answer("short", text: "Draft typed immediately before deleting project")
        try await store.flushDocuments()
        _ = try await store.invoke("learning:delete", ["binding": binding.request])
        await model.close()
        _ = try await store.invoke("learning:restore", ["binding": binding.request])
        let restored = NativeLearningWorkspaceModel(store: store, binding: binding)
        await restored.start(); await restored.openArtifact("quiz-a")
        XCTAssertEqual(restored.answers["short"], "Draft typed immediately before deleting project")
        XCTAssertNil(store.errorMessage)
        await restored.close()
    }
}

extension NativeLearningWorkspaceTests {
    func testSameQuizSharesDraftAttemptCompletionAndRetryAcrossWindowInstances() async throws {
        let first = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "instance:first")
        let second = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "instance:second")
        await first.start(); await first.openArtifact("quiz-a")
        await second.start(); await second.openArtifact("quiz-a")
        first.answer("short", text: "First draft", check: true)
        XCTAssertEqual(second.answers["short"], "First draft")
        XCTAssertEqual(second.selfChecks["short"], true)
        second.answer("short", text: "Peer correction")
        XCTAssertEqual(first.answers["short"], "Peer correction")
        XCTAssertNil(first.selfChecks["short"])
        try await first.flush()
        let saved = try await store.invoke("learning:get", ["binding": binding.request]) as! [String: Any]
        let attempts = (saved["quizAttempts"] as! [[String: Any]]).filter { $0["artifactId"] as? String == "quiz-a" }
        XCTAssertEqual(attempts.count, 1, "Two windows must not create separate attempts for the same quiz")
        first.answer("short", text: "Peer correction", check: true)
        await second.finishQuiz()
        XCTAssertTrue(first.completed); XCTAssertTrue(second.completed)
        let oldAttempt = first.attempt?["id"] as? String
        first.retryQuiz()
        XCTAssertFalse(second.completed); XCTAssertTrue(second.answers.isEmpty)
        second.answer("short", text: "Shared retry", check: false)
        try await first.flush()
        XCTAssertNotEqual(first.attempt?["id"] as? String, oldAttempt)
        XCTAssertEqual(second.attempt?["id"] as? String, first.attempt?["id"] as? String)
        XCTAssertEqual(first.answers["short"], "Shared retry")
        await first.close(); await second.close()
    }

    func testSameExamSharesSubmissionAndRejectsPostSubmissionEditsFromOtherPane() async throws {
        let source: [String: Any] = ["kind": "material", "pathScope": "course", "sourceCourseId": binding.courseID, "relPath": "source.md", "quote": "A vector has magnitude and direction."]
        _ = try await store.invokePrivate("nativeLearning:putArtifact", ["binding": binding.request, "artifact": ["id": "shared-exam", "kind": "quiz", "title": "Exam", "generationMode": "expected-exam", "sourceRefs": [source], "questions": [["id": "short", "type": "short-answer", "prompt": "Explain a vector", "answer": "Magnitude and direction", "explanation": "Both parts matter."]]]])
        let first = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "exam-first")
        let second = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "exam-second")
        await first.start(); await first.openArtifact("shared-exam")
        await second.start(); await second.openArtifact("shared-exam")
        first.answer("short", text: "Magnitude and direction")
        await second.submitExam()
        XCTAssertTrue(first.submitted); XCTAssertTrue(second.submitted)
        first.answer("short", text: "Must not replace a submitted answer")
        XCTAssertEqual(second.answers["short"], "Magnitude and direction")
        first.answer("short", text: "Magnitude and direction", check: true)
        await second.finishQuiz(); XCTAssertTrue(first.completed)
        await first.close(); await second.close()
    }

    func testOpenArticleRefreshesPeerDetailsWithoutChangingPaneIdentity() async throws {
        _ = try await store.invokePrivate("nativeLearning:putArticle", ["binding": binding.request, "article": ["id": "shared-article", "title": "Vectors", "sourceUrl": "https://example.com/vectors", "paragraphs": [["id": "p1", "text": "A vector has direction.", "sentences": []]]]])
        let first = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "article-first")
        let second = NativeLearningWorkspaceModel(store: store, binding: binding, detailID: "article-second")
        await first.start(); await first.openArticle("shared-article")
        await second.start(); await second.openArticle("shared-article")
        XCTAssertNotEqual(first.panelID, second.panelID)
        let completed = await first.mutate("learning:completeArticle", ["articleId": "shared-article"])
        XCTAssertTrue(completed)
        await second.reload()
        XCTAssertEqual(second.article?["status"] as? String, "completed")
        XCTAssertEqual(second.article?["id"] as? String, "shared-article")
        await first.close(); await second.close()
    }
}

extension NativeLearningWorkspaceTests {
    func testPeerEditDuringSaveKeepsNewestAnswerAndRejectsStaleReload() async throws {
        let backend = HeldQuizWriter()
        let artifact: [String: Any] = ["id": "quiz", "kind": "quiz"]
        let session = NativeLearningQuizSession(store: store, binding: binding, artifact: artifact,
            snapshot: ["revision": 0, "quizAttempts": []], invoke: backend.invoke)
        session.answer("question", text: "first", check: nil)
        let saving = Task { @MainActor in try await session.flush() }
        while backend.waiting == nil { await Task.yield() }
        session.answer("question", text: "peer typed during first save", check: nil)
        backend.waiting?.resume(); backend.waiting = nil
        try await saving.value
        XCTAssertEqual(backend.answers, ["first", "peer typed during first save"])
        XCTAssertTrue(session.saved)
        XCTAssertEqual(session.answers["question"], "peer typed during first save")
        session.update(artifact: artifact, snapshot: ["revision": 1, "quizAttempts": [["id": session.attemptID, "answers": [["questionId": "question", "answer": "stale first snapshot"]]]]])
        XCTAssertEqual(session.answers["question"], "peer typed during first save", "An older peer reload must not undo an acknowledged later save")
    }

    @MainActor
    private final class HeldQuizWriter {
        var waiting: CheckedContinuation<Void, Never>?
        var answers: [String] = []
        func invoke(_ channel: String, _ request: [String: Any]) async throws -> Any {
            let answer = request["answer"] as! String
            answers.append(answer)
            if answers.count == 1 { await withCheckedContinuation { waiting = $0 } }
            return ["revision": answers.count, "quizAttempts": [["id": request["attemptId"]!, "artifactId": request["artifactId"]!, "answers": [["questionId": request["questionId"]!, "answer": answer]]]]]
        }
    }
}
