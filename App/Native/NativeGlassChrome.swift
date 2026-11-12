import SwiftUI
import UIKit

/// The window's decor: a palette and how loudly it shows (Settings › 화면 › 꾸미기). The palette's colours
/// live only in `NativeWorkspaceBackdrop`; the glass regions let it through in proportion to `intensity`,
/// and a chosen row takes the palette's accent. Paper never takes any of it.
struct NativeDecorPalette: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// OKLCH hues the mesh runs through, from the lit top-leading corner to the bottom-trailing one.
    let hues: (Double, Double, Double)
    /// The mesh's chroma at the dial's tuned point; 0 is grey.
    let chroma: Double

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    static let all: [NativeDecorPalette] = [
        .init(id: "dawn", title: "새벽", hues: (270, 295, 345), chroma: 0.05),
        .init(id: "blossom", title: "벚꽃", hues: (350, 15, 50), chroma: 0.05),
        .init(id: "sunset", title: "노을", hues: (30, 60, 330), chroma: 0.06),
        .init(id: "forest", title: "숲", hues: (150, 175, 120), chroma: 0.045),
        .init(id: "ocean", title: "바다", hues: (220, 195, 250), chroma: 0.05),
        .init(id: "lavender", title: "라벤더", hues: (300, 280, 320), chroma: 0.045),
        .init(id: "ink", title: "먹", hues: (70, 60, 80), chroma: 0.012),
        .init(id: "mono", title: "모노", hues: (270, 270, 270), chroma: 0),
    ]
    static let `default` = all[0]
    static func named(_ id: String) -> NativeDecorPalette { all.first { $0.id == id } ?? .default }

    /// The 3 × 3 mesh, row by row. Lightness falls from the lit corner; hue runs along the diagonal and
    /// bows ±12° off it, so the blend has some turn to it rather than a straight ramp.
    func mesh(dark: Bool, saturation: Double) -> [Color] {
        (0..<3).flatMap { row in (0..<3).map { column in
            let t = Double(row + column) / 4, bow = Double(column - row) * 12
            let hue = t < 0.5 ? Self.mix(hues.0, hues.1, t * 2) : Self.mix(hues.1, hues.2, t * 2 - 1)
            let lightness = dark ? 0.31 - 0.08 * t : 0.955 - 0.045 * t
            return Color(uiColor: NativeOKLCH.color(lightness, chroma * saturation * (dark ? 1.25 : 1), hue + bow))
        } }
    }
    /// The accent a chosen row is tinted with.
    func accent(dark: Bool) -> UIColor {
        chroma == 0 ? (dark ? .white : .black) : NativeOKLCH.color(dark ? 0.78 : 0.55, dark ? 0.12 : 0.15, hues.0)
    }
    /// Hue interpolation the short way round.
    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return a + delta * t
    }
}

/// OKLCH → sRGB (Björn Ottosson's OKLab), clipped into the gamut.
enum NativeOKLCH {
    static func color(_ lightness: Double, _ chroma: Double, _ hue: Double, alpha: CGFloat = 1) -> UIColor {
        let radians = hue * .pi / 180, a = chroma * cos(radians), b = chroma * sin(radians)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
        let rgb = linear.map { value -> CGFloat in
            let v = min(max(value, 0), 1)
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha)
    }
}

/// The decor in force: the stored choice, handed down the view tree so every glass region redraws when it changes.
struct NativeDecor: Equatable, Sendable {
    static let paletteKey = "native.decor.palette", intensityKey = "native.decor.intensity"
    static let defaultIntensity = 0.55

    var palette = NativeDecorPalette.default
    /// 0 is barely-there (grey glass over a faint wash), 1 the loudest.
    var intensity = defaultIntensity

    static var stored: NativeDecor {
        let defaults = UserDefaults.standard
        let intensity = defaults.object(forKey: intensityKey) as? Double ?? defaultIntensity
        return NativeDecor(palette: .named(defaults.string(forKey: paletteKey) ?? ""), intensity: min(max(intensity, 0), 1))
    }

