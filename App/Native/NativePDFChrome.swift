import SwiftUI
import UniformTypeIdentifiers

/// The floating row above the page (Figma 269:8679): pages · zoom · search · view pills · thumbnails.
/// Controls the design does not show (zoom steps, fit, export, hiding the tools, history while the
/// palette is hidden) live in the "100% ∨" menu.
struct NativePDFToolbar: View {
    var model: NativePDFWorkspaceModel
    var writingOnly = false
    @State private var entry = "1"
    @State private var showZoomMenu = false
    static let height: CGFloat = 54, top: CGFloat = 10
    var body: some View {
        Group {
            if !writingOnly {
                ViewThatFits(in: .horizontal) { row(compact: false); row(compact: true) }
                    .background { saveStatus }
                    .padding(.horizontal, 10).frame(height: Self.height)
                    .bandalGlass(in: Capsule())
                    .padding(.horizontal, 8).padding(.top, Self.top)
            }
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .buttonStyle(.plain)
        .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
        .onChange(of: model.page, initial: true) { _, value in entry = String(value) }
    }
    private func row(compact: Bool) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                icon("이전 페이지", id: "native-pdf-page-previous") { Image(systemName: "chevron.left").font(.system(size: 17)) } action: { model.go(to: model.page - 1) }
                    .disabled(model.page <= 1)
                pageBox
                icon("다음 페이지", id: "native-pdf-page-next") { Image(systemName: "chevron.right").font(.system(size: 17)) } action: { model.go(to: model.page + 1) }
                    .disabled(model.page >= model.pageCount)
            }
            Spacer(minLength: 0)
            zoom(compact: compact)
            separator
            icon("PDF에서 찾기", id: "native-pdf-search") { Image(systemName: "magnifyingglass").font(.system(size: 17)) } action: { model.find() }
            if !compact {
                pill("원본 주석", "PDFIconAnnotations", id: "native-pdf-annotations", active: model.showAnnotations) { model.toggleAnnotations() }
                    .accessibilityValue(String(model.annotationCount))
                if model.hasPageNoteAction { pill("페이지 필기", "PDFIconPageNote", id: "native-pdf-page-note") { model.openPageNote() } }
            }
            separator
            icon("미리보기", id: "native-pdf-pages", active: model.showPages) { Image("PDFIconGrid") } action: { model.togglePages() }
        }
    }
    private var separator: some View { Rectangle().fill(NativeGlass.separator).frame(width: 1, height: 20) }
    /// The current page is the entry itself: tap the box, type a number, press return.
    private var pageBox: some View {
        HStack(spacing: 4) {
            TextField("", text: $entry).keyboardType(.numbersAndPunctuation).submitLabel(.go).multilineTextAlignment(.center)
                .font(.system(size: 14, weight: .semibold)).fixedSize().frame(minWidth: 9)
                .onSubmit { navigate() }.accessibilityLabel("페이지").accessibilityIdentifier("native-pdf-page")
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("페이지로 이동") { navigate() } } }
            Text(verbatim: "/ \(model.pageCount)").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary)
                .accessibilityIdentifier("native-pdf-page-count")
        }.padding(.horizontal, 10).frame(height: 32).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 8))
    }
    private func navigate() { model.go(to: Int(entry) ?? model.page); entry = String(model.page) }
    private func zoom(compact: Bool) -> some View {
        Button { showZoomMenu = true } label: {
            HStack(spacing: 4) {
                Text(verbatim: "\(Int((model.zoom * 100).rounded()))%").font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.secondary)
            }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
        }.accessibilityLabel("배율").accessibilityIdentifier("native-pdf-zoom")
            .bandalPopover(isPresented: $showZoomMenu, width: 260, padding: 8) {
                BandalMenu {
                    menuRow("확대", "plus.magnifyingglass", id: "native-pdf-zoom-in", closes: false) { model.setZoom(model.zoom + 0.1) }
                    menuRow("축소", "minus.magnifyingglass", id: "native-pdf-zoom-out", closes: false) { model.setZoom(model.zoom - 0.1) }
                    menuRow("페이지 맞춤", "arrow.up.left.and.arrow.down.right", id: "native-pdf-fit") { model.fitPage() }
                    BandalMenuDivider()
                    if compact {
                        menuRow("원본 주석", "doc.text", id: "native-pdf-annotations") { model.toggleAnnotations() }
                        if model.hasPageNoteAction { menuRow("페이지 필기", "pencil", id: "native-pdf-page-note") { model.openPageNote() } }
                    }
                    if !model.toolsExpanded {
                        menuRow("되돌리기", "arrow.uturn.backward", id: "native-pdf-undo", closes: false) { model.undo() }.disabled(!model.canUndo && !model.isEditingText)
                        menuRow("다시 실행", "arrow.uturn.forward", id: "native-pdf-redo", closes: false) { model.redo() }.disabled(!model.canRedo && !model.isEditingText)
                    }
                    menuRow(model.toolsExpanded ? "필기 도구 숨기기" : "필기 도구 보이기", "pencil.tip.crop.circle", id: "native-pdf-toggle-tools") { model.toggleTools() }
                    menuRow("필기 포함 PDF 내보내기", "square.and.arrow.up", id: "native-pdf-export") { model.exportPDF() }
                }
            }
    }
    private func menuRow(_ title: String, _ symbol: String, id: String, closes: Bool = true, action: @escaping () -> Void) -> some View {
        BandalMenuRow(title, symbol: symbol) { if closes { showZoomMenu = false }; action() }.accessibilityIdentifier(id)
    }
    /// Save state for assistive technology and UI tests; activating it shows or hides the tools.
    private var saveStatus: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel("주석 도구").accessibilityIdentifier("native-pdf-drawing-tools")
            .accessibilityValue("drawings=\(model.drawingCount) pending=\(model.pendingCount)")
            .accessibilityHint(model.pendingCount > 0 ? "필기 저장 중" : "모든 필기 저장됨")
            .accessibilityAction { model.toggleTools() }
    }
    private func pill(_ title: LocalizedStringKey, _ image: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(image)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }.padding(.horizontal, 10).frame(height: 34)
                .background(active ? NativeDesktopTheme.raised : NativeGlass.tool, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.accessibilityIdentifier(id).accessibilityAddTraits(active ? .isSelected : []).fixedSize()
    }
    private func icon<Label: View>(_ title: LocalizedStringKey, id: String, active: Bool = false, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label().frame(width: 38, height: 38)
                .background(active ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityIdentifier(id).accessibilityAddTraits(active ? .isSelected : []).help(title)
    }
}

