import SwiftUI

/// Visual contract: a floating top row (pages · zoom · view), under it a glass pill with
/// tools · colours · favourite pens, and a "<tool> 설정" sheet anchored inside the PDF body.
@MainActor enum NativePDFPaletteLook {
    static let colorNames = ["ink": "먹색", "red": "빨강", "orange": "주황", "yellow": "노랑", "green": "초록", "blue": "파랑", "violet": "보라"]
    static func toolName(_ tool: String) -> String {
        ["pen": "펜", "ballpoint": "볼펜", "highlighter": "형광펜", "eraser": "지우개", "line": "직선", "lasso": "올가미", "select": "손", "text": "텍스트",
         "tape": "테이프", "laser": "레이저 포인터", "comment": "댓글"][tool] ?? "필기 도구"
    }
    static func colorName(_ color: String) -> String { colorNames[color] ?? color }
    static func uiColor(_ color: String) -> Color { Color(uiColor: NativePDFInkSurface.color(color)) }
    /// Palette order (Figma 269:8719): writing tools, then the rest. The 22 pt line icons are the design's own vectors.
    static let writingTools = [("pen", "펜", "PDFIconPen"), ("highlighter", "형광펜", "PDFIconHighlighter"), ("eraser", "지우개", "PDFIconEraser"), ("line", "직선", "PDFIconLine"), ("lasso", "올가미", "PDFIconLasso")]
    static let otherTools = [("text", "텍스트", "PDFIconText"), ("tape", "테이프", "PDFIconTape"), ("laser", "레이저 포인터", "PDFIconLaser"), ("comment", "댓글", "PDFIconComment"), ("select", "손", "PDFIconHand")]
    static func toolImage(_ tool: String) -> String { (writingTools + otherTools).first { $0.0 == tool }?.2 ?? "PDFIconPen" }
    static func penImage(_ kind: String) -> String { kind == "ballpoint" ? "PDFIconBallpoint" : "PDFIconFountain" }
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

/// Anchored inside the PDF body, so a narrow pane or a keyboard can never move
/// style controls over another document or outside the visible workspace.
struct NativePDFPaletteOverlay: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.05).contentShape(Rectangle()).onTapGesture { model.showStyle = false }
                    .accessibilityHidden(true)
                NativePDFPaletteControls(model: model)
                    .frame(width: max(0, min(340, geometry.size.width - 24)), height: max(0, min(600, geometry.size.height - 88)))
                    .bandalGlass(in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 12).padding(.top, NativePDFFloatingPalette.top + 64).padding(.bottom, 12)
            }.clipped()
        }
    }
}

