import XCTest
import UIKit
import Metal
@testable import Bandal

@MainActor
final class NativePDFRetainedInkHitTestTests: XCTestCase {
    private typealias Hit = NativePDFRetainedInkHitTest
    private typealias Entry = NativePDFRetainedInkScene.Entry

    func testSparseCapsuleCrossingHitsWhenBothEventEndpointsMiss() throws {
        let scene = try scene([object("horizontal", points: [point(0.1,0.5),point(0.9,0.5)])])
        let hit = Hit(), start = CGPoint(x: 0.5,y: 0.2), end = CGPoint(x: 0.5,y: 0.8)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [start], radius: 0).isEmpty)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [end], radius: 0).isEmpty)
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [end], previous: start, radius: 0)), ["horizontal"])
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [start,end], radius: 0)), ["horizontal"])
        XCTAssertEqual(hit.geometryBuildCount, 1)
        XCTAssertGreaterThan(hit.geometryReuseCount, 0)
    }

    func testBoundingBoxInteriorEmptySpaceDoesNotEraseAndCoalescedBendIsPreserved() throws {
        let scene = try scene([object("elbow", points: [point(0.1,0.1),point(0.1,0.9),point(0.9,0.9)])])
        let hit = Hit()
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)]).isEmpty,
                      "Bounding-box inclusion cannot authorize deleting ink")
        let source = [CGPoint(x: 0.5,y: 0.45),CGPoint(x: 0.095,y: 0.5),CGPoint(x: 0.5,y: 0.55)]
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: source)), ["elbow"])
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [source.first!,source.last!]).isEmpty,
                      "The middle coalesced sample is essential to this control")
    }

    func testStationaryDotPaddingAndAspectUseOnePhysicalMetric() throws {
        let scene = try scene([object("dot", points: [point(0.5,0.5)], width: 0.02)], aspect: 2)
        let hit = Hit()
        // V3 p=.5 gives physical radius .0052; .005 eraser padding extends it
        // to .0102 in x and .0051 in normalized y on an aspect-2 page.
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.510,y: 0.5)])), ["dot"])
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.511,y: 0.5)]).isEmpty)
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.505)])), ["dot"])
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.506)]).isEmpty)
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)], radius: 0)), ["dot"])
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)],
                                   previous: CGPoint(x: 0.5,y: 0.5), radius: 0)), ["dot"])
    }

    func testPressureReplacementRebuildsOnlyChangedGeometryAndRetiresOldOwner() throws {
        var low = object("same-id", points: [point(0.5,0.5,p: 0)], width: 0.1)
        let scene = try scene([low])
        let hit = Hit(), target = CGPoint(x: 0.525,y: 0.5)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [target], radius: 0).isEmpty)
        // The narrow dot's bbox does not touch the target. Force one actual
        // narrow-path cache entry before replacing it under the same ID.
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)], radius: 0)), ["same-id"])
        let oldPrepared = scene.entries[0].prepared
        low["data"] = ["inkVersion": 3, "points": [point(0.5,0.5,p: 1)]]
        XCTAssertEqual(scene.update(objects: [low], aspect: 1), .supported)
        XCTAssertFalse(scene.entries[0].prepared === oldPrepared)
        XCTAssertEqual(ids(hit.hits(entries: scene.entries, points: [target], radius: 0)), ["same-id"])
        XCTAssertEqual(hit.geometryBuildCount, 2); XCTAssertEqual(hit.retainedGeometryCount, 1)
        XCTAssertTrue(hit.hits(entries: [], points: [target]).isEmpty)
        XCTAssertEqual(hit.retainedGeometryCount, 0); XCTAssertEqual(hit.retainedBytes, 0)
    }

    func testOrderedUnicodeIdentitiesAndInvisibleInkRemainIndividuallyErasable() throws {
        let a = "\u{00e9}", b = "e\u{0301}"
        var transparent = object(a, points: [point(0.2,0.5),point(0.8,0.5)])
        transparent["style"] = ["color": "blue", "width": 0.02, "opacity": 0.0]
        let marker = object(b, points: [point(0.2,0.5),point(0.8,0.5)], highlighter: true)
        let scene = try scene([transparent,marker])
        let hit = Hit(), result = hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { Data($0.savedID.utf8) }, [Data(a.utf8),Data(b.utf8)])
        XCTAssertEqual(result.map(\.multiply), [false,true])
        XCTAssertEqual(result[0].color.w, 0, "Opacity is presentation, not deletion eligibility")
        let builds = hit.geometryBuildCount
        XCTAssertEqual(scene.update(objects: [marker,transparent], aspect: 1), .supported)
        let reordered = hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)])
        XCTAssertEqual(reordered.map { Data($0.savedID.utf8) }, [Data(b.utf8),Data(a.utf8)])
        XCTAssertEqual(hit.geometryBuildCount, builds)
    }

    func testLongThinStrokeAndZeroBudgetStreamingHaveSameExactHitDecisions() throws {
        let points = (0..<2400).map { index in point(0.1 + Double(index)/2399*0.8,0.5) }
        let scene = try scene([object("long-thin", points: points, width: 0.0005)])
        let cached = Hit(), streaming = Hit(maximumCachedBytes: 0)
        let probes: [(CGPoint,CGPoint?,CGFloat)] = [
            (CGPoint(x: 0.5,y: 0.5001),nil,0.00001),
            (CGPoint(x: 0.5,y: 0.5003),nil,0.00001),
            (CGPoint(x: 0.5,y: 0.9),CGPoint(x: 0.5,y: 0.1),0),
            (CGPoint(x: 0.05,y: 0.5),nil,0.005)
        ]
        var decisions: [Bool] = []
        for (point,previous,radius) in probes {
            let a = cached.hits(entries: scene.entries, points: [point], previous: previous, radius: radius)
            let b = streaming.hits(entries: scene.entries, points: [point], previous: previous, radius: radius)
            XCTAssertEqual(ids(a),ids(b)); decisions.append(!a.isEmpty)
        }
        XCTAssertEqual(decisions,[true,false,true,false])
        XCTAssertEqual(cached.geometryBuildCount,1)
        XCTAssertEqual(streaming.geometryBuildCount,0); XCTAssertEqual(streaming.retainedBytes,0)
        XCTAssertGreaterThan(streaming.streamingFallbackCount,0)
    }

    func testInvalidBatchDoesNotJoinAcrossNonfiniteSamplesOrModifyScene() throws {
        let scene = try scene([object("a", points: [point(0.1,0.5),point(0.9,0.5)])])
        let hit = Hit(), mesh = scene.entries[0].mesh
        XCTAssertTrue(hit.hits(entries: scene.entries, points: []).isEmpty)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)], radius: -1).isEmpty)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.1),CGPoint(x: CGFloat.nan,y: 0.5),CGPoint(x: 0.5,y: 0.9)]).isEmpty)
        XCTAssertTrue(hit.hits(entries: scene.entries, points: [CGPoint(x: 0.5,y: 0.5)], previous: CGPoint(x: CGFloat.infinity,y: 0)).isEmpty)
        XCTAssertEqual(scene.entries.count,1); XCTAssertTrue(scene.entries[0].mesh === mesh)
    }

    private func scene(_ rows: [[String: Any]], aspect: Double = 1) throws -> NativePDFRetainedInkScene {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(NativePDFRetainedInkRenderer(device: device))
        let scene = NativePDFRetainedInkScene(renderer: renderer)
        XCTAssertEqual(scene.update(objects: rows, aspect: aspect), .supported)
        return scene
    }
    private func ids(_ entries: [Entry]) -> [String] { entries.map(\.savedID) }
    private func point(_ x: Double, _ y: Double, p: Double = 0.5) -> [String: Double] { ["x": x,"y": y,"p": p] }
    private func object(_ id: String, points: [[String: Double]], width: Double = 0.02,
                        highlighter: Bool = false) -> [String: Any] {
        ["id": id, "page": 1, "kind": highlighter ? "highlighter" : "ink",
         "data": ["inkVersion": 3,"points": points],
         "style": ["color": highlighter ? "yellow" : "blue","width": width,"opacity": 0.5]]
    }
}