    /// Glass opacity: `quiet` at intensity 0 down to `loud` at 1. Reduce Transparency keeps it solid.
    func alpha(_ quiet: CGFloat, _ loud: CGFloat, reduceTransparency: Bool = false) -> CGFloat {
        reduceTransparency ? 1 : quiet + (loud - quiet) * CGFloat(intensity)
    }
    /// The mesh's chroma follows the dial: a faint wash at 0, the palette as tuned near 0.75, louder past it.
    var saturation: Double { 0.25 + intensity }
    func selectionAlpha(dark: Bool) -> CGFloat { dark ? 0.08 + 0.1 * CGFloat(intensity) : 0.06 + 0.08 * CGFloat(intensity) }
}

extension EnvironmentValues {
    @Entry var nativeDecor = NativeDecor.stored
}

/// A glass fill that follows the decor in the environment, so a change redraws it wherever it is painted.
struct NativeDecorStyle: ShapeStyle {
    enum Kind: Sendable { case rail, panel, selection, clear }
    let kind: Kind
    static let clear = NativeDecorStyle(kind: .clear)

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let decor = environment.nativeDecor, dark = environment.colorScheme == .dark
        let solid = environment.accessibilityReduceTransparency
        let color: UIColor = switch kind {
        case .rail: dark ? Self.rgb(0x131315, decor.alpha(0.95, 0.6, reduceTransparency: solid)) : Self.rgb(0xdcdce1, decor.alpha(0.93, 0.5, reduceTransparency: solid))
        case .panel: dark ? Self.rgb(0x1f1f21, decor.alpha(0.94, 0.66, reduceTransparency: solid)) : Self.rgb(0xf4f4f6, decor.alpha(0.9, 0.58, reduceTransparency: solid))
        case .selection: decor.palette.accent(dark: dark).withAlphaComponent(decor.selectionAlpha(dark: dark))
        case .clear: .clear
        }
        return Color(uiColor: color).resolve(in: environment)
    }
    static func rgb(_ value: UInt32, _ alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
}

