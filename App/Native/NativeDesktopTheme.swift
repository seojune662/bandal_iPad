import SwiftUI
import UIKit

/// Semantic colors and metrics shared with the desktop design system.
/// Native controls render this chrome; no HTML or renderer is embedded.
enum NativeDesktopTheme {
    static let bgApp = adaptive(0xffffff, 0x212121)
    static let surface = adaptive(0xf9f9f9, 0x181818)
    static let raised = adaptive(0xeeeeee, 0x303030)
    static let overlay = adaptive(0xffffff, 0x292929)
    static let text = adaptive(0x0d0d0d, 0xececec)
    static let secondary = adaptive(0x565656, 0xb4b4b4)
    static let muted = adaptive(0x686868, 0x9b9b9b)
    static let accent = adaptive(0x171717, 0xececec)
    static let onAccent = adaptive(0xffffff, 0x171717)
    static let border = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.09) : UIColor.black.withAlphaComponent(0.075) })
    static let accentMuted = adaptive(0xe9e9e9, 0x333333)
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
                .frame(width: 36, height: 36)
                .background(selected ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}
