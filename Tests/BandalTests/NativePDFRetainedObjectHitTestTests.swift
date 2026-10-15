import XCTest
import CoreGraphics
@testable import Bandal

/// Independent analytic controls for the approved mixed-object policy. These
/// are pure geometry tests, not UIKit/Pencil delivery or GPU presentation tests.
final class NativePDFRetainedObjectHitTestTests: XCTestCase {
    private typealias Hit = NativePDFRetainedObjectHitTest
    private let square: [String: Double] = ["x": 0.2, "y": 0.2, "width": 0.4, "height": 0.4]

    func testOnlyTextboxErasesItsInteriorWhileAllBoxKindsEraseEdgesAtZeroOpacity() throws {
        for kind in ["rect", "ellipse", "textbox", "image", "clip"] {
            let entry = try entry(kind, data: ["box": square], opacity: 0)
            XCTAssertEqual(hit(entry, 0.4, 0.4), kind == "textbox", kind)
            XCTAssertTrue(hit(entry, 0.2, 0.4), kind)
            XCTAssertTrue(hit(entry, 0.193001, 0.4), kind)
            XCTAssertFalse(hit(entry, 0.192999, 0.4), kind)
        }
    }

    func testArrowWingAndIntermediatePointAreNotItsHitGeometry() throws {
        let arrow = try entry("arrow", data: ["points": [point(0.2,0.5),point(0.5,0.8),point(0.8,0.5)]], width: 0.02)
        XCTAssertTrue(hit(arrow, 0.5, 0.5))
        XCTAssertFalse(hit(arrow, 0.5, 0.8), "Only the first/last points define the shaft")
        // Visible head length=max(4*.02,.012)=.08; its wing is .04 away
        // from the shaft, beyond the independent .015 hit threshold.
        XCTAssertFalse(hit(arrow, 0.8 - 0.08 * cos(.pi / 6), 0.54))
        let line = try entry("line", data: ["points": [point(0.2,0.5),point(0.8,0.5)], "box": square])
        XCTAssertFalse(hit(line, 0.2, 0.2), "Valid endpoints take precedence over a conflicting box")
        let fallback = try entry("arrow", data: ["points": [point(0.9,0.1)], "box": square])
        XCTAssertTrue(hit(fallback, 0.4, 0.4)); XCTAssertFalse(hit(fallback, 0.9, 0.1))
    }

    func testEllipseUsesThirtyTwoChordsRatherThanIdealCurveOrFilledBounds() throws {
        let ellipse = try entry("ellipse", data: ["box": ["x": 0.3,"y": 0.3,"width": 0.4,"height": 0.4]])
        let angle = Double.pi / 32, radius = 0.2 + 0.007 - 0.00001
        let point = CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
        XCTAssertLessThan(radius - 0.2, 0.007, "An ideal circle would hit")
        XCTAssertGreaterThan(radius - 0.2 * cos(angle), 0.007, "The 32-chord polygon must miss")
        XCTAssertTrue(Hit.hits(entries: [ellipse], points: [point]).isEmpty)
        XCTAssertTrue(hit(ellipse, 0.7, 0.5)); XCTAssertFalse(hit(ellipse, 0.5, 0.5))
        XCTAssertEqual(ellipse.geometry.pointCount, 33)
    }

    func testWidthThresholdAndAspectUsePageWidthUnits() throws {
        let data: [String: Any] = ["points": [point(0.2,0.5),point(0.8,0.5)]]
        for aspect in [0.5,1.0,2.0] {
            let thin = try entry("line", data: data, aspect: aspect)
            XCTAssertEqual(thin.geometry.threshold, 0.007)
            XCTAssertTrue(hit(thin, 0.5, 0.5 + 0.006999 / aspect))
            XCTAssertFalse(hit(thin, 0.5, 0.5 + 0.007001 / aspect))
            let thick = try entry("line", data: data, width: 0.02, aspect: aspect)
            XCTAssertEqual(thick.geometry.threshold, 0.015)
            XCTAssertTrue(hit(thick, 0.5, 0.5 + 0.014999 / aspect))
            XCTAssertFalse(hit(thick, 0.5, 0.5 + 0.015001 / aspect))
        }
        let vertical = try entry("line", data: ["points": [point(0.5,0.2),point(0.5,0.8)]], aspect: 2)
        XCTAssertTrue(hit(vertical, 0.506999, 0.5)); XCTAssertFalse(hit(vertical, 0.507001, 0.5))
        let origin = try entry("ink", data: ["points": [point(0,0)]])
        XCTAssertTrue(hit(origin, 0.007, 0), "The threshold is inclusive")
        XCTAssertFalse(hit(origin, Double(0.007).nextUp, 0))
    }

