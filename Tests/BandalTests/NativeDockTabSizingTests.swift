import XCTest
import UIKit
@testable import Bandal

final class NativeDockTabSizingTests: XCTestCase {
    /// A side panel's resize handle takes touches over the panel's edge and the glass between the panel and the
    /// document's card, never over the card: a stroke or a pinch that begins at the page's edge belongs to the page.
    func testRailResizeHandlesStopShortOfTheDocumentCard() {
        let window: CGFloat = 1376, left: CGFloat = 240, right: CGFloat = 361
        // Left panel: its seam is the 1 pt divider at 48 + width; the centre pane starts right after it.
        let leftSeam = 48 + left + 0.5, paneStart = 48 + left + 1
        let leftHandle = NativeDockRailResizer.center(seam: leftSeam, side: .left)
        XCTAssertLessThanOrEqual(leftHandle + NativeDockRailResizer.hitWidth / 2, paneStart + NativeDockCard.inset)
        XCTAssertLessThan(leftHandle - NativeDockRailResizer.hitWidth / 2, leftSeam, "It still covers the seam and the panel's edge")
        // Right panel, mirrored.
        let rightSeam = window - right - 0.5, paneEnd = window - right - 1
        let rightHandle = NativeDockRailResizer.center(seam: rightSeam, side: .right)
        XCTAssertGreaterThanOrEqual(rightHandle - NativeDockRailResizer.hitWidth / 2, paneEnd - NativeDockCard.inset)
        XCTAssertGreaterThan(rightHandle + NativeDockRailResizer.hitWidth / 2, rightSeam)
        XCTAssertGreaterThanOrEqual(NativeDockRailResizer.hitWidth, 24, "Wide enough to grab along the whole edge")
    }
    func testOnlyWindowTopHeadersOfAWindowedSceneMoveControlsBelowSystemDragRegion() {
        let upper = CGRect(x: 0, y: 0, width: 500, height: 400)
        let lower = CGRect(x: 0, y: 408, width: 500, height: 400)
        let belowSelector = CGRect(x: 0, y: 44, width: 500, height: 700)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper, topEdge: .window), 68)
        XCTAssertEqual(NativeDockHeaderMetrics.topPadding(for: upper, topEdge: .window), 16)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper, topEdge: .flush), 52, "Full screen, the strip starts at the top as in Figma")
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower, topEdge: .window), 52)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: belowSelector, topEdge: .window), 52)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower, controlsHeight: NativeDockStripMetrics.stacked.total, topEdge: .window), 49)
        // Full screen on iPadOS 26: the strip starts under the status bar, and the whole tab pill under the band
        // the system drags the window by.
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper, topEdge: .statusBar), 76)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower, topEdge: .statusBar), 52)
        let strip = NativeDockStripMetrics.single
        XCTAssertGreaterThanOrEqual(NativeDockTopEdge.statusBar.clearance + (strip.height - strip.pillHeight) / 2, NativeDockTopEdge.systemDragBand,
                                    "The tab pill starts below the top 32 pt, where a drag would move the window instead of the tab")
        for windowed in [NativeDockTopEdge.window, .flush, .statusBar] {
            for pane in [upper, lower, belowSelector] {
                let content = NativeDockHeaderMetrics.contentFrame(for: pane, topEdge: windowed)
                XCTAssertEqual(content.minY, pane.minY + NativeDockHeaderMetrics.height(for: pane, topEdge: windowed))
                XCTAssertEqual(content.maxY, pane.maxY)
                XCTAssertEqual(content.width, pane.width)
            }
        }
    }

    func testStripMetricsFollowTheFigmaFramesForOnePaneColumnsAndStackedPanes() {
        let bounds = CGRect(x: 0, y: 0, width: 958, height: 1024)
        let left = CGRect(x: 0, y: 0, width: 479, height: 1024), right = CGRect(x: 480, y: 0, width: 478, height: 1024)
        let top = CGRect(x: 0, y: 0, width: 958, height: 511), bottom = CGRect(x: 0, y: 512, width: 958, height: 512)
        XCTAssertEqual(NativeDockStripMetrics.resolve(paneFrames: [bounds], bounds: bounds), .single)
        XCTAssertEqual(NativeDockStripMetrics.resolve(paneFrames: [left, right], bounds: bounds), .columns)
        XCTAssertEqual(NativeDockStripMetrics.resolve(paneFrames: [top, bottom], bounds: bounds), .stacked)
        XCTAssertEqual(NativeDockStripMetrics.resolve(paneFrames: [left, CGRect(x: 480, y: 0, width: 478, height: 511), CGRect(x: 480, y: 512, width: 478, height: 512)], bounds: bounds), .stacked)
        XCTAssertEqual([NativeDockStripMetrics.single, .columns, .stacked].map(\.total), [52, 53, 49])
        XCTAssertEqual([NativeDockStripMetrics.single, .columns, .stacked].map(\.pillHeight), [31, 31, 28])
    }
    func testTabsHugTheirTitlesWhileTheyFitThenShareOneWidth() {
        let roomy = NativeDockTabSizing(availableWidth: 640, naturalWidths: [169, 89, 30, 400], activeIndex: 0, spacing: 6)
        XCTAssertEqual(roomy.indices, 0..<4); XCTAssertEqual(roomy.density, .regular); XCTAssertFalse(roomy.scrolls)
        XCTAssertEqual((0..<4).map(roomy.width(of:)), [169, 89, 76, 208], "A tab keeps room for its icon and ✕ and stops at the cap")
        XCTAssertEqual(roomy.totalWidth, 169 + 89 + 76 + 208 + 18)
        XCTAssertEqual(roomy.offset(of: 0), 0); XCTAssertEqual(roomy.offset(of: 2), 169 + 6 + 89 + 6)
        let tight = NativeDockTabSizing(availableWidth: 400, naturalWidths: [169, 89, 30, 400], activeIndex: 3, spacing: 6)
        XCTAssertEqual(tight, NativeDockTabSizing(availableWidth: 400, count: 4, activeIndex: 3, spacing: 6))
        XCTAssertEqual(tight.width(of: 2), tight.width); XCTAssertLessThanOrEqual(tight.totalWidth, 400)
        XCTAssertEqual(tight.offset(of: 3), (tight.width + 6) * 3)
        XCTAssertTrue(NativeDockTabSizing(availableWidth: 300, naturalWidths: [], activeIndex: -1).indices.isEmpty)
    }
    @MainActor func testEveryTabReservesItsCloseTarget() {
        let plain = NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .single, fontScale: 1, selected: false)
        let selected = NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .single, fontScale: 1, selected: true)
        // Figma 155:7546 is 89 wide with no ×; every tab now ends in a 44-point ×.
        XCTAssertEqual(plain - NativeDockTabSizing.closeTarget, 89 - 12, accuracy: 4)
        XCTAssertEqual(selected, plain, accuracy: 6, "The chosen tab, semibold, keeps about the same width")
        XCTAssertEqual(NativeDockTabSizing.closeTarget, 44)
        // A web tab is measured with room for its page's 16-point icon, so its title is not cut when the icon arrives.
        XCTAssertGreaterThan(NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .single, fontScale: 1, selected: false, pageIcon: true), plain)
        XCTAssertLessThan(NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .stacked, fontScale: 1, selected: false), plain)
    }

    /// The owner's rule: a tab is never narrower than its icon and its ✕, no tab is hidden, and past that the strip scrolls.
    func testTabsNeverHideAndScrollOnceTheyReachIconAndClose() {
        let one = NativeDockTabSizing(availableWidth: 500, count: 1, activeIndex: 0)
        let three = NativeDockTabSizing(availableWidth: 500, count: 3, activeIndex: 2)
        let six = NativeDockTabSizing(availableWidth: 500, count: 6, activeIndex: 5)
        XCTAssertEqual(one.width, 208)
        XCTAssertLessThan(three.width, one.width)
        XCTAssertEqual(six.width, NativeDockTabSizing.minimum, accuracy: 10)
        XCTAssertFalse(six.scrolls)
        let twenty = NativeDockTabSizing(availableWidth: 500, count: 20, activeIndex: 19, spacing: 6)
        XCTAssertEqual(twenty.width, NativeDockTabSizing.minimum)
        XCTAssertEqual(twenty.indices, 0..<20, "No tab is left out")
        XCTAssertTrue(twenty.scrolls); XCTAssertEqual(twenty.viewport, 500)
        XCTAssertEqual(twenty.totalWidth, 20 * 76 + 19 * 6)
        XCTAssertEqual(twenty.density, .icon)
        for available in stride(from: 0, through: 1200, by: 7) {
            for count in 1...80 {
                let value = NativeDockTabSizing(availableWidth: CGFloat(available), count: count, activeIndex: count - 1, spacing: 4)
                XCTAssertEqual(value.indices.count, count)
                XCTAssertGreaterThanOrEqual(value.width, NativeDockTabSizing.minimum)
                XCTAssertLessThanOrEqual(value.width, NativeDockTabSizing.maximum)
                XCTAssertLessThanOrEqual(value.viewport, CGFloat(available) + 0.001)
                XCTAssertEqual(value.scrolls, value.totalWidth > CGFloat(available) + 0.5)
                XCTAssertEqual(value.offset(of: count - 1) + value.width, value.totalWidth, accuracy: 0.001)
            }
        }
        for invalid: CGFloat in [0, 43, .infinity, .nan] {
            let value = NativeDockTabSizing(availableWidth: invalid, count: 5, activeIndex: 4)
            XCTAssertEqual(value.indices.count, 5); XCTAssertEqual(value.width, NativeDockTabSizing.minimum)
        }
    }
    func testTitlesShowOnlyWhileThereIsRoomForThem() {
        XCTAssertEqual(NativeDockTabSizing(availableWidth: 330, count: 3, activeIndex: 0).density, .regular)
        XCTAssertEqual(NativeDockTabSizing(availableWidth: 300, count: 3, activeIndex: 0).density, .icon, "100 wide: icon and ✕ only")
        XCTAssertEqual(NativeDockTabSizing(availableWidth: 312, count: 3, activeIndex: 0).density, .regular)
    }
    /// The chosen tab's paper follows the strip's scroll and is cut where the strip's tab area ends.
    func testChosenTabPaperFollowsTheScrollAndStopsAtTheStripEdges() {
        let viewport: ClosedRange<CGFloat> = 16...516
        XCTAssertEqual(NativeDockTabSizing.visibleSpan(x: 100, width: 76, offset: 0, viewport: viewport)?.x, 100)
        XCTAssertEqual(NativeDockTabSizing.visibleSpan(x: 100, width: 76, offset: 60, viewport: viewport)?.x, 40)
        let cut = NativeDockTabSizing.visibleSpan(x: 100, width: 76, offset: 120, viewport: viewport)
        XCTAssertEqual(cut?.x, 16); XCTAssertEqual(cut?.width, 40)
        let right = NativeDockTabSizing.visibleSpan(x: 480, width: 76, offset: 0, viewport: viewport)
        XCTAssertEqual(right?.x, 480); XCTAssertEqual(right?.width, 36)
        XCTAssertNil(NativeDockTabSizing.visibleSpan(x: 100, width: 76, offset: 170, viewport: viewport), "Scrolled out of sight: the card has no tab")
    }
    @MainActor func testLongBrowserTitleFitsAssignedButtonAndKeepsFullAccessibleName() {
        let title = String(repeating: "긴 브라우저 제목 – Very long website title ", count: 20)
        let button = NativeDockTabButton(frame: CGRect(x: 0, y: 0, width: 72, height: 44))
        button.configure(title: title, symbol: "globe", density: .regular, fontScale: 1.5, selected: true)
        button.setNeedsLayout(); button.layoutIfNeeded()
        XCTAssertEqual(button.bounds.width, 72)
        XCTAssertEqual(button.intrinsicContentSize.width, UIView.noIntrinsicMetric)
        XCTAssertTrue(button.clipsToBounds)
        XCTAssertEqual(button.titleLabel?.numberOfLines, 1)
        XCTAssertEqual(button.titleLabel?.lineBreakMode, .byTruncatingTail)
        XCTAssertLessThanOrEqual(button.titleLabel?.frame.maxX ?? 0, button.bounds.maxX + 0.5)
        XCTAssertEqual(button.accessibilityLabel, title)
        button.frame.size.width = 44
        button.configure(title: title, symbol: "globe", density: .icon, fontScale: 1.5, selected: true)
        button.setNeedsLayout(); button.layoutIfNeeded()
        XCTAssertNil(button.configuration?.title)
        XCTAssertEqual(button.accessibilityLabel, title)
        XCTAssertTrue(button.accessibilityTraits.contains(.selected))
    }
}
