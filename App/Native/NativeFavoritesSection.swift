import SwiftUI
import UniformTypeIdentifiers

/// The course children are portable saved tab descriptors, as on desktop.
struct NativeFavoritesSection: View {
    @ObservedObject var store: NativeWorkspaceStore
    let courseID: String
    let currentDocument: NativeDocumentReference?
    let descriptor: (NativeDocumentReference) -> [String: Any]?
    let documentByID: (String) -> NativeDocumentReference?
    let onOpen: (NativeSidebarFavorite) -> Void
    @State private var favorites: [NativeSidebarFavorite] = []
    @State private var adding = false
    @State private var linkURL = ""
    @State private var linkLabel = ""
    @State private var renaming: NativeSidebarFavorite?
    @State private var renamedLabel = ""
    @State private var busy = false
    @State private var error: String?
    @State private var targeted = false
    @State private var loadRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(favorites.isEmpty && !adding ? "탭을 끌어 즐겨찾기 추가" : "즐겨찾기")
                    .font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted)
                Spacer(minLength: 0)
                Menu {
                    Button("링크 추가", systemImage: "link.badge.plus") { adding.toggle() }.accessibilityIdentifier("native-favorite-add-link")
                    if let currentDocument, descriptor(currentDocument) != nil {
                        Button("현재 탭 즐겨찾기에 추가", systemImage: "star") { addDocument(currentDocument) }.accessibilityIdentifier("native-favorite-add-current")
                    }
                } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                .accessibilityLabel("즐겨찾기 추가").accessibilityIdentifier("native-favorite-add-" + courseID)
            }
            if adding { linkForm }
            if let error { Text(error).font(NativeDesktopTheme.font(11)).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
                Button { onOpen(favorite) } label: {
                    Label(favorite.label, systemImage: NativeSidebarDescriptor.symbol(favorite.kind))
                        .font(NativeDesktopTheme.font(12)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary)
                    .accessibilityIdentifier("native-favorite-" + favorite.id)
                    .contextMenu {
                        Button("이름 변경", systemImage: "pencil") { renamedLabel = favorite.label; renaming = favorite }
                        Button("위로 이동", systemImage: "arrow.up") { move(index, by: -1) }.disabled(index == 0)
                        Button("아래로 이동", systemImage: "arrow.down") { move(index, by: 1) }.disabled(index == favorites.count - 1)
                        Button("즐겨찾기 제거", systemImage: "star.slash", role: .destructive) { mutate("favorites:remove", ["id": favorite.id]) }
                    }
            }
        }.padding(.leading, 28).padding(.trailing, 8).padding(.bottom, 6)
            .background(targeted ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
            .disabled(busy)
            .onDrop(of: [NativeDockDragPayload.contentType], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: NativeDockDragPayload.contentType.identifier) { data, _ in
                    guard let data, let id = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in if let document = documentByID(id) { addDocument(document) } }
                }
                return true
            }
            .task(id: courseID) { await reload() }
            .onReceive(store.events) { event in
                if ["favorites:changed", "nativeWorkspace:favoritesChanged", "nativeWorkspace:materialRenamed", "nativeWorkspace:materialDeleted"].contains(event.channel) { Task { await reload() } }
            }
            .alert("즐겨찾기 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("이름", text: $renamedLabel)
                Button("취소", role: .cancel) { renaming = nil }
                Button("저장") { if let favorite = renaming { mutate("favorites:rename", ["id": favorite.id, "label": renamedLabel]); renaming = nil } }
            }
    }
    private var linkForm: some View {
        VStack(spacing: 8) {
            TextField("주소 입력", text: $linkURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("native-favorite-url")
            TextField("링크 이름", text: $linkLabel).accessibilityIdentifier("native-favorite-name")
            HStack { Button("취소") { adding = false }; Spacer(); Button("추가", action: addLink).disabled(linkURL.isEmpty || linkLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("native-favorite-save") }
        }.font(NativeDesktopTheme.font(12)).textFieldStyle(.roundedBorder).padding(.vertical, 6)
    }
    private func addLink() {
        var raw = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, host.contains("."), !host.contains(" ") else { error = "올바른 http(s) 주소를 입력해 주세요."; return }
        mutate("favorites:add", ["courseId": courseID, "label": linkLabel, "descriptor": ["kind": "browser", "payload": ["tabId": UUID().uuidString, "initialUrl": url.absoluteString]]], closeForm: true)
    }
    private func addDocument(_ document: NativeDocumentReference) {
        guard let value = descriptor(document) else { error = "이 탭은 즐겨찾기에 저장할 수 없습니다."; return }
        mutate("favorites:add", ["courseId": courseID, "label": document.title, "descriptor": value])
    }
    private func move(_ index: Int, by offset: Int) {
        guard favorites.indices.contains(index + offset) else { return }
        var ids = favorites.map(\.id); ids.swapAt(index, index + offset)
        mutate("favorites:reorder", ["courseId": courseID, "ids": ids])
    }
    private func mutate(_ channel: String, _ request: [String: Any], closeForm: Bool = false) {
        guard !busy else { return }; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await store.invoke(channel, request)
                if closeForm { adding = false; linkURL = ""; linkLabel = "" }
                await reload()
                store.events.send(.init(channel: "nativeWorkspace:favoritesChanged", payload: ["courseId": courseID]))
            } catch { self.error = error.localizedDescription }
        }
    }
    private func reload() async {
        loadRevision += 1; let revision = loadRevision
        do {
            let rows = try await store.invoke("favorites:list", ["courseId": courseID]) as? [[String: Any]] ?? []
            guard revision == loadRevision, !Task.isCancelled else { return }
            favorites = rows.compactMap(NativeSidebarFavorite.init); error = nil
        } catch { if revision == loadRevision { self.error = error.localizedDescription } }
    }
}