/// The window's glass surfaces, from the Figma styles `Glass/라이트|다크/레일 · 패널 · 종이`.
/// Each is a translucent fill; `NativeWorkspaceBackdrop` is what shows through.
/// Paint one per region and nothing opaque on top, or the glass turns into a flat colour.
enum NativeGlass {
    static let rail = NativeDecorStyle(kind: .rail)
    static let panel = NativeDecorStyle(kind: .panel)
    /// Documents, notes and web pages: opaque, so ink and page colours read true whatever the decor.
    static let paper = fill(0xffffff, 1, 0x18181a, 1)
    /// `Surface/Separator`: the hairline under the tab strip and between panels.
    static let separator = NativeDesktopTheme.adaptive(0xe5e5e5, 0x2e2e2e)
    /// A hairline drawn on a glass panel (between rail, panels and paper).
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.07) : UIColor.black.withAlphaComponent(0.06) })
    /// A chosen row or a pressed control on a glass panel: the palette's accent, faint.
    static let selection = NativeDecorStyle(kind: .selection)
    /// `Glass/팝업`: the tint over the glass of anything that floats (palette, popover, menu, toast).
    /// Light is the style's two fills as one: white 70 % under #BFBFBF 10 %.
    /// Floating surfaces take a breath of the palette's first hue, as strong as the dial says; they are drawn
    /// fresh each time they open, so the stored decor is read then.
    static let popup = Color(uiColor: UIColor { traits in
        tinted(dark: traits.userInterfaceStyle == .dark, lightness: (0.97, 0.235), share: 0.55, alpha: (0.73, 0.84))
    })
    /// `Glass/시트`: settings, the study board and its editor.
    static let sheet = Color(uiColor: UIColor { traits in
        tinted(dark: traits.userInterfaceStyle == .dark, lightness: (0.985, 0.235), share: 0.3, alpha: (0.93, 0.93))
    })
    /// The rim of a floating surface.
    static let rim = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.14) : UIColor(white: 0xdb / 255, alpha: 1) })
    /// Rail and panel-header icons (`Brand/Accent`).
    static let icon = NativeDesktopTheme.adaptive(0x1a1a1a, 0xededed)
    /// Icons and small labels on the side panels (sidebar rows, the files header, the window buttons).
    static let panelIcon = NativeDesktopTheme.adaptive(0x555555, 0x9a9a9a)
    static let panelTertiary = NativeDesktopTheme.adaptive(0x737373, 0x9a9a9a)
    /// A search field on a side panel: fill, stroke, magnifier and prompt.
    static let field = fill(0xffffff, 0.7, 0x1c1c1e, 0.7)
    static let fieldStroke = NativeDesktopTheme.adaptive(0xe6e6e6, 0x222222)
    static let fieldGlyph = NativeDesktopTheme.adaptive(0x999999, 0x4a4a4a)
    static let fieldPrompt = NativeDesktopTheme.adaptive(0xa8a8a8, 0x4a4a4a)
    /// `Surface/Tool`: the chosen tab's pill.
    static let tool = NativeDesktopTheme.adaptive(0xf7f7f7, 0x1f1f1f)

    /// A neutral surface nudged toward the palette: `share` of the mesh's chroma, scaled by the dial.
    private static func tinted(dark: Bool, lightness: (Double, Double), share: Double, alpha: (CGFloat, CGFloat)) -> UIColor {
        let decor = NativeDecor.stored
        return NativeOKLCH.color(dark ? lightness.1 : lightness.0, decor.palette.chroma * share * decor.saturation, decor.palette.hues.0,
                                 alpha: dark ? alpha.1 : alpha.0)
    }
    private static func fill(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? NativeDecorStyle.rgb(dark, darkAlpha) : NativeDecorStyle.rgb(light, lightAlpha)
        })
    }
}

/// What the glass sits on: the decor palette as a 3 × 3 mesh, blended in a perceptual space so
/// neighbouring hues never pass through grey. An iPad app cannot see the home-screen wallpaper behind
/// its window, so this is the window's own wallpaper.
struct NativeWorkspaceBackdrop: View {
    @Environment(\.nativeDecor) private var decor
    @Environment(\.colorScheme) private var scheme
    /// The middle column and row bow a little, so the blend reads as light falling rather than a grid.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.55, 0], [1, 0],
        [0, 0.45], [0.42, 0.56], [1, 0.4],
        [0, 1], [0.6, 1], [1, 1],
    ]
    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: decor.palette.mesh(dark: scheme == .dark, saturation: decor.saturation),
                     colorSpace: .perceptual)
            .overlay {
                // Grain: a fine tile of noise keeps the blend from banding and gives the glass something to catch.
                Image(uiImage: NativeGrain.tile).resizable(resizingMode: .tile)
                    .blendMode(.overlay).opacity(0.08 + 0.16 * decor.intensity)
            }
            .ignoresSafeArea().accessibilityHidden(true)
    }
}

