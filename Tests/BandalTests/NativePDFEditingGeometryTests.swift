import XCTest
@testable import Bandal

final class NativePDFEditingGeometryTests: XCTestCase {
    func testStrokeHitUsesMeasuredPathRatherThanEmptyBoundingBox() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        XCTAssertNil(NativePDFEditingGeometry.hit(CGPoint(x: 0.1, y: 0.9), rows: [row], aspect: 1.4))
        XCTAssertEqual(NativePDFEditingGeometry.hit(CGPoint(x: 0.5, y: 0.5), rows: [row], aspect: 1.4), "ink")
    }
    func testLassoFindsCrossingSegmentAndRejectsEmptyStrokeInterior() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        let crossing = [CGPoint(x: 0.45, y: 0.45), CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.55, y: 0.55), CGPoint(x: 0.45, y: 0.55)]
        XCTAssertEqual(NativePDFEditingGeometry.lasso(crossing, rows: [row], aspect: 1.4), ["ink"])
        let empty = [CGPoint(x: 0.08, y: 0.85), CGPoint(x: 0.15, y: 0.85), CGPoint(x: 0.15, y: 0.95), CGPoint(x: 0.08, y: 0.95)]
        XCTAssertTrue(NativePDFEditingGeometry.lasso(empty, rows: [row], aspect: 1.4).isEmpty)
    }
    func testBoxLassoCornersSelectCrossingStrokeAndPortableRowsDropIdentityAndImages() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        let start = CGPoint(x: 0.4, y: 0.6), end = CGPoint(x: 0.6, y: 0.4)
        let box = [start, CGPoint(x: end.x, y: start.y), end, CGPoint(x: start.x, y: end.y)]
        XCTAssertEqual(NativePDFEditingGeometry.lasso(box, rows: [row], aspect: 1.4), ["ink"])
        var stale = row; stale["nativePath"] = "stale"; stale["_nativeInk"] = "cache"
        let image: [String: Any] = ["id": "img", "page": 1, "kind": "image", "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2]], "style": ["color": "ink", "width": 0.01, "opacity": 1]]
        let portable = NativePDFEditingGeometry.portable([stale, image])
        XCTAssertEqual(portable.count, 1)
        XCTAssertEqual(Set(portable[0].keys), ["page", "kind", "data", "style"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(portable))
    }
    func testRestyleAppliesHighlighterRulesAndLeavesTextBoxGeometryAlone() throws {
        var highlighter = stroke([["x": 0.1, "y": 0.1, "p": 0.4]]); highlighter["kind"] = "highlighter"; highlighter["nativePath"] = "stale"
        let text: [String: Any] = ["id": "t", "page": 1, "kind": "textbox", "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.1], "text": "hi"],
                                   "style": ["color": "ink", "width": 0.01, "opacity": 1, "fontSizePt": 14, "bold": true, "align": "center"]]
        let rows = NativePDFEditingGeometry.restyled([highlighter, text], color: "red", width: 0.004, opacity: 0.9)
        let marker = try XCTUnwrap(rows[0]["style"] as? [String: Any]), label = try XCTUnwrap(rows[1]["style"] as? [String: Any])
        XCTAssertEqual(marker["color"] as? String, "red"); XCTAssertEqual(marker["width"] as? Double, 0.016); XCTAssertEqual(marker["opacity"] as? Double, 0.34)
        XCTAssertNil(rows[0]["nativePath"])
        XCTAssertEqual(label["color"] as? String, "red"); XCTAssertEqual(label["width"] as? Double, 0.01); XCTAssertEqual((label["opacity"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(label["bold"] as? Bool, true); XCTAssertEqual(label["align"] as? String, "center")
        let ink = NativePDFEditingGeometry.restyled([stroke([["x": 0.1, "y": 0.1, "p": 0.4]])], color: nil, width: 0.004, opacity: nil)
        XCTAssertEqual((ink[0]["style"] as? [String: Any])?["width"] as? Double, 0.004)
        XCTAssertEqual((ink[0]["style"] as? [String: Any])?["color"] as? String, "blue", "nil leaves the colour alone")
    }
    func testMoveAndResizePreserveMeasuredSamplesAndDropStaleLegacyPath() throws {
        let point: [String: Any] = ["x": 0.2, "y": 0.3, "p": 0.00016200891049007697, "t": 12.3354324324321, "tiltX": -30.33, "tiltY": 22.53]
        var row = stroke([point]); row["nativePath"] = "stale"
        var data = row["data"] as! [String: Any]; data["futureMetadata"] = "keep"; row["data"] = data
        let moved = try XCTUnwrap(NativePDFEditingGeometry.translated([row], dx: 0.1, dy: 0.2, aspect: 1.4).first)
        let value = moved["data"] as! [String: Any], sample = (value["points"] as! [[String: Any]])[0]
        XCTAssertEqual((sample["x"] as! NSNumber).doubleValue, 0.3, accuracy: 1e-12)
        XCTAssertEqual((sample["y"] as! NSNumber).doubleValue, 0.5, accuracy: 1e-12)
        for key in ["p", "t", "tiltX", "tiltY"] { XCTAssertEqual((sample[key] as! NSNumber).doubleValue.bitPattern, (point[key] as! NSNumber).doubleValue.bitPattern) }
        XCTAssertNil(moved["nativePath"]); XCTAssertEqual(value["inkVersion"] as? Int, 5); XCTAssertEqual(value["futureMetadata"] as? String, "keep")
    }
    func testGroupMoveAndResizeRemainWithinNormalizedPage() throws {
        let row: [String: Any] = ["id": "rect", "kind": "rect", "data": ["box": ["x": 0.7, "y": 0.8, "width": 0.2, "height": 0.1]], "style": ["color": "blue", "width": 0.003, "opacity": 1]]
        let moved = NativePDFEditingGeometry.translated([row], dx: 1, dy: 1, aspect: 1.4)
        let box = try XCTUnwrap(NativePDFEditingGeometry.union(moved))
        XCTAssertLessThanOrEqual(box.maxX, 1); XCTAssertLessThanOrEqual(box.maxY, 1)
        let resized = NativePDFEditingGeometry.resized(moved, original: box, corner: "nw", to: CGPoint(x: -2, y: -2))
        let next = try XCTUnwrap(NativePDFEditingGeometry.union(resized))
        XCTAssertEqual(next.minX, 0); XCTAssertEqual(next.minY, 0); XCTAssertLessThanOrEqual(next.maxX, 1); XCTAssertLessThanOrEqual(next.maxY, 1)
    }
    func testCrossPageMovePreservesPhysicalStrokeSizeGrabPointAndMetadata() throws {
        var row = stroke([["x": 0.2, "y": 0.3, "p": 0.7, "t": 123.5], ["x": 0.4, "y": 0.5, "p": 0.4, "t": 124.0]])
        row["page"] = 1
        let moved = NativePDFEditingGeometry.movedAcrossPages([row], from: CGSize(width: 600, height: 800),
            to: CGSize(width: 1200, height: 600), grabbedAt: CGPoint(x: 0.3, y: 0.4), droppedAt: CGPoint(x: 0.5, y: 0.5), page: 2)
        let value = try XCTUnwrap(moved.first), points = try XCTUnwrap((value["data"] as? [String: Any])?["points"] as? [[String: Any]])
        XCTAssertEqual(value["page"] as? Int, 2); XCTAssertEqual(value["id"] as? String, "ink")
        XCTAssertEqual(try XCTUnwrap(points[0]["x"] as? Double), 0.45, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(points[0]["y"] as? Double), 0.5 - 0.1 * 800 / 600, accuracy: 1e-9)
        XCTAssertEqual(points[0]["p"] as? Double, 0.7); XCTAssertEqual(points[0]["t"] as? Double, 123.5)
        XCTAssertEqual((value["style"] as? [String: Any])?["width"] as? Double, 0.0015)
        let edge = NativePDFEditingGeometry.movedAcrossPages([row], from: CGSize(width: 600, height: 800),
            to: CGSize(width: 600, height: 800), grabbedAt: CGPoint(x: 0.3, y: 0.4), droppedAt: CGPoint(x: -2, y: 4), page: 3)
        let bounds = try XCTUnwrap(NativePDFEditingGeometry.union(edge, aspect: 800.0 / 600))
        XCTAssertGreaterThanOrEqual(bounds.minX, -1e-9); XCTAssertLessThanOrEqual(bounds.maxY, 1 + 1e-9)
        XCTAssertEqual(bounds.width, try XCTUnwrap(NativePDFEditingGeometry.union([row], aspect: 800.0 / 600)).width, accuracy: 1e-9)
    }
    func testPaperRegionNeedsAreaAndClipsToPageWithoutInk() {
        XCTAssertNil(NativePDFEditingGeometry.regionBounds([CGPoint(x: 0.2, y: 0.2)]))
        XCTAssertNil(NativePDFEditingGeometry.regionBounds([CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.3, y: 0.2)]))
        let box = NativePDFEditingGeometry.regionBounds([CGPoint(x: -0.1, y: 0.2), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.6)])
        XCTAssertEqual(box?.minX, 0); XCTAssertEqual(box?.width, 0.5)
        XCTAssertEqual(box?.height ?? 0, 0.4, accuracy: 1e-9)
    }
    private func stroke(_ points: [[String: Any]]) -> [String: Any] { ["id": "ink", "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": ["color": "blue", "width": 0.003, "opacity": 1]] }
}
