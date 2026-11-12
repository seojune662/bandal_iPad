import SwiftUI
import UniformTypeIdentifiers

/// The thumbnails button at the top left of the page area, beside the pages panel it opens: in the palette's row
/// when the pill leaves room, otherwise in the band under it. The row it used to end is not in the design
/// (Figma 155:7503); what that row held (page jump, zoom, search, 원본 주석, 페이지 필기, and its zoom menu's fit,
/// hide tools and export) is in the menu a long press opens. VoiceOver opens it with the 보기 메뉴 action.
struct NativePDFViewButton: View {
    var model: NativePDFWorkspaceModel
    @State private var showMenu = false
    /// The palette's 34 pt cell in a glass circle as tall as the palette, 14 from the page area's left edge.
    static let size: CGFloat = 44, leading: CGFloat = 14
    private static let menuWidth: CGFloat = 260
    private var unavailable: Bool { model.isLoading || model.isBusy || model.errorMessage != nil }
    var body: some View {
        Image("PDFIconGrid").foregroundStyle(NativePDFPaletteLook.icon).frame(width: NativePDFPaletteLook.cell, height: NativePDFPaletteLook.cell)
            .background(model.showPages ? NativePDFPaletteLook.chosen : .clear, in: Circle())
            .frame(width: Self.size, height: Self.size).contentShape(Circle()).bandalGlass(in: Circle())
            .onTapGesture { model.togglePages() }
            .onLongPressGesture(minimumDuration: 0.4) { showMenu = true }
            // A real button for assistive technology and UI tests: its traits and enabled state are the system's.
            .accessibilityRepresentation {
                Button("미리보기") { model.togglePages() }.disabled(unavailable)
                    .accessibilityValue("\(model.page) / \(model.pageCount)").accessibilityHint("길게 누르면 페이지 이동과 보기 메뉴가 열립니다")
                    .accessibilityAddTraits(model.showPages ? .isSelected : []).accessibilityAction(named: "보기 메뉴") { showMenu = true }
                    .accessibilityIdentifier("native-pdf-pages")
            }
            // Under the button, their left edges in line: the menu stays inside a narrow pane.
            .bandalPopover(isPresented: $showMenu, at: .bottom, offset: CGSize(width: (Self.menuWidth - Self.size) / 2, height: 0), width: Self.menuWidth, padding: 8) {
                NativePDFViewMenu(model: model) { showMenu = false }
            }
            .background { saveStatus }
            .disabled(unavailable)
    }
    /// Save state for assistive technology and UI tests; activating it shows or hides the tools.
    private var saveStatus: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel("주석 도구").accessibilityIdentifier("native-pdf-drawing-tools")
            .accessibilityValue("drawings=\(model.drawingCount) pending=\(model.pendingCount)")
            .accessibilityHint(model.pendingCount > 0 ? "필기 저장 중" : "모든 필기 저장됨")
            .accessibilityAction { model.toggleTools() }
    }
}

