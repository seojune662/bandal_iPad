import SwiftUI

struct NativeLearningWorkspace: View {
    @ObservedObject var store: NativeWorkspaceStore
    let binding: NativeLearningBinding
    let onOpenDocument: (NativeDocumentReference) -> Void
    let onOpenBrowser: (String) -> Void
    @StateObject private var model: NativeLearningWorkspaceModel
    @State private var tab = "home"
    @State private var articleURL = ""
    @State private var showingAdd = false
    @State private var generating: NativeLearningStartKind?
    init(store: NativeWorkspaceStore, binding: NativeLearningBinding, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenBrowser: @escaping (String) -> Void) {
        self.store = store; self.binding = binding; self.onOpenDocument = onOpenDocument; self.onOpenBrowser = onOpenBrowser
        _model = StateObject(wrappedValue: NativeLearningWorkspaceModel(store: store, binding: binding))
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error { NativeToolError(message: error).padding(12) }
            if model.loading { ProgressView("학습 공간 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let article = model.article { NativeLearningArticleView(model: model, article: article, onOpenBrowser: onOpenBrowser) }
            else if let artifact = model.artifact { NativeLearningArtifactView(model: model, artifact: artifact, onOpenSource: openSource) }
            else { overview }
        }.background(NativeDesktopTheme.bgApp).accessibilityElement(children: .contain).accessibilityIdentifier("native-learning-workspace")
            .task { await model.start() }.onDisappear { Task { await model.close() } }.onReceive(store.events) { model.receive($0) }
            .alert("기사 주소", isPresented: $showingAdd) { TextField("https://…", text: $articleURL).textInputAutocapitalization(.never).keyboardType(.URL); Button("취소", role: .cancel) { }; Button("추가") { addArticle() } } message: { Text("기사의 원문을 학습 공간에 보관합니다.") }
            .sheet(item: $generating) { kind in NativeLearningStartSheet(store: store, kind: kind, source: nil, binding: binding, onOpen: { _ in Task { await model.reload() } }) }
    }
    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                if model.article != nil || model.artifact != nil { NativeChromeButton(title: "학습 공간으로", symbol: "chevron.left") { model.clearDetail() } }
                VStack(alignment: .leading, spacing: 3) { Text(model.name).font(NativeDesktopTheme.font(18, weight: .semibold)); Text(model.snapshot["topic"] as? String ?? "").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                Menu { Button("기사 주소 추가", systemImage: "link") { showingAdd = true }; Button("퀴즈 만들기") { generating = .quiz }; Button("카드 만들기") { generating = .flashcards } } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityIdentifier("native-learning-add")
            }
            if model.article == nil && model.artifact == nil { Picker("학습 보기", selection: $tab) { Text("홈").tag("home"); Text("글").tag("articles"); Text("표현").tag("words"); Text("복습").tag("review") }.pickerStyle(.segmented) }
        }.padding(14).background(NativeDesktopTheme.surface).disabled(model.frozen)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if tab == "home" { runs; statistics }
                if tab == "home" || tab == "articles" { articles }
                if tab == "home" || tab == "review" { artifacts }
                if tab == "words" { words }
            }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.disabled(model.busy || model.frozen)
    }
    private var statistics: some View {
        HStack(spacing: 16) { stat("읽은 글", model.rows("articles").filter { $0["status"] as? String == "completed" }.count); stat("모은 표현", model.rows("words").count); stat("복습 카드", model.rows("cards").count) }
    }
    private func stat(_ title: String, _ count: Int) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary); Text("\(count)").font(NativeDesktopTheme.font(24, weight: .semibold)) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10)) }
    private var runs: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.rows("runs").filter { $0["dismissedAt"] as? String == nil }.enumerated()), id: \.offset) { _, run in
                let status = run["status"] as? String ?? ""
                HStack { if ["queued", "running", "validating"].contains(status) { ProgressView() }; VStack(alignment: .leading) { Text(run["message"] as? String ?? status); if let error = run["error"] as? String { Text(error).font(.caption).foregroundStyle(.red) } }; Spacer(); Button(["queued", "running", "validating"].contains(status) ? "중지" : "닫기") { Task { _ = await model.mutate(["queued", "running", "validating"].contains(status) ? "learning:runCancel" : "learning:dismissRun", ["runId": run["id"] ?? ""]) } } }.font(NativeDesktopTheme.font(12)).padding(12).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var articles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("영어 이어읽기").font(.headline); Spacer(); Button("주소 추가", systemImage: "link") { showingAdd = true }.accessibilityIdentifier("native-learning-add-article") }
            if model.rows("articles").isEmpty { Text("읽고 싶은 기사의 주소를 추가해 보세요.").foregroundStyle(.secondary) }
            ForEach(Array(model.rows("articles").enumerated()), id: \.offset) { _, row in
                Button { Task { await model.openArticle(row["id"] as? String ?? "") } } label: { HStack { VStack(alignment: .leading, spacing: 6) { Text(row["title"] as? String ?? "기사"); Text(row["status"] as? String == "completed" ? "읽기 완료" : "이어서 읽기").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.padding(14).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
            }
        }
    }
    private var artifacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("학습 자료와 복습").font(.headline); Spacer(); Menu("만들기") { Button("퀴즈 만들기") { generating = .quiz }; Button("카드 만들기") { generating = .flashcards } } }
            if model.rows("artifacts").isEmpty { Text("퀴즈나 카드를 만들면 원문과 함께 여기에 보관됩니다.").foregroundStyle(.secondary) }
            ForEach(Array(model.rows("artifacts").enumerated()), id: \.offset) { _, row in
                Button { Task { await model.openArtifact(row["id"] as? String ?? "") } } label: { HStack { Image(systemName: row["kind"] as? String == "quiz" ? "questionmark.square" : row["kind"] as? String == "cards" ? "rectangle.on.rectangle" : "text.alignleft"); Text(row["title"] as? String ?? "학습 자료"); Spacer(); Image(systemName: "chevron.right") }.padding(14).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
            }
        }
    }
    private var words: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("모은 표현").font(.headline)
            if model.rows("words").isEmpty { Text("글의 문단에서 표현 저장을 눌러 원문과 함께 모아 보세요.").foregroundStyle(.secondary) }
            ForEach(Array(model.rows("words").enumerated()), id: \.offset) { _, word in NativeLearningWordRow(model: model, word: word) }
        }
    }
    private func addArticle() { let url = articleURL.trimmingCharacters(in: .whitespacesAndNewlines); Task { if await model.mutate("learning:addArticle", ["url": url]) { articleURL = ""; tab = "articles" } } }
    private func openSource(_ source: [String: Any]) {
        if source["kind"] as? String == "article", let id = source["articleId"] as? String { Task { await model.openArticle(id) }; return }
        Task {
            do {
                let value = try await store.invoke("learning:resolveSource", ["binding": binding.request, "sourceRef": source]) as? [String: Any] ?? [:]
                guard value["missing"] as? Bool != true, let path = value["relPath"] as? String else { throw DesktopRuntimeError("원문 자료를 찾을 수 없습니다.") }
                let course = value["sourceCourseId"] as? String ?? binding.courseID
                onOpenDocument(.init(courseID: course, relativePath: path, title: (path as NSString).lastPathComponent, kind: NativeSidebarDescriptor.materialKind(path)))
                if let page = source["page"] { store.events.send(.init(channel: "nativeWorkspace:goToPage", payload: ["courseId": course, "relPath": path, "page": page])) }
            } catch { model.error = error.localizedDescription }
        }
    }
}
