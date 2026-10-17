import SwiftUI

enum NativeNewTabAction: Equatable {
    case markdown(title: String?), browser(url: String?), assistant, learning, recording, note, planner
    case material(NativeDocumentReference)
}

/// The desktop omnibox order and search rules, independent of presentation.
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
    static func items(query: String, courseID: String, courseName: String, materials: [NativeMaterial]) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ terms: [String]) -> Bool { trimmed.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(trimmed) } }
        var result: [Item] = []
        if let url = url(trimmed) { result.append(.init(id: "open-url", title: url + " 열기", hint: "브라우저", symbol: "globe", shortcutID: nil, action: .browser(url: url))) }
        if matches(["새 마크다운", "새 필기"]) { result.append(.init(id: "new-note", title: "새 마크다운", hint: trimmed.isEmpty ? "" : "\"\(trimmed)\"", symbol: "doc.text", shortcutID: "new-markdown", action: .markdown(title: trimmed.isEmpty ? nil : trimmed))) }
        if matches(["새 브라우저 탭"]) { result.append(.init(id: "new-browser", title: "새 브라우저 탭", hint: "", symbol: "globe", shortcutID: "new-browser-tab", action: .browser(url: nil))) }
        if matches(["AI", "AI 튜터"]) { result.append(.init(id: "chat", title: "AI", hint: courseName, symbol: "bubble.left.and.bubble.right", shortcutID: "new-ai-tab", action: .assistant)) }
        if matches(["학습 공간", "영어", "단어장", "플래시카드", "퀴즈"]) { result.append(.init(id: "learning", title: "학습 공간", hint: "읽기 · 단어장 · 복습", symbol: "book", shortcutID: nil, action: .learning)) }
        if matches(["녹음", "강의 녹음", "실시간 자막", "STT", "recording"]) { result.append(.init(id: "recording", title: "녹음", hint: "강의 · 실시간 자막", symbol: "waveform", shortcutID: "new-recording-tab", action: .recording)) }
        if matches(["새 노트", "노트", "화이트보드", "마인드맵"]) { result.append(.init(id: "new-whiteboard", title: "새 노트", hint: "PDF 필기", symbol: "rectangle.and.pencil.and.ellipsis", shortcutID: "new-whiteboard", action: .note)) }
        if matches(["학업 보드"]) { result.append(.init(id: "board", title: "학업 보드", hint: "", symbol: "checklist", shortcutID: "open-study-board", action: .planner)) }
        if !trimmed.isEmpty {
            func pdfs(_ nodes: [NativeMaterial]) -> [NativeMaterial] { nodes.flatMap { ($0.kind == "pdf" ? [$0] : []) + pdfs($0.children ?? []) } }
            for pdf in pdfs(materials).filter({ matches([$0.name]) }).prefix(8) {
                result.append(.init(id: "pdf:" + pdf.relPath, title: pdf.name, hint: "PDF 열기", symbol: "doc.richtext", shortcutID: nil, action: .material(pdf.document(in: courseID))))
            }
        }
        return result
    }
}

struct NativeNewTabMenu: View {
    @ObservedObject var store: NativeWorkspaceStore
    let courseID: String
    let onAction: (NativeNewTabAction) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var addingLink = false
    @State private var linkURL = ""
    @State private var linkLabel = ""
    @State private var error: String?
    @State private var saving = false
    @State private var settings: [String: Any] = [:]
    @FocusState private var searchFocused: Bool
    private var items: [NativeNewTabCatalog.Item] {
        NativeNewTabCatalog.items(query: query, courseID: courseID,
            courseName: store.courses.first(where: { $0.id == courseID })?.name ?? "",
            materials: store.selectedCourseID == courseID ? store.materials : [])
    }
    var body: some View {
        Group {
            if addingLink { linkForm }
            else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
                        TextField("검색하거나 URL 입력…", text: $query).textFieldStyle(.plain)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).focused($searchFocused)
                            .accessibilityIdentifier("native-new-tab-search")
                            .onSubmit { activateHighlighted() }
                            .onKeyPress(.downArrow) { highlighted = min(items.count, highlighted + 1); return .handled }
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
                            Divider().padding(.vertical, 4)
                            Button { beginLink() } label: {
                                HStack(spacing: 8) { Image(systemName: "link").frame(width: 18); Text("링크 추가"); Spacer(); Text("즐겨찾기").foregroundStyle(NativeDesktopTheme.muted) }
                                    .padding(.horizontal, 8).frame(height: 36)
                                    .background(highlighted == items.count ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityIdentifier("native-new-tab-add-link")
                        }
                    }.frame(maxHeight: 340)
                }
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
    private func activateHighlighted() { if items.indices.contains(highlighted) { activate(items[highlighted]) } else { beginLink() } }
    private func beginLink() {
        linkURL = NativeNewTabCatalog.url(query) ?? ""; linkLabel = URL(string: linkURL)?.host ?? ""
        addingLink = true; error = nil
    }
    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("링크 추가").font(.system(size: 14, weight: .medium))
            TextField("주소 입력", text: $linkURL).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("native-new-tab-link-url")
            TextField("이름", text: $linkLabel).textFieldStyle(.roundedBorder).accessibilityIdentifier("native-new-tab-link-name")
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            HStack { Spacer(); Button("취소") { addingLink = false; error = nil; searchFocused = true }; Button(saving ? "저장 중…" : "저장") { saveLink() }.disabled(saving) }
        }.padding(8)
    }
    private func saveLink() {
        guard let url = NativeNewTabCatalog.url(linkURL) else { error = "http(s) URL을 입력해 주세요."; return }
        let label = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { error = "링크 이름을 입력해 주세요."; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await store.invoke("favorites:add", ["courseId": courseID, "label": label,
                    "descriptor": ["kind": "browser", "payload": ["tabId": UUID().uuidString, "initialUrl": url]]])
                store.events.send(.init(channel: "nativeWorkspace:favoritesChanged", payload: ["courseId": courseID])); onClose()
            } catch { self.error = error.localizedDescription }
        }
    }
}
