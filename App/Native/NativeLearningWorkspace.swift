import SwiftUI

struct NativeLearningWorkspace: View {
    @ObservedObject var store: NativeWorkspaceStore
    let binding: NativeLearningBinding
    let onOpenDocument: (NativeDocumentReference) -> Void
    let onOpenBrowser: (String) -> Void
    @StateObject private var model: NativeLearningWorkspaceModel
    @Environment(\.nativeEditorVisible) private var editorVisible
    @State private var sourceTask: Task<Void, Never>?
    @State private var tab = "home"
    @State private var articleURL = ""
    @State private var showingAdd = false
    init(store: NativeWorkspaceStore, binding: NativeLearningBinding, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenBrowser: @escaping (String) -> Void, initialTab: String = "home") {
        _tab = State(initialValue: initialTab)
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
            .task(id: binding) {
                await model.rebind(binding); guard model.binding == binding else { return }
                await model.start()
                if tab == "words" && model.rows("words").isEmpty { tab = "history" }
            }.onDisappear { sourceTask?.cancel(); Task { await model.close() } }
            .onChange(of: editorVisible) { _, visible in if !visible { sourceTask?.cancel() } }.onReceive(store.events) { model.receive($0) }
            .alert("기사 주소", isPresented: $showingAdd) { TextField("https://…", text: $articleURL).textInputAutocapitalization(.never).keyboardType(.URL); Button("취소", role: .cancel) { }; Button("추가") { addArticle() } } message: { Text("기사의 원문을 학습 공간에 보관합니다.") }
    }
    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                if model.article != nil || model.artifact != nil { NativeChromeButton(title: "프로젝트로", symbol: "chevron.left") { model.clearDetail() } }
                VStack(alignment: .leading, spacing: 3) { Text(model.name).font(NativeDesktopTheme.font(18, weight: .semibold)); Text(model.snapshot["topic"] as? String ?? "").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                Menu { Button("기사 주소 추가", systemImage: "link") { showingAdd = true }; Button("AI로 만들기", systemImage: "sparkles") { store.assistantDocumentIDs.insert(binding.id) } } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityIdentifier("native-learning-add")
            }
            if model.article == nil && model.artifact == nil { Picker("학습 보기", selection: $tab) { Text("홈").tag("home"); Text("글").tag("articles"); Text("표현").tag("words"); Text("복습").tag("review"); Text("기록").tag("history") }.pickerStyle(.segmented) }
        }.padding(14).background(NativeDesktopTheme.surface).disabled(model.frozen)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if tab == "home" { runs; statistics }
                if tab == "home" || tab == "articles" { articles }
                if tab == "home" || tab == "review" { artifacts }
                if tab == "words" { words }
                if tab == "history" { history }
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
                Button { openResult(row, kind: .article) } label: { HStack { VStack(alignment: .leading, spacing: 6) { Text(row["title"] as? String ?? "기사"); Text(row["status"] as? String == "completed" ? "읽기 완료" : "이어서 읽기").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.padding(14).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
            }
        }
    }
    private var artifacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("학습 자료와 복습").font(.headline); Spacer(); Menu("만들기") { Button("AI로 만들기", systemImage: "sparkles") { store.assistantDocumentIDs.insert(binding.id) } } }
            if model.rows("artifacts").isEmpty { Text("퀴즈나 카드를 만들면 원문과 함께 여기에 보관됩니다.").foregroundStyle(.secondary) }
            ForEach(Array(model.rows("artifacts").enumerated()), id: \.offset) { _, row in
                Button { openResult(row, kind: .artifact) } label: { HStack { Image(systemName: row["kind"] as? String == "quiz" ? "questionmark.square" : row["kind"] as? String == "cards" ? "rectangle.on.rectangle" : "text.alignleft"); Text(row["title"] as? String ?? "학습 자료"); Spacer(); Image(systemName: "chevron.right") }.padding(14).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
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
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("학습 기록").font(.headline)
            if model.rows("history").isEmpty { Text("아직 저장된 기록이 없습니다.").foregroundStyle(.secondary) }
            ForEach(Array(model.rows("history").reversed().enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row["summary"] as? String ?? "학습 기록")
                    Text(row["createdAt"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
    private func openResult(_ row: [String: Any], kind: NativeLearningDocumentTarget.Kind) {
        guard let id = row["id"] as? String, let projectID = model.snapshot["projectId"] as? String else { return }
        onOpenDocument(NativeLearningDocumentTarget(projectID: projectID, binding: binding, kind: kind, entityID: id).document(title: row["title"] as? String ?? "학습 자료"))
    }
    private func addArticle() { let url = articleURL.trimmingCharacters(in: .whitespacesAndNewlines); Task { if await model.mutate("learning:addArticle", ["url": url]) { articleURL = ""; tab = "articles" } } }
    private func openSource(_ source: [String: Any]) {
        if source["kind"] as? String == "article", let id = source["articleId"] as? String { openResult(model.rows("articles").first { $0["id"] as? String == id } ?? ["id": id], kind: .article); return }
        sourceTask?.cancel()
        sourceTask = Task {
            do {
                let value = try await store.invoke("learning:resolveSource", ["binding": binding.request, "sourceRef": source]) as? [String: Any] ?? [:]
                try Task.checkCancellation()
                guard editorVisible else { return }
                guard value["missing"] as? Bool != true, let path = value["relPath"] as? String else { throw DesktopRuntimeError("원문 자료를 찾을 수 없습니다.") }
                let course = value["sourceCourseId"] as? String ?? binding.courseID
                var payload: [String: Any] = ["courseId": course, "relPath": path, "kind": NativeSidebarDescriptor.materialKind(path)]
                payload["page"] = source["page"]
                store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: payload))
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
    }
}

/// Each article or generated result owns its detail model and answer state.
/// Opening another quiz in a split never replaces the first quiz's answers.
struct NativeLearningDocumentWorkspace: View {
    @ObservedObject var store: NativeWorkspaceStore
    let document: NativeDocumentReference
    let onOpenDocument: (NativeDocumentReference) -> Void
    let onOpenBrowser: (String) -> Void
    @StateObject private var model: NativeLearningWorkspaceModel
    @Environment(\.nativeEditorVisible) private var editorVisible
    @State private var sourceTask: Task<Void, Never>?
    init(store: NativeWorkspaceStore, document: NativeDocumentReference, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenBrowser: @escaping (String) -> Void) {
        self.store = store; self.document = document; self.onOpenDocument = onOpenDocument; self.onOpenBrowser = onOpenBrowser
        let binding = document.learningTarget?.binding ?? NativeLearningBinding(courseID: document.courseID, rootRelPath: document.relativePath)
        _model = StateObject(wrappedValue: NativeLearningWorkspaceModel(store: store, binding: binding, detailID: document.id))
    }
    var body: some View {
        VStack(spacing: 0) {
            if let target = document.learningTarget, target.kind == .overview {
                NativeLearningWorkspace(store: store, binding: target.binding, onOpenDocument: onOpenDocument, onOpenBrowser: onOpenBrowser, initialTab: "words")
            } else {
            if let error = model.error { NativeToolError(message: error).padding(12) }
            if model.loading { ProgressView("자료 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let article = model.article { NativeLearningArticleView(model: model, article: article, onOpenBrowser: onOpenBrowser) }
            else if let artifact = model.artifact { NativeLearningArtifactView(model: model, artifact: artifact, onOpenSource: openSource) }
            else if model.error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.background(NativeDesktopTheme.bgApp).accessibilityElement(children: .contain).accessibilityIdentifier("native-learning-document")
            .task(id: document.learningTarget) {
                guard document.learningTarget?.kind != .overview else { return }
                if let binding = document.learningTarget?.binding {
                    await model.rebind(binding)
                    guard model.binding == binding else { return }
                }
                await model.start()
                guard let target = document.learningTarget else { return }
                if target.kind == .article { await model.openArticle(target.entityID) }
                else { await model.openArtifact(target.entityID) }
            }
            .onReceive(store.events) { if document.learningTarget?.kind != .overview { model.receive($0) } }
            .onDisappear { sourceTask?.cancel(); Task { await model.close() } }
            .onChange(of: editorVisible) { _, visible in if !visible { sourceTask?.cancel() } }
    }
    private func openSource(_ source: [String: Any]) {
        if source["kind"] as? String == "article", let id = source["articleId"] as? String {
            let target = NativeLearningDocumentTarget(projectID: document.learningTarget?.projectID ?? model.binding.id, binding: model.binding, kind: .article, entityID: id)
            let name = model.rows("articles").first { $0["id"] as? String == id }?["title"] as? String ?? "읽기 자료"
            onOpenDocument(target.document(title: name)); return
        }
        if let url = source["url"] as? String { onOpenBrowser(url); return }
        sourceTask?.cancel()
        sourceTask = Task {
            do {
                var reference = source
                if reference["kind"] as? String == "annotation" { reference["kind"] = "material"; reference["pathScope"] = "course"; reference.removeValue(forKey: "contentHash") }
                let value = try await store.invoke("learning:resolveSource", ["binding": model.binding.request, "sourceRef": reference]) as? [String: Any] ?? [:]
                try Task.checkCancellation()
                guard editorVisible else { return }
                guard value["missing"] as? Bool != true, let path = value["relPath"] as? String else { throw DesktopRuntimeError("원문 자료를 찾을 수 없습니다.") }
                let owner = value["sourceCourseId"] as? String ?? model.binding.courseID
                var payload: [String: Any] = ["courseId": owner, "relPath": path, "kind": NativeSidebarDescriptor.materialKind(path)]
                payload["page"] = source["page"]
                store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: payload))
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
    }
}