    func testLegacyRawPolylineIgnoresPressureAndModernInkStaysWithExistingPolicy() throws {
        for kind in ["ink", "highlighter"] {
            for pressure in [0.0,1.0] {
                let legacy = try entry(kind, data: ["points": [point(0.2,0.2,p: pressure),point(0.2,0.8,p: pressure),point(0.8,0.8,p: pressure)]])
                XCTAssertTrue(hit(legacy, 0.206999, 0.5))
                XCTAssertFalse(hit(legacy, 0.207001, 0.5))
                XCTAssertFalse(hit(legacy, 0.5, 0.5), "Bounding-box inclusion is not a hit")
            }
            for version in [2,3,4,5,99] {
                XCTAssertNil(Hit.prepare(object: object(kind, data: ["inkVersion": version,"points": [point(0.5,0.5)]]), aspect: 1))
            }
        }
    }

    func testContinuousSweepAndPreviousEventCrossingDeleteWithoutEndpointHits() throws {
        let entries = try ["rect", "ellipse", "textbox", "image", "clip"].map {
            try entry($0, data: ["box": square], id: $0)
        }
        let start = CGPoint(x: 0.1,y: 0.4), end = CGPoint(x: 0.9,y: 0.4)
        XCTAssertTrue(Hit.hits(entries: entries, points: [start]).isEmpty)
        XCTAssertTrue(Hit.hits(entries: entries, points: [end]).isEmpty)
        XCTAssertEqual(Hit.hits(entries: entries, points: [start,end]).map(\.savedID), entries.map(\.savedID))
        XCTAssertEqual(Hit.hits(entries: entries, points: [end], previous: start).map(\.savedID), entries.map(\.savedID))
        let textbox = entries[2], inside = [CGPoint(x: 0.3,y: 0.3),CGPoint(x: 0.5,y: 0.5)]
        XCTAssertEqual(Hit.hits(entries: entries, points: inside).map(\.savedID), [textbox.savedID],
                       "A sweep wholly inside an outlined box must not erase that outline")
    }

    func testMeasuredCoalescedBendIsNotReplacedByEndpointChord() throws {
        let row = try entry("line", data: ["points": [point(0.1,0.2),point(0.1,0.8)]])
        let points = [CGPoint(x: 0.5,y: 0.3),CGPoint(x: 0.105,y: 0.5),CGPoint(x: 0.5,y: 0.7)]
        XCTAssertEqual(Hit.hits(entries: [row], points: points).count, 1)
        XCTAssertTrue(Hit.hits(entries: [row], points: [points[0],points[2]]).isEmpty)
    }

    func testZeroBoxesAndStationaryLegacyDotsRemainValidGeometry() throws {
        for kind in ["line", "arrow", "rect", "ellipse", "textbox", "image", "clip"] {
            let row = try entry(kind, data: ["box": ["x": 0.5,"y": 0.5,"width": 0.0,"height": 0.0]])
            XCTAssertTrue(hit(row, 0.506999, 0.5), kind)
            XCTAssertFalse(hit(row, 0.507001, 0.5), kind)
        }
        let dot = try entry("ink", data: ["points": [point(0.5,0.5)]])
        XCTAssertTrue(hit(dot, 0.506999, 0.5)); XCTAssertFalse(hit(dot, 0.507001, 0.5))
        XCTAssertEqual(Hit.hits(entries: [dot], points: [CGPoint(x: 0.9,y: 0.5)], previous: CGPoint(x: 0.1,y: 0.5)).count, 1)
    }

    func testPreparationCopiesMutableInputAndReprepareReflectsSameContainerEdit() throws {
        let first = NSMutableDictionary(dictionary: point(0.2,0.5))
        let last = NSMutableDictionary(dictionary: point(0.8,0.5))
        let points = NSMutableArray(array: [first,last])
        let data = NSMutableDictionary(dictionary: ["points": points])
        let source = object("ink", data: try XCTUnwrap(data as? [String: Any]))
        let old = try XCTUnwrap(Hit.prepare(object: source, aspect: 1))
        first["y"] = 0.8; last["y"] = 0.8
        // Rebuild the dictionary view from the same mutable owner, as the caller
        // does when an immutable row revision is replaced.
        let current = object("ink", data: try XCTUnwrap(data as? [String: Any]))
        let new = try XCTUnwrap(Hit.prepare(object: current, aspect: 1))
        let oldEntry = Hit.Entry(savedID: "same", mutationID: nil, geometry: old)
        let newEntry = Hit.Entry(savedID: "same", mutationID: nil, geometry: new)
        XCTAssertTrue(hit(oldEntry, 0.5, 0.5)); XCTAssertFalse(hit(oldEntry, 0.5, 0.8))
        XCTAssertFalse(hit(newEntry, 0.5, 0.5)); XCTAssertTrue(hit(newEntry, 0.5, 0.8))
        XCTAssertEqual(first["y"] as? Double, 0.8, "Preparation must not rewrite source geometry")
    }

