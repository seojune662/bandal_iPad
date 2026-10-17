import SwiftUI

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
                    .frame(width: max(0, min(360, geometry.size.width - 16)), height: max(0, min(570, geometry.size.height - 16)))
                    .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeDesktopTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4).padding(8)
            }.clipped()
        }
    }
}

struct NativePDFPaletteControls: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(model.tool == "highlighter" ? "형광펜" : model.tool == "pen" ? "펜" : "필기 도구").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.showStyle = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("필기 스타일 닫기").accessibilityIdentifier("native-pdf-style-close")
            }.padding(.leading, 16).padding(.trailing, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isInkTool { inkControls }
                    else { Text(toolHint).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                    Toggle(isOn: Binding(get: { model.shapeRecognitionEnabled }, set: { model.setShapeRecognition($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("도형 보정").font(.system(size: 13, weight: .medium))
                            Text("그린 뒤 펜을 잠시 멈추면 도형으로 정리해요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                        }
                    }.frame(minHeight: 44).accessibilityIdentifier("native-pdf-shape-recognition")
                    Divider()
                    favorites
                }.padding(16)
            }.accessibilityIdentifier("native-pdf-palette-scroll")
                .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
        }.foregroundStyle(NativeDesktopTheme.text).buttonStyle(.plain)
    }
    private var inkControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativePDFStrokePreview(preset: model.currentPreset, highlighter: model.tool == "highlighter", pageWidthPoints: model.currentPageWidthPoints)
                .frame(height: max(60, min(140, NativePDFPaletteStyle.effectiveWidth(model.width, highlighter: model.tool == "highlighter") * (model.currentPageWidthPoints ?? 595.28) + 24)))
                .accessibilityElement(children: .ignore).accessibilityLabel("필기 미리보기, 원본 크기 기준").accessibilityValue(model.styleAccessibilityValue)
                .accessibilityIdentifier("native-pdf-stroke-preview")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], spacing: 0) {
                ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in
                    NativePDFPaletteColorButton(model: model, item: item, id: "native-pdf-color-" + item.name)
                }
            }
            HStack { Text("굵기"); Spacer(); Text(model.widthLabel(for: model.width)).monospacedDigit() }.font(.system(size: 13))
            HStack(spacing: 4) {
                ForEach(Array(model.quickWidths.enumerated()), id: \.offset) { index, width in
                    NativePDFPaletteWidthButton(model: model, width: width, id: "native-pdf-palette-width-\(index)")
                        .frame(maxWidth: .infinity)
                }
            }
            Slider(value: Binding(get: { model.width }, set: { model.setWidth($0) }), in: NativePDFPaletteStyle.widthRange(model.width, highlighter: model.tool == "highlighter"))
                .frame(minHeight: 44).accessibilityLabel("필기 굵기").accessibilityValue(model.widthLabel(for: model.width))
                .accessibilityIdentifier("native-pdf-width-slider")
            HStack { Text("불투명도"); Spacer(); Text("\(Int((model.opacity * 100).rounded()))%").monospacedDigit() }.font(.system(size: 13))
            Slider(value: Binding(get: { model.opacity }, set: { model.setOpacity($0) }), in: NativePDFPaletteStyle.opacityRange(model.opacity, highlighter: model.tool == "highlighter"))
                .frame(minHeight: 44).accessibilityLabel("필기 불투명도").accessibilityValue("\(Int((model.opacity * 100).rounded()))%")
                .accessibilityIdentifier("native-pdf-opacity-slider")
        }
    }
    private var favorites: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("즐겨찾는 펜").font(.system(size: 13, weight: .semibold))
            ForEach(model.favorites.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Button { model.chooseFavorite(index) } label: {
                        HStack(spacing: 10) {
                            NativePDFPaletteFavoriteIcon(preset: model.favorites[index], index: index)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("펜 \(index + 1)").font(.system(size: 13))
                                Text(model.widthLabel(for: model.favorites[index].width, highlighter: false)).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                            }
                            Spacer(minLength: 0)
                            if model.tool == "pen" && model.currentPreset == model.favorites[index] { Image(systemName: "checkmark").foregroundStyle(NativeDesktopTheme.accent) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("즐겨찾는 펜 \(index + 1)").accessibilityValue(model.favoriteAccessibilityValue(index))
                        .accessibilityIdentifier("native-pdf-palette-favorite-\(index)")
                        .accessibilityAddTraits(model.tool == "pen" && model.currentPreset == model.favorites[index] ? .isSelected : [])
                    Button { model.saveFavorite(index) } label: { Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("현재 펜을 즐겨찾기 \(index + 1)에 저장").accessibilityIdentifier("native-pdf-save-favorite-\(index)")
                        .disabled(model.tool != "pen")
                }
            }
            if model.tool != "pen" { Text("펜을 선택하면 현재 스타일을 저장할 수 있어요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
        }
    }
    private var toolHint: String {
        switch model.tool {
        case "eraser": return "필기를 문지르면 지울 수 있어요. 지운 내용은 되돌리기로 복원할 수 있어요."
        case "lasso": return "필기를 둘러싸서 선택한 뒤 이동하거나 복제할 수 있어요."
        case "text": return "페이지를 눌러 텍스트를 추가하고, 선택한 텍스트를 다시 편집할 수 있어요."
        default: return "원문이나 필기를 선택할 수 있어요. 펜과 형광펜을 선택하면 색과 굵기를 바꿀 수 있어요."
        }
    }
}

struct NativePDFPaletteQuickControls: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(NativePDFWorkspaceModel.colors, id: \.name) { item in
                        NativePDFPaletteColorButton(model: model, item: item, id: "native-pdf-quick-color-" + item.name)
                    }
                    Divider().frame(height: 20).padding(.horizontal, 6)
                    ForEach(Array(model.quickWidths.enumerated()), id: \.offset) { index, width in
                        NativePDFPaletteWidthButton(model: model, width: width, id: "native-pdf-width-\(index)")
                    }
                }.fixedSize(horizontal: true, vertical: false).disabled(!model.isInkTool)
            }.accessibilityIdentifier("native-pdf-quick-style-scroll")
            Divider().frame(height: 20).padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(model.favorites.indices, id: \.self) { index in
                    Button { model.chooseFavorite(index) } label: {
                        NativePDFPaletteFavoriteIcon(preset: model.favorites[index], index: index)
                            .frame(width: 44, height: 44)
                            .background(model.tool == "pen" && model.currentPreset == model.favorites[index] ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.accessibilityLabel("즐겨찾는 펜 \(index + 1)").accessibilityValue(model.favoriteAccessibilityValue(index))
                        .accessibilityIdentifier("native-pdf-favorite-\(index)")
                        .accessibilityAddTraits(model.tool == "pen" && model.currentPreset == model.favorites[index] ? .isSelected : [])
                        .contextMenu { Button("현재 펜 저장") { model.saveFavorite(index) }.disabled(model.tool != "pen") }
                }
            }.fixedSize(horizontal: true, vertical: false)
        }.frame(height: 44)
    }
}

