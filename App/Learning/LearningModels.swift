import Foundation

enum LearningError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum LearningQuestionType: String, Codable, CaseIterable, Identifiable {
    case choice, cloze
    case shortAnswer = "short-answer"
    var id: String { rawValue }
    var title: String { switch self { case .choice: "객관식"; case .cloze: "빈칸"; case .shortAnswer: "서술형" } }
}

struct LearningQuizQuestion: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var type: LearningQuestionType
    var prompt: String
    var options: [String] = []
    var answer: String
    var acceptedAnswers: [String] = []
    var explanation: String = ""

    func matches(_ response: String) -> Bool {
        let normalized = Self.normalized(response)
        guard !normalized.isEmpty else { return false }
        // Choice labels are exact; free-text answers ignore case and whitespace.
        if type == .choice { return response == answer }
        return ([answer] + acceptedAnswers).contains { Self.normalized($0) == normalized }
    }
    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct LearningQuiz: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var courseID: String
    var title: String
    var questions: [LearningQuizQuestion]
    var sourceMaterialID: String? = nil
    var createdAt: Date = Date()

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              (1...100).contains(questions.count), Set(questions.map(\.id)).count == questions.count else {
            throw LearningError.message("퀴즈 제목과 1~100개의 서로 다른 문제를 입력해 주세요.")
        }
        for question in questions {
            guard !question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !question.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.prompt.count <= 20_000, question.answer.count <= 10_000,
                  question.explanation.count <= 20_000, question.acceptedAnswers.count <= 30,
                  question.acceptedAnswers.allSatisfy({ $0.count <= 10_000 }) else {
                throw LearningError.message("모든 문제에 질문과 정답이 필요합니다. 너무 긴 내용은 나누어 주세요.")
            }
            if question.type == .choice {
                guard (2...8).contains(question.options.count), Set(question.options).count == question.options.count,
                      question.options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 5_000 }),
                      question.options.contains(question.answer) else {
                    throw LearningError.message("객관식에는 서로 다른 보기 2~8개와 보기 중 하나와 일치하는 정답이 필요합니다.")
                }
            }
        }
        guard try JSONEncoder().encode(self).count <= 2_000_000 else { throw LearningError.message("퀴즈가 너무 큽니다. 여러 퀴즈로 나누어 주세요.") }
    }

    /// Accepts the public AI/import schema; IDs and dates are assigned locally.
    static func fromJSON(_ data: Data, courseID: String, sourceMaterialID: String? = nil) throws -> LearningQuiz {
        struct Draft: Decodable {
            struct Question: Decodable { var type: LearningQuestionType; var prompt: String; var options: [String]?; var answer: String; var acceptedAnswers: [String]?; var explanation: String? }
            var title: String; var questions: [Question]
        }
        guard data.count <= 1_000_000 else { throw LearningError.message("퀴즈 데이터가 너무 큽니다.") }
        let draft = try JSONDecoder().decode(Draft.self, from: data)
        let result = LearningQuiz(courseID: courseID, title: draft.title, questions: draft.questions.map {
            LearningQuizQuestion(type: $0.type, prompt: $0.prompt, options: $0.options ?? [], answer: $0.answer, acceptedAnswers: $0.acceptedAnswers ?? [], explanation: $0.explanation ?? "")
        }, sourceMaterialID: sourceMaterialID)
        try result.validate()
        return result
    }
}

struct LearningQuizAnswer: Codable, Equatable {
    var response: String
    var correct: Bool?
    var selfChecked: Bool
    var submitted: Bool = false
    var answeredAt: Date = Date()
    var updatedAt: TimeInterval = Date().timeIntervalSince1970
}

/// One immutable event per answer revision avoids overwriting another device's attempt.
struct LearningQuizAttempt: Codable, Identifiable {
    var recordType: String = "quiz-attempt"
    var id: String = UUID().uuidString
    var attemptID: String
    var courseID: String
    var quizID: String
    var answers: [String: LearningQuizAnswer]
    var currentIndex: Int
    var startedAt: Date
    var createdAt: Date = Date()
    var eventTime: TimeInterval = Date().timeIntervalSince1970
    var completedAt: Date?
    var score: Int { answers.values.filter { $0.correct == true }.count }
    static func merged(_ revisions: [LearningQuizAttempt]) -> LearningQuizAttempt? {
        guard var latest = revisions.max(by: { $0.eventTime < $1.eventTime }) else { return nil }
        var answers: [String: LearningQuizAnswer] = [:]
        for revision in revisions {
            for (questionID, answer) in revision.answers {
                if answers[questionID].map({ $0.updatedAt <= answer.updatedAt }) ?? true { answers[questionID] = answer }
            }
        }
        latest.answers = answers
        latest.completedAt = revisions.compactMap(\.completedAt).max()
        return latest
    }
}

struct LearningArticle: Codable, Identifiable, Equatable {
    var recordType: String = "article"
    var id: String = UUID().uuidString
    var courseID: String
    var title: String
    var sourceURL: String?
    var paragraphs: [String]
    var createdAt: Date = Date()
}

struct LearningReadingProgress: Codable, Identifiable {
    var recordType: String = "article-progress"
    var id: String = UUID().uuidString
    var courseID: String
    var articleID: String
    var paragraphIndex: Int
    var completed: Bool
    var createdAt: Date = Date()
    var eventTime: TimeInterval = Date().timeIntervalSince1970
}

enum LearningArticleParser {
    static func extract(_ html: String) -> (title: String, paragraphs: [String]) {
        let title = firstCapture(html, pattern: "(?is)<title\\b[^>]*>(.*?)</title>").map(plainText) ?? ""
        var content = firstCapture(html, pattern: "(?is)<article\\b[^>]*>(.*?)</article>")
            ?? firstCapture(html, pattern: "(?is)<main\\b[^>]*>(.*?)</main>") ?? html
        content = content.replacingOccurrences(of: "(?is)<!--.*?-->|<(script|style|noscript|svg|iframe|head|nav|header|footer|aside|form)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        content = content.replacingOccurrences(of: "(?i)</?(p|div|h[1-6]|li|ul|ol|blockquote|section|article|main|tr)\\b[^>]*>|<br\\s*/?>", with: "\n\n", options: .regularExpression)
        content = content.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let paragraphs = content.components(separatedBy: "\n\n").flatMap { part -> [String] in
            let cleaned = entities(part).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty else { return [] }
            // A long uninterrupted block is split for usable reading positions.
            var remaining = cleaned[...], chunks: [String] = []
            while remaining.count > 3_000 { let end = remaining.index(remaining.startIndex, offsetBy: 3_000); chunks.append(String(remaining[..<end])); remaining = remaining[end...] }
            if !remaining.isEmpty { chunks.append(String(remaining)) }
            return chunks
        }
        return (title, Array(paragraphs.prefix(1_500)))
    }
    static func pasted(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private static func firstCapture(_ value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    private static func plainText(_ value: String) -> String { entities(value.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func entities(_ value: String) -> String {
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "bull": "•", "copy": "©", "reg": "®", "eacute": "é", "ouml": "ö", "uuml": "ü", "auml": "ä"]
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let full = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: value) else { continue }
            let key = String(value[inner]); var replacement = names[key]
            if key.hasPrefix("#x"), let number = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            else if key.hasPrefix("#"), let number = UInt32(key.dropFirst()), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            if let replacement { result.replaceSubrange(full, with: replacement) }
        }
        return result
    }
}