    func testExactUTF8IdentityAliasAndSceneOrderArePreserved() throws {
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        let geometry = try XCTUnwrap(Hit.prepare(object: object("textbox", data: ["box": square]), aspect: 1))
        let a = Hit.Entry(savedID: composed, mutationID: "M-a", geometry: geometry)
        let b = Hit.Entry(savedID: decomposed, mutationID: "M-b", geometry: geometry)
        let result = Hit.hits(entries: [b,a], points: [CGPoint(x: 0.4,y: 0.4)])
        XCTAssertEqual(result.map { Data($0.savedID.utf8) }, [Data(decomposed.utf8),Data(composed.utf8)])
        XCTAssertEqual(result.map(\.mutationID), ["M-b","M-a"])
        XCTAssertTrue(result.allSatisfy { $0.geometry === geometry })
    }

    func testMalformedGeometryNeverBecomesLocationlessGlobalDeletion() throws {
        let invalid: [[String: Any]] = [
            object("ink", data: [:]), object("ink", data: ["points": []]),
            object("ink", data: ["points": [],"box": square]),
            object("ink", data: ["points": [point(0.1,0.1),point(.nan,0.5),point(0.9,0.9)]]),
            object("line", data: ["points": "bad", "box": square]),
            object("rect", data: [:]), object("unknown", data: ["box": square]),
            object("rect", data: ["box": ["x": 0.2,"y": 0.2,"width": -0.1,"height": 0.2]]),
            object("rect", data: ["box": ["x": true,"y": 0.2,"width": 0.1,"height": 0.2]]),
            object("rect", data: ["box": square], width: .infinity),
            object("rect", data: ["box": square], width: 0)
        ]
        for row in invalid { XCTAssertNil(Hit.prepare(object: row, aspect: 1)) }
        var booleanWidth = object("rect", data: ["box": square]); booleanWidth["style"] = ["width": true]
        XCTAssertNil(Hit.prepare(object: booleanWidth, aspect: 1))
        for aspect in [0.0,-1,.nan,.infinity] { XCTAssertNil(Hit.prepare(object: object("rect", data: ["box": square]), aspect: aspect)) }
        XCTAssertNil(Hit.prepare(object: object("ink", data: ["points": [point(0.1,Double.greatestFiniteMagnitude)]]), aspect: 2))
        let valid = try entry("line", data: ["points": [point(0.1,0.5),point(0.9,0.5)]])
        XCTAssertTrue(Hit.hits(entries: [valid], points: []).isEmpty)
        XCTAssertTrue(Hit.hits(entries: [valid], points: [CGPoint(x: 0.5,y: 0.2),CGPoint(x: CGFloat.nan,y: 0.5),CGPoint(x: 0.5,y: 0.8)]).isEmpty)
        XCTAssertTrue(Hit.hits(entries: [valid], points: [CGPoint(x: 0.5,y: 0.5)], previous: CGPoint(x: CGFloat.infinity,y: 0)).isEmpty)
    }

    private func hit(_ entry: Hit.Entry, _ x: Double, _ y: Double) -> Bool {
        !Hit.hits(entries: [entry], points: [CGPoint(x: x,y: y)]).isEmpty
    }
    private func entry(_ kind: String, data: [String: Any], width: Double = 0.004,
                       opacity: Double = 1, aspect: Double = 1, id: String = "object") throws -> Hit.Entry {
        let geometry = try XCTUnwrap(Hit.prepare(object: object(kind, data: data, width: width, opacity: opacity), aspect: aspect))
        return Hit.Entry(savedID: id, mutationID: nil, geometry: geometry)
    }
    private func point(_ x: Double, _ y: Double, p: Double = 0.5) -> [String: Double] { ["x": x,"y": y,"p": p] }
    private func object(_ kind: String, data: [String: Any], width: Double = 0.004, opacity: Double = 1) -> [String: Any] {
        ["id": "object", "kind": kind, "data": data, "style": ["color": "blue", "width": width, "opacity": opacity]]
    }
}
