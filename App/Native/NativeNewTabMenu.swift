import SwiftUI

enum NativeNewTabAction: Equatable {
    case markdown(title: String?), browser(url: String?), assistant, recording, note
}

/// The five creation actions, in the order the user asked for: 브라우저 · 노트 · 마크다운 · AI · 녹음.
enum NativeNewTabCatalog {
    struct Item: Identifiable {
        let id: String, title: String, hint: String, symbol: String
        let shortcutID: String?
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
    static func items(query: String, courseName: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url(trimmed)
        func matches(_ terms: [String]) -> Bool { trimmed.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(trimmed) } }
        let all: [(Item, [String])] = [
            (.init(id: "new-browser", title: "브라우저", hint: url ?? "", symbol: "globe", shortcutID: "new-browser-tab", action: .browser(url: url)), ["브라우저", "웹", "browser"]),
            (.init(id: "new-whiteboard", title: "노트", hint: "빈 종이 · 줄 · 모눈 · 점", symbol: "rectangle.and.pencil.and.ellipsis", shortcutID: "new-whiteboard", action: .note), ["노트", "필기", "종이", "화이트보드", "note"]),
            (.init(id: "new-note", title: "마크다운", hint: "", symbol: "doc.text", shortcutID: "new-markdown", action: .markdown(title: nil)), ["마크다운", "문서", "markdown"]),
            (.init(id: "chat", title: "AI", hint: courseName, symbol: "bubble.left.and.bubble.right", shortcutID: "new-ai-tab", action: .assistant), ["AI", "대화", "튜터"]),
            (.init(id: "recording", title: "녹음", hint: "강의 · 실시간 자막", symbol: "waveform", shortcutID: "new-recording-tab", action: .recording), ["녹음", "강의", "실시간 자막", "STT", "recording"])
        ]
        if url != nil { return [all[0].0] }
        return all.filter { matches($0.1) && (NativeReleaseFlags.showsRecording || $0.0.id != "recording") }.map(\.0)
    }
}

struct NativeNewTabMenu: View {
    @ObservedObject var store: NativeWorkspaceStore
    let courseID: String
    let onAction: (NativeNewTabAction) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var settings: [String: Any] = [:]
    @FocusState private var searchFocused: Bool
    private var items: [NativeNewTabCatalog.Item] {
        NativeNewTabCatalog.items(query: query, courseName: store.courses.first(where: { $0.id == courseID })?.name ?? "")
    }
    var body: some View {
        Group {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
                        TextField("검색하거나 URL 입력…", text: $query).textFieldStyle(.plain)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).focused($searchFocused)
                            .accessibilityIdentifier("native-new-tab-search")
                            .onSubmit { activateHighlighted() }
                            .onKeyPress(.downArrow) { highlighted = min(max(0, items.count - 1), highlighted + 1); return .handled }
                            .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                            .onKeyPress(.escape) { onClose(); return .handled }
                    }.padding(.horizontal, 8).frame(height: 36)
                        .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(NativeDesktopTheme.border, lineWidth: 1))
                    ScrollView {
                        VStack(spacing: 0) {
                            if items.isEmpty { Text("일치하는 항목이 없어요").foregroundStyle(NativeDesktopTheme.muted).padding(16) }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button { activate(item) } label: { row(item, selected: highlighted == index) }
                                    .buttonStyle(.plain).accessibilityIdentifier("native-new-tab-" + item.id)
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                    }.frame(maxHeight: 340)
                }
        }.font(.system(size: 13)).padding(8).frame(width: 352)
            .background(NativeDesktopTheme.surface)
            .onChange(of: query) { _, _ in highlighted = 0 }
            .task { settings = (try? await store.invoke("settings:get")) as? [String: Any] ?? [:]; searchFocused = true }
    }
    private func row(_ item: NativeNewTabCatalog.Item, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(NativeDesktopTheme.muted)
            Text(item.title).lineLimit(1)
            Spacer(minLength: 4)
            if !item.hint.isEmpty { Text(item.hint).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
            if let chord = shortcut(item.shortcutID) { Text(chord).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).fixedSize() }
        }.padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
            .background(selected ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
    private func shortcut(_ id: String?) -> String? {
        guard let id else { return nil }
        let bindings = settings["keybindings"] as? [String: Any] ?? [:]
        if bindings[id] is NSNull { return nil }
        guard let value = bindings[id] as? String ?? NativeBrowserShortcuts.specs.first(where: { $0.id == id })?.chord else { return nil }
        return value.replacingOccurrences(of: "mod+", with: "⌘").replacingOccurrences(of: "alt+", with: "⌥").replacingOccurrences(of: "shift+", with: "⇧").uppercased()
    }
    private func activate(_ item: NativeNewTabCatalog.Item) { onClose(); onAction(item.action) }
    private func activateHighlighted() { if items.indices.contains(highlighted) { activate(items[highlighted]) } }
}
