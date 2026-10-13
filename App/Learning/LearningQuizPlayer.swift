import SwiftUI

struct LearningQuizPlayer: View {
    @EnvironmentObject private var model: AppModel
    let quiz: LearningQuiz
    let history: [LearningQuizAttempt]
    let onBack: () -> Void
    let onSave: (LearningQuizAttempt) -> Void
    @State private var attempt: LearningQuizAttempt?
    @State private var index = 0
    @State private var response = ""
    @State private var submitted = false
    @State private var saveTask: Task<Void, Never>?
    private var question: LearningQuizQuestion { quiz.questions[min(index, max(0, quiz.questions.count - 1))] }
    private var answer: LearningQuizAnswer? { attempt?.answers[question.id] }
    private var gradedCount: Int { attempt?.answers.values.filter { $0.correct != nil }.count ?? 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("목록", systemImage: "chevron.left") { saveDraft(); onBack() }.frame(minHeight: 44)
                Spacer()
                Text(quiz.title).font(.headline).lineLimit(1)
                Spacer()
                if attempt != nil { Button("풀이 개요") { saveDraft(); attempt = nil }.frame(minHeight: 44) }
            }.padding(.horizontal, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let attempt {
                        if attempt.completedAt != nil { completion(attempt) }
                        else { exercise }
                    } else { overview }
                }.padding(24).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
        }.onDisappear { saveTask?.cancel(); saveDraft() }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(quiz.title).font(.title2.bold())
            Text("\(quiz.questions.count)문제 · 서술형 문항은 모범 답안을 보며 직접 채점합니다.").foregroundStyle(.secondary)
            if let unfinished = history.first(where: { $0.completedAt == nil }) {
                Button("이전 풀이 이어서 하기", systemImage: "play.fill") { resume(unfinished) }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            Button("새로 풀기", systemImage: "arrow.clockwise") { start() }.buttonStyle(.bordered).controlSize(.large)
            if let materialID = quiz.sourceMaterialID, let material = model.material(materialID) {
                Text("출처 자료: \(material.title)").font(.caption).foregroundStyle(.secondary)
            }
            if !history.isEmpty {
                Divider(); Text("풀이 이력").font(.headline)
                ForEach(history) { item in
                    Button { resume(item) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(item.startedAt.formatted(date: .abbreviated, time: .shortened)); Text(item.completedAt == nil ? "진행 중 · \(item.answers.values.filter { $0.correct != nil }.count)/\(quiz.questions.count)" : "완료 · \(item.score)/\(quiz.questions.count)").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right")
                        }.padding(14).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var exercise: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("\(index + 1) / \(quiz.questions.count)").font(.headline).monospacedDigit(); Spacer(); Text(question.type.title).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6).background(BandalTheme.background, in: Capsule()) }
            ProgressView(value: Double(gradedCount), total: Double(quiz.questions.count)).tint(BandalTheme.accent)
            Text(question.prompt).font(.title3.weight(.medium)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if question.type == .choice {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                    Button { response = option; scheduleDraft() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: response == option ? "largecircle.fill.circle" : "circle").font(.title3)
                            Text("\(optionIndex + 1). \(option)").frame(maxWidth: .infinity, alignment: .leading)
                            if submitted && option == question.answer { Image(systemName: "checkmark.circle.fill").foregroundStyle(BandalTheme.accent) }
                        }.padding(16).background(response == option ? BandalTheme.accent.opacity(0.12) : BandalTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(submitted)
                }
            } else if question.type == .cloze {
                TextField("빈칸에 들어갈 답", text: $response, axis: .vertical).textFieldStyle(.roundedBorder).font(.title3).disabled(submitted).onChange(of: response) { _, _ in scheduleDraft() }
            } else {
                Text("나의 설명").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $response).frame(minHeight: 170).padding(10).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.25))).disabled(submitted).onChange(of: response) { _, _ in scheduleDraft() }
            }
            if submitted { feedback }
            else { Button("답 확인", action: submit).buttonStyle(.borderedProminent).controlSize(.large).disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Divider()
            HStack {
                Button("이전", systemImage: "chevron.left") { move(-1) }.disabled(index == 0)
                Spacer()
                Button(index + 1 == quiz.questions.count ? "결과 보기" : "다음", systemImage: index + 1 == quiz.questions.count ? "checkmark" : "chevron.right") {
                    if index + 1 == quiz.questions.count { finish() } else { move(1) }
                }.buttonStyle(.borderedProminent).disabled(answer?.correct == nil)
            }.controlSize(.large)
        }
    }
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let correct = answer?.correct { Label(correct ? "맞았어요" : "다시 살펴보세요", systemImage: correct ? "checkmark.circle" : "arrow.trianglehead.clockwise").font(.headline).foregroundStyle(correct ? BandalTheme.accent : .orange) }
            Text(question.type == .shortAnswer ? "모범 답안" : "정답").font(.caption.bold()).foregroundStyle(.secondary)
            Text(question.answer).textSelection(.enabled)
            if !question.explanation.isEmpty { Text(question.explanation).foregroundStyle(.secondary).textSelection(.enabled) }
            if question.type == .shortAnswer && answer?.correct == nil {
                Text("핵심 내용이 내 답에 포함되었는지 확인해 주세요.").font(.subheadline)
                HStack { Button("더 복습할래요") { grade(false) }.buttonStyle(.bordered); Button("맞았어요") { grade(true) }.buttonStyle(.borderedProminent) }.controlSize(.large)
            }
            if answer?.correct == false { Button("복습 카드로 저장", systemImage: "rectangle.on.rectangle") { model.saveCard(Flashcard(courseID: quiz.courseID, front: question.prompt, back: question.answer + (question.explanation.isEmpty ? "" : "\n\n" + question.explanation))); model.notice = "복습 카드에 저장했습니다." }.font(.subheadline) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 14))
    }
    private func completion(_ result: LearningQuizAttempt) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(BandalTheme.accent)
            Text("이번 퀴즈를 마쳤어요").font(.title2.bold())
            Text("\(result.score) / \(quiz.questions.count)").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("서술형 결과에는 나의 자기 점검이 반영됩니다.").font(.caption).foregroundStyle(.secondary)
            Button("한 번 더 풀기", action: start).buttonStyle(.borderedProminent).controlSize(.large)
            ForEach(quiz.questions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Label(item.prompt, systemImage: result.answers[item.id]?.correct == true ? "checkmark.circle" : "xmark.circle").font(.headline)
                    Text("나의 답: \(result.answers[item.id]?.response ?? "미응답")").foregroundStyle(.secondary)
                    Text("정답: \(item.answer)")
                    if !item.explanation.isEmpty { Text(item.explanation).font(.subheadline).foregroundStyle(.secondary) }
                }.textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func start() {
        let value = LearningQuizAttempt(attemptID: UUID().uuidString, courseID: quiz.courseID, quizID: quiz.id, answers: [:], currentIndex: 0, startedAt: Date(), completedAt: nil)
        attempt = value; index = 0; response = ""; submitted = false; onSave(value)
    }
    private func resume(_ value: LearningQuizAttempt) {
        attempt = value; index = min(max(0, value.currentIndex), quiz.questions.count - 1); restoreAnswer()
    }
    private func restoreAnswer() { response = answer?.response ?? ""; submitted = answer?.submitted ?? false }
    private func scheduleDraft() {
        guard !submitted else { return }
        saveTask?.cancel(); saveTask = Task { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { saveDraft() } }
    }
    private func saveDraft() {
        saveTask?.cancel()
        guard !submitted, var current = attempt, current.completedAt == nil, current.answers[question.id]?.response != response else { return }
        current.answers[question.id] = LearningQuizAnswer(response: response, correct: nil, selfChecked: false)
        commit(current)
    }
    private func submit() {
        saveTask?.cancel(); guard var current = attempt else { return }
        submitted = true
        current.answers[question.id] = LearningQuizAnswer(response: response, correct: question.type == .shortAnswer ? nil : question.matches(response), selfChecked: false, submitted: true)
        commit(current)
    }
    private func grade(_ correct: Bool) {
        guard var current = attempt else { return }
        current.answers[question.id] = LearningQuizAnswer(response: response, correct: correct, selfChecked: true, submitted: true); commit(current)
    }
    private func move(_ offset: Int) {
        saveDraft(); index = min(max(0, index + offset), quiz.questions.count - 1)
        if let current = attempt { commit(current) }; restoreAnswer()
    }
    private func finish() {
        guard var current = attempt else { return }
        if let unanswered = quiz.questions.firstIndex(where: { current.answers[$0.id]?.correct == nil }) { index = unanswered; restoreAnswer(); return }
        current.completedAt = Date(); commit(current)
    }
    private func commit(_ value: LearningQuizAttempt) {
        var event = value; event.id = UUID().uuidString; event.createdAt = Date(); event.eventTime = Date().timeIntervalSince1970; event.currentIndex = index
        attempt = event; onSave(event)
    }
}

