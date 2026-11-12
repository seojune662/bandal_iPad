import SwiftUI

/// What the sidebar may do with the open folder's windows. Each is the same action the full-screen overview
/// (the window button at the top right) offers; the sidebar only puts them a tap away.
struct NativeSidebarWindowActions {
    let select: (String) -> Void
    let add: () -> Void
    let rename: (String, String) -> Void
    let move: (String, Int) -> Void
    let close: (String) -> Void
}

/// A folder's windows, listed under it in the sidebar: tap one to switch to it, ＋ for a new one, long press
/// to rename, reorder or close. A window still called "윈도우 N" is shown by what it holds.
struct NativeSidebarWindowsSection: View {
    let windows: [NativeWorkspaceWindow]
    let activeID: String?
    /// The front tab of each pane of the window with this id.
    let titles: (String) -> [String]
    /// How many tabs that window holds.
    let tabCount: (String) -> Int
    let actions: NativeSidebarWindowActions
    @State private var renamingID: String?
    @State private var closingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("윈도우").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted)
                Spacer(minLength: 0)
                Button(action: actions.add) { Image(systemName: "plus").font(.system(size: 11)).frame(width: 32, height: 32).padding(6).contentShape(Rectangle()).padding(-6) }
                    .buttonStyle(.plain).foregroundStyle(NativeGlass.panelIcon)
                    .accessibilityLabel("새 윈도우").accessibilityIdentifier("native-sidebar-window-add")
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in row(window, index: index) }
        }.padding(.leading, 34).padding(.trailing, 8)
            // The guide line of an open folder, down from its chevron.
            .overlay(alignment: .leading) { NativeGlass.treeGuide.frame(width: 1).padding(.leading, 19).allowsHitTesting(false) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-sidebar-windows")
    }

    /// The window's own name once the user gave it one; until then the front tabs of its panes ("노트 + eTL").
    static func title(_ name: String, titles: [String]) -> String {
        let titles = titles.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        guard !titles.isEmpty, name.hasPrefix("윈도우 "), Int(name.dropFirst(4)) != nil else { return name }
        return titles.prefix(2).joined(separator: " + ") + (titles.count > 2 ? " 외 \(titles.count - 2)" : "")
    }

    @ViewBuilder private func row(_ window: NativeWorkspaceWindow, index: Int) -> some View {
        let active = window.id == activeID, title = Self.title(window.name, titles: titles(window.id)), count = tabCount(window.id)
        if renamingID == window.id {
            BandalInlineEditor(text: window.name, isEditing: .editing(window.id, in: $renamingID),
                               font: NativeDesktopTheme.font(12), identifier: "native-sidebar-window-rename") { actions.rename(window.id, $0) }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        } else {
            Button { actions.select(window.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(active ? AnyShapeStyle(NativeGlass.accent) : AnyShapeStyle(NativeGlass.panelIcon)).frame(width: 16)
                    Text(verbatim: title).font(NativeDesktopTheme.font(12, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? NativeGlass.icon : NativeDesktopTheme.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if count > 0 { Text(verbatim: "\(count)").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted) }
                }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(title).accessibilityValue(active ? "현재 윈도우" : "").accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("native-sidebar-window-" + window.id)
                .contextMenu {
                    Button("이름 변경", systemImage: "pencil") { renamingID = window.id }
                    Button("위로 이동", systemImage: "arrow.up") { actions.move(window.id, index - 1) }.disabled(index == 0)
                    Button("아래로 이동", systemImage: "arrow.down") { actions.move(window.id, index + 1) }.disabled(index == windows.count - 1)
                    Button("윈도우 닫기", systemImage: "xmark", role: .destructive) { closingID = window.id }.disabled(windows.count <= 1)
                }
                .bandalConfirm("윈도우를 지울까요?", isPresented: Binding(get: { closingID == window.id }, set: { if !$0, closingID == window.id { closingID = nil } }),
                               message: "열려 있던 탭만 닫혀요. 파일은 폴더에 그대로 있어요.", action: "삭제", destructive: true,
                               identifier: "native-sidebar-window-close-confirm") { actions.close(window.id) }
        }
    }
}
