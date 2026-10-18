import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFDrawingSnapshotStoreTests: XCTestCase {
    private func drawing(_ id: String, pressure: Double = 0.5, count: Int = 4) -> [String: Any] {
        var points: [[String: Any]] = []
        for index in 0..<count {
            points.append(["x": 0.1 + Double(index) * 0.8 / Double(max(1, count - 1)), "y": 0.4,
                           "p": pressure, "t": Double(index) * 4])
        }
        return ["id": id, "page": 1, "kind": "ink", "data": ["inkVersion": 4, "points": points],
                "style": ["color": "blue", "width": 0.003, "opacity": 0.6]]
    }
    private func patch(_ revision: Int, order: [String], upserts: [[String: Any]] = [], reset: Bool = false) -> [String: Any] {
        ["drawingPatch": ["reset": reset, "baseRevision": reset ? 0 : revision - 1,
                          "revision": revision, "order": order, "upserts": upserts]]
    }

    func testApplyReportsOnlyPagesWhoseRowIdentitiesChanged() throws {
        let store = NativePDFDrawingSnapshotStore()
        var b = drawing("b"); b["page"] = 2
        XCTAssertEqual(try store.apply(patch(1, order: ["a", "b"], upserts: [drawing("a"), b], reset: true), pageCount: 3), [1, 2])
        XCTAssertEqual(store.rows(page: 1).map(\.id), ["a"]); XCTAssertEqual(store.rows(page: 2).map(\.id), ["b"])
        var c = drawing("c"); c["page"] = 2
        XCTAssertEqual(try store.apply(patch(2, order: ["a", "b", "c"], upserts: [c]), pageCount: 3), [2])
        XCTAssertEqual(try store.apply(patch(3, order: ["a", "b", "c"], upserts: [drawing("a")]), pageCount: 3), [], "an unchanged upsert reuses the row and touches no page")
        XCTAssertEqual(try store.apply(patch(4, order: ["a", "c", "b"]), pageCount: 3), [2], "a reorder within a page changes that page only")
        XCTAssertEqual(try store.apply(patch(5, order: ["c", "b"]), pageCount: 3), [1])
        XCTAssertTrue(store.rows(page: 1).isEmpty)
        XCTAssertEqual(store.rows(page: 2).map(\.id), store.orderedRows.filter { $0.page == 2 }.map(\.id))
    }

    func testTwoHundredDeltaRowsReuseEveryUnchangedTokenAndPreparedPath() throws {
        let store = NativePDFDrawingSnapshotStore()
        var ids: [String] = [], visible: [[String: Any]] = []
        var first: NativePDFDrawingSnapshotStore.Row?
        for index in 0..<200 {
            let id = "stroke-\(index)"; ids.append(id)
            try store.apply(patch(index + 1, order: ids, upserts: [drawing(id, count: 96)], reset: index == 0), pageCount: 1)
            visible = store.orderedRows.map { $0.prepared(aspect: 1.5) }
            if index == 0 { first = store.row(id: id) }
            XCTAssertTrue(store.row(id: "stroke-0") === first)
            XCTAssertEqual(first?.preparationCount, 1, "Later strokes must not reparse the first stroke's 96 points")
            XCTAssertEqual(store.replacementCount, index + 1)
        }
        let tokens = store.orderedRows.map(\.visualToken)
        try store.apply(patch(201, order: ids), pageCount: 1)
        for (row, token) in zip(store.orderedRows, tokens) { XCTAssertTrue(row.visualToken === token) }
        XCTAssertEqual(store.replacementCount, 200)
        XCTAssertEqual(visible.count, 200)
        XCTAssertEqual(store.orderedRows.map(\.preparationCount), Array(repeating: 1, count: 200))
    }

    func testCorrectionsReorderDeleteAndLegacyResetRemainAtomic() throws {
        let store = NativePDFDrawingSnapshotStore()
        try store.apply(["drawings": [drawing("a"), drawing("b")]], pageCount: 1)
        let a = try XCTUnwrap(store.row(id: "a")), b = try XCTUnwrap(store.row(id: "b"))
        try store.apply(patch(1, order: ["a", "b"], upserts: [drawing("a"), drawing("b")], reset: true), pageCount: 1)
        XCTAssertTrue(a === store.row(id: "a")); XCTAssertTrue(b === store.row(id: "b"))
        let oldInk = a.prepared(aspect: 1.5)["_nativeInk"] as? NativePDFPreparedInk
        var corrected = drawing("a", pressure: 0.9)
        corrected["_nativeInk"] = oldInk; corrected["_nativeVisualToken"] = a.visualToken
        try store.apply(patch(2, order: ["b", "a"], upserts: [corrected]), pageCount: 1)
        let newA = try XCTUnwrap(store.row(id: "a"))
        XCTAssertFalse(a === newA); XCTAssertFalse(a.visualToken === newA.visualToken)
        XCTAssertNil(newA.object["_nativeInk"]); XCTAssertNil(newA.object["_nativeVisualToken"])
        XCTAssertFalse(oldInk === (newA.prepared(aspect: 1.5)["_nativeInk"] as? NativePDFPreparedInk))
        XCTAssertTrue(b === store.row(id: "b")); XCTAssertEqual(store.order, ["b", "a"])
        try store.apply(patch(3, order: ["a"]), pageCount: 1)
        XCTAssertNil(store.row(id: "b")); XCTAssertTrue(newA === store.row(id: "a"))
        try store.apply(["drawings": [drawing("legacy")]], pageCount: 1)
        XCTAssertEqual(store.revision, 0); XCTAssertEqual(store.order, ["legacy"])
    }

    func testInvalidRevisionsIDsAndRowsNeverPartiallyChangeTheScene() throws {
        let store = NativePDFDrawingSnapshotStore()
        try store.apply(patch(1, order: ["kept"], upserts: [drawing("kept")], reset: true), pageCount: 1)
        let kept = try XCTUnwrap(store.row(id: "kept"))
        var missingID = drawing("bad"); missingID.removeValue(forKey: "id")
        var wrongPage = drawing("bad"); wrongPage["page"] = true
        let invalid: [[String: Any]] = [
            patch(1, order: []), patch(3, order: ["kept"]), patch(1, order: [], reset: true),
            patch(2, order: ["kept", "kept"]), patch(2, order: ["absent"]),
            patch(2, order: ["kept"], upserts: [drawing("unused")]),
            patch(2, order: ["kept"], upserts: [drawing("kept"), drawing("kept")]),
            patch(2, order: ["kept", "bad"], upserts: [drawing("kept", pressure: 0.9), wrongPage]),
            ["drawings": [missingID]], ["drawings": [drawing("x"), drawing("x")]],
            ["drawingPatch": ["reset": 1, "baseRevision": 0, "revision": 2, "order": [], "upserts": []]],
            ["drawingPatch": ["reset": false, "baseRevision": true, "revision": 2, "order": [], "upserts": []]]
        ]
        for request in invalid {
            XCTAssertThrowsError(try store.apply(request, pageCount: 1))
            XCTAssertEqual(store.revision, 1); XCTAssertEqual(store.order, ["kept"])
            XCTAssertTrue(kept === store.row(id: "kept")); XCTAssertEqual(store.replacementCount, 1)
        }
        // Unknown/failed transport result is repaired by a newer full reset.
        try store.apply(patch(4, order: ["recovered"], upserts: [drawing("recovered")], reset: true), pageCount: 1)
        XCTAssertEqual(store.revision, 4); XCTAssertEqual(store.order, ["recovered"])
    }

    func testRowsDetachMutableJSONAndDoNotRetainVisitedPageGeometry() throws {
        let store = NativePDFDrawingSnapshotStore()
        let mutableStyle = NSMutableDictionary(dictionary: ["color": "blue", "width": 0.003, "opacity": 0.6])
        var source = drawing("a"); source["style"] = mutableStyle
        try store.apply(["drawings": [source]], pageCount: 1)
        let row = try XCTUnwrap(store.row(id: "a"))
        mutableStyle["width"] = 0.9
        XCTAssertEqual((row.object["style"] as? [String: Any])?["width"] as? Double, 0.003)
        weak var weakInk: NativePDFPreparedInk?
        autoreleasepool {
            var visible: [String: Any]? = row.prepared(aspect: 1.5)
            weakInk = visible?["_nativeInk"] as? NativePDFPreparedInk
            XCTAssertNotNil(weakInk)
            NativePDFObjectRenderer.releaseInkPaths()
            visible = nil
        }
        XCTAssertNil(weakInk, "A retained row/token must not strongly retain an offscreen path")
        _ = row.prepared(aspect: 1.5)
        XCTAssertEqual(row.preparationCount, 2)
    }

    func testNativeHostAcceptsDeltasAndRejectsInvalidPatchWithoutChangingUIState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-delta-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        let file = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }.write(to: file)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" { return ["materialID": "fixture", "documentRevision": request["documentRevision"]!] }
            return file.path
        }
        defer { host.closeAll() }
        let id: [String: Any] = ["surfaceId": "delta", "generation": "one", "courseId": "course", "relPath": "fixture.pdf"]
        _ = try await host.handle("pdfNative:open", request: id)
        func send(_ payload: [String: Any]) async throws {
            _ = try await host.handle("pdfNative:snapshot", request: id.merging(payload) { _, new in new })
        }
        var first = patch(1, order: ["a"], upserts: [drawing("a")], reset: true)
        first["loading"] = false; first["active"] = true
        first["tool"] = ["name": "pen", "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]
        try await send(first)
        try await send(patch(2, order: ["a", "b"], upserts: [drawing("b")]))
        try await send(patch(3, order: ["b", "a"]))
        var invalid = patch(4, order: ["missing"]); invalid["loading"] = true
        do { try await send(invalid); XCTFail("Reject missing drawing atomically") } catch {}
        // Still at revision 3, so this valid next patch must be accepted.
        try await send(patch(4, order: ["a"]))
        try await send(["drawings": [], "loading": false])
    }
}
