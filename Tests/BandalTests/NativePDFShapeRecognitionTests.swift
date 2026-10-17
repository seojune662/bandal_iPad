import XCTest
import UIKit
@testable import Bandal

final class NativePDFShapeRecognitionTests: XCTestCase {
    private func edge(_ a: (Double, Double), _ b: (Double, Double), count: Int = 24) -> [NativePDFPoint] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1), jitter = sin(Double(i) * 17) * 0.001
            return NativePDFPoint(x: a.0 + (b.0 - a.0) * t + jitter, y: a.1 + (b.1 - a.1) * t + jitter, p: 0.5)
        }
    }
    @MainActor
    func testHeldPreviewMatchesSavedShapeStrokeWidthAndInvalidatesInkCache() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 600, height: 900)), width = 0.006
        let ellipse = (0...96).map { i in
            let angle = Double(i) / 96 * .pi * 2
            return NativePDFPoint(x: 0.5 + 0.2 * cos(angle), y: 0.4 + 0.1 * sin(angle), p: 0.5)
        }
        let rect = edge((0.2, 0.2), (0.7, 0.2)) + edge((0.7, 0.2), (0.7, 0.6))
            + edge((0.7, 0.6), (0.2, 0.6)) + edge((0.2, 0.6), (0.2, 0.2))
        for raw in [edge((0.1, 0.2), (0.7, 0.4)), rect, ellipse] {
            let shape = try XCTUnwrap(NativePDFShapeRecognition.recognize(raw, aspect: 1.5))
            var object = shape.payload
            object["style"] = ["color": "ink", "width": width, "opacity": 1] as [String: Any]
            let stored = try XCTUnwrap(NativePDFObjectRenderer.hitBounds(object, mapper: mapper))
            let cache = NativePDFLiveInkGeometryCache()
            let polygons = cache.polygons(version: 5, points: shape.points, width: width, aspect: 1.5, highlighter: false, heldShape: shape)
            let vertices = polygons.flatMap { $0 }
            let x = vertices.map(\.x), y = vertices.map(\.y)
            XCTAssertEqual(x.min()! * 600, stored.minX, accuracy: 0.02)
            XCTAssertEqual(x.max()! * 600, stored.maxX, accuracy: 0.02)
            XCTAssertEqual(y.min()! * 900, stored.minY, accuracy: 0.02)
            XCTAssertEqual(y.max()! * 900, stored.maxY, accuracy: 0.02)
            _ = cache.polygons(version: 5, points: shape.points, width: width, aspect: 1.5, highlighter: false, heldShape: shape)
            XCTAssertEqual(cache.retainedPrefixPolygonCount, polygons.count)
            let freehand = cache.polygons(version: 5, points: raw, width: width, aspect: 1.5, highlighter: false)
            XCTAssertNotEqual(freehand, polygons, "Resuming ink must discard the held geometric mesh")
        }
    }
    func testPhysicalGeometrySurvivesLandscapeAndPortraitCoordinates() throws {
        for aspect in [0.75, 1.0, 1.414, 2.0] {
            let circle = (0...96).map { i in
                let angle = Double(i) / 96 * .pi * 2
                return NativePDFPoint(x: 0.5 + 0.2 * cos(angle), y: 0.35 + 0.15 * sin(angle) / aspect, p: 0.5)
            }
            let shape = try XCTUnwrap(NativePDFShapeRecognition.recognize(circle, aspect: aspect))
            XCTAssertEqual(shape.kind, "ellipse"); XCTAssertEqual(shape.box[2], 0.4, accuracy: 0.001)
            XCTAssertEqual(shape.box[3] * aspect, 0.3, accuracy: 0.001)
            XCTAssertTrue(shape.points.allSatisfy(\.isValid))
        }
    }
    func testRectangleStartingMidEdgeAndTriangleProduceClosedCleanPreview() throws {
        let rect = edge((0.4, 0.2), (0.7, 0.2)) + edge((0.7, 0.2), (0.7, 0.6))
            + edge((0.7, 0.6), (0.2, 0.6)) + edge((0.2, 0.6), (0.2, 0.2)) + edge((0.2, 0.2), (0.4, 0.2))
        let shape = try XCTUnwrap(NativePDFShapeRecognition.recognize(rect, aspect: 1.4))
        XCTAssertEqual(shape.kind, "rect"); XCTAssertEqual(shape.points.first, shape.points.last)
        let triangle = edge((0.2, 0.7), (0.5, 0.2)) + edge((0.5, 0.2), (0.8, 0.7)) + edge((0.8, 0.7), (0.2, 0.7))
        let clean = try XCTUnwrap(NativePDFShapeRecognition.recognize(triangle, aspect: 1.4))
        XCTAssertEqual(clean.kind, "ink"); XCTAssertEqual(clean.points.first, clean.points.last)
        XCTAssertGreaterThan(clean.points.count, 10)
        XCTAssertTrue(clean.points.allSatisfy { $0.p == 0.5 })
    }
    func testConvexQuadrilateralFitTranslatesWithoutChangingShapeOrMeasuredSource() throws {
        let raw = edge((0.15, 0.25), (0.5, 0.15)) + edge((0.5, 0.15), (0.7, 0.45))
            + edge((0.7, 0.45), (0.3, 0.6)) + edge((0.3, 0.6), (0.15, 0.25))
        let shape = try XCTUnwrap(NativePDFShapeRecognition.recognize(raw, aspect: 1.4))
        XCTAssertEqual(shape.kind, "ink"); XCTAssertEqual(shape.points.first, shape.points.last)
        let moved = raw.map { p in NativePDFPoint(x: p.x + 0.1, y: p.y + 0.1, p: p.p) }
        let translated = try XCTUnwrap(NativePDFShapeRecognition.recognize(moved, aspect: 1.4))
        XCTAssertEqual(translated.kind, shape.kind); XCTAssertEqual(translated.points.count, shape.points.count)
        for (a, b) in zip(shape.points, translated.points) {
            XCTAssertEqual(b.x - a.x, 0.1, accuracy: 0.000001); XCTAssertEqual(b.y - a.y, 0.1, accuracy: 0.000001)
        }
        XCTAssertTrue(shape.isValid); XCTAssertTrue(translated.isValid)
    }
    func testBridgePayloadUsesInkVersionOnlyForCleanedInk() throws {
        let line = try XCTUnwrap(NativePDFShapeRecognition.recognize(edge((0.1, 0.2), (0.7, 0.4)), aspect: 1.4))
        let geometricData = try XCTUnwrap(line.payload["data"] as? [String: Any])
        XCTAssertEqual(line.payload["kind"] as? String, "line")
        XCTAssertNil(geometricData["inkVersion"], "The canonical validator rejects inkVersion on geometric shapes")
        let highlightData = try XCTUnwrap(line.inkPayload["data"] as? [String: Any])
        XCTAssertEqual(highlightData["inkVersion"] as? Int, 5)
    }
    func testStationaryTailDoesNotBiasFitButRetracingAndTinyMarksRemainRaw() throws {
        let line = edge((0.1, 0.2), (0.7, 0.4))
        let held = line + Array(repeating: line.last!, count: 1000)
        XCTAssertEqual(NativePDFShapeRecognition.recognize(held, aspect: 1.4)?.kind, "line")
        let retrace = edge((0.1, 0.2), (0.7, 0.2)) + edge((0.7, 0.2), (0.3, 0.2)) + edge((0.3, 0.2), (0.8, 0.2))
        XCTAssertNil(NativePDFShapeRecognition.recognize(retrace, aspect: 1.4))
        XCTAssertNil(NativePDFShapeRecognition.recognize(edge((0.1, 0.1), (0.105, 0.105)), aspect: 1.4))
        XCTAssertNil(NativePDFShapeRecognition.recognize(line, aspect: .nan))
    }
}
