import SwiftUI

/// Visual contract (Figma 155:7571): one glass pill under the tab strip with history · tools · colours ·
/// three thicknesses · collapse. A second tap on the chosen tool opens its popover under the button
/// (`NativePDFPenSettings`, `NativePDFToolPopovers`).
@MainActor enum NativePDFPaletteLook {
    static let colorNames = ["ink": "먹색", "red": "빨강", "orange": "주황", "yellow": "노랑", "green": "초록", "blue": "파랑", "violet": "보라"]
    static func colorName(_ color: String) -> String { colorNames[color] ?? color }
    static func uiColor(_ color: String) -> Color { Color(uiColor: NativePDFInkSurface.color(color)) }
    /// Palette order: the first `shownTools` show, the rest slide in from the right of the same strip.
    /// The 22 pt line icons are the design's own vectors.
    static let tools = [("pen", "펜", "PDFIconPen"), ("highlighter", "형광펜", "PDFIconHighlighter"), ("eraser", "지우개", "PDFIconEraser"),
                        ("lasso", "올가미", "PDFIconLasso"), ("text", "텍스트", "PDFIconText"), ("tape", "테이프", "PDFIconTape"),
                        ("laser", "레이저 포인터", "PDFIconLaser"), ("comment", "댓글", "PDFIconComment"), ("select", "손", "PDFIconHand")]
    static let shownTools = 5
    static func toolImage(_ tool: String) -> String { tools.first { $0.0 == tool }?.2 ?? "PDFIconPen" }
    /// One palette cell, and the row it sits in.
    static let cell: CGFloat = 34
    static let icon = NativeDesktopTheme.adaptive(0x6b6b6b, 0x9a9a9a)
    static let chosen = alpha(black: 0.07, white: 0.10)
    static let divider = alpha(black: 0.08, white: 0.11)
    static let ring = alpha(black: 0.85, white: 1)
    static let addRing = alpha(black: 0.20, white: 0.28)
    /// A thickness dot (155:7651): the chosen one solid, the others a step lighter.
    static let dot = NativeDesktopTheme.adaptive(0x1a1a1a, 0xededed)
    static let dotIdle = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.98) : UIColor(white: 0x1a / 255, alpha: 0.7) })
    /// A swatch on the palette: 먹색 reads light on the dark glass, the ink itself stays dark on the page.
    static func swatch(_ color: String, tape: Bool = false) -> Color {
        tape ? Color(uiColor: NativePDFObjectRenderer.tapeColor(color)) : color == "ink" ? NativeDesktopTheme.adaptive(0x1a1a1a, 0xededed) : uiColor(color)
    }
    private static func alpha(black: CGFloat, white: CGFloat) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(white) : UIColor.black.withAlphaComponent(black) })
    }
}

/// Where the window draws a PDF pane's palette: above the side panels, centred on the page area.
/// A pane registers its page area here; with one pane the window floats the palette, otherwise each pane keeps its own.
@MainActor @Observable final class NativePDFPaletteHost {
    /// `top`: the palette's distance from the top of the page area.
    struct Entry { let model: NativePDFWorkspaceModel; var frame: CGRect; var top = NativePDFFloatingPalette.top }
    var entries: [String: Entry] = [:]
    /// The floating pill's own frame, global: the side panels only start under it where it actually covers them.
    var paletteFrame = CGRect.zero
    /// A drawer covers the document, or another pane sits beside it: the palette stays inside its pane.
    var suspended = false
    func floats(_ id: String) -> Bool { !suspended && entries.count == 1 && entries[id] != nil }
}
extension EnvironmentValues { @Entry var nativePDFPaletteHost: NativePDFPaletteHost? = nil }