struct LearningQuizComposer: View {
    @Environment(\.dismiss) private var dismiss
    let courseID: String
    let onSave: (LearningQuiz) -> Void
    @State private var mode = 0
    @State private var title = ""
    @State private var questions: [LearningQuizQuestion] = []
    @State private var type = LearningQuestionType.choice
    @State private var prompt = ""
    @State private var options = ""
    @State private var answer = ""
    @State private var alternatives = ""
    @State private var explanation = ""
    @State private var editID: String?
    @State private var json = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("입력 방법", selection: $mode) { Text("직접 입력").tag(0); Text("JSON 가져오기").tag(1) }.pickerStyle(.segmented)
                if mode == 0 {
                    Section("퀴즈 제목") { TextField("제목", text: $title) }
                    if !questions.isEmpty {
                        Section("추가한 문제 · \(questions.count)개") {
                            ForEach(questions) { item in Button { edit(item) } label: { VStack(alignment: .leading, spacing: 4) { Text(item.prompt); Text(item.type.title).font(.caption).foregroundStyle(.secondary) } } }.onDelete { questions.remove(atOffsets: $0) }
                        }
                    }
                    Section(editID == nil ? "새 문제" : "문제 수정") {
                        Picker("유형", selection: $type) { ForEach(LearningQuestionType.allCases) { Text($0.title).tag($0) } }
                        TextField("질문 (빈칸은 ___로 표시)", text: $prompt, axis: .vertical).lineLimit(2...8)
                        if type == .choice {
                            TextField("보기마다 줄을 바꿔 입력하세요", text: $options, axis: .vertical).lineLimit(3...8)
                            Picker("정답", selection: $answer) { Text("선택").tag(""); ForEach(optionLines, id: \.self) { Text($0).tag($0) } }
                        } else {
                            TextField(type == .shortAnswer ? "모범 답안" : "정답", text: $answer, axis: .vertical).lineLimit(2...6)
                            if type == .cloze { TextField("추가 인정 답안 (줄바꿈으로 구분)", text: $alternatives, axis: .vertical) }
                        }
                        TextField("해설 (선택)", text: $explanation, axis: .vertical).lineLimit(2...6)
                        Button(editID == nil ? "문제 추가" : "수정 반영", action: addQuestion).disabled(prompt.isEmpty || answer.isEmpty)
                    }
                } else {
                    Section("퀴즈 JSON") {
                        TextEditor(text: $json).font(.system(.footnote, design: .monospaced)).frame(minHeight: 300)
                        Text("형식: title, questions 배열. 각 문제에 type(choice, cloze, short-answer), prompt, answer가 필요합니다. 객관식은 options 배열, 해설은 explanation에 입력합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("퀴즈 만들기").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("퀴즈 저장", action: save).disabled(mode == 0 ? title.isEmpty || questions.isEmpty : json.isEmpty) }
            }
        }
    }
    private var optionLines: [String] { var seen = Set<String>(); return options.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted } }
    private func addQuestion() {
        let item = LearningQuizQuestion(id: editID ?? UUID().uuidString, type: type, prompt: prompt, options: type == .choice ? optionLines : [], answer: answer, acceptedAnswers: alternatives.components(separatedBy: .newlines).filter { !$0.isEmpty }, explanation: explanation)
        do {
            try LearningQuiz(courseID: courseID, title: "검증", questions: [item]).validate()
            if let index = questions.firstIndex(where: { $0.id == editID }) { questions[index] = item } else { questions.append(item) }
            prompt = ""; options = ""; answer = ""; alternatives = ""; explanation = ""; editID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func edit(_ item: LearningQuizQuestion) { editID = item.id; type = item.type; prompt = item.prompt; options = item.options.joined(separator: "\n"); answer = item.answer; alternatives = item.acceptedAnswers.joined(separator: "\n"); explanation = item.explanation }
    private func save() {
        do {
            guard mode == 1 || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "작성 중인 문제를 먼저 추가하거나 수정을 반영해 주세요."; return }
            let quiz = try mode == 0 ? LearningQuiz(courseID: courseID, title: title, questions: questions) : LearningQuiz.fromJSON(Data(json.utf8), courseID: courseID)
            try quiz.validate(); onSave(quiz); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