/// The long-press menu of the thumbnails button. Every control keeps the identifier it had in the row.
private struct NativePDFViewMenu: View {
    var model: NativePDFWorkspaceModel
    let close: () -> Void
    @State private var entry: String
    init(model: NativePDFWorkspaceModel, close: @escaping () -> Void) {
        self.model = model; self.close = close; _entry = State(initialValue: String(model.page))
    }
    var body: some View {
        BandalMenu {
            HStack(spacing: 0) {
                step("이전 페이지", "chevron.left", id: "native-pdf-page-previous", enabled: model.page > 1) { model.go(to: model.page - 1) }
                Spacer(minLength: 0)
                pageBox
                Spacer(minLength: 0)
                step("다음 페이지", "chevron.right", id: "native-pdf-page-next", enabled: model.page < model.pageCount) { model.go(to: model.page + 1) }
            }
            HStack(spacing: 0) {
                step("축소", "minus", id: "native-pdf-zoom-out") { model.setZoom(model.zoom - 0.1) }
                Spacer(minLength: 0)
                Text(verbatim: "\(Int((model.zoom * 100).rounded()))%").font(.system(size: 16, weight: .medium)).monospacedDigit()
                    .accessibilityLabel("배율").accessibilityValue("\(Int((model.zoom * 100).rounded()))%").accessibilityIdentifier("native-pdf-zoom")
                Spacer(minLength: 0)
                step("확대", "plus", id: "native-pdf-zoom-in") { model.setZoom(model.zoom + 0.1) }
            }
            row("페이지 맞춤", "arrow.up.left.and.arrow.down.right", id: "native-pdf-fit") { model.fitPage() }
            BandalMenuDivider()
            row("PDF에서 찾기", "magnifyingglass", id: "native-pdf-search") { model.find() }
            BandalMenuRow("원본 주석", asset: "PDFIconAnnotations", checked: model.showAnnotations) { close(); model.toggleAnnotations() }
                .accessibilityValue(String(model.annotationCount)).accessibilityIdentifier("native-pdf-annotations")
            if model.hasPageNoteAction {
                BandalMenuRow("페이지 필기", asset: "PDFIconPageNote") { close(); model.openPageNote() }.accessibilityIdentifier("native-pdf-page-note")
            }
            BandalMenuDivider()
            if !model.toolsExpanded {
                row("되돌리기", "arrow.uturn.backward", id: "native-pdf-undo", closes: false) { model.undo() }.disabled(!model.canUndo && !model.isEditingText)
                row("다시 실행", "arrow.uturn.forward", id: "native-pdf-redo", closes: false) { model.redo() }.disabled(!model.canRedo && !model.isEditingText)
            }
            row(model.toolsExpanded ? "필기 도구 숨기기" : "필기 도구 보이기", "pencil.tip.crop.circle", id: "native-pdf-toggle-tools") { model.toggleTools() }
            row("필기 포함 PDF 내보내기", "square.and.arrow.up", id: "native-pdf-export") { model.exportPDF() }
        }
        .onChange(of: model.page) { _, value in entry = String(value) }
    }
    /// The current page is the entry itself: tap the box, type a number, press return.
    private var pageBox: some View {
        HStack(spacing: 4) {
            TextField("", text: $entry).keyboardType(.numbersAndPunctuation).submitLabel(.go).multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .semibold)).fixedSize().frame(minWidth: 10)
                .onSubmit { navigate() }.accessibilityLabel("페이지").accessibilityIdentifier("native-pdf-page")
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("페이지로 이동") { navigate() } } }
            Text(verbatim: "/ \(model.pageCount)").font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.secondary)
                .accessibilityIdentifier("native-pdf-page-count")
        }.padding(.horizontal, 12).frame(height: 34).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 8))
    }
    private func navigate() { model.go(to: Int(entry) ?? model.page); entry = String(model.page) }
    private func step(_ title: LocalizedStringKey, _ symbol: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(NativeGlass.icon).opacity(enabled ? 1 : 0.35)
                .frame(width: 44, height: BandalMetrics.rowHeight).contentShape(Rectangle())
        }.buttonStyle(BandalRowStyle()).disabled(!enabled).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func row(_ title: String, _ symbol: String, id: String, closes: Bool = true, action: @escaping () -> Void) -> some View {
        BandalMenuRow(title, symbol: symbol) { if closes { close() }; action() }.accessibilityIdentifier(id)
    }
}

