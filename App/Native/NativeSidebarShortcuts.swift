import SwiftUI

struct NativeSidebarShortcuts: View {
    @ObservedObject var store: NativeWorkspaceStore
    let settings: [String: Any]
    let onOpenSettings: (String) -> Void
    let onOpenURL: (String) -> Void
    let onOpenAIWeb: (NativeAIWebShortcut) -> Void
    @AppStorage("native.desktop.universityCollapsed") private var universityCollapsed = false
    @AppStorage("native.desktop.universityShowAll") private var showAll = false
    @AppStorage("native.desktop.aiShortcutsCollapsed") private var aiCollapsed = false
    @State private var busy = false
    private var services: [NativeUniversityService] { NativeUniversityCatalog.resolvedServices(settings: settings) }
    private var primary: [NativeUniversityService] { services.filter { !$0.secondary } }
    private var secondary: [NativeUniversityService] { services.filter(\.secondary) }
    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let university = NativeUniversityCatalog.university(settings) {
                heading(university["nameKo"] as? String ?? "학교 바로가기", collapsed: $universityCollapsed)
                    .accessibilityIdentifier("native-university-heading")
                    .contextMenu { Button("학교 설정") { onOpenSettings("university") } }
                if !universityCollapsed {
                    LazyVGrid(columns: columns, spacing: 4) { ForEach(primary, content: serviceButton) }
                    if showAll { LazyVGrid(columns: columns, spacing: 4) { ForEach(secondary, content: serviceButton) } }
                    if !secondary.isEmpty { Button(showAll ? "접기" : "더보기 \(secondary.count)") { showAll.toggle() }.font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 28).accessibilityIdentifier("native-university-more") }
                }
            } else {
                Button("학교 고르기", systemImage: "building.columns") { onOpenSettings("university") }
                    .font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 36).accessibilityIdentifier("native-university-choose")
            }
            heading("AI", collapsed: $aiCollapsed).accessibilityIdentifier("native-ai-web-heading")
            if !aiCollapsed {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(NativeAIWebShortcut.all) { shortcut in
                        Button { onOpenAIWeb(shortcut) } label: {
                            HStack(spacing: 7) {
                                NativeProviderMark(provider: shortcut.id, size: 20)
                                Text(shortcut.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(NativeDesktopTheme.font(12)).padding(.horizontal, 7).frame(minHeight: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(shortcut.title + " 웹 열기").accessibilityIdentifier("native-ai-web-" + shortcut.id)
                    }
                }
            }
        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10).disabled(busy)
    }
    private func heading(_ title: String, collapsed: Binding<Bool>) -> some View {
        Button { collapsed.wrappedValue.toggle() } label: {
            HStack(spacing: 7) { Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down").font(.system(size: 9)).frame(width: 12); Text(title).font(NativeDesktopTheme.font(12, weight: .semibold)).lineLimit(1); Spacer(minLength: 0) }.frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title + (collapsed.wrappedValue ? " 펼치기" : " 접기"))
    }
    private func serviceButton(_ service: NativeUniversityService) -> some View {
        Button {
            if service.opensExternally, let url = URL(string: service.url) { UIApplication.shared.open(url) }
            else { onOpenURL(service.url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol(service.kind)).font(.system(size: 13)).frame(width: 16)
                Text(service.label).font(NativeDesktopTheme.font(12)).lineLimit(1)
                Spacer(minLength: 0)
                if service.opensExternally { Image(systemName: "arrow.up.right").font(.system(size: 8)) }
            }.padding(.horizontal, 6).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary)
            .accessibilityIdentifier("native-university-service-" + service.id)
            .contextMenu {
                Button("위로 이동", systemImage: "arrow.up") { move(service, by: -1) }
                Button("아래로 이동", systemImage: "arrow.down") { move(service, by: 1) }
                Button(service.secondary ? "항상 표시" : "더보기로 이동") {
                    var overrides = ((settings["university"] as? [String: Any])?["secondaryOverrides"] as? [String: Bool]) ?? [:]
                    overrides[service.id] = !service.secondary; persist(["secondaryOverrides": overrides])
                }
                Button("숨기기", systemImage: "eye.slash") {
                    let hidden = (settings["university"] as? [String: Any])?["hiddenServiceIds"] as? [String] ?? []
                    persist(["hiddenServiceIds": Array(Set(hidden + [service.id]))])
                }
                Button("배치 초기화", systemImage: "arrow.counterclockwise") { persist(["serviceOrder": [], "secondaryOverrides": [String: Bool](), "hiddenServiceIds": []]) }
                Button("학교 설정", systemImage: "gearshape") { onOpenSettings("university") }
            }
    }
    private func symbol(_ kind: String) -> String {
        switch kind { case "lms": "graduationcap"; case "portal", "registration": "person.text.rectangle"; case "library": "books.vertical"; case "mail": "envelope"; case "community": "person.2"; default: "globe" }
    }
    private func move(_ service: NativeUniversityService, by offset: Int) {
        var ids = services.map(\.id)
        guard let index = ids.firstIndex(of: service.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); persist(["serviceOrder": ids])
    }
    private func persist(_ changes: [String: Any]) {
        guard !busy else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do { _ = try await store.invoke("settings:set", ["university": changes]) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}
