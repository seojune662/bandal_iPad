import Foundation
import XCTest
@testable import Bandal

final class NativeLearningActionTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var learning: NativeLearningRepository!
    private var course = ""
    private var binding: [String: Any] = [:]
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("learning-actions-\(UUID().uuidString)")
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context)
        course = try XCTUnwrap((library.handle("courses:create", ["name": "Physics", "color": "blue"]) as? [String: Any])?["id"] as? String)
        _ = try library.handle("materials:writeFile", ["courseId": course, "dirRelPath": "", "fileName": "source.md", "encoding": "utf8", "data": "A vector has magnitude and direction."])
        learning = NativeLearningRepository(context: context)
        let project = try XCTUnwrap(learning.handle("learning:create", ["placement": "in-course", "courseId": course, "name": "Review", "topic": "Physics"]) as? [String: Any])
        binding = try XCTUnwrap(project["binding"] as? [String: Any])
    }
    override func tearDownWithError() throws { learning = nil; context = nil; try FileManager.default.removeItem(at: root) }
    private func call(_ channel: String, _ input: [String: Any] = [:]) throws -> [String: Any] {
        let result = try learning.handle(channel, input.merging(["binding": binding]) { _, new in new })
        return try XCTUnwrap(result as? [String: Any])
    }
    private var source: [String: Any] { ["kind": "material", "pathScope": "course", "sourceCourseId": course, "relPath": "source.md", "quote": "A vector has magnitude and direction."] }
    private func quiz() throws {
        _ = try call("nativeLearning:putArtifact", ["artifact": ["id": "quiz", "kind": "quiz", "title": "Vectors", "sourceRefs": [source], "questions": [
            ["id": "choice", "type": "choice", "prompt": "What does a vector have?", "options": [["id": "a", "text": "Magnitude and direction"], ["id": "b", "text": "Neither"]], "answer": "a", "explanation": "The original states both."],
            ["id": "short", "type": "short-answer", "prompt": "Explain a vector.", "answer": "Magnitude and direction", "explanation": "Check both parts."]
        ]]])
    }
    func testQuizRequiresEveryAnswerAndShortAnswerSelfCheckThenSurvivesReopen() throws {
        try quiz()
        _ = try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "choice", "answer": "a"])
        XCTAssertThrowsError(try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"]))
        _ = try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "short", "answer": "Magnitude and direction"])
        XCTAssertThrowsError(try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"]))
        _ = try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "short", "answer": "Magnitude and direction", "selfCheck": true])
        let completed = try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"])
        let attempt = try XCTUnwrap((completed["quizAttempts"] as? [[String: Any]])?.first)
        XCTAssertEqual(attempt["score"] as? Int, 1); XCTAssertEqual(attempt["total"] as? Int, 1)
        XCTAssertEqual(attempt["selfCheckedCount"] as? Int, 1); XCTAssertEqual(attempt["selfPassedCount"] as? Int, 1)
        let revision = completed["revision"] as? Int
        XCTAssertEqual(try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"])["revision"] as? Int, revision)
        XCTAssertThrowsError(try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "choice", "answer": "b"]))
        learning = NativeLearningRepository(context: context)
        XCTAssertEqual(try call("learning:get")["revision"] as? Int, revision)
        let path = try XCTUnwrap(attempt["resultRelPath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try context.courseFolder(course).appendingPathComponent("Review/" + path).path))
    }
    func testQuizRejectsUnknownChoiceAndTamperedArtifactWithoutChangingAttempt() throws {
        try quiz()
        XCTAssertThrowsError(try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "a", "questionId": "choice", "answer": "invented"]))
        let state = try call("learning:get"), ref = try XCTUnwrap((state["artifacts"] as? [[String: Any]])?.first)
        let path = try XCTUnwrap(ref["relPath"] as? String)
        try Data("{}".utf8).write(to: context.courseFolder(course).appendingPathComponent("Review/" + path))
        XCTAssertThrowsError(try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "a", "questionId": "choice", "answer": "a"]))
        XCTAssertEqual((try call("learning:get")["quizAttempts"] as? [Any])?.count, 0)
    }
    func testCardRatingIsIdempotentAndMatchesDesktopIntervals() throws {
        _ = try call("nativeLearning:putArtifact", ["artifact": ["id": "cards", "kind": "cards", "title": "Vectors", "sourceRefs": [source], "cards": [["id": "card", "front": "Vector?", "back": "Magnitude and direction"]]]])
        let good = try call("learning:reviewCard", ["cardId": "card", "reviewId": "r1", "rating": "good"])
        var card = try XCTUnwrap((good["cards"] as? [[String: Any]])?.first)
        XCTAssertEqual(card["intervalDays"] as? Int, 1); XCTAssertEqual(card["repetitions"] as? Int, 1)
        XCTAssertEqual(try call("learning:reviewCard", ["cardId": "card", "reviewId": "r1", "rating": "good"])["revision"] as? Int, good["revision"] as? Int)
        let next = try call("learning:reviewCard", ["cardId": "card", "reviewId": "r2", "rating": "good"])
        card = try XCTUnwrap((next["cards"] as? [[String: Any]])?.first); XCTAssertEqual(card["intervalDays"] as? Int, 3)
        let hard = try call("learning:reviewCard", ["cardId": "card", "reviewId": "r3", "rating": "hard"])
        card = try XCTUnwrap((hard["cards"] as? [[String: Any]])?.first); XCTAssertEqual(card["intervalDays"] as? Int, 3); XCTAssertEqual(card["repetitions"] as? Int, 2)
        let again = try call("learning:reviewCard", ["cardId": "card", "reviewId": "r4", "rating": "again"])
        card = try XCTUnwrap((again["cards"] as? [[String: Any]])?.first)
        XCTAssertEqual(card["intervalDays"] as? Int, 0); XCTAssertEqual(card["repetitions"] as? Int, 0); XCTAssertEqual(card["lapses"] as? Int, 1)
        XCTAssertThrowsError(try call("learning:reviewCard", ["cardId": "other", "reviewId": "r4", "rating": "good"]))
    }
    func testArtifactRequiresUnchangedGroundedSourceAndUniqueIdentities() throws {
        let invalid: [String: Any] = ["id": "bad", "kind": "summary", "title": "Summary", "markdown": "Invented", "sourceRefs": [source.merging(["quote": "This was fabricated"]) { _, new in new }]]
        XCTAssertThrowsError(try call("nativeLearning:putArtifact", ["artifact": invalid]))
        XCTAssertEqual((try call("learning:get")["artifacts"] as? [Any])?.count, 0)
        let bytes = try Data(contentsOf: context.courseFolder(course).appendingPathComponent("source.md"))
        let oldSource = source.merging(["contentHash": NativeSyncFormat.hash(bytes)]) { _, new in new }
        try Data("A vector has magnitude and direction. Changed.".utf8).write(to: context.courseFolder(course).appendingPathComponent("source.md"))
        XCTAssertThrowsError(try call("nativeLearning:putArtifact", ["artifact": ["kind": "summary", "title": "Changed", "markdown": "Summary", "sourceRefs": [oldSource]]]))
    }
    func testSavedArticleProgressAndCompletionValidateParagraph() throws {
        _ = try call("nativeLearning:putArticle", ["article": ["id": "article", "title": "Vectors", "sourceUrl": "https://example.com/vectors", "canonicalUrl": "https://example.com/vectors", "paragraphs": [["id": "p1", "text": "A vector has direction.", "sentences": [["id": "s1", "text": "A vector has direction.", "start": 0, "end": 23]]]]]])
        XCTAssertThrowsError(try call("learning:saveProgress", ["articleId": "article", "paragraphId": "wrong", "scrollFraction": 0.5]))
        let state = try call("learning:saveProgress", ["articleId": "article", "paragraphId": "p1", "scrollFraction": 0.5])
        XCTAssertEqual((state["articles"] as? [[String: Any]])?.first?["status"] as? String, "reading")
        let done = try call("learning:completeArticle", ["articleId": "article"])
        XCTAssertEqual((done["articles"] as? [[String: Any]])?.first?["status"] as? String, "completed")
        XCTAssertEqual(try call("learning:completeArticle", ["articleId": "article"])["revision"] as? Int, done["revision"] as? Int)
    }
    func testRestartMarksOnlyPendingRunsInterrupted() throws {
        _ = try call("nativeLearning:updateRun", ["run": ["id": "running", "status": "running"]])
        _ = try call("nativeLearning:updateRun", ["run": ["id": "done", "status": "complete"]])
        try learning.recoverInterruptedRuns()
        let runs = try XCTUnwrap(try call("learning:get")["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.first { $0["id"] as? String == "running" }?["status"] as? String, "interrupted")
        XCTAssertEqual(runs.first { $0["id"] as? String == "done" }?["status"] as? String, "complete")
    }
    func testResultPublicationFailureDoesNotStrandAnImmutableQuizReceipt() throws {
        try quiz()
        _ = try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "choice", "answer": "a"])
        _ = try call("learning:saveQuizAnswer", ["artifactId": "quiz", "attemptId": "attempt", "questionId": "short", "answer": "Magnitude and direction", "selfCheck": true])
        let directory = try context.courseFolder(course).appendingPathComponent("Review/.bandal/learning")
        let previous = directory.appendingPathComponent("previous.json"), backup = directory.appendingPathComponent("previous.saved")
        let stateURL = directory.appendingPathComponent("state.json"), before = try Data(contentsOf: stateURL)
        try FileManager.default.moveItem(at: previous, to: backup)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        XCTAssertThrowsError(try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"]))
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        let result = directory.appendingPathComponent("results/quiz-attempt.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path), "A failed state publication cannot leave an immutable result that blocks the retry")
        try FileManager.default.removeItem(at: previous); try FileManager.default.moveItem(at: backup, to: previous)
        let saved = try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"])
        XCTAssertNotNil((saved["quizAttempts"] as? [[String: Any]])?.first?["completedAt"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(try call("learning:finishQuiz", ["artifactId": "quiz", "attemptId": "attempt"])["revision"] as? Int, saved["revision"] as? Int)
    }
    func testInterruptedResultAndStatePublicationRollBackBeforeRetry() throws {
        _ = try call("nativeLearning:putArtifact", ["artifact": ["id": "cards", "kind": "cards", "title": "Vectors", "sourceRefs": [source], "cards": [["id": "card", "front": "Vector?", "back": "Magnitude and direction"]]]])
        let directory = try context.courseFolder(course).appendingPathComponent("Review/.bandal/learning")
        let stateURL = directory.appendingPathComponent("state.json"), before = try Data(contentsOf: stateURL)
        let resultURL = directory.appendingPathComponent("results/review-interrupted.json")
        let operation = UUID().uuidString.lowercased(), recovery = root.appendingPathComponent("SyncRecovery/" + operation)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let afterResult = Data("{\"interrupted\":true}".utf8)
        var afterState = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        afterState["revision"] = ((afterState["revision"] as? Int) ?? 0) + 1
        let after = Data(try NativeRepositoryContext.json(afterState).utf8)
        try before.write(to: recovery.appendingPathComponent("1.original"))
        let entries: [[String: Any]] = [
            ["target": resultURL.path, "backup": recovery.appendingPathComponent("0.original").path, "existed": false, "remove": false, "afterHash": NativeSyncFormat.hash(afterResult)],
            ["target": stateURL.path, "backup": recovery.appendingPathComponent("1.original").path, "existed": true, "remove": false, "beforeHash": NativeSyncFormat.hash(before), "afterHash": NativeSyncFormat.hash(after)]
        ]
        try Data(try NativeRepositoryContext.json(["id": operation, "entries": entries]).utf8).write(to: recovery.appendingPathComponent("intent.json"))
        try afterResult.write(to: resultURL); try after.write(to: stateURL)
        XCTAssertThrowsError(try call("learning:reviewCard", ["cardId": "card", "reviewId": "interrupted", "rating": "good"]), "A later edit must not race an uncommitted recovery intent")
        try NativeSyncJournal(context: context).recover()
        learning = NativeLearningRepository(context: context)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultURL.path))
        let saved = try call("learning:reviewCard", ["cardId": "card", "reviewId": "interrupted", "rating": "good"])
        XCTAssertEqual((saved["cards"] as? [[String: Any]])?.first?["repetitions"] as? Int, 1)
        XCTAssertEqual(try call("learning:reviewCard", ["cardId": "card", "reviewId": "interrupted", "rating": "good"])["revision"] as? Int, saved["revision"] as? Int)
    }

    func testArticleGroundingRejectsStaleHashAndChangedOriginalWithoutRewritingIt() throws {
        _ = try call("nativeLearning:putArticle", ["article": ["id": "article", "title": "Vectors", "sourceUrl": "https://example.com/vectors", "paragraphs": [["id": "p1", "text": "A vector has direction.", "sentences": []]]]])
        let source: [String: Any] = ["kind": "article", "articleId": "article", "paragraphId": "p1", "quote": "A vector has direction.", "contentHash": String(repeating: "0", count: 64)]
        XCTAssertThrowsError(try call("nativeLearning:putArtifact", ["artifact": ["id": "summary", "kind": "summary", "title": "Vectors", "markdown": "Summary", "sourceRefs": [source]]]))
        let original = try call("learning:getArticle", ["id": "article"])
        XCTAssertEqual(original["title"] as? String, "Vectors")
        let url = try context.courseFolder(course).appendingPathComponent("Review/.bandal/learning/articles/article.json")
        var changed = original; changed["paragraphs"] = [["id": "p1", "text": "A vector has direction. External edits are not the retained source.", "sentences": []]]
        let bytes = Data(try NativeRepositoryContext.json(changed).utf8); try bytes.write(to: url)
        XCTAssertThrowsError(try call("learning:getArticle", ["id": "article"]))
        XCTAssertThrowsError(try call("learning:saveProgress", ["articleId": "article", "paragraphId": "p1", "scrollFraction": 0.5]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual((try call("learning:get")["artifacts"] as? [Any])?.count, 0)
    }
    func testReviewReceiptRejectsChangedRatingUnderSameId() throws {
        _ = try call("nativeLearning:putArtifact", ["artifact": ["id": "cards", "kind": "cards", "title": "Vectors", "sourceRefs": [source], "cards": [["id": "card", "front": "Vector?", "back": "Magnitude and direction"]]]])
        let saved = try call("learning:reviewCard", ["cardId": "card", "reviewId": "one", "rating": "good"])
        XCTAssertThrowsError(try call("learning:reviewCard", ["cardId": "card", "reviewId": "one", "rating": "again"]))
        XCTAssertEqual(try call("learning:get")["revision"] as? Int, saved["revision"] as? Int)
        XCTAssertEqual((try call("learning:get")["cards"] as? [[String: Any]])?.first?["repetitions"] as? Int, 1)
    }

    func testStartupSkipsInvalidProjectAndRecoversValidRunsInSameCourse() throws {
        _ = try call("nativeLearning:updateRun", ["run": ["id": "pending", "status": "running"]])
        _ = try learning.handle("learning:create", ["placement": "in-course", "courseId": course, "name": "AA Broken", "topic": "Unknown"])
        let directory = try context.courseFolder(course).appendingPathComponent("AA Broken/.bandal/learning")
        let state = directory.appendingPathComponent("state.json"), previous = directory.appendingPathComponent("previous.json")
        let damaged = Data("{ unavailable future document".utf8)
        try damaged.write(to: state); try damaged.write(to: previous)
        var warnings = 0
        context.emit = { channel, _ in if channel == "learning:recoveryWarning" { warnings += 1 } }
        try learning.recoverInterruptedRuns()
        XCTAssertGreaterThan(warnings, 0)
        XCTAssertEqual((try call("learning:get")["runs"] as? [[String: Any]])?.first?["status"] as? String, "interrupted")
        XCTAssertEqual(try Data(contentsOf: state), damaged); XCTAssertEqual(try Data(contentsOf: previous), damaged)
    }

}
