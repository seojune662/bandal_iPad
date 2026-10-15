import XCTest
import CoreGraphics
@testable import Bandal

final class NativePDFInkV4Tests: XCTestCase {
    private func samples(_ count: Int) -> [NativePDFPoint] {
        (0..<count).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.0003, y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.2 + sin(step * 0.19) * 0.15, t: step * 1000 / 240)
        }
    }
    private func segment(_ points: [NativePDFPoint], _ index: Int, width: Double = 0.004, aspect: Double = 1) -> [NativePDFInkGeometryV4.Sample] {
        var result: [NativePDFInkGeometryV4.Sample] = []
        NativePDFInkGeometryV4.forEachSegmentSample(points: points, pressures: NativePDFInkGeometryV3.filteredPressures(points),
            index: index, width: width, aspect: aspect) { result.append($0) }
        return result
    }

    func testDoxensCentripetalControlsRespectNonuniformSampleSpacing() {
        let controls = NativePDFInkGeometryV4.controlPoints(p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 1, y: 0),
                                                           p2: CGPoint(x: 5, y: 0), p3: CGPoint(x: 6, y: 0))
        XCTAssertEqual(controls.cp1.x, 17.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(controls.cp2.x, 37.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(controls.cp1.y, 0); XCTAssertEqual(controls.cp2.y, 0)
    }

    func testDotTwoPointLineAndStationaryPressureRenderImmediately() {
        let dot = NativePDFPoint(x: 0.2, y: 0.3, p: 0, t: 0)
        let inputs = [[dot], [dot, .init(x: 0.8, y: 0.7, p: 1, t: 32)],
                      [dot, .init(x: 0.2, y: 0.3, p: 1, t: 32), .init(x: 0.2, y: 0.3, p: 0, t: 64)]]
        for points in inputs {
            let actual = NativePDFInkGeometryV4.polygons(points: points, width: 0.02, aspect: 1.5, highlighter: false)
            XCTAssertEqual(actual, NativePDFInkGeometryV3.polygons(points: points, width: 0.02, aspect: 1.5, highlighter: false))
            XCTAssertTrue(actual.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        let stationary = NativePDFInkGeometryV4.polygons(points: inputs[2], width: 0.02, aspect: 1.5, highlighter: false)
        XCTAssertEqual(stationary.map(\.count), [32, 32, 32])
        XCTAssertGreaterThan(stationary[1][0].x, stationary[0][0].x)
    }

    func testRightAngleSmallWritingRetainsExactCornerWithoutOvershoot() {
        for scale in [1.0, 0.02] {
            let points: [NativePDFPoint] = [.init(x: 0.1, y: 0.1, p: 0.4),
                .init(x: 0.1 + scale * 0.1, y: 0.1, p: 0.4), .init(x: 0.1 + scale * 0.1, y: 0.1 + scale * 0.1, p: 0.4)]
            for point in segment(points, 0) { XCTAssertEqual(point.y, 0.1, accuracy: 1e-14) }
            for point in segment(points, 1) { XCTAssertEqual(point.x, 0.1 + scale * 0.1, accuracy: 1e-14) }
            XCTAssertEqual(segment(points, 0).last?.x, points[1].x)
            XCTAssertEqual(segment(points, 1).last?.y, points[2].y)
        }
    }

    func testCurveRefinesOnlyLastMeasuredSegmentAndIncludesNewestTip() {
        let points: [NativePDFPoint] = [.init(x: 0.1, y: 0.2, p: 0.1, t: 0),
            .init(x: 0.3, y: 0.24, p: 0.8, t: 8), .init(x: 0.5, y: 0.4, p: 0.3, t: 16),
            .init(x: 0.72, y: 0.42, p: 0.9, t: 24)]
        let first = Array(points.prefix(3))
        XCTAssertEqual(segment(first, 0), segment(points, 0), "Earlier measured controls are sealed once their next neighbor exists")
        XCTAssertNotEqual(segment(first, 1), segment(points, 1), "The former live tip segment may be refined by the new measured neighbor")
        XCTAssertEqual(segment(first, 1).last?.x, first.last?.x)
        XCTAssertEqual(segment(first, 1).last?.y, first.last?.y)
        XCTAssertEqual(segment(points, 2).last?.x, points.last?.x)
    }

    func testPressureIsFilteredAtRawRateOnceAndPredictionsCannotMoveMeasuredCurve() {
        let points: [NativePDFPoint] = [.init(x: 0.1, y: 0.2, p: 0.1, t: 0),
            .init(x: 0.3, y: 0.24, p: 1, t: 8), .init(x: 0.5, y: 0.4, p: 0, t: 16),
            .init(x: 0.72, y: 0.42, p: 0.9, t: 24)]
        let original = points, pressures = NativePDFInkGeometryV3.filteredPressures(points)
        for index in 0..<(points.count - 1) {
            let emitted = segment(points, index)
            XCTAssertEqual(emitted.last?.p, pressures[index + 1])
            let low = min(pressures[index], pressures[index + 1]), high = max(pressures[index], pressures[index + 1])
            XCTAssertTrue(emitted.allSatisfy { $0.p >= low && $0.p <= high })
            XCTAssertLessThanOrEqual(emitted.count, 1 << NativePDFInkGeometryV4.maximumSubdivisionDepth)
        }
        let measured = NativePDFInkGeometryV4.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        let predictions: [NativePDFPoint] = [.init(x: 0.8, y: 0.6, p: 1), .init(x: 0.9, y: 0.3, p: 0)]
        let predicted = NativePDFInkGeometryV4.polygons(points: points, predictions: predictions, width: 0.004, aspect: 1.5, highlighter: false)
        XCTAssertEqual(Array(predicted.prefix(measured.count)), measured)
        let lastDisk = predicted.last!, expectedRadius = 0.004 * (0.42 + 0.20 * pressures.last!) / 2
        XCTAssertEqual(lastDisk[0].x, 0.9 + expectedRadius, accuracy: 1e-14)
        XCTAssertEqual(points, original, "Rendering must not rewrite raw pressure/time/coordinates")
    }

    func testStreamingMatchesCollectedPolygonsAndAspectCorrectMetric() {
        let points = samples(80)
        var streamed: [[CGPoint]] = []
        NativePDFInkGeometryV4.forEachPolygon(points: points, width: 0.004, aspect: 1.5, highlighter: false) { streamed.append($0) }
        XCTAssertEqual(streamed, NativePDFInkGeometryV4.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false))
        let tall = points.map { point -> NativePDFPoint in var result = point; result.y /= 2; return result }
        for index in 0..<(points.count - 1) {
            let a = segment(points, index, aspect: 1), b = segment(tall, index, aspect: 2)
            XCTAssertEqual(a.count, b.count)
            for (left, right) in zip(a, b) {
                XCTAssertEqual(left.x, right.x, accuracy: 1e-13)
                XCTAssertEqual(left.y, right.y * 2, accuracy: 1e-13)
                XCTAssertEqual(left.p, right.p)
            }
        }
    }

    func testInvalidInputAndBoundedPredictions() {
        let points = samples(5)
        for width in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(NativePDFInkGeometryV4.polygons(points: points, width: width, aspect: 1, highlighter: false).isEmpty)
        }
        for aspect in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(NativePDFInkGeometryV4.polygons(points: points, width: 0.004, aspect: aspect, highlighter: false).isEmpty)
        }
        var bad = points; bad[2].x = .nan
        XCTAssertTrue(NativePDFInkGeometryV4.polygons(points: bad, width: 0.004, aspect: 1, highlighter: false).isEmpty)
        let predictions = (0..<100).map { NativePDFPoint(x: 0.5 + Double($0) * 0.001, y: 0.4, p: 1) }
        let all = NativePDFInkGeometryV4.polygons(points: points, predictions: predictions, width: 0.004, aspect: 1, highlighter: false)
        let limited = NativePDFInkGeometryV4.polygons(points: points, predictions: Array(predictions.prefix(8)), width: 0.004, aspect: 1, highlighter: false)
        XCTAssertEqual(all, limited)
        XCTAssertTrue(NativePDFInkGeometryV4.polygons(points: [], predictions: predictions, width: 0.004, aspect: 1, highlighter: false).isEmpty)
    }

    func testCacheAppendPredictionsCorrectionsTruncationAndResetEqualPureReplay() {
        let cache = NativePDFInkGeometryV4Cache(), points = samples(100)
        var previous: [[CGPoint]] = []
        func check(_ input: [NativePDFPoint], _ predicted: [NativePDFPoint] = [], width: Double = 0.004, aspect: Double = 1.5) {
            let actual = cache.polygons(points: input, predictions: predicted, width: width, aspect: aspect, highlighter: false)
            XCTAssertEqual(actual, NativePDFInkGeometryV4.polygons(points: input, predictions: predicted, width: width, aspect: aspect, highlighter: false))
            XCTAssertEqual(Array(actual.prefix(cache.retainedPrefixPolygonCount)), Array(previous.prefix(cache.retainedPrefixPolygonCount)))
            XCTAssertLessThanOrEqual(cache.retainedPrefixPolygonCount, min(actual.count, previous.count))
            previous = actual
        }
        check(Array(points.prefix(40)))
        check(Array(points.prefix(44)))
        XCTAssertEqual(cache.recomputedPointCount, 4); XCTAssertEqual(cache.recomputedSegmentCount, 5)
        check(Array(points.prefix(44)), [.init(x: 0.8, y: 0.9, p: 1)])
        XCTAssertEqual(cache.recomputedSegmentCount, 0)
        check(Array(points.prefix(44)), [.init(x: 0.9, y: 0.2, p: 0)])
        XCTAssertEqual(cache.recomputedSegmentCount, 0)
        check(Array(points.prefix(44)))
        var corrected = Array(points.prefix(44)); corrected[5].p = 0.9; corrected[5].y += 0.02
        check(corrected)
        XCTAssertEqual(cache.recomputedPointCount, 39); XCTAssertEqual(cache.recomputedSegmentCount, 40)
        check(Array(corrected.prefix(3))); check(Array(corrected.prefix(1))); check(points)
        check(points, width: 0.01); check(points, aspect: 0.75)
        cache.reset(); check([points[0]])
        var invalid = points; invalid[3].p = .infinity
        check(invalid); XCTAssertEqual(cache.retainedPointCount, 0)
        check([]); check(points)
    }

    func testCacheDeterministicMixedDegenerateAndEstimatedInputs() {
        let cache = NativePDFInkGeometryV4Cache()
        var state: UInt64 = 0x3249abcd, points: [NativePDFPoint] = []
        func random(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        var previous: [[CGPoint]] = []
        for step in 0..<150 {
            switch random(4) {
            case 0 where points.count > 1: points = Array(points.prefix(random(points.count)))
            case 1 where !points.isEmpty:
                let index = random(points.count)
                points[index].p = Double(random(100)) / 100; points[index].t = Double(random(600))
            default:
                let last = points.last
                points.append(.init(x: step.isMultiple(of: 3) ? last?.x ?? 0.3 : Double(random(100)) / 100,
                                    y: step.isMultiple(of: 3) ? last?.y ?? 0.4 : Double(random(100)) / 100,
                                    p: Double(random(100)) / 100, t: Double(step * 4)))
            }
            let prediction = step.isMultiple(of: 2) ? [NativePDFPoint(x: 0.6, y: 0.7, p: 1)] : []
            let actual = cache.polygons(points: points, predictions: prediction, width: 0.004, aspect: 1.5, highlighter: false)
            XCTAssertEqual(actual, NativePDFInkGeometryV4.polygons(points: points, predictions: prediction, width: 0.004, aspect: 1.5, highlighter: false))
            XCTAssertEqual(Array(actual.prefix(cache.retainedPrefixPolygonCount)), Array(previous.prefix(cache.retainedPrefixPolygonCount)))
            previous = actual
        }
    }

    func testLongStrokeUpdatesOnlyLastMeasuredSegmentAndNewSamples() {
        let points = samples(2400), cache = NativePDFInkGeometryV4Cache(), mesh = NativePDFInkVertexCache()
        let prefix = cache.polygons(points: Array(points.dropLast(4)), width: 0.004, aspect: 1.5, highlighter: false)
        mesh.update(prefix, retainedPrefix: cache.retainedPrefixPolygonCount, revision: cache.revision)
        let start = Date.timeIntervalSinceReferenceDate
        let actual = cache.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        mesh.update(actual, retainedPrefix: cache.retainedPrefixPolygonCount, revision: cache.revision)
        let incrementalMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
        let fullStart = Date.timeIntervalSinceReferenceDate
        let expected = NativePDFInkGeometryV4.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        let fullMS = (Date.timeIntervalSinceReferenceDate - fullStart) * 1000
        XCTAssertEqual(actual, expected); XCTAssertEqual(cache.recomputedPointCount, 4); XCTAssertEqual(cache.recomputedSegmentCount, 5)
        XCTAssertGreaterThan(cache.retainedPrefixPolygonCount, 4000)
        XCTAssertLessThanOrEqual(mesh.rebuiltVertexCount, 5 * (1 << NativePDFInkGeometryV4.maximumSubdivisionDepth) * 96)
        XCTAssertLessThan(mesh.rebuiltVertexCount, mesh.vertices.count / 10)
        print("Native ink v4: 2400 measured samples, 5 segments / \(mesh.rebuiltVertexCount) of \(mesh.vertices.count) vertices rebuilt; incremental geometry+mesh \(incrementalMS) ms vs full geometry \(fullMS) ms; excludes display latency")
    }
}
