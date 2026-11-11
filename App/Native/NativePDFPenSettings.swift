import SwiftUI

/// The pen settings (Figma 261:8446): a glass popover under the 펜 button with the pen type, a stroke preview,
/// the palette's colours, thickness and opacity, 모양 다듬기 and the three favourite pens.
struct NativePDFPenSettings: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        NativePDFToolPopover(model: model) {
            HStack(spacing: 8) {
                Text("펜").font(.system(size: 17, weight: .bold))
                Spacer(minLength: 0)
                star
            }
            NativePDFSegments(options: [("pen", "만년필"), ("ballpoint", "볼펜"), ("brush", "붓")], selection: model.isPenLike ? model.tool : model.penKind,
                              identifierPrefix: "native-pdf-pen-kind-") { model.choosePenKind($0) }
            NativePDFSquiggle.preview.stroke(NativePDFPaletteLook.swatch(model.color).opacity(model.opacity),
                                             style: StrokeStyle(lineWidth: previewWidth, lineCap: .round, lineJoin: .round))
                .frame(width: 240, height: 36).frame(maxWidth: .infinity).frame(height: 60)
                .background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement().accessibilityLabel("미리보기 · " + NativePDFPaletteLook.colorName(model.color) + " · " + model.widthLabel(for: model.width))
                .accessibilityValue(model.styleAccessibilityValue).accessibilityIdentifier("native-pdf-stroke-preview")
            NativePDFPopoverCaption("색 · 기존 팔레트")
            colors
            NativePDFWidthSlider(model: model, showsCount: true)
            NativePDFOpacitySlider(model: model)
            Toggle(isOn: Binding(get: { model.shapeRecognitionEnabled }, set: { model.setShapeRecognition($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("모양 다듬기").font(.system(size: 14))
                    Text("그리다 멈추면 직선 · 원으로").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                }
            }.toggleStyle(BandalToggleStyle(compact: true)).frame(height: 38)
                .accessibilityLabel("모양 다듬기").accessibilityIdentifier("native-pdf-shape-recognition")
            NativePDFPopoverCaption("즐겨찾기")
            HStack(spacing: 9) { ForEach(model.favorites.indices, id: \.self) { favorite($0) } }
        }
    }
    /// The preview's 4 pt line is step 5 of 12 (0.003 of the page width).
    private var previewWidth: CGFloat { min(24, max(1.5, model.width * (model.tool == "brush" ? NativePDFPaletteStyle.brushWidthScale : 1) * 4 / 0.003)) }
    /// Figma 264:1440. Filled on its tile: the current pen is a favourite, a tap removes it. Outline: a tap puts
    /// the current pen in the first empty cell. Faded: the three cells are taken.
    private var star: some View {
        let saved = model.favoriteIndex != nil, full = !saved && !model.hasEmptyFavorite
        return Button { model.toggleFavorite() } label: {
            Image(saved ? "PDFIconStarFill" : "PDFIconStar").foregroundStyle(NativeDesktopTheme.text).frame(width: 26, height: 26)
                .background(saved ? NativeGlass.tool : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(full ? 0.3 : 1).frame(width: 44, height: 44).contentShape(Rectangle())
        }.frame(width: 26, height: 26)
            .accessibilityLabel(saved ? "즐겨찾기에서 빼기" : "즐겨찾기에 추가").accessibilityIdentifier("native-pdf-favorite-star")
            .accessibilityAddTraits(saved ? .isSelected : [])
    }
    private var colors: some View {
        let slots = model.colorSlots, missing = NativePDFWorkspaceModel.colors.filter { !slots.contains($0.name) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(slots, id: \.self) { name in
                    NativePDFColorCell(color: NativePDFPaletteLook.swatch(name), chosen: model.color == name, rimmed: name == "ink") { model.chooseColor(name) }
                        .accessibilityLabel(NativePDFPaletteLook.colorName(name) + " 색상").accessibilityIdentifier("native-pdf-color-" + name)
                        .contextMenu { if slots.count > 1 { Button("이 색 빼기", role: .destructive) { model.removeColorSlot(name) } } }
                }
                Menu {
                    ForEach(missing, id: \.name) { item in Button(item.label) { model.addColorSlot(item.name) } }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(NativeGlass.separator, lineWidth: 1)).contentShape(Rectangle())
                }.disabled(missing.isEmpty).accessibilityLabel("색 추가").accessibilityIdentifier("native-pdf-settings-color-add")
            }
        }.frame(height: 36)
    }
    /// A favourite cell (82 × 49): the pen's stroke in its colour and width. The one in use is filled.
    /// An empty cell takes the current pen.
    @ViewBuilder private func favorite(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if let preset = model.favorites[index] {
            let chosen = model.favoriteIndex == index
            Button { model.chooseFavorite(index) } label: {
                NativePDFSquiggle.favorite.stroke(NativePDFPaletteLook.swatch(preset.color).opacity(preset.opacity),
                                                  style: StrokeStyle(lineWidth: min(9, max(1.5, preset.width * 2.2 / 0.003)), lineCap: .round, lineJoin: .round))
                    .frame(width: 60, height: 24.4).frame(maxWidth: .infinity).frame(height: 49)
                    .background(chosen ? NativeGlass.tool : .clear, in: shape)
                    .overlay { if !chosen { shape.strokeBorder(NativeGlass.separator, lineWidth: 1.1) } }.contentShape(Rectangle())
            }.accessibilityLabel("즐겨찾는 펜 \(index + 1): " + NativePDFPaletteLook.colorName(preset.color)).accessibilityValue(model.favoriteAccessibilityValue(index))
                .accessibilityIdentifier("native-pdf-palette-favorite-\(index)").accessibilityAddTraits(chosen ? .isSelected : [])
                .contextMenu {
                    Button("현재 펜 저장") { model.saveFavorite(index) }.accessibilityIdentifier("native-pdf-save-favorite-\(index)")
                    Button("즐겨찾기에서 빼기", role: .destructive) { model.clearFavorite(index) }
                }
        } else {
            Button { model.saveFavorite(index) } label: {
                Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).frame(height: 49)
                    .overlay { shape.strokeBorder(NativeGlass.separator, lineWidth: 1.1) }.contentShape(Rectangle())
            }.accessibilityLabel("즐겨찾는 펜 \(index + 1)에 현재 펜 저장").accessibilityIdentifier("native-pdf-save-favorite-\(index)")
        }
    }
}