/// The "<tool> 설정" sheet: stroke preview, named colour grid, thickness and
/// opacity ranges, draw-and-hold switch, and three favourite pens with "현재 펜 저장".
struct NativePDFPaletteControls: View {
    var model: NativePDFWorkspaceModel
    private var highlighter: Bool { model.tool == "highlighter" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(NativePDFPaletteLook.toolName(model.tool) + " 설정").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.showStyle = false } label: { Text("×").font(.system(size: 25)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("도구 메뉴 닫기").accessibilityIdentifier("native-pdf-style-close")
            }.padding(.leading, 16).padding(.trailing, 8).padding(.top, 4)
            Divider().padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isPenLike { penKinds }
                    if model.isInkTool { inkControls }
                    else { Text(toolHint).font(.system(size: 13)).lineSpacing(5).foregroundStyle(NativeDesktopTheme.secondary).padding(.horizontal, 4).padding(.vertical, 12).fixedSize(horizontal: false, vertical: true) }
                    presets
                }.padding(12)
            }.accessibilityIdentifier("native-pdf-palette-scroll")
                .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
        }.foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
    }
    private var penKinds: some View {
        HStack(spacing: 4) {
            ForEach([("pen", "만년필"), ("ballpoint", "볼펜")], id: \.0) { kind, title in
                let selected = model.tool == kind
                Button { model.choosePenKind(kind) } label: {
                    HStack(spacing: 6) { Image(NativePDFPaletteLook.penImage(kind)); Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium)) }
                        .frame(maxWidth: .infinity, minHeight: 44).background(selected ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                }.accessibilityIdentifier("native-pdf-pen-kind-" + kind).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(.bottom, 8)
    }
    private var inkControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                NativePDFStrokePreview(preset: model.currentPreset, highlighter: highlighter).frame(height: 66)
                HStack { Text(NativePDFPaletteLook.colorName(model.color)); Spacer(); Text(model.widthLabel(for: model.width)).bold().monospacedDigit() }
                    .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 10)
                .background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .ignore).accessibilityLabel("미리보기 · " + NativePDFPaletteLook.colorName(model.color) + " · " + model.widthLabel(for: model.width))
                .accessibilityValue(model.styleAccessibilityValue).accessibilityIdentifier("native-pdf-stroke-preview")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in
                    let selected = model.color == item.name
                    Button { model.chooseColor(item.name) } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(NativePDFPaletteLook.uiColor(item.name)).frame(width: 26, height: 26).overlay(Circle().stroke(.black.opacity(0.07), lineWidth: 1))
                                if selected { Text("✓").font(.system(size: 15)).foregroundStyle(.white).shadow(color: .black.opacity(0.55), radius: 1, y: 1) }
                            }
                            Text(NativePDFPaletteLook.colorName(item.name)).font(.system(size: 11))
                        }.frame(maxWidth: .infinity, minHeight: 62).padding(7)
                            .background(selected ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? NativeDesktopTheme.accent : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                    }.accessibilityLabel(NativePDFPaletteLook.colorName(item.name) + " 색상").accessibilityIdentifier("native-pdf-color-" + item.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("선 굵기").font(.system(size: 13, weight: .semibold)); Spacer()
                    Text(model.widthLabel(for: model.width)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(NativeDesktopTheme.accent)
                }
                HStack(spacing: 2) { NativePDFWidthSlots(model: model, popover: false) }
                // Edits the selected slot.
                NativePDFWidthSteps(color: NativePDFPaletteLook.uiColor(model.color), selected: model.selectedWidthSlot.map { model.widthSlots[$0] } ?? NativePDFPaletteStyle.nearestStep(model.width, tool: model.tool),
                                    id: "native-pdf-sheet-width-steps") { model.setWidthStep($0, slot: model.selectedWidthSlot) }
            }.padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 6)
            range("불투명도", value: "\(Int((model.opacity * 100).rounded()))%", id: "native-pdf-opacity-slider",
                  binding: Binding(get: { model.opacity }, set: { model.setOpacity($0) }), in: NativePDFPaletteStyle.opacityRange(model.opacity, highlighter: highlighter))
            Divider().padding(.top, 8)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("그린 뒤 유지하여 도형 정리").font(.system(size: 13, weight: .semibold))
                    Text("펜을 떼지 않고 잠시 멈추세요. 계속 쓰면 원래 필기로 돌아갑니다.").font(.system(size: 11)).lineSpacing(4).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { model.shapeRecognitionEnabled }, set: { model.setShapeRecognition($0) })).labelsHidden().tint(NativeDesktopTheme.accent)
                    .accessibilityLabel("그린 뒤 유지하여 도형 정리").accessibilityIdentifier("native-pdf-shape-recognition")
            }.padding(.horizontal, 4).padding(.vertical, 12)
        }
    }
    private func range(_ title: String, value: String, id: String, binding: Binding<Double>, in bounds: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(NativeDesktopTheme.accent) }
            Slider(value: binding, in: bounds).tint(NativeDesktopTheme.accent).frame(height: 44)
                .accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier(id)
        }.padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 6)
    }
    private var presets: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("즐겨찾는 펜").font(.system(size: 12, weight: .semibold))
                Text("색상 · 굵기 · 불투명도를 함께 기억해요").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.secondary)
            }.padding(.horizontal, 4).padding(.vertical, 8)
            HStack(alignment: .top, spacing: 4) {
                ForEach(model.favorites.indices, id: \.self) { index in
                    let preset = model.favorites[index]
                    VStack(spacing: 0) {
                        Button { model.chooseFavorite(index) } label: {
                            HStack(spacing: 7) {
                                Circle().fill(NativePDFPaletteLook.uiColor(preset.color)).frame(width: 22, height: 22).overlay(Circle().stroke(.black.opacity(0.07), lineWidth: 1))
                                Text("\(index + 1) · " + model.widthLabel(for: preset.width, tool: "pen")).font(.system(size: 12)).monospacedDigit().foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel("즐겨찾는 펜 \(index + 1): " + NativePDFPaletteLook.colorName(preset.color)).accessibilityValue(model.favoriteAccessibilityValue(index))
                            .accessibilityIdentifier("native-pdf-palette-favorite-\(index)")
                            .accessibilityAddTraits(model.isPenLike && model.currentPreset == preset ? .isSelected : [])
                        Button { model.saveFavorite(index) } label: {
                            Text("현재 펜 저장").font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.disabled(!model.isPenLike).opacity(model.isPenLike ? 1 : 0.35)
                            .accessibilityLabel("즐겨찾는 펜 \(index + 1)에 현재 펜 저장").accessibilityIdentifier("native-pdf-save-favorite-\(index)")
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
    private var toolHint: String {
        switch model.tool {
        case "text": return "페이지를 탭해 입력하고 아래 서식 도구에서 글자를 꾸미세요."
        case "eraser": return "펜으로 필기를 지우세요. 펜 도구를 다시 선택하면 이전 스타일로 돌아갑니다."
        default: return "필기나 텍스트를 선택해 이동하고 크기를 조절하세요."
        }
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
        VStack(spacing: 4) {
            Group {
                if collapsed { mini } else {
                    // Hug the row when it fits; scroll inside the pill in a narrow pane.
                    ViewThatFits(in: .horizontal) {
                        NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true }).fixedSize(horizontal: true, vertical: false)
                        NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true })
                    }.padding(.horizontal, 10)
                }
            }.padding(.vertical, 8).bandalGlass(in: Capsule())
            if !collapsed, NativePDFToolOptions.tools.contains(model.tool) {
                NativePDFToolOptions(model: model).padding(.horizontal, 10).padding(.vertical, 8).bandalGlass(in: Capsule())
            }
        }
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

/// The palette row. Its cells never change with the tool; a tool's own options sit in `NativePDFToolOptions`.
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
    private func tool(_ value: (String, String, String)) -> some View {
        // One 펜 button for both pen types; the type is chosen in the pen settings.
        let chosen = value.0 == "pen" ? model.isPenLike : model.tool == value.0
        return Button { if value.0 == "pen" { model.choosePen() } else { model.chooseTool(value.0) } } label: { cell(value.2, chosen: chosen) }
            .accessibilityLabel(LocalizedStringKey(value.1)).accessibilityIdentifier("native-pdf-tool-" + value.0)
            .accessibilityValue(chosen && model.isInkTool ? model.styleAccessibilityValue : "")
            .accessibilityAddTraits(chosen ? .isSelected : []).help(LocalizedStringKey(value.1))
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
    /// A favourite pen: the pen-type icon over a bar as thick as its stroke, both in its colour.
    private func favorite(_ index: Int) -> some View {
        let preset = model.favorites[index], chosen = model.isPenLike && model.currentPreset == preset
        let bar = 2 + (CGFloat(NativePDFPaletteStyle.nearestStep(preset.width, tool: "pen")) * 6 / 11).rounded() / 2
        return Button { if chosen { model.showStyle.toggle() } else { model.chooseFavorite(index) } } label: {
            VStack(spacing: 3) {
                Image(NativePDFPaletteLook.penImage(model.penKind))
                Capsule().frame(width: 16, height: bar)
            }.foregroundStyle(NativePDFPaletteLook.swatch(preset.color)).frame(width: 40, height: 40)
                .background(chosen ? NativePDFPaletteLook.chosen : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.accessibilityLabel("즐겨찾는 펜 \(index + 1): " + NativePDFPaletteLook.colorName(preset.color)).accessibilityValue(model.favoriteAccessibilityValue(index))
            .accessibilityIdentifier("native-pdf-quick-favorite-\(index)").accessibilityAddTraits(chosen ? .isSelected : [])
            .contextMenu { Button("현재 펜 저장") { model.saveFavorite(index) }.disabled(!model.isPenLike) }
    }
}

/// Options of the eraser, lasso and tape, in a second pill under the palette until each gets its own popover.
struct NativePDFToolOptions: View {
    static let tools: Set<String> = ["eraser", "lasso", "tape"]
    var model: NativePDFWorkspaceModel
    var body: some View {
        HStack(spacing: 2) {
            switch model.tool {
            case "eraser":
                Picker("지우개 방식", selection: Binding(get: { model.palette.eraserMode }, set: { model.setEraserMode($0) })) {
                    Text("획 전체").tag("stroke"); Text("부분").tag("partial")
                }.pickerStyle(.segmented).frame(width: 150).padding(.horizontal, 4).accessibilityIdentifier("native-pdf-eraser-mode")
                NativePDFWidthSlots(model: model)
            case "lasso":
                Picker("올가미 방식", selection: Binding(get: { model.lassoMode }, set: { model.setLassoMode($0) })) {
                    Text("자유형").tag("freeform"); Text("박스형").tag("box")
                }.pickerStyle(.segmented).frame(width: 170).padding(.horizontal, 4).accessibilityIdentifier("native-pdf-lasso-mode")
                Button { model.pasteObjects() } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard").font(.system(size: 12)).frame(height: 40).padding(.horizontal, 8).contentShape(Rectangle())
                }.disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
            default:
                NativePDFWidthSlots(model: model)
                Button { model.setAllTapes(revealed: !model.allTapesRevealed) } label: {
                    Label(model.allTapesRevealed ? "모두 가리기" : "모두 보기", systemImage: model.allTapesRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 12)).frame(height: 40).padding(.horizontal, 8).contentShape(Rectangle())
                }.disabled(!model.hasTapes).opacity(model.hasTapes ? 1 : 0.4).accessibilityIdentifier("native-pdf-tape-all")
            }
        }.frame(height: 40)
    }
}

/// Three thickness slots. A tap picks one; tapping the picked one opens its
/// twelve steps, so nobody has to guess a millimetre value.
struct NativePDFWidthSlots: View {
    var model: NativePDFWorkspaceModel
    /// Off inside the pen settings, whose own step bar edits the chosen slot.
    var popover = true
    var body: some View {
        let selected = model.selectedWidthSlot
        let tint = model.tool == "eraser" ? NativeDesktopTheme.secondary
            : model.tool == "tape" ? Color(uiColor: NativePDFObjectRenderer.tapeColor(model.activeColor)) : NativePDFPaletteLook.uiColor(model.color)
        ForEach(Array(model.widthSlots.enumerated()), id: \.offset) { index, step in
            Button { model.chooseWidthSlot(index) } label: {
                ZStack {
                    Circle().fill(NativeDesktopTheme.text.opacity(0.07)).frame(width: 28, height: 28).opacity(selected == index ? 1 : 0)
                    Circle().fill(tint).frame(width: Self.dot(step), height: Self.dot(step))
                }.frame(width: 32, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("굵기 \(index + 1)").accessibilityValue(NativePDFPaletteStyle.stepLabel(step))
            .accessibilityIdentifier("native-pdf-width-slot-\(index)")
            .accessibilityAddTraits(selected == index ? .isSelected : [])
            .popover(isPresented: Binding(get: { popover && model.editingWidthSlot == index },
                                          set: { if !$0, model.editingWidthSlot == index { model.editingWidthSlot = nil } })) {
                NativePDFWidthSteps(color: tint, selected: model.widthSlots.indices.contains(index) ? model.widthSlots[index] : step) {
                    model.setWidthStep($0, slot: index)
                }.padding(.horizontal, 18).padding(.vertical, 12).frame(width: 400)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
    static func dot(_ step: Int) -> CGFloat { 4 + 17 * CGFloat(step) / 11 }
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

/// The reference preview wave (`M18 43 C45 43 35 15 64 22 S72 57 101 38 …` in a
/// 280×66 box), stroked at `effectiveWidth × 600` of the box width.
struct NativePDFStrokePreview: View {
    let preset: NativePDFPenPreset
    let highlighter: Bool
    var pageWidthPoints: Double? = nil
    var body: some View {
        GeometryReader { geometry in
            let sx = geometry.size.width / 280, sy = geometry.size.height / 66
            Path { path in
                func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
                path.move(to: p(18, 43))
                path.addCurve(to: p(64, 22), control1: p(45, 43), control2: p(35, 15))
                var control = p(64, 22).reflected(over: p(35, 15))
                let smooth: [(c2: (Double, Double), to: (Double, Double))] = [((72, 57), (101, 38)), ((123, 16), (151, 32)), ((175, 51), (201, 33)), ((233, 20), (262, 30))]
                for segment in smooth {
                    let to = p(segment.to.0, segment.to.1), c2 = p(segment.c2.0, segment.c2.1)
                    path.addCurve(to: to, control1: control, control2: c2)
                    control = to.reflected(over: c2)
                }
            }.stroke(NativePDFPaletteLook.uiColor(preset.color).opacity(preset.opacity),
                     style: StrokeStyle(lineWidth: NativePDFPaletteStyle.effectiveWidth(preset.width, highlighter: highlighter) * 600 * sx, lineCap: .round, lineJoin: .round))
        }
    }
}

private extension CGPoint {
    /// Smooth-curve reflection: the next control point mirrors the previous one.
    func reflected(over control: CGPoint) -> CGPoint { CGPoint(x: 2 * x - control.x, y: 2 * y - control.y) }
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
                        Text(Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
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

/// While the palette microphone records: a glass bar at the bottom of the page with the elapsed time and a stop button.
struct NativePDFRecordingBar: View {
    var model: NativePDFWorkspaceModel
    let started: Date
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            Image(systemName: "waveform").font(.system(size: 14))
            Text("강의 녹음 중").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
            Button { model.toggleRecording() } label: {
                Text("끝내기").font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("native-pdf-record-stop")
            Button { model.finishRecordingAndSummarize() } label: {
                Text("끝내고 요약").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).frame(height: 32)
                    .background(NativeDesktopTheme.text.opacity(0.07), in: Capsule()).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("native-pdf-record-summarize")
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 48)
        .foregroundStyle(NativeDesktopTheme.text).bandalGlass(in: Capsule()).padding(.bottom, 16)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-recording-bar")
    }
}
