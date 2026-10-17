import SwiftUI
import UIKit
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
    func end() { transfer = nil; target = nil }
}

/// Frames are projected from the recursive tree, but editor views live in a flat
/// stable-ID layer. Splitting or moving a tab therefore never reparents its editor.
struct NativeDockWorkspace<Content: View, Empty: View>: View {
    @ObservedObject var navigation: NativeWorkspaceNavigation
    @ObservedObject var store: NativeWorkspaceStore
    let content: (NativeDocumentReference) -> Content
    let empty: () -> Empty
    let perform: (@escaping @MainActor () -> Void) -> Void
    let persist: () -> Void
    let closeDocuments: ([String]) -> Void
    let openMaterials: () -> Void
    let openNewTab: (NativeNewTabAction, String) -> Void
    @StateObject private var drag = NativeDockDragSession()
    @State private var maximizedGroupID: String?
    @State private var newTabGroupID: String?
    @State private var tabListGroupID: String?
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @AppStorage("native.density") private var density = "comfortable"

    private let headerHeight: CGFloat = 44
    var body: some View {
        GeometryReader { proxy in
            if let layout = navigation.layout {
                let requiresFocus = layout.root.minimumSize.width > proxy.size.width || layout.root.minimumSize.height > proxy.size.height
                let focusMode = layout.groups.count > 1 && (requiresFocus || maximizedGroupID != nil)
                let selected = maximizedGroupID.flatMap { id in layout.groups.first { $0.id == id } } ?? layout.focused!
                let selectorHeight: CGFloat = focusMode ? 44 : 0
                let bounds = CGRect(x: 0, y: selectorHeight, width: proxy.size.width, height: max(0, proxy.size.height - selectorHeight))
                let geometry = focusMode ? NativeDockGeometry(panes: [.init(group: selected, frame: bounds)]) : layout.geometry(in: bounds)
                ZStack(alignment: .topLeading) {
                    NativeDesktopTheme.bgApp
                    ForEach(geometry.panes) { pane in
                        paneChrome(pane, focused: layout.focusedGroupID == pane.id)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .position(x: pane.frame.midX, y: pane.frame.midY)
                    }
                    // Do not nest these in pane chrome: an editor retains identity
                    // when the same document moves to another group or the tree changes.
                    ForEach(visibleDocuments(geometry, layout: layout, bounds: bounds)) { entry in
                        content(entry.document)
                            .frame(width: entry.frame.width, height: entry.frame.height)
                            .background {
                                if Self.retainsEditor(entry.document) {
                                    NativeDockEditorVisibility(isVisible: entry.visible)
                                }
                            }
                            .clipped()
                            .opacity(entry.visible ? 1 : 0)
                            .allowsHitTesting(entry.visible)
                            .accessibilityHidden(!entry.visible)
                            .simultaneousGesture(TapGesture().onEnded { focus(entry.groupID) })
                            .position(x: entry.frame.midX, y: entry.frame.midY)
                    }
                    ForEach(geometry.panes.filter { $0.group.activeID == nil }) { pane in
                        let frame = NativeDockHeaderMetrics.contentFrame(for: pane.frame)
                        emptyPane(pane.group, groupCount: layout.groups.count)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    ForEach(geometry.dividers) { divider in
                        NativeDockDivider(divider: divider, change: { navigation.resize(divider.id, fraction: $0) }, persist: persist)
                            .frame(width: divider.hitFrame.width, height: divider.hitFrame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                    ForEach(geometry.panes) { pane in
                        let frame = NativeDockHeaderMetrics.contentFrame(for: pane.frame)
                        paneDropZones(pane)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    if focusMode {
                        paneSelector(layout, compact: requiresFocus)
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
        .onChange(of: navigation.activeCourseID) { _, _ in drag.end(); maximizedGroupID = nil }
    }

    struct VisibleDocument: Identifiable {
        var document: NativeDocumentReference; var groupID: String; var frame: CGRect; var visible: Bool
        var id: String { document.id }
    }
    private func visibleDocuments(_ geometry: NativeDockGeometry, layout: NativeDockLayout, bounds: CGRect) -> [VisibleDocument] {
        Self.projectDocuments(navigation.documents, geometry: geometry, layout: layout, bounds: bounds, headerHeight: headerHeight)
    }
    static func retainsEditor(_ document: NativeDocumentReference) -> Bool {
        document.kind == "note" || ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())
    }
    static func projectDocuments(_ documents: [NativeDocumentReference], geometry: NativeDockGeometry, layout: NativeDockLayout,
                                 bounds: CGRect, headerHeight: CGFloat = 44) -> [VisibleDocument] {
        // Compact mode hides other groups without ending their editor session.
        // Rotation or maximizing a pane must not race an asynchronous draft flush.
        let projected = layout.geometry(in: bounds)
        var result: [VisibleDocument] = projected.panes.compactMap { original in
            guard let document = documents.first(where: { $0.id == original.group.activeID }) else { return nil }
            let visible = geometry.panes.first { $0.id == original.id }
            let frame = visible?.frame ?? CGRect(x: -10000, y: -10000, width: max(280, original.frame.width), height: max(220, original.frame.height))
            let inset = NativeDockHeaderMetrics.height(for: visible?.frame ?? original.frame, controlsHeight: headerHeight)
            return VisibleDocument(document: document, groupID: original.id,
                frame: CGRect(x: frame.minX, y: frame.minY + inset, width: frame.width, height: max(0, frame.height - inset)), visible: visible != nil)
        }
        let activeIDs = Set(result.map(\.id))
        // UIKit owns Markdown selection, composition and per-pane Undo. Keep
        // that editor alive until the tab is actually closed, including while
        // another course is active. PDF retains its existing checkpoint path.
        for document in documents where retainsEditor(document) && !activeIDs.contains(document.id) {
            let original = projected.panes.first { $0.group.tabs.contains(document.id) }
            let inset = NativeDockHeaderMetrics.height(for: original?.frame ?? bounds, controlsHeight: headerHeight)
            result.append(VisibleDocument(document: document, groupID: original?.id ?? "",
                frame: CGRect(x: -10000, y: -10000, width: max(280, original?.frame.width ?? bounds.width),
                              height: max(220, (original?.frame.height ?? bounds.height) - inset)), visible: false))
        }
        return result
    }
    private func paneChrome(_ pane: NativeDockPaneFrame, focused: Bool) -> some View {
        VStack(spacing: 0) {
            tabs(pane.group, topPadding: NativeDockHeaderMetrics.topPadding(for: pane.frame))
            Spacer(minLength: 0)
        }
        .background(NativeDesktopTheme.bgApp)
    }
    private func tabs(_ group: NativeDockGroup, topPadding: CGFloat) -> some View {
        GeometryReader { geometry in
            let sizing = NativeDockTabSizing(availableWidth: max(0, geometry.size.width - 140), count: group.tabs.count,
                activeIndex: group.tabs.firstIndex(of: group.activeID ?? "") ?? -1, spacing: density == "compact" ? 0 : 4)
            HStack(alignment: .bottom, spacing: 0) {
                HStack(spacing: sizing.spacing) {
                    ForEach(sizing.visibleIndices.map { group.tabs[$0] }, id: \.self) { id in
                        if let document = navigation.document(id), let index = group.tabs.firstIndex(of: id) {
                            tab(document, group: group, index: index, sizing: sizing)
                        }
                    }
                }.frame(width: sizing.totalWidth, height: headerHeight, alignment: .leading).clipped()
                Color.clear.frame(maxWidth: .infinity).frame(height: headerHeight)
                    .contentShape(Rectangle())
                    .onDrop(of: [NativeDockDragPayload.contentType], delegate: drop(group.id, index: group.tabs.count))
                Button { focus(group.id); newTabGroupID = group.id } label: { Image(systemName: "plus").font(.system(size: 14)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("새 탭 열기").accessibilityIdentifier("native-dock-add-" + group.id)
                .popover(isPresented: Binding(get: { newTabGroupID == group.id }, set: { if !$0 { newTabGroupID = nil } }), arrowEdge: .top) {
                    if let courseID = navigation.activeCourseID {
                        NativeNewTabMenu(store: store, courseID: courseID, onAction: { openNewTab($0, group.id) }, onClose: { newTabGroupID = nil })
                            .presentationCompactAdaptation(.popover)
                    }
                }
                Button { tabListGroupID = group.id } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("이 영역의 열린 탭 \(group.tabs.count)개")
                    .accessibilityIdentifier("native-dock-tabs-" + group.id)
                    .popover(isPresented: Binding(get: { tabListGroupID == group.id }, set: { if !$0 { tabListGroupID = nil } }), arrowEdge: .top) {
                        NativeDockTabList(documents: group.tabs.compactMap { navigation.document($0) }, activeID: group.activeID,
                            select: { id in tabListGroupID = nil; perform { navigation.select(id, in: group.id) } },
                            close: { closeDocuments([$0]) })
                            .presentationCompactAdaptation(.popover)
                    }
                groupMenu(group)
            }.frame(height: headerHeight, alignment: .bottom).padding(.horizontal, 4).padding(.top, topPadding)
        }.frame(height: headerHeight + topPadding).clipped().background(NativeDesktopTheme.surface)
            .background { NativeDockTabStripBounds(groupID: group.id) }
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .onDrop(of: [NativeDockDragPayload.contentType], delegate: drop(group.id))
    }
    private func tab(_ document: NativeDocumentReference, group: NativeDockGroup, index: Int, sizing: NativeDockTabSizing) -> some View {
        HStack(spacing: 0) {
            NativeDockDraggableTab(document: document, selected: group.activeID == document.id,
                fontScale: fontScale, density: sizing.density, courseID: navigation.activeCourseID ?? document.courseID, drag: drag,
                close: { closeDocuments([document.id]) }) {
                perform { navigation.select(document.id, in: group.id) }
            }
            .frame(width: max(0, sizing.width - (sizing.showsClose ? 32 : 0)), height: 44).clipped()
            if sizing.showsClose {
                Button { closeDocuments([document.id]) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 32, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(document.title + " 닫기")
                    .accessibilityIdentifier(document.id == navigation.activeID ? "native-close-document" : "native-close-tab-" + document.id)
            }
        }
        .frame(width: sizing.width, height: headerHeight).clipped()
        .background {
            RoundedRectangle(cornerRadius: 6).fill(group.activeID == document.id ? NativeDesktopTheme.raised : Color.clear).padding(.vertical, 4)
        }
        .contextMenu { tabMenu(document, group: group) }
        .overlay(alignment: .leading) {
            if drag.target == .init(groupID: group.id, direction: .within, index: index) { NativeDesktopTheme.accent.frame(width: 3) }
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
            Button("파일 공유", systemImage: "square.and.arrow.up") {
                resourceAction { try await store.flushDocuments(); _ = try await store.invoke("materials:share", ["courseId": document.courseID, "relPath": document.relativePath]) }
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
        perform {
            guard let copy = navigation.duplicate(document.id, inGroup: group.id, direction: direction) else { return }
            store.documentDuplicateSourceIDs[copy.id] = document.id
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
    private func groupMenu(_ group: NativeDockGroup) -> some View {
        Menu {
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
        } label: { Image(systemName: "rectangle.split.2x1").font(.system(size: 14)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("열린 자료와 분할 보기")
            .accessibilityIdentifier(group.id == navigation.focusedGroupID ? "native-open-documents" : "native-dock-layout-" + group.id)
    }
    @ViewBuilder private func emptyPane(_ group: NativeDockGroup, groupCount: Int) -> some View {
        if groupCount == 1 { empty() }
        else {
            VStack(spacing: 14) {
                NativeBandalMark(size: 32).foregroundStyle(NativeDesktopTheme.muted.opacity(0.5))
                Text("이 영역에서 새 탭을 여세요").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.muted)
                Button("새 탭 열기", systemImage: "plus") { focus(group.id); newTabGroupID = group.id }.buttonStyle(.bordered).frame(minHeight: 44)
                Button("빈 영역 닫기", systemImage: "xmark") { perform { navigation.removeEmptyGroup(group.id) } }.buttonStyle(.bordered).frame(minHeight: 44)
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
        }.padding(.horizontal, 12).background(NativeDesktopTheme.surface)
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
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
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

/// Keeping a hidden Markdown editor mounted preserves its local Undo manager.
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
    }
    final class Surface: UIView {
        var acceptsTouches = false
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            acceptsTouches && super.point(inside: point, with: event)
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
        NativeDesktopTheme.border
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay(grip)
    }
    private var grip: some View {
        Capsule().fill(NativeDesktopTheme.muted.opacity(0.45))
            .frame(width: horizontal ? 2 : 28, height: horizontal ? 28 : 2)
    }
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged(resize)
            .onEnded { _ in initial = nil; persist() }
    }
    private func resize(_ value: DragGesture.Value) {
        if initial == nil { initial = divider.displayedFraction }
        let extent: Double = max(1, Double(horizontal ? divider.bounds.width : divider.bounds.height) - 8)
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
        let symbol = document.kind == "pdf" ? "doc.richtext" : document.kind == "whiteboard" ? "rectangle.and.pencil.and.ellipsis" : document.kind == "browser" ? "globe" : document.kind == "assistant" ? "sparkle" : document.kind == "recordings" ? "waveform" : document.kind == "planner" ? "checklist" : "doc.text"
        button.configure(title: document.title, symbol: symbol, density: density, fontScale: fontScale, selected: selected)
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
            return [UIDragItem(itemProvider: NativeDockDragPayload.provider(documentID: owner.document.id))]
        }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            NativeDockDragPayload.trace("source.end operation=\(operation.rawValue)")
            owner.drag.end()
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
    }
}
