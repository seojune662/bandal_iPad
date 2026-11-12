import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers

enum NativeDockDragPayload {
    static let contentType = UTType(exportedAs: "app.bandal.workspace-tab", conformingTo: .data)
    static func provider(documentID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(documentID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    static func trace(_ message: String) {
        if NativeInputTrace.isEnabled { Task { @MainActor in NativeInputTrace.record("dock.drag", message) } }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-testing") { NSLog("[bandal.dock] %@", message) }
        #endif
    }
}

@MainActor
private final class NativeDockDragSession: ObservableObject {
    struct Transfer: Equatable { let documentID: String; let courseID: String }
    struct Target: Equatable { let groupID: String; let direction: NativeDockDirection; let index: Int? }
    @Published var transfer: Transfer?
    @Published var target: Target?
    /// The system's session for `transfer`. UIKit keeps it alive only while the drag runs, so a transfer
    /// whose session is gone lost its end callback (the source tab was torn down mid-drag).
    weak var source: UIDragSession?
    var isStale: Bool { transfer != nil && source == nil }
    func end() { transfer = nil; target = nil; source = nil }
}

/// Frames are projected from the recursive tree, but editor views live in a flat
/// stable-ID layer. Splitting or moving a tab therefore never reparents its editor.
private struct NativeEditorVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False while a retained editor is hidden (another tab is active, or a
    /// section screen covers the dock). Editors suspend rendering, not state.
    var nativeEditorVisible: Bool { get { self[NativeEditorVisibleKey.self] } set { self[NativeEditorVisibleKey.self] = newValue } }
}

struct NativeDockWorkspace<Content: View, Empty: View>: View {
    @ObservedObject var navigation: NativeWorkspaceNavigation
    var store: NativeWorkspaceStore
    let content: (NativeDocumentReference) -> Content
    let empty: () -> Empty
    let perform: (@escaping @MainActor () -> Void) -> Void
    let persist: () -> Void
    let closeDocuments: ([String]) -> Void
    let materialsOpen: Bool
    let toggleMaterials: () -> Void
    let openNewTab: (NativeNewTabAction, String) -> Void
    /// The dock stays mounted behind Settings/Help/Learning; editors are hidden, not rebuilt.
    var covered = false
    /// Tab taps that need no global flush (retained editors). nil falls back to `perform`.
    var select: ((String, String) -> Void)? = nil
    var chromeMode: NativeWorkspaceChromeMode = .all
    var controlInset: CGFloat = 0
    @StateObject private var drag = NativeDockDragSession()
    @Environment(\.nativeDecor) private var decor
    @Environment(\.colorScheme) private var scheme
    @State private var maximizedGroupID: String?
    @State private var newTabGroupID: String?
    @State private var tabListGroupID: String?
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @AppStorage("native.density") private var density = "comfortable"

    /// Figma 129:1460: the home screen (one pane, nothing open) has no tab strip.
    private func isHome(_ group: NativeDockGroup) -> Bool { navigation.groups.count == 1 && group.tabs.isEmpty }
    private static var topEdge: NativeDockTopEdge { NativeDockHeaderMetrics.topEdge }
    private func contentFrame(_ pane: NativeDockPaneFrame, _ metrics: NativeDockStripMetrics) -> CGRect {
        isHome(pane.group) ? pane.frame : NativeDockHeaderMetrics.contentFrame(for: pane.frame, controlsHeight: chromeMode.showsTabs ? metrics.total : 0, topEdge: Self.topEdge)
    }
    var body: some View {
        dockBody.onReceive(store.events) { event in
            if event.channel == "nativeDock:newTab", let id = (event.payload as? [String: Any])?["groupID"] as? String { newTabGroupID = id }
        }
    }
    private var dockBody: some View {
        GeometryReader { proxy in
            if let layout = navigation.layout {
                let requiresFocus = layout.root.minimumSize.width > proxy.size.width || layout.root.minimumSize.height > proxy.size.height
                let focusMode = layout.groups.count > 1 && (requiresFocus || maximizedGroupID != nil)
                let selected = maximizedGroupID.flatMap { id in layout.groups.first { $0.id == id } } ?? layout.focused!
                let selectorHeight: CGFloat = focusMode && chromeMode.showsTabs ? 44 : 0
                let bounds = CGRect(x: 0, y: selectorHeight, width: proxy.size.width, height: max(0, proxy.size.height - selectorHeight))
                let geometry = focusMode ? NativeDockGeometry(panes: [.init(group: selected, frame: bounds)]) : layout.geometry(in: bounds)
                let metrics = layout.groups.count > 1 && focusMode ? NativeDockStripMetrics.columns : NativeDockStripMetrics.resolve(paneFrames: geometry.panes.map(\.frame), bounds: bounds)
                ZStack(alignment: .topLeading) {
                    // Sizes the stack. With panes side by side it also tracks the last touch, so 공유 and the
                    // other window controls act on the pane the user last worked in, whatever the editor
                    // (PDFKit, Pencil and text views swallow the SwiftUI tap below).
                    NativeDockTouchFocus(panes: geometry.panes.count > 1 && !covered ? geometry.panes.map { ($0.group.id, $0.frame) } : []) { id in
                        if navigation.layout?.focusedGroupID != id { focus(id) }
                    }
                    // Each pane's paper: a card on the glass with its chosen tab joined to it like a folder's tab.
                    ForEach(geometry.panes) { pane in
                        paneSurface(pane, metrics: metrics, focused: layout.groups.count > 1 && pane.group.id == layout.focusedGroupID,
                                    corner: pane.frame.maxX >= bounds.maxX - 1 && pane.frame.minY <= bounds.minY + 1)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .position(x: pane.frame.midX, y: pane.frame.midY)
                            .allowsHitTesting(false)
                    }
                    ForEach(geometry.panes) { pane in
                        paneChrome(pane, metrics: metrics,
                                   corner: pane.frame.maxX >= bounds.maxX - 1 && pane.frame.minY <= bounds.minY + 1)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .position(x: pane.frame.midX, y: pane.frame.midY)
                    }
                    // Do not nest these in pane chrome: an editor retains identity
                    // when the same document moves to another group or the tree changes.
                    ForEach(visibleDocuments(geometry, layout: layout, bounds: bounds, metrics: metrics)) { entry in
                        let card = Self.cardFrame(entry.frame)
                        content(entry.document)
                            .environment(\.nativeEditorVisible, entry.visible && !covered)
                            .environment(\.nativeWorkspaceChromeMode, chromeMode)
                            .environment(\.nativeWorkspaceControlInset, !chromeMode.showsTabs && entry.frame.minY <= 16.5 && entry.frame.maxX >= bounds.maxX - 1 ? controlInset : 0)
                            .frame(width: card.width, height: card.height)
                            .background {
                                if Self.retainsEditor(entry.document) {
                                    NativeDockEditorVisibility(isVisible: entry.visible && !covered)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
                            .opacity(entry.visible ? 1 : 0)
                            .allowsHitTesting(entry.visible && !covered)
                            .accessibilityHidden(!entry.visible || covered)
                            .simultaneousGesture(TapGesture().onEnded { focus(entry.groupID) })
                            .position(x: card.midX, y: card.midY)
                    }
                    ForEach(geometry.panes.filter { $0.group.activeID == nil }) { pane in
                        let frame = isHome(pane.group) ? contentFrame(pane, metrics) : Self.cardFrame(contentFrame(pane, metrics))
                        emptyPane(pane.group, groupCount: layout.groups.count)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    ForEach(geometry.dividers) { divider in
                        NativeDockDivider(divider: divider, wide: metrics == .columns,
                            topInset: metrics == .columns && chromeMode.showsTabs ? NativeDockHeaderMetrics.height(for: divider.frame, controlsHeight: metrics.total, topEdge: Self.topEdge) : 0,
                            grip: Self.gripCenter(divider, in: geometry), change: { navigation.resize(divider.id, fraction: $0) }, persist: persist)
                            .frame(width: divider.hitFrame.width, height: divider.hitFrame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                    ForEach(geometry.panes) { pane in
                        let frame = contentFrame(pane, metrics)
                        paneDropZones(pane)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    if selectorHeight > 0 {
                        paneSelector(layout, compact: requiresFocus)
                            .padding(.trailing, controlInset)
                            .frame(width: proxy.size.width, height: selectorHeight)
                            .position(x: proxy.size.width / 2, y: selectorHeight / 2)
                    }
                }
                .clipped()
                .onChange(of: layout.groups.map(\.id)) { _, _ in
                    // A structural split/merge exits maximize, as the desktop
                    // layout application does. Compact mode still follows focus.
                    maximizedGroupID = nil
                }
                .onChange(of: layout.focusedGroupID) { _, id in
                    if maximizedGroupID != nil { maximizedGroupID = id }
                }
            } else { empty() }
        }
        .onChange(of: navigation.currentWindowRef) { _, _ in NativeInputTrace.record("dock.reset", "window changed"); drag.end(); maximizedGroupID = nil; newTabGroupID = nil; tabListGroupID = nil }
        .onChange(of: chromeMode) { _, _ in NativeInputTrace.record("dock.reset", "chrome mode changed"); drag.end(); newTabGroupID = nil; tabListGroupID = nil }
        .onChange(of: newTabGroupID) { old, new in NativeInputTrace.record("dock.newTabGroup", "\(old == nil ? "nil" : "set")→\(new == nil ? "nil" : "set")") }
        .allowsHitTesting(!covered).accessibilityHidden(covered)
    }

    struct VisibleDocument: Identifiable {
        var document: NativeDocumentReference; var groupID: String; var frame: CGRect; var visible: Bool
        var id: String { document.id }
    }
    private func visibleDocuments(_ geometry: NativeDockGeometry, layout: NativeDockLayout, bounds: CGRect, metrics: NativeDockStripMetrics) -> [VisibleDocument] {
        Self.projectDocuments(navigation.documents, geometry: geometry, layout: layout, bounds: bounds, headerHeight: chromeMode.showsTabs ? metrics.total : 0)
    }
    /// Where a seam's grip sits along it (Figma 130:6137): beside the first pane it borders,
    /// and seams that continue one another across a split share the first one's grip.
    static func gripCenter(_ divider: NativeDockDividerFrame, in geometry: NativeDockGeometry) -> CGFloat? {
        let horizontal = divider.split.axis == .horizontal, frame = divider.frame
        func along(_ rect: CGRect) -> CGFloat { horizontal ? rect.minY : rect.minX }
        func across(_ rect: CGRect) -> CGFloat { horizontal ? rect.minX : rect.minY }
        let continues = geometry.dividers.contains { other in
            other.id != divider.id && other.split.axis == divider.split.axis && abs(across(other.frame) - across(frame)) < 1 && along(other.frame) < along(frame)
        }
        if continues { return nil }
        let start = along(frame), end = horizontal ? frame.maxY : frame.maxX
        let beside = geometry.panes.map(\.frame).filter { pane in
            let edge: CGFloat = horizontal ? pane.maxX : pane.maxY, low = along(pane), high: CGFloat = horizontal ? pane.maxY : pane.maxX
            return abs(edge - across(frame)) < 1 && low >= start - 1 && high <= end + 1
        }
        let first = beside.min { along($0) < along($1) }
        return first.map { horizontal ? $0.midY - frame.minY : $0.midX - frame.minX } ?? (horizontal ? frame.height : frame.width) / 2
    }
    static func retainsEditor(_ document: NativeDocumentReference) -> Bool {
        // PDF warm-retention is deferred: a resumed (offscreen-then-shown) PDFKit view
        // swallows the UIKit tab drag-drop, so switching PDFs relies on the fast open()
        // path (PDFOriginals + hash cache + deferred page history) instead. Markdown
        // keeps live retention: UIKit owns its selection, composition and per-pane undo.
        // Whiteboard owns local tools/history, and learning owns card disclosure
        // and answer focus. A window switch must not end those panel sessions.
        return document.kind == "note" || document.kind == "whiteboard" || document.kind == "learning"
            || document.learningTarget != nil || ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())
    }
    static func projectDocuments(_ documents: [NativeDocumentReference], geometry: NativeDockGeometry, layout: NativeDockLayout,
                                 bounds: CGRect, headerHeight: CGFloat = NativeDockStripMetrics.single.total, topEdge: NativeDockTopEdge? = nil) -> [VisibleDocument] {
        let topEdge = topEdge ?? Self.topEdge
        // Compact mode hides other groups without ending their editor session.
        // Rotation or maximizing a pane must not race an asynchronous draft flush.
        let projected = layout.geometry(in: bounds)
        var result: [VisibleDocument] = projected.panes.compactMap { original in
            guard let document = documents.first(where: { $0.id == original.group.activeID }) else { return nil }
            let visible = geometry.panes.first { $0.id == original.id }
            let frame = visible?.frame ?? CGRect(x: -10000, y: -10000, width: max(280, original.frame.width), height: max(220, original.frame.height))
            let inset = NativeDockHeaderMetrics.height(for: visible?.frame ?? original.frame, controlsHeight: headerHeight, topEdge: topEdge)
            return VisibleDocument(document: document, groupID: original.id,
                frame: CGRect(x: frame.minX, y: frame.minY + inset, width: frame.width, height: max(0, frame.height - inset)), visible: visible != nil)
        }
        let activeIDs = Set(result.map(\.id))
        // Keep panel-local editor state alive until its tab is actually closed,
        // including while another window/course is active. Hidden panels cannot
        // receive UIKit input. PDF retains its existing checkpoint path.
        for document in documents where retainsEditor(document) && !activeIDs.contains(document.id) {
            let original = projected.panes.first { $0.group.tabs.contains(document.id) }
            let inset = NativeDockHeaderMetrics.height(for: original?.frame ?? bounds, controlsHeight: headerHeight, topEdge: topEdge)
            result.append(VisibleDocument(document: document, groupID: original?.id ?? "",
                frame: CGRect(x: -10000, y: -10000, width: max(280, original?.frame.width ?? bounds.width),
                              height: max(220, (original?.frame.height ?? bounds.height) - inset)), visible: false))
        }
        return result
    }
    private func selectTab(_ id: String, in groupID: String) {
        if let select { select(id, groupID) } else { perform { navigation.select(id, in: groupID) } }
    }
    private func paneChrome(_ pane: NativeDockPaneFrame, metrics: NativeDockStripMetrics, corner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if chromeMode.showsTabs {
                // Out of sight on the home screen, yet still the anchor of the new-tab menu for VoiceOver, keyboards and tests.
                if isHome(pane.group) { addButton(pane.group, metrics: metrics, visible: false).padding(.top, NativeDockHeaderMetrics.topPadding(for: pane.frame, topEdge: Self.topEdge)) }
                else { tabs(pane.group, metrics: metrics, topPadding: NativeDockHeaderMetrics.topPadding(for: pane.frame, topEdge: Self.topEdge), corner: corner) }
            }
            Spacer(minLength: 0)
        }
    }
    private static var listWidth: CGFloat { 24 }
    private static func addWidth(_ metrics: NativeDockStripMetrics) -> CGFloat { metrics.gap + metrics.plus + 4 }
    static func symbol(_ document: NativeDocumentReference, split: Bool) -> String {
        if ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased()) { return "square.and.pencil" }
        switch document.kind {
        // Figma 269:8464 draws a PDF with the pencil; the split frames (130:5992) draw it as a file.
        case "pdf": return split ? "doc" : "pencil"
        case "note": return "square.and.pencil"
        case "whiteboard": return "rectangle.and.pencil.and.ellipsis"
        case "browser": return "globe"
        case "assistant": return "sparkles"
        case "recordings": return "waveform"
        case "planner": return "checklist"
        default: return "doc"
        }
    }
    private func sizing(_ group: NativeDockGroup, metrics: NativeDockStripMetrics, available: CGFloat) -> NativeDockTabSizing {
        let split = navigation.groups.count > 1
        let widths = group.tabs.map { id in
            navigation.document(id).map { NativeDockTabButton.naturalWidth(title: $0.title, symbol: Self.symbol($0, split: split), metrics: metrics, fontScale: fontScale, selected: id == group.activeID) } ?? 44
        }
        return NativeDockTabSizing(availableWidth: max(0, available), naturalWidths: widths,
            activeIndex: group.tabs.firstIndex(of: group.activeID ?? "") ?? -1, spacing: density == "compact" ? 0 : metrics.gap)
    }
    /// How a strip `width` wide sizes its tabs, and whether it keeps the open-tabs list.
    private func stripSizing(_ group: NativeDockGroup, metrics: NativeDockStripMetrics, width: CGFloat, corner: Bool) -> (sizing: NativeDockTabSizing, showsList: Bool) {
        let split = navigation.groups.count > 1
        let inset = corner ? controlInset : 0
        let room = width - metrics.padding - Self.addWidth(metrics) - 8 - (split ? 44 : 0) - inset
        let roomy = sizing(group, metrics: metrics, available: room - (split ? 0 : Self.listWidth))
        // The list of open tabs stays in a split pane only while some of its tabs do not fit.
        let showsList = !split || roomy.visibleIndices.count < group.tabs.count
        return (split && showsList ? sizing(group, metrics: metrics, available: room - Self.listWidth) : roomy, showsList)
    }
    /// The chosen tab's span in the strip (from the pane's left edge), when it is on screen.
    private func selectedTabSpan(_ group: NativeDockGroup, metrics: NativeDockStripMetrics, width: CGFloat, corner: Bool) -> (x: CGFloat, width: CGFloat)? {
        let sizing = stripSizing(group, metrics: metrics, width: width, corner: corner).sizing
        guard let active = group.activeID, let index = group.tabs.firstIndex(of: active), let position = sizing.visibleIndices.firstIndex(of: index) else { return nil }
        let before = sizing.visibleIndices.prefix(position).reduce(CGFloat(0)) { $0 + sizing.width(of: $1) + sizing.spacing }
        return (metrics.padding + before, sizing.width(of: index))
    }
    // MARK: Card
    static var cardInset: CGFloat { NativeDockCard.inset }
    static var cardRadius: CGFloat { NativeDockCard.radius }
    /// The paper inside a pane's content area: in from the sides and bottom, flush with the strip on top.
    static func cardFrame(_ content: CGRect) -> CGRect {
        CGRect(x: content.minX + cardInset, y: content.minY, width: max(0, content.width - cardInset * 2), height: max(0, content.height - cardInset))
    }
    /// The card and its chosen tab as one silhouette, so a single shadow (accent when this pane has focus) runs round both.
    @ViewBuilder private func paneSurface(_ pane: NativeDockPaneFrame, metrics: NativeDockStripMetrics, focused: Bool, corner: Bool) -> some View {
        if !isHome(pane.group) {
            let content = contentFrame(pane, metrics), card = Self.cardFrame(content).offsetBy(dx: -pane.frame.minX, dy: -pane.frame.minY)
            let top = NativeDockHeaderMetrics.topPadding(for: pane.frame, topEdge: Self.topEdge)
            let span = chromeMode.showsTabs ? selectedTabSpan(pane.group, metrics: metrics, width: pane.frame.width, corner: corner) : nil
            let accent = Color(uiColor: decor.palette.accent(dark: scheme == .dark))
            ZStack(alignment: .topLeading) {
                Color.clear
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous).fill(NativeGlass.paper)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                                .strokeBorder(focused ? AnyShapeStyle(accent.opacity(0.55)) : AnyShapeStyle(NativeGlass.hairline), lineWidth: focused ? 1.5 : 1)
                        }
                        .frame(width: card.width, height: card.height).offset(x: card.minX, y: card.minY)
                    if let span {
                        // Drawn over the card's rim, so the rim stops where the tab joins it.
                        let pillTop = top + (metrics.height - metrics.pillHeight) / 2
                        let pdf = navigation.document(pane.group.activeID)?.kind == "pdf"
                        // Over a PDF the card shows the gutter's wash, so its tab takes the same.
                        NativeDockTabShape(radius: metrics.radius, flare: Self.tabFlare).fill(NativeGlass.paper)
                            .overlay { if pdf { NativeDockTabShape(radius: metrics.radius, flare: Self.tabFlare).fill(NativeGlass.gutter) } }
                            .frame(width: span.width + Self.tabFlare * 2, height: card.minY - pillTop + 2)
                            .offset(x: span.x - Self.tabFlare, y: pillTop)
                    }
                }
                .compositingGroup()
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.07), radius: 6, y: 2)
                .shadow(color: focused ? accent.opacity(0.22) : .clear, radius: 10)
            }.animation(.snappy(duration: 0.2), value: span?.x)
        }
    }
    static var tabFlare: CGFloat { 6 }
    private func tabs(_ group: NativeDockGroup, metrics: NativeDockStripMetrics, topPadding: CGFloat, corner: Bool) -> some View {
        GeometryReader { geometry in
            let split = navigation.groups.count > 1
            let inset = corner ? controlInset : 0
            let (sizing, showsList) = stripSizing(group, metrics: metrics, width: geometry.size.width, corner: corner)
            HStack(spacing: 0) {
                HStack(spacing: sizing.spacing) {
                    ForEach(sizing.visibleIndices.map { group.tabs[$0] }, id: \.self) { id in
                        if let document = navigation.document(id), let index = group.tabs.firstIndex(of: id) {
                            tab(document, group: group, index: index, sizing: sizing, metrics: metrics)
                        }
                    }
                }.frame(width: sizing.totalWidth, height: metrics.height, alignment: .leading).clipped()
                addButton(group, metrics: metrics)
                if showsList {
                    Button { tabListGroupID = group.id } label: {
                        // 44 wide to touch; the glyph keeps its place right after ＋.
                        Image(systemName: "chevron.down").font(.system(size: 13)).frame(width: 15).padding(.leading, 3).padding(.trailing, 6)
                            .frame(minWidth: 44, alignment: .leading).frame(height: metrics.height).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("이 영역의 열린 탭 \(group.tabs.count)개")
                        .accessibilityIdentifier("native-dock-tabs-" + group.id)
                        .popover(isPresented: Binding(get: { tabListGroupID == group.id }, set: { if !$0 { tabListGroupID = nil } }), arrowEdge: .top) {
                            NativeDockTabList(documents: group.tabs.compactMap { navigation.document($0) }, activeID: group.activeID,
                                select: { id in tabListGroupID = nil; selectTab(id, in: group.id) },
                                close: { closeDocuments([$0]) })
                                .presentationCompactAdaptation(.popover)
                        }
                }
                Color.clear.frame(maxWidth: .infinity).frame(height: metrics.height)
                    .contentShape(Rectangle())
                    .onDrop(of: [NativeDockDragPayload.contentType], delegate: drop(group.id, index: group.tabs.count))
                // Closes this pane only: its tabs move to the neighbouring pane.
                if split, let other = navigation.groups.first(where: { $0.id != group.id }) {
                    Button { perform { if group.tabs.isEmpty { navigation.removeEmptyGroup(group.id) } else { navigation.merge(group.id, into: other.id) }; maximizedGroupID = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: metrics.paneClose)).foregroundStyle(NativeDesktopTheme.muted).padding(.trailing, metrics.paneCloseInset)
                            .frame(width: 44, height: metrics.height, alignment: .trailing).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("이 칸 닫기").accessibilityIdentifier("native-dock-close-pane-" + group.id)
                }
                if inset > 0 { Color.clear.frame(width: inset, height: metrics.height) }
            }.frame(height: metrics.height).padding(.leading, metrics.padding).padding(.top, topPadding)
                .foregroundStyle(NativeDesktopTheme.secondary)
        // The strip lies on the glass; the chosen tab is the paper rising out of the card (`paneSurface`).
        }.frame(height: metrics.total + topPadding).clipped()
            .background { NativeDockTabStripBounds(groupID: group.id) }
            .onDrop(of: [NativeDockDragPayload.contentType], delegate: drop(group.id))
    }
    /// ＋ opens the new-tab menu; a long press opens the split and layout menu the design keeps out of the strip.
    private func addButton(_ group: NativeDockGroup, metrics: NativeDockStripMetrics, visible: Bool = true) -> some View {
        Button {
            NativeInputTrace.record("dock.plus", "tapped activeCourse=\(navigation.activeCourseID == nil ? 0 : 1)")
            focus(group.id); newTabGroupID = group.id
        } label: {
            if visible {
                Image(systemName: "plus").font(.system(size: metrics.plus)).frame(width: metrics.plus + 1).padding(.leading, metrics.gap).padding(.trailing, 3)
                    .frame(minWidth: 44).frame(height: metrics.height).contentShape(Rectangle())
            } else { Color.clear.frame(width: 44, height: 44).contentShape(Rectangle()) }
        }
        .buttonStyle(.plain)
        .contextMenu { layoutMenu(group) }
        .accessibilityLabel("새 탭 열기").accessibilityHint("길게 누르면 화면 나누기 메뉴가 열립니다").accessibilityIdentifier("native-dock-add-" + group.id)
        // Figma 129:2809: the card's left edge 32 left of the ＋, its top 23 below the ＋'s middle.
        .bandalPopover(isPresented: Binding(get: { newTabGroupID == group.id && navigation.activeCourseID != nil }, set: { if !$0 { newTabGroupID = nil } }),
                       at: .center, offset: CGSize(width: 118, height: 17), width: 300, radius: 18, padding: 0) {
            NativeNewTabMenu(onAction: { openNewTab($0, group.id) }, onClose: { newTabGroupID = nil })
        }
    }
    private func tab(_ document: NativeDocumentReference, group: NativeDockGroup, index: Int, sizing: NativeDockTabSizing, metrics: NativeDockStripMetrics) -> some View {
        let selected = group.activeID == document.id, split = navigation.groups.count > 1
        // Only the pane being written in fills its selected tab; the others stay at full strength in grey.
        let active = selected && (!split || group.id == navigation.focusedGroupID)
        let closeInside = selected && sizing.showsClose, width = sizing.width(of: index)
        return HStack(spacing: 0) {
            NativeDockDraggableTab(document: document, selected: selected, symbol: Self.symbol(document, split: split), metrics: metrics,
                dimmed: !active, mutedIcon: split && !active, closeInside: closeInside,
                fontScale: fontScale, density: sizing.density, courseID: navigation.activeCourseID ?? document.courseID, drag: drag,
                close: { closeDocuments([document.id]) }) {
                selectTab(document.id, in: group.id)
            }
            .frame(width: max(0, width - (closeInside ? metrics.closeZone : 0)), height: metrics.height).clipped()
            if closeInside {
                Button { closeDocuments([document.id]) } label: {
                    Image(systemName: "xmark").font(.system(size: metrics.close)).frame(width: metrics.close + 1).padding(.leading, 6).padding(.trailing, metrics.tabPadding)
                        .frame(height: metrics.height).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(split ? NativeDesktopTheme.muted : NativeDesktopTheme.secondary).accessibilityLabel(document.title + " 닫기")
                    .accessibilityIdentifier(document.id == navigation.activeID ? "native-close-document" : "native-close-tab-" + document.id)
            }
        }
        .frame(width: width, height: metrics.height).clipped()
        // The pane being written in marks its chosen tab with a short accent bar along the top.
        .overlay(alignment: .top) {
            if split && active {
                Capsule().fill(NativeGlass.accent).frame(width: max(0, min(28, width - metrics.tabPadding * 2)), height: 3)
                    .padding(.top, (metrics.height - metrics.pillHeight) / 2 + 3).allowsHitTesting(false)
            }
        }
        .contextMenu { tabMenu(document, group: group) }
        .overlay(alignment: .leading) {
            if drag.target == .init(groupID: group.id, direction: .within, index: index) { Rectangle().fill(NativeGlass.accent).frame(width: 3) }
        }
        .onDrop(of: [NativeDockDragPayload.contentType], delegate: drop(group.id, index: index))
    }
    @ViewBuilder private func tabMenu(_ document: NativeDocumentReference, group: NativeDockGroup) -> some View {
        Button("닫기", systemImage: "xmark") { closeDocuments([document.id]) }
        Button("이 그룹의 다른 탭 닫기") { closeDocuments(group.tabs.filter { $0 != document.id }) }
        Button("전체 작업 공간의 다른 탭 닫기") { closeDocuments(navigation.groups.flatMap(\.tabs).filter { $0 != document.id }) }
        Button("오른쪽 탭 모두 닫기") { closeDocuments(Array(group.tabs.dropFirst((group.tabs.firstIndex(of: document.id) ?? group.tabs.count) + 1))) }
            .disabled(group.tabs.last == document.id)
        Divider()
        Button("즐겨찾기에 추가", systemImage: "link") {
            resourceAction {
                let descriptor = try favoriteDescriptor(document)
                _ = try await store.invoke("favorites:add", ["courseId": document.courseID, "label": document.title, "descriptor": descriptor])
                store.events.send(.init(channel: "nativeWorkspace:favoritesChanged", payload: ["courseId": document.courseID]))
            }
        }
        Button("보드에 할 일로 추가", systemImage: "checklist") {
            resourceAction { _ = try await store.invoke("board:createTask", ["courseId": document.courseID, "title": document.title]) }
        }
        if document.supportsDuplicate {
            Divider()
            Button("탭 복제", systemImage: "plus.square.on.square") { duplicate(document, group: group, direction: .within) }
                .accessibilityIdentifier("native-duplicate-tab")
            Button("오른쪽에 분할 복제", systemImage: "rectangle.split.2x1") { duplicate(document, group: group, direction: .right) }
                .accessibilityIdentifier("native-duplicate-right")
        }
        if !document.isWorkspaceTool && !["whiteboard", "learning"].contains(document.kind) {
            Divider()
            // A split pane's strip has no 미리보기 and 공유 buttons: their whole menu lives here instead.
            if navigation.groups.count > 1, NativeDockShareControls.supports(document) { NativeDockShareControls(document: document, store: store).menuItems }
            else {
                Button("파일 공유", systemImage: "square.and.arrow.up") {
                    resourceAction { try await store.flushDocuments(); _ = try await store.invoke("materials:share", ["courseId": document.courseID, "relPath": document.relativePath]) }
                }
            }
            Button("경로 복사", systemImage: "link") {
                resourceAction {
                    guard let path = try await store.invokePrivate("nativeMaterial:path", ["courseId": document.courseID, "relPath": document.relativePath]) as? String else { throw DesktopRuntimeError("자료 경로를 확인하지 못했습니다.") }
                    UIPasteboard.general.string = path
                }
            }
            if document.supportsDuplicate {
                Button("AI 튜터에게 이 자료 물어보기", systemImage: "sparkle") {
                    perform { Self.revealDocumentAssistant(document.id, in: group.id, navigation: navigation, store: store) }
                }.accessibilityIdentifier("native-tab-ask-assistant")
            }
        }
        if document.kind == "browser" {
            Divider()
            Button("URL 복사", systemImage: "link") { resourceAction { UIPasteboard.general.string = try browserURL(document) } }
            Button("기본 브라우저로 열기", systemImage: "safari") {
                resourceAction {
                    guard let url = URL(string: try browserURL(document)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw DesktopRuntimeError("이 주소는 외부 브라우저에서 열 수 없습니다.") }
                    await UIApplication.shared.open(url)
                }
            }
            Button("새로고침", systemImage: "arrow.clockwise") { store.events.send(.init(channel: "nativeBrowser:scopeAction", payload: ["workspaceID": document.relativePath, "action": "reload"])) }
        }
        Divider()
        ForEach(NativeDockDirection.allCases.filter { $0 != .within }, id: \.rawValue) { direction in
            Button(direction.title, systemImage: direction.symbol) { perform { navigation.move(document.id, to: group.id, direction: direction) } }
                .accessibilityIdentifier("native-dock-move-" + direction.rawValue)
        }
        if navigation.groups.count > 1 {
            Menu("다른 영역으로 이동") {
                ForEach(Array(navigation.groups.enumerated()).filter { $0.element.id != group.id }, id: \.element.id) { index, target in
                    Button(groupTitle(target, index: index)) { perform { navigation.move(document.id, to: target.id) } }
                }
            }
        }
    }
    private func duplicate(_ document: NativeDocumentReference, group: NativeDockGroup, direction: NativeDockDirection) {
        let initialURL = document.kind == "browser" ? try? browserURL(document) : nil
        perform {
            guard let copy = navigation.duplicate(document.id, inGroup: group.id, direction: direction) else { return }
            store.documentDuplicateSourceIDs[copy.id] = document.id
            if let initialURL { store.pendingBrowserURLs[copy.relativePath] = initialURL }
            store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
        }
    }
    static func revealDocumentAssistant(_ documentID: String, in groupID: String, navigation: NativeWorkspaceNavigation, store: NativeWorkspaceStore) {
        guard let document = navigation.document(documentID), document.supportsDuplicate,
              navigation.groups.contains(where: { $0.id == groupID && $0.tabs.contains(documentID) }) else { return }
        navigation.select(documentID, in: groupID)
        store.assistantDocumentIDs.insert(documentID)
    }
    private func resourceAction(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { store.errorMessage = error.localizedDescription } }
    }
    private func browserURL(_ document: NativeDocumentReference) throws -> String {
        guard let page = NativeBrowserSession.currentPage(workspaceID: document.relativePath, store: store), !page.url.isEmpty, page.url != "about:blank" else {
            throw DesktopRuntimeError("열린 웹페이지 주소를 확인하지 못했습니다. 개인정보 보호 탭의 주소는 작업 공간에 저장하지 않습니다.")
        }
        return page.url
    }
    private func favoriteDescriptor(_ document: NativeDocumentReference) throws -> [String: Any] {
        let kind: String, payload: [String: Any]
        switch document.kind {
        case "browser": kind = "browser"; payload = ["tabId": UUID().uuidString, "initialUrl": try browserURL(document)]
        case "assistant":
            kind = "chat"
            var value: [String: Any] = ["courseId": document.courseID]
            if let id = NativeToolSelection.conversationID(workspaceID: document.relativePath, root: store.root) { value["conversationId"] = id }
            payload = value
        case "recordings":
            kind = "recording"
            var value: [String: Any] = ["courseId": document.courseID]
            if let id = NativeToolSelection.recordingID(workspaceID: document.relativePath, courseID: document.courseID) { value["recordingId"] = id }
            payload = value
        case "planner": kind = "board"; payload = [:]
        case "whiteboard": kind = "whiteboard"; payload = ["courseId": document.courseID, "boardId": document.relativePath]
        case "learning-home": kind = "learning"; payload = ["courseId": document.courseID]
        case "learning": kind = "learning"; payload = ["courseId": document.courseID, "rootRelPath": document.relativePath]
        default:
            kind = ["pdf", "note", "image"].contains(document.kind) ? document.kind : "file"
            payload = ["courseId": document.courseID, "relPath": document.relativePath]
        }
        return ["kind": kind, "payload": payload]
    }
    @ViewBuilder private func layoutMenu(_ group: NativeDockGroup) -> some View {
            Section("열린 자료") {
                ForEach(navigation.groups.flatMap(\.tabs), id: \.self) { id in
                    if let document = navigation.document(id), let owner = navigation.group(containing: id) {
                        Button(document.title) { perform { navigation.select(id, in: owner.id) } }
                    }
                }
            }
            Section("화면 배치") {
                Button("새 탭 열기", systemImage: "plus") { focus(group.id); newTabGroupID = group.id }
                ForEach(NativeDockPreset.allCases, id: \.rawValue) { preset in
                    Button(preset.title, systemImage: preset.symbol) { perform { navigation.focus(group.id); navigation.apply(preset); maximizedGroupID = nil } }
                        .accessibilityIdentifier("native-dock-preset-" + preset.rawValue)
                }
            }
            if let document = navigation.document(group.activeID), document.supportsDuplicate {
                Section("현재 탭") {
                    Button("탭 복제", systemImage: "plus.square.on.square") { duplicate(document, group: group, direction: .within) }
                        .accessibilityIdentifier("native-duplicate-tab")
                    Button("오른쪽에 분할 복제", systemImage: "rectangle.split.2x1") { duplicate(document, group: group, direction: .right) }
                        .accessibilityIdentifier("native-duplicate-right")
                }
            }
            Section("이 영역") {
                Button("이 영역을 좌우로 나누기", systemImage: "rectangle.split.2x1") { perform { navigation.split(group.id, direction: .right) } }
                    .accessibilityIdentifier("native-dock-split-right")
                Button("이 영역을 상하로 나누기", systemImage: "rectangle.split.1x2") { perform { navigation.split(group.id, direction: .below) } }
                    .accessibilityIdentifier("native-dock-split-below")
                if navigation.groups.count > 1 {
                    Button(maximizedGroupID == group.id ? "전체 영역 보기" : "이 영역 크게 보기", systemImage: "arrow.up.left.and.arrow.down.right") {
                        perform { navigation.focus(group.id); maximizedGroupID = maximizedGroupID == group.id ? nil : group.id }
                    }.accessibilityIdentifier("native-dock-maximize")
                    Menu("다른 영역과 합치기") {
                        ForEach(Array(navigation.groups.enumerated()).filter { $0.element.id != group.id }, id: \.element.id) { index, target in
                            Button(groupTitle(target, index: index)) { perform { navigation.merge(group.id, into: target.id) } }
                        }
                    }
                    Button("모든 영역 합치기", systemImage: "rectangle") { perform { navigation.apply(.single); maximizedGroupID = nil } }
                        .accessibilityIdentifier("native-dock-merge-all")
                    if group.tabs.isEmpty { Button("빈 영역 닫기", systemImage: "xmark") { perform { navigation.removeEmptyGroup(group.id) } }.accessibilityIdentifier("native-dock-close-empty") }
                }
            }
    }
    @ViewBuilder private func emptyPane(_ group: NativeDockGroup, groupCount: Int) -> some View {
        if groupCount == 1 { empty() }
        else {
            VStack(spacing: 14) {
                NativeBandalMark(size: 36).foregroundStyle(NativeDecorMarkStyle()).opacity(0.85)
                Text("이 영역에서 새 탭을 여세요").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.muted)
                Button("새 탭 열기", systemImage: "plus") { focus(group.id); newTabGroupID = group.id }.buttonStyle(NativeThemedButtonStyle(prominent: true)).frame(minHeight: 44)
                Button("빈 영역 닫기", systemImage: "xmark") { perform { navigation.removeEmptyGroup(group.id) } }.buttonStyle(NativeThemedButtonStyle()).frame(minHeight: 44)
                    .accessibilityIdentifier("native-dock-close-empty-" + group.id)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).onTapGesture { focus(group.id) }
        }
    }
    private func groupTitle(_ group: NativeDockGroup, index: Int) -> String {
        "영역 \(index + 1) · " + (navigation.document(group.activeID)?.title ?? "빈 영역")
    }
    private func paneSelector(_ layout: NativeDockLayout, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(layout.groups.enumerated()), id: \.element.id) { index, group in
                    Button(groupTitle(group, index: index)) { perform { navigation.focus(group.id); if maximizedGroupID != nil { maximizedGroupID = group.id } } }
                        .accessibilityIdentifier("native-dock-select-group-\(index)")
                }
            } label: {
                Label("영역 \((layout.groups.firstIndex { $0.id == (maximizedGroupID ?? layout.focusedGroupID) } ?? 0) + 1) / \(layout.groups.count)", systemImage: "square.grid.2x2")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("native-dock-pane-selector")
            Text(compact ? "좁은 화면에서는 영역을 선택해 보세요" : "선택한 영역 크게 보기").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
            Spacer(minLength: 0)
            if !compact { Button("전체 보기") { perform { maximizedGroupID = nil } }.frame(minHeight: 44) }
        }.padding(.horizontal, 12).background(NativeGlass.panel)
    }
    private func focus(_ id: String) { navigation.focus(id); persist() }
    private func drop(_ groupID: String, direction: NativeDockDirection = .within, index: Int? = nil) -> NativeDockDropDelegate {
        NativeDockDropDelegate(drag: drag, target: .init(groupID: groupID, direction: direction, index: index), navigation: navigation, perform: perform)
    }
    private func paneDropZones(_ pane: NativeDockPaneFrame) -> some View {
        GeometryReader { proxy in
            NativeDockDropSurface(groupID: pane.id, drag: drag, navigation: navigation, perform: perform)
            .overlay {
                if let target = drag.target, target.groupID == pane.id, target.index == nil {
                    let horizontal = target.direction.axis == .horizontal, half = target.direction != .within
                    RoundedRectangle(cornerRadius: Self.cardRadius).fill(NativeGlass.accentSoft).overlay(RoundedRectangle(cornerRadius: Self.cardRadius).stroke(NativeGlass.accent, lineWidth: 2))
                        .frame(width: half && horizontal ? proxy.size.width / 2 : proxy.size.width, height: half && !horizontal ? proxy.size.height / 2 : proxy.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: target.direction == .left ? .leading : target.direction == .right ? .trailing : target.direction == .above ? .top : target.direction == .below ? .bottom : .center)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// A separate accessibility element exposes the whole strip's bounds without
/// propagating an identifier over its individual UIKit/SwiftUI controls.
private struct NativeDockTabStripBounds: UIViewRepresentable {
    let groupID: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true; view.accessibilityLabel = "이 영역의 탭"
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { view.accessibilityIdentifier = "native-dock-tab-strip-" + groupID }
}

/// Keeping a hidden editor mounted preserves its local Undo and disclosure state.
/// Its keyboard focus must still end when the tab becomes hidden. Track only
/// responders inside this document's visible rectangle, never another pane.
private struct NativeDockEditorVisibility: UIViewRepresentable {
    let isVisible: Bool
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.setVisible(isVisible) }

    final class Probe: UIView {
        private var documentVisible = false
        private weak var editor: UIView?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(beganEditing(_:)), name: UITextView.textDidBeginEditingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(beganEditing(_:)), name: UITextField.textDidBeginEditingNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        func setVisible(_ value: Bool) {
            if documentVisible && !value {
                // Navigation's flush commits marked text before this update.
                // Resigning here also covers switching courses through a link.
                if editor?.isFirstResponder == true { editor?.resignFirstResponder() }
                editor = nil
            }
            documentVisible = value
        }
        @objc private func beganEditing(_ notification: Notification) {
            guard documentVisible, let responder = notification.object as? UIView,
                  let window, responder.window === window, !bounds.isEmpty else { return }
            let visibleBounds = convert(bounds, to: window)
            let editorBounds = responder.convert(responder.bounds, to: window)
            let overlap = visibleBounds.intersection(editorBounds)
            guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { return }
            editor = responder
        }
    }
}

/// A stable UIKit drop interaction sits above the editor only during a local
/// tab drag. UITextView must never interpret a tab identifier as pasted text.
private struct NativeDockDropSurface: UIViewRepresentable {
    let groupID: String
    @ObservedObject var drag: NativeDockDragSession
    let navigation: NativeWorkspaceNavigation
    let perform: (@escaping @MainActor () -> Void) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        context.coordinator.owner = self
        let active = drag.transfer != nil
        if view.acceptsTouches != active { NativeDockDragPayload.trace("surface.active=\(active)") }
        view.acceptsTouches = active
        let drag = drag
        view.releaseIfStale = { guard drag.isStale else { return false }; NativeDockDragPayload.trace("surface.stale"); drag.end(); return true }
    }
    /// Covers the pane only while a tab drag runs, and only for the drag: a drop is hit-tested with the drag's own
    /// event, never with a touch event. Touches always pass through to the editor beneath, so a drag whose end was
    /// never reported (iPadOS took the finger to move the window) cannot leave the pane dead; the first touch
    /// after such a drag also clears it.
    final class Surface: UIView {
        var acceptsTouches = false
        var releaseIfStale: () -> Bool = { false }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard acceptsTouches else { return false }
            if event?.type == .touches {
                if releaseIfStale() { acceptsTouches = false }
                return false
            }
            return super.point(inside: point, with: event)
        }
    }
    @MainActor final class Coordinator: NSObject, UIDropInteractionDelegate {
        var owner: NativeDockDropSurface
        private var lastSession: ObjectIdentifier?
        init(_ owner: NativeDockDropSurface) { self.owner = owner }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            let accepted = session.localDragSession != nil && owner.drag.transfer != nil && owner.drag.transfer?.courseID == owner.navigation.activeCourseID &&
                session.hasItemsConforming(toTypeIdentifiers: [NativeDockDragPayload.contentType.identifier])
            if lastSession != ObjectIdentifier(session) {
                lastSession = ObjectIdentifier(session)
                NativeDockDragPayload.trace("target.canHandle=\(accepted) active=\(owner.drag.transfer != nil) local=\(session.localDragSession != nil)")
            }
            return accepted
        }
        private func target(_ interaction: UIDropInteraction, _ session: UIDropSession) -> NativeDockDragSession.Target {
            guard let view = interaction.view else { return .init(groupID: owner.groupID, direction: .within, index: nil) }
            let point = session.location(in: view), size = view.bounds.size
            let edgeX = min(72, size.width * 0.22), edgeY = min(72, size.height * 0.22)
            let direction: NativeDockDirection = point.x < edgeX ? .left : point.x > size.width - edgeX ? .right :
                point.y < edgeY ? .above : point.y > size.height - edgeY ? .below : .within
            return .init(groupID: owner.groupID, direction: direction, index: nil)
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            guard dropInteraction(interaction, canHandle: session) else { return UIDropProposal(operation: .cancel) }
            owner.drag.target = target(interaction, session)
            return UIDropProposal(operation: .move)
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            if owner.drag.target?.groupID == owner.groupID { owner.drag.target = nil }
        }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard dropInteraction(interaction, canHandle: session), let transfer = owner.drag.transfer else { return }
            let destination = target(interaction, session)
            NativeDockDragPayload.trace("target.performDrop direction=\(destination.direction.rawValue)")
            owner.drag.end()
            owner.perform { [navigation = owner.navigation] in
                guard transfer.courseID == navigation.activeCourseID else { return }
                navigation.move(transfer.documentID, to: destination.groupID, direction: destination.direction)
            }
        }
    }
}

