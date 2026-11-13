import SwiftUI

/// A card or bar that floats over the page and lets it show through: the system's glass from iOS 26, a blur
/// material before it (iOS 18). One view for every such surface, so they all read alike.
///
/// `veil` is a thin wash laid between the glass and the content, enough for text to keep a ground over a busy page
/// without hiding it. The surface takes the touches that land on it (none reach the page underneath) and clips its
/// content to its shape, so a scrolled list never runs past the corners.
struct NativeGlassSurface<Surface: InsettableShape, Content: View>: View {
    let shape: Surface
    var veil: Color = NativeGlass.veil
    var shadow = true
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    init(in shape: Surface, veil: Color = NativeGlass.veil, shadow: Bool = true, @ViewBuilder content: () -> Content) {
        self.shape = shape; self.veil = veil; self.shadow = shadow; self.content = content()
    }

    var body: some View {
        glass(content.clipShape(shape).background(veil, in: shape))
            .contentShape(shape)
            .overlay { shape.strokeBorder(NativeGlass.rim, lineWidth: 0.5).allowsHitTesting(false) }
            .shadow(color: .black.opacity(shadow ? (scheme == .dark ? 0.45 : 0.16) : 0), radius: 18, y: 6)
    }

    @ViewBuilder private func glass(_ view: some View) -> some View {
        if #available(iOS 26, *) { view.glassEffect(.regular, in: shape) }
        else { view.background(.ultraThinMaterial, in: shape) }
    }
}

extension NativeGlass {
    /// The wash under a `NativeGlassSurface`'s content: thinner than `popup`, so the page reads through.
    static let veil = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 0.24) : UIColor(white: 1, alpha: 0.12) })
}