struct NativePDFPaletteLayer: View {
    var host: NativePDFPaletteHost
    var covered = false
    var body: some View {
        GeometryReader { geometry in
            if !host.suspended, host.entries.count == 1, let entry = host.entries.values.first {
                let origin = geometry.frame(in: .global).origin, middle = entry.frame.midX - origin.x
                // Centred on the page area and kept inside it, clear of the thumbnails button at its left
                // (and as far from the right, to stay centred): with both side panels open the pill
                // compacts rather than spilling over them or pushing that button down.
                let half = max(0, min(entry.frame.width / 2 - NativePDFFloatingPalette.sideReserve, min(middle, geometry.size.width - middle) - 8))
                NativePDFFloatingPalette(model: entry.model, onFrame: { host.paletteFrame = $0 }).frame(width: half * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: middle - half, y: entry.frame.minY - origin.y + entry.top)
            }
        }.onChange(of: covered, initial: true) { _, value in host.suspended = value; if value { host.paletteFrame = .zero } }
    }
}

/// The glass pill floating over the page (Figma 155:7571): history · tools · colours · thicknesses · collapse.
/// Collapsed (130:4713) it keeps only the current tool and colour.
struct NativePDFFloatingPalette: View {
    var model: NativePDFWorkspaceModel
    /// The pill's global frame, for the views that must stay clear of it.
    var onFrame: ((CGRect) -> Void)? = nil
    @AppStorage("native.pdf.paletteCollapsed") private var collapsed = false
    /// Its gap below the tab strip and its height: the 34 pt row and 5 pt above and below.
    static let top: CGFloat = 14, height: CGFloat = 44
    /// What the pill leaves free at each side of the page area: the thumbnails button and a gap.
    static let sideReserve = NativePDFViewButton.leading + NativePDFViewButton.width + 8
    /// Narrower and narrower rows, tried in order: the colours give way first, then the tools.
    /// (tools shown in their strip, colours shown in theirs; nil shows every colour.)
    private static let stages: [(tools: CGFloat, colors: Int?)] = [(5.5, nil), (5.5, 3), (3.5, 3), (3.5, 2), (2.5, 2), (1.5, 1)]
    var body: some View {
        Group {
            if collapsed { mini } else {
                // Hug the row when it fits; shrink the colours, then the tools, each into a strip that slides;
                // only when even that does not fit does the whole row scroll.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(Self.stages.enumerated()), id: \.offset) { _, stage in
                        NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true }, shownTools: stage.tools, shownColors: stage.colors)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    // Too narrow for the pill: the whole row scrolls, with every tool in it (no second scroller inside).
                    ScrollView(.horizontal, showsIndicators: false) {
                        NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true }, slidingTools: false).fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 5)
                    }.padding(.vertical, -5).accessibilityIdentifier("native-pdf-palette-scroll")
                }.padding(.horizontal, 8)
            }
        }.padding(.vertical, 5).bandalGlass(in: Capsule())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame?($0) }
        .foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
        .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
    }
    private var mini: some View {
        Button { collapsed = false } label: {
            HStack(spacing: 6) {
                Image(NativePDFPaletteLook.toolImage(model.isPenLike ? "pen" : model.tool)).foregroundStyle(NativeDesktopTheme.text)
                    .frame(width: 34, height: 34).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                if model.usesColorSlots {
                    Circle().fill(NativePDFPaletteLook.swatch(model.activeColor, tape: model.tool == "tape")).frame(width: 16, height: 16)
                        .frame(width: 26, height: 26).overlay(Circle().strokeBorder(NativeDesktopTheme.accent, lineWidth: 2))
                }
                Rectangle().fill(NativeGlass.separator).frame(width: 1, height: 20)
                Image(systemName: "chevron.up").font(.system(size: 16)).frame(width: 34, height: 34)
            }.padding(.horizontal, 6).contentShape(Rectangle())
        }.accessibilityLabel("팔레트 펼치기").accessibilityIdentifier("native-pdf-palette-expand")
    }
}

