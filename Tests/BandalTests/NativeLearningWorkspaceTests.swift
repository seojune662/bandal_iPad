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
