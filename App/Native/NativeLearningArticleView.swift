import SwiftUI

struct NativeLearningArticleView: View {
    @ObservedObject var model: NativeLearningWorkspaceModel
    let article: [String: Any]
    let onOpenBrowser: (String) -> Void
    @State private var wordParagraph: Paragraph?
    private struct Paragraph: Identifiable { let id: String; let text: String }
    private var paragraphs: [Paragraph] { (article["paragraphs"] as? [[String: Any]] ?? []).compactMap { row in guard let id = row["id"] as? String, let text = row["text"] as? String else { return nil }; return Paragraph(id: id, text: text) } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(article["title"] as? String ?? "기사").font(NativeDesktopTheme.font(28, weight: .semibold))
                    if let url = article["sourceUrl"] as? String { Button("원문 사이트 열기", systemImage: "arrow.up.right") { onOpenBrowser(url) }.font(.caption) }
                    ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(paragraph.text).font(NativeDesktopTheme.font(18)).lineSpacing(8).textSelection(.enabled)
                            HStack { Button("표현 저장", systemImage: "bookmark") { wordParagraph = paragraph }; Spacer(); Button("여기까지 읽음") { Task { _ = await model.mutate("learning:saveProgress", ["articleId": article["id"] ?? "", "paragraphId": paragraph.id, "scrollFraction": Double(index + 1) / Double(max(1, paragraphs.count))]) } } }.font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted)
                        }.id(paragraph.id)
                    }
                    Button("다 읽었어요", systemImage: "checkmark.circle") { Task { _ = await model.mutate("learning:completeArticle", ["articleId": article["id"] ?? ""]) } }.buttonStyle(.borderedProminent).accessibilityIdentifier("native-learning-complete-article")
                }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.nativeLearningPanelScroll(model: model, detail: article["id"] as? String ?? "article").onAppear {
                guard model.store.panelViewStates.read(NativeLearningPanelScrollState.self, id: model.panelID + ":" + (article["id"] as? String ?? "article"), kind: "learning") == nil else { return }
                if let row = model.rows("articles").first(where: { $0["id"] as? String == article["id"] as? String }), let progress = row["progress"] as? [String: Any], let paragraph = progress["paragraphId"] as? String { proxy.scrollTo(paragraph, anchor: .top) }
            }
        }.disabled(model.busy || model.frozen)
            .sheet(item: $wordParagraph) { paragraph in NativeLearningSaveWordSheet(model: model, articleID: article["id"] as? String ?? "", paragraphID: paragraph.id, text: paragraph.text) }
    }
}

private struct NativeLearningSaveWordSheet: View {
    @ObservedObject var model: NativeLearningWorkspaceModel
    let articleID: String
    let paragraphID: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""
    @State private var meaning = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("원문") { Text(text).textSelection(.enabled) }
                Section("저장할 표현") { TextField("원문에 있는 단어나 표현", text: $word); TextField("뜻 · 메모", text: $meaning) }
                if let error = model.error { NativeToolError(message: error) }
            }.navigationTitle("표현 저장").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("저장") { save() }.disabled(word.isEmpty || !text.contains(word) || model.busy || model.frozen) } }
        }.interactiveDismissDisabled(model.busy)
    }
    private func save() { Task { if await model.mutate("learning:saveWord", ["surface": word, "sentence": text, "meaning": meaning, "sourceRef": ["kind": "article", "articleId": articleID, "paragraphId": paragraphID, "quote": text]]) { dismiss() } } }
}

struct NativeLearningWordRow: View {
    @ObservedObject var model: NativeLearningWorkspaceModel
    let word: [String: Any]
    @State private var editing = false
    @State private var meaning = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(word["lemma"] as? String ?? word["surface"] as? String ?? "").font(.headline); Text(word["pronunciation"] as? String ?? "").font(.caption).foregroundStyle(.secondary); Spacer(); statusMenu }
            Text(word["meaning"] as? String ?? "").textSelection(.enabled)
            ForEach(Array(model.rows("occurrences").filter { $0["wordId"] as? String == word["id"] as? String }.enumerated()), id: \.offset) { _, row in Text(row["sentence"] as? String ?? "").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("뜻 편집", systemImage: "pencil") { meaning = word["meaning"] as? String ?? ""; editing = true }.font(.caption)
        }.padding(16).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .alert("표현의 뜻", isPresented: $editing) { TextField("뜻", text: $meaning); Button("취소", role: .cancel) { }; Button("저장") { Task { _ = await model.mutate("learning:updateWord", ["wordId": word["id"] ?? "", "meaning": meaning]) } } }
    }
    private var statusMenu: some View {
        Menu { Button("새 표현") { status("new") }; Button("학습 중") { status("learning") }; Button("알고 있어요") { status("known") } } label: { Text(word["status"] as? String == "known" ? "알고 있어요" : word["status"] as? String == "learning" ? "학습 중" : "새 표현").font(.caption) }
    }
    private func status(_ value: String) { Task { _ = await model.mutate("learning:updateWord", ["wordId": word["id"] ?? "", "status": value]) } }
}