/// Floats above the lasso/select box like a notebook app's selection menu.
struct NativePDFSelectionBar: View {
    var model: NativePDFWorkspaceModel
    let frame: CGRect
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 16, model.selectionCount > 0 ? (model.selectedText ? 650.0 : 580.0) : (model.selectedRegion != nil ? 250.0 : 150.0))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Notability order: cut · copy · delete · duplicate, then style and the rest.
                    if model.selectionCount > 0 {
                        Button { model.cutSelection() } label: { action("잘라내기") }.disabled(model.isCopyingSelection).accessibilityIdentifier("native-pdf-cut-selection")
                        Button { model.copySelection() } label: { action(model.isCopyingSelection ? "복사 중…" : "복사") }.disabled(model.isCopyingSelection).accessibilityIdentifier("native-pdf-copy-selection")
                        Button(role: .destructive) { model.deleteSelection() } label: { action("삭제").foregroundStyle(.red) }.accessibilityIdentifier("native-pdf-delete-selection")
                        Button { model.duplicateSelection() } label: { action("복제") }.accessibilityIdentifier("native-pdf-duplicate-selection")
                        Menu {
                            Menu("색") { ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in Button(item.label) { model.restyleSelection(color: item.name) } } }
                            Menu("굵기") { ForEach(model.palette.widths(for: "pen"), id: \.self) { step in Button("굵기 " + NativePDFPaletteStyle.stepLabel(step)) { model.restyleSelection(width: NativePDFPaletteStyle.penSteps[step]) } } }
                            Menu("불투명도") { ForEach([1.0, 0.6, 0.3], id: \.self) { value in Button("\(Int(value * 100))%") { model.restyleSelection(opacity: value) } } }
                        } label: { action("스타일") }.accessibilityIdentifier("native-pdf-selection-style")
                        if model.selectedText { Button { model.editSelectedText() } label: { action("텍스트 편집") }.accessibilityIdentifier("native-pdf-edit-text") }
                    }
                    if model.selectedRegion != nil || model.selectionCount > 0 {
                        Button { model.copyPDFRegion() } label: {
                            if model.isCopyingRegion { ProgressView().frame(width: 92, height: 40) }
                            else { action("이미지로 복사") }
                        }.disabled(model.isCopyingRegion).accessibilityIdentifier("native-pdf-copy-region")
                    }
                    Button { model.pasteObjects() } label: { action("붙여넣기") }
                        .disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
                    Button { model.clearSelection() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 36, height: 40).contentShape(Rectangle())
                    }.accessibilityLabel("선택 해제")
                }.padding(.horizontal, 6)
            }
            .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
            .frame(width: max(1, width), height: 40)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(NativeDesktopTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .position(x: min(max(frame.midX, width / 2 + 8), max(width / 2 + 8, geometry.size.width - width / 2 - 8)),
                      y: frame.minY - 28 > 40 ? frame.minY - 28 : min(frame.maxY + 28, geometry.size.height - 28))
        }.disabled(model.isBusy || model.errorMessage != nil)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-selection-bar")
    }
    private func action(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
    }
}

