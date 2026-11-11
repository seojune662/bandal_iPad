import SwiftUI
import UIKit

/// Where the conversation is drawn: the side panel (Figma A1–A6) or a whole tab (F1–F2).
enum NativeAssistantStyle { case panel, tab }

/// The Figma numbers that differ between the side panel and the full tab.
struct NativeAssistantLook {
    let text: CGFloat, lineHeight: CGFloat
    /// "반달 AI" and its mark.
    let label: CGFloat
    let bubbleRadius: CGFloat, bubblePadding: CGSize, bubbleWidth: CGFloat
    let messageGap: CGFloat, answerGap: CGFloat
    let sourceText: CGFloat, sourceIcon: CGFloat, sourceHeight: CGFloat, sourcePadding: CGFloat, sourceFill: Color
    let actionText: CGFloat, actionIcon: CGFloat, actionHeight: CGFloat, actionPadding: CGFloat, actionStroke: CGFloat
    let tile: CGFloat, tileRadius: CGFloat, tileIcon: CGFloat, title: CGFloat, titleLine: CGFloat

    static let panel = NativeAssistantLook(text: 15, lineHeight: 1.45, label: 13, bubbleRadius: 18, bubblePadding: .init(width: 14, height: 10), bubbleWidth: 260,
        messageGap: 22, answerGap: 10, sourceText: 12, sourceIcon: 11, sourceHeight: 25, sourcePadding: 9, sourceFill: NativeDesktopTheme.bgApp,
        actionText: 13, actionIcon: 12, actionHeight: 33, actionPadding: 12, actionStroke: 0, tile: 48, tileRadius: 16, tileIcon: 22, title: 20, titleLine: 1.45)
    static let tab = NativeAssistantLook(text: 16, lineHeight: 1.5, label: 14, bubbleRadius: 20, bubblePadding: .init(width: 16, height: 11), bubbleWidth: 520,
        messageGap: 28, answerGap: 12, sourceText: 13, sourceIcon: 12, sourceHeight: 30, sourcePadding: 10, sourceFill: NativeDesktopTheme.surface,
        actionText: 14, actionIcon: 13, actionHeight: 39, actionPadding: 14, actionStroke: 1, tile: 60, tileRadius: 20, tileIcon: 27.5, title: 28, titleLine: 1.5)
}

extension View {
    /// Figma's line height (a factor of the size): the extra goes between lines and half of it above and below.
    func assistantLine(_ size: CGFloat, _ factor: CGFloat = 1.45) -> some View {
        let extra = max(0, size * factor - UIFont.systemFont(ofSize: size).lineHeight)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
    /// A 44 pt touch area around a small glyph without moving its neighbours.
    func assistantHitArea(_ inset: CGFloat = 12) -> some View { padding(inset).contentShape(Rectangle()).padding(-inset) }
}

/// A button that draws its label as given: the caller sets the disabled look (Figma: 35 %).
struct NativeAssistantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.6 : 1) }
}

/// Chips and pills of the conversation: attachment, source, action, suggestion.
struct NativeAssistantPill: View {
    var symbol: String?
    /// A template image from the asset catalog, for icons Figma draws as vectors.
    var asset: String?
    let title: Text
    var size: CGFloat = 12
    var iconSize: CGFloat = 11
    var weight: Font.Weight = .regular
    var color = NativeDesktopTheme.secondary
    var iconColor: Color?
    var height: CGFloat = 25
    var padding: CGFloat = 9
    var gap: CGFloat = 5
    var fill = NativeDesktopTheme.bgApp
    var stroke: CGFloat = 0
    /// A fixed width (the panel's suggestions are all one size); nil hugs the text.
    var width: CGFloat?
    var body: some View {
        HStack(spacing: gap) {
            if let symbol { Image(systemName: symbol).font(.system(size: iconSize)).foregroundStyle(iconColor ?? color) }
            if let asset { Image(asset).resizable().frame(width: iconSize, height: iconSize).foregroundStyle(iconColor ?? color) }
            title.font(.system(size: size, weight: weight)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, padding).frame(width: width, height: height)
        .background(fill, in: Capsule())
        .overlay { if stroke > 0 { Capsule().strokeBorder(NativeDesktopTheme.border, lineWidth: stroke) } }
        .contentShape(Capsule())
    }
}

/// "Reading" before the answer starts: three dots in a pill (Figma 189:8131).
struct NativeAssistantDots: View {
    private static let levels = [1, 0.6, 0.3]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(NativeDesktopTheme.secondary).frame(width: 7, height: 7)
                    .phaseAnimator([0, 1, 2]) { dot, phase in dot.opacity(Self.levels[(index - phase + 3) % 3]) } animation: { _ in .easeInOut(duration: 0.45) }
            }
        }
        .padding(.horizontal, 12).frame(height: 27)
        .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }
}

/// The empty state's mark: a half-clear glass tile with a small hard shadow.
struct NativeAssistantTile: View {
    let look: NativeAssistantLook
    @Environment(\.colorScheme) private var scheme
    private static let fill = NativeDesktopTheme.adaptive(0xffffff, 0x3a3a3e).opacity(0.5)
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous), offset = look.tile / 24
        glass(Image(systemName: "sparkles").font(.system(size: look.tileIcon)).foregroundStyle(NativeDesktopTheme.text)
            .frame(width: look.tile, height: look.tile).background(Self.fill, in: shape), shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: offset / 2, x: offset, y: offset)
            .accessibilityHidden(true)
    }
    @ViewBuilder private func glass(_ view: some View, _ shape: RoundedRectangle) -> some View {
        if #available(iOS 26, *) { view.glassEffect(.regular, in: shape) } else { view }
    }
}

/// The user's bubble: three round corners and a 6 pt one toward the sender.
struct NativeAssistantBubble: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 6, topTrailingRadius: radius).path(in: rect)
    }
}
