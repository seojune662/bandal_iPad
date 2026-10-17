import SwiftUI

struct NativeLearningHome: View {
    @ObservedObject var store: NativeWorkspaceStore
    var courseID: String? = nil
    let onOpen: (NativeLearningBinding) -> Void
    @StateObject private var model = NativeLearningCatalog()
    @State private var creating: NativeLearningStartKind?
    @State private var showDeleted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("학습").font(NativeDesktopTheme.font(28, weight: .semibold))
                    Text("읽고, 풀고, 기억하는 나의 학습을 여기서 이어가세요.").foregroundStyle(NativeDesktopTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("새 학습").font(NativeDesktopTheme.font(18, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { startActions }.frame(minWidth: 680)
                        VStack(spacing: 8) { startActions }
                    }
                }
                if model.loading { ProgressView("학습 기록 불러오는 중…") }
                if let error = model.error { NativeToolError(message: error); Button("다시 불러오기") { Task { await model.reload(store, courseID: courseID) } } }
                let live = model.projects.filter { $0.deletedAt == nil }
                if !live.isEmpty {
                    Text("이어서 학습하기").font(NativeDesktopTheme.font(18, weight: .semibold))
                    ForEach(Array(live.prefix(3))) { project in NativeLearningProjectRow(project: project, store: store, onOpen: onOpen) }
                }
                let due = live.filter { $0.dueCardCount > 0 }
                if !due.isEmpty {
                    Text("오늘 복습할 카드").font(NativeDesktopTheme.font(18, weight: .semibold))
                    ForEach(due) { project in Button { onOpen(project.binding) } label: { HStack { Text(project.displayName(courses: store.courses)); Spacer(); Text("\(project.dueCardCount)개 복습하기"); Image(systemName: "chevron.right") }.padding(14).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("나의 학습 공간").font(NativeDesktopTheme.font(18, weight: .semibold))
                    NativeLearningGroups(projects: live, store: store, onOpen: onOpen)
                }
                Button("삭제한 학습", systemImage: "trash") { showDeleted.toggle() }.font(NativeDesktopTheme.font(12)).accessibilityIdentifier("native-learning-show-deleted")
                if showDeleted {
                    Text("목록에서 삭제한 공간입니다. 파일과 기록은 보존되어 있어요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted)
                    ForEach(model.projects.filter { $0.deletedAt != nil }) { project in
                        HStack { Text(project.name); Spacer(); Button("복원") { Task { do { _ = try await store.invoke("learning:restore", ["binding": project.binding.request]); await model.reload(store, courseID: courseID) } catch { store.errorMessage = error.localizedDescription } } } }
                    }
                }
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(NativeDesktopTheme.bgApp).accessibilityElement(children: .contain).accessibilityIdentifier("native-learning-home")
            .task { await model.reload(store, courseID: courseID) }
            .onReceive(store.events) { event in if ["learning:changed", "courses:changed"].contains(event.channel) { Task { await model.reload(store, courseID: courseID) } } }
            .sheet(item: $creating) { kind in NativeLearningStartSheet(store: store, kind: kind, source: nil, onOpen: onOpen) }
    }
    @ViewBuilder private var startActions: some View {
        ForEach(NativeLearningStartKind.allCases) { kind in
            Button { creating = kind } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(kind.symbol).font(NativeDesktopTheme.font(24, weight: .semibold)).frame(width: 32)
                    VStack(alignment: .leading, spacing: 8) { Text(kind.title).fontWeight(.semibold); Text(kind.detail).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 10))
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("native-learning-start-" + kind.id)
        }
    }
}

struct NativeLearningSidebar: View {
    @ObservedObject var store: NativeWorkspaceStore
    let onOpen: (NativeLearningBinding) -> Void
    @StateObject private var model = NativeLearningCatalog()
    @State private var query = ""
    @State private var creating: NativeLearningStartKind?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("학습 공간").font(NativeDesktopTheme.font(16, weight: .semibold)); Spacer(); NativeChromeButton(title: "학습 공간 새로고침", symbol: "arrow.clockwise") { Task { await model.reload(store) } } }
            HStack { Image(systemName: "magnifyingglass"); TextField("공간 검색", text: $query).textFieldStyle(.plain) }.font(NativeDesktopTheme.font(12)).padding(8).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            Menu { ForEach(NativeLearningStartKind.allCases) { kind in Button(kind.title) { creating = kind } } } label: { Label("새 학습", systemImage: "plus").foregroundStyle(NativeDesktopTheme.onAccent).frame(maxWidth: .infinity, minHeight: 36) }.buttonStyle(.borderedProminent).tint(NativeDesktopTheme.accent)
            if model.loading { ProgressView() }
            if let error = model.error { Text(error).font(NativeDesktopTheme.font(11)).foregroundStyle(.red) }
            ScrollView { NativeLearningGroups(projects: model.projects.filter { $0.deletedAt == nil && (query.isEmpty || ($0.name + " " + $0.topic).localizedStandardContains(query)) }, store: store, onOpen: onOpen) }
        }.padding(12).background(NativeDesktopTheme.surface).accessibilityIdentifier("native-learning-sidebar")
            .task { await model.reload(store) }
            .onReceive(store.events) { event in if ["learning:changed", "courses:changed"].contains(event.channel) { Task { await model.reload(store) } } }
            .sheet(item: $creating) { kind in NativeLearningStartSheet(store: store, kind: kind, source: nil, onOpen: onOpen) }
    }
}

