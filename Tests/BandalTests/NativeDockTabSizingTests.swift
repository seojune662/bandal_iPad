import XCTest
import UIKit
@testable import Bandal

final class NativeDockTabSizingTests: XCTestCase {
    func testOnlyWindowTopHeadersMoveControlsBelowSystemDragRegion() {
        let upper = CGRect(x: 0, y: 0, width: 500, height: 400)
        let lower = CGRect(x: 0, y: 408, width: 500, height: 400)
        let belowSelector = CGRect(x: 0, y: 44, width: 500, height: 700)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: upper), 60)
        XCTAssertEqual(NativeDockHeaderMetrics.topPadding(for: upper) + 22, 38)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: lower), 44)
        XCTAssertEqual(NativeDockHeaderMetrics.height(for: belowSelector), 44)
        for pane in [upper, lower, belowSelector] {
            let content = NativeDockHeaderMetrics.contentFrame(for: pane)
            XCTAssertEqual(content.minY, pane.minY + NativeDockHeaderMetrics.height(for: pane))
            XCTAssertEqual(content.maxY, pane.maxY)
            XCTAssertEqual(content.width, pane.width)
        }
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
