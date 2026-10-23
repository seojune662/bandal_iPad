import SwiftUI

/// Desktop rail dimensions with a 44-point iPad touch target around the visible seam.
struct NativeDockRailResizer: View {
    let side: NativeDockRailSide
    @Binding var width: Double
    let maximum: Double
    var resetWidth: Double? = nil
    @State private var initial: Double?
    private var title: String { side == .left ? "과목 사이드바 폭 조절" : "자료 사이드바 폭 조절" }
    var body: some View {
        Color.clear
            .overlay { Capsule().fill(NativeDesktopTheme.muted.opacity(initial == nil ? 0.3 : 0.8)).frame(width: 3, height: 32) }
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
