import SwiftUI

/// The handle that resizes a side panel, along the seam between the panel and the centre pane.
///
/// It takes touches over 22 pt of the panel's edge and over the strip of glass between the seam and the
/// document's card, and nowhere over the card. It used to be a 44 pt strip centred on the seam, which put
/// about 16 pt of it over the page: a stroke or a pinch that began at the page's edge resized the panel instead.
struct NativeDockRailResizer: View {
    /// How far the handle reaches over the panel, and over the centre pane (the gap before the card).
    static let panelReach: CGFloat = 22
    static var paneReach: CGFloat { NativeDockCard.inset }
    static var hitWidth: CGFloat { panelReach + paneReach }
    /// The handle's centre for a seam at `seam`: shifted off the seam toward the panel.
    static func center(seam: CGFloat, side: NativeDockRailSide) -> CGFloat {
        seam + (side == .left ? -1 : 1) * (panelReach - paneReach) / 2
    }
    let side: NativeDockRailSide
    @Binding var width: Double
    let maximum: Double
    var resetWidth: Double? = nil
    @State private var initial: Double?
    private var title: String { side == .left ? "폴더 사이드바 폭 조절" : "자료 사이드바 폭 조절" }
    var body: some View {
        Color.clear
            // The grip shows on the seam itself, which is off this strip's centre.
            .overlay {
                Capsule().fill(NativeDesktopTheme.muted.opacity(initial == nil ? 0 : 0.8)).frame(width: 3, height: 32)
                    .offset(x: (side == .left ? 1 : -1) * (Self.panelReach - Self.paneReach) / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { value in
                if initial == nil { initial = width }
                adjust((initial ?? width) + Double(value.translation.width) * (side == .left ? 1 : -1))
            }.onEnded { _ in initial = nil })
            .onTapGesture(count: 2) { adjust(resetWidth ?? side.defaultWidth) }
            .onDisappear { initial = nil }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(width))포인트")
            .accessibilityIdentifier(side == .left ? "native-course-rail-resizer" : "native-materials-rail-resizer")
            .accessibilityAdjustableAction { direction in adjust(width + (direction == .increment ? 16 : -16)) }
            .accessibilityAction(named: "기본 폭으로") { adjust(resetWidth ?? side.defaultWidth) }
    }
    private func adjust(_ value: Double) { width = side.clamp(min(maximum, value)) }
}
