import SwiftUI

struct NativeSidebarShortcuts: View {
    var store: NativeWorkspaceStore
    let settings: [String: Any]
    let onOpenSettings: (String) -> Void
    let onOpenURL: (String) -> Void
    let onOpenAIWeb: (NativeAIWebShortcut) -> Void
    @AppStorage("native.desktop.universityCollapsed") private var universityCollapsed = false
    @AppStorage("native.desktop.universityShowAll") private var showAll = false
    /// The design shows this heading alone; the three sites open under it.
    @AppStorage("native.desktop.aiShortcutsCollapsed") private var aiCollapsed = true
    @State private var busy = false
    private var services: [NativeUniversityService] { NativeUniversityCatalog.resolvedServices(settings: settings) }
    private var primary: [NativeUniversityService] { services.filter { !$0.secondary } }
    private var secondary: [NativeUniversityService] { services.filter(\.secondary) }
    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let university = NativeUniversityCatalog.university(settings) {
                Button { universityCollapsed.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: universityCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 14)
                        Text(university["nameKo"] as? String ?? "학교 바로가기").font(NativeDesktopTheme.font(15, weight: .bold)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(height: 21).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel((university["nameKo"] as? String ?? "학교 바로가기") + (universityCollapsed ? " 펼치기" : " 접기"))
                    .accessibilityIdentifier("native-university-heading")
                    .contextMenu { Button("학교 설정") { onOpenSettings("university") } }
                if !universityCollapsed {
                    if NativeUniversityCatalog.needsLinks(settings) {
                        noLinksCard(university).padding(.top, 14)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) { ForEach(primary, content: serviceButton) }.padding(.top, 14)
                        if showAll { LazyVGrid(columns: columns, spacing: 6) { ForEach(secondary, content: serviceButton) }.padding(.top, 6) }
                        if !secondary.isEmpty {
                            Button(showAll ? "접기" : "더보기 \(secondary.count)") { showAll.toggle() }.buttonStyle(.plain).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeGlass.panelTertiary)
                                .frame(height: 22).contentShape(Rectangle()).accessibilityIdentifier("native-university-more")
                        }
                    }
                }
            } else {
                NativeSchoolPickerButton(store: store, arrowEdge: .leading) { Label("학교 고르기", systemImage: "building.columns") }
                    .buttonStyle(.plain).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 36).accessibilityIdentifier("native-university-choose")
            }
            Button { aiCollapsed.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: aiCollapsed ? "chevron.down" : "chevron.up").font(.system(size: 11)).foregroundStyle(NativeGlass.panelIcon).frame(width: 13)
                    Text("외부 AI 사이트 ↗").font(NativeDesktopTheme.font(11, weight: .medium)).foregroundStyle(NativeGlass.icon).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 2).accessibilityLabel(aiCollapsed ? "외부 AI 사이트 펼치기" : "외부 AI 사이트 접기").accessibilityIdentifier("native-ai-web-heading")
            if !aiCollapsed {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(NativeAIWebShortcut.all) { shortcut in
                        Button { onOpenAIWeb(shortcut) } label: {
                            HStack(spacing: 7) {
                                NativeProviderMark(provider: shortcut.id, size: 18)
                                Text(shortcut.title).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                        }.buttonStyle(NativeShortcutTileStyle()).accessibilityLabel(shortcut.title + " 웹 열기").accessibilityIdentifier("native-ai-web-" + shortcut.id)
                    }
                }.padding(.bottom, 8)
            }
        }.padding(.horizontal, 14).padding(.top, 18).disabled(busy)

    }
    /// A school known by name only (typed in, or its AI result not yet saved).
    private func noLinksCard(_ university: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("FigmaLink").foregroundStyle(NativeDesktopTheme.muted).frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("아직 바로가기가 없어요").font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text).frame(minHeight: 21)
                Text("학교 홈 · 포털 · 도서관 링크를 AI가 찾아 드려요").font(NativeDesktopTheme.font(13)).lineSpacing(2.5).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 1.25)
            }
            // The picker opens on the AI search for this school's sites.
            NativeSchoolPickerButton(store: store, aiQuery: university["nameKo"] as? String, country: university["country"] as? String, arrowEdge: .leading) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 14)).accessibilityHidden(true)
                    Text("AI로 링크 찾기").font(NativeDesktopTheme.font(15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }.foregroundStyle(NativeDesktopTheme.onAccent).frame(maxWidth: .infinity).frame(height: 43)
                    .background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("AI로 링크 찾기").accessibilityIdentifier("native-university-find-links")
            Button("직접 추가") { onOpenSettings("university") }.buttonStyle(.plain).font(NativeDesktopTheme.font(14, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                .frame(height: 20).accessibilityIdentifier("native-university-add-links")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NativeDesktopTheme.border) }
    }
    /// The sidebar's glyphs for a portal and a library differ from the settings list's.
    private static func symbol(_ kind: String) -> String {
        switch kind { case "portal", "registration": "person.crop.square"; case "library": "books.vertical.fill"; default: NativeUniversityService.symbol(kind) }
    }
    private func serviceButton(_ service: NativeUniversityService) -> some View {
        Button {
            if service.opensExternally, let url = URL(string: service.url) { UIApplication.shared.open(url) }
            else { onOpenURL(service.url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(service.kind)).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 20)
                Text(service.label).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if service.opensExternally { Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(NativeGlass.panelTertiary) }
            }
        }.buttonStyle(NativeShortcutTileStyle())
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

/// A shortcut tile: 38 high, 12 radius, no fill until pressed.
private struct NativeShortcutTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.leading, 6).padding(.trailing, 2).frame(height: 38)
            .background(configuration.isPressed ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The pill on the line under the shortcuts: drag it to give the shortcuts more or less of the sidebar.
struct NativeSidebarSectionHandle: View {
    /// The stored limit; 0 keeps the automatic height.
    @Binding var limit: Double
    let current: CGFloat
    let content: CGFloat
    @State private var initial: CGFloat?
    static let minimum: CGFloat = 44
    var body: some View {
        Capsule().fill(NativeDesktopTheme.bgApp).overlay { Capsule().strokeBorder(NativeDesktopTheme.border) }.frame(width: 54, height: 14)
            .overlay { RoundedRectangle(cornerRadius: 2).fill(NativeDesktopTheme.muted).frame(width: 28, height: 4) }
            .frame(width: 54, height: 32).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { value in
                if initial == nil { initial = current }
                adjust((initial ?? current) + value.translation.height)
            }.onEnded { _ in initial = nil })
            .onTapGesture(count: 2) { limit = 0 }
            .onDisappear { initial = nil }
            .accessibilityElement().accessibilityLabel("바로가기 영역 높이 조절").accessibilityValue("\(Int(current))포인트")
            .accessibilityIdentifier("native-shortcuts-resizer")
            .accessibilityAdjustableAction { direction in adjust(current + (direction == .increment ? 24 : -24)) }
            .accessibilityAction(named: "기본 높이로") { limit = 0 }
    }
    private func adjust(_ value: CGFloat) { limit = Double(min(content, max(Self.minimum, value))) }
}
