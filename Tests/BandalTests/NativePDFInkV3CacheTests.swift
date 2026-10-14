import XCTest
@testable import Bandal

final class NativePDFInkV3CacheTests: XCTestCase {
    private func samples(_ count: Int) -> [NativePDFPoint] {
        (0..<count).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.0003, y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.15 + sin(step * 0.19) * 0.05, t: step * 1000 / 240)
        }
    }
    private func compare(_ cache: NativePDFInkGeometryV3Cache, _ points: [NativePDFPoint], width: Double = 0.004, aspect: Double = 842.0 / 595, highlighter: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let actual = cache.polygons(points: points, width: width, aspect: aspect, highlighter: highlighter)
        let expected = NativePDFInkGeometryV3.polygons(points: points, width: width, aspect: aspect, highlighter: highlighter)
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(cache.retainedPointCount, points.count, file: file, line: line)
        XCTAssertEqual(cache.retainedPolygonCount, expected.count, file: file, line: line)
    }
    func testAppendPredictionReplacementAndEarlyPressureCorrectionMatchPureGeometryExactly() {
        let cache = NativePDFInkGeometryV3Cache(), measured = samples(100)
        compare(cache, Array(measured.prefix(40)))
        compare(cache, Array(measured.prefix(44)))
        XCTAssertEqual(cache.recomputedPointCount, 4)
        var predicted = Array(measured.prefix(48))
        for index in 44..<48 { predicted[index].y += 0.01; predicted[index].p = measured[43].p }
        compare(cache, predicted)
        compare(cache, Array(measured.prefix(48)))
        XCTAssertEqual(cache.recomputedPointCount, 4)
        var corrected = Array(measured.prefix(48)); corrected[5].p = 0.8; corrected[5].t = 18
        compare(cache, corrected)
        XCTAssertEqual(cache.recomputedPointCount, 43, "An early pressure correction invalidates every later EMA state")
        compare(cache, corrected)
        XCTAssertEqual(cache.recomputedPointCount, 0, "Recoloring does not change geometry or invalidate the measured prefix")
    }
    func testTruncationResetAndNewStrokeWithIdenticalPrefixCannotReuseOldTail() {
        let cache = NativePDFInkGeometryV3Cache(), long = samples(2400)
        compare(cache, long)
        let returned = cache.polygons(points: long, width: 0.004, aspect: 842.0 / 595, highlighter: false)
        var short = Array(long.prefix(4))
        compare(cache, short)
        XCTAssertEqual(cache.recomputedPointCount, 0)
        short.append(.init(x: 0.2, y: 0.8, p: 0.8, t: 24))
        compare(cache, short)
        XCTAssertEqual(cache.recomputedPointCount, 1)
        XCTAssertEqual(returned, NativePDFInkGeometryV3.polygons(points: long, width: 0.004, aspect: 842.0 / 595, highlighter: false), "Previously returned polygons remain immutable")
        cache.reset()
        XCTAssertEqual(cache.retainedPointCount, 0); XCTAssertEqual(cache.retainedPolygonCount, 0)
        compare(cache, short)
        XCTAssertEqual(cache.recomputedPointCount, short.count)
        compare(cache, [])
        XCTAssertEqual(cache.retainedPolygonCount, 0)
    }
    func testGeometryConfigurationChangesInvalidateAllPointsAndInvalidInputClearsState() {
        let cache = NativePDFInkGeometryV3Cache(), points = samples(20)
        compare(cache, points)
        for (width, aspect, highlighter) in [(0.01, 1.5, false), (0.01, 0.7, false), (0.01, 0.7, true), (0.004, 1.5, false)] {
            compare(cache, points, width: width, aspect: aspect, highlighter: highlighter)
            XCTAssertEqual(cache.recomputedPointCount, points.count)
        }
        var invalid = points; invalid[3].p = .nan
        XCTAssertTrue(cache.polygons(points: invalid, width: 0.004, aspect: 1.5, highlighter: false).isEmpty)
        XCTAssertEqual(cache.retainedPointCount, 0); XCTAssertEqual(cache.retainedPolygonCount, 0)
        compare(cache, points)
        XCTAssertEqual(cache.recomputedPointCount, points.count)
    }
    func testDeterministicMixedAppendReplaceTruncateTimingAndContainedDisks() {
        let cache = NativePDFInkGeometryV3Cache()
        var state: UInt64 = 0x3249abcd
        func random(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        var points: [NativePDFPoint] = []
        for step in 0..<160 {
            switch random(4) {
            case 0 where points.count > 1: points = Array(points.prefix(random(points.count)))
            case 1 where !points.isEmpty:
                let index = random(points.count)
                points[index].p = Double(random(100)) / 100
                points[index].t = step.isMultiple(of: 2) ? nil : Double(random(600))
            default:
                let previous = points.last
                points.append(.init(x: step.isMultiple(of: 3) ? previous?.x ?? 0.3 : Double(random(100)) / 100,
                                    y: step.isMultiple(of: 3) ? previous?.y ?? 0.4 : Double(random(100)) / 100,
                                    p: Double(random(100)) / 100, t: Double(step * 4)))
            }
            compare(cache, points, width: step.isMultiple(of: 7) ? 0.1 : 0.004, aspect: step.isMultiple(of: 11) ? 2 : 1.5, highlighter: step.isMultiple(of: 13))
        }
    }
    func testTenSecond240HzLastFourSamplesReportIncrementalCost() {
        let points = samples(2400), prefix = Array(points.dropLast(4)), cache = NativePDFInkGeometryV3Cache()
        _ = cache.polygons(points: prefix, width: 0.004, aspect: 842.0 / 595, highlighter: false)
        let started = Date.timeIntervalSinceReferenceDate
        let actual = cache.polygons(points: points, width: 0.004, aspect: 842.0 / 595, highlighter: false)
        let incrementalMS = (Date.timeIntervalSinceReferenceDate - started) * 1000
        let fullStarted = Date.timeIntervalSinceReferenceDate
        let full = NativePDFInkGeometryV3.polygons(points: points, width: 0.004, aspect: 842.0 / 595, highlighter: false)
        let fullMS = (Date.timeIntervalSinceReferenceDate - fullStarted) * 1000
        XCTAssertEqual(actual, full); XCTAssertEqual(cache.recomputedPointCount, 4)
        XCTAssertEqual(actual.count, 4799)
        print("Native ink v3 cache: 2400-point/10-second stroke, last4+EMA anchor incremental \(incrementalMS) ms vs full \(fullMS) ms; geometry only, no timing pass/fail threshold")
    }
}
