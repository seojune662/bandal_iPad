import SwiftUI

struct LearningWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0
    @State private var front = ""
    @State private var back = ""
    @State private var revealed = false
    @State private var word = ""
    @State private var meaning = ""
    @State private var context = ""
    @State private var search = ""
    @State private var dictionaryResults: [DictionaryMeaning] = []
    private var dueCards: [Flashcard] { model.cards.filter { $0.courseID == model.courseID && $0.due <= Date() }.sorted { $0.due < $1.due } }
    var body: some View {
        VStack(spacing: 0) {
            Picker("학습", selection: $section) { Text("복습 카드").tag(0); Text("단어장").tag(1); Text("학습 자료").tag(2) }.pickerStyle(.segmented).padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if section == 0 { flashcards }
                    else if section == 1 { vocabulary }
                    else { generation }
                }.padding(24)
            }
        }
    }
    private var flashcards: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("오늘의 복습").font(.title2.bold())
            Text("복습할 카드 \(dueCards.count)개").foregroundStyle(.secondary)
            if let card = dueCards.first {
                VStack(spacing: 24) {
                    Text(card.front).font(.title3.weight(.medium)).frame(maxWidth: .infinity, minHeight: 90)
                    if revealed {
                        Divider(); Text(card.back).frame(maxWidth: .infinity, minHeight: 70)
                        HStack { Button("다시 학습") { model.reviewCard(card, remembered: false); revealed = false }.buttonStyle(.bordered); Button("기억했어요") { model.reviewCard(card, remembered: true); revealed = false }.buttonStyle(.borderedProminent) }
                    } else { Button("정답 보기") { revealed = true }.buttonStyle(.borderedProminent) }
                }.padding(24).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 18))
            } else { Label("오늘 예정된 복습을 마쳤어요.", systemImage: "checkmark.seal").foregroundStyle(BandalTheme.accent) }
            Divider()
            Text("새 카드 만들기").font(.headline)
            TextField("질문 또는 개념", text: $front, axis: .vertical).textFieldStyle(.roundedBorder)
            TextField("정답 또는 설명", text: $back, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("카드 추가") {
                model.saveCard(Flashcard(courseID: model.courseID, front: front.trimmingCharacters(in: .whitespacesAndNewlines), back: back.trimmingCharacters(in: .whitespacesAndNewlines))); front = ""; back = ""
            }.buttonStyle(.borderedProminent).disabled(front.trimmingCharacters(in: .whitespaces).isEmpty || back.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("전체 \(model.cards.filter { $0.courseID == model.courseID }.count)개 카드 · 학습 이력은 동기화됩니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("나의 단어장").font(.title2.bold())
            HStack { TextField("영어 사전 검색", text: $word).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(lookup); Button("찾기", action: lookup).buttonStyle(.bordered) }
            ForEach(dictionaryResults) { entry in
                VStack(alignment: .leading, spacing: 5) { Text(entry.word).font(.headline); Text(entry.meaning).font(.subheadline); if let url = URL(string: entry.source) { Link("Wiktionary 출처", destination: url).font(.caption) }; Button("뜻 선택") { meaning = entry.meaning }.font(.caption) }.padding(12).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 10))
            }
            TextField("뜻", text: $meaning, axis: .vertical).textFieldStyle(.roundedBorder)
            TextField("원문 예문 또는 메모", text: $context, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("단어 저장") { model.saveVocabulary(VocabularyEntry(courseID: model.courseID, word: word, meaning: meaning, context: context)); word = ""; meaning = ""; context = ""; dictionaryResults = [] }.buttonStyle(.borderedProminent).disabled(word.isEmpty || meaning.isEmpty)
            Divider()
            TextField("저장한 단어 검색", text: $search).textFieldStyle(.roundedBorder)
            ForEach(model.vocabulary.filter { $0.courseID == model.courseID && (search.isEmpty || $0.word.localizedCaseInsensitiveContains(search) || $0.meaning.localizedCaseInsensitiveContains(search)) }) { entry in
                VStack(alignment: .leading, spacing: 6) { Text(entry.word).font(.headline); Text(entry.meaning); if !entry.context.isEmpty { Text(entry.context).font(.caption).foregroundStyle(.secondary) }; Button("복습 카드로 만들기") { model.saveCard(Flashcard(courseID: model.courseID, front: entry.word, back: entry.meaning)) }.font(.caption) }.padding(.vertical, 8)
            }
        }
    }
    private var generation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("자료에서 학습으로").font(.title2.bold())
            Text("AI 튜터에서 자료를 선택하고 요약, 퀴즈, 플래시카드, 개념 설명을 요청하세요. 결과는 새 노트로 저장할 수 있습니다.").foregroundStyle(.secondary)
            ForEach([("요약 노트", "text.alignleft"), ("복습 퀴즈", "questionmark.circle"), ("핵심 개념", "lightbulb"), ("시험 예상 문제", "graduationcap")], id: \.0) { title, icon in
                Button { model.open(.chat) } label: { HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "arrow.up.right") }.padding(18).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
            }
        }
    }
    private func lookup() { do { dictionaryResults = try DictionaryService.lookup(word) } catch { model.error = error.localizedDescription } }
}
