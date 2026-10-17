import SwiftUI
import UniformTypeIdentifiers

struct NativePDFToolbar: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    @State private var entry = "1"
    var body: some View {
        VStack(spacing: 0) {
            // Row 1: pages · history · export · view. Row 2: tools · colours · thickness · favourites.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { navigation; divider; history; Spacer(minLength: 0); viewActions }
                HStack(spacing: 4) { navigationControls(compact: true); divider; history; Spacer(minLength: 0); compactViewActions }
            }
            if model.toolsExpanded { Divider(); NativePDFPaletteQuickControls(model: model) }
        }
        .padding(.horizontal, 8).background(NativeDesktopTheme.surface)
        .foregroundStyle(NativeDesktopTheme.text)
        .buttonStyle(.plain)
        .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
        .onChange(of: model.page, initial: true) { _, value in entry = String(value) }
    }
    private var divider: some View { Rectangle().fill(NativeDesktopTheme.border).frame(width: 1, height: 20).padding(.horizontal, 3) }
    private var navigation: some View { navigationControls(compact: false) }
    private func navigationControls(compact: Bool) -> some View {
        HStack(spacing: 0) {
            icon("미리보기", "sidebar.left", id: "native-pdf-pages", active: model.showPages) { model.togglePages() }
            TextField("페이지", text: $entry).keyboardType(.numberPad).multilineTextAlignment(.center)
                .frame(width: 34, height: 44).font(.system(size: 13).monospacedDigit())
                .onSubmit { navigate() }.accessibilityIdentifier("native-pdf-page")
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("페이지로 이동") { navigate() } } }
            Text("/ \(model.pageCount)").font(.system(size: 13).monospacedDigit()).foregroundStyle(NativeDesktopTheme.muted)
                .accessibilityIdentifier("native-pdf-page-count")
            Menu {
                Button("이전 페이지") { model.go(to: model.page - 1) }.disabled(model.page <= 1)
                Button("다음 페이지") { model.go(to: model.page + 1) }.disabled(model.page >= model.pageCount)
                Button("페이지로 이동") { navigate() }
            } label: { Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 44, height: 44) }.accessibilityLabel("페이지 이동")
            if model.hasPageNoteAction && !compact { icon("페이지 필기", "doc.text", id: "native-pdf-page-note") { model.openPageNote() } }
            icon("주석 도구", "pencil.tip.crop.circle", id: "native-pdf-drawing-tools", active: model.toolsExpanded) { model.toggleTools() }
                .accessibilityValue("drawings=\(model.drawingCount) pending=\(model.pendingCount)")
                .accessibilityHint(model.pendingCount > 0 ? "필기 저장 중" : "모든 필기 저장됨")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func navigate() { model.go(to: Int(entry) ?? model.page); entry = String(model.page) }
    private var history: some View {
        HStack(spacing: 0) {
            icon("되돌리기", "arrow.uturn.backward", id: "native-pdf-undo") { model.undo() }.disabled(!model.canUndo)
            icon("다시 실행", "arrow.uturn.forward", id: "native-pdf-redo") { model.redo() }.disabled(!model.canRedo)
            icon("필기 포함 PDF 내보내기", "square.and.arrow.up", id: "native-pdf-export") { model.exportPDF() }
        }.fixedSize(horizontal: true, vertical: false)
    }
    static let tools = [("pen", "펜", "pencil.tip"), ("ballpoint", "볼펜", "pencil.line"), ("highlighter", "형광펜", "highlighter"), ("eraser", "지우개", "eraser"), ("text", "텍스트", "textformat"), ("lasso", "올가미", "lasso"), ("select", "손", "hand.point.up.left")]
    static func toolButton(_ model: NativePDFWorkspaceModel, _ value: (String, String, String)) -> some View {
        Button { model.chooseTool(value.0) } label: {
            Image(systemName: value.2).font(.system(size: 17)).frame(width: 44, height: 44)
                .foregroundStyle(model.tool == value.0 ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary)
                .background(model.tool == value.0 ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { if model.tool == value.0 { Capsule().fill(NativeDesktopTheme.accent).frame(width: 20, height: 2).padding(.bottom, 4) } }
                .contentShape(Rectangle())
        }.accessibilityLabel(value.1).accessibilityIdentifier("native-pdf-tool-" + value.0).accessibilityAddTraits(model.tool == value.0 ? .isSelected : []).help(value.1)
    }
    private var viewActions: some View {
        HStack(spacing: 0) {
            icon("축소", "minus", id: "native-pdf-zoom-out") { model.setZoom(model.zoom - 0.1) }
            Button { model.fitPage() } label: { Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit().font(.system(size: 12)).frame(width: 48, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("페이지 맞춤").accessibilityIdentifier("native-pdf-fit")
            icon("확대", "plus", id: "native-pdf-zoom-in") { model.setZoom(model.zoom + 0.1) }
            icon("PDF에서 찾기", "magnifyingglass", id: "native-pdf-search") { model.find() }
            Button { model.toggleAnnotations() } label: {
                HStack(spacing: 3) { Image(systemName: "text.bubble"); if model.annotationCount > 0 { Text(String(model.annotationCount)).font(.system(size: 10)) } }
                    .frame(minWidth: 44, minHeight: 44).background(model.showAnnotations ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            }.accessibilityLabel("원문 주석").accessibilityIdentifier("native-pdf-annotations").accessibilityValue(String(model.annotationCount))
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var compactViewActions: some View {
        Menu {
            if model.hasPageNoteAction {
                Button("페이지 필기", systemImage: "doc.text") { model.openPageNote() }.accessibilityIdentifier("native-pdf-page-note")
            }
            Button("축소", systemImage: "minus") { model.setZoom(model.zoom - 0.1) }
            Button("페이지 맞춤", systemImage: "arrow.up.left.and.arrow.down.right") { model.fitPage() }
            Button("확대", systemImage: "plus") { model.setZoom(model.zoom + 0.1) }
            Button("PDF에서 찾기", systemImage: "magnifyingglass") { model.find() }
            Button("원문 주석", systemImage: "text.bubble") { model.toggleAnnotations() }.accessibilityIdentifier("native-pdf-annotations").accessibilityValue(String(model.annotationCount))
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("PDF 보기 옵션")
    }
    private func icon(_ title: String, _ symbol: String, id: String, active: Bool = false, underline: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 44, height: 44)
                .foregroundStyle(active ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary)
                .background(active ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { if active && underline { Capsule().fill(NativeDesktopTheme.accent).frame(width: 20, height: 2).padding(.bottom, 4) } }
                .contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityIdentifier(id).accessibilityAddTraits(active ? .isSelected : []).help(title)
    }
}

/// Floats above the lasso/select box like a notebook app's selection menu.
struct NativePDFSelectionBar: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    let frame: CGRect
    @State private var size = CGSize(width: 420, height: 40)
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Menu {
                    Menu("색") { ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in Button(item.label) { model.restyleSelection(color: item.name) } } }
                    Menu("굵기") { ForEach(Array(NativePDFPaletteStyle.penWidths.enumerated()), id: \.offset) { index, width in Button(NativePDFPaletteLook.sizeNames[index]) { model.restyleSelection(width: width) } } }
                    Menu("불투명도") { ForEach([1.0, 0.6, 0.3], id: \.self) { value in Button("\(Int(value * 100))%") { model.restyleSelection(opacity: value) } } }
                } label: { action("스타일") }.accessibilityIdentifier("native-pdf-selection-style")
                if model.selectedText { Button { model.editSelectedText() } label: { action("텍스트 편집") }.accessibilityIdentifier("native-pdf-edit-text") }
                Button { model.duplicateSelection() } label: { action("복제") }.accessibilityIdentifier("native-pdf-duplicate-selection")
                Button { model.cutSelection() } label: { action("잘라내기") }.accessibilityIdentifier("native-pdf-cut-selection")
                Button { model.copySelection() } label: { action("복사") }.accessibilityIdentifier("native-pdf-copy-selection")
                Button { model.pasteObjects() } label: { action("붙여넣기") }.disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
                Button(role: .destructive) { model.deleteSelection() } label: { action("삭제").foregroundStyle(.red) }.accessibilityIdentifier("native-pdf-delete-selection")
                Button { model.clearSelection() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 36, height: 40).contentShape(Rectangle()) }.accessibilityLabel("선택 해제")
            }
            .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
            .padding(.horizontal, 6).frame(height: 40)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(NativeDesktopTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(x: min(max(frame.midX, size.width / 2 + 8), max(size.width / 2 + 8, geometry.size.width - size.width / 2 - 8)),
                      y: frame.minY - 28 > size.height ? frame.minY - 28 : min(frame.maxY + 28, geometry.size.height - 28))
        }.disabled(model.isBusy || model.errorMessage != nil)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-selection-bar")
    }
    private func action(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
    }
}

struct NativePDFPagesPanel: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    @State private var thumbnailHeights: [Int: CGFloat] = [:]
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("페이지").font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(model.pageCount)쪽").font(.system(size: 10)) }
                .foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12).frame(height: 40)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(1...max(1, model.pageCount), id: \.self) { number in
                            VStack(spacing: 0) {
                                insertionMarker(number)
                                thumbnail(number)
                            }.id(number)
                        }
                        insertionMarker(model.pageCount + 1).frame(height: 20)
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }
                .onChange(of: model.page) { _, page in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(page, anchor: .center) } }
            }
            Divider()
            HStack(spacing: 0) {
                Button { model.restorePageChange(undo: true) } label: { Image(systemName: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .disabled(!model.pageHistoryCanUndo).accessibilityLabel("페이지 변경 되돌리기").accessibilityIdentifier("native-pdf-pages-undo")
                Button { model.restorePageChange(undo: false) } label: { Image(systemName: "arrow.uturn.forward").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .disabled(!model.pageHistoryCanRedo).accessibilityLabel("페이지 변경 다시 실행").accessibilityIdentifier("native-pdf-pages-redo")
                Menu {
                    Button("변경 전 복구 사본 만들기") { model.recoverPageCopy() }.disabled(!model.pageHistoryCanRecover)
                    if let reason = model.pageHistoryReason { Text(reason) }
                } label: { Image(systemName: "clock.arrow.circlepath").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("페이지 복구").accessibilityIdentifier("native-pdf-pages-recovery")
            }
        }.background(NativeDesktopTheme.surface).buttonStyle(.plain)
            .disabled(model.isBusy || model.isLoading || model.errorMessage != nil)
    }
    private func insertionMarker(_ slot: Int) -> some View {
        Rectangle().fill(model.pageDropSlot == slot ? NativeDesktopTheme.accent : .clear).frame(height: 4)
            .onDrop(of: [UTType.text], delegate: NativePDFPageDropDelegate(model: model, slot: slot))
    }
    private func thumbnail(_ number: Int) -> some View {
        VStack(spacing: 0) {
            Button { model.go(to: number) } label: {
                NativePDFPageThumbnail(source: model.thumbnailSource, page: number)
                    .padding(3).overlay(RoundedRectangle(cornerRadius: 5).stroke(model.page == number ? NativeDesktopTheme.accent : .clear, lineWidth: 2))
            }.accessibilityLabel("\(number)페이지").accessibilityIdentifier("native-pdf-thumbnail-\(number)")
                .accessibilityAddTraits(model.page == number ? .isSelected : [])
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in thumbnailHeights[number] = height }
                })
                .onDrag { model.draggedPage = number; return NSItemProvider(object: (model.dragIdentity + ":" + String(number)) as NSString) }
                .onDrop(of: [UTType.text], delegate: NativePDFPageDropDelegate(model: model, slot: number, midpoint: thumbnailHeights[number].map { $0 / 2 }))
            HStack {
                Text(String(number)).font(.system(size: 11).monospacedDigit()).foregroundStyle(NativeDesktopTheme.muted)
                Spacer()
                Menu {
                    Button("위로 이동") { model.movePage(number, to: number - 1) }.disabled(number == 1 || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-move-up")
                    Button("아래로 이동") { model.movePage(number, to: number + 1) }.disabled(number == model.pageCount || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-move-down")
                    Button("페이지 삭제", role: .destructive) { model.requestDeletePage(number) }.disabled(model.pageCount == 1 || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-delete")
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("\(number)페이지 메뉴").accessibilityIdentifier("native-pdf-page-menu-\(number)")
            }.padding(.leading, 4)
        }
    }
}

private struct NativePDFPageDropDelegate: DropDelegate {
    let model: NativePDFWorkspaceModel
    let slot: Int
    var midpoint: CGFloat? = nil
    private func target(_ info: DropInfo) -> Int { slot + (midpoint.map { info.location.y > $0 } == true ? 1 : 0) }
    func validateDrop(info: DropInfo) -> Bool { model.draggedPage != nil && !model.isBusy && model.pageCanRestructure }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { model.pageDropSlot = target(info) } }
    func dropExited(info: DropInfo) { if model.pageDropSlot == slot || midpoint != nil && model.pageDropSlot == slot + 1 { model.pageDropSlot = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if validateDrop(info: info) { model.pageDropSlot = target(info); return DropProposal(operation: .move) }
        return DropProposal(operation: .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard let page = model.draggedPage, let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        let expected = model.dragIdentity + ":" + String(page), destination = target(info)
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let received = object as? String
            Task { @MainActor in
                guard received == expected else { model.draggedPage = nil; model.pageDropSlot = nil; return }
                model.dropPage(page, at: destination)
            }
        }
        return true
    }
}

struct NativePDFAnnotationRail: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("형광펜 · 메모").font(.system(size: 13, weight: .semibold)); Spacer(); Button { model.toggleAnnotations() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("주석 닫기") }.padding(.leading, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.annotationItems.isEmpty { Text("텍스트를 선택하면 형광펜과 메모를 추가할 수 있어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(.top, 8) }
                    ForEach(Array(Set(model.annotationItems.map(\.page))).sorted(), id: \.self) { page in
                        Text("p.\(page)").font(.system(size: 11, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted).padding(.top, 8)
                        ForEach(model.annotationItems.filter { $0.page == page }) { item in
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(NativePDFWorkspaceModel.annotationColors.first(where: { $0.name == item.color })?.color ?? .yellow).frame(width: 4)
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { model.go(to: item.page) } label: { Text(item.quote).font(.system(size: 13)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
                                    if !item.comment.isEmpty { Text(item.comment).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary) }
                                }.padding(.vertical, 10)
                                Button { model.openAnnotation(id: item.id) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                                    .accessibilityLabel("주석 편집").accessibilityIdentifier("native-pdf-annotation-" + item.id)
                            }.fixedSize(horizontal: false, vertical: true).background(NativeDesktopTheme.overlay, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.padding(12)
            }
        }.background(NativeDesktopTheme.surface).foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
            .disabled(model.isBusy || model.isLoading || model.errorMessage != nil)
    }
}