/// A small window drawn with the decor: rail, panel and a page, over the backdrop. Onboarding shows it
/// while the palette is chosen, so the choice is seen on something like the app before the app opens.
struct NativeDecorPreview: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 5).fill(index == 0 ? AnyShapeStyle(NativeGlass.selection) : AnyShapeStyle(.clear))
                        .overlay { Circle().fill(NativeGlass.icon.opacity(0.55)).frame(width: 9, height: 9) }
                        .frame(width: 22, height: 22)
                }
                Spacer()
            }.padding(.top, 14).frame(width: 40).frame(maxHeight: .infinity).background(NativeGlass.rail)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<5, id: \.self) { index in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(NativeGlass.panelIcon.opacity(0.5)).frame(width: 10, height: 9)
                        Capsule().fill(NativeGlass.panelIcon.opacity(0.35)).frame(width: [70, 54, 82, 60, 46][index], height: 6)
                    }
                    .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(index == 1 ? AnyShapeStyle(NativeGlass.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
            }.padding(.top, 14).padding(.horizontal, 8).frame(width: 150).frame(maxHeight: .infinity).background(NativeGlass.panel)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(NativeDesktopTheme.text.opacity(0.75)).frame(width: 120, height: 9)
                ForEach(0..<5, id: \.self) { index in
                    Capsule().fill(NativeDesktopTheme.muted.opacity(0.35)).frame(width: [210, 190, 220, 160, 200][index], height: 6)
                }
                Spacer()
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(NativeGlass.paper)
        }
        .background { NativeWorkspaceBackdrop() }
        .clipShape(shape).overlay { shape.strokeBorder(NativeGlass.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        .accessibilityHidden(true)
    }
}

/// A 128 pt tile of grey noise, made once.
enum NativeGrain {
    static let tile: UIImage = {
        let side = 128
        var generator = SystemRandomNumberGenerator()
        let pixels = (0..<side * side).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let image = pixels.withUnsafeBytes { bytes -> CGImage? in
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage()
    }()
}

/// The backdrop as it sits behind a drawer that floats over the paper: the window's mesh, laid out at
/// the window's size and shifted so the drawer shows the same stretch of it a pinned panel would.
struct NativeBackdropUnderlay: View {
    let windowSize: CGSize
    var alignment: Alignment = .leading
    var leadingInset: CGFloat = 0
    var body: some View {
        NativeWorkspaceBackdrop().frame(width: windowSize.width, height: windowSize.height)
            .offset(x: -leadingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .accessibilityHidden(true)
    }
}

/// The open panel's tab on the rail: the panel's surface reaches across the rail behind the button
/// and meets the panel's edge with two concave 12 pt corners. Drawn in a 48 × 76 box, the tab itself
/// being the middle 52 pt. The first tab runs up to the window's top edge instead of curving back.
struct NativeRailTab: Shape {
    static let size = CGSize(width: 48, height: 76)
    var reachesTop = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if reachesTop {
            path.move(to: CGPoint(x: 0, y: -400)); path.addLine(to: CGPoint(x: 48, y: -400))
        } else {
            path.move(to: CGPoint(x: 0, y: 12)); path.addLine(to: CGPoint(x: 36, y: 12))
            path.addCurve(to: CGPoint(x: 48, y: 0), control1: CGPoint(x: 44, y: 12), control2: CGPoint(x: 48, y: 8))
        }
        path.addLine(to: CGPoint(x: 48, y: 76))
        path.addCurve(to: CGPoint(x: 36, y: 64), control1: CGPoint(x: 48, y: 68), control2: CGPoint(x: 44, y: 64))
        path.addLine(to: CGPoint(x: 0, y: 64)); path.closeSubpath()
        return path
    }
}

/// The rail's surface with the open panel's tab cut out of it and filled with the panel's glass,
/// so rail and panel never stack into a third colour. `tabCenter` is the open button's centre in the rail.
struct NativeRailSurface: View {
    var tabCenter: CGFloat?
    var reachesTop = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(NativeGlass.rail).ignoresSafeArea()
                if let tabCenter { tab(tabCenter).foregroundStyle(.black).blendMode(.destinationOut) }
            }.compositingGroup()
            if let tabCenter { tab(tabCenter).foregroundStyle(NativeGlass.panel) }
        }.accessibilityHidden(true)
    }
    private func tab(_ center: CGFloat) -> some View {
        NativeRailTab(reachesTop: reachesTop).frame(width: NativeRailTab.size.width, height: NativeRailTab.size.height)
            .offset(y: center - NativeRailTab.size.height / 2)
    }
}

