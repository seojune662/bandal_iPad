import XCTest
@testable import Bandal

final class NativePDFEditingGeometryTests: XCTestCase {
    func testStrokeHitUsesMeasuredPathRatherThanEmptyBoundingBox() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        XCTAssertNil(NativePDFEditingGeometry.hit(CGPoint(x: 0.1, y: 0.9), rows: [row], aspect: 1.4))
        XCTAssertEqual(NativePDFEditingGeometry.hit(CGPoint(x: 0.5, y: 0.5), rows: [row], aspect: 1.4), "ink")
    }
    func testLassoNeedsMostOfAStrokeInsideAndRejectsGrazingAndEmptyInterior() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        let grazing = [CGPoint(x: 0.45, y: 0.45), CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.55, y: 0.55), CGPoint(x: 0.45, y: 0.55)]
        XCTAssertTrue(NativePDFEditingGeometry.lasso(grazing, rows: [row], aspect: 1.4).isEmpty, "Crossing a stroke no longer picks it up")
        let most = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.95, y: 0.3), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.3, y: 0.95)]
        XCTAssertEqual(NativePDFEditingGeometry.lasso(most, rows: [row], aspect: 1.4), ["ink"], "Three quarters of its length is inside")
        let empty = [CGPoint(x: 0.08, y: 0.85), CGPoint(x: 0.15, y: 0.85), CGPoint(x: 0.15, y: 0.95), CGPoint(x: 0.08, y: 0.95)]
        XCTAssertTrue(NativePDFEditingGeometry.lasso(empty, rows: [row], aspect: 1.4).isEmpty)
        let text: [String: Any] = ["id": "t", "kind": "textbox", "data": ["box": ["x": 0.2, "y": 0.2, "width": 0.4, "height": 0.1]], "style": ["width": 0.002]]
        XCTAssertEqual(NativePDFEditingGeometry.lasso(most.map { CGPoint(x: $0.x - 0.2, y: $0.y - 0.15) }, rows: [text], aspect: 1.4), ["t"], "A box joins when its centre is inside")
    }
    func testBoxLassoAroundAStrokeSelectsItAndPortableRowsDropIdentityAndImages() {
        let row = stroke([["x": 0.1, "y": 0.1, "p": 0.4], ["x": 0.9, "y": 0.9, "p": 0.8]])
        let start = CGPoint(x: 0.05, y: 0.95), end = CGPoint(x: 0.95, y: 0.05)
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
        XCTAssertGreaterThanOrEqual(next.minX, -1e-9); XCTAssertGreaterThanOrEqual(next.minY, -1e-9)
        XCTAssertLessThanOrEqual(next.maxX, 1); XCTAssertLessThanOrEqual(next.maxY, 1)
        XCTAssertEqual(next.width / next.height, box.width / box.height, accuracy: 1e-6, "Resizing keeps the proportions")
        XCTAssertEqual(min(next.minX, next.minY), 0, accuracy: 1e-9, "It grows until one side reaches the page edge")
    }
    func testProportionalResizeScalesStrokeWidthButNotTextGeometry() throws {
        let line = stroke([["x": 0.2, "y": 0.2, "p": 0.5], ["x": 0.4, "y": 0.3, "p": 0.5]])
        let box = try XCTUnwrap(NativePDFEditingGeometry.union([line]))
        let doubled = try XCTUnwrap(NativePDFEditingGeometry.resized([line], original: box, corner: "se",
            to: CGPoint(x: box.minX + box.width * 2, y: box.minY + box.height * 2)).first)
        let width = try XCTUnwrap(((line["style"] as? [String: Any])?["width"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(try XCTUnwrap(((doubled["style"] as? [String: Any])?["width"] as? NSNumber)?.doubleValue), width * 2, accuracy: 1e-9)
        let grown = try XCTUnwrap(NativePDFEditingGeometry.union([doubled]))
        XCTAssertEqual(grown.minX, box.minX, accuracy: 1e-9, "The opposite corner stays")
        XCTAssertEqual(NativePDFEditingGeometry.corner(at: CGPoint(x: box.maxX, y: box.maxY), box: box, aspect: 1), "se")
        XCTAssertNil(NativePDFEditingGeometry.corner(at: CGPoint(x: box.minX, y: box.minY), box: box, aspect: 1), "Only the drawn handle resizes")
        XCTAssertEqual(NativePDFEditingGeometry.corner(at: CGPoint(x: box.minX, y: box.midY), box: box, aspect: 1, sides: true), "w")
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
    // MARK: Shapes

    private func shape(_ figure: NativePDFShapeFigure, id: String, aspect: Double = 1.4) -> [String: Any] {
        let fit = NativePDFHeldShape(figure, width: 0.004, aspect: aspect).correction(kind: "ink", style: ["color": "blue", "width": 0.006, "opacity": 1])
        return ["id": id, "page": 1, "kind": fit.kind, "data": fit.data, "style": fit.style]
    }
    private let box = NativePDFShapeFigure(kind: .polygon, name: "rect", vertices: [CGPoint(x: 0.2, y: 0.28), CGPoint(x: 0.6, y: 0.28), CGPoint(x: 0.6, y: 0.56), CGPoint(x: 0.2, y: 0.56)])

    func testTappingAShapeFindsItsLineFirstThenWhatItEncloses() {
        let rect = shape(box, id: "rect"), ink = stroke([["x": 0.3, "y": 0.3, "p": 0.5], ["x": 0.4, "y": 0.32, "p": 0.5]])
        // Page coordinates: the rectangle spans y 0.2...0.4 on a 1.4 page.
        XCTAssertEqual(NativePDFEditingGeometry.shapeHit(CGPoint(x: 0.4, y: 0.205), rows: [rect], aspect: 1.4, tolerance: 0.012), "rect")
        XCTAssertNil(NativePDFEditingGeometry.shapeHit(CGPoint(x: 0.4, y: 0.3), rows: [rect], aspect: 1.4, tolerance: 0.012), "Inside is only for the Pencil")
        XCTAssertEqual(NativePDFEditingGeometry.shapeHit(CGPoint(x: 0.4, y: 0.3), rows: [rect], aspect: 1.4, tolerance: 0.012, interior: true), "rect")
        // Handwriting inside the box is found by the ordinary hit before the box's interior.
        XCTAssertEqual(NativePDFEditingGeometry.hit(CGPoint(x: 0.35, y: 0.31), rows: [ink, rect], aspect: 1.4), "ink")
        XCTAssertNil(NativePDFEditingGeometry.shapeHit(CGPoint(x: 0.35, y: 0.31), rows: [ink], aspect: 1.4, tolerance: 0.012, interior: true),
                     "Handwriting is not a shape")
        // A shape the eraser cut, or an older build rewrote, is handwriting.
        var cut = rect, data = rect["data"] as! [String: Any]
        data["points"] = Array((data["points"] as! [Any]).prefix(30)); cut["data"] = data
        XCTAssertNil(NativePDFEditingGeometry.shapeHit(CGPoint(x: 0.4, y: 0.205), rows: [cut], aspect: 1.4, tolerance: 0.012))
    }

    func testOneShapeGetsFreeCornersOrLineEndsAndAGroupKeepsOneProportionalHandle() {
        let rect = shape(box, id: "rect")
        let line = shape(NativePDFShapeFigure(kind: .line, name: "line", vertices: [CGPoint(x: 0.1, y: 0.14), CGPoint(x: 0.5, y: 0.7)]), id: "line")
        XCTAssertEqual(NativePDFEditingGeometry.handles(for: [rect], aspect: 1.4, text: false).mode, "corners")
        let ends = NativePDFEditingGeometry.handles(for: [line], aspect: 1.4, text: false)
        XCTAssertEqual(ends.mode, "ends")
        XCTAssertEqual(ends.ends[0].x, 0.1, accuracy: 1e-9); XCTAssertEqual(ends.ends[0].y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ends.ends[1].x, 0.5, accuracy: 1e-9); XCTAssertEqual(ends.ends[1].y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(NativePDFEditingGeometry.handles(for: [rect, line], aspect: 1.4, text: false).mode, "corner")
        XCTAssertEqual(NativePDFEditingGeometry.handles(for: [stroke([["x": 0.1, "y": 0.1, "p": 0.5], ["x": 0.2, "y": 0.2, "p": 0.5]])], aspect: 1.4, text: false).mode, "corner")
        XCTAssertEqual(NativePDFEditingGeometry.handlePoints(mode: "corners", box: CGRect(x: 0, y: 0, width: 1, height: 1), ends: []).map(\.0), ["nw", "ne", "se", "sw"])
    }

    func testCornerHandleStretchesOneShapeFreelyAndKeepsItsWidth() throws {
        let rect = shape(box, id: "rect")
        let bounds = try XCTUnwrap(NativePDFEditingGeometry.union([rect], aspect: 1.4))
        // Drag the north-east corner up and right: wider and taller, by different amounts.
        let target = CGPoint(x: bounds.maxX + 0.1, y: bounds.minY - 0.1)
        let stretched = try XCTUnwrap(NativePDFEditingGeometry.reshaped([rect], handle: "ne", original: bounds, to: target, aspect: 1.4)?.first)
        let after = try XCTUnwrap(NativePDFEditingGeometry.union([stretched], aspect: 1.4))
        XCTAssertEqual(after.minX, bounds.minX, accuracy: 0.002, "The opposite corner stays")
        XCTAssertEqual(after.maxY, bounds.maxY, accuracy: 0.002)
        XCTAssertEqual(after.maxX, target.x, accuracy: 0.003); XCTAssertEqual(after.minY, target.y, accuracy: 0.003)
        XCTAssertNotEqual(after.width / bounds.width, after.height / bounds.height, accuracy: 0.05, "Free proportions")
        XCTAssertEqual((stretched["style"] as? [String: Any])?["width"] as? Double, 0.004, "The line's width never changes")
        let figure = try XCTUnwrap(NativePDFShapeFigure(data: stretched["data"] as! [String: Any], aspect: 1.4), "Still a shape")
        XCTAssertEqual(figure.name, "rect")
        // A line moves one end; the other stays.
        let line = shape(NativePDFShapeFigure(kind: .line, name: "line", vertices: [CGPoint(x: 0.1, y: 0.14), CGPoint(x: 0.5, y: 0.7)]), id: "line")
        let lineBounds = try XCTUnwrap(NativePDFEditingGeometry.union([line], aspect: 1.4))
        let moved = try XCTUnwrap(NativePDFEditingGeometry.reshaped([line], handle: "end1", original: lineBounds, to: CGPoint(x: 0.7, y: 0.2), aspect: 1.4)?.first)
        let movedFigure = try XCTUnwrap(NativePDFShapeFigure(data: moved["data"] as! [String: Any], aspect: 1.4))
        XCTAssertEqual(movedFigure.vertices[0].x, 0.1, accuracy: 1e-9); XCTAssertEqual(movedFigure.vertices[0].y, 0.14, accuracy: 1e-9)
        XCTAssertEqual(movedFigure.vertices[1].x, 0.7, accuracy: 1e-9); XCTAssertEqual(movedFigure.vertices[1].y, 0.28, accuracy: 1e-9)
        // Handwriting and groups are not reshaped.
        XCTAssertNil(NativePDFEditingGeometry.reshaped([stroke([["x": 0.1, "y": 0.1, "p": 0.5], ["x": 0.2, "y": 0.2, "p": 0.5]])], handle: "ne", original: bounds, to: target, aspect: 1.4))
        XCTAssertNil(NativePDFEditingGeometry.reshaped([rect, line], handle: "ne", original: bounds, to: target, aspect: 1.4))
    }
    private func stroke(_ points: [[String: Any]]) -> [String: Any] { ["id": "ink", "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": ["color": "blue", "width": 0.003, "opacity": 1]] }
}