/// The palette row. Its cells never change with the tool; a tool's own options open in a popover under its button.
struct NativePDFPaletteQuickControls: View {
    var model: NativePDFWorkspaceModel
    var collapse: (() -> Void)? = nil
    /// The tools slide inside their own strip; off in a row that itself scrolls.
    var slidingTools = true
    /// How many tool cells the strip shows (a half cell hints at more).
    var shownTools = CGFloat(NativePDFPaletteLook.shownTools) + 0.5
    /// How many swatches show before the rest slide; nil shows them all.
    var shownColors: Int? = nil
    private static let spacing: CGFloat = 4
    @State private var moreColorsLeft = false
    @State private var moreColorsRight = false
    @State private var moreLeft = false
    @State private var moreRight = false
    var body: some View {
        // History · tools · colours · thicknesses stay put; only the tool strip slides.
        HStack(spacing: Self.spacing) {
            history("되돌리기", "PDFIconUndo", id: "native-pdf-undo", enabled: model.canUndo || model.isEditingText) { model.undo() }
            history("다시 실행", "PDFIconRedo", id: "native-pdf-redo", enabled: model.canRedo || model.isEditingText) { model.redo() }
            divider
            if slidingTools { toolStrip } else { HStack(spacing: Self.spacing) { toolButtons } }
            divider
            if let shownColors, slidingTools { colorStrip(shownColors) } else { colors }
            divider
            widths
            if let collapse {
                divider
                Button(action: collapse) { cell("PDFIconChevron") }.accessibilityLabel("팔레트 접기").accessibilityIdentifier("native-pdf-palette-collapse")
            }
        }.frame(height: NativePDFPaletteLook.cell)
    }
    @ViewBuilder private var toolButtons: some View {
        ForEach(NativePDFPaletteLook.tools, id: \.0) { tool($0).id($0.0) }
        if NativeReleaseFlags.showsRecording { NativePDFRecordButton(model: model).id("record") }
    }
    /// Five tools wide and half of the sixth, so the strip reads as one that slides; its edges fade where more tools wait.
    /// A tool chosen elsewhere (Pencil double-tap, a shortcut) scrolls just enough to come into view.
    private var toolStrip: some View {
        let cell = NativePDFPaletteLook.cell, shown = shownTools.rounded(.down), partial = shownTools - shown
        let selected = model.isPenLike ? "pen" : model.tool
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                // 5 pt above and below: the pill's padding is part of each tool's tap area.
                HStack(spacing: Self.spacing) { toolButtons }.scrollTargetLayout().padding(.vertical, 5)
            }
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                [geometry.contentOffset.x > 1, geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1]
            } action: { _, edges in moreLeft = edges[0]; moreRight = edges[1] }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(moreLeft ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(moreRight ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                }
            }
            .frame(width: cell * (shown + partial) + Self.spacing * shown)
            .padding(.vertical, -5)
            .onChange(of: selected, initial: true) { _, tool in
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(tool) }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-tool-scroll")
    }
    /// The swatches in a strip `count` wide that slides, the chosen one scrolled into view; ＋ stays outside it.
    private func colorStrip(_ count: Int) -> some View {
        let slots = model.usesColorSlots ? model.colorSlots : model.palette.colors(for: model.penKind)
        let width = CGFloat(count) * 30 + CGFloat(max(0, count - 1)) * Self.spacing + (slots.count > count ? 12 : 0)
        return HStack(spacing: Self.spacing) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) { swatches }.padding(.vertical, 5)
                }
                .onScrollGeometryChange(for: [Bool].self) { geometry in
                    [geometry.contentOffset.x > 1, geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1]
                } action: { _, edges in moreColorsLeft = edges[0]; moreColorsRight = edges[1] }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(moreColorsLeft ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(moreColorsRight ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    }
                }
                .frame(width: width).padding(.vertical, -5)
                .onChange(of: model.activeColor, initial: true) { _, color in withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("color-" + color) } }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-color-scroll")
            addColor
        }
    }
    private var divider: some View { Rectangle().fill(NativePDFPaletteLook.divider).frame(width: 1, height: 18).padding(.horizontal, 4) }
    private func cell(_ image: String, chosen: Bool = false) -> some View {
        Image(image).foregroundStyle(NativePDFPaletteLook.icon).frame(width: NativePDFPaletteLook.cell, height: NativePDFPaletteLook.cell)
            .background(chosen ? NativePDFPaletteLook.chosen : .clear, in: RoundedRectangle(cornerRadius: 10)).paletteHitArea()
    }
    private func history(_ title: LocalizedStringKey, _ image: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { cell(image) }.disabled(!enabled).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    @ViewBuilder private func tool(_ value: (String, String, String)) -> some View {
        // One 펜 button for the three pen types, always the design's pen; the type is chosen in the pen settings.
        let pen = value.0 == "pen", chosen = pen ? model.isPenLike : model.tool == value.0
        let button = Button { if pen { model.choosePen() } else { model.chooseTool(value.0) } } label: { cell(value.2, chosen: chosen) }
            .accessibilityLabel(LocalizedStringKey(value.1)).accessibilityIdentifier("native-pdf-tool-" + value.0)
            .accessibilityValue(chosen && model.isInkTool ? model.styleAccessibilityValue : value.0 == "tape" ? model.tapeAccessibilityValue : "")
            .accessibilityAddTraits(chosen ? .isSelected : []).help(LocalizedStringKey(value.1))
        if ["pen", "highlighter", "eraser", "lasso", "tape"].contains(value.0) {
            // A second tap on the chosen tool: its options, directly under the button.
            button.bandalPopover(isPresented: Binding(get: { model.showStyle && chosen }, set: { if !$0, chosen { model.showStyle = false } }),
                                 width: pen ? 300 : 280, radius: 22, padding: 18, dims: false) {
                switch value.0 {
                case "pen": NativePDFPenSettings(model: model)
                case "highlighter": NativePDFHighlighterOptions(model: model)
                case "eraser": NativePDFEraserOptions(model: model)
                case "lasso": NativePDFLassoOptions(model: model)
                default: NativePDFTapeOptions(model: model)
                }
            }
        } else { button }
    }
    /// The current tool's colours, or the pen's while a tool without colour is chosen (a tap then returns to the pen).
    @ViewBuilder private var colors: some View { swatches; addColor }
    @ViewBuilder private var swatches: some View {
        let slots = model.usesColorSlots ? model.colorSlots : model.palette.colors(for: model.penKind), tape = model.tool == "tape"
        ForEach(slots, id: \.self) { name in
            let chosen = model.usesColorSlots && model.activeColor == name
            Button {
                if !model.usesColorSlots { model.choosePen() }
                if chosen, model.isInkTool { model.showStyle.toggle() } else { model.chooseColor(name) }
            } label: {
                Circle().fill(NativePDFPaletteLook.swatch(name, tape: tape)).frame(width: chosen ? 16 : 18, height: chosen ? 16 : 18)
                    .frame(width: 26, height: 26).overlay(Circle().strokeBorder(NativePDFPaletteLook.ring, lineWidth: 2).opacity(chosen ? 1 : 0))
                    .frame(width: 30, height: NativePDFPaletteLook.cell).paletteHitArea()
            }.accessibilityLabel(NativePDFPaletteLook.colorName(name)).accessibilityIdentifier("native-pdf-quick-color-" + name)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .contextMenu { if model.usesColorSlots, slots.count > 1 { Button("이 색 빼기", role: .destructive) { model.removeColorSlot(name) } } }
                .id("color-" + name)
        }
    }
    @ViewBuilder private var addColor: some View {
        let slots = model.usesColorSlots ? model.colorSlots : model.palette.colors(for: model.penKind)
        let missing = NativePDFWorkspaceModel.colors.filter { !slots.contains($0.name) }
        Menu {
            ForEach(missing, id: \.name) { item in Button(item.label) { if !model.usesColorSlots { model.choosePen() }; model.addColorSlot(item.name) } }
        } label: {
            Image("PDFIconPlus").resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(NativePDFPaletteLook.icon).frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(NativePDFPaletteLook.addRing, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))).frame(width: 30, height: NativePDFPaletteLook.cell).paletteHitArea()
        }.disabled(missing.isEmpty).accessibilityLabel("색 추가").accessibilityIdentifier("native-pdf-color-add")
    }
    /// The three thickness dots (Figma 155:7650): a tap picks one, a tap on the picked one opens its twelve steps.
    /// While a tool without thickness is chosen they are the pen's, and a tap returns to the pen.
    @ViewBuilder private var widths: some View {
        let own = model.usesWidthSlots, slots = own ? model.widthSlots : model.palette.widths(for: model.penKind), selected = own ? model.selectedWidthSlot : nil
        ForEach(Array(slots.enumerated()), id: \.offset) { index, step in
            let chosen = selected == index
            Button {
                if own { model.chooseWidthSlot(index) } else { model.choosePen(); if model.selectedWidthSlot != index { model.chooseWidthSlot(index) } }
            } label: {
                // 4 · 7 · 10 pt for the pen's default steps 3 · 6 · 9.
                Circle().fill(chosen ? NativePDFPaletteLook.dot : NativePDFPaletteLook.dotIdle).frame(width: 2 + CGFloat(step), height: 2 + CGFloat(step))
                    .frame(width: 26, height: 28).background(chosen ? NativePDFPaletteLook.chosen : .clear, in: Capsule()).frame(height: NativePDFPaletteLook.cell).paletteHitArea()
            }.accessibilityLabel("굵기 \(index + 1)").accessibilityValue(NativePDFPaletteStyle.stepLabel(step))
                .accessibilityIdentifier("native-pdf-width-slot-\(index)").accessibilityAddTraits(chosen ? .isSelected : [])
                // The eraser and tape popovers show the same slots and open the steps themselves.
                .bandalPopover(isPresented: Binding(get: { model.editingWidthSlot == index && !model.showStyle }, set: { if !$0, model.editingWidthSlot == index { model.editingWidthSlot = nil } }),
                               width: 320, radius: 22, padding: 18, dims: false) {
                    NativePDFWidthSteps(color: NativeDesktopTheme.text, selected: model.widthSlots.indices.contains(index) ? model.widthSlots[index] : step) { model.setWidthStep($0, slot: index) }
                }
        }
    }
}

