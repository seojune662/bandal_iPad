import Foundation
import CoreGraphics
import UIKit

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

/// The paper card inside a pane's content area: in from the sides and bottom by `inset`, with `radius` corners.
/// The strip of glass that leaves between a side panel and the card is where a panel's resize handle may reach.
enum NativeDockCard {
    static let inset: CGFloat = 6, radius: CGFloat = 12
}

/// How far a pane at the window's top keeps its tab strip below the top edge.
///
/// A window that is not full screen keeps the strip 16 pt down, clear of the window's own controls.
///
/// Full screen on iPadOS 26 the top 32 pt (`systemDragBand`) belong to the system: a drag that starts there
/// moves the window, whatever it starts on and whichever way it goes, and the app has no say in it (measured on
/// 26.5; deferring system gestures on that edge and a recognizer of ours set to win over the window's changed
/// nothing). So that band holds what the system puts there anyway, the status bar with its clock and battery,
/// as in other tabbed iPad apps, and everything of ours starts under it: the strip 24 pt down, which puts the
/// whole tab pill (10 pt inside its row) below the band, and the rail and side panels by the same 24 pt.
/// Before iPadOS 26 nothing claims that edge: the status bar stays hidden and the strip is flush (Figma 129:1596).
struct NativeDockTopEdge: Equatable {
    let clearance: CGFloat
    /// Full screen before iPadOS 26: the strip starts at the top edge.
    static let flush = NativeDockTopEdge(clearance: 0)
    /// A window that is not full screen.
    static let window = NativeDockTopEdge(clearance: 16)
    /// Full screen on iPadOS 26: under the status bar.
    static let statusBar = NativeDockTopEdge(clearance: 24)
    /// The depth of the band iPadOS 26 drags a full-screen window by.
    static let systemDragBand: CGFloat = 32
}

enum NativeDockHeaderMetrics {
    /// Read while laying out: entering or leaving full screen resizes the window, which lays the dock out again.
    @MainActor static var windowed: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard let scene = scene as? UIWindowScene, scene.activationState == .foregroundActive else { return false }
            let window = scene.coordinateSpace.bounds.size, screen = scene.screen.bounds.size
            return abs(window.width - screen.width) > 1 || abs(window.height - screen.height) > 1
        }
    }
    /// From iPadOS 26 the status bar shows (in full screen; a window that is not has none to show).
    nonisolated static var showsStatusBar: Bool { if #available(iOS 26, *) { true } else { false } }
    /// What the rail and the side panels leave free at their top for the status bar.
    @MainActor static var statusBand: CGFloat { topEdge == .statusBar ? NativeDockTopEdge.statusBar.clearance : 0 }
    /// The top edge the window has now.
    @MainActor static var topEdge: NativeDockTopEdge {
        if windowed { return .window }
        return showsStatusBar ? .statusBar : .flush
    }
    static func topPadding(for paneFrame: CGRect, topEdge: NativeDockTopEdge) -> CGFloat {
        abs(paneFrame.minY) < 0.5 ? topEdge.clearance : 0
    }
    static func height(for paneFrame: CGRect, controlsHeight: CGFloat = NativeDockStripMetrics.single.total, topEdge: NativeDockTopEdge) -> CGFloat {
        controlsHeight + topPadding(for: paneFrame, topEdge: topEdge)
    }
    static func contentFrame(for paneFrame: CGRect, controlsHeight: CGFloat = NativeDockStripMetrics.single.total, topEdge: NativeDockTopEdge) -> CGRect {
        let header = height(for: paneFrame, controlsHeight: controlsHeight, topEdge: topEdge)
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
