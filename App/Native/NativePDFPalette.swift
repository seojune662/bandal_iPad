import SwiftUI

/// Visual contract: the notebook-style palette from the reference iPad renderer
/// (`PdfPalette.tsx`). Pages · history · view on the first row; tools · colours ·
/// thickness on the second; a "<tool> 설정" sheet anchored inside the PDF body.
@MainActor enum NativePDFPaletteLook {
    static let colorNames = ["ink": "먹색", "red": "빨강", "orange": "주황", "yellow": "노랑", "green": "초록", "blue": "파랑", "violet": "보라"]
    static let sizeNames = ["가는 선", "중간 선", "굵은 선"]
    static func toolName(_ tool: String) -> String {
        ["pen": "펜", "ballpoint": "볼펜", "highlighter": "형광펜", "eraser": "지우개", "lasso": "올가미", "select": "손", "text": "텍스트"][tool] ?? "필기 도구"
    }
    static func colorName(_ color: String) -> String { colorNames[color] ?? color }
    static func uiColor(_ color: String) -> Color { Color(uiColor: NativePDFInkSurface.color(color)) }
    static func swatchSize(_ width: Double) -> CGFloat { CGFloat(12 + (width * 1000).rounded()) }
}

/// Anchored inside the PDF body, so a narrow pane or a keyboard can never move
/// style controls over another document or outside the visible workspace.
struct NativePDFPaletteOverlay: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.05).contentShape(Rectangle()).onTapGesture { model.showStyle = false }
                    .accessibilityHidden(true)
                NativePDFPaletteControls(model: model)
                    .frame(width: max(0, min(340, geometry.size.width - 24)), height: max(0, min(600, geometry.size.height - 24)))
                    .background(NativeDesktopTheme.overlay, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeDesktopTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.13), radius: 20, y: 12).padding(12)
            }.clipped()
        }
    }
}

/// The "<tool> 설정" sheet: stroke preview, named colour grid, thickness and
/// opacity ranges, draw-and-hold switch, and three favourite pens with "현재 펜 저장".
struct NativePDFPaletteControls: View {
    @ObservedObject var model: NativePDFWorkspaceModel
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
                    if model.isInkTool { inkControls }
                    else { Text(toolHint).font(.system(size: 13)).lineSpacing(5).foregroundStyle(NativeDesktopTheme.secondary).padding(.horizontal, 4).padding(.vertical, 12).fixedSize(horizontal: false, vertical: true) }
                    presets
                }.padding(12)
            }.accessibilityIdentifier("native-pdf-palette-scroll")
                .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
        }.foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
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
            // Hidden quick-stop buttons keep the stable identifiers the UI flows use.
            HStack(spacing: 0) {
                ForEach(Array(model.quickWidths.enumerated()), id: \.offset) { index, width in
                    Button { model.chooseQuickWidth(width) } label: { Color.clear.frame(width: 1, height: 1) }
                        .accessibilityLabel(NativePDFPaletteLook.sizeNames[index] + " · " + model.widthLabel(for: width)).accessibilityIdentifier("native-pdf-palette-width-\(index)")
                        .accessibilityAddTraits(abs(model.width - width) < 0.0000001 ? .isSelected : [])
                }
            }.frame(height: 1)
            range("선 굵기", value: model.widthLabel(for: model.width), id: "native-pdf-width-slider",
                  binding: Binding(get: { model.width }, set: { model.setWidth($0) }), in: NativePDFPaletteStyle.widthRange(model.width, highlighter: highlighter))
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
                                Text("\(index + 1) · " + model.widthLabel(for: preset.width, highlighter: false)).font(.system(size: 12)).monospacedDigit().foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
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

/// Second docked row: tools · colours · thickness slider + styles button.
struct NativePDFPaletteQuickControls: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    var showsHistory = false
    private var highlighter: Bool { model.tool == "highlighter" }
    var body: some View {
        HStack(spacing: 0) {
            // Let the editing controls use the full width, including in split panes.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if showsHistory {
                        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                            .disabled(!model.canUndo).accessibilityLabel("되돌리기").accessibilityIdentifier("native-pdf-undo")
                        Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                            .disabled(!model.canRedo).accessibilityLabel("다시 실행").accessibilityIdentifier("native-pdf-redo")
                    }
                    HStack(spacing: 0) { ForEach(NativePDFToolbar.tools, id: \.0) { NativePDFToolbar.toolButton(model, $0) } }
                    if model.isInkTool {
                        group(leadingDivider: true) {
                            ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in
                                NativePDFPaletteColorButton(model: model, item: item, id: "native-pdf-quick-color-" + item.name)
                            }
                        }
                        group(leadingDivider: true) {
                            Slider(value: Binding(get: { model.width }, set: { model.setWidth($0) }), in: NativePDFPaletteStyle.widthRange(model.width, highlighter: highlighter))
                                .tint(NativeDesktopTheme.accent).frame(width: 96, height: 44)
                                .accessibilityLabel("선 굵기").accessibilityValue(model.widthLabel(for: model.width)).accessibilityIdentifier("native-pdf-quick-width")
                            Text(model.widthLabel(for: model.width)).font(.system(size: 10)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(NativeDesktopTheme.secondary).frame(width: 46).padding(.leading, 2)
                            Button { model.showStyle.toggle() } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 17)).frame(width: 44, height: 44)
                                    .foregroundStyle(model.showStyle ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary)
                                    .background(model.showStyle ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.accessibilityLabel("필기 스타일").accessibilityValue(model.styleAccessibilityValue).accessibilityIdentifier("native-pdf-style")
                        }
                    } else if model.tool == "lasso" {
                        Picker("올가미 방식", selection: Binding(get: { model.lassoMode }, set: { model.setLassoMode($0) })) {
                            Text("자유형").tag("freeform"); Text("박스형").tag("box")
                        }.pickerStyle(.segmented).frame(width: 170).padding(.horizontal, 4).accessibilityIdentifier("native-pdf-lasso-mode")
                        Button { model.pasteObjects() } label: {
                            Label("붙여넣기", systemImage: "doc.on.clipboard").font(.system(size: 12)).frame(height: 44).padding(.horizontal, 8).contentShape(Rectangle())
                        }.disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-tool-scroll")
        }.frame(height: 44)
    }
    private func group<Content: View>(leadingDivider: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            if leadingDivider { Rectangle().fill(NativeDesktopTheme.border).frame(width: 1, height: 24).padding(.leading, 4).padding(.trailing, 6) }
            content()
        }
    }
}

struct NativePDFSwatch: View {
    let color: String
    var size: CGFloat = 22
    var ring = false
    var body: some View {
        Circle().fill(NativePDFPaletteLook.uiColor(color)).frame(width: size, height: size)
            .overlay(Circle().stroke(.black.opacity(0.07), lineWidth: 1))
            .background(Circle().stroke(NativeDesktopTheme.accent, lineWidth: 2).padding(-4).opacity(ring ? 1 : 0))
            .background(Circle().stroke(NativeDesktopTheme.surface, lineWidth: 2).padding(-2).opacity(ring ? 1 : 0))
    }
}

private struct NativePDFPaletteColorButton: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    let item: NativePDFWorkspaceModel.InkColor
    let id: String
    var body: some View {
        let selected = model.isInkTool && model.color == item.name
        Button {
            if selected { model.showStyle.toggle() } else { model.chooseColor(item.name) }
        } label: {
            NativePDFSwatch(color: item.name, ring: selected).frame(width: 36, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(NativePDFPaletteLook.colorName(item.name)).accessibilityIdentifier(id)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
