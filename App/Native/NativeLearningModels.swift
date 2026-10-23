import Combine
import Foundation

struct NativeLearningBinding: Codable, Hashable, Identifiable {
    let courseID: String
    let rootRelPath: String
    var id: String { courseID + ":" + rootRelPath }
    var request: [String: Any] { ["courseId": courseID, "rootRelPath": rootRelPath] }
    enum CodingKeys: String, CodingKey { case courseID = "courseId", rootRelPath }
}

struct NativeLearningSummary: Decodable, Identifiable {
    let binding: NativeLearningBinding
    let projectId: String?
    let name: String
    let topic: String
    let purpose: String?
    let linkedCourseId: String?
    let completedArticleCount: Int
    let wordCount: Int
    let dueCardCount: Int
    let updatedAt: String
    let deletedAt: String?
    let warning: String?
    var id: String { projectId ?? binding.id }
    var group: String { ["english-reading", "course-review"].contains(purpose ?? "") ? purpose! : "unclassified" }
    func displayName(courses: [NativeCourse]) -> String {
        guard name == "AI 학습자료", topic == "과목 자료", purpose == "course-review" else { return name }
        let source = courses.first { $0.id == (linkedCourseId ?? binding.courseID) && $0.workspaceKind != "study-space" }
        return source.map { $0.name + " 복습" } ?? "과목 복습"
    }
}

@MainActor
final class NativeLearningCatalog: ObservableObject {
    @Published var projects: [NativeLearningSummary] = []
    @Published var loading = false
    @Published var error: String?
    private var request = 0
    func reload(_ store: NativeWorkspaceStore, courseID: String? = nil) async {
        request += 1; let revision = request; loading = true
        defer { if request == revision { loading = false } }
        do {
            var input: [String: Any] = ["includeDeleted": true]
            if let courseID { input["courseId"] = courseID }
            let result = try await store.invoke("learning:list", input) as? [String: Any] ?? [:]
            let projects: [NativeLearningSummary] = try NativeToolJSON.decode(result["projects"] ?? [])
            guard request == revision, !Task.isCancelled else { return }
            self.projects = projects.sorted { $0.updatedAt > $1.updatedAt }; error = nil
        } catch { if request == revision { self.error = error.localizedDescription } }
    }
}

enum NativeLearningStartKind: String, Identifiable, CaseIterable {
    case english, quiz, flashcards
    var id: String { rawValue }
    var title: String { switch self { case .english: "영어 글 읽기"; case .quiz: "퀴즈 만들기"; case .flashcards: "카드 만들기" } }
    var detail: String { switch self { case .english: "관심 주제로 글을 찾고, 읽으며 표현을 모아요."; case .quiz: "내 자료로 문제를 만들고 직접 풀어봐요."; case .flashcards: "내 자료의 내용을 카드로 만들어 복습해요." } }
    var symbol: String { switch self { case .english: "Aa"; case .quiz: "?"; case .flashcards: "▤" } }
}
