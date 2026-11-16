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
    private func recognize(_ points: [NativePDFPoint], aspect: Double = 1.4) -> NativePDFShapeFigure? {
        NativePDFShapeRecognition.recognize(points, aspect: aspect)
    }

    // MARK: Recognition

    func testHandDrawnCorpusRecognizesEveryShapeAndLeavesLettersAlone() {
        var hits: [String: (ok: Int, total: Int)] = [:], wrong: [String: [String: Int]] = [:]
        for stroke in NativePDFShapeCorpus.positives(seed: 1, perShape: 120) {
            let name = recognize(stroke.points, aspect: NativePDFShapeCorpus.aspect)?.name ?? "nil", expected = stroke.expected!
            hits[expected, default: (0, 0)].total += 1
            if name == expected { hits[expected]!.ok += 1 } else { wrong[expected, default: [:]][stroke.variant + " → " + name, default: 0] += 1 }
        }
        XCTAssertEqual(hits.count, 11)
        for (shape, hit) in hits {
            XCTAssertGreaterThanOrEqual(Double(hit.ok) / Double(hit.total), 0.95, "\(shape): \(hit.ok)/\(hit.total) \(wrong[shape] ?? [:])")
        }
        // Letters written at handwriting size with a pause at the end stay handwriting.
        let letters = NativePDFShapeCorpus.letters(seed: 2)
        let converted = letters.compactMap { stroke in recognize(stroke.points, aspect: NativePDFShapeCorpus.aspect).map { stroke.variant + " → " + $0.name } }
        XCTAssertEqual(letters.count, 22 * 60)
        XCTAssertTrue(converted.isEmpty, "\(converted.count) letters became shapes: \(converted.prefix(10))")
        // So do large curved letters, which are no shape at any size.
        let curved = NativePDFShapeCorpus.letters(seed: 3, perLetter: 30, sizes: 80...200).filter { ["D", "2", "S", "C", "U", "e", "a", "3", "8"].contains($0.variant) }
        let curvedShapes = curved.compactMap { stroke in recognize(stroke.points, aspect: NativePDFShapeCorpus.aspect).map { stroke.variant + " → " + $0.name } }
        XCTAssertTrue(curvedShapes.isEmpty, "\(curvedShapes)")
    }

    func testSizeLimitsAreScreenPointsSoZoomingInDoesNotTurnLettersIntoShapes() throws {
        // A 0.12 page-width square: 72 pt on a 600 pt page, 216 pt when zoomed in to 1800 pt per page width.
        let square = edge((0.4, 0.3), (0.52, 0.3)) + edge((0.52, 0.3), (0.52, 0.386)) + edge((0.52, 0.386), (0.4, 0.386)) + edge((0.4, 0.386), (0.4, 0.3))
        XCTAssertNil(NativePDFShapeRecognition.recognize(square, aspect: 1.4, screenScale: 400), "48 pt on screen: a letter")
        XCTAssertEqual(NativePDFShapeRecognition.recognize(square, aspect: 1.4, screenScale: 1800)?.name, "square")
    }

    func testPhysicalGeometrySurvivesLandscapeAndPortraitCoordinates() throws {
        for aspect in [0.75, 1.0, 1.414, 2.0] {
            let circle = (0...96).map { i in
                let angle = Double(i) / 96 * .pi * 2
                return NativePDFPoint(x: 0.5 + 0.2 * cos(angle), y: 0.35 + 0.2 * sin(angle) / aspect, p: 0.5)
            }
            let figure = try XCTUnwrap(recognize(circle, aspect: aspect))
            XCTAssertEqual(figure.name, "circle")
            XCTAssertEqual(hypot(figure.axisA.x, figure.axisA.y), 0.2, accuracy: 0.004)
            let ink = figure.ink(aspect: aspect).points
            XCTAssertTrue(ink.allSatisfy(\.isValid))
            XCTAssertEqual(ink.map(\.x).max()! - ink.map(\.x).min()!, 0.4, accuracy: 0.008)
            XCTAssertEqual((ink.map(\.y).max()! - ink.map(\.y).min()!) * aspect, 0.4, accuracy: 0.008)
        }
    }

    func testCleanFiguresSnapNearlyAlignedNearlySquareAndNearlyRound() throws {
        // 3° off level and 4 % off square: an axis-aligned square.
        let turned = { (x: Double, y: Double) -> (Double, Double) in
            let a = 3 * Double.pi / 180, cx = 0.5, cy = 0.5
            return (cx + (x - cx) * cos(a) - (y - cy) * sin(a), cy + (x - cx) * sin(a) + (y - cy) * cos(a))
        }
        let corners = [(0.35, 0.35), (0.65, 0.35), (0.65, 0.662), (0.35, 0.662)].map(turned)
        let raw = (0..<4).flatMap { edge(corners[$0], corners[($0 + 1) % 4]) }
        let square = try XCTUnwrap(recognize(raw, aspect: 1))
        XCTAssertEqual(square.name, "square")
        for (a, b) in zip(square.pathCorners, square.pathCorners.dropFirst()) {
            XCTAssertTrue(abs(a.x - b.x) < 1e-9 || abs(a.y - b.y) < 1e-9, "Edges lie level or upright")
        }
        // 20° turned stays turned.
        let rotated = [(0.3, 0.3), (0.7, 0.3), (0.7, 0.5), (0.3, 0.5)].map { (x: Double, y: Double) -> (Double, Double) in
            let a = 20 * Double.pi / 180
            return (0.5 + (x - 0.5) * cos(a) - (y - 0.4) * sin(a), 0.4 + (x - 0.5) * sin(a) + (y - 0.4) * cos(a))
        }
        let rect = try XCTUnwrap(recognize((0..<4).flatMap { edge(rotated[$0], rotated[($0 + 1) % 4]) }, aspect: 1))
        XCTAssertEqual(rect.name, "rect")
        let folded = rect.orientation - floor(rect.orientation / (.pi / 2)) * (.pi / 2)
        XCTAssertEqual(min(folded, .pi / 2 - folded), 20 * .pi / 180, accuracy: 0.02)
        // A slightly oval loop is a circle.
        let oval = (0...96).map { i -> NativePDFPoint in
            let angle = Double(i) / 96 * .pi * 2
            return NativePDFPoint(x: 0.5 + 0.2 * cos(angle), y: 0.5 + 0.185 * sin(angle), p: 0.5)
        }
        XCTAssertEqual(recognize(oval, aspect: 1)?.name, "circle")
    }

    func testRetracingScribblesTinyMarksAndInvalidPagesStayInk() {
        let line = edge((0.1, 0.2), (0.7, 0.4))
        XCTAssertEqual(recognize(line + Array(repeating: line.last!, count: 1000))?.name, "line", "The resting tail does not bias the fit")
        let retrace = edge((0.1, 0.2), (0.7, 0.2)) + edge((0.7, 0.2), (0.3, 0.2)) + edge((0.3, 0.2), (0.8, 0.2))
        XCTAssertNil(recognize(retrace))
        XCTAssertNil(recognize(edge((0.1, 0.1), (0.105, 0.105))))
        XCTAssertNil(recognize(line, aspect: .nan))
    }

    // MARK: Saved form

    @MainActor
    func testSavedShapeIsEvenInkTheLivePreviewDrawsExactly() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 600, height: 840)), aspect = 1.4
        let rect = edge((0.2, 0.2), (0.7, 0.2)) + edge((0.7, 0.2), (0.7, 0.6)) + edge((0.7, 0.6), (0.2, 0.6)) + edge((0.2, 0.6), (0.2, 0.2))
        let ellipse = (0...96).map { i in NativePDFPoint(x: 0.5 + 0.25 * cos(Double(i) / 96 * .pi * 2), y: 0.4 + 0.1 * sin(Double(i) / 96 * .pi * 2), p: 0.5) }
        let triangle = edge((0.2, 0.7), (0.5, 0.3)) + edge((0.5, 0.3), (0.8, 0.7)) + edge((0.8, 0.7), (0.2, 0.7))
        for raw in [edge((0.1, 0.2), (0.7, 0.4)), rect, ellipse, triangle] {
            let figure = try XCTUnwrap(recognize(raw, aspect: aspect))
            let held = NativePDFHeldShape(figure, width: 0.0042, aspect: aspect)
            XCTAssertTrue(held.isValid)
            let fit = held.correction(kind: "ink", style: ["color": "blue", "width": 0.006, "opacity": 0.8])
            XCTAssertEqual(fit.kind, "ink")
            XCTAssertEqual(fit.data["inkVersion"] as? Int, 5)
            XCTAssertEqual(fit.style["width"] as? Double, 0.0042, "The stroke's own width, not the tool's")
            XCTAssertEqual(fit.style["fixedWidth"] as? Bool, true)
            XCTAssertEqual(fit.style["color"] as? String, "blue"); XCTAssertEqual(fit.style["opacity"] as? Double, 0.8)
            let row: [String: Any] = ["id": UUID().uuidString, "kind": fit.kind, "data": fit.data, "style": fit.style]
            // What every build draws for the row is what was previewed.
            let saved = try XCTUnwrap(NativePDFObjectRenderer.hitBounds(row, mapper: mapper))
            let live = NativePDFLiveInkGeometryCache().polygons(version: 4, points: raw, width: 0.006, aspect: aspect, highlighter: false, heldShape: held)
            XCTAssertEqual(live, NativePDFInkGeometryV5.polygons(points: held.points, width: 0.0042, aspect: aspect, highlighter: true))
            let vertices = live.flatMap { $0 }
            XCTAssertEqual(vertices.map(\.x).min()! * 600, saved.minX, accuracy: 0.05)
            XCTAssertEqual(vertices.map(\.x).max()! * 600, saved.maxX, accuracy: 0.05)
            XCTAssertEqual(vertices.map(\.y).min()! * 840, saved.minY, accuracy: 0.05)
            XCTAssertEqual(vertices.map(\.y).max()! * 840, saved.maxY, accuracy: 0.05)
            // It reads back as the same figure.
            let parsed = try XCTUnwrap(NativePDFShapeFigure(data: fit.data, aspect: aspect))
            XCTAssertEqual(parsed.kind, figure.kind)
            XCTAssertEqual(parsed.ink(aspect: aspect).points.count, held.points.count)
        }
        // A highlighter keeps its style; its fit is still a shape.
        let line = try XCTUnwrap(recognize(edge((0.1, 0.2), (0.7, 0.4))))
        let highlight = NativePDFHeldShape(line, width: 0.014, aspect: 1.4).correction(kind: "highlighter", style: ["color": "yellow", "width": 0.014, "opacity": 0.32])
        XCTAssertEqual(highlight.kind, "highlighter"); XCTAssertNil(highlight.style["fixedWidth"])
        XCTAssertNotNil(highlight.data["shape"])
    }

    func testJournalsFromBeforeShapesBecameInkKeepTheirOldCorrection() throws {
        let legacy = NativePDFHeldShape(kind: "line", points: [.init(x: 0.2, y: 0.3, p: 0.5), .init(x: 0.6, y: 0.5, p: 0.5)], box: [0.2, 0.3, 0.4, 0.2])
        XCTAssertTrue(legacy.isValid)
        let decoded = try JSONDecoder().decode(NativePDFHeldShape.self, from: JSONSerialization.data(withJSONObject: legacy.journalPayload))
        XCTAssertEqual(decoded, legacy)
        let fit = legacy.correction(kind: "ink", style: ["color": "ink", "width": 0.01, "opacity": 1])
        XCTAssertEqual(fit.kind, "line"); XCTAssertEqual(fit.style["width"] as? Double ?? 0, 0.006, accuracy: 1e-12)
        XCTAssertNil(fit.data["inkVersion"], "The validator rejects inkVersion on geometric shapes")
        // A new fit round-trips through the journal with its width and corners.
        let figure = try XCTUnwrap(recognize(edge((0.2, 0.7), (0.5, 0.3)) + edge((0.5, 0.3), (0.8, 0.7)) + edge((0.8, 0.7), (0.2, 0.7))))
        let held = NativePDFHeldShape(figure, width: 0.004, aspect: 1.4)
        XCTAssertEqual(try JSONDecoder().decode(NativePDFHeldShape.self, from: JSONSerialization.data(withJSONObject: held.journalPayload)), held)
    }

    func testFigureSurvivesMovesScalesAndPageRotationButNotAPartialErase() throws {
        let aspect = 1.4
        let figure = try XCTUnwrap(recognize(edge((0.2, 0.2), (0.6, 0.25)) + edge((0.6, 0.25), (0.55, 0.55)) + edge((0.55, 0.55), (0.15, 0.5)) + edge((0.15, 0.5), (0.2, 0.2)), aspect: aspect))
        let held = NativePDFHeldShape(figure, width: 0.004, aspect: aspect)
        let data = held.correction(kind: "ink", style: ["color": "ink", "width": 0.006, "opacity": 1]).data
        XCTAssertNotNil(NativePDFShapeFigure(data: data, aspect: aspect))
        func mapped(_ body: (Double, Double) -> (Double, Double)) -> [String: Any] {
            var next = data
            next["points"] = (data["points"] as! [[String: Any]]).map { point -> [String: Any] in
                var point = point; let (x, y) = body(point["x"] as! Double, point["y"] as! Double); point["x"] = x; point["y"] = y; return point
            }
            return next
        }
        // A lasso move, a proportional resize, a free one, and sync's rotation of the page frame.
        XCTAssertNotNil(NativePDFShapeFigure(data: mapped { ($0 + 0.1, $1 + 0.05) }, aspect: aspect))
        XCTAssertNotNil(NativePDFShapeFigure(data: mapped { (0.1 + ($0 - 0.1) * 1.3, 0.1 + ($1 - 0.1) * 1.3) }, aspect: aspect))
        XCTAssertNotNil(NativePDFShapeFigure(data: mapped { ($0 * 0.8, $1 * 1.1) }, aspect: aspect))
        XCTAssertNotNil(NativePDFShapeFigure(data: mapped { ($1, 1 - $0) }, aspect: 1 / aspect))
        // A piece the partial eraser left, or a row whose points were redrawn, is ink.
        var cut = data; cut["points"] = Array((data["points"] as! [[String: Any]]).prefix(40))
        XCTAssertNil(NativePDFShapeFigure(data: cut, aspect: aspect))
        var bent = data, points = data["points"] as! [[String: Any]]
        points[5]["x"] = (points[5]["x"] as! Double) + 0.01; bent["points"] = points
        XCTAssertNil(NativePDFShapeFigure(data: bent, aspect: aspect))
        var plain = data; plain.removeValue(forKey: "shape")
        XCTAssertNil(NativePDFShapeFigure(data: plain, aspect: aspect))
    }

    func testValidatorKeepsAShapeDescriptorAndDropsAMalformedOneWithoutLosingTheInk() throws {
        let figure = try XCTUnwrap(recognize(edge((0.1, 0.2), (0.7, 0.4))))
        let data = NativePDFHeldShape(figure, width: 0.004, aspect: 1.4).correction(kind: "ink", style: [:]).data
        let kept = try NativePDFRepositoryValidation.data(data, kind: "ink")
        XCTAssertEqual(kept["shape"] as? NSDictionary, data["shape"] as? NSDictionary)
        XCTAssertEqual((kept["points"] as? [Any])?.count, (data["points"] as? [Any])?.count)
        for broken: Any in [["type": "star", "corners": [0, 1]], ["type": "line", "corners": [0, 3]], ["type": "ellipse", "segments": 96], "line", ["type": "line", "corners": [true, 1]]] {
            var bad = data; bad["shape"] = broken
            let value = try NativePDFRepositoryValidation.data(bad, kind: "ink")
            XCTAssertNil(value["shape"], "\(broken)")
            XCTAssertNotNil(value["points"])
        }
        // Only ink and highlighter rows carry one.
        var tape = data; tape.removeValue(forKey: "inkVersion")
        XCTAssertNil(try NativePDFRepositoryValidation.data(tape, kind: "tape")["shape"])
    }

    // MARK: Thickness

    /// The drawn stroke and the shape it becomes, rendered by the saved-row renderer, measured in pixels across
    /// the middle of a level line.
    @MainActor
    func testShapeIsAsThickAsTheDrawnStrokeForEveryPenAndPressure() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 600, height: 840)), aspect = 1.4
        struct Pen { var name: String; var kind: String; var version: Int; var style: NativePDFInkStyle; var pressure: (Double) -> Double }
        let pens = [
            Pen(name: "펜", kind: "ink", version: 4, style: .init(color: "ink", width: 0.006, opacity: 1), pressure: { $0 }),
            Pen(name: "볼펜", kind: "ink", version: 5, style: .init(color: "ink", width: 0.006, opacity: 1, fixedWidth: true), pressure: { $0 }),
            Pen(name: "붓", kind: "ink", version: 5, style: .init(color: "ink", width: 0.008, opacity: 1), pressure: NativePDFInkSurface.brushPressure),
            Pen(name: "V5 펜", kind: "ink", version: 5, style: .init(color: "ink", width: 0.006, opacity: 1), pressure: { $0 }),
            Pen(name: "형광펜", kind: "highlighter", version: 5, style: .init(color: "yellow", width: 0.02, opacity: 1), pressure: { $0 })
        ]
        /// The stroke's thickness at 4×, anti-aliasing included: the darkness summed down a column, the median of
        /// 21 columns across the middle third of the line (pressure varies along a hand's stroke).
        func thickness(_ row: [String: Any], ink: UIColor) -> Double {
            let scale = 4.0
            let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 840), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 840))
                NativePDFObjectRenderer.draw(row, in: context.cgContext, mapper: mapper, image: nil)
            }
            guard let cg = image.cgImage, let pixels = cg.dataProvider?.data as Data? else { return 0 }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ink.getRed(&r, green: &g, blue: &b, alpha: &a)
            let full = 1 - Double(min(r, g, b))
            let stride = cg.bytesPerRow, channels = cg.bitsPerPixel / 8
            let sums = (0...20).map { step -> Double in
                let column = Int((240 + 6 * Double(step)) * scale)
                var sum = 0.0
                for line in 0..<cg.height {
                    let offset = line * stride + column * channels
                    let darkest = (0..<min(3, channels)).map { Double(pixels[offset + $0]) / 255 }.min() ?? 1
                    sum += (1 - darkest) / full
                }
                return sum / scale
            }.sorted()
            return sums[sums.count / 2]
        }
        for pen in pens {
            for raw in [0.12, 0.3, 0.6] {
                // A level stroke across the page at Pencil speed, then the pause.
                var points = (0...150).map { i -> NativePDFPoint in
                    NativePDFPoint(x: 0.2 + 0.6 * Double(i) / 150, y: 0.4, p: pen.pressure(raw * (0.95 + 0.1 * sin(Double(i) / 7))), t: Double(i) * 6)
                }
                let rest = points.count - 1
                points += (1...40).map { NativePDFPoint(x: 0.8, y: 0.4, p: pen.pressure(raw * 1.6), t: Double(150 + $0) * 6) }
                let freehand: [String: Any] = ["id": UUID().uuidString, "kind": pen.kind,
                    "data": ["points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p, "t": $0.t!] }, "inkVersion": pen.version],
                    "style": ["color": pen.style.color, "width": pen.style.width, "opacity": 1.0, "fixedWidth": pen.style.fixedWidth ?? false]]
                let width = NativePDFHeldShape.measuredWidth(points: Array(points.prefix(rest + 1)), style: pen.style, inkVersion: pen.version,
                                                             highlighter: pen.kind == "highlighter", aspect: aspect)
                let figure = try XCTUnwrap(recognize(points, aspect: aspect), pen.name)
                let fit = NativePDFHeldShape(figure, width: width, aspect: aspect).correction(kind: pen.kind,
                    style: ["color": pen.style.color, "width": pen.style.width, "opacity": 1.0])
                let shape: [String: Any] = ["id": UUID().uuidString, "kind": fit.kind, "data": fit.data, "style": fit.style]
                let ink = NativePDFObjectRenderer.color(pen.style.color)
                let drawn = thickness(freehand, ink: ink), snapped = thickness(shape, ink: ink)
                XCTAssertGreaterThan(drawn, 1, "\(pen.name) \(raw)")
                XCTAssertEqual(snapped / drawn, 1, accuracy: 0.1, "\(pen.name) at pressure \(raw): drawn \(drawn) pt, shape \(snapped) pt")
            }
        }
    }

    // MARK: Adjusting with the pen

    func testPenStillDownSizesAndTurnsTheShape() throws {
        let line = NativePDFShapeFigure(kind: .line, name: "line", vertices: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.2)])
        // The start stays; the end goes where the pen goes.
        var moved = line.adjusted(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.4, y: 0.5), minimumSize: 0.01)
        XCTAssertEqual(moved.figure.vertices[0], CGPoint(x: 0.2, y: 0.2))
        XCTAssertEqual(moved.figure.vertices[1].x, 0.4, accuracy: 1e-9); XCTAssertEqual(moved.figure.vertices[1].y, 0.5, accuracy: 1e-9)
        XCTAssertFalse(moved.snapped)
        // 3° off upright snaps upright and keeps the length.
        let pen = CGPoint(x: 0.2 + 0.3 * sin(3 * .pi / 180), y: 0.2 + 0.3 * cos(3 * .pi / 180))
        moved = line.adjusted(from: CGPoint(x: 0.5, y: 0.2), to: pen, minimumSize: 0.01)
        XCTAssertTrue(moved.snapped)
        XCTAssertEqual(moved.figure.vertices[1].x, 0.2, accuracy: 1e-9); XCTAssertEqual(moved.figure.vertices[1].y, 0.5, accuracy: 1e-9)
        // A rectangle keeps its centre, grows with the pen's distance and turns with it.
        let rect = NativePDFShapeFigure(kind: .polygon, name: "rect", vertices: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.3, y: 0.4)])
        let grab = CGPoint(x: 0.5, y: 0.4), centre = rect.pivot
        let far = CGPoint(x: centre.x + (grab.x - centre.x) * 2 * cos(0.5) - (grab.y - centre.y) * 2 * sin(0.5),
                          y: centre.y + (grab.x - centre.x) * 2 * sin(0.5) + (grab.y - centre.y) * 2 * cos(0.5))
        let grown = rect.adjusted(from: grab, to: far, minimumSize: 0.01).figure
        XCTAssertEqual(grown.pivot.x, centre.x, accuracy: 1e-9); XCTAssertEqual(grown.pivot.y, centre.y, accuracy: 1e-9)
        XCTAssertEqual(hypot(grown.vertices[1].x - grown.vertices[0].x, grown.vertices[1].y - grown.vertices[0].y), 0.4, accuracy: 1e-9)
        XCTAssertEqual(NativePDFShapeFigure.wrap(grown.orientation), 0.5, accuracy: 1e-9)
        // Turned 43°: it settles on 45°.
        let near45 = CGPoint(x: centre.x + (grab.x - centre.x) * cos(0.75) - (grab.y - centre.y) * sin(0.75),
                             y: centre.y + (grab.x - centre.x) * sin(0.75) + (grab.y - centre.y) * cos(0.75))
        let settled = rect.adjusted(from: grab, to: near45, minimumSize: 0.01)
        XCTAssertTrue(settled.snapped)
        XCTAssertEqual(NativePDFShapeFigure.wrap(settled.figure.orientation), .pi / 4, accuracy: 1e-9)
        // A circle only grows; an arrow's head keeps its size.
        let circle = NativePDFShapeFigure(kind: .ellipse, name: "circle", center: CGPoint(x: 0.5, y: 0.5), axisA: CGPoint(x: 0.1, y: 0), axisB: CGPoint(x: 0, y: 0.1))
        let bigger = circle.adjusted(from: CGPoint(x: 0.6, y: 0.5), to: CGPoint(x: 0.5, y: 0.65), minimumSize: 0.01).figure
        XCTAssertEqual(bigger.axisA.x, 0.15, accuracy: 1e-9); XCTAssertEqual(bigger.axisA.y, 0, accuracy: 1e-9)
        let wings = NativePDFShapeFigure.arrowWings(tail: CGPoint(x: 0.1, y: 0.5), tip: CGPoint(x: 0.4, y: 0.5))
        let arrow = NativePDFShapeFigure(kind: .arrow, name: "arrow", vertices: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.4, y: 0.5), wings.0, wings.1])
        let longer = arrow.adjusted(from: CGPoint(x: 0.4, y: 0.5), to: CGPoint(x: 0.6, y: 0.37), minimumSize: 0.01).figure
        XCTAssertEqual(longer.vertices[0], arrow.vertices[0])
        XCTAssertEqual(hypot(longer.vertices[2].x - longer.vertices[1].x, longer.vertices[2].y - longer.vertices[1].y),
                       hypot(wings.0.x - 0.4, wings.0.y - 0.5), accuracy: 1e-9)
    }
}
