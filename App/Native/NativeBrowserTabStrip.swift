import SwiftUI
import UIKit

/// Website popups and inner tabs use the same adaptive sizing as document tabs.
/// A narrow strip keeps the active page visible and exposes every page in a list.
struct NativeBrowserTabStrip: View {
    let tabs: [NativeBrowserTab]
    let activeID: String?
    let select: (String) -> Void
    let close: (String) -> Void
    let add: () -> Void
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @State private var showingList = false
    @State private var pendingClose: String?

    var body: some View {
        GeometryReader { geometry in
            let sizing = NativeDockTabSizing(availableWidth: max(0, geometry.size.width - 96), count: tabs.count,
                activeIndex: tabs.firstIndex { $0.id == activeID } ?? -1)
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(sizing.visibleIndices.map { tabs[$0] }) { tab in
                        item(tab, sizing: sizing)
                    }
                }.frame(width: sizing.totalWidth, height: 44, alignment: .leading).clipped()
                Spacer(minLength: 0)
                Button(action: add) { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("새 탭").accessibilityIdentifier("native-browser-add-tab")
                Button { showingList = true } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("브라우저의 열린 탭 \(tabs.count)개").accessibilityIdentifier("native-browser-tabs-list")
            }.padding(.horizontal, 4).buttonStyle(.plain).font(.system(size: 13))
        }.frame(height: 44).clipped().background(NativeDesktopTheme.surface)
            .foregroundStyle(NativeDesktopTheme.text)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .sheet(isPresented: $showingList, onDismiss: finishClose) {
                NativeBrowserTabList(tabs: tabs, activeID: activeID,
                    select: { id in select(id); showingList = false },
                    close: { id in pendingClose = id; showingList = false })
            }
    }

    private func item(_ tab: NativeBrowserTab, sizing: NativeDockTabSizing) -> some View {
        HStack(spacing: 0) {
            NativeBrowserTabButton(tab: tab, selected: tab.id == activeID, density: sizing.density, fontScale: fontScale,
                select: { select(tab.id) }, close: { close(tab.id) })
                .frame(width: sizing.width - (sizing.showsClose ? 44 : 0), height: 44).clipped()
            if sizing.showsClose {
                Button { close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(Self.title(tab) + " 닫기")
                    .accessibilityIdentifier("native-browser-close-tab-" + tab.id)
            }
        }.frame(width: sizing.width, height: 44).clipped()
            .nativeWorkspacePreviewSurface(id: "browser-tab-" + tab.id, privateContent: { tab.isPrivate })
            .background(tab.id == activeID ? NativeDesktopTheme.raised : .clear)
            .overlay(alignment: .trailing) { NativeDesktopTheme.border.frame(width: 1).padding(.vertical, 8) }
            .contextMenu {
                Button("탭 닫기", systemImage: "xmark") { close(tab.id) }
                    .accessibilityIdentifier("native-browser-context-close-tab")
            }
    }
    private func finishClose() {
        guard let id = pendingClose else { return }; pendingClose = nil
        // beforeunload may present a confirmation. The list must finish dismissal
        // before asking the website whether its unsaved form can be closed.
        if tabs.contains(where: { $0.id == id }) { close(id) }
    }
    fileprivate static func title(_ tab: NativeBrowserTab) -> String {
        let value = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return tab.url == "about:blank" || tab.url.isEmpty ? "새 탭" : NativeBrowserAddress.display(tab.url)
    }
}

private struct NativeBrowserTabButton: UIViewRepresentable {
    let tab: NativeBrowserTab
    let selected: Bool
    let density: NativeDockTabSizing.Density
    let fontScale: Double
    let select: () -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> NativeDockTabButton {
        let button = NativeDockTabButton(frame: .zero)
        button.addTarget(context.coordinator, action: #selector(Coordinator.select), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: NativeDockTabButton, context: Context) {
        context.coordinator.parent = self
        button.configure(title: NativeBrowserTabStrip.title(tab), symbol: tab.isPrivate ? "hand.raised" : "globe",
            density: density, fontScale: fontScale, selected: selected)
        button.accessibilityIdentifier = "native-browser-tab-" + tab.id
        button.accessibilityHint = tab.isPrivate ? "개인정보 보호 탭" : nil
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "탭 닫기", target: context.coordinator, selector: #selector(Coordinator.close))]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeDockTabButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: 44)
    }
    final class Coordinator: NSObject {
        var parent: NativeBrowserTabButton
        init(_ parent: NativeBrowserTabButton) { self.parent = parent }
        @objc func select() { parent.select() }
        @objc func close() -> Bool { parent.close(); return true }
    }
}

private struct NativeBrowserTabList: View {
    let tabs: [NativeBrowserTab]
    let activeID: String?
    let select: (String) -> Void
    let close: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var matches: [NativeBrowserTab] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.filter { value.isEmpty || NativeBrowserTabStrip.title($0).localizedCaseInsensitiveContains(value) || $0.url.localizedCaseInsensitiveContains(value) }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { tab in
                    HStack(spacing: 0) {
                        Button { select(tab.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.isPrivate ? "hand.raised" : "globe").frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(NativeBrowserTabStrip.title(tab)).lineLimit(3)
                                    if tab.url != "about:blank" { Text(NativeBrowserAddress.display(tab.url)).font(.caption).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if tab.id == activeID { Image(systemName: "checkmark") }
                            }.multilineTextAlignment(.leading).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(tab.id == activeID ? .isSelected : [])
                            .accessibilityIdentifier("native-browser-tab-list-select-" + tab.id)
                        Button { close(tab.id) } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel(NativeBrowserTabStrip.title(tab) + " 닫기")
                            .accessibilityIdentifier("native-browser-tab-list-close-" + tab.id)
                    }
                }
                if matches.isEmpty { ContentUnavailableView("일치하는 탭이 없습니다", systemImage: "magnifyingglass") }
            }.navigationTitle("열린 탭 \(tabs.count)개").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "제목 또는 주소로 탭 검색")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() }.accessibilityIdentifier("native-browser-tabs-done") } }
        }.presentationDetents([.medium, .large])
    }
}
