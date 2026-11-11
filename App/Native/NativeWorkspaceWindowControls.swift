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
    let store: NativeWorkspaceStore
    /// The active tab, which 공유 hands on: a web page's link or a file.
    let shareDocument: NativeDocumentReference?

    /// Figma's three cells (128) and 공유 before them, which the owner moved here from the tab strip.
    static let width: CGFloat = 169
    static let trailing: CGFloat = 10
    static let top: CGFloat = 12
    static let inspectorTop: CGFloat = 61

    var body: some View {
        HStack(spacing: 0) {
            if let shareDocument { NativeDockShareControls(document: shareDocument, store: store, hidden: overview).padding(.leading, 5).disabled(!enabled || overview) }
            else { icon("square.and.arrow.up").padding(.leading, 5).opacity(0.35).accessibilityHidden(true) }
            Menu {
                Button { changeMode(.all) } label: { label("모두 표시", mode: .all) }
                Button { changeMode(.tabsHidden) } label: { label("탭만 숨김", mode: .tabsHidden) }
                Button { changeMode(.toolsHidden) } label: { label("탭·일반 도구 숨김", mode: .toolsHidden) }
                Text("펜·지우개 등 필기 도구는 유지됩니다.")
            } label: { icon("macwindow").padding(.leading, 5) }
                .disabled(!enabled || overview).accessibilityLabel("탭과 도구 표시")
                .accessibilityIdentifier("native-workspace-chrome-menu")
            Button(action: toggleOverview) { icon("rectangle.on.rectangle", selected: overview).padding(.leading, 5) }
                .disabled(!enabled).accessibilityLabel(overview ? "윈도우 관리 닫기" : "윈도우 관리")
                .accessibilityIdentifier("native-workspace-windows-toggle")
                // The inspector remains usable in overview. Keep Escape in the
                // window's command scope even when focus moves to that sibling.
                .keyboardShortcut(overview ? KeyboardShortcut(.escape, modifiers: []) : nil)
            Button(action: toggleInspector) { icon("sidebar.right", selected: rightVisible, width: 34).padding(.leading, 7).padding(.trailing, 5) }
                .disabled(overview).accessibilityLabel(rightVisible ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기")
                .accessibilityIdentifier("native-toggle-materials-rail")
        }
        .buttonStyle(.plain)
        .background(NativeGlass.selection.opacity(overview ? 0 : 1), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(NativeGlass.fieldStroke, lineWidth: 1).opacity(overview ? 0 : 1) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-workspace-controls")
    }

    /// Cells of 36 · 36 · 36 · 34 in a 169 × 40 group; the chosen one carries a 34 × 30 pill.
    /// The windows overview draws no group (Figma 132:2517): the cells stay, unseen, so the window button still closes it.
    private func icon(_ name: String, selected: Bool = false, width: CGFloat = 36) -> some View {
        Image(systemName: name).font(.system(size: 16))
            .foregroundStyle(selected ? NativeGlass.icon : NativeGlass.panelIcon)
            .frame(width: width, height: 40)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(NativeGlass.selection).frame(width: 34, height: 30) } }
            .opacity(overview ? 0 : 1).contentShape(Rectangle())
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

    /// Figma 132:2517: the whole window is paper; title at (64, 56), cards from y 200.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("윈도우").font(.system(size: 28, weight: .bold)).foregroundStyle(NativeDesktopTheme.text).frame(height: 33)
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Text("작업 화면을 나누고, 다른 곳에서 이어서 쓰세요")
                    .font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.secondary).frame(height: 19).padding(.top, 7)
                NativeWindowCardFlow(spacing: 40) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        card(window, index: index)
                            .onDrag { draggingID = window.id; return NSItemProvider(object: ("bandal-window:" + window.id) as NSString) }
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                guard !providers.isEmpty, let id = draggingID, id != window.id else { return false }
                                draggingID = nil; move(id, index); return true
                            }
                    }
                    Button(action: add) {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 30))
                            Text("새 창").font(.system(size: 16, weight: .medium))
                        }.foregroundStyle(NativeDesktopTheme.secondary).frame(width: 220, height: 368)
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 2, dash: [8, 6])) }
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityIdentifier("native-window-add")
                }.padding(.top, 85)
            }.padding(.leading, 64).padding(.trailing, 18).padding(.top, 56).padding(.bottom, 40).frame(maxWidth: .infinity, alignment: .leading)
        }.scaleEffect(settled || reduceMotion ? 1 : 1.08).opacity(settled ? 1 : 0)
            .background { ZStack { NativeWorkspaceBackdrop(); NativeGlass.paper }.ignoresSafeArea() }
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

    /// The card is the window's picture, 492 × 369; its name sits under it. Long press: move, rename, close.
    private func card(_ window: NativeWorkspaceWindow, index: Int) -> some View {
        let active = activeID == window.id, shape = RoundedRectangle(cornerRadius: 14)
        return VStack(alignment: .leading, spacing: 14) {
            Button { select(window.id) } label: {
                Group {
                    if let preview = image(window.id) {
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.split.2x1").font(.title2)
                            Text("아직 미리보기 없음").font(.callout)
                        }.foregroundStyle(NativeDesktopTheme.muted)
                    }
                }.frame(width: 492, height: 369, alignment: .top).background(NativeDesktopTheme.bgApp).clipShape(shape)
                    // The active card's 2-point stroke sits outside the picture, the others' hairline inside.
                    .overlay { if active { RoundedRectangle(cornerRadius: 16).strokeBorder(NativeDesktopTheme.accent, lineWidth: 2).padding(-2) } else { shape.strokeBorder(NativeDesktopTheme.border, lineWidth: 1) } }
                    .contentShape(shape).shadow(color: .black.opacity(0.14), radius: 15, y: 10)
            }.buttonStyle(.plain).accessibilityLabel(window.name + " 열기")
                .accessibilityIdentifier("native-window-open-" + window.id)
                .contextMenu {
                    Button("이름 변경", systemImage: "pencil") { renamingID = window.id }
                    Button("앞으로 이동", systemImage: "arrow.left") { move(window.id, index - 1) }.disabled(index == 0)
                    Button("뒤로 이동", systemImage: "arrow.right") { move(window.id, index + 1) }.disabled(index == windows.count - 1)
                    Button("윈도우 닫기", systemImage: "xmark", role: .destructive) { close(window.id) }.disabled(windows.count <= 1)
                }
            Group {
                if renamingID == window.id {
                    BandalInlineEditor(text: window.name, isEditing: .editing(window.id, in: $renamingID),
                                       font: .system(size: 16, weight: .semibold), identifier: "native-window-rename") { rename(window.id, $0) }
                } else {
                    Button { renamingID = window.id } label: {
                        Text(Self.title(window.name, caption: caption(window.id))).font(.system(size: 16, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(window.name + " 이름 변경")
                }
            }.frame(width: 492, height: 19, alignment: .leading)
        }.accessibilityElement(children: .contain)
    }
}

/// Cards of different widths in rows, left to right, wrapping when the row is full.
private struct NativeWindowCardFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    private func place(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
