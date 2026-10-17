import SwiftUI

struct NativeLearningArtifactView: View {
    @ObservedObject var model: NativeLearningWorkspaceModel
    let artifact: [String: Any]
    let onOpenSource: ([String: Any]) -> Void
    @State private var revealed: Set<String> = []
    @State private var rated: Set<String> = []
    private var kind: String { artifact["kind"] as? String ?? "" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(artifact["title"] as? String ?? "학습 자료").font(NativeDesktopTheme.font(26, weight: .semibold))
                if kind == "summary" { Text(LocalizedStringKey(artifact["markdown"] as? String ?? "")).textSelection(.enabled).lineSpacing(5) }
                else if kind == "cards" { cards }
                else if kind == "quiz" { quiz }
                let refs = artifact["sourceRefs"] as? [[String: Any]] ?? []
                if !refs.isEmpty {
                    Divider(); Text("원문 근거").font(.headline)
                    ForEach(Array(refs.enumerated()), id: \.offset) { index, source in
                        Button { onOpenSource(source) } label: { VStack(alignment: .leading, spacing: 6) { Label("원문 \(index + 1)", systemImage: "arrow.up.right.square"); Text(source["quote"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(4) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    }
                }
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.disabled(model.busy || model.frozen)
            .onChange(of: artifact["id"] as? String) { _, _ in revealed = []; rated = [] }
    }
    private var cards: some View {
        VStack(spacing: 16) {
            ForEach(Array((artifact["cards"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, card in
                let id = card["id"] as? String ?? ""
                VStack(alignment: .leading, spacing: 16) {
                    Text(card["front"] as? String ?? "").font(.title3).textSelection(.enabled)
                    if revealed.contains(id) {
                        Divider(); Text(card["back"] as? String ?? "").textSelection(.enabled)
                        if rated.contains(id) { Label("복습을 저장했어요", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                        else { HStack { rating("다시", "again", id); rating("어려워요", "hard", id); rating("알겠어요", "good", id) }.buttonStyle(.bordered) }
                    } else { Button("정답 보기") { revealed.insert(id) }.buttonStyle(.bordered) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func rating(_ title: String, _ value: String, _ id: String) -> some View {
        Button(title) { let reviewID = UUID().uuidString.lowercased(); Task { if await model.mutate("learning:reviewCard", ["cardId": id, "rating": value, "reviewId": reviewID]) { rated.insert(id) } } }
    }
    private var quiz: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(model.completed ? "풀이 완료" : model.saved ? "답안 저장됨" : "답안 저장 중…").font(.caption).foregroundStyle(.secondary); Spacer(); if model.completed { Button("다시 풀기") { model.retryQuiz() } } }
            ForEach(Array((artifact["questions"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { index, question in NativeLearningQuizQuestion(model: model, question: question, number: index + 1) }
            if model.completed { Text("점수 \((model.attempt?["score"] as? NSNumber)?.intValue ?? 0) / \((model.attempt?["total"] as? NSNumber)?.intValue ?? 0)").font(.headline) }
            else { Button("풀이 마치기", systemImage: "checkmark.circle") { Task { await model.finishQuiz() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("native-learning-finish-quiz") }
        }
    }
}

private struct NativeLearningQuizQuestion: View {
    @ObservedObject var model: NativeLearningWorkspaceModel
    let question: [String: Any]
    let number: Int
    @State private var showAnswer = false
    private var id: String { question["id"] as? String ?? "" }
    private var type: String { question["type"] as? String ?? "" }
    private var answer: Binding<String> { Binding(get: { model.answers[id] ?? "" }, set: { model.answer(id, text: $0) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(number). " + (question["prompt"] as? String ?? "")).font(.headline).textSelection(.enabled)
            if type == "choice" { choices }
            else { TextField("답을 입력하세요", text: answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...8).disabled(model.completed).accessibilityIdentifier("native-learning-answer-" + id) }
            if model.completed || (type == "short-answer" && showAnswer) { solution }
            else if type == "short-answer" { Button("모범 답안과 비교") { showAnswer = true }.disabled((model.answers[id] ?? "").isEmpty) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((question["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in
                let optionID = option["id"] as? String ?? ""
                Button { model.answer(id, text: optionID) } label: { HStack { Image(systemName: model.answers[id] == optionID ? "largecircle.fill.circle" : "circle"); Text(option["text"] as? String ?? ""); Spacer() }.frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.completed)
            }
        }
    }
    private var solution: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            let raw = question["answer"] as? String ?? ""
            let solution = (question["options"] as? [[String: String]] ?? []).first { $0["id"] == raw }?["text"] ?? raw
            Text("정답: " + solution).fontWeight(.medium)
            Text(question["explanation"] as? String ?? "").font(.subheadline).foregroundStyle(.secondary)
            if type == "short-answer" && !model.completed {
                HStack { Button { model.answer(id, text: model.answers[id] ?? "", check: false) } label: { Label("더 공부할게요", systemImage: model.selfChecks[id] == false ? "checkmark.circle.fill" : "circle") }; Button { model.answer(id, text: model.answers[id] ?? "", check: true) } label: { Label("맞았어요", systemImage: model.selfChecks[id] == true ? "checkmark.circle.fill" : "circle") } }.buttonStyle(.bordered)
            }
        }
    }
}
