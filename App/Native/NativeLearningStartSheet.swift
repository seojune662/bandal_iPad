import SwiftUI

struct NativeLearningStartSheet: View {
    @ObservedObject var store: NativeWorkspaceStore
    let kind: NativeLearningStartKind
    let source: NativeDocumentReference?
    var binding: NativeLearningBinding? = nil
    var packID: String? = nil
    let onOpen: (NativeLearningBinding) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var level = "intermediate"
    @State private var minutes = 4
    @State private var courseID = ""
    @State private var useMaterial = true
    @State private var useSelection = true
    @State private var sourceMode = "course"
    @State private var articles: [[String: Any]] = []
    @State private var selectedArticles: Set<String> = []
    @State private var wordIDs: [String] = []
    private var selectedText: String { source.flatMap { store.documentSelections[$0.id] } ?? "" }
    @State private var busy = false
    @State private var error: String?
    private var title: String { packID == "summary" ? "요약 만들기" : kind.title }
    private var courses: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }
    private var materialAvailable: Bool { source != nil && ["pdf", "note", "file"].contains(source!.kind) && source!.courseID == courseID }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(kind == .english ? kind.detail : "선택한 자료의 원문을 근거로 학습 자료를 만듭니다.").foregroundStyle(.secondary) }
                if kind == .english && packID == nil {
                    Section("학습 공간") {
                        TextField("학습 공간 이름", text: $name).accessibilityIdentifier("native-learning-create-name")
                        TextField("관심 주제", text: $topic).accessibilityIdentifier("native-learning-create-topic")
                        Picker("읽기 수준", selection: $level) { Text("입문").tag("beginner"); Text("중급").tag("intermediate"); Text("고급").tag("advanced") }
                        Picker("읽는 시간", selection: $minutes) { ForEach([3, 4, 5, 8], id: \.self) { Text("\($0)분").tag($0) } }
                    }
                    Section { Text("공간을 만든 뒤 기사 주소를 추가해 읽고, 원문에서 표현을 저장할 수 있어요.").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Section("학습할 자료") {
                        if !articles.isEmpty || !wordIDs.isEmpty {
                            Picker("원문", selection: $sourceMode) {
                                Text("과목 자료").tag("course")
                                if !articles.isEmpty { Text("보관한 글").tag("article") }
                                if !wordIDs.isEmpty { Text("모은 표현").tag("vocabulary") }
                            }
                        }
                        if sourceMode == "article" {
                            ForEach(Array(articles.enumerated()), id: \.offset) { _, article in
                                let id = article["id"] as? String ?? ""
                                Toggle(article["title"] as? String ?? "기사", isOn: Binding(get: { selectedArticles.contains(id) }, set: { if $0 { selectedArticles.insert(id) } else { selectedArticles.remove(id) } }))
                            }
                        } else if sourceMode == "vocabulary" { Text("모은 표현 \(wordIDs.count)개와 원문 예문을 사용합니다.") }
                        else {
                            Picker("과목", selection: $courseID) { Text("과목 선택").tag(""); ForEach(courses) { Text($0.name).tag($0.id) } }
                            if materialAvailable { Toggle("현재 자료 사용", isOn: $useMaterial); if useMaterial { Text(source?.title ?? "").font(.subheadline); if !selectedText.isEmpty { Toggle("선택한 글만 사용", isOn: $useSelection); if useSelection { Text(selectedText).font(.caption).lineLimit(5).foregroundStyle(.secondary) } } } }
                            Text(materialAvailable && useMaterial ? "현재 자료에 저장된 본문을 사용합니다." : "선택한 과목의 자료를 사용합니다.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section { Text("AI 연결과 기본 모델은 설정의 AI 항목을 따릅니다. 생성 상태와 결과는 학습 공간에 보관됩니다.").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { Section { NativeToolError(message: error) } }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }; ToolbarItem(placement: .confirmationAction) { Button { start() } label: { if busy { ProgressView() } else { Text(kind == .english && packID == nil ? "만들기" : "생성") } }.disabled(busy || invalid).accessibilityIdentifier("native-learning-create-confirm") } }
                .interactiveDismissDisabled(busy)
                .task { await loadSources() }
        }
    }
    private var invalid: Bool { kind == .english && packID == nil ? name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : sourceMode == "article" ? selectedArticles.isEmpty || selectedArticles.count > 20 : sourceMode == "vocabulary" ? wordIDs.isEmpty : courseID.isEmpty }
    private func loadSources() async {
        courseID = source?.courseID ?? (courses.contains { $0.id == store.selectedCourseID } ? store.selectedCourseID : nil) ?? courses.first?.id ?? ""
        guard let binding else { return }
        do {
            let project = try await store.invoke("learning:get", ["binding": binding.request]) as? [String: Any] ?? [:]
            if let linked = project["linkedCourseId"] as? String { courseID = linked }
            articles = project["articles"] as? [[String: Any]] ?? []
            selectedArticles = Set(articles.prefix(20).compactMap { $0["id"] as? String })
            wordIDs = (project["words"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if !articles.isEmpty { sourceMode = "article" } else if !wordIDs.isEmpty { sourceMode = "vocabulary" }
        } catch { self.error = error.localizedDescription }
    }
    private func start() {
        guard !busy, !invalid else { return }; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.flushDocuments()
                let result: Any
                if kind == .english && packID == nil {
                    result = try await store.invoke("learning:create", ["placement": "standalone", "name": name, "topic": topic, "purpose": "english-reading", "level": level, "readingMinutes": minutes, "readingSetupConfirmed": true])
                } else {
                    var input: [String: Any] = ["kind": "course", "sourceCourseId": courseID]
                    if sourceMode == "article" { input = ["kind": "article", "articleIds": selectedArticles.sorted()] }
                    else if sourceMode == "vocabulary" { input = ["kind": "vocabulary", "wordIds": wordIDs] }
                    else if materialAvailable && useMaterial, let source { input = ["kind": "material", "relPath": source.relativePath, "sourceCourseId": source.courseID]; if useSelection && !selectedText.isEmpty { input["selection"] = selectedText } }
                    var request: [String: Any] = ["courseId": sourceMode == "course" ? courseID : binding?.courseID ?? courseID, "packId": packID ?? (kind == .quiz ? "quiz" : "flashcards"), "source": input]
                    if let binding { request["binding"] = binding.request }
                    result = try await store.invoke("study:generate", request)
                }
                guard let row = result as? [String: Any], let rawBinding = row["binding"] else { throw DesktopRuntimeError("학습 공간을 열지 못했습니다.") }
                let created: NativeLearningBinding = try NativeToolJSON.decode(rawBinding)
                dismiss(); onOpen(created)
            } catch { self.error = error.localizedDescription }
        }
    }
}
