import XCTest
import UIKit
@testable import Bandal

final class NativeDockTabSizingTests: XCTestCase {
    func testOnlyWindowTopHeadersOfAWindowedSceneMoveControlsBelowSystemDragRegion() {
        let upper = CGRect(x: 0, y: 0, width: 500, height: 400)
        let lower = CGRect(x: 0, y: 408, width: 500, height: 400)
        let belowSelector = CGRect(x: 0, y: 44, width: 500, height: 700)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper, windowed: true), 68)
        XCTAssertEqual(NativeDockHeaderMetrics.topPadding(for: upper, windowed: true), 16)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper, windowed: false), 52, "Full screen, the strip starts at the top as in Figma")
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower, windowed: true), 52)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: belowSelector, windowed: true), 52)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower, controlsHeight: NativeDockStripMetrics.stacked.total, windowed: true), 49)
        for windowed in [true, false] {
            for pane in [upper, lower, belowSelector] {
                let content = NativeDockHeaderMetrics.contentFrame(for: pane, windowed: windowed)
                XCTAssertEqual(content.minY, pane.minY + NativeDockHeaderMetrics.height(for: pane, windowed: windowed))
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
        let roomy = NativeDockTabSizing(availableWidth: 600, naturalWidths: [169, 89, 30, 400], activeIndex: 0, spacing: 6)
        XCTAssertEqual(roomy.visibleIndices, [0, 1, 2, 3]); XCTAssertEqual(roomy.density, .regular)
        XCTAssertEqual((0..<4).map(roomy.width(of:)), [169, 89, 44, 208], "A tab keeps a 44-point target and stops at the cap")
        XCTAssertEqual(roomy.totalWidth, 169 + 89 + 44 + 208 + 18)
        let tight = NativeDockTabSizing(availableWidth: 300, naturalWidths: [169, 89, 30, 400], activeIndex: 3, spacing: 6)
        XCTAssertEqual(tight, NativeDockTabSizing(availableWidth: 300, count: 4, activeIndex: 3, spacing: 6))
        XCTAssertEqual(tight.width(of: 2), tight.width); XCTAssertLessThanOrEqual(tight.totalWidth, 300)
        XCTAssertTrue(NativeDockTabSizing(availableWidth: 300, naturalWidths: [], activeIndex: -1).visibleIndices.isEmpty)
    }
    @MainActor func testSelectedTabReservesItsCloseInsideThePill() {
        let plain = NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .single, fontScale: 1, selected: false)
        let selected = NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .single, fontScale: 1, selected: true)
        XCTAssertEqual(plain, 89, accuracy: 4, "Figma 155:7546 is 89 wide")
        XCTAssertGreaterThanOrEqual(selected - plain, 6 + 11)
        XCTAssertLessThan(NativeDockTabButton.naturalWidth(title: "학교 홈", symbol: "globe", metrics: .stacked, fontScale: 1, selected: false), plain)
    }

    func testEqualTabsShrinkBeforeOverflowAndNeverNeedHorizontalScrolling() {
        let one = NativeDockTabSizing(availableWidth: 500, count: 1, activeIndex: 0)
        let three = NativeDockTabSizing(availableWidth: 500, count: 3, activeIndex: 2)
        let eight = NativeDockTabSizing(availableWidth: 500, count: 8, activeIndex: 7)
        XCTAssertEqual(one.width, 208)
        XCTAssertLessThan(three.width, one.width)
        XCTAssertLessThan(eight.width, three.width)
        XCTAssertEqual(eight.visibleIndices, Array(0..<8))
        for available in stride(from: 44, through: 1200, by: 7) {
            for count in 1...80 {
                let value = NativeDockTabSizing(availableWidth: CGFloat(available), count: count, activeIndex: count - 1, spacing: 4)
                XCTAssertLessThanOrEqual(value.totalWidth, CGFloat(available) + 0.001)
                XCTAssertGreaterThanOrEqual(value.width, 44)
                XCTAssertLessThanOrEqual(value.width, 208)
                XCTAssertTrue(value.visibleIndices.contains(count - 1), "The selected tab must remain on screen")
                XCTAssertEqual(Set(value.visibleIndices).count, value.visibleIndices.count)
            }
        }
    }
    func testCompactAndIconWidthsReserveUsableWholeTargets() {
        XCTAssertEqual(NativeDockTabSizing(availableWidth: 312, count: 3, activeIndex: 0).density, .regular)
        let compact = NativeDockTabSizing(availableWidth: 168, count: 3, activeIndex: 0)
        XCTAssertEqual(compact.density, .compact); XCTAssertFalse(compact.showsClose)
        let icon = NativeDockTabSizing(availableWidth: 132, count: 9, activeIndex: 8)
        XCTAssertEqual(icon.density, .icon); XCTAssertEqual(icon.visibleIndices, [0, 1, 8])
        XCTAssertFalse(icon.showsClose)
        for invalid: CGFloat in [0, 43, .infinity, .nan] {
            XCTAssertTrue(NativeDockTabSizing(availableWidth: invalid, count: 5, activeIndex: 4).visibleIndices.isEmpty)
        }
    }
    @MainActor func testLongBrowserTitleFitsAssignedButtonAndKeepsFullAccessibleName() {
        let title = String(repeating: "긴 브라우저 제목 – Very long website title ", count: 20)
        let button = NativeDockTabButton(frame: CGRect(x: 0, y: 0, width: 72, height: 44))
        button.configure(title: title, symbol: "globe", density: .compact, fontScale: 1.5, selected: true)
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
