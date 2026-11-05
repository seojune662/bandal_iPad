import XCTest
import CoreGraphics
@testable import Bandal

final class NativePDFEraseSplitTests: XCTestCase {
    private func line(from start: CGPoint, to end: CGPoint, count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            return ["x": Double(start.x + (end.x - start.x) * t), "y": Double(start.y + (end.y - start.y) * t), "p": 0.5, "t": Double(index * 10)]
        }
    }

    func testErasingTheMiddleLeavesTwoPiecesThatKeepTheirOriginalSamples() throws {
        let stroke = line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), count: 81)
        let pieces = try XCTUnwrap(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.5, y: 0.55)], reach: 0.02, aspect: 1))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].first?["x"] as? Double, 0.1)
        XCTAssertEqual(pieces[1].last?["x"] as? Double, 0.9)
        XCTAssertLessThan(try XCTUnwrap(pieces[0].last?["x"] as? Double), 0.4801)
        XCTAssertGreaterThan(try XCTUnwrap(pieces[1].first?["x"] as? Double), 0.5199)
        // Far from the eraser the stored samples are untouched: only the
        // segments next to the cut gain interpolated samples.
        XCTAssertTrue((38...40).contains(pieces[0].count), "\(pieces[0].count)")
        XCTAssertEqual(pieces[0][5]["t"] as? Double, 50)
        XCTAssertEqual(pieces[0][5]["x"] as? Double, stroke[5]["x"] as? Double)
    }

    func testErasingAnEndLeavesOnePieceAndErasingEverythingLeavesNone() throws {
        let stroke = line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.3, y: 0.5), count: 21)
        let end = try XCTUnwrap(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.3, y: 0.5)], reach: 0.03, aspect: 1))
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].first?["x"] as? Double, 0.1)
        let all = try XCTUnwrap(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.3, y: 0.5)], reach: 0.03, aspect: 1))
        XCTAssertTrue(all.isEmpty)
    }

    func testAMissReturnsNilSoTheStrokeIsNotRewritten() {
        let stroke = line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), count: 9)
        XCTAssertNil(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.5, y: 0.8)], reach: 0.02, aspect: 1))
    }

    func testATwoPointLineIsResampledNearTheEraserAndSplitInTwo() throws {
        // A snapped straight line has only its two end samples.
        let stroke = line(from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 0.9, y: 0.2), count: 2)
        let pieces = try XCTUnwrap(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.5, y: 0.2)], reach: 0.01, aspect: 1))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].first?["x"] as? Double, 0.1)
        XCTAssertEqual(pieces[1].last?["x"] as? Double, 0.9)
        let pressure = try XCTUnwrap(pieces[0].last?["p"] as? Double)
        XCTAssertEqual(pressure, 0.5, accuracy: 0.0001)
    }

    func testDistancesUseThePageAspect() {
        // 0.02 below in normalized y is 0.04 page widths on a 1:2 page: outside a 0.03 reach.
        let stroke = line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), count: 81)
        XCTAssertNil(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.5, y: 0.52)], reach: 0.03, aspect: 2))
        XCTAssertNotNil(NativePDFEraseSplit.cut(stroke, path: [CGPoint(x: 0.5, y: 0.52)], reach: 0.03, aspect: 1))
    }

    func testWholeEraserTouchesStrokesWithinRadiusAndBoxesItEntersOnly() {
        let ink: [String: Any] = ["kind": "ink", "data": ["points": line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), count: 2)], "style": ["width": 0.004]]
        XCTAssertTrue(NativePDFEraseSplit.touches(ink, path: [CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.5, y: 0.55)], radius: 0.005, aspect: 1))
        XCTAssertFalse(NativePDFEraseSplit.touches(ink, path: [CGPoint(x: 0.5, y: 0.6)], radius: 0.005, aspect: 1))
        let box: [String: Any] = ["kind": "textbox", "data": ["box": ["x": 0.2, "y": 0.2, "width": 0.1, "height": 0.05]], "style": [:]]
        XCTAssertTrue(NativePDFEraseSplit.touches(box, path: [CGPoint(x: 0.25, y: 0.22)], radius: 0.005, aspect: 1))
        XCTAssertFalse(NativePDFEraseSplit.touches(box, path: [CGPoint(x: 0.5, y: 0.5)], radius: 0.005, aspect: 1))
    }
}