struct NativePDFPagesPanel: View {
    var model: NativePDFWorkspaceModel
    /// Every thumbnail shares one fixed aspect ratio, so one measured height
    /// serves all rows; per-row writes re-rendered the whole panel per page.
    @State private var thumbnailHeight: CGFloat?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("페이지").font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(model.pageCount)쪽").font(.system(size: 10))
                Button { model.addPage(after: model.pageCount) } label: { Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .disabled(!model.pageCanAppend).accessibilityLabel("페이지 추가").accessibilityIdentifier("native-pdf-page-add")
            }
                .foregroundStyle(NativeDesktopTheme.muted).padding(.leading, 12).padding(.trailing, 4).frame(height: 40)
            if !model.pageCanRestructure, model.pageCanAppend, let reason = model.pageHistoryReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("native-pdf-pages-sync-note")
            }
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
    /// A page action disables this panel; running it inside the menu action
    /// disabled the menu's own label while UIKit was still dismissing it.
    private func afterMenu(_ action: @escaping @MainActor () -> Void) { Task { @MainActor in action() } }
    private func insertionMarker(_ slot: Int) -> some View {
        Rectangle().fill(model.pageDropSlot == slot ? NativeDesktopTheme.accent : .clear).frame(height: 4)
            .onDrop(of: [UTType.text], delegate: NativePDFPageDropDelegate(model: model, slot: slot))
    }
    private func thumbnail(_ number: Int) -> some View {
        VStack(spacing: 0) {
            Button { model.go(to: number) } label: {
                NativePDFPageThumbnail(source: model.thumbnailSource, page: number, rows: model.thumbnailRows(number), inkRevision: model.thumbnailRevisions[number] ?? 0)
                    .padding(3).overlay(RoundedRectangle(cornerRadius: 5).stroke(model.page == number ? NativeDesktopTheme.accent : .clear, lineWidth: 2))
            }.accessibilityLabel("\(number)페이지").accessibilityIdentifier("native-pdf-thumbnail-\(number)")
                .accessibilityAddTraits(model.page == number ? .isSelected : [])
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if thumbnailHeight != height { thumbnailHeight = height }
                }
                .onDrag { model.draggedPage = number; return NSItemProvider(object: (model.dragIdentity + ":" + String(number)) as NSString) }
                .onDrop(of: [UTType.text], delegate: NativePDFPageDropDelegate(model: model, slot: number, midpoint: thumbnailHeight.map { $0 / 2 }))
            HStack {
                Text(String(number)).font(.system(size: 11).monospacedDigit()).foregroundStyle(NativeDesktopTheme.muted)
                Spacer()
                Menu {
                    Button("아래에 페이지 추가") { afterMenu { model.addPage(after: number) } }.disabled(!(model.pageCanRestructure || model.pageCanAppend && number == model.pageCount)).accessibilityIdentifier("native-pdf-page-insert-below")
                    Button("위로 이동") { afterMenu { model.movePage(number, to: number - 1) } }.disabled(number == 1 || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-move-up")
                    Button("아래로 이동") { afterMenu { model.movePage(number, to: number + 1) } }.disabled(number == model.pageCount || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-move-down")
                    Button("페이지 삭제", role: .destructive) { afterMenu { model.requestDeletePage(number) } }.disabled(model.pageCount == 1 || !model.pageCanRestructure).accessibilityIdentifier("native-pdf-page-delete")
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
    var model: NativePDFWorkspaceModel
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
