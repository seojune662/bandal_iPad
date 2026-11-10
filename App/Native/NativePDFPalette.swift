import SwiftUI

/// Visual contract: pages · history · view docked on top; tools · colours · thickness in a
/// glass pill floating over the page; a "<tool> 설정" sheet anchored inside the PDF body.
@MainActor enum NativePDFPaletteLook {
    static let colorNames = ["ink": "먹색", "red": "빨강", "orange": "주황", "yellow": "노랑", "green": "초록", "blue": "파랑", "violet": "보라"]
    static func toolName(_ tool: String) -> String {
        ["pen": "펜", "ballpoint": "볼펜", "highlighter": "형광펜", "eraser": "지우개", "lasso": "올가미", "select": "손", "text": "텍스트",
         "tape": "테이프", "laser": "레이저 포인터", "comment": "댓글"][tool] ?? "필기 도구"
    }
    static func colorName(_ color: String) -> String { colorNames[color] ?? color }
    static func uiColor(_ color: String) -> Color { Color(uiColor: NativePDFInkSurface.color(color)) }
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
                    .bandalGlass(in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 12).padding(.top, 76).padding(.bottom, 12)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("선 굵기").font(.system(size: 13, weight: .semibold)); Spacer()
                    Text(model.widthLabel(for: model.width)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(NativeDesktopTheme.accent)
                }
                // Edits the selected slot, like its popover in the palette row.
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

/// The glass pill floating over the top of the page: history · tools · colours · thickness · collapse.
/// Collapsed it keeps only the current tool and colour.
struct NativePDFFloatingPalette: View {
    var model: NativePDFWorkspaceModel
    @AppStorage("native.pdf.paletteCollapsed") private var collapsed = false
    var body: some View {
        Group {
            if collapsed { mini } else {
                // Hug the row when it fits; scroll inside the pill in a narrow pane.
                ViewThatFits(in: .horizontal) {
                    NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true }).fixedSize(horizontal: true, vertical: false)
                    NativePDFPaletteQuickControls(model: model, collapse: { collapsed = true })
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .bandalGlass(in: Capsule())
        .foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.top, 10)
        .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
    }
    private var mini: some View {
        Button { collapsed = false } label: {
            HStack(spacing: 6) {
                Image(systemName: NativePDFToolbar.tools.first { $0.0 == model.tool }?.2 ?? "pencil.tip").font(.system(size: 17))
                    .frame(width: 40, height: 40).background(NativeDesktopTheme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if model.usesColorSlots { NativePDFSwatch(color: model.activeColor, size: 22, ring: true, tape: model.tool == "tape").frame(width: 32, height: 32) }
                Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 40)
            }.contentShape(Rectangle())
        }.accessibilityLabel("팔레트 펼치기").accessibilityIdentifier("native-pdf-palette-expand")
    }
}

/// The palette row: history · tools · colours · thickness slots + styles button · collapse.
struct NativePDFPaletteQuickControls: View {
    var model: NativePDFWorkspaceModel
    var collapse: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 17)).frame(width: 40, height: 40).contentShape(Rectangle()) }
                        .disabled(!model.canUndo && !model.isEditingText).accessibilityLabel("되돌리기").accessibilityIdentifier("native-pdf-undo")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 17)).frame(width: 40, height: 40).contentShape(Rectangle()) }
                        .disabled(!model.canRedo && !model.isEditingText).accessibilityLabel("다시 실행").accessibilityIdentifier("native-pdf-redo")
                    group(leadingDivider: true) {
                        ForEach(NativePDFToolbar.tools, id: \.0) { NativePDFToolbar.toolButton(model, $0) }
                        if NativeReleaseFlags.showsRecording { NativePDFRecordButton(model: model) }
                    }
                    if model.usesColorSlots {
                        group(leadingDivider: true) {
                            ForEach(model.colorSlots, id: \.self) { name in
                                NativePDFPaletteColorButton(model: model, name: name, id: "native-pdf-quick-color-" + name)
                                    .contextMenu {
                                        if model.colorSlots.count > 1 {
                                            Button("이 색 빼기", role: .destructive) { model.removeColorSlot(name) }
                                        }
                                    }
                            }
                            let missing = NativePDFWorkspaceModel.colors.filter { !model.colorSlots.contains($0.name) }
                            if !missing.isEmpty {
                                Menu {
                                    ForEach(missing, id: \.name) { item in Button(item.label) { model.addColorSlot(item.name) } }
                                } label: {
                                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                                        .frame(width: 30, height: 30).overlay(Circle().strokeBorder(NativeDesktopTheme.text.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3]))).frame(width: 36, height: 40).contentShape(Rectangle())
                                }.accessibilityLabel("색 추가").accessibilityIdentifier("native-pdf-color-add")
                            }
                        }
                        group(leadingDivider: true) {
                            NativePDFWidthSlots(model: model)
                            if model.tool == "tape" {
                                Button { model.setAllTapes(revealed: !model.allTapesRevealed) } label: {
                                    Label(model.allTapesRevealed ? "모두 가리기" : "모두 보기", systemImage: model.allTapesRevealed ? "eye.slash" : "eye")
                                        .font(.system(size: 12)).frame(height: 40).padding(.horizontal, 8).contentShape(Rectangle())
                                }.disabled(!model.hasTapes).opacity(model.hasTapes ? 1 : 0.4).accessibilityIdentifier("native-pdf-tape-all")
                            } else {
                            Button { model.showStyle.toggle() } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 17)).frame(width: 40, height: 40)
                                    .foregroundStyle(model.showStyle ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary)
                                    .background(model.showStyle ? NativeDesktopTheme.text.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                            }.accessibilityLabel("필기 스타일").accessibilityValue(model.styleAccessibilityValue).accessibilityIdentifier("native-pdf-style")
                            }
                        }
                    } else if model.tool == "eraser" {
                        group(leadingDivider: true) {
                            Picker("지우개 방식", selection: Binding(get: { model.palette.eraserMode }, set: { model.setEraserMode($0) })) {
                                Text("획 전체").tag("stroke"); Text("부분").tag("partial")
                            }.pickerStyle(.segmented).frame(width: 150).padding(.horizontal, 4).accessibilityIdentifier("native-pdf-eraser-mode")
                        }
                        group(leadingDivider: true) { NativePDFWidthSlots(model: model) }
                    } else if model.tool == "lasso" {
                        Picker("올가미 방식", selection: Binding(get: { model.lassoMode }, set: { model.setLassoMode($0) })) {
                            Text("자유형").tag("freeform"); Text("박스형").tag("box")
                        }.pickerStyle(.segmented).frame(width: 170).padding(.horizontal, 4).accessibilityIdentifier("native-pdf-lasso-mode")
                        Button { model.pasteObjects() } label: {
                            Label("붙여넣기", systemImage: "doc.on.clipboard").font(.system(size: 12)).frame(height: 40).padding(.horizontal, 8).contentShape(Rectangle())
                        }.disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
                    }
                    if let collapse {
                        group(leadingDivider: true) {
                            Button(action: collapse) { Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle()) }
                                .accessibilityLabel("팔레트 접기").accessibilityIdentifier("native-pdf-palette-collapse")
                        }
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-tool-scroll")
        }.frame(height: 40)
    }
    private func group<Content: View>(leadingDivider: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            if leadingDivider { Rectangle().fill(NativeDesktopTheme.text.opacity(0.08)).frame(width: 1, height: 22).padding(.horizontal, 5) }
            content()
        }
    }
}

