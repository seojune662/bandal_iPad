import XCTest
import CoreGraphics
@testable import Bandal

/// Routing/cache boundaries, independent of the new pressure evaluator's
/// formula tests. No physical touch, backend ACK or presentation claim.
final class NativePDFInkV5IntegrationTests: XCTestCase {
    func testPreparedPathVersionIsPartOfIdentityAndOldDefaultsRemainV4() throws {
        let points = samples()
        let style = NativePDFInkStyle(color: "blue", width: 0.012, opacity: 0.7)
        let old = NativePDFCompletedStroke(mutationID: UUID().uuidString, kind: "ink", points: points, style: style)
        XCTAssertEqual(old.inkVersion, 4)
        XCTAssertEqual(NativePDFStrokeData(points: points).inkVersion, 4)
        let cache = NativePDFInkPathCache()
        let v4 = try XCTUnwrap(cache.prepare(key: "shared", points: points, version: 4, width: style.width, aspect: 1.4, highlighter: false))
        XCTAssertEqual(v4.path, path(NativePDFInkGeometryV4.polygons(points: points, width: style.width, aspect: 1.4, highlighter: false)))
        let v5 = try XCTUnwrap(cache.prepare(key: "shared", points: points, version: 5, width: style.width, aspect: 1.4, highlighter: false, reusing: v4))
        XCTAssertFalse(v5 === v4)
        XCTAssertNotEqual(v5.path, v4.path, "New pressure/taper must not silently reuse the older path")
        XCTAssertEqual(v5.path, path(NativePDFInkGeometryV5.polygons(points: points, width: style.width, aspect: 1.4, highlighter: false)))
        XCTAssertTrue(cache.prepare(key: "shared", points: points, version: 5, width: style.width, aspect: 1.4, highlighter: false, reusing: v5) === v5)
        // The original immutable prepared owner is still reusable even though
        // its cache key has subsequently referred to a different version.
        XCTAssertTrue(cache.prepare(key: "shared", points: points, version: 4, width: style.width, aspect: 1.4, highlighter: false, reusing: v4) === v4)
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(v4.path, path(NativePDFInkGeometryV4.polygons(points: points, width: style.width, aspect: 1.4, highlighter: false)))
    }

    func testVersionedLiveCacheChangesResetPrefixAndPreserveFailedV4Completion() throws {
        let points = samples(), predictions = [NativePDFPoint(x: 0.87, y: 0.4, p: 1, t: 400)]
        let style = NativePDFInkStyle(color: "blue", width: 0.012, opacity: 0.7)
        let old = NativePDFCompletedStroke(mutationID: UUID().uuidString, kind: "ink", points: points, style: style)
        let pending = NativePDFCompletionBuffer()
        try pending.retain(old)
        XCTAssertThrowsError(try pending.flush { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(pending.pending, old)
        let live = NativePDFLiveInkGeometryCache()
        var lastRevision: UInt64 = 0
        for version in [4, 5, 4, 5] {
            let actual = live.polygons(version: version, points: points, predictions: predictions,
                                      width: style.width, aspect: 1.4, highlighter: false)
            let expected = version == 4
                ? NativePDFInkGeometryV4.polygons(points: points, predictions: predictions, width: style.width, aspect: 1.4, highlighter: false)
                : NativePDFInkGeometryV5.polygons(points: points, predictions: predictions, width: style.width, aspect: 1.4, highlighter: false)
            XCTAssertTrue(actual == expected)
            XCTAssertEqual(live.retainedPrefixPolygonCount, 0, "Different geometry versions may share no mesh prefix hint")
            XCTAssertGreaterThan(live.revision, lastRevision); lastRevision = live.revision
        }
        var replayed: NativePDFCompletedStroke?
        try pending.flush { replayed = $0 }
        XCTAssertEqual(replayed, old); XCTAssertNil(pending.pending)
        let recovered = try XCTUnwrap(replayed)
        XCTAssertEqual(recovered.inkVersion, 4)
        XCTAssertTrue(live.polygons(version: recovered.inkVersion, points: recovered.points,
                                   width: recovered.style.width, aspect: 1.4, highlighter: false) ==
                      NativePDFInkGeometryV4.polygons(points: points, width: style.width, aspect: 1.4, highlighter: false))
        XCTAssertTrue(live.polygons(version: 999, points: points, width: style.width, aspect: 1.4, highlighter: false).isEmpty)
        XCTAssertEqual(live.retainedPrefixPolygonCount, 0)
    }

    func testV5TransportRawBitsAndHighlighterGeometryRemainUnmodified() throws {
        let points = samples()
        let input = NativePDFStrokeInput(courseId: "v5-public-fixture", relPath: "paper.pdf", page: 1, kind: "ink",
            data: .init(points: points, inkVersion: 5), style: .init(color: "blue", width: 0.012, opacity: 0.7),
            clientMutationId: UUID().uuidString, documentRevision: String(repeating: "a", count: 64))
        try input.validate()
        let decoded = try JSONDecoder().decode(NativePDFStrokeInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.data.inkVersion, 5)
        XCTAssertEqual(decoded.data.points.count, points.count)
        for (a, b) in zip(decoded.data.points, points) {
            XCTAssertEqual(a.x.bitPattern, b.x.bitPattern); XCTAssertEqual(a.y.bitPattern, b.y.bitPattern)
            XCTAssertEqual(a.p.bitPattern, b.p.bitPattern); XCTAssertEqual(a.t?.bitPattern, b.t?.bitPattern)
            XCTAssertEqual(a.tiltX?.bitPattern, b.tiltX?.bitPattern); XCTAssertEqual(a.tiltY?.bitPattern, b.tiltY?.bitPattern)
        }
        // Highlighter remains constant width and uses the unchanged centerline;
        // pen pressure/velocity/taper must not leak into its multiply footprint.
        let cache = NativePDFLiveInkGeometryCache()
        for count in [1, 2, 3, 17, points.count] {
            let prefix = Array(points.prefix(count))
            let actual = cache.polygons(version: 5, points: prefix, width: 0.012, aspect: 1.4, highlighter: true)
            XCTAssertTrue(actual == NativePDFInkGeometryV4.polygons(points: prefix, width: 0.012, aspect: 1.4, highlighter: true))
        }
        XCTAssertEqual(input.data.points, points, "Render-only filtering never rewrites the canonical samples")
    }

    private func samples() -> [NativePDFPoint] {
        (0..<96).map { index in
            let u = Double(index) / 95
            return NativePDFPoint(x: 0.1 + 0.7 * u, y: 0.4 + 0.05 * sin(u * .pi * 2),
                p: 0.02 + 0.96 * sin(u * .pi), t: Double(index) * 4,
                tiltX: 17.0 / 12345 + u, tiltY: -11.0 / 12345 - u)
        }
    }
    private func path(_ polygons: [[CGPoint]]) -> CGPath {
        let result = CGMutablePath()
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            result.move(to: first)
            for point in polygon.dropFirst() { result.addLine(to: point) }
            result.closeSubpath()
        }
        return result
    }
}