private struct NativeLearningGroups: View {
    let projects: [NativeLearningSummary]
    @ObservedObject var store: NativeWorkspaceStore
    let onOpen: (NativeLearningBinding) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([("english-reading", "영어 이어읽기", "관심 있는 주제로 영어 글 읽기를 시작해 보세요."), ("course-review", "과목 복습", "새 학습에서 자료로 퀴즈나 카드를 만들어 보세요."), ("unclassified", "종류 확인 필요", "")], id: \.0) { group, title, empty in
                let entries = projects.filter { $0.group == group }
                if group != "unclassified" || !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(title).fontWeight(.semibold); Text("\(entries.count)").foregroundStyle(NativeDesktopTheme.muted) }.font(NativeDesktopTheme.font(12))
                        ForEach(entries) { project in NativeLearningProjectRow(project: project, store: store, onOpen: onOpen) }
                        if entries.isEmpty { Text(empty).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeLearningProjectRow: View {
    let project: NativeLearningSummary
    @ObservedObject var store: NativeWorkspaceStore
    let onOpen: (NativeLearningBinding) -> Void
    @State private var renaming = false
    @State private var name = ""
    @State private var deleting = false
    var body: some View {
        Button { onOpen(project.binding) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.displayName(courses: store.courses)).font(NativeDesktopTheme.font(13, weight: .medium)).lineLimit(2)
                Text(project.group == "course-review" ? "퀴즈와 카드, 풀이 기록" : project.topic).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(2)
                if project.completedArticleCount > 0 || project.wordCount > 0 || project.dueCardCount > 0 { Text("읽은 글 \(project.completedArticleCount) · 표현 \(project.wordCount) · 복습 \(project.dueCardCount)").font(NativeDesktopTheme.font(10)).foregroundStyle(NativeDesktopTheme.muted) }
                if let warning = project.warning { Text(warning).font(NativeDesktopTheme.font(10)).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("native-learning-project-" + project.binding.id)
            .contextMenu {
                Button("이름 변경", systemImage: "pencil") { name = project.name; renaming = true }
                Button("목록에서 삭제", systemImage: "trash", role: .destructive) { deleting = true }
            }
            .alert("학습 공간 이름", isPresented: $renaming) { TextField("이름", text: $name); Button("취소", role: .cancel) { }; Button("저장") { mutate("learning:rename", ["name": name]) } }
            .confirmationDialog("학습 공간을 목록에서 삭제할까요?", isPresented: $deleting, titleVisibility: .visible) { Button("목록에서 삭제", role: .destructive) { mutate("learning:delete", [:]) } } message: { Text("파일과 학습 기록은 보존되며 학습 홈에서 복원할 수 있습니다.") }
    }
    private func mutate(_ channel: String, _ extra: [String: Any]) {
        Task { do { _ = try await store.invoke(channel, ["binding": project.binding.request].merging(extra) { _, new in new }) } catch { store.errorMessage = error.localizedDescription } }
    }
}
