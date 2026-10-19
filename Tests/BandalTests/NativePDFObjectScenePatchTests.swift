import XCTest
import UIKit
import PDFKit
import WebKit
@testable import Bandal

/// Exercises the production Host protocol. No fixture bypasses the epoch or
/// ordered-patch gate, and no timing threshold stands in for display integrity.
@MainActor
final class NativePDFObjectScenePatchTests: XCTestCase {
    func testSnapshotEpochAdoptionRejectsToolAndLegacyRacesBeforeAnyMutation() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a"), b = Self.ink("b", y: 0.6)
        try await f.legacySnapshot([a])
        try await f.legacyScene([b])
        try Self.assertPayload(f.surface.objects, [b])

        let ack = try await f.snapshot([a], epoch: 0)
        XCTAssertEqual(ack["objectSceneEpoch"] as? Int, 0)
        XCTAssertEqual(ack["tool"] as? String, "eraser")
        // Adoption keeps the currently visible non-ink editor scene.
        try Self.assertPayload(f.surface.objects, [b])
        let before = try Self.state(f.surface)
        let invalidSnapshots: [(String, [String: Any])] = [
            ("legacy-after-adoption", f.snapshotRequest([b], epoch: nil, tool: "pen")),
            ("same-epoch-different-tool", f.snapshotRequest([b], epoch: 0, tool: "pen")),
            ("negative-epoch", f.snapshotRequest([b], epoch: -1, tool: "eraser")),
            ("boolean-epoch", f.snapshotRequest([b], epoch: true, tool: "eraser")),
            ("fractional-epoch", f.snapshotRequest([b], epoch: 0.5, tool: "eraser")),
            ("unsafe-integer-epoch", f.snapshotRequest([b], epoch: 9_007_199_254_740_992.0, tool: "eraser")),
            ("invalid-tool", f.snapshotRequest([b], epoch: 1, tool: "unknown-tool"))
        ]
        for (name, request) in invalidSnapshots {
            await Self.rejects(name) { _ = try await f.call("pdfNative:snapshot", request) }
            try Self.assertState(f.surface, equals: before, message: name)
        }
        await Self.rejects("legacy-scene-after-adoption") { try await f.legacyScene([b]) }
        try Self.assertState(f.surface, equals: before)
        var sameRequest = f.snapshotRequest([], epoch: 0, tool: "eraser")
        sameRequest.removeValue(forKey: "drawings")
        let sameResult = try await f.call("pdfNative:snapshot", sameRequest)
        let sameEpoch = try XCTUnwrap(sameResult as? [String: Any])
        XCTAssertEqual(sameEpoch["tool"] as? String, "eraser")
        var retainRequest = f.snapshotRequest([], epoch: 1, tool: "select")
        retainRequest.removeValue(forKey: "drawings")
        _ = try await f.call("pdfNative:snapshot", retainRequest)
        try Self.assertPayload(f.surface.objects, [b])
        // Reveal the canonical Store without replacing it: rejected snapshots
        // must not have changed hidden canonical rows behind the editor scene.
        var penRequest = f.snapshotRequest([], epoch: 2, tool: "pen")
        penRequest.removeValue(forKey: "drawings")
        _ = try await f.call("pdfNative:snapshot", penRequest)
        try Self.assertPayload(f.surface.objects, [a])
        let newer = try await f.snapshot([b], epoch: 3, tool: "select")
        XCTAssertEqual(newer["objectSceneEpoch"] as? Int, 3)
        XCTAssertEqual(newer["tool"] as? String, "select")
        try Self.assertPayload(f.surface.objects, [b])
        let after = try Self.state(f.surface)
        await Self.rejects("old-snapshot") { _ = try await f.snapshot([a], epoch: 0) }
        try Self.assertState(f.surface, equals: after)
    }

    func testPatchSelectionDeleteReorderAndPressurePreserveUnchangedRowsAndExactPixels() async throws {
        let f = try await Fixture(); defer { f.close() }
        let rows = [Self.ink("a"), Self.ink("b", y: 0.5), Self.ink("c", y: 0.7)]
        _ = try await f.snapshot(rows, epoch: 4)
        let initial = try Self.identities(f.surface)
        let reset = try await f.patch(epoch: 4, revision: 1, reset: true, base: 0,
                                      order: ["a", "b", "c"], upserts: rows)
        Self.assertAck(reset, page: 1, epoch: 4, revision: 1)
        XCTAssertEqual(try Self.identities(f.surface), initial)
        let box: [String: Double] = ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.6]
        let selection = try await f.patch(epoch: 4, revision: 7, base: 1, order: ["a", "b", "c"],
                                         selection: box, resizable: true, textHandles: true)
        Self.assertAck(selection, page: 1, epoch: 4, revision: 7)
        XCTAssertEqual(f.surface.selectionBox, box)
        XCTAssertTrue(f.surface.selectionResizable); XCTAssertTrue(f.surface.selectionTextHandles)
        XCTAssertEqual(try Self.identities(f.surface), initial)
        _ = try await f.patch(epoch: 4, revision: 9, base: 7, order: ["c", "a"])
        try Self.assertPayload(f.surface.objects, [rows[2], rows[0]])
        let reordered = try Self.identities(f.surface)
        XCTAssertEqual(reordered[Data("a".utf8)], initial[Data("a".utf8)])
        XCTAssertEqual(reordered[Data("c".utf8)], initial[Data("c".utf8)])
        XCTAssertNil(f.surface.selectionBox)
        XCTAssertFalse(f.surface.selectionResizable); XCTAssertFalse(f.surface.selectionTextHandles)

        var changed = rows[0]
        var data = try XCTUnwrap(changed["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        points[1]["p"] = 0.93; data["points"] = points; changed["data"] = data
        _ = try await f.patch(epoch: 4, revision: 11, base: 9, order: ["c", "a"], upserts: [changed])
        let corrected = try Self.identities(f.surface)
        XCTAssertEqual(corrected[Data("c".utf8)], reordered[Data("c".utf8)])
        XCTAssertNotEqual(corrected[Data("a".utf8)]?.path, reordered[Data("a".utf8)]?.path)
        XCTAssertNotEqual(corrected[Data("a".utf8)]?.token, reordered[Data("a".utf8)]?.token)
        try Self.assertPayload(f.surface.objects, [rows[2], changed])
        try Self.assertPixels(f.surface.objects, [rows[2], changed])
        _ = try await f.patch(epoch: 4, revision: 12, base: 11, order: [])
        XCTAssertTrue(f.surface.objects.isEmpty)
        XCTAssertEqual(f.surface.objectVisualTokens?.count, 0)
    }

    func testInvalidPatchEnvelopesAreAtomicAndDoNotAdvanceRevision() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a"), b = Self.ink("b", y: 0.6)
        _ = try await f.snapshot([a, b], epoch: 8)
        let box: [String: Double] = ["x": 0.15, "y": 0.25, "width": 0.3, "height": 0.35]
        _ = try await f.patch(epoch: 8, revision: 4, reset: true, base: 0,
                              order: ["a", "b"], upserts: [a, b], selection: box)
        let before = try Self.state(f.surface)
        let valid = f.patchRequest(epoch: 8, revision: 5, base: 4, order: ["b", "a"])
        var invalid: [(String, [String: Any])] = []
        func root(_ name: String, _ key: String, _ value: Any) {
            var request = valid; request[key] = value; invalid.append((name, request))
        }
        func patch(_ name: String, _ key: String, _ value: Any) {
            var request = valid
            var valuePatch = request["objectPatch"] as! [String: Any]
            valuePatch[key] = value; request["objectPatch"] = valuePatch
            invalid.append((name, request))
        }
        root("old-epoch", "objectSceneEpoch", 7)
        root("future-epoch", "objectSceneEpoch", 9)
        root("boolean-epoch", "objectSceneEpoch", true)
        root("boolean-revision", "objectSceneRevision", true)
        root("fractional-revision", "objectSceneRevision", 5.5)
        root("unsafe-revision", "objectSceneRevision", 9_007_199_254_740_992.0)
        root("negative-page", "page", -1)
        root("boolean-page", "page", true)
        root("out-of-document-page", "page", 3)
        root("mixed-full-and-patch", "objects", [b])
        patch("revision-mismatch", "revision", 6)
        patch("stale-base", "baseRevision", 3)
        patch("future-base", "baseRevision", 5)
        patch("boolean-base", "baseRevision", true)
        patch("integer-reset", "reset", 0)
        patch("duplicate-order", "order", ["a", "a"])
        patch("nonstring-order", "order", ["a", 1] as [Any])
        patch("unknown-order", "order", ["a", "missing"])
        patch("duplicate-upserts", "upserts", [a, a])
        patch("upsert-outside-order", "upserts", [Self.ink("unknown")])
        patch("idless-upsert", "upserts", [["kind": "ink", "data": [:], "style": [:]]])
        patch("nonobject-upserts", "upserts", [17])
        var incompleteReset = f.patchRequest(epoch: 8, revision: 5, reset: true, base: 0,
                                             order: ["a", "b"], upserts: [a])
        invalid.append(("incomplete-reset", incompleteReset))
        var nonzeroReset = incompleteReset["objectPatch"] as! [String: Any]
        nonzeroReset["baseRevision"] = 4; nonzeroReset["upserts"] = [a, b]
        incompleteReset["objectPatch"] = nonzeroReset
        invalid.append(("nonzero-reset-base", incompleteReset))
        for (name, request) in invalid {
            await Self.rejects(name) { _ = try await f.call("pdfNative:objectScene", request) }
            try Self.assertState(f.surface, equals: before, message: name)
        }
        // This succeeds only if none of the failed requests changed its base.
        let ack = try await f.call("pdfNative:objectScene", valid)
        Self.assertAck(try XCTUnwrap(ack as? [String: Any]), page: 1, epoch: 8, revision: 5)
        try Self.assertPayload(f.surface.objects, [b, a])
        let after = try Self.state(f.surface)
        await Self.rejects("duplicate-ack-revision") { _ = try await f.call("pdfNative:objectScene", valid) }
        try Self.assertState(f.surface, equals: after)
    }

    func testLostAckResetAndToolEpochRequireFreshPageBase() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a"), b = Self.ink("b", y: 0.6)
        _ = try await f.snapshot([a, b], epoch: 2)
        let first = f.patchRequest(epoch: 2, revision: 1, reset: true, base: 0,
                                   order: ["a", "b"], upserts: [a, b])
        _ = try await f.call("pdfNative:objectScene", first)
        await Self.rejects("lost-ack-replay") { _ = try await f.call("pdfNative:objectScene", first) }
        let recovered = try await f.patch(epoch: 2, revision: 3, reset: true, base: 0,
                                          order: ["b"], upserts: [b])
        Self.assertAck(recovered, page: 1, epoch: 2, revision: 3)
        try Self.assertPayload(f.surface.objects, [b])
        _ = try await f.snapshot([a, b], epoch: 3, tool: "pen")
        try Self.assertPayload(f.surface.objects, [a, b])
        let penState = try Self.state(f.surface)
        await Self.rejects("patch-during-ink-tool") {
            _ = try await f.patch(epoch: 3, revision: 4, reset: true, base: 0, order: ["b"], upserts: [b])
        }
        try Self.assertState(f.surface, equals: penState)
        _ = try await f.snapshot([a, b], epoch: 4)
        let newEpoch = try Self.state(f.surface)
        await Self.rejects("late-old-tool-ack") {
            _ = try await f.patch(epoch: 2, revision: 6, reset: true, base: 0, order: ["b"], upserts: [b])
        }
        await Self.rejects("old-base-in-new-epoch") {
            _ = try await f.patch(epoch: 4, revision: 7, base: 3, order: ["b"])
        }
        try Self.assertState(f.surface, equals: newEpoch)
        let reset = try await f.patch(epoch: 4, revision: 1, reset: true, base: 0, order: ["a"], upserts: [a])
        Self.assertAck(reset, page: 1, epoch: 4, revision: 1)
        try Self.assertPayload(f.surface.objects, [a])
    }

    func testFullFallbackAndMalformedRowsPreserveDisplayThenRequireReset() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a"), b = Self.ink("b", y: 0.6)
        _ = try await f.snapshot([a], epoch: 5)
        _ = try await f.patch(epoch: 5, revision: 1, reset: true, base: 0, order: ["a"], upserts: [a])
        var idless = b; idless.removeValue(forKey: "id")
        var duplicate = b; duplicate["id"] = "a"
        let full = [a, duplicate, idless]
        let ack = try await f.fullScene(full, epoch: 5, revision: 4)
        Self.assertAck(ack, page: 1, epoch: 5, revision: 4)
        try Self.assertPayload(f.surface.objects, full)
        try Self.assertPixels(f.surface.objects, full)
        let before = try Self.state(f.surface)
        await Self.rejects("full-fallback-has-no-delta-base") {
            _ = try await f.patch(epoch: 5, revision: 5, base: 4, order: ["a"])
        }
        try Self.assertState(f.surface, equals: before)
        let malformed: [String: Any] = ["id": "malformed", "data": ["unknown": "kept"], "style": [:]]
        let preview: [String: Any] = ["id": "preview", "kind": "rect",
            "data": ["box": ["x": 0.2, "y": 0.1, "width": 0.25, "height": 0.3]],
            "style": ["color": "red", "width": 0.005, "opacity": 0.5]]
        _ = try await f.patch(epoch: 5, revision: 6, reset: true, base: 0,
                              order: ["a", "malformed", "preview"], upserts: [a, malformed, preview])
        try Self.assertPayload(f.surface.objects, [a, malformed, preview])
        XCTAssertNil(f.surface.objects[2]["page"], "The preview's implicit page is internal")
        let tokens = f.surface.objectVisualTokens?.map(ObjectIdentifier.init)
        _ = try await f.patch(epoch: 5, revision: 10, base: 6, order: ["preview", "malformed", "a"])
        XCTAssertEqual(f.surface.objectVisualTokens?.map(ObjectIdentifier.init), tokens?.reversed().map { $0 })
        try Self.assertPayload(f.surface.objects, [preview, malformed, a])
        try Self.assertPixels(f.surface.objects, [preview, malformed, a])
    }

    func testUnicodeIDsUseUTF8IdentityAndMutableUpsertsAreFrozen() async throws {
        let f = try await Fixture(); defer { f.close() }
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Control: Swift canonical string equality differs from JSON identity")
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let a = Self.ink(composed), b = Self.ink(decomposed, y: 0.6)
        _ = try await f.snapshot([], epoch: 6)
        _ = try await f.patch(epoch: 6, revision: 1, reset: true, base: 0,
                              order: [composed, decomposed], upserts: [a, b])
        try Self.assertPayload(f.surface.objects, [a, b])
        let old = try Self.identities(f.surface)
        XCTAssertEqual(old.count, 2)
        let mutablePoint = NSMutableDictionary(dictionary: ["x": 0.1, "y": 0.65, "p": 0.9, "t": 1.0])
        let second: [String: Any] = ["x": 0.8, "y": 0.7, "p": 0.8, "t": 2.0]
        let mutablePoints = NSMutableArray(array: [mutablePoint, second])
        var changed = b
        changed["data"] = ["inkVersion": 4, "points": mutablePoints]
        let frozenChanged = try XCTUnwrap(DesktopJSON.immutableCopy(changed) as? [String: Any])
        _ = try await f.patch(epoch: 6, revision: 2, base: 1,
                              order: [decomposed, composed], upserts: [changed])
        let current = try Self.identities(f.surface)
        XCTAssertEqual(current[Data(composed.utf8)], old[Data(composed.utf8)])
        XCTAssertNotEqual(current[Data(decomposed.utf8)]?.path, old[Data(decomposed.utf8)]?.path)
        mutablePoint["p"] = 0.01; mutablePoint["x"] = 0.99
        try Self.assertPayload(f.surface.objects, [frozenChanged, a])
        _ = try await f.patch(epoch: 6, revision: 3, base: 2, order: [decomposed])
        try Self.assertPayload(f.surface.objects, [frozenChanged])
        try Self.assertPixels(f.surface.objects, [frozenChanged])
    }

    func testPatchCannotDropPendingCheckpointAndCanonicalAckPreservesOrder() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a"), b = Self.ink("b", y: 0.65)
        _ = try await f.snapshot([a, b], epoch: 10)
        _ = try await f.patch(epoch: 10, revision: 1, reset: true, base: 0,
                              order: ["a", "b"], upserts: [a, b])
        let points = [NativePDFPoint(x: 0.2, y: 0.3, p: 0.41, t: 1),
                      NativePDFPoint(x: 0.7, y: 0.4, p: 0.62, t: 2)]
        var stroke = NativePDFCompletedStroke(mutationID: "64073D05-0B95-4BCA-B56B-AB1586F226E0",
            kind: "ink", points: points, style: .init(color: "blue", width: 0.008, opacity: 0.7))
        try XCTUnwrap(f.surface.onCheckpoint)(stroke)
        _ = try await f.patch(epoch: 10, revision: 2, base: 1, order: ["b"])
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["b", stroke.mutationID])
        let before = try Self.identities(f.surface)
        stroke.points[0].p = 0.87
        try XCTUnwrap(f.surface.onCheckpoint)(stroke)
        // A corrected checkpoint reaches the journal synchronously; its display update is coalesced (60 ms).
        var after = try Self.identities(f.surface)
        let deadline = CACurrentMediaTime() + 1
        while after[Data(stroke.mutationID.utf8)]?.path == before[Data(stroke.mutationID.utf8)]?.path, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10)); after = try Self.identities(f.surface)
        }
        XCTAssertEqual(after[Data("b".utf8)], before[Data("b".utf8)])
        XCTAssertNotEqual(after[Data(stroke.mutationID.utf8)]?.path, before[Data(stroke.mutationID.utf8)]?.path)
        try await f.journalQueue.barrier() // Disk-only: keep this measured checkpoint provisional.
        let journal = try NativePDFJournal(root: f.root)
        let record = try XCTUnwrap(journal.pending(courseID: "course", relativePath: "object-patch.pdf").first)
        XCTAssertEqual(record.input.data.points, stroke.points); XCTAssertTrue(record.provisional == true)
        try XCTUnwrap(f.surface.onStroke)(stroke)
        var canonical = try XCTUnwrap(f.surface.objects.last)
        canonical.removeValue(forKey: "_nativeInk"); canonical["id"] = "server-contact"
        _ = try await f.patch(epoch: 10, revision: 3, base: 2,
                              order: ["server-contact", "b"], upserts: [canonical])
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["server-contact", "b"])
        _ = try await f.call("pdfNative:ack", ["clientMutationId": stroke.mutationID, "drawingId": "server-contact"])
        XCTAssertTrue(try journal.pending(courseID: "course", relativePath: "object-patch.pdf").isEmpty)
        try Self.assertPayload(f.surface.objects, [canonical, b])
        try Self.assertPixels(f.surface.objects, [canonical, b])
    }

    func testPageWatermarksAreIndependentAndRevisionSkipsAreAllowed() async throws {
        let f = try await Fixture(); defer { f.close() }
        let a = Self.ink("a")
        var b = Self.ink("b", y: 0.6); b["page"] = 2
        _ = try await f.snapshot([a, b], epoch: 11)
        let first = try await f.patch(epoch: 11, revision: 5, reset: true, base: 0,
                                      order: ["a"], upserts: [a])
        Self.assertAck(first, page: 1, epoch: 11, revision: 5)
        let second = try await f.patch(page: 2, epoch: 11, revision: 9, reset: true, base: 0,
                                       order: ["b"], upserts: [b])
        Self.assertAck(second, page: 2, epoch: 11, revision: 9)
        let third = try await f.patch(epoch: 11, revision: 12, base: 5, order: ["a"])
        Self.assertAck(third, page: 1, epoch: 11, revision: 12)
        let fourth = try await f.patch(page: 2, epoch: 11, revision: 15, base: 9, order: [])
        Self.assertAck(fourth, page: 2, epoch: 11, revision: 15)
        await Self.rejects("another-pages-base") {
            _ = try await f.patch(epoch: 11, revision: 16, base: 15, order: ["a"])
        }
        _ = try await f.patch(epoch: 11, revision: 20, base: 12, order: ["a"])
        try Self.assertPayload(f.surface.objects, [a])
    }

    private struct Identity: Equatable {
        let path: ObjectIdentifier?
        let token: ObjectIdentifier
    }
    private struct State: Equatable {
        let json: Data
        let paths: [ObjectIdentifier?]
        let tokens: [ObjectIdentifier]
        let selection: [String: Double]?
        let resizable: Bool
        let textHandles: Bool
        let tool: NativePDFInkSurface.Tool
    }
    private static func state(_ surface: NativePDFInkSurface) throws -> State {
        let tokens = try XCTUnwrap(surface.objectVisualTokens)
        return State(json: try json(surface.objects),
            paths: surface.objects.map { ($0["_nativeInk"] as? NativePDFPreparedInk).map(ObjectIdentifier.init) },
            tokens: tokens.map(ObjectIdentifier.init), selection: surface.selectionBox,
            resizable: surface.selectionResizable, textHandles: surface.selectionTextHandles, tool: surface.tool)
    }
    private static func assertState(_ surface: NativePDFInkSurface, equals expected: State, message: String = "",
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try state(surface) == expected, "Rejected request mutated visible state: \(message)", file: file, line: line)
    }
    private static func identities(_ surface: NativePDFInkSurface) throws -> [Data: Identity] {
        let tokens = try XCTUnwrap(surface.objectVisualTokens)
        XCTAssertEqual(tokens.count, surface.objects.count)
        var result: [Data: Identity] = [:]
        for (object, token) in zip(surface.objects, tokens) {
            let id = try XCTUnwrap(object["id"] as? String)
            let path = (object["_nativeInk"] as? NativePDFPreparedInk).map(ObjectIdentifier.init)
            XCTAssertNil(result.updateValue(Identity(path: path, token: ObjectIdentifier(token)), forKey: Data(id.utf8)))
        }
        return result
    }
    private static func rejects(_ name: String, operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Accepted invalid request: \(name)", file: file, line: line) }
        catch { }
    }
    private static func assertAck(_ ack: [String: Any], page: Int, epoch: Int, revision: Int,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ack["page"] as? Int, page, file: file, line: line)
        XCTAssertEqual(ack["objectSceneEpoch"] as? Int, epoch, file: file, line: line)
        XCTAssertEqual(ack["objectSceneRevision"] as? Int, revision, file: file, line: line)
    }
    private static func json(_ rows: [[String: Any]]) throws -> Data {
        let clean = rows.map { object -> [String: Any] in
            var value = object; value.removeValue(forKey: "_nativeInk"); value.removeValue(forKey: "_nativeVisualToken")
            return value
        }
        return try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
    }
    private static func assertPayload(_ actual: [[String: Any]], _ expected: [[String: Any]],
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try json(actual) == json(expected), "Ordered raw editor payload changed", file: file, line: line)
        let aIDs = actual.map { ($0["id"] as? String).map { Data($0.utf8) } }
        let bIDs = expected.map { ($0["id"] as? String).map { Data($0.utf8) } }
        XCTAssertEqual(aIDs, bIDs, file: file, line: line)
        // JSON equivalence alone is insufficient for the measured-point contract.
        for (a, b) in zip(actual, expected) {
            let ap = (a["data"] as? [String: Any])?["points"] as? [[String: Any]] ?? []
            let bp = (b["data"] as? [String: Any])?["points"] as? [[String: Any]] ?? []
            XCTAssertEqual(ap.count, bp.count, file: file, line: line)
            for (p, q) in zip(ap, bp) {
                for key in ["x", "y", "p", "t", "tiltX", "tiltY"] {
                    let x = (p[key] as? NSNumber)?.doubleValue.bitPattern
                    let y = (q[key] as? NSNumber)?.doubleValue.bitPattern
                    XCTAssertEqual(x, y, "Raw \(key) bits changed", file: file, line: line)
                }
            }
        }
    }
    private static func assertPixels(_ actual: [[String: Any]], _ expected: [[String: Any]],
        file: StaticString = #filePath, line: UInt = #line) throws {
        let size = CGSize(width: 400, height: 600)
        let mapper = InkCoordinateMapper.whiteboard(size: size)
        func raster(_ rows: [[String: Any]], raw: Bool) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                for var row in rows {
                    if raw { row.removeValue(forKey: "_nativeInk"); row.removeValue(forKey: "_nativeVisualToken") }
                    NativePDFObjectRenderer.draw(row, in: context.cgContext, mapper: mapper, image: nil)
                }
            }
            return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        }
        XCTAssertTrue(try raster(actual, raw: false) == raster(expected, raw: true),
                      "Prepared editor pixels differ from ordered raw replay", file: file, line: line)
    }
    private static func ink(_ id: String, y: Double = 0.3) -> [String: Any] {
        let points: [[String: Any]] = [
            ["x": 0.1, "y": y, "p": 0.4, "t": 1.0, "tiltX": 0.2, "tiltY": 0.3],
            ["x": 0.45, "y": y + 0.04, "p": 0.6, "t": 2.0, "tiltX": 0.2, "tiltY": 0.3],
            ["x": 0.8, "y": y, "p": 0.5, "t": 3.0, "tiltX": 0.2, "tiltY": 0.3]
        ]
        return ["id": id, "page": 1, "kind": "ink", "data": ["inkVersion": 4, "points": points],
                "style": ["color": "blue", "width": 0.012, "opacity": 0.45]]
    }

    @MainActor private final class Fixture {
        let journalQueue: NativePDFJournalQueue
        let root: URL, window: UIWindow, controller: UIViewController, host: NativePDFHost
        let previous: UIWindow?, oldEnabled: Any?
        let identity: [String: Any] = ["surfaceId": "object-patch", "generation": "one",
            "courseId": "course", "relPath": "object-patch.pdf"]
        private(set) var surface: NativePDFInkSurface!
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-object-patch-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("object-patch.pdf")
            let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData {
                $0.beginPage(); $0.beginPage()
            }
            try bytes.write(to: url)
            oldEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
            UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
            let deadline = CACurrentMediaTime() + 2
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
                  CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
            let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
            journalQueue = NativePDFJournalQueue(root: root)
            let originalsRoot = root
            host = try NativePDFHost(root: root, journalQueue: journalQueue) { channel, request in
                if channel == "nativePDF:binding" { return try NativePDFTestBinding.respond(root: originalsRoot, file: url, materialID: "object-patch") }
                XCTAssertEqual(channel, "nativeMaterial:path"); return url.path
            }
            host.attach(to: controller.view, shell: shell)
            _ = try await host.handle("pdfNative:open", request: identity)
            _ = try await call("pdfNative:layout", ["visible": true,
                "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]])
            try await legacySnapshot([])
            let attachedDeadline = CACurrentMediaTime() + 5
            while CACurrentMediaTime() < attachedDeadline {
                controller.view.layoutIfNeeded(); host.layout()
                if let value = Self.find(in: controller.view).first(where: { candidate in
                    guard let page = candidate.pdfPage, let document = page.document else { return false }
                    return document.index(for: page) == 0
                }),
                   value.mapper != nil { surface = value; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            surface = try XCTUnwrap(surface)
        }
        func call(_ channel: String, _ payload: [String: Any]) async throws -> Any {
            try await host.handle(channel, request: identity.merging(payload) { _, new in new })
        }
        func snapshotRequest(_ rows: [[String: Any]], epoch: Any?, tool: String) -> [String: Any] {
            var request: [String: Any] = ["loading": false, "active": true, "drawings": rows, "annotations": [],
                "tool": ["name": tool, "style": ["color": "blue", "width": 0.012, "opacity": 0.45]]]
            request["objectSceneEpoch"] = epoch
            return request
        }
        func legacySnapshot(_ rows: [[String: Any]]) async throws {
            _ = try await call("pdfNative:snapshot", snapshotRequest(rows, epoch: nil, tool: "eraser"))
        }
        func snapshot(_ rows: [[String: Any]], epoch: Int, tool: String = "eraser") async throws -> [String: Any] {
            let result = try await call("pdfNative:snapshot", snapshotRequest(rows, epoch: epoch, tool: tool))
            return try XCTUnwrap(result as? [String: Any])
        }
        func legacyScene(_ rows: [[String: Any]]) async throws {
            _ = try await call("pdfNative:objectScene", ["page": 1, "objects": rows])
        }
        func fullScene(_ rows: [[String: Any]], epoch: Int, revision: Int) async throws -> [String: Any] {
            let request: [String: Any] = ["page": 1, "objects": rows,
                "objectSceneEpoch": epoch, "objectSceneRevision": revision]
            let result = try await call("pdfNative:objectScene", request)
            return try XCTUnwrap(result as? [String: Any])
        }
        func patchRequest(page: Int = 1, epoch: Int, revision: Int, reset: Bool = false, base: Int,
            order: [String], upserts: [[String: Any]] = [], selection: [String: Double]? = nil,
            resizable: Bool = false, textHandles: Bool = false) -> [String: Any] {
            let patch: [String: Any] = ["reset": reset, "baseRevision": base, "revision": revision,
                                      "order": order, "upserts": upserts]
            var request: [String: Any] = ["page": page, "objectSceneEpoch": epoch, "objectSceneRevision": revision,
                "objectPatch": patch, "resizable": resizable, "textHandles": textHandles]
            request["selection"] = selection
            return request
        }
        func patch(page: Int = 1, epoch: Int, revision: Int, reset: Bool = false, base: Int,
            order: [String], upserts: [[String: Any]] = [], selection: [String: Double]? = nil,
            resizable: Bool = false, textHandles: Bool = false) async throws -> [String: Any] {
            let request = patchRequest(page: page, epoch: epoch, revision: revision, reset: reset, base: base,
                order: order, upserts: upserts, selection: selection, resizable: resizable, textHandles: textHandles)
            let result = try await call("pdfNative:objectScene", request)
            return try XCTUnwrap(result as? [String: Any])
        }
        func close() {
            host.closeAll(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            UserDefaults.standard.set(oldEnabled, forKey: "bandal.nativePDF.enabled")
            NativePDFObjectRenderer.releaseInkPaths(); try? FileManager.default.removeItem(at: root)
        }
        private static func find(in view: UIView) -> [NativePDFInkSurface] {
            if let surface = view as? NativePDFInkSurface { return [surface] }
            return view.subviews.flatMap { find(in: $0) }
        }
    }
}
