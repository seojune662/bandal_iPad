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
    let select: (String) -> Void
    let add: () -> Void
    let rename: (String, String) -> Void
    let move: (String, Int) -> Void
    let close: (String) -> Void
    let dismiss: () -> Void
    @State private var renamingID: String?
    @State private var name = ""
    @State private var draggingID: String?
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var overviewFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("윈도우").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Text("작업 화면을 나누고, 하던 곳에서 이어가세요.")
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
                            Image(systemName: "plus.circle").font(.system(size: 34, weight: .light))
                            Text("윈도우 추가").font(.body.weight(.medium))
                        }.frame(maxWidth: .infinity).frame(height: 190)
                            .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5])) }
                    }.buttonStyle(.plain).accessibilityIdentifier("native-window-add")
                }
            }.padding(20).padding(.top, NativeWorkspaceWindowControls.inspectorTop)
        }.background(NativeDesktopTheme.bgApp)
            .focusable()
            .focusEffectDisabled()
            .focused($overviewFocused)
            .onKeyPress(.escape) { dismiss(); return .handled }
            .accessibilityAction(.escape) { dismiss() }
            .accessibilityIdentifier("native-windows-overview")
            .onAppear { headingFocused = true; overviewFocused = true }
            .alert("윈도우 이름", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
                TextField("이름", text: $name)
                Button("취소", role: .cancel) { renamingID = nil }
                Button("저장") {
                    if let id = renamingID { rename(id, name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    renamingID = nil
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
                Button { name = window.name; renamingID = window.id } label: {
                    Text(window.name).font(.callout.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(window.name + " 이름 변경")
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
