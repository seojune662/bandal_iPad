import SwiftUI

enum NativeNewTabAction: Equatable {
    case markdown(title: String?), browser(url: String?), assistant, recording, note
}

/// The five creation actions, in the order the user asked for: 브라우저 · 노트 · 마크다운 · AI · 녹음.
enum NativeNewTabCatalog {
    struct Item: Identifiable {
        let id: String, title: String, hint: String, symbol: String
        let action: NativeNewTabAction
    }
    static func url(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        let hasScheme = value.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let domain = value.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard hasScheme || domain else { return nil }
        let result = hasScheme ? value : "https://" + value
        guard let url = URL(string: result), url.host != nil else { return nil }
        return result
    }
    static func items(query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url(trimmed)
        func matches(_ terms: [String]) -> Bool { trimmed.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(trimmed) } }
        let all: [(Item, [String])] = [
            (.init(id: "new-browser", title: "브라우저", hint: "학교 사이트·웹 검색", symbol: "globe", action: .browser(url: url)), ["브라우저", "웹", "browser"]),
            (.init(id: "new-whiteboard", title: "노트", hint: "펜슬로 쓰는 종이", symbol: "pencil", action: .note), ["노트", "필기", "종이", "화이트보드", "note"]),
            (.init(id: "new-note", title: "마크다운", hint: "키보드로 쓰는 문서", symbol: "square.and.pencil", action: .markdown(title: nil)), ["마크다운", "문서", "markdown"]),
            (.init(id: "chat", title: "AI", hint: "자료에 대해 질문", symbol: "sparkles", action: .assistant), ["AI", "대화", "튜터"]),
            (.init(id: "recording", title: "녹음", hint: "강의 녹음 → 요약", symbol: "mic", action: .recording), ["녹음", "강의", "실시간 자막", "STT", "recording"])
        ]
        if url != nil { return [all[0].0] }
        return all.filter { matches($0.1) && (NativeReleaseFlags.showsRecording || $0.0.id != "recording") }.map(\.0)
    }
}

/// The ＋ menu (Figma 129:2809): five rows and no search bar. 브라우저's second line is the field: what is
/// typed there filters the rows or is taken as a URL, and Enter opens the highlighted row. The menu itself
/// holds the focus when it opens, so a hardware keyboard works at once and the on-screen one stays down.
struct NativeNewTabMenu: View {
    let onAction: (NativeNewTabAction) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    /// The highlight is a keyboard's or pointer's cursor. Under a finger every row looks the same: a row
    /// already shaded when the menu opens read as a different kind of row.
    @State private var showsHighlight = false
    private enum Focus { case menu, search }
    @FocusState private var focus: Focus?
    @Environment(\.locale) private var locale
    private static let browserID = "new-browser"
    /// 브라우저 stays because it holds the field; the other rows are the ones that match.
    private var items: [NativeNewTabCatalog.Item] {
        let found = NativeNewTabCatalog.items(query: query)
        return [found.first { $0.id == Self.browserID } ?? NativeNewTabCatalog.items(query: "")[0]] + found.filter { $0.id != Self.browserID }
    }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { activate(item) } label: { row(item, selected: showsHighlight && highlighted == index, first: index == 0, last: index == items.count - 1) }
                    .buttonStyle(.plain).accessibilityIdentifier("native-new-tab-" + item.id)
                    .onHover { if $0 { highlighted = index; showsHighlight = true } }
                    .overlay { if item.id == Self.browserID { searchLine(item) } }
            }
        }
        .focusable().focusEffectDisabled().focused($focus, equals: .menu)
        .onKeyPress(.downArrow) { move(1) }.onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) { activateHighlighted(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        // The first typed character starts the search and hands the focus to the field.
        .onKeyPress(phases: .down) { press in
            guard focus == .menu, press.modifiers.subtracting(.shift).isEmpty, let first = press.characters.first, first.isLetter || first.isNumber else { return .ignored }
            query += press.characters; focus = .search; showsHighlight = true
            return .handled
        }
        .onChange(of: query) { _, _ in highlighted = items.count > 1 && !query.isEmpty ? 1 : 0; if !query.isEmpty { showsHighlight = true } }
        // The preferred document starts highlighted, so Enter makes it.
        .onAppear {
            let preferred = UserDefaults.standard.string(forKey: NativeLocalPreferences.newDocumentKind) == "markdown" ? "new-note" : "new-whiteboard"
            highlighted = items.firstIndex { $0.id == preferred } ?? 0
            focus = .menu
        }
    }
    /// The highlight runs edge to edge; only the first and last rows follow the card's corners.
    private func row(_ item: NativeNewTabCatalog.Item, selected: Bool, first: Bool, last: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol).font(.system(size: 18)).foregroundStyle(NativeDesktopTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                BandalText(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                BandalText(item.hint).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).opacity(item.id == Self.browserID ? 0 : 1)
            }.lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).frame(height: 55).contentShape(Rectangle())
            .background(selected ? NativeDesktopTheme.raised : .clear, in: UnevenRoundedRectangle(topLeadingRadius: first ? 18 : 0, bottomLeadingRadius: last ? 18 : 0,
                                                                                               bottomTrailingRadius: last ? 18 : 0, topTrailingRadius: first ? 18 : 0, style: .continuous))
    }
    /// Laid out as the row is, so the field lies exactly where the second line would be.
    private func searchLine(_ item: NativeNewTabCatalog.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol).font(.system(size: 18)).hidden()
            VStack(alignment: .leading, spacing: 1) {
                BandalText(item.title).font(.system(size: 15, weight: .medium)).hidden()
                TextField("", text: $query, prompt: Text(verbatim: NativeAppLocale.string(item.hint, locale)).foregroundStyle(NativeDesktopTheme.secondary))
                    .font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.text).textFieldStyle(.plain)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).focused($focus, equals: .search)
                    .accessibilityLabel("검색하거나 URL 입력").accessibilityIdentifier("native-new-tab-search")
                    .onSubmit { activateHighlighted() }
                    .onKeyPress(.downArrow) { move(1) }.onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .frame(width: 200)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).frame(height: 55)
    }
    private func move(_ step: Int) -> KeyPress.Result {
        // The first arrow press shows the cursor where Enter already pointed; the next ones move it.
        if showsHighlight { highlighted = min(max(0, highlighted + step), items.count - 1) }
        showsHighlight = true
        return .handled
    }
    private func activate(_ item: NativeNewTabCatalog.Item) { onClose(); onAction(item.action) }
    private func activateHighlighted() { if items.indices.contains(highlighted) { activate(items[highlighted]) } }
}
