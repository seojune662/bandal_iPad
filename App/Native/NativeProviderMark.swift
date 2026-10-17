import SwiftUI

/// The desktop's brand geometry, compiled into native vector assets. No web
/// renderer is involved. Colors follow the same semantic provider styles.
struct NativeProviderMark: View {
    let provider: String
    var size: CGFloat = 20
    private var isClaude: Bool { provider == "claude" || provider == "claude-code" }
    private var isGemini: Bool { provider == "gemini" }
    private var asset: String { isClaude ? "ClaudeMark" : isGemini ? "GeminiMark" : "OpenAIMark" }
    var body: some View {
        Image(asset).resizable().scaledToFit()
            .foregroundStyle(isClaude ? Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255) : isGemini ? NativeDesktopTheme.accent : NativeDesktopTheme.text)
            .frame(width: size * 0.72, height: size * 0.72)
            .frame(width: size, height: size)
            .background(isGemini ? NativeDesktopTheme.accentMuted : NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(NativeDesktopTheme.border, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
