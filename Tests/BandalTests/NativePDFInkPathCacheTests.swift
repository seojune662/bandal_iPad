import XCTest
import CoreGraphics
@testable import Bandal

final class NativePDFInkPathCacheTests: XCTestCase {
    private func samples(_ count: Int) -> [NativePDFPoint] {
        (0..<count).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step / Double(max(count, 1)) * 0.7,
                         y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.15 + sin(step * 0.19) * 0.1, t: step * 1000 / 240)
        }
    }
    private func path(_ polygons: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            path.move(to: first)
            polygon.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        return path
    }
    func testTypedPathsExactlyMatchEveryVersionIncludingCurveChunkBoundaries() throws {
        var points = samples(600)
        // Exercise containment, missing time, zero delta and the chunk seam.
        points[255] = .init(x: points[254].x, y: points[254].y, p: 0.8, t: points[254].t)
        points[256].t = nil
        let cache = NativePDFInkPathCache()
        for version in [2, 3, 4, 5] {
            for highlighter in [false, true] {
                let actual = try XCTUnwrap(cache.prepare(key: "same", points: points, version: version, width: 0.004, aspect: 1.4, highlighter: highlighter))
                let expected = version == 5
                    ? NativePDFInkGeometryV5.polygons(points: points, width: 0.004, aspect: 1.4, highlighter: highlighter)
                    : version == 4
                    ? NativePDFInkGeometryV4.polygons(points: points, width: 0.004, aspect: 1.4, highlighter: highlighter)
                    : version == 3
                    ? NativePDFInkGeometryV3.polygons(points: points, width: 0.004, aspect: 1.4, highlighter: highlighter)
                    : NativePDFInkGeometry.polygons(points: points, width: 0.004, aspect: 1.4, highlighter: highlighter)
                XCTAssertEqual(actual.path, path(expected))
                XCTAssertEqual(actual.vertexCount, expected.reduce(0) { $0 + $1.count })
            }
        }
    }
    func testReplacementConfigurationAndTimeChangesInvalidateButColorDoesNot() throws {
        let cache = NativePDFInkPathCache(), points = samples(10)
        var input = NativePDFStrokeInput(courseId: "c", relPath: "p.pdf", page: 1, kind: "ink", data: .init(points: points),
            style: .init(color: "blue", width: 0.004, opacity: 1), clientMutationId: "mutation")
        var previous = try XCTUnwrap(cache.prepare(input, aspect: 1.4))
        input.style.color = "red"; input.style.opacity = 0.5
        XCTAssertTrue(cache.prepare(input, aspect: 1.4) === previous)
        for index in 0..<5 {
            switch index {
            case 0: input.data.points[4].p = 0.9
            case 1: input.data.points[5].t = 120
            case 2: input.style.width = 0.007
            case 3: input.kind = "highlighter"
            default: input.data.inkVersion = 2
            }
            let changed = try XCTUnwrap(cache.prepare(input, aspect: 1.4, reusing: previous))
            XCTAssertFalse(changed === previous); previous = changed
        }
        XCTAssertFalse(cache.prepare(input, aspect: 0.7, reusing: previous) === previous)
        input.data.points[0].p = .nan
        XCTAssertNil(cache.prepare(input, aspect: 0.7)); XCTAssertEqual(cache.retainedCount, 0)
        input.data.points = points
        XCTAssertNotNil(cache.prepare(input, aspect: 0.7))
    }
    func testMovedCanonicalVersionTwoInkOutsidePageAndClampedPressureRemainVisible() throws {
        let cache = NativePDFInkPathCache()
        let initial = try XCTUnwrap(cache.prepare(key: "moved", points: samples(3), version: 2, width: 0.02, aspect: 1.4, highlighter: false))
        let points: [NativePDFPoint] = [.init(x: -0.2, y: 0.9, p: -1, t: 0),
            .init(x: 0.4, y: 1.2, p: 0.5, t: 4), .init(x: 1.3, y: -0.1, p: 2, t: 8)]
        let clamped = points.map { point in var point = point; point.p = min(1, max(0, point.p)); return point }
        for highlighter in [false, true] {
            let canonical: [String: Any] = ["id": "moved", "kind": highlighter ? "highlighter" : "ink",
                "style": ["width": 0.02, "color": "blue", "opacity": 1],
                "data": ["inkVersion": 2, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p, "t": $0.t!] }]]
            let actual = try XCTUnwrap(cache.prepare(canonical, aspect: 1.4))
            let expected = NativePDFInkGeometry.polygons(points: clamped, width: 0.02, aspect: 1.4, highlighter: highlighter)
            XCTAssertFalse(actual === initial)
            XCTAssertEqual(actual.path, path(expected))
            XCTAssertEqual(NativePDFInkGeometry.polygons(points: points, width: 0.02, aspect: 1.4, highlighter: highlighter), expected)
            XCTAssertTrue(actual.path.boundingBoxOfPath.minX < 0)
            XCTAssertTrue(actual.path.boundingBoxOfPath.maxX > 1)
            XCTAssertTrue(actual.path.boundingBoxOfPath.minY < 0)
            XCTAssertTrue(actual.path.boundingBoxOfPath.maxY > 1)
        }
        var invalid = points; invalid[1].x = .infinity
        XCTAssertTrue(NativePDFInkGeometry.polygons(points: invalid, width: 0.02, aspect: 1.4, highlighter: false).isEmpty)
        XCTAssertNil(cache.prepare(key: "moved", points: invalid, version: 2, width: 0.02, aspect: 1.4, highlighter: false))
        // This renderer compatibility change must not loosen newly journaled
        // Pencil input. Test position and pressure violations independently.
        for point in [NativePDFPoint(x: -0.1, y: 0.5, p: 0.5), NativePDFPoint(x: 0.5, y: 0.5, p: 2)] {
            let input = NativePDFStrokeInput(courseId: "course", relPath: "paper.pdf", page: 1, kind: "ink",
                data: .init(points: [point], inkVersion: 2), style: .init(color: "blue", width: 0.02, opacity: 1), clientMutationId: UUID().uuidString)
            var rejected = false
            do { try input.validate() } catch { rejected = true }
            XCTAssertTrue(rejected, "Canonical rendering must not change the new-stroke journal boundary")
        }
    }
    func testLRUEvictionAndOversizedEntryDoNotRetainUnboundedGeometry() throws {
        let cache = NativePDFInkPathCache(byteLimit: 8_000, countLimit: 2), point = samples(1)
        func prepare(_ key: String) throws -> NativePDFPreparedInk {
            try XCTUnwrap(cache.prepare(key: key, points: point, version: 3, width: 0.004, aspect: 1.4, highlighter: false))
        }
        let first = try prepare("first"), second = try prepare("second")
        XCTAssertTrue(try prepare("first") === first)
        _ = try prepare("third")
        XCTAssertEqual(cache.retainedCount, 2); XCTAssertLessThanOrEqual(cache.retainedCost, cache.byteLimit)
        XCTAssertFalse(try prepare("second") === second)
        let before = cache.retainedCount
        XCTAssertNotNil(cache.prepare(key: "large", points: samples(6000), version: 3, width: 0.004, aspect: 1.4, highlighter: false))
        XCTAssertEqual(cache.retainedCount, before); XCTAssertLessThanOrEqual(cache.retainedCost, cache.byteLimit)
        cache.removeAll(); XCTAssertEqual(cache.retainedCount, 0); XCTAssertEqual(cache.retainedCost, 0)
    }
    func testVisibleOverlayReusesSixtyFivePathsWithoutLRUThrashOrStaleSameIDGeometry() throws {
        let cache = NativePDFInkPathCache(countLimit: 64), points = samples(3)
        let objects: [[String: Any]] = (0..<65).map { index in
            ["id": "stroke-\(index)", "kind": "ink", "style": ["width": 0.004, "color": "blue", "opacity": 1],
             "data": ["inkVersion": 3, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p, "t": $0.t!] }]]
        }
        let visible = try objects.map { try XCTUnwrap(cache.prepare($0, aspect: 1.4)) }
        XCTAssertEqual(cache.buildCount, 65); XCTAssertEqual(cache.retainedCount, 64)
        for (index, object) in objects.enumerated() {
            XCTAssertTrue(cache.prepare(object, aspect: 1.4, reusing: visible[index]) === visible[index])
        }
        XCTAssertEqual(cache.buildCount, 65, "An unchanged full-page refresh must not rebuild all paths after exceeding LRU capacity")
        XCTAssertEqual(cache.retainedCount, 64); XCTAssertLessThanOrEqual(cache.retainedCost, cache.byteLimit)
        var edited = objects[0]
        var changed = points; changed[1].x += 0.2
        edited["data"] = ["inkVersion": 3, "points": changed.map { ["x": $0.x, "y": $0.y, "p": $0.p, "t": $0.t!] }]
        // A stale typed object copied alongside a same-ID edit is no authority
        // to reuse the old path; it must pass the same full-input comparison.
        edited["_nativeInk"] = visible[0]
        let replacement = try XCTUnwrap(cache.prepare(edited, aspect: 1.4, reusing: visible[0]))
        XCTAssertFalse(replacement === visible[0]); XCTAssertEqual(cache.buildCount, 66)
        XCTAssertEqual(replacement.path, path(NativePDFInkGeometryV3.polygons(points: changed, width: 0.004, aspect: 1.4, highlighter: false)))
        let small = NativePDFInkPathCache(byteLimit: 1_000, countLimit: 1), long = samples(6000)
        let oversize = try XCTUnwrap(small.prepare(key: "long", points: long, version: 3, width: 0.004, aspect: 1.4, highlighter: false))
        XCTAssertEqual(small.retainedCount, 0); XCTAssertEqual(small.retainedCost, 0)
        XCTAssertTrue(small.prepare(key: "long", points: long, version: 3, width: 0.004, aspect: 1.4, highlighter: false, reusing: oversize) === oversize)
        XCTAssertEqual(small.buildCount, 1); XCTAssertEqual(small.retainedCount, 0); XCTAssertEqual(small.retainedCost, 0)
    }
    func testSixThousandPointStrokeKeepsEveryPolygonWithoutSVGSizeLimit() throws {
        let cache = NativePDFInkPathCache(), points = samples(6000)
        let started = Date.timeIntervalSinceReferenceDate
        let actual = try XCTUnwrap(cache.prepare(key: "long", points: points, version: 3, width: 0.003, aspect: 1.4, highlighter: false))
        let elapsed = (Date.timeIntervalSinceReferenceDate - started) * 1000
        let polygons = NativePDFInkGeometryV3.polygons(points: points, width: 0.003, aspect: 1.4, highlighter: false)
        XCTAssertEqual(actual.path, path(polygons)); XCTAssertEqual(actual.pointCount, 6000)
        XCTAssertEqual(actual.vertexCount, polygons.reduce(0) { $0 + $1.count })
        var closed = 0
        actual.path.applyWithBlock { if $0.pointee.type == .closeSubpath { closed += 1 } }
        XCTAssertEqual(closed, polygons.count)
        XCTAssertTrue(actual.path.boundingBoxOfPath.maxX.isFinite)
        XCTAssertTrue(cache.prepare(key: "long", points: points, version: 3, width: 0.003, aspect: 1.4, highlighter: false) === actual)
        print("Native typed completed ink: 6000 raw points, \(actual.vertexCount) vertices, \(elapsed) ms; no SVG encoding or parsing")
    }
}
