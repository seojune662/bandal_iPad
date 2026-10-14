import XCTest
@testable import Bandal

final class NativePDFInkV3Tests: XCTestCase {
    private let golden: [NativePDFPoint] = [
        .init(x: 0.1, y: 0.2, p: 0, t: 0), .init(x: 0.103, y: 0.202, p: 0.8, t: 4),
        .init(x: 0.106, y: 0.203, p: 0.2, t: 12), .init(x: 0.107, y: 0.203, p: 1, t: 12),
        .init(x: 0.12, y: 0.22, p: 0.6, t: 100)
    ]
    func testSharedTypeScriptGoldenPressureAndTangentVertices() {
        let expected = [0, 0.12281462008750875, 0.14469425857416682, 0.14469425857416682, 0.47998270959249123]
        for (actual, value) in zip(NativePDFInkGeometryV3.filteredPressures(golden), expected) { XCTAssertEqual(actual, value, accuracy: 1e-12) }
        let quad = NativePDFInkGeometryV3.polygons(points: golden, width: 0.01, aspect: 1.5, highlighter: false)[1]
        let vertices = [CGPoint(x: 0.10144131683328605, y: 0.19898180862176848), CGPoint(x: 0.1045256095853364, y: 0.20092226158019996),
                        CGPoint(x: 0.10138339237029992, y: 0.20301707305689096), CGPoint(x: 0.09847271293265271, y: 0.20096087788885736)]
        for (actual, value) in zip(quad, vertices) { XCTAssertEqual(actual.x, value.x, accuracy: 1e-12); XCTAssertEqual(actual.y, value.y, accuracy: 1e-12) }
    }
    func testTimeRulesAreCausalAndAppendingPredictionsPreservesMeasuredPrefix() {
        let missing = [NativePDFPoint(x: 0.2, y: 0.3, p: 0), .init(x: 0.2, y: 0.3, p: 1)]
        XCTAssertEqual(NativePDFInkGeometryV3.filteredPressures(missing)[1], -expm1(-4.0 / 24), accuracy: 1e-14)
        let zero = [NativePDFPoint(x: 0.2, y: 0.3, p: 0.3, t: 10), .init(x: 0.3, y: 0.3, p: 1, t: 10), .init(x: 0.4, y: 0.3, p: 0, t: 8)]
        XCTAssertEqual(NativePDFInkGeometryV3.filteredPressures(zero), [0.3, 0.3, 0.3])
        let prefix = NativePDFInkGeometryV3.polygons(points: Array(golden.prefix(3)), width: 0.004, aspect: 2, highlighter: false)
        let original = golden, full = NativePDFInkGeometryV3.polygons(points: golden, width: 0.004, aspect: 2, highlighter: false)
        XCTAssertEqual(Array(full.prefix(prefix.count)), prefix); XCTAssertEqual(golden, original)
    }
    func testPressureJitterReducesWithoutMovingPositionsOrInflatingNormalWidth() {
        let points: [NativePDFPoint] = (0..<240).map { index in .init(x: 0.1 + Double(index) * 0.0005, y: 0.3, p: index.isMultiple(of: 2) ? 0.1 : 0.2, t: Double(index) * 4) }
        let values = NativePDFInkGeometryV3.filteredPressures(points)
        let rawChange = 0.004 * 0.65 * 0.1 / 2
        var changes: [Double] = []
        for index in 1..<values.count { changes.append(0.004 * 0.20 * abs(values[index] - values[index - 1]) / 2) }
        XCTAssertLessThan(changes.max()!, rawChange * 0.1)
        XCTAssertLessThan(sqrt(changes.reduce(0) { $0 + $1 * $1 } / Double(changes.count)), rawChange * 0.1)
        let ratio = (0.42 + 0.20 * 0.137) / (0.35 + 0.65 * 0.137)
        XCTAssertGreaterThan(ratio, 0.98); XCTAssertLessThan(ratio, 1.03)
        let circles = NativePDFInkGeometryV3.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false).filter { $0.count == 32 }
        for (circle, point) in zip(circles, points) {
            XCTAssertEqual((circle[0].x + circle[16].x) / 2, point.x, accuracy: 1e-14)
            XCTAssertEqual((circle[8].y + circle[24].y) / 2, point.y, accuracy: 1e-14)
        }
    }
    func testContainedDiskDotsHighlighterAndTangentWinding() {
        let contained = [NativePDFPoint(x: 0.2, y: 0.4, p: 0, t: 0), .init(x: 0.201, y: 0.4, p: 1, t: 32)]
        XCTAssertEqual(NativePDFInkGeometryV3.polygons(points: contained, width: 0.1, aspect: 2, highlighter: false).map(\.count), [32, 32])
        let dot = NativePDFInkGeometryV3.polygons(points: [contained[0]], width: 0.02, aspect: 2, highlighter: false)[0]
        XCTAssertEqual(dot[0].x, 0.2042, accuracy: 1e-14); XCTAssertEqual(dot[8].y, 0.4021, accuracy: 1e-14)
        let polygons = NativePDFInkGeometryV3.polygons(points: golden, width: 0.01, aspect: 1.5, highlighter: false)
        for polygon in polygons {
            let area = polygon.indices.reduce(0.0) { sum, index in
                let p = polygon[index], q = polygon[(index + 1) % polygon.count]
                return sum + p.x * q.y - q.x * p.y
            }
            XCTAssertGreaterThan(area, 0)
        }
        let high = golden.map { point in var point = point; point.p = 1; return point }
        XCTAssertEqual(NativePDFInkGeometryV3.polygons(points: golden, width: 0.02, aspect: 2, highlighter: true), NativePDFInkGeometryV3.polygons(points: high, width: 0.02, aspect: 2, highlighter: true))
        XCTAssertTrue(NativePDFInkGeometryV3.polygons(points: [], width: 0.01, aspect: 2, highlighter: false).isEmpty)
    }
    func testTenSecond240HzGeometryReportsCostAndKeepsFiniteOutput() {
        let points: [NativePDFPoint] = (0..<2400).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.0003, y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.15 + sin(step * 0.19) * 0.05, t: step * 1000 / 240)
        }
        let started = Date.timeIntervalSinceReferenceDate
        let polygons = NativePDFInkGeometryV3.polygons(points: points, width: 0.004, aspect: 842.0 / 595, highlighter: false)
        let elapsed = (Date.timeIntervalSinceReferenceDate - started) * 1000
        XCTAssertEqual(polygons.count, points.count * 2 - 1)
        XCTAssertEqual(polygons.filter { $0.count == 32 }.count, points.count)
        XCTAssertTrue(polygons.allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        print("Native ink v3: 2400 measured points / 10 seconds at 240Hz, \(polygons.count) polygons, geometry \(elapsed) ms (not display/presentation latency)")
    }
}
