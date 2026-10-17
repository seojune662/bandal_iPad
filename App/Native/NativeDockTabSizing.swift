import Foundation
import CoreGraphics

/// iPadOS reserves the window's top edge for window movement. Keep the
/// 44-point controls below it without adding a separate status/title bar.
enum NativeDockHeaderMetrics {
    static func topPadding(for paneFrame: CGRect) -> CGFloat {
        abs(paneFrame.minY) < 0.5 ? 16 : 0
    }
    static func height(for paneFrame: CGRect, controlsHeight: CGFloat = 44) -> CGFloat {
        controlsHeight + topPadding(for: paneFrame)
    }
    static func contentFrame(for paneFrame: CGRect, controlsHeight: CGFloat = 44) -> CGRect {
        let header = height(for: paneFrame, controlsHeight: controlsHeight)
        return CGRect(x: paneFrame.minX, y: paneFrame.minY + header,
                      width: paneFrame.width, height: max(0, paneFrame.height - header))
    }
}

/// Desktop adaptiveTabs.ts sizing, with a 44-point minimum touch target.
/// Title length and resource kind never participate in the width calculation.
struct NativeDockTabSizing: Equatable {
    enum Density { case regular, compact, icon }
    let width: CGFloat
    let spacing: CGFloat
    let density: Density
    let visibleIndices: [Int]
    var totalWidth: CGFloat { width * CGFloat(visibleIndices.count) + spacing * CGFloat(max(0, visibleIndices.count - 1)) }
    var showsClose: Bool { density == .regular }

    init(availableWidth: CGFloat, count: Int, activeIndex: Int, spacing: CGFloat = 0) {
        self.spacing = max(0, spacing)
        guard count > 0, availableWidth.isFinite, availableWidth >= 44 else {
            width = 0; density = .icon; visibleIndices = []; return
        }
        let capacity = min(count, max(1, Int(floor((availableWidth + self.spacing) / (44 + self.spacing)))))
        var indices = Array(0..<capacity)
        if activeIndex >= capacity, activeIndex < count { indices[capacity - 1] = activeIndex }
        visibleIndices = indices
        width = min(208, (availableWidth - self.spacing * CGFloat(capacity - 1)) / CGFloat(capacity))
        density = width >= 104 ? .regular : width >= 56 ? .compact : .icon
    }
}