private struct NativeDockDivider: View {
    let divider: NativeDockDividerFrame
    /// Left/right split: a 2-point seam below the strips with an 8×64 grip (Figma 130:5984). Otherwise 1 point and 6×56.
    let wide: Bool
    let topInset: CGFloat
    /// Grip centre along the seam; nil when a neighbouring seam already shows it.
    let grip: CGFloat?
    let change: (Double) -> Void
    let persist: () -> Void
    @State private var initial: Double?
    private var horizontal: Bool { divider.split.axis == .horizontal }
    var body: some View {
        Color.clear
            .overlay(seam.allowsHitTesting(false))
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture)
            .onDisappear { initial = nil }
            .onTapGesture(count: 2, perform: reset)
            .accessibilityElement()
            .accessibilityLabel(horizontal ? "분할 화면 폭 조절" : "분할 화면 높이 조절")
            .accessibilityValue("\(Int(divider.displayedFraction * 100))퍼센트")
            .accessibilityIdentifier("native-dock-divider-" + divider.id)
            .accessibilityAdjustableAction { direction in
                change(divider.displayedFraction + (direction == .increment ? 0.05 : -0.05)); persist()
            }
            .accessibilityAction(named: "같은 크기로", reset)
    }
    private var seam: some View {
        let thickness: CGFloat = wide ? 2 : 1, short: CGFloat = wide ? 8 : 6, long: CGFloat = wide ? 64 : 56
        return ZStack(alignment: .topLeading) {
            NativeGlass.separator
                .frame(width: horizontal ? thickness : divider.frame.width, height: horizontal ? max(0, divider.frame.height - topInset) : thickness)
                // The wide seam keeps its right edge on the pane boundary, as drawn.
                .offset(x: horizontal ? divider.frame.width - thickness : 0, y: horizontal ? topInset : 0)
            if let grip {
                RoundedRectangle(cornerRadius: short / 2).fill(NativeDesktopTheme.muted)
                    .frame(width: horizontal ? short : long, height: horizontal ? long : short)
                    .position(x: horizontal ? divider.frame.width - thickness / 2 : grip, y: horizontal ? grip : divider.frame.height / 2)
            }
        }.frame(width: divider.frame.width, height: divider.frame.height, alignment: .topLeading)
    }
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged(resize)
            .onEnded { _ in initial = nil; persist() }
    }
    private func resize(_ value: DragGesture.Value) {
        if initial == nil { initial = divider.displayedFraction }
        let extent: Double = max(1, Double(horizontal ? divider.bounds.width : divider.bounds.height) - Double(NativeDockLayout.seam))
        let translation: Double = Double(horizontal ? value.translation.width : value.translation.height)
        change((initial ?? 0.5) + translation / extent)
    }
    private func reset() { change(0.5); persist() }
}