/// Twelve segments that thicken left to right, filled up to the chosen step.
/// Tap or drag along it; VoiceOver adjusts it one step at a time.
struct NativePDFWidthSteps: View {
    let color: Color
    let selected: Int
    var id = "native-pdf-width-steps"
    let onSelect: (Int) -> Void
    private let count = 12
    var body: some View {
        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(count)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(index <= selected ? color : color.opacity(0.18)).frame(height: 3 + CGFloat(index) * 1.3)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Text("\(selected + 1)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(NativeDesktopTheme.text)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(NativeDesktopTheme.surface).shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                    .offset(x: cell * (CGFloat(selected) + 0.5) - 16)
                    .animation(.easeOut(duration: 0.12), value: selected)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let index = min(count - 1, max(0, Int(value.location.x / max(1, cell))))
                if index != selected { onSelect(index) }
            })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("선 굵기").accessibilityValue(NativePDFPaletteStyle.stepLabel(selected))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(min(count - 1, selected + 1))
            case .decrement: onSelect(max(0, selected - 1))
            @unknown default: break
            }
        }
        .accessibilityIdentifier(id)
    }
}

/// The palette microphone: a toggle, not a tool. While recording it shows a
/// red dot and the elapsed time.
private struct NativePDFRecordButton: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        Button { model.toggleRecording() } label: {
            if let started = model.recordingStartedAt {
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Duration.seconds(max(0, (model.recordingPausedAt ?? context.date).timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                }.padding(.horizontal, 8).frame(height: 28)
                    .background(Color.red.opacity(0.12), in: Capsule()).frame(height: NativePDFPaletteLook.cell).paletteHitArea()
            } else {
                Image("PDFIconMic").frame(width: NativePDFPaletteLook.cell, height: NativePDFPaletteLook.cell).paletteHitArea()
            }
        }
        .foregroundStyle(model.recordingStartedAt == nil ? NativePDFPaletteLook.icon : Color.red)
        .accessibilityLabel(model.recordingStartedAt == nil ? "녹음 시작" : "녹음 정지")
        .accessibilityIdentifier("native-pdf-record")
    }
}

