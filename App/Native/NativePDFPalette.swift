import SwiftUI

/// Visual contract: a floating top row (pages · zoom · view), under it a glass pill with
/// tools · colours · favourite pens. A second tap on the chosen tool opens its popover under the button
/// (`NativePDFPenSettings`, `NativePDFToolPopovers`).
@MainActor enum NativePDFPaletteLook {
    static let colorNames = ["ink": "먹색", "red": "빨강", "orange": "주황", "yellow": "노랑", "green": "초록", "blue": "파랑", "violet": "보라"]
    static func colorName(_ color: String) -> String { colorNames[color] ?? color }
    static func uiColor(_ color: String) -> Color { Color(uiColor: NativePDFInkSurface.color(color)) }
    /// Palette order (Figma 269:8719): writing tools, then the rest. The 22 pt line icons are the design's own vectors.
    static let writingTools = [("pen", "펜", "PDFIconPen"), ("highlighter", "형광펜", "PDFIconHighlighter"), ("eraser", "지우개", "PDFIconEraser"), ("line", "직선", "PDFIconLine"), ("lasso", "올가미", "PDFIconLasso")]
    static let otherTools = [("text", "텍스트", "PDFIconText"), ("tape", "테이프", "PDFIconTape"), ("laser", "레이저 포인터", "PDFIconLaser"), ("comment", "댓글", "PDFIconComment"), ("select", "손", "PDFIconHand")]
    static func toolImage(_ tool: String) -> String { (writingTools + otherTools).first { $0.0 == tool }?.2 ?? "PDFIconPen" }
    /// A favourite cell's 17 pt pen-type icon (Figma 268:8710).
    static func penImage(_ kind: String) -> String { kind == "ballpoint" ? "PDFIconBallpoint" : kind == "brush" ? "PDFIconBrush" : "PDFIconFountain" }
    /// The 펜 button shows the type chosen last (Figma 262:1392); 볼펜 is the plain pen.
    static func penToolImage(_ kind: String) -> String { kind == "brush" ? "PDFIconBrushTool" : kind == "pen" ? "PDFIconFountainTool" : "PDFIconPen" }
    static let icon = NativeDesktopTheme.adaptive(0x6b6b6b, 0x9a9a9a)
    static let chosen = alpha(black: 0.07, white: 0.10)
    static let divider = alpha(black: 0.08, white: 0.11)
    static let ring = alpha(black: 0.85, white: 1)
    static let addRing = alpha(black: 0.20, white: 0.28)
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
    struct Entry { let model: NativePDFWorkspaceModel; var frame: CGRect }
    var entries: [String: Entry] = [:]
    /// A drawer covers the document: the palette stays inside its pane, under the drawer.
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
                // Centred on the page area and as wide as the window allows on both sides.
                let half = max(0, min(middle, geometry.size.width - middle) - 8)
                NativePDFFloatingPalette(model: entry.model).frame(width: half * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: middle - half, y: entry.frame.minY - origin.y + NativePDFFloatingPalette.top)
            }
        }.onChange(of: covered, initial: true) { _, value in host.suspended = value }
    }
}

/// The glass pill floating below the PDF top row (Figma 269:8719): history · tools · colours · favourite pens · collapse.
/// Collapsed (130:4713) it keeps only the current tool and colour.
struct NativePDFFloatingPalette: View {
    var model: NativePDFWorkspaceModel
    @AppStorage("native.pdf.paletteCollapsed") private var collapsed = false
    /// Gap below the PDF top row.
    static let top: CGFloat = 4
    var body: some View {
        Group {
            if collapsed { mini } else {
                // Hug the row when it fits; scroll inside the pill in a narrow pane.
                ViewThatFits(in: .horizontal) {
                    NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true }).fixedSize(horizontal: true, vertical: false)
                    NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true })
                }.padding(.horizontal, 10)
            }
        }.padding(.vertical, 8).bandalGlass(in: Capsule())
        .foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
        .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
    }
    private var mini: some View {
        Button { collapsed = false } label: {
            HStack(spacing: 6) {
                Image(NativePDFPaletteLook.toolImage(model.isPenLike ? "pen" : model.tool)).foregroundStyle(NativeDesktopTheme.text)
                    .frame(width: 44, height: 44).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                if model.usesColorSlots {
                    Circle().fill(NativePDFPaletteLook.swatch(model.activeColor, tape: model.tool == "tape")).frame(width: 20, height: 20)
                        .frame(width: 30, height: 30).overlay(Circle().strokeBorder(NativeDesktopTheme.accent, lineWidth: 2))
                }
                Rectangle().fill(NativeGlass.separator).frame(width: 1, height: 28)
                Image(systemName: "chevron.up").font(.system(size: 19)).frame(width: 44, height: 44)
            }.padding(.horizontal, 8).contentShape(Rectangle())
        }.accessibilityLabel("팔레트 펼치기").accessibilityIdentifier("native-pdf-palette-expand")
    }
}

