import SwiftUI
import UIKit

/// The window's glass surfaces, from the Figma styles `Glass/라이트|다크/레일 · 패널 · 종이`.
/// Each is a translucent fill; `NativeWorkspaceBackdrop` is what shows through.
/// Paint one per region and nothing opaque on top, or the glass turns into a flat colour.
enum NativeGlass {
    static let rail = fill(0xdcdce1, 0.93, 0x131315, 0.95)
    static let panel = fill(0xf4f4f6, 0.9, 0x1f1f21, 0.94)
    static let paper = fill(0xffffff, 0.95, 0x18181a, 0.97)
    /// `Surface/Separator`: the hairline under the tab strip and between panels.
    static let separator = NativeDesktopTheme.adaptive(0xe5e5e5, 0x2e2e2e)
    /// A hairline drawn on a glass panel (between rail, panels and paper).
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x2e / 255, green: 0x2e / 255, blue: 0x2e / 255, alpha: 1) : UIColor.black.withAlphaComponent(0.06) })
    /// A chosen row or a pressed control on a glass panel.
    static let selection = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.07) : UIColor.black.withAlphaComponent(0.05) })
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
            let isDark = traits.userInterfaceStyle == .dark, value = isDark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// What the glass sits on. An iPad app cannot see the home-screen wallpaper behind its window, so the
/// design's wallpaper under a 60 pt blur is drawn here as a mesh of its sampled colours.
struct NativeWorkspaceBackdrop: View {
    private static let colors: [Color] = [
        0x08202b, 0x6e5d50, 0x947c63, 0x343829,
        0x122524, 0x1e2f26, 0x37463e, 0x2c341b,
        0x323828, 0x67563d, 0x956430, 0x353116,
        0x3a4f55, 0x35464d, 0x4d5759, 0x71461d,
    ].map { NativeDesktopTheme.adaptive($0, $0) }
    private static let points: [SIMD2<Float>] = (0..<4).flatMap { row in (0..<4).map { SIMD2(Float($0) / 3, Float(row) / 3) } }
    var body: some View {
        MeshGradient(width: 4, height: 4, points: Self.points, colors: Self.colors).ignoresSafeArea().accessibilityHidden(true)
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
