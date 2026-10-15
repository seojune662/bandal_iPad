import XCTest
import UIKit
import Metal
@testable import Bandal

@MainActor
final class NativePDFRetainedInkSceneTests: XCTestCase {
    private typealias Scene = NativePDFRetainedInkScene
    private let aspect = 1.5

    func testVersionedInkAndHighlighterKeepOrderStyleAndNormalizedPath() throws {
        let (renderer, scene) = try make()
        let rows = try (2...4).map { try prepared(object("v\($0)", version: $0, highlighter: $0 == 3)) }
        XCTAssertEqual(update(scene, rows), .supported)
        XCTAssertEqual(scene.entries.map(\.savedID), ["v2", "v3", "v4"])
        XCTAssertEqual(scene.entries.map(\.multiply), [false, true, false])
        XCTAssertEqual(scene.retainedGeometryCount, 3); XCTAssertEqual(renderer.meshUploadCount, 3)
        for (entry, row) in zip(scene.entries, rows) {
            XCTAssertTrue(entry.path === (row["_nativeInk"] as? NativePDFPreparedInk)?.path)
            XCTAssertEqual(entry.prepared.aspect, aspect)
            XCTAssertEqual(entry.style.width, 0.03)
            XCTAssertEqual(entry.color.w, Float(entry.style.opacity))
            let expected = NativePDFObjectRenderer.color(entry.style.color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(expected.getRed(&r, green: &g, blue: &b, alpha: &a))
            XCTAssertEqual(entry.color, SIMD4(Float(r) * entry.color.w, Float(g) * entry.color.w,
                                              Float(b) * entry.color.w, entry.color.w))
        }
        let transform = CGAffineTransform(a: 1200, b: 0, c: 0, d: 1800, tx: -37, ty: -89)
        let items = scene.items(transform: transform)
        XCTAssertEqual(items.map(\.multiply), [false, true, false])
        XCTAssertTrue(items.allSatisfy { $0.transform == transform })
        XCTAssertEqual(renderer.meshUploadCount, 3, "Projection is a uniform, never a geometry rewrite")
    }

    func testReorderDeleteColorOpacityAndAliasExclusionReuseGeometry() throws {
        let (renderer, scene) = try make()
        var rows = try (0..<3).map { try prepared(object("s\($0)", highlighter: $0 == 1)) }
        XCTAssertEqual(update(scene, rows), .supported)
        let original = scene.entries
        rows.swapAt(0, 2)
        var style = try XCTUnwrap(rows[0]["style"] as? [String: Any])
        style["color"] = "green"; style["opacity"] = 1.0; rows[0]["style"] = style
        // The actual native store validates the unchanged shape and retains
        // its PreparedInk even when it mints a new appearance token.
        rows[0] = try prepared(rows[0])
        XCTAssertEqual(update(scene, rows), .supported)
        XCTAssertEqual(scene.entries.map(\.savedID), ["s2", "s1", "s0"])
        XCTAssertTrue(scene.entries[0].mesh === original[2].mesh)
        XCTAssertTrue(scene.entries[0].prepared === original[2].prepared)
        XCTAssertEqual(scene.entries[0].color.w, 1)
        XCTAssertEqual(renderer.meshUploadCount, 3)
        let filtered = scene.items(excludingIDs: ["mutation-s1", "s0"])
        XCTAssertEqual(filtered.count, 1); XCTAssertTrue(filtered[0].mesh === original[2].mesh)
        rows.remove(at: 1)
        XCTAssertEqual(update(scene, rows), .supported)
        XCTAssertEqual(scene.retainedGeometryCount, 2)
        XCTAssertEqual(renderer.meshUploadCount, 3)
        XCTAssertEqual(scene.update(objects: [], visualTokens: [], aspect: aspect), .supported)
        XCTAssertTrue(scene.entries.isEmpty); XCTAssertTrue(scene.items().isEmpty)
        XCTAssertEqual(scene.retainedGeometryCount, 0)
    }

    func testCanonicalAcknowledgementReusesMeshButPressureCorrectionDoesNot() throws {
        let (renderer, scene) = try make()
        var row = try prepared(object("pending", version: 4))
        row["clientMutationId"] = "stable-mutation"
        XCTAssertEqual(update(scene, [row]), .supported)
        let pending = try XCTUnwrap(scene.entries.first)
        row["id"] = "canonical"; row["updatedAt"] = "ack"
        XCTAssertEqual(update(scene, [row]), .supported)
        XCTAssertEqual(scene.entries[0].savedID, "canonical")
        XCTAssertEqual(scene.entries[0].mutationID, "stable-mutation")
        XCTAssertTrue(scene.entries[0].mesh === pending.mesh)
        XCTAssertTrue(scene.entries[0].path === pending.path)
        XCTAssertEqual(renderer.meshUploadCount, 1)
        var data = try XCTUnwrap(row["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
        points[0]["p"] = 0.95; data["points"] = points; row["data"] = data
        row = try prepared(row)
        XCTAssertEqual(update(scene, [row]), .supported)
        XCTAssertFalse(scene.entries[0].prepared === pending.prepared)
        XCTAssertFalse(scene.entries[0].mesh === pending.mesh)
        XCTAssertFalse(scene.entries[0].path === pending.path)
        XCTAssertEqual(renderer.meshUploadCount, 2)
        XCTAssertEqual(scene.retainedGeometryCount, 1)
        let reference = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(row, aspect: aspect))
        XCTAssertEqual(scene.entries[0].path, reference.path)
        XCTAssertEqual((row["data"] as? [String: Any])?["points"] as? [[String: Double]], points,
                       "The display builder must not rewrite corrected or surviving raw points")
    }

    func testUnsupportedOrMalformedRowsRejectAtomicallyBeforeAnyMeshUpload() throws {
        let (renderer, scene) = try make()
        let accepted = try prepared(object("accepted"))
        XCTAssertEqual(update(scene, [accepted]), .supported)
        let before = scene.entries[0]
        var unsupported = object("shape"); unsupported["kind"] = "rect"
        var idless = object("missing"); idless.removeValue(forKey: "id")
        var boolWidth = object("boolean"); boolWidth["style"] = ["color": "blue", "width": true, "opacity": 0.5]
        var legacy = object("legacy"); legacy["data"] = ["points": [["x": 0.2, "y": 0.3, "p": 0.5]]]
        var boolVersion = object("bool-version"); boolVersion["data"] = ["inkVersion": true, "points": [["x": 0.2, "y": 0.3, "p": 0.5]]]
        var badPoint = object("nonfinite"); badPoint["data"] = ["inkVersion": 4, "points": [["x": Double.nan, "y": 0.3, "p": 0.5]]]
        let duplicateAlias = object("different").merging(["clientMutationId": "mutation-accepted"]) { _, new in new }
        let cases: [[[String: Any]]] = [
            [object("new-before-failure"), unsupported], [idless], [accepted, accepted],
            [boolWidth], [legacy], [boolVersion], [badPoint], [accepted, duplicateAlias]
        ]
        for rows in cases {
            guard case .unsupported = scene.update(objects: rows, aspect: aspect) else {
                XCTFail("Malformed or mixed scenes must use an explicit whole-scene fallback"); continue
            }
            XCTAssertEqual(scene.entries.count, 1)
            XCTAssertEqual(scene.entries[0].savedID, before.savedID)
            XCTAssertTrue(scene.entries[0].mesh === before.mesh)
            XCTAssertTrue(scene.entries[0].path === before.path)
            XCTAssertEqual(renderer.meshUploadCount, 1, "Validation must finish before allocating a partial scene")
            XCTAssertEqual(scene.retainedGeometryCount, 1)
        }
        XCTAssertEqual(scene.update(objects: [], aspect: .nan), .unsupported(.invalidAspect))
        XCTAssertTrue(scene.entries[0].mesh === before.mesh)
    }

    func testUntrustedPreparedMarkerAndMismatchedTokenCountValidateRawInput() throws {
        let (renderer, scene) = try make()
        var row = try prepared(object("a"))
        XCTAssertEqual(update(scene, [row]), .supported)
        let old = scene.entries[0]
        var data = try XCTUnwrap(row["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
        points[1]["y"] = 0.87; data["points"] = points; row["data"] = data
        row["_nativeVisualToken"] = NativePDFCommittedVisualToken(object: row)
        // A copied stale _nativeInk pointer is not trusted without the separate
        // owner token array. A wrong-length array is the same safe fallback.
        XCTAssertEqual(scene.update(objects: [row], visualTokens: [], aspect: aspect), .supported)
        XCTAssertFalse(scene.entries[0].prepared === old.prepared)
        XCTAssertFalse(scene.entries[0].mesh === old.mesh)
        XCTAssertEqual(renderer.meshUploadCount, 2)
        XCTAssertEqual(scene.entries[0].path, try XCTUnwrap(NativePDFObjectRenderer.prepareInk(row, aspect: aspect)).path)
        let changed = scene.entries[0]
        XCTAssertEqual(scene.update(objects: [row], aspect: aspect * 2), .supported)
        XCTAssertFalse(scene.entries[0].prepared === changed.prepared)
        XCTAssertEqual(scene.entries[0].prepared.aspect, aspect * 2)
    }

    func testExactUTF8IdentitiesRemainDistinctAndExclusionDoesNotFoldThem() throws {
        let (_, scene) = try make()
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        var first = object(composed), second = object(decomposed)
        first.removeValue(forKey: "clientMutationId"); second.removeValue(forKey: "clientMutationId")
        XCTAssertEqual(scene.update(objects: [first, second], aspect: aspect), .supported)
        XCTAssertEqual(scene.entries.count, 2)
        let items = scene.items(excludingIDs: [composed])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].mesh === scene.entries[1].mesh)
        XCTAssertTrue(scene.items(excludingIDs: [composed, decomposed]).isEmpty,
                      "Do not fold distinct wire IDs in a Swift Set before the UTF8 comparison")
    }

    func testRetainedMeshLifetimeEndsWhenItsLastSceneEntryRetires() throws {
        let (_, scene) = try make()
        weak var oldMesh: NativePDFRetainedInkRenderer.Mesh?
        do {
            let row = try prepared(object("lifetime"))
            XCTAssertEqual(update(scene, [row]), .supported)
            oldMesh = scene.entries[0].mesh
        }
        XCTAssertNotNil(oldMesh, "The current scene owns resources even after caller arrays leave scope")
        XCTAssertEqual(scene.update(objects: [], aspect: aspect), .supported)
        XCTAssertNil(oldMesh, "Deleted resources are not retained by an ID-keyed or unbounded secondary cache")
        XCTAssertEqual(scene.retainedGeometryCount, 0)
    }

    func testGeometryBudgetRejectsWholeSceneBeforeUploadAndCountsSharedResourcesOnce() throws {
        let (renderer, probe) = try make()
        let a = try prepared(object("budget-a", version: 2))
        XCTAssertEqual(update(probe, [a]), .supported)
        let bytes = try XCTUnwrap(probe.entries.first).mesh.buffer.length
        XCTAssertGreaterThan(bytes, 0)
        let scene = Scene(renderer: renderer, geometryByteLimit: bytes)
        XCTAssertEqual(update(scene, [a]), .supported)
        let accepted = scene.entries[0], uploads = renderer.meshUploadCount
        XCTAssertEqual(scene.retainedGeometryBytes, bytes)
        var b = try prepared(object("budget-b", version: 2))
        XCTAssertEqual(update(scene, [a, b]), .unsupported(.geometryBudgetExceeded))
        XCTAssertEqual(scene.entries.count, 1); XCTAssertTrue(scene.entries[0].mesh === accepted.mesh)
        XCTAssertEqual(scene.retainedGeometryBytes, bytes); XCTAssertEqual(renderer.meshUploadCount, uploads)

        // Two rows may reference the same validated immutable geometry while
        // retaining distinct order/identities. Its buffer is charged only once.
        b["_nativeInk"] = accepted.prepared
        XCTAssertEqual(update(scene, [a, b]), .supported)
        XCTAssertEqual(scene.entries.count, 2); XCTAssertEqual(scene.retainedGeometryCount, 1)
        XCTAssertEqual(scene.retainedGeometryBytes, bytes); XCTAssertEqual(renderer.meshUploadCount, uploads)
        XCTAssertTrue(scene.entries[0].mesh === scene.entries[1].mesh)

        var larger = object("budget-a", version: 2)
        var data = try XCTUnwrap(larger["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
        points.append(["x": 0.95, "y": 0.8, "p": 0.5, "t": 24]); data["points"] = points
        larger["data"] = data; larger = try prepared(larger)
        XCTAssertEqual(update(scene, [larger]), .unsupported(.geometryBudgetExceeded))
        XCTAssertEqual(scene.entries.count, 2); XCTAssertTrue(scene.entries[0].mesh === accepted.mesh)
        XCTAssertEqual(renderer.meshUploadCount, uploads)
        XCTAssertEqual(scene.update(objects: [], aspect: aspect), .supported)
        XCTAssertEqual(scene.retainedGeometryBytes, 0); XCTAssertEqual(scene.retainedGeometryCount, 0)
        let zero = Scene(renderer: renderer, geometryByteLimit: 0)
        XCTAssertEqual(update(zero, [a]), .unsupported(.geometryBudgetExceeded))
        XCTAssertTrue(zero.entries.isEmpty); XCTAssertEqual(renderer.meshUploadCount, uploads)
        XCTAssertEqual(zero.update(objects: [], aspect: aspect), .supported)
    }

    private func make() throws -> (NativePDFRetainedInkRenderer, Scene) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(NativePDFRetainedInkRenderer(device: device))
        return (renderer, Scene(renderer: renderer))
    }
    private func update(_ scene: Scene, _ rows: [[String: Any]]) -> Scene.UpdateResult {
        scene.update(objects: rows, visualTokens: rows.map(NativePDFCommittedVisualToken.init), aspect: aspect)
    }
    private func prepared(_ source: [String: Any]) throws -> [String: Any] {
        var row = source
        row["_nativeInk"] = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(row, aspect: aspect))
        return row
    }
    private func object(_ id: String, version: Int = 4, highlighter: Bool = false) -> [String: Any] {
        let points: [[String: Double]] = [
            ["x": 0.1, "y": 0.2, "p": 0.15, "t": 0],
            ["x": 0.5, "y": 0.6, "p": 0.8, "t": 8],
            ["x": 0.9, "y": 0.3, "p": 0.45, "t": 16]
        ]
        let data: [String: Any] = ["inkVersion": version, "points": points]
        let style: [String: Any] = ["color": highlighter ? "yellow" : "blue", "width": 0.03,
                                   "opacity": highlighter ? 0.4 : 1.0]
        return ["id": id, "clientMutationId": "mutation-\(id)", "page": 1,
                "kind": highlighter ? "highlighter" : "ink", "data": data, "style": style]
    }
}
