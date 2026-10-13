import XCTest
@testable import Bandal

@MainActor
final class LearningTests: XCTestCase {
    func testQuizImportsAllQuestionTypesAndGradesAcceptedAnswers() throws {
        let input = #"{"title":"Revision","questions":[{"type":"choice","prompt":"Pick A","options":["A","B"],"answer":"A"},{"type":"cloze","prompt":"___ language","answer":"Swift","acceptedAnswers":["Swift language"]},{"type":"short-answer","prompt":"Explain","answer":"A model answer","explanation":"The principle"}]}"#
        let quiz = try LearningQuiz.fromJSON(Data(input.utf8), courseID: "course")
        XCTAssertEqual(quiz.questions.count, 3)
        XCTAssertEqual(Set(quiz.questions.map(\.id)).count, 3)
        XCTAssertTrue(quiz.questions[0].matches("A"))
        XCTAssertFalse(quiz.questions[0].matches("a"))
        XCTAssertTrue(quiz.questions[1].matches("  SWIFT\n language  "))
        XCTAssertFalse(quiz.questions[1].matches(""))
        XCTAssertEqual(quiz.questions[2].type, .shortAnswer)
        XCTAssertEqual(quiz.questions[2].explanation, "The principle")
        let restored = try AppModel.decoder.decode(LearningQuiz.self, from: AppModel.encoder.encode(quiz))
        XCTAssertLessThan(abs(restored.createdAt.timeIntervalSince(quiz.createdAt)), 1)
        var expected = quiz; expected.createdAt = restored.createdAt
        XCTAssertEqual(restored, expected)
    }

    func testQuizRejectsUnusableChoiceAndRepeatedQuestionIDs() throws {
        for input in [
            #"{"title":"Bad","questions":[]}"#,
            #"{"title":"Bad","questions":[{"type":"choice","prompt":"Q","options":["A","B"],"answer":"C"}]}"#,
            #"{"title":"Bad","questions":[{"type":"choice","prompt":"Q","options":["A","A"],"answer":"A"}]}"#,
            #"{"title":"Bad","questions":[{"type":"other","prompt":"Q","answer":"A"}]}"#
        ] { XCTAssertThrowsError(try LearningQuiz.fromJSON(Data(input.utf8), courseID: "course")) }
        let question = LearningQuizQuestion(type: .cloze, prompt: "Q", answer: "A")
        XCTAssertThrowsError(try LearningQuiz(courseID: "course", title: "Duplicate", questions: [question, question]).validate())
    }

    func testArticleExtractorKeepsReadableSourceAndDropsActiveContent() {
        let html = #"<html><head><title>A &amp; B</title></head><body><nav>Menu</nav><article><h1>A lesson</h1><p>A &lt; B &amp; &#x1F319;</p><script>fetch('https://tracker')</script><p>Second <strong>paragraph</strong>.</p><iframe src='https://external'>hidden</iframe></article><footer>Footer</footer></body></html>"#
        let result = LearningArticleParser.extract(html)
        XCTAssertEqual(result.title, "A & B")
        XCTAssertEqual(result.paragraphs, ["A lesson", "A < B & 🌙", "Second paragraph."])
        XCTAssertEqual(LearningArticleParser.pasted(" first \n\n second \n"), ["first", "second"])
    }

    func testConcurrentAttemptEventsMergeWithoutLosingAnotherAnswer() throws {
        let first = LearningQuizAnswer(response: "A", correct: true, selfChecked: false, submitted: true, updatedAt: 1)
        let second = LearningQuizAnswer(response: "B", correct: false, selfChecked: true, submitted: true, updatedAt: 2)
        let older = LearningQuizAttempt(attemptID: "shared", courseID: "course", quizID: "quiz", answers: ["one": first], currentIndex: 0, startedAt: Date(), eventTime: 1, completedAt: nil)
        let later = LearningQuizAttempt(attemptID: "shared", courseID: "course", quizID: "quiz", answers: ["two": second], currentIndex: 1, startedAt: older.startedAt, eventTime: 2, completedAt: nil)
        let merged = try XCTUnwrap(LearningQuizAttempt.merged([older, later]))
        XCTAssertEqual(merged.answers.count, 2)
        XCTAssertEqual(merged.score, 1)
        XCTAssertEqual(merged.currentIndex, 1)
    }

    @MainActor
    func testArticleQuizAndProgressSurviveRepositoryReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageRoot: directory, seedWelcome: false)
        while model.loading { await Task.yield() }
        model.addCourse("Reading")
        let library = LearningLibrary()
        let article = LearningArticle(courseID: model.courseID, title: "Saved source", sourceURL: "https://example.org/article", paragraphs: ["First paragraph", "Second paragraph"])
        let quiz = LearningQuiz(courseID: model.courseID, title: "Recall", questions: [LearningQuizQuestion(type: .cloze, prompt: "___", answer: "A")])
        let progress = LearningReadingProgress(courseID: model.courseID, articleID: article.id, paragraphIndex: 1, completed: true)
        library.save(article, model: model); library.save(quiz, model: model); library.save(progress, model: model)
        let answer = LearningQuizAnswer(response: "A", correct: true, selfChecked: false, submitted: true)
        let attempt = LearningQuizAttempt(attemptID: UUID().uuidString, courseID: model.courseID, quizID: quiz.id, answers: [quiz.questions[0].id: answer], currentIndex: 0, startedAt: Date(), completedAt: Date())
        library.save(attempt, model: model)
        await model.flush()
        let reopened = AppModel(storageRoot: directory, seedWelcome: false)
        while reopened.loading { await Task.yield() }
        let restored = LearningLibrary(); await restored.reload(reopened)
        XCTAssertEqual(restored.articles.first?.paragraphs, article.paragraphs)
        XCTAssertEqual(restored.quizzes.first?.questions, quiz.questions)
        XCTAssertEqual(restored.latestProgress(article.id)?.paragraphIndex, 1)
        XCTAssertEqual(restored.latestProgress(article.id)?.completed, true)
        XCTAssertEqual(restored.attempts.first?.score, 1)
        XCTAssertNil(restored.error)
    }
}
