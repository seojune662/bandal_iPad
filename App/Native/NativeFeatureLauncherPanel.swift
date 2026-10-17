import SwiftUI

struct NativeFeatureLauncherPanel: View {
    @ObservedObject var store: NativeWorkspaceStore
    let source: NativeDocumentReference?
    let onOpen: (NativeLearningBinding) -> Void
    let onOpenSettings: (String) -> Void
    @State private var tools: [Tool] = []
    @State private var query = ""
    @State private var selected: Tool?
    @State private var error: String?
    private struct Tool: Decodable, Identifiable {
        let id: String
        let packId: String
        let label: String
        let description: String
        let enabled: Bool
        let unavailableReason: String?
        var start: NativeLearningStartKind { packId == "vocab-chain-en" ? .english : packId == "quiz" ? .quiz : .flashcards }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("바로 실행").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted)
            Text("학습 도구").font(NativeDesktopTheme.font(19, weight: .semibold))
            HStack { Image(systemName: "magnifyingglass"); TextField("도구 검색", text: $query).textFieldStyle(.plain) }.font(NativeDesktopTheme.font(12)).padding(8).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            if let error { NativeToolError(message: error); Button("다시 불러오기") { Task { await reload() } } }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tools.filter { query.isEmpty || ($0.label + " " + $0.description).localizedStandardContains(query) }) { tool in
                        Button { selected = tool } label: {
                            HStack(alignment: .top) {
                                Image(systemName: tool.packId == "quiz" ? "questionmark.square" : tool.packId == "flashcards" ? "rectangle.on.rectangle" : tool.packId == "summary" ? "text.alignleft" : "text.book.closed").frame(width: 24)
                                VStack(alignment: .leading, spacing: 6) { Text(tool.label).fontWeight(.medium); Text(tool.unavailableReason ?? tool.description).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 10))
                            }.font(NativeDesktopTheme.font(13)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(!tool.enabled).accessibilityIdentifier("native-study-tool-" + tool.packId)
                    }
                }
            }
            Button("플러그인 관리", systemImage: "slider.horizontal.3") { onOpenSettings("plugins") }.font(NativeDesktopTheme.font(12))
        }.padding(14).background(NativeDesktopTheme.surface).accessibilityElement(children: .contain).accessibilityIdentifier("native-study-tools")
            .task { await reload() }
            .sheet(item: $selected) { tool in NativeLearningStartSheet(store: store, kind: tool.start, source: source, packID: tool.packId == "summary" ? "summary" : nil, onOpen: onOpen) }
    }
    private func reload() async {
        do { tools = try NativeToolJSON.decode(try await store.invoke("study:listTools")); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
