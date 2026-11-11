import Foundation
import CoreGraphics

/// Figma tab strip values: one pane (155:7541, 269:8463), left/right split
/// (130:5986) and the smaller strip of top/bottom and four panes (130:6064).
struct NativeDockStripMetrics: Equatable {
    /// `height` is the row the pill is centred in, without the line under it.
    let height, padding, gap, radius, tabPadding, pillHeight, icon, title, close, plus, paneClose, paneCloseInset: CGFloat
    static let single = NativeDockStripMetrics(height: 51, padding: 16, gap: 6, radius: 9, tabPadding: 12, pillHeight: 31, icon: 13, title: 14, close: 11, plus: 16, paneClose: 13, paneCloseInset: 14)
    static let columns = NativeDockStripMetrics(height: 52, padding: 12, gap: 6, radius: 8, tabPadding: 10, pillHeight: 31, icon: 13, title: 14, close: 11, plus: 15, paneClose: 13, paneCloseInset: 14)
    static let stacked = NativeDockStripMetrics(height: 48, padding: 10, gap: 4, radius: 8, tabPadding: 9, pillHeight: 28, icon: 12, title: 13, close: 10, plus: 14, paneClose: 12, paneCloseInset: 13)
    /// One pane, panes side by side at full height, or anything stacked.
    static func resolve(paneFrames: [CGRect], bounds: CGRect) -> NativeDockStripMetrics {
        paneFrames.count <= 1 ? .single : paneFrames.allSatisfy { $0.height >= bounds.height - 1 } ? .columns : .stacked
    }
    /// The strip and the 1-point line under it: 52 for one pane (the line is inside the Figma frame), 53 and 49 in a split.
    var total: CGFloat { height + 1 }
    /// The × of the selected tab: its glyph, the 6-point gap before it and the pill's trailing padding.
    var closeZone: CGFloat { 6 + close + 1 + tabPadding }
}

/// iPadOS reserves the window's top edge for window movement. A pane at the
/// window top keeps its strip below it; the strip itself is the Figma height.
enum NativeDockHeaderMetrics {
    static func topPadding(for paneFrame: CGRect) -> CGFloat {
        abs(paneFrame.minY) < 0.5 ? 16 : 0
    }
    static func height(for paneFrame: CGRect, controlsHeight: CGFloat = NativeDockStripMetrics.single.total) -> CGFloat {
        controlsHeight + topPadding(for: paneFrame)
    }
    static func contentFrame(for paneFrame: CGRect, controlsHeight: CGFloat = NativeDockStripMetrics.single.total) -> CGRect {
        let header = height(for: paneFrame, controlsHeight: controlsHeight)
        return CGRect(x: paneFrame.minX, y: paneFrame.minY + header,
                      width: paneFrame.width, height: max(0, paneFrame.height - header))
    }
}

/// Tabs hug their titles as in Figma while they fit. When they do not, desktop
/// adaptiveTabs.ts sizing takes over: equal widths with a 44-point minimum,
/// where title length and resource kind no longer participate.
struct NativeDockTabSizing: Equatable {
    enum Density { case regular, compact, icon }
    let width: CGFloat
    let spacing: CGFloat
    let density: Density
    let visibleIndices: [Int]
    /// Per-tab widths while every tab fits at its own size; nil once tabs share one width.
    let natural: [CGFloat]?
    var totalWidth: CGFloat { (natural?.reduce(0, +) ?? width * CGFloat(visibleIndices.count)) + spacing * CGFloat(max(0, visibleIndices.count - 1)) }
    var showsClose: Bool { density == .regular }
    func width(of index: Int) -> CGFloat { natural?[index] ?? width }

    init(availableWidth: CGFloat, naturalWidths: [CGFloat], activeIndex: Int, spacing: CGFloat = 0) {
        let capped = naturalWidths.map { min(Self.maximum, max(44, $0)) }, gaps = max(0, spacing) * CGFloat(max(0, capped.count - 1))
        guard !capped.isEmpty, availableWidth.isFinite, capped.reduce(0, +) + gaps <= availableWidth else {
            self.init(availableWidth: availableWidth, count: naturalWidths.count, activeIndex: activeIndex, spacing: spacing); return
        }
        self.init(width: capped.max() ?? 0, spacing: max(0, spacing), density: .regular, visibleIndices: Array(capped.indices), natural: capped)
    }
    private init(width: CGFloat, spacing: CGFloat, density: Density, visibleIndices: [Int], natural: [CGFloat]?) {
        self.width = width; self.spacing = spacing; self.density = density; self.visibleIndices = visibleIndices; self.natural = natural
    }
    static let maximum: CGFloat = 208

    init(availableWidth: CGFloat, count: Int, activeIndex: Int, spacing: CGFloat = 0) {
        self.spacing = max(0, spacing); natural = nil
        guard count > 0, availableWidth.isFinite, availableWidth >= 44 else {
            width = 0; density = .icon; visibleIndices = []; return
        }
        let capacity = min(count, max(1, Int(floor((availableWidth + self.spacing) / (44 + self.spacing)))))
        var indices = Array(0..<capacity)
        if activeIndex >= capacity, activeIndex < count { indices[capacity - 1] = activeIndex }
        visibleIndices = indices
        width = min(Self.maximum, (availableWidth - self.spacing * CGFloat(capacity - 1)) / CGFloat(capacity))
        density = width >= 104 ? .regular : width >= 56 ? .compact : .icon
    }
}