private struct NativePDFPaletteFavoriteIcon: View {
    let preset: NativePDFPenPreset
    let index: Int
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "pencil.tip").font(.system(size: 19)).foregroundStyle(Color(uiColor: NativePDFInkSurface.color(preset.color)))
            Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                .padding(2).background(NativeDesktopTheme.surface, in: Circle()).offset(x: 5, y: 5)
        }.frame(width: 28, height: 28).accessibilityHidden(true)
    }
}

private struct NativePDFPaletteColorButton: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    let item: NativePDFWorkspaceModel.InkColor
    let id: String
    var body: some View {
        Button { model.chooseColor(item.name) } label: {
            Circle().fill(item.color).frame(width: 22, height: 22)
                .overlay(Circle().stroke(NativeDesktopTheme.border, lineWidth: 1))
                .padding(4).overlay(Circle().stroke(model.isInkTool && model.color == item.name ? NativeDesktopTheme.accent : .clear, lineWidth: 2))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(item.label).accessibilityIdentifier(id)
            .accessibilityAddTraits(model.isInkTool && model.color == item.name ? .isSelected : [])
    }
}

private struct NativePDFPaletteWidthButton: View {
    @ObservedObject var model: NativePDFWorkspaceModel
    let width: Double
    let id: String
    var body: some View {
        Button { model.chooseQuickWidth(width) } label: {
            Text(model.widthLabel(for: width)).font(.system(size: 11)).monospacedDigit().lineLimit(1)
                .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(abs(model.width - width) < 0.0000001 ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary)
                .background(abs(model.width - width) < 0.0000001 ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.accessibilityLabel("굵기 " + model.widthLabel(for: width)).accessibilityIdentifier(id)
            .accessibilityAddTraits(abs(model.width - width) < 0.0000001 ? .isSelected : [])
    }
}

struct NativePDFStrokePreview: View {
    let preset: NativePDFPenPreset
    let highlighter: Bool
    var pageWidthPoints: Double? = nil
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let y = geometry.size.height / 2
                path.move(to: CGPoint(x: 20, y: y))
                path.addCurve(to: CGPoint(x: geometry.size.width - 20, y: y),
                              control1: CGPoint(x: geometry.size.width * 0.35, y: y - 20),
                              control2: CGPoint(x: geometry.size.width * 0.65, y: y + 20))
            }.stroke(Color(uiColor: NativePDFInkSurface.color(preset.color)).opacity(preset.opacity),
                     style: StrokeStyle(lineWidth: NativePDFPaletteStyle.effectiveWidth(preset.width, highlighter: highlighter) * (pageWidthPoints ?? geometry.size.width), lineCap: .round, lineJoin: .round))
        }.background(Color.white, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NativeDesktopTheme.border, lineWidth: 1))
    }
}
