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
        let restored = try JSONDecoder().decode(LearningQuiz.self, from: JSONEncoder().encode(quiz))
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

}
