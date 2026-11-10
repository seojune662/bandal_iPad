import SwiftUI
import UniformTypeIdentifiers

private struct NativeWorkspaceTargetEnvironmentKey: EnvironmentKey {
    static let defaultValue: NativeWorkspaceTarget? = nil
}
extension EnvironmentValues {
    var nativeWorkspaceTarget: NativeWorkspaceTarget? {
        get { self[NativeWorkspaceTargetEnvironmentKey.self] }
        set { self[NativeWorkspaceTargetEnvironmentKey.self] = newValue }
    }
}

/// Owned by the app shell, independently of the selected pane and inspector.
struct NativeWorkspaceWindowControls: View {
    let mode: NativeWorkspaceChromeMode
    let overview: Bool
    let rightVisible: Bool
    let enabled: Bool
    let changeMode: (NativeWorkspaceChromeMode) -> Void
    let toggleOverview: () -> Void
    let toggleInspector: () -> Void

    static let width: CGFloat = 140
    static let trailing: CGFloat = 4
    static let top: CGFloat = 16
    static let inspectorTop: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button { changeMode(.all) } label: { label("모두 표시", mode: .all) }
                Button { changeMode(.tabsHidden) } label: { label("탭만 숨김", mode: .tabsHidden) }
                Button { changeMode(.toolsHidden) } label: { label("탭·일반 도구 숨김", mode: .toolsHidden) }
                Text("펜·지우개 등 필기 도구는 유지됩니다.")
            } label: { icon("rectangle.topthird.inset.filled") }
                .disabled(!enabled).accessibilityLabel("탭과 도구 표시")
                .accessibilityIdentifier("native-workspace-chrome-menu")
            Button(action: toggleOverview) { icon("rectangle.on.rectangle", selected: overview) }
                .disabled(!enabled).accessibilityLabel(overview ? "윈도우 관리 닫기" : "윈도우 관리")
                .accessibilityIdentifier("native-workspace-windows-toggle")
                // The inspector remains usable in overview. Keep Escape in the
                // window's command scope even when focus moves to that sibling.
                .keyboardShortcut(overview ? KeyboardShortcut(.escape, modifiers: []) : nil)
            Button(action: toggleInspector) { icon("sidebar.right", selected: rightVisible) }
                .accessibilityLabel(rightVisible ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기")
                .accessibilityIdentifier("native-toggle-materials-rail")
        }
        .buttonStyle(.plain).padding(.horizontal, 4)
        .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border, lineWidth: 1) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-workspace-controls")
    }

    private func icon(_ name: String, selected: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
            .frame(width: 44, height: 44)
            .background(selected ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
    @ViewBuilder private func label(_ title: String, mode value: NativeWorkspaceChromeMode) -> some View {
        if mode == value { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct NativeWorkspaceWindowsOverview: View {
    let windows: [NativeWorkspaceWindow]
    let activeID: String?
    let image: (String) -> UIImage?
    /// What a window holds, e.g. "디자인 스튜디오 · 3주차 노트" or "eTL 강좌 + 노트"; shown while the window still has its numbered name.
    var caption: (String) -> String? = { _ in nil }
    let select: (String) -> Void
    let add: () -> Void
    let rename: (String, String) -> Void
    let move: (String, Int) -> Void
    let close: (String) -> Void
    let dismiss: () -> Void
    @State private var renamingID: String?
    @State private var draggingID: String?
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var overviewFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The cards start slightly large and settle, so opening reads as the window zooming out into its card.
    @State private var settled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("윈도우").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Text("작업 화면을 나누고, 다른 곳에서 이어서 쓰세요")
                            .font(.callout).foregroundStyle(NativeDesktopTheme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("윈도우 관리 닫기")
                        .accessibilityIdentifier("native-windows-overview-close")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 18) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        card(window, index: index)
                            .onDrag { draggingID = window.id; return NSItemProvider(object: ("bandal-window:" + window.id) as NSString) }
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                guard !providers.isEmpty, let id = draggingID, id != window.id else { return false }
                                draggingID = nil; move(id, index); return true
                            }
                    }
                    Button(action: add) {
                        VStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 30, weight: .light))
                            Text("새 창").font(.body.weight(.medium))
                        }.frame(maxWidth: .infinity).frame(height: 190)
                            .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5])) }
                    }.buttonStyle(.plain).accessibilityIdentifier("native-window-add")
                }
            }.padding(20).padding(.top, NativeWorkspaceWindowControls.inspectorTop)
        }.scaleEffect(settled || reduceMotion ? 1 : 1.08).opacity(settled ? 1 : 0)
            .background(NativeDesktopTheme.bgApp)
            .focusable()
            .focusEffectDisabled()
            .focused($overviewFocused)
            .onKeyPress(.escape) { dismiss(); return .handled }
            .accessibilityAction(.escape) { dismiss() }
            .accessibilityIdentifier("native-windows-overview")
            .onAppear { headingFocused = true; overviewFocused = true; withAnimation(.easeOut(duration: 0.22)) { settled = true } }
    }

    /// "과목 · 문서" for one pane, "문서 + 문서" for a split (the front tab of each pane); nil when nothing is open.
    static func caption(course: String, titles: [String]) -> String? {
        let titles = titles.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        guard let first = titles.first else { return nil }
        if titles.count == 1 { return course + " · " + first }
        return titles.prefix(2).joined(separator: " + ") + (titles.count > 2 ? " 외 \(titles.count - 2)" : "")
    }

    /// A window the user named keeps that name; "윈도우 N" gives way to what the window holds.
    static func title(_ name: String, caption: String?) -> String {
        guard let caption, !caption.isEmpty, name.hasPrefix("윈도우 "), Int(name.dropFirst(4)) != nil else { return name }
        return caption
    }

    private func card(_ window: NativeWorkspaceWindow, index: Int) -> some View {
        VStack(spacing: 0) {
            Button { select(window.id) } label: {
                ZStack(alignment: .bottomLeading) {
                    if let preview = image(window.id) {
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity).frame(height: 146)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.split.2x1").font(.title2)
                            Text("아직 미리보기 없음").font(.callout)
                        }.foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).frame(height: 146)
                    }
                    if activeID == window.id {
                        Text("현재 윈도우").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule()).padding(10)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(window.name + " 열기")
                .accessibilityIdentifier("native-window-open-" + window.id)
            HStack(spacing: 0) {
                if renamingID == window.id {
                    BandalInlineEditor(text: window.name, isEditing: .editing(window.id, in: $renamingID),
                                       font: .callout.weight(.medium), identifier: "native-window-rename") { rename(window.id, $0) }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    Button { renamingID = window.id } label: {
                        Text(Self.title(window.name, caption: caption(window.id))).font(.callout.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(window.name + " 이름 변경")
                }
                Menu {
                    Button("앞으로 이동", systemImage: "arrow.left") { move(window.id, index - 1) }.disabled(index == 0)
                    Button("뒤로 이동", systemImage: "arrow.right") { move(window.id, index + 1) }.disabled(index == windows.count - 1)
                    Button("윈도우 닫기", systemImage: "xmark", role: .destructive) { close(window.id) }.disabled(windows.count <= 1)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(window.name + " 관리").accessibilityIdentifier("native-window-actions-" + window.id)
            }.padding(.leading, 12)
        }.background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(activeID == window.id ? NativeDesktopTheme.accent : NativeDesktopTheme.border, lineWidth: activeID == window.id ? 2 : 1) }
            .accessibilityElement(children: .contain)
    }
}