struct NativePDFSwatch: View {
    let color: String
    var size: CGFloat = 22
    var ring = false
    /// Tape swatches show the pastel the tape is drawn in.
    var tape = false
    var body: some View {
        Circle().fill(tape ? Color(uiColor: NativePDFObjectRenderer.tapeColor(color)) : NativePDFPaletteLook.uiColor(color)).frame(width: size, height: size)
            .overlay(Circle().stroke(.black.opacity(0.07), lineWidth: 1))
            .background(Circle().stroke(NativeDesktopTheme.accent, lineWidth: 2).padding(-4).opacity(ring ? 1 : 0))
            .background(Circle().stroke(NativeDesktopTheme.surface, lineWidth: 2).padding(-2).opacity(ring ? 1 : 0))
    }
}

private struct NativePDFPaletteColorButton: View {
    var model: NativePDFWorkspaceModel
    let name: String
    let id: String
    var body: some View {
        let selected = model.usesColorSlots && model.activeColor == name
        Button {
            if selected, model.isInkTool { model.showStyle.toggle() } else { model.chooseColor(name) }
        } label: {
            NativePDFSwatch(color: name, size: 24, ring: selected, tape: model.tool == "tape").frame(width: 36, height: 40).contentShape(Rectangle())
        }.accessibilityLabel(NativePDFPaletteLook.colorName(name)).accessibilityIdentifier(id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Three thickness slots. A tap picks one; tapping the picked one opens its
/// twelve steps, so nobody has to guess a millimetre value.
struct NativePDFWidthSlots: View {
    var model: NativePDFWorkspaceModel
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
            .popover(isPresented: Binding(get: { model.editingWidthSlot == index },
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
                Image(systemName: "mic").font(.system(size: 17)).frame(width: 40, height: 40).contentShape(Rectangle())
            }
        }
        .foregroundStyle(model.recordingStartedAt == nil ? NativeDesktopTheme.secondary : Color.red)
        .accessibilityLabel(model.recordingStartedAt == nil ? "녹음 시작" : "녹음 정지")
        .accessibilityIdentifier("native-pdf-record")
    }
}