/// The selection menu (Figma 260:8643): a glass bar above the lasso/select box (below it when there is no room)
/// with 잘라내기 · 복사 · 삭제 · 복제 | 스타일 ›. What the design does not show (텍스트 편집, 이미지로 복사, 붙여넣기,
/// 불투명도, 선택 해제) is behind ⋯. With nothing selected the bar is the paste menu of a long press, or the
/// image copy of an empty lasso.
struct NativePDFSelectionBar: View {
    var model: NativePDFWorkspaceModel
    let frame: CGRect
    @State private var width: CGFloat = 331
    @State private var showStyle = false
    @State private var showMore = false
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                if model.selectionCount > 0 {
                    Button { model.cutSelection() } label: { action("잘라내기") }.disabled(model.isCopyingSelection).accessibilityIdentifier("native-pdf-cut-selection")
                    Button { model.copySelection() } label: { action(model.isCopyingSelection ? "복사 중…" : "복사") }.disabled(model.isCopyingSelection).accessibilityIdentifier("native-pdf-copy-selection")
                    Button { model.deleteSelection() } label: { action("삭제") }.accessibilityIdentifier("native-pdf-delete-selection")
                    Button { model.duplicateSelection() } label: { action("복제") }.accessibilityIdentifier("native-pdf-duplicate-selection")
                    Rectangle().fill(NativeGlass.separator).frame(width: 1, height: 20)
                    Button { showStyle = true } label: {
                        HStack(spacing: 4) { Text("스타일").font(.system(size: 14, weight: .medium)); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.secondary) }
                            .padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                    }.accessibilityLabel("스타일").accessibilityIdentifier("native-pdf-selection-style")
                        .bandalPopover(isPresented: $showStyle, arrowEdge: nil, width: 252, radius: 22, padding: 18, dims: false) { NativePDFSelectionStyle(model: model) }
                    Button { showMore = true } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36).contentShape(Rectangle()) }
                        .accessibilityLabel("선택 더 보기").accessibilityIdentifier("native-pdf-selection-more")
                        .bandalPopover(isPresented: $showMore, arrowEdge: nil, width: 240, radius: 14, padding: 8, dims: false) { more }
                } else {
                    if model.selectedRegion != nil { copyRegion }
                    Button { model.pasteObjects() } label: { action("붙여넣기") }
                        .disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
                    Button { model.clearSelection() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.accessibilityLabel("선택 해제")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6).fixedSize()
            .buttonStyle(BandalRowStyle()).foregroundStyle(NativeDesktopTheme.text)
            .bandalGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), adaptive: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .position(x: min(max(frame.midX, width / 2 + 8), max(width / 2 + 8, geometry.size.width - width / 2 - 8)),
                      y: frame.minY - 40 > 40 ? frame.minY - 40 : min(frame.maxY + 40, geometry.size.height - 32))
        }.disabled(model.isBusy || model.errorMessage != nil)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-selection-bar")
    }
    private var copyRegion: some View {
        Button { model.copyPDFRegion() } label: {
            if model.isCopyingRegion { ProgressView().frame(width: 92, height: 36) } else { action("이미지로 복사") }
        }.disabled(model.isCopyingRegion).accessibilityIdentifier("native-pdf-copy-region")
    }
    private var more: some View {
        BandalMenu {
            if model.selectedText { BandalMenuRow("텍스트 편집", symbol: "character.cursor.ibeam") { showMore = false; model.editSelectedText() }.accessibilityIdentifier("native-pdf-edit-text") }
            BandalMenuRow("이미지로 복사", symbol: "photo.on.rectangle") { showMore = false; model.copyPDFRegion() }.disabled(model.isCopyingRegion).accessibilityIdentifier("native-pdf-copy-region")
            BandalMenuRow("붙여넣기", symbol: "square.and.pencil") { showMore = false; model.pasteObjects() }.disabled(!model.canPaste).accessibilityIdentifier("native-pdf-paste")
            BandalMenuDivider()
            ForEach([1.0, 0.6, 0.3], id: \.self) { value in
                BandalMenuRow("불투명도 \(Int(value * 100))%", symbol: "circle.lefthalf.filled") { showMore = false; model.restyleSelection(opacity: value) }
            }
            BandalMenuDivider()
            BandalMenuRow("선택 해제", symbol: "xmark") { showMore = false; model.clearSelection() }.accessibilityIdentifier("native-pdf-clear-selection")
        }
    }
    private func action(_ title: String) -> some View {
        Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .medium)).lineLimit(1).padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
    }
}