/// The palette row. Its cells never change with the tool; a tool's own options open in a popover under its button.
struct NativePDFPaletteQuickControls: View {
    var model: NativePDFWorkspaceModel
    var collapse: (() -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                history("되돌리기", "PDFIconUndo", id: "native-pdf-undo", enabled: model.canUndo || model.isEditingText) { model.undo() }
                history("다시 실행", "PDFIconRedo", id: "native-pdf-redo", enabled: model.canRedo || model.isEditingText) { model.redo() }
                divider
                ForEach(NativePDFPaletteLook.writingTools, id: \.0) { tool($0) }
                divider
                ForEach(NativePDFPaletteLook.otherTools, id: \.0) { tool($0) }
                if NativeReleaseFlags.showsRecording { NativePDFRecordButton(model: model) }
                divider
                colors
                divider
                ForEach(model.favorites.indices, id: \.self) { favorite($0) }
                if let collapse {
                    divider
                    Button(action: collapse) { cell("PDFIconChevron") }.accessibilityLabel("팔레트 접기").accessibilityIdentifier("native-pdf-palette-collapse")
                }
            }.fixedSize(horizontal: true, vertical: false)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-tool-scroll").frame(height: 40)
    }
    private var divider: some View { Rectangle().fill(NativePDFPaletteLook.divider).frame(width: 1, height: 22).padding(.horizontal, 5) }
    private func cell(_ image: String, chosen: Bool = false) -> some View {
        Image(image).foregroundStyle(NativePDFPaletteLook.icon).frame(width: 40, height: 40)
            .background(chosen ? NativePDFPaletteLook.chosen : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
    }
    private func history(_ title: LocalizedStringKey, _ image: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { cell(image) }.disabled(!enabled).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    @ViewBuilder private func tool(_ value: (String, String, String)) -> some View {
        // One 펜 button for the three pen types; the type is chosen in the pen settings.
        let pen = value.0 == "pen", chosen = pen ? model.isPenLike : model.tool == value.0
        let button = Button { if pen { model.choosePen() } else { model.chooseTool(value.0) } } label: {
            if pen, model.penKind != "ballpoint" {
                Image(NativePDFPaletteLook.penToolImage(model.penKind)).resizable().frame(width: 19, height: 19).foregroundStyle(NativePDFPaletteLook.icon).frame(width: 40, height: 40)
                    .background(chosen ? NativePDFPaletteLook.chosen : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            } else { cell(value.2, chosen: chosen) }
        }
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
    @ViewBuilder private var colors: some View {
        let slots = model.usesColorSlots ? model.colorSlots : model.palette.colors(for: "pen"), tape = model.tool == "tape"
        ForEach(slots, id: \.self) { name in
            let chosen = model.usesColorSlots && model.activeColor == name
            Button {
                if !model.usesColorSlots { model.choosePen() }
                if chosen, model.isInkTool { model.showStyle.toggle() } else { model.chooseColor(name) }
            } label: {
                Circle().fill(NativePDFPaletteLook.swatch(name, tape: tape)).frame(width: chosen ? 20 : 22, height: chosen ? 20 : 22)
                    .frame(width: 32, height: 32).overlay(Circle().strokeBorder(NativePDFPaletteLook.ring, lineWidth: 2).opacity(chosen ? 1 : 0))
                    .frame(height: 40).contentShape(Rectangle())
            }.accessibilityLabel(NativePDFPaletteLook.colorName(name)).accessibilityIdentifier("native-pdf-quick-color-" + name)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .contextMenu { if model.usesColorSlots, slots.count > 1 { Button("이 색 빼기", role: .destructive) { model.removeColorSlot(name) } } }
        }
        let missing = NativePDFWorkspaceModel.colors.filter { !slots.contains($0.name) }
        Menu {
            ForEach(missing, id: \.name) { item in Button(item.label) { if !model.usesColorSlots { model.choosePen() }; model.addColorSlot(item.name) } }
        } label: {
            Image("PDFIconPlus").foregroundStyle(NativePDFPaletteLook.icon).frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(NativePDFPaletteLook.addRing, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))).frame(height: 40).contentShape(Rectangle())
        }.disabled(missing.isEmpty).accessibilityLabel("색 추가").accessibilityIdentifier("native-pdf-color-add")
    }
    /// A favourite pen (Figma 268:8710): its type's icon over a bar as thick as its stroke, both in its colour.
    /// A tap uses it, a tap on the one in use opens the pen settings. An empty cell takes the current pen.
    @ViewBuilder private func favorite(_ index: Int) -> some View {
        if let preset = model.favorites[index] {
            let chosen = model.favoriteIndex == index
            let bar = 2 + (CGFloat(NativePDFPaletteStyle.nearestStep(preset.width, tool: "pen")) * 6 / 11).rounded() / 2
            Button { if chosen { model.showStyle.toggle() } else { model.chooseFavorite(index) } } label: {
                VStack(spacing: 3) {
                    Image(NativePDFPaletteLook.penImage(preset.kind))
                    Capsule().frame(width: 16, height: bar)
                }.foregroundStyle(NativePDFPaletteLook.swatch(preset.color)).frame(width: 40, height: 40)
                    .background(chosen ? NativePDFPaletteLook.chosen : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.accessibilityLabel("즐겨찾는 펜 \(index + 1): " + NativePDFPaletteLook.colorName(preset.color)).accessibilityValue(model.favoriteAccessibilityValue(index))
                .accessibilityIdentifier("native-pdf-quick-favorite-\(index)").accessibilityAddTraits(chosen ? .isSelected : [])
                .contextMenu {
                    Button("현재 펜 저장") { model.saveFavorite(index) }.disabled(!model.isPenLike)
                    Button("즐겨찾기에서 빼기", role: .destructive) { model.clearFavorite(index) }
                }
        } else {
            Button { if !model.isPenLike { model.choosePen() }; model.saveFavorite(index) } label: {
                Image("PDFIconPlus").foregroundStyle(NativeDesktopTheme.muted).frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.muted, lineWidth: 1.2).padding(2)).contentShape(Rectangle())
            }.accessibilityLabel("즐겨찾는 펜 \(index + 1)에 현재 펜 저장").accessibilityIdentifier("native-pdf-quick-favorite-\(index)")
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
                }.padding(.horizontal, 8).frame(height: 32)
                    .background(Color.red.opacity(0.12), in: Capsule()).frame(height: 40).contentShape(Rectangle())
            } else {
                Image("PDFIconMic").frame(width: 40, height: 40).contentShape(Rectangle())
            }
        }
        .foregroundStyle(model.recordingStartedAt == nil ? NativePDFPaletteLook.icon : Color.red)
        .accessibilityLabel(model.recordingStartedAt == nil ? "녹음 시작" : "녹음 정지")
        .accessibilityIdentifier("native-pdf-record")
    }
}

/// While the palette microphone records (Figma 260:9026): a glass capsule at the top centre of the page area with
/// the elapsed time, a waveform, pause and 끝내고 요약. 끝내기 without a summary is the palette microphone, or a
/// long press on this bar. While the summary is being made the bar is the "요약하는 중이에요" card (260:9033).
struct NativePDFRecordingBar: View {
    var model: NativePDFWorkspaceModel
    /// Below the floating palette (its 4 pt gap, 56 pt height) with the design's 8 pt between floating bars.
    static let top = NativePDFFloatingPalette.top + 56 + 8
    private static let wave: [CGFloat] = [4, 17.1, 5.5, 7.4, 9.8, 16.6, 14, 8.8, 5.2, 8, 18.8, 6.3, 13.7, 4.1, 12.1, 9.2, 17.9, 10.7, 6.3, 8.9, 11.1, 18.5, 7.8, 9.2, 4.2, 16.1]
    private static let dot = NativeDesktopTheme.adaptive(0xff383c, 0xff383c)
    var body: some View {
        Group {
            if let started = model.recordingStartedAt { bar(started) }
            else if model.summarizingRecording { summarizing }
        }.padding(.top, Self.top)
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