@MainActor
private struct NativeDockDropDelegate: DropDelegate {
    let drag: NativeDockDragSession
    let target: NativeDockDragSession.Target
    let navigation: NativeWorkspaceNavigation
    let perform: (@escaping @MainActor () -> Void) -> Void
    func validateDrop(info: DropInfo) -> Bool { drag.transfer?.courseID == navigation.activeCourseID && drag.transfer != nil }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { drag.target = target } }
    func dropExited(info: DropInfo) { if drag.target == target { drag.target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .move : .cancel) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let transfer = drag.transfer else { return false }
        drag.end()
        perform {
            guard transfer.courseID == navigation.activeCourseID else { return }
            navigation.move(transfer.documentID, to: target.groupID, direction: target.direction, index: target.index)
        }
        return true
    }
}

/// UIKit supplies a real drag-session end callback, including cancellation. This
/// avoids a permanent drop overlay after a SwiftUI onDrag is cancelled outside a pane.
private struct NativeDockDraggableTab: UIViewRepresentable {
    let document: NativeDocumentReference
    let selected: Bool
    let symbol: String
    let metrics: NativeDockStripMetrics
    let dimmed: Bool
    let mutedIcon: Bool
    let closeInside: Bool
    let fontScale: Double
    let density: NativeDockTabSizing.Density
    let courseID: String
    let drag: NativeDockDragSession
    let close: () -> Void
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> NativeDockTabButton {
        let button = NativeDockTabButton(frame: .zero)
        button.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.owner.action() }, for: .touchUpInside)
        let interaction = UIDragInteraction(delegate: context.coordinator); interaction.isEnabled = true; button.addInteraction(interaction)
        updateUIView(button, context: context); return button
    }
    func updateUIView(_ button: NativeDockTabButton, context: Context) {
        context.coordinator.owner = self
        button.configure(title: document.title, symbol: symbol, density: density, fontScale: fontScale, selected: selected,
                         metrics: metrics, dimmed: dimmed, mutedIcon: mutedIcon, closeInside: closeInside)
        button.accessibilityIdentifier = "native-document-tab-" + document.id
        button.accessibilityHint = "길게 눌러 다른 영역이나 탭 사이로 드래그할 수 있습니다"
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "닫기", actionHandler: { [weak coordinator = context.coordinator] _ in coordinator?.owner.close(); return true })]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeDockTabButton, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 44)
    }
    @MainActor final class Coordinator: NSObject, UIDragInteractionDelegate {
        var owner: NativeDockDraggableTab
        init(_ owner: NativeDockDraggableTab) { self.owner = owner }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            NativeDockDragPayload.trace("source.begin")
            owner.drag.transfer = .init(documentID: owner.document.id, courseID: owner.courseID)
            owner.drag.source = session
            return [UIDragItem(itemProvider: NativeDockDragPayload.provider(documentID: owner.document.id))]
        }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            NativeDockDragPayload.trace("source.end operation=\(operation.rawValue)")
            owner.drag.end()
        }
        // A lift that never becomes a drag (the finger lifts, or iPadOS takes the touch for itself) ends here, not in `didEndWith`.
        func dragInteraction(_ interaction: UIDragInteraction, item: UIDragItem, willAnimateCancelWith animator: UIDragAnimating) {
            NativeDockDragPayload.trace("source.cancel")
            owner.drag.end()
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { NativeDockDragPayload.trace("source.willBegin") }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
    }
}

