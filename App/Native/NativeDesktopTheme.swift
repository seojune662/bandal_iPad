import SwiftUI
import UIKit

/// Semantic colors and metrics shared with the desktop design system.
/// Native controls render this chrome; no HTML or renderer is embedded.
enum NativeDesktopTheme {
    // Figma variables: Surface/Paper, Surface/Tool, Brand/Accent Soft. Window regions use `NativeGlass` instead.
    static let bgApp = adaptive(0xffffff, 0x181818)
    static let surface = adaptive(0xf7f7f7, 0x1f1f1f)
    static let raised = adaptive(0xededed, 0x2c2c2c)
    static let overlay = adaptive(0xffffff, 0x292929)
    /// The chosen segment of `BandalSegmented`: white in light, a lighter pill on the track in dark (whatever the track sits on).
    static let segmentSelected = adaptive(0xffffff, 0x181818)
    /// Figma `Text/Primary` and `Text/Secondary`.
    static let text = adaptive(0x141414, 0xededed)
    static let secondary = adaptive(0x6b6b6b, 0xa1a1a1)
    /// Figma `Text/Tertiary`: counts, hints, chevrons, footnotes.
    static let muted = adaptive(0x8f8f8f, 0x6e6e6e)
    /// Figma `Brand/Accent`: filled buttons, chosen marks, the user's bubble.
    static let accent = adaptive(0x1a1a1a, 0xc4c4c4)
    static let onAccent = adaptive(0xffffff, 0x181818)
    /// Figma `Surface/Separator`: strokes of cards, chips and fields, and lines inside them.
    static let border = adaptive(0xe5e5e5, 0x2e2e2e)
    static let accentMuted = adaptive(0xededed, 0x2c2c2c)
    /// The skinny rail sits one tone behind the panels, so the open panel's button reads as its tab.
    static let rail = adaptive(0xe8e8ea, 0x101010)
    /// The AI panel: one tone darker than the home sidebar, so the two never look like the same place.
    static let aiSurface = adaptive(0xf0f0f2, 0x141414)
    static let navigationWidth: CGFloat = 48
    static let courseWidth: CGFloat = 240
    static let materialsWidth: CGFloat = 288
    static var fontScale: CGFloat {
        let value = UserDefaults.standard.double(forKey: "native.fontScale")
        return [0.9, 1, 1.1, 1.2].contains(value) ? CGFloat(value) : 1
    }
    static var compact: Bool { UserDefaults.standard.string(forKey: "native.density") == "compact" }
    static let chromeHeight: CGFloat = 44
    static var controlHeight: CGFloat { (compact ? 28 : 32) * fontScale }
    static var buttonHeight: CGFloat { (compact ? 32 : 36) * fontScale }
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * fontScale, weight: weight, design: design)
    }
    static func spacing(_ base: CGFloat) -> CGFloat {
        let value: CGFloat = compact && base == 12 ? 8 : compact && base == 16 ? 12 : base
        return value * fontScale
    }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct NativeChromeButton: View {
    let title: String
    let symbol: String
    var selected = false
    /// The highlight behind a selected button.
    var selectedFill = NativeDesktopTheme.raised
    /// A rail button whose panel is open beside it: `NativeRailSurface` draws the panel's tab behind it,
    /// so the button itself draws no highlight.
    var joinsPanel = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                .foregroundStyle(NativeGlass.icon)
                .frame(width: 44, height: 44)
                .background { if selected, !joinsPanel { RoundedRectangle(cornerRadius: 8).fill(selectedFill).padding(5) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}