/// 스타일 (Figma 260:8678): the pen's colours and three thicknesses for what is selected.
/// 글자로 바꾸기 needs handwriting recognition, which the app does not have: it is drawn and says 준비 중.
struct NativePDFSelectionStyle: View {
    var model: NativePDFWorkspaceModel
    private static let weights: [CGFloat] = [2, 4, 7]
    var body: some View {
        let style = model.selectionStyle, steps = model.palette.widths(for: "pen")
        VStack(alignment: .leading, spacing: 14) {
            NativePDFPopoverTitle("스타일")
            NativePDFPopoverCaption("색")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.palette.colors(for: "pen"), id: \.self) { name in
                        NativePDFColorCell(color: NativePDFPaletteLook.swatch(name), chosen: style.color == name, rimmed: name == "ink") { model.restyleSelection(color: name) }
                            .accessibilityLabel(NativePDFPaletteLook.colorName(name) + " 색상").accessibilityIdentifier("native-pdf-selection-color-" + name)
                    }
                }
            }.frame(height: 36)
            NativePDFPopoverCaption("굵기")
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let value = NativePDFPaletteStyle.penSteps[step], chosen = style.width.map { abs($0 - value) < 0.0000001 } == true
                    Button { model.restyleSelection(width: value) } label: {
                        NativePDFSquiggle.weight.stroke(NativeDesktopTheme.text, style: StrokeStyle(lineWidth: Self.weights[min(index, 2)], lineCap: .round, lineJoin: .round))
                            .frame(width: 44, height: 16).frame(maxWidth: .infinity).frame(height: 38)
                            .background(chosen ? NativeGlass.tool : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
                    }.accessibilityLabel("굵기 " + NativePDFPaletteStyle.stepLabel(step)).accessibilityIdentifier("native-pdf-selection-width-\(index)")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Button { model.paletteNotice = "글자로 바꾸기는 준비 중이에요" } label: {
                Text("글자로 바꾸기").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 43)
                    .background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).contentShape(Rectangle())
            }.accessibilityLabel("글자로 바꾸기 (준비 중)").accessibilityIdentifier("native-pdf-selection-to-text")
        }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text).disabled(model.isBusy || model.errorMessage != nil)
    }
}

struct NativePDFPagesPanel: View {
    var model: NativePDFWorkspaceModel
    /// Every thumbnail shares one fixed aspect ratio, so one measured height
    /// serves all rows; per-row writes re-rendered the whole panel per page.
    @State private var thumbnailHeight: CGFloat?
    @Environment(\.locale) private var locale
    var body: some View {
        // While the document is searched only the pages with a match stay, each with its count.
        let counts = model.search.counts
        let pages = (1...max(1, model.pageCount)).filter { counts == nil || counts?[$0] != nil }
        VStack(spacing: 0) {
            HStack {
                Text("페이지").font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(model.pageCount)쪽").font(.system(size: 10))
                Button { model.addPage(after: model.pageCount) } label: { Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .disabled(!model.pageCanAppend).accessibilityLabel("페이지 추가").accessibilityIdentifier("native-pdf-page-add")
            }
                .foregroundStyle(NativeDesktopTheme.muted).padding(.leading, 12).padding(.trailing, 4).frame(height: 40)
            NativePDFPagesSearchField(search: model.search).padding(.horizontal, 12).padding(.bottom, 8)
            if !model.pageCanRestructure, model.pageCanAppend, let reason = model.pageHistoryReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("native-pdf-pages-sync-note")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(pages, id: \.self) { number in
                            VStack(spacing: 0) {
                                if counts == nil { insertionMarker(number) }
                                thumbnail(number, matches: counts?[number])
                            }.id(number)
                        }
                        if counts == nil { insertionMarker(model.pageCount + 1).frame(height: 20) }
                        else if pages.isEmpty {
                            Text("결과 없음").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(.top, 16).accessibilityIdentifier("native-pdf-pages-empty")
                        }
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
    private func thumbnail(_ number: Int, matches: Int? = nil) -> some View {
        VStack(spacing: 0) {
            Button { model.go(to: number) } label: {
                NativePDFPageThumbnail(source: model.thumbnailSource, page: number, rows: model.thumbnailRows(number), inkRevision: model.thumbnailRevisions[number] ?? 0)
                    .padding(3).overlay(RoundedRectangle(cornerRadius: 5).stroke(model.page == number ? NativeDesktopTheme.accent : .clear, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if let matches {
                            Text(verbatim: String(matches)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.black)
                                .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(Color(uiColor: NativePDFSearchMarksView.match), in: Capsule())
                                .padding(6)
                        }
                    }
            }.accessibilityValue(matches.map { String(format: NativeAppLocale.string("일치 %lld곳", locale), $0) } ?? "").accessibilityLabel("\(number)페이지").accessibilityIdentifier("native-pdf-thumbnail-\(number)")
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
    // A filtered list hides the pages a drop would land between.
    func validateDrop(info: DropInfo) -> Bool { model.draggedPage != nil && !model.isBusy && model.pageCanRestructure && model.search.counts == nil }
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