/// While the palette microphone records (Figma 260:9026): a glass capsule at the top centre of the page area, under
/// the palette, with the elapsed time, a waveform, pause and 끝내고 요약. 끝내기 without a summary is the palette
/// microphone, or a long press on this bar. While the summary is being made the bar is the "요약하는 중이에요" card (260:9033).
struct NativePDFRecordingBar: View {
    var model: NativePDFWorkspaceModel
    /// Room kept on both sides: the thumbnails button's width when it shares this band.
    var sideInset: CGFloat = 16
    private static let wave: [CGFloat] = [4, 17.1, 5.5, 7.4, 9.8, 16.6, 14, 8.8, 5.2, 8, 18.8, 6.3, 13.7, 4.1, 12.1, 9.2, 17.9, 10.7, 6.3, 8.9, 11.1, 18.5, 7.8, 9.2, 4.2, 16.1]
    private static let dot = NativeDesktopTheme.adaptive(0xff383c, 0xff383c)
    var body: some View {
        if model.recordingStartedAt != nil || model.summarizingRecording {
            // Centred, clear of the thumbnails button at the left end of the same band; in a pane too narrow for both, under it.
            ViewThatFits(in: .horizontal) {
                content.padding(.horizontal, sideInset)
                content.padding(.top, NativePDFViewButton.size + 8)
            }
        }
    }
    @ViewBuilder private var content: some View {
        if let started = model.recordingStartedAt { bar(started) } else { summarizing }
    }
    private func bar(_ started: Date) -> some View {
        let paused = model.recordingPausedAt
        return HStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Self.dot).frame(width: 10, height: 10).opacity(paused == nil ? 1 : 0.35)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Duration.seconds(max(0, (paused ?? context.date).timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
            }.padding(.horizontal, 8)
            HStack(spacing: 2) {
                ForEach(Self.wave.indices, id: \.self) { Capsule().fill(NativeDesktopTheme.secondary).frame(width: 2, height: Self.wave[$0]) }
            }.frame(height: 18.8).opacity(paused == nil ? 1 : 0.35).accessibilityHidden(true)
            Button { model.toggleRecordingPause() } label: {
                Group { if paused == nil { Image("PDFIconPause") } else { Image(systemName: "play.fill").font(.system(size: 14)) } }
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }.accessibilityLabel(paused == nil ? "녹음 일시 정지" : "이어 녹음").accessibilityIdentifier("native-pdf-record-pause")
            Button { model.finishRecordingAndSummarize() } label: {
                HStack(spacing: 7) { Image(systemName: "sparkles").font(.system(size: 14)); Text("끝내고 요약").font(.system(size: 15, weight: .semibold)) }
                    .foregroundStyle(NativeDesktopTheme.onAccent).frame(width: 128, height: 43)
                    .background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).contentShape(Rectangle())
            }.accessibilityIdentifier("native-pdf-record-summarize")
        }
        .padding(.horizontal, 8).padding(.vertical, 6).buttonStyle(.plain)
        .foregroundStyle(NativeDesktopTheme.text).bandalGlass(in: Capsule())
        .contextMenu { Button("끝내기") { model.toggleRecording() }.accessibilityIdentifier("native-pdf-record-stop") }
        .accessibilityElement(children: .contain).accessibilityLabel("강의 녹음 중").accessibilityIdentifier("native-pdf-recording-bar")
    }
    private var summarizing: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(NativeDesktopTheme.secondary).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("요약하는 중이에요").font(.system(size: 14, weight: .semibold))
                Text("\(model.recordingSummaryMinutes)분 녹음 · 1분쯤 걸려요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(width: 320).foregroundStyle(NativeDesktopTheme.text)
        .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
        .accessibilityElement(children: .combine).accessibilityIdentifier("native-pdf-recording-summarizing")
    }
}

extension View {
    /// A palette control's tap area: the 34 pt cell plus the pill's 5 pt above and below (44 pt tall)
    /// and half of the gap on each side, without changing its layout.
    func paletteHitArea() -> some View {
        padding(.vertical, 5).padding(.horizontal, 2).contentShape(Rectangle()).padding(.vertical, -5).padding(.horizontal, -2)
    }
}
