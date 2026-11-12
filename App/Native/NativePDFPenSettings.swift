import SwiftUI

/// The pen settings (Figma 261:8446 without its favourites, which the owner dropped): a glass popover under the 펜
/// button with the pen type (the plain 펜 first), a stroke preview, the palette's colours, thickness and opacity, 모양 다듬기.
struct NativePDFPenSettings: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        NativePDFToolPopover(model: model) {
            NativePDFPopoverTitle("펜")
            NativePDFSegments(options: [("pen", "펜"), ("ballpoint", "볼펜"), ("brush", "붓")], selection: model.isPenLike ? model.tool : model.penKind,
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
        }
    }
    /// The preview's 4 pt line is step 5 of 12 (0.003 of the page width).
    private var previewWidth: CGFloat { min(24, max(1.5, model.width * (model.tool == "brush" ? NativePDFPaletteStyle.brushWidthScale : model.tool == "pen" ? NativePDFPaletteStyle.penWidthScale : 1) * 4 / 0.003)) }
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
    /// 260:8653 in its 44 × 16 frame.
    static let weight = Self(numbers: [0, 4.8, 2.8, -1.6, 7.2, 11.2, 13.8, 4.8, 20.4, -1.6, 24.8, -1.6, 31.4, 4.8, 38, 11.2, 32, 8, 32, 4], origin: CGPoint(x: 6, y: 3.2), scale: 1)
}