/// Watches every touch in the window without taking part in it: a recognizer that fails on its first
/// touch, never cancels or delays, and reports where the touch began in this view's space.
private struct NativeDockTouchFocus: UIViewRepresentable {
    let panes: [(String, CGRect)]
    let onFocus: (String) -> Void
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.isUserInteractionEnabled = false; view.isAccessibilityElement = false; return view }
    func updateUIView(_ view: Probe, context: Context) {
        let panes = panes, onFocus = onFocus
        view.onTouch = { point in if let pane = panes.first(where: { $0.1.contains(point) }) { onFocus(pane.0) } }
        view.active = !panes.isEmpty
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: UIView {
        var onTouch: (CGPoint) -> Void = { _ in }
        /// Only with panes side by side does the window carry the watcher at all.
        var active = false { didSet { if active != oldValue { attach() } } }
        private var watcher: Watcher?
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        private func attach() {
            detach()
            guard active, let window else { return }
            let watcher = Watcher { [weak self] touch in
                guard let self, self.active, self.window != nil, !self.isHidden else { return }
                let point = touch.location(in: self)
                guard self.bounds.contains(point) else { return }
                DispatchQueue.main.async { self.onTouch(point) }
            }
            window.addGestureRecognizer(watcher); self.watcher = watcher
        }
        func detach() { if let watcher { watcher.view?.removeGestureRecognizer(watcher); self.watcher = nil } }
    }
    final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let report: (UITouch) -> Void
        init(_ report: @escaping (UITouch) -> Void) {
            self.report = report
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { report(touch) }
            state = .failed
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A tab rising out of the card under it: rounded on top, and at the bottom flaring out into the card's edge
/// with a concave curve each side (`flare` wide), so tab and card read as one sheet.
struct NativeDockTabShape: Shape {
    var radius: CGFloat
    var flare: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + flare, right = rect.maxX - flare, top = rect.minY, bottom = rect.maxY
        let r = min(radius, (right - left) / 2, (bottom - top) / 2)
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - flare), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bottom), control: CGPoint(x: right, y: bottom))
        path.closeSubpath()
        return path
    }
}
