import SwiftUI
import UIKit

/// The window's decor: a hand-tuned palette and how loudly it shows. The palette's colours live only in
/// `NativeWorkspaceBackdrop`; the glass regions let it through in proportion to `intensity`, and the
/// chosen row and the pressed control take the palette's accent. Paper never takes any of it.
struct NativeDecorPalette: Sendable {
    let id: String
    /// 3 × 3 mesh colours, row by row from the top leading corner, which is the lit one.
    let light: [UInt32], dark: [UInt32]
    /// The palette's accent: selection tints and, later, the accent token.
    let accentLight: UInt32, accentDark: UInt32

    /// 새벽: periwinkle into lilac and blush by day, deep indigo into plum by night.
    static let dawn = NativeDecorPalette(id: "dawn",
        light: [0xdde4ff, 0xe8e0fc, 0xf7e4ee,
                0xd6e6f8, 0xe3ddf7, 0xf3dfe4,
                0xd2eaf0, 0xdee0f5, 0xf0e3dc],
        dark: [0x1d2650, 0x271f4b, 0x33213f,
               0x152541, 0x1e1d3c, 0x2b1d33,
               0x10283a, 0x19213e, 0x281e2b],
        accentLight: 0x5a5fd8, accentDark: 0xa3a6ff)
}

enum NativeDecor {
    static let palette = NativeDecorPalette.dawn
    /// 0 is barely-there (today's grey glass over a faint wash), 1 the loudest.
    static let intensity: CGFloat = 0.55

    /// Glass opacity: `quiet` at intensity 0 down to `loud` at 1.
    static func alpha(_ quiet: CGFloat, _ loud: CGFloat) -> CGFloat { quiet + (loud - quiet) * intensity }
    /// The mesh's saturation follows the dial: a faint wash at 0, the palette as tuned at about 0.8.
    static var saturation: CGFloat { 0.35 + 0.8 * intensity }
    /// How strongly a chosen row takes the accent.
    static var selectionAlpha: (light: CGFloat, dark: CGFloat) { (0.06 + 0.08 * intensity, 0.08 + 0.1 * intensity) }
}

/// The window's glass surfaces, from the Figma styles `Glass/라이트|다크/레일 · 패널 · 종이`.
/// Each is a translucent fill; `NativeWorkspaceBackdrop` is what shows through.
/// Paint one per region and nothing opaque on top, or the glass turns into a flat colour.
enum NativeGlass {
    static let rail = fill(0xdcdce1, NativeDecor.alpha(0.93, 0.5), 0x131315, NativeDecor.alpha(0.95, 0.6))
    static let panel = fill(0xf4f4f6, NativeDecor.alpha(0.9, 0.58), 0x1f1f21, NativeDecor.alpha(0.94, 0.66))
    /// Documents, notes and web pages: opaque, so ink and page colours read true whatever the decor.
    static let paper = fill(0xffffff, 1, 0x18181a, 1)
    /// `Surface/Separator`: the hairline under the tab strip and between panels.
    static let separator = NativeDesktopTheme.adaptive(0xe5e5e5, 0x2e2e2e)
    /// A hairline drawn on a glass panel (between rail, panels and paper).
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.07) : UIColor.black.withAlphaComponent(0.06) })
    /// A chosen row or a pressed control on a glass panel: the palette's accent, faint.
    static let selection = Color(uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark, alpha = NativeDecor.selectionAlpha
        return rgb(dark ? NativeDecor.palette.accentDark : NativeDecor.palette.accentLight, dark ? alpha.dark : alpha.light)
    })
    /// `Glass/팝업`: the tint over the glass of anything that floats (palette, popover, menu, toast).
    /// Light is the style's two fills as one: white 70 % under #BFBFBF 10 %.
    static let popup = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 0.84) : UIColor(white: 0xf6 / 255, alpha: 0.73) })
    /// `Glass/시트`: settings, the study board and its editor.
    static let sheet = fill(0xfafafb, 0.93, 0x1c1c1e, 0.93)
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

    private static func fill(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }
    fileprivate static func rgb(_ value: UInt32, _ alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
}

/// What the glass sits on: the decor palette as a 3 × 3 mesh, blended in a perceptual space so
/// neighbouring hues never pass through grey. An iPad app cannot see the home-screen wallpaper behind
/// its window, so this is the window's own wallpaper.
struct NativeWorkspaceBackdrop: View {
    private static let colors: [Color] = zip(NativeDecor.palette.light, NativeDecor.palette.dark).map { light, dark in
        Color(uiColor: UIColor { traits in
            let color = NativeGlass.rgb(traits.userInterfaceStyle == .dark ? dark : light, 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return color }
            return UIColor(hue: hue, saturation: min(1, saturation * NativeDecor.saturation), brightness: brightness, alpha: 1)
        })
    }
    /// The middle column and row bow a little, so the blend reads as light falling rather than a grid.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.55, 0], [1, 0],
        [0, 0.45], [0.42, 0.56], [1, 0.4],
        [0, 1], [0.6, 1], [1, 1],
    ]
    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: Self.colors, colorSpace: .perceptual)
            .ignoresSafeArea().accessibilityHidden(true)
    }
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
                NativeGlass.rail.ignoresSafeArea()
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