/// A stroke drawn in the design: the start point and cubic segments of a Figma vector, in that vector's own units.
struct NativePDFSquiggle: Shape {
    let numbers: [CGFloat]
    let origin: CGPoint
    let scale: CGFloat
    func path(in rect: CGRect) -> Path {
        func point(_ index: Int) -> CGPoint { CGPoint(x: (origin.x + numbers[index]) * scale, y: (origin.y + numbers[index + 1]) * scale) }
        var path = Path(); path.move(to: point(0))
        for index in stride(from: 2, to: numbers.count, by: 6) { path.addCurve(to: point(index + 4), control1: point(index), control2: point(index + 2)) }
        return path
    }
    /// 261:8461 in its 348 × 52.2 frame, drawn at the popover's 1 / 1.45 scale (240 × 36).
    static let preview = Self(numbers: [0, 15.66, 60.9, -5.22, 95.7, 36.54, 147.9, 15.66, 200.1, -5.22, 234.9, -5.22, 287.1, 15.66, 339.3, 36.54, 330.6, 26.1, 330.6, 13.05],
                              origin: CGPoint(x: 8.7, y: 10.44), scale: 1 / 1.45)
    /// 261:8520 in its 86.85 × 35.39 frame (60 × 24.4).
    static let favorite = Self(numbers: [0, 10.618, 7.72, -3.539, 16.406, 24.776, 29.434, 10.618, 42.462, -3.539, 51.147, -3.539, 64.175, 10.618, 77.203, 24.776, 67.553, 17.697, 67.553, 8.849],
                               origin: CGPoint(x: 9.652, y: 7.079), scale: 1 / 1.45)
    /// 260:8653 in its 44 × 16 frame.
    static let weight = Self(numbers: [0, 4.8, 2.8, -1.6, 7.2, 11.2, 13.8, 4.8, 20.4, -1.6, 24.8, -1.6, 31.4, 4.8, 38, 11.2, 32, 8, 32, 4], origin: CGPoint(x: 6, y: 3.2), scale: 1)
}
