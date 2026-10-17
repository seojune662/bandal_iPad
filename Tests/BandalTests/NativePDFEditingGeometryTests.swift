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
    private func stroke(_ points: [[String: Any]]) -> [String: Any] { ["id": "ink", "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": ["color": "blue", "width": 0.003, "opacity": 1]] }
}
