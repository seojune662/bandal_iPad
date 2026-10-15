import XCTest
import CoreGraphics
@testable import Bandal

final class NativePDFInkV5Tests: XCTestCase {
    private func samples(_ count: Int) -> [NativePDFPoint] {
        (0..<count).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.0003, y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.2 + sin(step * 0.19) * 0.15, t: step * 1000 / 240,
                         tiltX: step.truncatingRemainder(dividingBy: 30), tiltY: -10)
        }
    }

    func testPressureResponseIsMonotonicAndFiniteWithoutRewritingRawSamples() {
        var previous = 0.0
        for pressure in stride(from: 0.0, through: 1.0, by: 0.05) {
            let points = (0..<80).map { index in
                NativePDFPoint(x: Double(index) * 0.002, y: 0.4, p: pressure, t: Double(index) * 8)
            }
            let original = points
            let factors = NativePDFInkGeometryV5.widthFactors(points: points, width: 0.006, aspect: 1.5, highlighter: false)
            XCTAssertTrue(factors.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 0.92 + 1e-14 })
            XCTAssertGreaterThan(factors[30], previous)
            let expected = (0.24 + 0.68 * pow(pressure, 0.8)) * (1 - 0.12 * (0.25 / 0.8))
            XCTAssertEqual(factors[30], expected, accuracy: 1e-13)
            XCTAssertEqual(points, original)
            previous = factors[30]
        }
    }

    func testPressureFilterUsesOnlyFourRawSamplesAndFiniteTimeWindow() {
        let points: [NativePDFPoint] = [.init(x: 0, y: 0, p: 1, t: 0), .init(x: 0, y: 0, p: 0, t: 4),
            .init(x: 0, y: 0, p: 0.2, t: 8), .init(x: 0, y: 0, p: 0.6, t: 12), .init(x: 0, y: 0, p: 1, t: 16)]
        let weights = [1.0, exp(-0.5), exp(-1.0), exp(-1.5)]
        let expected = (weights[0] + 0.6 * weights[1] + 0.2 * weights[2]) / weights.reduce(0, +)
        XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(points)[4], expected, accuracy: 1e-15)
        var oldCorrection = points; oldCorrection[0].p = 0
        XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(oldCorrection)[4], expected, accuracy: 1e-15)
        let atCutoff: [NativePDFPoint] = [.init(x: 0, y: 0, p: -3, t: 0), .init(x: 0, y: 0, p: 4, t: 24)]
        XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(atCutoff)[1], 1 / (1 + exp(-3)), accuracy: 1e-15)
        var outside = atCutoff; outside[1].t = 24.0.nextUp
        XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(outside)[1], 1)
        outside[1].t = 500
        XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(outside)[1], 1)
        let invalidTimes: [Double?] = [nil, 0, -1, .nan, .infinity]
        for time in invalidTimes {
            var missing = atCutoff; missing[1].t = time
            XCTAssertEqual(NativePDFInkGeometryV5.filteredPressures(missing)[1], 1 / (1 + exp(-0.5)), accuracy: 1e-15)
        }
    }

    func testSpeedUsesPhysicalPageWidthMetricAndInvalidClocksAreNeutral() {
        var points: [NativePDFPoint] = [.init(x: 0, y: 0, p: 0.5, t: 0), .init(x: 0.001, y: 0, p: 0.5, t: 4)]
        XCTAssertEqual(NativePDFInkGeometryV5.speeds(points, aspect: 2), [0, 0.25])
        points[1].x = 0; points[1].y = 0.001
        XCTAssertEqual(NativePDFInkGeometryV5.speeds(points, aspect: 2), [0, 0.5])
        points[1].y = 1
        XCTAssertEqual(NativePDFInkGeometryV5.speeds(points, aspect: 2), [0, 3])
        let invalidTimes: [Double?] = [nil, 0, -1, .nan, .infinity, 64.0.nextUp]
        for time in invalidTimes {
            points[1].t = time
            XCTAssertEqual(NativePDFInkGeometryV5.speeds(points, aspect: 2), [0, 0])
        }
        points[1].y = 0.001; points[1].t = 64
        XCTAssertEqual(NativePDFInkGeometryV5.speeds(points, aspect: 2), [0, 0.03125])
    }

    func testDotShortStrokeAndStationaryPressureHaveNonzeroImmediateGeometry() {
        let dot = NativePDFPoint(x: 0.2, y: 0.3, p: 0, t: 0)
        let width = 0.02, aspect = 1.5
        let factor = NativePDFInkGeometryV5.widthFactors(points: [dot], width: width, aspect: aspect, highlighter: false)
        XCTAssertEqual(factor[0], 0.18, accuracy: 1e-15)
        let polygons = NativePDFInkGeometryV5.polygons(points: [dot], width: width, aspect: aspect, highlighter: false)
        XCTAssertEqual(polygons.count, 1); XCTAssertEqual(polygons[0].count, 32)
        XCTAssertEqual(polygons[0][0].x, dot.x + width * factor[0] / 2, accuracy: 1e-15)
        let stationary: [NativePDFPoint] = [dot, .init(x: dot.x, y: dot.y, p: 1, t: 32), .init(x: dot.x, y: dot.y, p: 0, t: 64)]
        let disks = NativePDFInkGeometryV5.polygons(points: stationary, width: width, aspect: aspect, highlighter: false)
        XCTAssertEqual(disks.map(\.count), [32], "Stationary raw samples share one render anchor")
        let pressed = NativePDFInkGeometryV5.polygons(points: Array(stationary.prefix(2)), width: width, aspect: aspect, highlighter: false)
        XCTAssertGreaterThan(pressed[0][0].x, polygons[0][0].x)
        XCTAssertEqual(disks, polygons)
        let short: [NativePDFPoint] = [dot, .init(x: dot.x + 0.000001, y: dot.y, p: 0.8, t: 4)]
        let shortFactors = NativePDFInkGeometryV5.widthFactors(points: short, width: width, aspect: aspect, highlighter: false)
        XCTAssertTrue(shortFactors.allSatisfy { $0 > 0.1 && $0.isFinite })
        XCTAssertFalse(NativePDFInkGeometryV5.polygons(points: short, width: width, aspect: aspect, highlighter: false).isEmpty)
    }

    func testTaperIsDistanceBoundedAtCountBoundaryAndRepeatedEndpoints() {
        let width = 0.006
        for count in [1, 2, 16, 17, 18, 19, 80] {
            var points = (0..<count).map { NativePDFPoint(x: Double($0) * 0.002, y: 0.3, p: 0.7, t: Double($0) * 8) }
            for _ in 0..<18 {
                let travel = NativePDFInkGeometryV5.cumulativeTravel(points, aspect: 1.5)
                let tailStart = max(0, points.count - 17)
                for index in 0..<tailStart { XCTAssertEqual(NativePDFInkGeometryV5.endGain(index: index, travel: travel, width: width), 1) }
                XCTAssertEqual(NativePDFInkGeometryV5.endGain(index: tailStart, travel: travel, width: width), 1, accuracy: 1e-13)
                let factors = NativePDFInkGeometryV5.widthFactors(points: points, width: width, aspect: 1.5, highlighter: false)
                XCTAssertEqual(factors.count, points.count)
                XCTAssertTrue(factors.allSatisfy { $0 > 0 && $0 <= 0.92 && $0.isFinite })
                var repeated = points.last!; repeated.t = (repeated.t ?? 0) + 4
                points.append(repeated)
            }
        }
        let travel = (0..<80).map { Double($0) * 0.002 }
        XCTAssertEqual(NativePDFInkGeometryV5.endGain(index: 79, travel: travel, width: width), 0.32, accuracy: 1e-15)
        XCTAssertEqual(NativePDFInkGeometryV5.endGain(index: 0, travel: [0], width: width), 1)
    }

    func testCenterlineStreamingAndAspectRemainV4WithExplicitFactorInterpolation() {
        let points = samples(80), width = 0.004, aspect = 1.5
        let profile = NativePDFInkGeometryV5.renderProfile(points: points, width: width, aspect: aspect, highlighter: false)!
        for index in 0..<(points.count - 1) {
            var old: [NativePDFInkGeometryV4.Sample] = [], next: [NativePDFInkGeometryV5.Sample] = []
            NativePDFInkGeometryV4.forEachSegmentSample(points: points, pressures: profile.sampleTimes, index: index, width: width, aspect: aspect) { old.append($0) }
            NativePDFInkGeometryV5.forEachSegmentSample(profile: profile, index: index, width: width, aspect: aspect, highlighter: false) { next.append($0) }
            for sample in old { XCTAssertTrue(next.contains { $0.x == sample.x && $0.y == sample.y }, "Every V4 centerline vertex is preserved") }
            XCTAssertEqual(next.last?.factor, profile.factors[index + 1])
            XCTAssertLessThanOrEqual(next.count, (1 << NativePDFInkGeometryV5.maximumSubdivisionDepth) + 16)
        }
        let tall = points.map { point -> NativePDFPoint in var result = point; result.y /= 2; return result }
        XCTAssertEqual(NativePDFInkGeometryV5.widthFactors(points: points, width: width, aspect: aspect, highlighter: false),
                       NativePDFInkGeometryV5.widthFactors(points: tall, width: width, aspect: aspect * 2, highlighter: false))
        var streamed: [[CGPoint]] = []
        NativePDFInkGeometryV5.forEachPolygon(points: points, width: width, aspect: aspect, highlighter: false) { streamed.append($0) }
        XCTAssertEqual(streamed, NativePDFInkGeometryV5.polygons(points: points, width: width, aspect: aspect, highlighter: false))
    }

    func testSparseLongLineLocalizesTapersAndKeepsBroadConstantBody() {
        let width = 0.004
        // Missing clocks deliberately neutralize speed so both bases are equal.
        let points: [NativePDFPoint] = [.init(x: 0.1, y: 0.4, p: 0.6), .init(x: 0.9, y: 0.4, p: 0.6)]
        let profile = NativePDFInkGeometryV5.renderProfile(points: points, width: width, aspect: 1.5, highlighter: false)!
        var rendered: [NativePDFInkGeometryV5.Sample] = []
        NativePDFInkGeometryV5.forEachSegmentSample(profile: profile, index: 0, width: width, aspect: 1.5, highlighter: false) { rendered.append($0) }
        XCTAssertLessThanOrEqual(rendered.count, 17)
        XCTAssertEqual(rendered.last?.x, points[1].x)
        let bodyStart = rendered.first { $0.x >= points[0].x + 1.2 * width - 1e-14 }!
        let bodyEnd = rendered.last { $0.x <= points[1].x - 2.2 * width + 1e-14 }!
        XCTAssertEqual(bodyStart.factor, profile.bases[0], accuracy: 1e-13)
        XCTAssertEqual(bodyEnd.factor, profile.bases[0], accuracy: 1e-13)
        XCTAssertGreaterThan(bodyEnd.x - bodyStart.x, 0.75)
        XCTAssertTrue(rendered.allSatisfy { $0.y == 0.4 })
        XCTAssertEqual(profile.factors[0], profile.bases[0] * 0.75, accuracy: 1e-15)
        XCTAssertEqual(profile.factors[1], profile.bases[1] * 0.32, accuracy: 1e-15)
    }

    func testStationaryTailDoesNotInflateOrRebuildItsEntireRawRun() {
        var points = (0..<80).map { NativePDFPoint(x: 0.1 + Double($0) * 0.001, y: 0.4, p: 0.6, t: Double($0) * 4) }
        let original = points, cache = NativePDFInkGeometryV5Cache(), width = 0.004
        let baseline = cache.polygons(points: points, width: width, aspect: 1.5, highlighter: false)
        for _ in 0..<64 {
            var last = points.last!; last.t = last.t! + 4; points.append(last)
            let actual = cache.polygons(points: points, width: width, aspect: 1.5, highlighter: false)
            XCTAssertEqual(actual, baseline, "Same-position, steady-force time updates must not consume the taper")
            XCTAssertEqual(cache.retainedAnchorCount, original.count)
            XCTAssertEqual(cache.recomputedPointCount, 1)
            XCTAssertLessThanOrEqual(cache.recomputedSegmentCount, 17)
        }
        var pressed = points.last!; pressed.p = 0.95; pressed.t = pressed.t! + 4; points.append(pressed)
        let changed = cache.polygons(points: points, width: width, aspect: 1.5, highlighter: false)
        XCTAssertNotEqual(changed, baseline, "A real stationary pressure correction remains visible")
        XCTAssertEqual(changed, NativePDFInkGeometryV5.polygons(points: points, width: width, aspect: 1.5, highlighter: false))
        var resumed = points.last!; resumed.x += 0.003; resumed.t = resumed.t! + 4; points.append(resumed)
        XCTAssertEqual(cache.polygons(points: points, width: width, aspect: 1.5, highlighter: false),
                       NativePDFInkGeometryV5.polygons(points: points, width: width, aspect: 1.5, highlighter: false))
        XCTAssertEqual(cache.retainedAnchorCount, original.count + 1)
        XCTAssertEqual(Array(points.prefix(original.count)), original)
    }

    func testHighlighterKeepsExactV4WidthAndPolygonsIncludingPredictions() {
        let points = samples(70), prediction: [NativePDFPoint] = [.init(x: 0.8, y: 0.7, p: 0), .init(x: 0.9, y: 0.8, p: 1)]
        XCTAssertEqual(NativePDFInkGeometryV5.widthFactors(points: points, width: 0.02, aspect: 1.5, highlighter: true), Array(repeating: 1, count: points.count))
        let actual = NativePDFInkGeometryV5.polygons(points: points, predictions: prediction, width: 0.02, aspect: 1.5, highlighter: true)
        XCTAssertEqual(actual, NativePDFInkGeometryV4.polygons(points: points, predictions: prediction, width: 0.02, aspect: 1.5, highlighter: true))
    }

    func testPredictionsDoNotAffectMeasuredGeometryAndLiftEqualsSavedReplay() {
        let points = samples(75), original = points, cache = NativePDFInkGeometryV5Cache(), width = 0.004
        let measured = NativePDFInkGeometryV5.polygons(points: points, width: width, aspect: 1.5, highlighter: false)
        let predictions = (0..<100).map { NativePDFPoint(x: 0.8 + Double($0) * 0.001, y: 0.7, p: $0.isMultiple(of: 2) ? 0 : 1) }
        let preview = cache.polygons(points: points, predictions: predictions, width: width, aspect: 1.5, highlighter: false)
        XCTAssertEqual(Array(preview.prefix(measured.count)), measured)
        XCTAssertEqual(preview, NativePDFInkGeometryV5.polygons(points: points, predictions: Array(predictions.prefix(8)), width: width, aspect: 1.5, highlighter: false))
        let factor = NativePDFInkGeometryV5.widthFactors(points: points, width: width, aspect: 1.5, highlighter: false).last!
        XCTAssertEqual(preview.last![0].x, predictions[7].x + width * factor / 2, accuracy: 1e-15)
        let lifted = cache.polygons(points: points, width: width, aspect: 1.5, highlighter: false)
        XCTAssertEqual(lifted, measured); XCTAssertEqual(cache.recomputedSegmentCount, 0)
        XCTAssertEqual(cache.retainedPrefixPolygonCount, measured.count)
        XCTAssertEqual(points, original)
    }

    func testInvalidGeometryRejectsAndInvalidTimeRemainsFinite() {
        let points = samples(5), cache = NativePDFInkGeometryV5Cache()
        for width in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(NativePDFInkGeometryV5.polygons(points: points, width: width, aspect: 1, highlighter: false).isEmpty)
            XCTAssertTrue(cache.polygons(points: points, width: width, aspect: 1, highlighter: false).isEmpty)
        }
        for aspect in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(NativePDFInkGeometryV5.polygons(points: points, width: 0.004, aspect: aspect, highlighter: false).isEmpty)
        }
        for key in [0, 1, 2] {
            var invalid = points
            if key == 0 { invalid[2].x = .nan }
            else if key == 1 { invalid[2].y = .infinity }
            else { invalid[2].p = .nan }
            XCTAssertTrue(NativePDFInkGeometryV5.polygons(points: invalid, width: 0.004, aspect: 1, highlighter: false).isEmpty)
            XCTAssertTrue(cache.polygons(points: invalid, width: 0.004, aspect: 1, highlighter: false).isEmpty)
        }
        var times = points; times[1].t = .nan; times[2].t = .infinity; times[3].t = nil
        let finite = cache.polygons(points: times, width: 0.004, aspect: 1, highlighter: false)
        XCTAssertFalse(finite.isEmpty); XCTAssertTrue(finite.joined().allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(finite, NativePDFInkGeometryV5.polygons(points: times, width: 0.004, aspect: 1, highlighter: false))
        let huge: [NativePDFPoint] = [.init(x: -Double.greatestFiniteMagnitude, y: 0, p: 0.5), .init(x: .greatestFiniteMagnitude, y: 0, p: 0.5)]
        XCTAssertTrue(cache.polygons(points: huge, width: 0.004, aspect: 1, highlighter: false).isEmpty)
        XCTAssertTrue(NativePDFInkGeometryV5.polygons(points: huge, width: 0.004, aspect: 1, highlighter: false).isEmpty)
    }

    func testCacheMatchesPureReplayForAppendCorrectionsTruncationAndPredictionReplacement() {
        let cache = NativePDFInkGeometryV5Cache(), points = samples(100)
        var previous: [[CGPoint]] = [], revision: UInt64 = 0
        func check(_ input: [NativePDFPoint], _ predictions: [NativePDFPoint] = [], width: Double = 0.004, aspect: Double = 1.5, highlighter: Bool = false) {
            let actual = cache.polygons(points: input, predictions: predictions, width: width, aspect: aspect, highlighter: highlighter)
            XCTAssertEqual(actual, NativePDFInkGeometryV5.polygons(points: input, predictions: predictions, width: width, aspect: aspect, highlighter: highlighter))
            XCTAssertLessThanOrEqual(cache.retainedPrefixPolygonCount, min(previous.count, actual.count))
            XCTAssertEqual(Array(actual.prefix(cache.retainedPrefixPolygonCount)), Array(previous.prefix(cache.retainedPrefixPolygonCount)))
            XCTAssertGreaterThan(cache.revision, revision); revision = cache.revision; previous = actual
        }
        check(Array(points.prefix(40))); check(Array(points.prefix(44)))
        XCTAssertEqual(cache.recomputedPointCount, 4); XCTAssertEqual(cache.recomputedFactorCount, 21)
        XCTAssertEqual(cache.recomputedSegmentCount, 21)
        check(Array(points.prefix(44)), [.init(x: 0.8, y: 0.9, p: 1)])
        XCTAssertEqual(cache.recomputedSegmentCount, 0); XCTAssertEqual(cache.recomputedFactorCount, 0)
        check(Array(points.prefix(44)), [.init(x: 0.9, y: 0.2, p: 0)])
        check(Array(points.prefix(44)))
        var corrected = Array(points.prefix(44)); corrected[5].p = 0.9; corrected[5].y += 0.02; corrected[6].t = 29
        check(corrected); XCTAssertEqual(cache.recomputedPointCount, 39); XCTAssertEqual(cache.recomputedSegmentCount, 40)
        check(Array(corrected.prefix(18))); check(Array(corrected.prefix(17))); check(Array(corrected.prefix(2))); check(Array(corrected.prefix(1)))
        check(points); check(points, width: 0.01); check(points, aspect: 0.75); check(points, highlighter: true)
        cache.reset(); check([points[0]])
        var invalid = points; invalid[3].p = .infinity
        check(invalid); XCTAssertEqual(cache.retainedPointCount, 0)
        check([]); check(points)
    }

    func testCacheMixedDegenerateCorrectionsAndShrinkingPredictionsKeepExactGPUHint() {
        let cache = NativePDFInkGeometryV5Cache(), mesh = NativePDFInkVertexCache()
        var state: UInt64 = 0x6e624b, points: [NativePDFPoint] = [], previous: [[CGPoint]] = []
        func random(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        for step in 0..<160 {
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
            let predictions = step.isMultiple(of: 2) ? [NativePDFPoint(x: 0.6, y: 0.7, p: 1)] : []
            let actual = cache.polygons(points: points, predictions: predictions, width: 0.004, aspect: 1.5, highlighter: false)
            XCTAssertEqual(actual, NativePDFInkGeometryV5.polygons(points: points, predictions: predictions, width: 0.004, aspect: 1.5, highlighter: false))
            XCTAssertEqual(Array(actual.prefix(cache.retainedPrefixPolygonCount)), Array(previous.prefix(cache.retainedPrefixPolygonCount)))
            mesh.update(actual, retainedPrefix: cache.retainedPrefixPolygonCount, revision: cache.revision)
            let fresh = NativePDFInkVertexCache(); fresh.update(actual)
            XCTAssertEqual(mesh.vertices, fresh.vertices); XCTAssertEqual(mesh.bounds, fresh.bounds)
            previous = actual
        }
    }

    func testLongStrokeAppendRebuildsBoundedTaperAndVertexSuffix() {
        let points = samples(2400), cache = NativePDFInkGeometryV5Cache(), mesh = NativePDFInkVertexCache()
        let previous = cache.polygons(points: Array(points.dropLast(4)), width: 0.004, aspect: 1.5, highlighter: false)
        mesh.update(previous, retainedPrefix: cache.retainedPrefixPolygonCount, revision: cache.revision)
        let start = Date.timeIntervalSinceReferenceDate
        let actual = cache.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        mesh.update(actual, retainedPrefix: cache.retainedPrefixPolygonCount, revision: cache.revision)
        let incrementalMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
        let fullStart = Date.timeIntervalSinceReferenceDate
        let expected = NativePDFInkGeometryV5.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        let fullMS = (Date.timeIntervalSinceReferenceDate - fullStart) * 1000
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(cache.recomputedPointCount, 4); XCTAssertEqual(cache.recomputedFactorCount, 21)
        XCTAssertEqual(cache.recomputedSegmentCount, 21); XCTAssertGreaterThan(cache.retainedPrefixPolygonCount, 4000)
        XCTAssertLessThanOrEqual(mesh.rebuiltVertexCount, 21 * ((1 << NativePDFInkGeometryV5.maximumSubdivisionDepth) + 16) * 96)
        XCTAssertLessThan(mesh.rebuiltVertexCount, mesh.vertices.count / 10)
        print("Native ink v5: 2400 measured samples; 4 raw factors, 21 tapered factors / segments; \(mesh.rebuiltVertexCount)/\(mesh.vertices.count) vertices rebuilt; incremental geometry+mesh \(incrementalMS) ms versus full geometry \(fullMS) ms; excludes display latency and includes existing raw-prefix comparison")
    }
}