/// 화면 › 꾸미기: the palette swatches and the intensity slider. Both write straight to the stored decor,
/// which the workspace hands down, so the window behind the settings sheet repaints as the slider moves.
struct NativeDecorSettingsGroup: View {
    @AppStorage(NativeDecor.paletteKey) private var paletteID = NativeDecorPalette.default.id
    @AppStorage(NativeDecor.intensityKey) private var intensity = NativeDecor.defaultIntensity
    var body: some View {
        NativeSettingsGroup(title: "꾸미기", description: "창 가장자리의 색이에요. 문서와 필기 색은 바뀌지 않아요.") {
            VStack(alignment: .leading, spacing: 12) {
                BandalText("색")
                NativeDecorSwatches(selection: $paletteID)
            }.padding(.vertical, 4)
            NativeSettingsRow(title: "세기", height: 61) {
                NativeDecorIntensitySlider(value: $intensity, palette: .named(paletteID))
            }
        }
    }
}

struct NativeDecorSwatches: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.locale) private var locale
    private static let points: [SIMD2<Float>] = (0..<3).flatMap { row in (0..<3).map { SIMD2(Float($0) / 2, Float(row) / 2) } }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(NativeDecorPalette.all) { palette in
                    let chosen = palette.id == selection
                    Button { selection = palette.id } label: {
                        VStack(spacing: 6) {
                            // The palette's daylight mesh at full strength in either mode: a dark mesh this small reads as mud.
                            MeshGradient(width: 3, height: 3, points: Self.points, colors: palette.mesh(dark: false, saturation: 2), colorSpace: .perceptual)
                                .frame(width: 36, height: 36).clipShape(Circle())
                                .overlay { Circle().strokeBorder(NativeGlass.hairline, lineWidth: 1) }
                                .padding(3)
                                .overlay { if chosen { Circle().strokeBorder(Color(uiColor: palette.accent(dark: scheme == .dark)), lineWidth: 2) } }
                            Text(verbatim: NativeAppLocale.string(palette.title, locale)).font(NativeDesktopTheme.font(12, weight: chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
                        }.frame(minWidth: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(NativeAppLocale.string(palette.title, locale)).accessibilityAddTraits(chosen ? .isSelected : [])
                        .accessibilityIdentifier("native-settings-decor-" + palette.id)
                }
            }
        }.sensoryFeedback(.selection, trigger: selection)
    }
}

/// 은은하게 … 선명하게: a 200 pt bar filled with the palette's own accent, with a knob that follows the finger.
/// It clicks at each quarter, and VoiceOver steps it by tenths.
struct NativeDecorIntensitySlider: View {
    @Binding var value: Double
    let palette: NativeDecorPalette
    @Environment(\.colorScheme) private var scheme
    private static let width: CGFloat = 200
    var body: some View {
        let accent = Color(uiColor: palette.accent(dark: scheme == .dark))
        HStack(spacing: 10) {
            Text("은은하게").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Capsule().fill(NativeDesktopTheme.surface).frame(height: 6)
                Capsule().fill(LinearGradient(colors: [accent.opacity(0.25), accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, Self.width * value), height: 6)
                Circle().fill(.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .overlay { Circle().strokeBorder(NativeGlass.hairline, lineWidth: 0.5) }
                    .offset(x: (Self.width - 22) * value)
            }
            .frame(width: Self.width, height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value = min(max(($0.location.x - 11) / (Self.width - 22), 0), 1) })
            .sensoryFeedback(.selection, trigger: Int((value * 4).rounded()))
            .accessibilityElement().accessibilityLabel("꾸미기 세기").accessibilityValue("\(Int((value * 100).rounded()))%")
            .accessibilityAdjustableAction { value = min(max(value + ($0 == .increment ? 0.1 : -0.1), 0), 1) }
            .accessibilityIdentifier("native-settings-decor-intensity")
            Text("선명하게").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
        }
    }
}
