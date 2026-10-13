import SwiftUI

@MainActor
final class LearningLibrary: ObservableObject {
    @Published var articles: [LearningArticle] = []
    @Published var quizzes: [LearningQuiz] = []
    @Published var attempts: [LearningQuizAttempt] = []
    @Published var progress: [LearningReadingProgress] = []
    @Published var error: String?
    private var loadID = UUID()

    func reload(_ model: AppModel) async {
        let requestID = UUID(); loadID = requestID
        let courseID = model.courseID
        await model.flush()
        guard let store = model.store else { return }
        do {
            async let artifactRecords = store.list(kind: "artifact")
            async let quizRecords = store.list(kind: "quiz")
            async let eventRecords = store.list(kind: "learningEvent")
            let (artifacts, quizRows, events) = try await (artifactRecords, quizRecords, eventRecords)
            guard loadID == requestID, courseID == model.courseID else { return }
            articles = artifacts.compactMap { try? AppModel.decoder.decode(LearningArticle.self, from: $0.payload) }.filter { $0.recordType == "article" && $0.courseID == courseID }.sorted { $0.createdAt > $1.createdAt }
            quizzes = quizRows.compactMap { try? AppModel.decoder.decode(LearningQuiz.self, from: $0.payload) }.filter { $0.courseID == courseID && (try? $0.validate()) != nil }.sorted { $0.createdAt > $1.createdAt }
            let allAttempts = events.compactMap { try? AppModel.decoder.decode(LearningQuizAttempt.self, from: $0.payload) }.filter { $0.recordType == "quiz-attempt" && $0.courseID == courseID }
            attempts = Dictionary(grouping: allAttempts, by: \.attemptID).values.compactMap(LearningQuizAttempt.merged).sorted { $0.eventTime > $1.eventTime }
            progress = events.compactMap { try? AppModel.decoder.decode(LearningReadingProgress.self, from: $0.payload) }.filter { $0.recordType == "article-progress" && $0.courseID == courseID }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func latestProgress(_ articleID: String) -> LearningReadingProgress? { progress.filter { $0.articleID == articleID }.max { $0.eventTime < $1.eventTime } }
    func save(_ article: LearningArticle, model: AppModel) {
        model.persist(article, kind: "artifact", id: "article:\(article.id)")
        articles.removeAll { $0.id == article.id }; articles.insert(article, at: 0)
    }
    func save(_ quiz: LearningQuiz, model: AppModel) {
        model.persist(quiz, kind: "quiz", id: "quiz:\(quiz.id)")
        quizzes.removeAll { $0.id == quiz.id }; quizzes.insert(quiz, at: 0)
    }
    func save(_ event: LearningQuizAttempt, model: AppModel) {
        model.persist(event, kind: "learningEvent", id: "learningEvent:\(event.id)")
        attempts.removeAll { $0.attemptID == event.attemptID }; attempts.insert(event, at: 0)
    }
    func save(_ event: LearningReadingProgress, model: AppModel) {
        model.persist(event, kind: "learningEvent", id: "learningEvent:\(event.id)")
        progress.append(event)
    }
}

struct LearningHubView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LearningLibrary()
    @State private var section = 0
    @State private var article: LearningArticle?
    @State private var quiz: LearningQuiz?
    @State private var addingArticle = false
    @State private var addingQuiz = false
    @State private var generatingQuiz = false
    var body: some View {
        VStack(spacing: 0) {
            if let article {
                LearningArticleReader(article: article, initialProgress: library.latestProgress(article.id), onBack: { self.article = nil }, onProgress: { library.save($0, model: model) })
                    .id(article.id)
            } else if let quiz {
                LearningQuizPlayer(quiz: quiz, history: library.attempts.filter { $0.quizID == quiz.id }, onBack: { self.quiz = nil }, onSave: { library.save($0, model: model) }).id(quiz.id)
            } else {
                HStack {
                    Picker("학습 도구", selection: $section) { Text("읽기").tag(0); Text("퀴즈").tag(1); Text("카드·단어장").tag(2) }.pickerStyle(.segmented)
                    Button { Task { await library.reload(model) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("학습 자료 새로 고침")
                }.padding(.horizontal, 16).padding(.vertical, 4)
                Divider()
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.red).padding() }
                if section == 2 { LearningWorkspaceView() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if section == 0 { articleList } else { quizList }
                        }.padding(22).frame(maxWidth: 840)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: model.courseID) { article = nil; quiz = nil; await library.reload(model) }
        .onChange(of: model.syncStatus) { _, _ in Task { await library.reload(model) } }
        .onChange(of: model.notice) { _, _ in Task { await library.reload(model) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await library.reload(model) } } }
        .sheet(isPresented: $addingArticle) { LearningArticleImport(courseID: model.courseID) { saved in library.save(saved, model: model); article = saved } }
        .sheet(isPresented: $addingQuiz) { LearningQuizComposer(courseID: model.courseID) { saved in library.save(saved, model: model); quiz = saved } }
        .sheet(isPresented: $generatingQuiz) { LearningQuizGenerator(articles: library.articles) { saved in library.save(saved, model: model); quiz = saved } }
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("읽고, 나의 것으로").font(.title2.bold()); Spacer(); Button("글 추가", systemImage: "plus") { addingArticle = true }.buttonStyle(.borderedProminent) }
            Text("공개 웹 문서나 붙여 넣은 글을 저장하면 오프라인에서도 읽고, 문장과 함께 단어를 모을 수 있어요.").foregroundStyle(.secondary)
            if library.articles.isEmpty { ContentUnavailableView("아직 저장한 글이 없어요", systemImage: "text.book.closed", description: Text("읽고 싶은 글을 추가해 보세요.")) }
            ForEach(library.articles) { item in
                Button { article = item } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item.title).font(.headline); Spacer(); if library.latestProgress(item.id)?.completed == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(BandalTheme.accent) } }
                        Text(item.paragraphs.first ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        HStack { Text(item.sourceURL.flatMap { URL(string: $0)?.host } ?? "직접 저장한 글"); Spacer(); Text(item.createdAt, style: .date) }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: readingFraction(item)).tint(BandalTheme.accent)
                    }.padding(18).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).contextMenu {
                    Button("노트로 복사", systemImage: "note.text") { articleToNote(item) }
                    Button("삭제", systemImage: "trash", role: .destructive) { model.deleteRecord("article:\(item.id)"); library.articles.removeAll { $0.id == item.id } }
                }
            }
        }
    }
    private var quizList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("이해를 확인하는 퀴즈").font(.title2.bold()); Spacer(); quizActions }
                VStack(alignment: .leading) { Text("이해를 확인하는 퀴즈").font(.title2.bold()); quizActions }
            }
            Text("객관식과 빈칸은 정답을 비교하고, 서술형은 모범 답안으로 직접 점검해요. 풀이 이력은 기기에 저장하고 동기화합니다.").foregroundStyle(.secondary)
            if library.quizzes.isEmpty { ContentUnavailableView("첫 퀴즈를 만들어 보세요", systemImage: "questionmark.bubble", description: Text("직접 문제를 입력하거나, 선택한 자료로 AI에게 생성을 요청할 수 있어요.")) }
            ForEach(library.quizzes) { item in
                Button { quiz = item } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { Text(item.title).font(.headline); Spacer(); Image(systemName: "chevron.right") }
                        Text("\(item.questions.count)문제 · \(item.questions.map { $0.type.title }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · "))").font(.subheadline).foregroundStyle(.secondary)
                        if let attempt = library.attempts.first(where: { $0.quizID == item.id }) {
                            Text(attempt.completedAt == nil ? "이어서 풀기 · \(attempt.answers.count)/\(item.questions.count)" : "최근 결과 \(attempt.score)/\(item.questions.count)").font(.caption).foregroundStyle(BandalTheme.accent)
                        }
                    }.padding(18).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).contextMenu {
                    Button("문제·해설을 노트로 저장", systemImage: "note.text") { model.createNote(title: item.title, markdown: item.questions.enumerated().map { "## \($0.offset + 1). \($0.element.prompt)\n\n정답: \($0.element.answer)\n\n\($0.element.explanation)" }.joined(separator: "\n\n")) }
                    Button("삭제", systemImage: "trash", role: .destructive) { model.deleteRecord("quiz:\(item.id)"); library.quizzes.removeAll { $0.id == item.id } }
                }
            }
        }
    }
    private var quizActions: some View { HStack { Button("직접 만들기", systemImage: "plus") { addingQuiz = true }.buttonStyle(.bordered); Button("AI로 만들기", systemImage: "sparkles") { generatingQuiz = true }.buttonStyle(.borderedProminent) }.controlSize(.large) }
    private func readingFraction(_ article: LearningArticle) -> Double {
        guard let saved = library.latestProgress(article.id) else { return 0 }
        return saved.completed ? 1 : Double(saved.paragraphIndex) / Double(max(1, article.paragraphs.count))
    }
    private func articleToNote(_ article: LearningArticle) { model.createNote(title: article.title, markdown: "# \(article.title)\n\n" + (article.sourceURL.map { "출처: \($0)\n\n" } ?? "") + article.paragraphs.joined(separator: "\n\n")) }
}
