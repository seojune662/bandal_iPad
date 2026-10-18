import XCTest
import UIKit
import PDFKit
import WebKit
import CryptoKit
@testable import Bandal

/// Calls the production Host objectScene route. These are geometry/lifecycle
/// checks, not hardware Pencil latency or UIKit gesture-arbitration claims.
@MainActor
final class NativePDFEditorSceneTests: XCTestCase {
    /// Measures the existing complete-page editor route without a time-based
    /// pass threshold. The separate scene helper localizes work; it is not a
    /// subtraction-based decomposition of the Host call or physical input lag.
    func testEditorScenePreparationBaselinePreservesRowsPathsAndPixels() async throws {
        var workloads: [[String: Any]] = []
        for rowCount in [85, 200] {
            let f = try await Fixture(); defer { f.close() }
            let swiftRows = (0..<rowCount).map { index in
                Self.ink("baseline-\(index)", count: 96,
                         y: 0.05 + Double(index) * 0.85 / Double(rowCount))
            }
            let wire = try JSONSerialization.data(withJSONObject: swiftRows, options: [.sortedKeys])
            // A real JSON-derived container fixture, not a claimed WKScriptMessage
            // representation. Its creation/serialization is outside all spans.
            let rows = try XCTUnwrap(DesktopJSON.decode(wire) as? [[String: Any]])
            XCTAssertTrue(try Self.benchmarkPointBits(rows) == Self.benchmarkPointBits(swiftRows))
            let operations = try Self.benchmarkOperations(rows)
            var diagnostics: [String] = []
            f.host.onDiagnostic = { event, code in
                if event == "nativePDF.hostTiming" { diagnostics.append(code) }
            }
            let snapshotStart = CACurrentMediaTime()
            try await f.snapshot(rows)
            let snapshotMS = (CACurrentMediaTime() - snapshotStart) * 1000
            var priorHost = try Self.benchmarkIdentity(f.surface.objects, tokens: f.surface.objectVisualTokens)
            var hostSamples: [[String: Any]] = []
            for operation in operations {
                let diagnosticStart = diagnostics.count
                let before = CACurrentMediaTime()
                try await f.scene(operation.rows, selection: operation.selection)
                let elapsed = (CACurrentMediaTime() - before) * 1000
                let codes = Array(diagnostics.dropFirst(diagnosticStart))
                let next = try Self.benchmarkIdentity(f.surface.objects, tokens: f.surface.objectVisualTokens)
                Self.assertBenchmarkIdentity(next, retains: priorHost, except: operation.changedIDs)
                try Self.assertBenchmarkPayload(f.surface.objects, expected: operation.rows)
                XCTAssertEqual(f.surface.selectionBox, operation.selection)
                // Keep raster/reference work outside every preparation timer.
                if operation.checkPixels { try Self.assertBenchmarkPixels(f.surface.objects, expected: operation.rows) }
                hostSamples.append(["operation": operation.name, "rows": operation.rows.count,
                    "handleWallMS": elapsed, "sampledRoundedHostTiming": codes])
                priorHost = next
            }
            let journal = try NativePDFJournal(root: f.root)
            XCTAssertTrue(try journal.pending(courseID: "course", relativePath: "editor.pdf").isEmpty)

            // Mirror the same requests using the real Scene/Store APIs. Keep
            // only the current display payload alive, as Surface.objects does;
            // identity witnesses contain no strong prepared-path references.
            let store = NativePDFDrawingSnapshotStore()
            let storeStart = CACurrentMediaTime()
            try store.apply(["drawings": rows], pageCount: 1)
            let initialStoreMS = (CACurrentMediaTime() - storeStart) * 1000
            let initialRows = store.orderedRows.map(ObjectIdentifier.init)
            let warmStart = CACurrentMediaTime()
            var visible = store.orderedRows.map { $0.prepared(aspect: 1.5) }
            let initialPrepareMS = (CACurrentMediaTime() - warmStart) * 1000
            var priorHelper = try Self.benchmarkIdentity(visible, tokens: store.orderedRows.map(\.visualToken))
            var scene: NativePDFEditorScene?
            var helperSamples: [[String: Any]] = []
            for operation in operations {
                let fastBefore = store.fastReuseCount, fullBefore = store.fullPreparationCount
                var request: [String: Any] = ["objects": operation.rows, "resizable": false, "textHandles": false]
                request["selection"] = operation.selection
                let initStart = CACurrentMediaTime()
                let nextScene = NativePDFEditorScene(request: request, page: 1, pageCount: 1, store: store, previous: scene)
                let initMS = (CACurrentMediaTime() - initStart) * 1000
                let prepareStart = CACurrentMediaTime()
                let nextVisible = withExtendedLifetime(visible) { nextScene.prepared(aspect: 1.5) }
                let prepareMS = (CACurrentMediaTime() - prepareStart) * 1000
                let tokens = nextScene.visualTokens
                let next = try Self.benchmarkIdentity(nextVisible, tokens: tokens)
                let fast = store.fastReuseCount - fastBefore, full = store.fullPreparationCount - fullBefore
                XCTAssertEqual(full, operation.expectedFullPreparations, operation.name)
                XCTAssertEqual(fast, operation.rows.count - operation.expectedFullPreparations, operation.name)
                Self.assertBenchmarkIdentity(next, retains: priorHelper, except: operation.changedIDs)
                try Self.assertBenchmarkPayload(nextVisible, expected: operation.rows)
                XCTAssertEqual(store.orderedRows.map(ObjectIdentifier.init), initialRows,
                    "An editor scene must not mutate the canonical Store rows")
                helperSamples.append(["operation": operation.name, "rows": operation.rows.count,
                    "sceneInitMS": initMS, "preparedMS": prepareMS,
                    "fastReuseDelta": fast, "fullPreparationDelta": full])
                visible = nextVisible; scene = nextScene; priorHelper = next
            }
            // Ensure the strong current-display owner is live through the last
            // comparison. No all-history path list papers over weak-row eviction.
            XCTAssertEqual(visible.count, rowCount)
            XCTAssertEqual(store.fullPreparationCount, rowCount + 2)
            let hostSelection = hostSamples.filter { ($0["operation"] as? String)?.hasPrefix("selection-") == true }
            let helperSelection = helperSamples.filter { ($0["operation"] as? String)?.hasPrefix("selection-") == true }
            func mean(_ samples: [[String: Any]], _ key: String) -> Double {
                let values = samples.compactMap { $0[key] as? Double }
                return values.reduce(0, +) / Double(max(1, values.count))
            }
            let summary: [String: Any] = ["rows": rowCount, "pointsPerRow": 96,
                "selectionHostMeanMS": mean(hostSelection, "handleWallMS"),
                "selectionSceneInitMeanMS": mean(helperSelection, "sceneInitMS"),
                "selectionPreparedMeanMS": mean(helperSelection, "preparedMS")]
            var workload = summary
            workload["inputBytes"] = wire.count
            workload["inputJSONSHA256"] = Self.benchmarkSHA(wire)
            workload["inputPointBitsSHA256"] = Self.benchmarkSHA(try Self.benchmarkPointBits(rows))
            workload["rawPointType"] = Self.benchmarkPointType(rows)
            workload["initialHostSnapshotMS"] = snapshotMS
            workload["helperInitialStoreMS"] = initialStoreMS
            workload["helperInitialPreparedMS"] = initialPrepareMS
            workload["host"] = hostSamples; workload["separateSceneHelper"] = helperSamples
            workload["storeFullPreparationCount"] = store.fullPreparationCount
            workload["storeFastReuseCount"] = store.fastReuseCount
            workloads.append(workload)
            let summaryBytes = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print("[EDITOR_SCENE_BASELINE] \(String(decoding: summaryBytes, as: UTF8.self))")
        }
        let report: [String: Any] = ["schemaVersion": 1, "workloads": workloads,
            "representation": "DesktopJSON.decode of synthetic Swift-generated JSON; not WKScriptMessage.body",
            "limitations": ["Single sequential run, shared host and normal Surface scheduling may overlap.",
                "Same MainActor Host.handle wall spans include routing; no new product timing hooks.",
                "Separate scene helper is a mirrored workload, not a subtractable breakdown of Host timings.",
                "Input creation, raw/pixel assertions, JSON attachments and helper warmup are outside steady-state spans.",
                "No timing threshold, physical Pencil claim, real document data, or wire dedup measurement."]]
        let reportBytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: reportBytes, uniformTypeIdentifier: "public.json")
        attachment.name = "editor-scene-preparation-baseline"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Same operations and input bytes as the frozen full-scene baseline.
    /// The Host protocol is tested separately; this paired helper isolates the
    /// real scene initializer and preparation APIs in one unchanged binary.
    func testEditorScenePatchDifferentialPreservesBaselineOperations() throws {
        var workloads: [[String: Any]] = []
        for rowCount in [85, 200] {
            let swiftRows = (0..<rowCount).map { index in
                Self.ink("baseline-\(index)", count: 96,
                         y: 0.05 + Double(index) * 0.85 / Double(rowCount))
            }
            let wire = try JSONSerialization.data(withJSONObject: swiftRows, options: [.sortedKeys])
            let rows = try XCTUnwrap(DesktopJSON.decode(wire) as? [[String: Any]])
            let operations = try Self.benchmarkOperations(rows)
            XCTAssertTrue(try Self.benchmarkPointBits(rows) == Self.benchmarkPointBits(swiftRows))
            // Reverse mode order for the second workload; this is still one
            // shared-host run, not a thermal-isolated randomized benchmark.
            let modes = rowCount == 85 ? ["full", "patch"] : ["patch", "full"]
            for mode in modes {
                let store = NativePDFDrawingSnapshotStore()
                let storeStart = CACurrentMediaTime()
                try store.apply(["drawings": rows], pageCount: 1)
                let initialStoreMS = (CACurrentMediaTime() - storeStart) * 1000
                let prepareStart = CACurrentMediaTime()
                var visible = store.orderedRows.map { $0.prepared(aspect: 1.5) }
                let initialPreparedMS = (CACurrentMediaTime() - prepareStart) * 1000
                let canonicalRows = store.orderedRows.map(ObjectIdentifier.init)
                var identities = try Self.benchmarkIdentity(visible, tokens: store.orderedRows.map(\.visualToken))
                var scene: NativePDFEditorScene?
                var priorIDs: Set<String> = []
                var samples: [[String: Any]] = []
                for (index, operation) in operations.enumerated() {
                    let reset = index == 0
                    let order = operation.rows.compactMap { $0["id"] as? String }
                    // Known synthetic changes supply the exact delta. Publisher
                    // diffing/serialization cost is deliberately not measured.
                    let upserts = reset ? operation.rows : operation.rows.filter {
                        guard let id = $0["id"] as? String else { return false }
                        return !priorIDs.contains(id) || operation.changedIDs.contains(id)
                    }
                    var request: [String: Any] = ["page": 1, "objects": operation.rows,
                        "resizable": false, "textHandles": false]
                    request["selection"] = operation.selection
                    let patch: [String: Any] = ["reset": reset, "baseRevision": index,
                        "revision": index + 1, "order": order, "upserts": upserts]
                    let fastBefore = store.fastReuseCount, fullBefore = store.fullPreparationCount
                    let initStart = CACurrentMediaTime()
                    let next: NativePDFEditorScene
                    if mode == "patch" {
                        var patchRequest = request; patchRequest.removeValue(forKey: "objects")
                        patchRequest["objectSceneEpoch"] = 1; patchRequest["objectSceneRevision"] = index + 1
                        next = try NativePDFEditorScene(patch: patch, request: patchRequest, page: 1,
                            pageCount: 1, store: store, previous: scene)
                    } else {
                        next = NativePDFEditorScene(request: request, page: 1, pageCount: 1, store: store, previous: scene)
                    }
                    let initMS = (CACurrentMediaTime() - initStart) * 1000
                    let preparedStart = CACurrentMediaTime()
                    let nextVisible = withExtendedLifetime(visible) { next.prepared(aspect: 1.5) }
                    let preparedMS = (CACurrentMediaTime() - preparedStart) * 1000
                    let nextIDs = try Self.benchmarkIdentity(nextVisible, tokens: next.visualTokens)
                    Self.assertBenchmarkIdentity(nextIDs, retains: identities, except: operation.changedIDs)
                    try Self.assertBenchmarkPayload(nextVisible, expected: operation.rows)
                    if operation.checkPixels { try Self.assertBenchmarkPixels(nextVisible, expected: operation.rows) }
                    let fast = store.fastReuseCount - fastBefore, full = store.fullPreparationCount - fullBefore
                    let checkedRows = mode == "patch" ? upserts.count : operation.rows.count
                    XCTAssertEqual(full, operation.expectedFullPreparations, "\(mode)/\(operation.name)")
                    XCTAssertEqual(fast, checkedRows - operation.expectedFullPreparations, "\(mode)/\(operation.name)")
                    XCTAssertEqual(store.orderedRows.map(ObjectIdentifier.init), canonicalRows)
                    samples.append(["operation": operation.name, "rows": operation.rows.count,
                        "upserts": mode == "patch" ? upserts.count : operation.rows.count,
                        "sceneInitMS": initMS, "preparedMS": preparedMS,
                        "fastReuseDelta": fast, "fullPreparationDelta": full])
                    visible = nextVisible; scene = next; identities = nextIDs; priorIDs = Set(order)
                }
                XCTAssertEqual(visible.count, rowCount)
                XCTAssertEqual(store.fullPreparationCount, rowCount + 2)
                let selection = samples.filter { ($0["operation"] as? String)?.hasPrefix("selection-") == true }
                func mean(_ key: String) -> Double {
                    selection.compactMap { $0[key] as? Double }.reduce(0, +) / Double(selection.count)
                }
                var workload: [String: Any] = ["rows": rowCount, "pointsPerRow": 96, "mode": mode,
                    "selectionSceneInitMeanMS": mean("sceneInitMS"),
                    "selectionPreparedMeanMS": mean("preparedMS"),
                    "initialStoreMS": initialStoreMS, "initialPreparedMS": initialPreparedMS,
                    "storeFastReuseCount": store.fastReuseCount, "storeFullPreparationCount": store.fullPreparationCount,
                    "inputJSONSHA256": Self.benchmarkSHA(wire),
                    "inputPointBitsSHA256": Self.benchmarkSHA(try Self.benchmarkPointBits(rows))]
                let summary = try JSONSerialization.data(withJSONObject: workload, options: [.sortedKeys])
                print("[EDITOR_SCENE_DIFFERENTIAL] \(String(decoding: summary, as: UTF8.self))")
                workload["operations"] = samples; workloads.append(workload)
            }
        }
        let report: [String: Any] = ["schemaVersion": 1, "workloads": workloads,
            "scope": "Same-binary real NativePDFEditorScene initializer/prepared APIs; Host protocol tested separately",
            "limitations": ["Single sequential shared-host run, alternating protocol order by workload size.",
                "Exact same 25 operations as the full-scene baseline; synthetic delta creation is outside the timers.",
                "Initial Store/preparation are reported separately from repeated selection requests.",
                "No publisher/bridge/frame-presentation timing, time pass threshold, or physical input-latency claim."]]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "editor-scene-patch-differential"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTwoHundredEditorRowsRetainPathsBeyondTheSixtyFourEntryLRU() async throws {
        let f = try await Fixture(); defer { f.close() }
        let rows = (0..<200).map { Self.ink("ink-\($0)", count: 96, y: 0.05 + Double($0) * 0.004) }
        try await f.snapshot(rows)
        let canonicalPaths = Self.pathIDs(f.surface.objects)
        let canonicalTokens = f.surface.objectVisualTokens ?? []
        XCTAssertEqual(canonicalPaths.count, 200)
        try await f.scene(rows)
        XCTAssertEqual(Self.pathIDs(f.surface.objects), canonicalPaths,
            "The first unchanged editor scene must reuse fully validated canonical rows")
        XCTAssertEqual(f.surface.objectVisualTokens?.count, 200)
        if let tokens = f.surface.objectVisualTokens {
            XCTAssertEqual(tokens.map(ObjectIdentifier.init), canonicalTokens.map(ObjectIdentifier.init))
        }
        // This separate cache observes the actual payload delivered by Host.
        // Raw 200-object passes thrash its 64 entries; retained validated paths
        // must bypass path construction even after that cache is emptied.
        let observer = NativePDFInkPathCache()
        for object in f.surface.objects { _ = observer.prepare(object, aspect: 1.5) }
        let firstPassBuilds = observer.buildCount
        for iteration in 0..<4 {
            if iteration == 3 { observer.removeAll() }
            try await f.scene(rows, selection: ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4])
            for object in f.surface.objects { _ = observer.prepare(object, aspect: 1.5) }
            XCTAssertEqual(observer.buildCount, firstPassBuilds, "Editor refresh \(iteration) rebuilt unchanged geometry")
            XCTAssertEqual(Self.pathIDs(f.surface.objects), canonicalPaths)
            XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, rows.compactMap { $0["id"] as? String })
        }
        XCTAssertEqual(firstPassBuilds, 0, "Visible native paths should need no independent-cache construction")
    }

    func testSameIDCorrectionUndoReorderDeleteAndAspectCannotReuseStalePaths() async throws {
        let f = try await Fixture(); defer { f.close() }
        let rows = [Self.ink("a"), Self.ink("b", y: 0.6), Self.ink("c", y: 0.8)]
        try await f.snapshot(rows); try await f.scene(rows)
        let original = try Self.paths(f.surface.objects)
        var changed = rows
        var data = try XCTUnwrap(changed[0]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        points[1]["p"] = 0.93; points[1]["y"] = 0.25; data["points"] = points
        changed[0]["data"] = data
        var style = try XCTUnwrap(changed[0]["style"] as? [String: Any]); style["width"] = 0.018
        changed[0]["style"] = style
        var colorOnly = try XCTUnwrap(changed[1]["style"] as? [String: Any])
        colorOnly["color"] = "red"; colorOnly["opacity"] = 0.25
        changed[1]["style"] = colorOnly
        changed[0]["_nativeInk"] = original[0]
        changed[0]["_nativeVisualToken"] = f.surface.objectVisualTokens?.first
        try await f.scene(changed)
        let corrected = try Self.paths(f.surface.objects)
        XCTAssertFalse(corrected[0] === original[0]); XCTAssertTrue(corrected[1] === original[1])
        XCTAssertTrue(corrected[2] === original[2])
        try Self.assertPixels(f.surface.objects, equalTo: changed)

        let selection = ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4]
        try await f.scene([changed[2], changed[0]], selection: selection, resizable: true, textHandles: true)
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["c", "a"])
        XCTAssertEqual(f.surface.selectionBox, selection)
        XCTAssertTrue(f.surface.selectionResizable); XCTAssertTrue(f.surface.selectionTextHandles)
        try Self.assertPixels(f.surface.objects, equalTo: [changed[2], changed[0]])
        try await f.scene(rows)
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["a", "b", "c"])
        try Self.assertPixels(f.surface.objects, equalTo: rows)
        XCTAssertNil(f.surface.selectionBox); XCTAssertFalse(f.surface.selectionResizable)

        let beforeAspect = try Self.paths(f.surface.objects)
        let resizedPage = try XCTUnwrap(f.surface.pdfPage)
        resizedPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 800), for: .mediaBox)
        resizedPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 800), for: .cropBox)
        try await f.scene(rows)
        let afterAspect = try Self.paths(f.surface.objects)
        XCTAssertEqual(afterAspect.map(\.aspect), [2, 2, 2])
        XCTAssertTrue(zip(beforeAspect, afterAspect).allSatisfy { pair in pair.0 !== pair.1 })
        try Self.assertPixels(f.surface.objects, equalTo: rows, height: 800)

        var legacy = rows[0]; var legacyData = try XCTUnwrap(legacy["data"] as? [String: Any])
        legacyData["inkVersion"] = 2; legacy["data"] = legacyData
        try await f.scene([legacy])
        XCTAssertFalse(try Self.paths(f.surface.objects)[0] === afterAspect[0])
        try Self.assertPixels(f.surface.objects, equalTo: [legacy], height: 800)
        try await f.scene([])
        XCTAssertTrue(f.surface.objects.isEmpty); XCTAssertEqual(f.surface.objectVisualTokens?.count, 0)
    }

    func testPreviewWithoutPageAndMalformedPeerPreserveOrderAndFreezeCallerData() async throws {
        let f = try await Fixture(); defer { f.close() }
        let canonical = Self.ink("kept")
        try await f.snapshot([canonical])
        let style = NSMutableDictionary(dictionary: ["color": "green", "width": 0.004, "opacity": 0.7])
        let preview: [String: Any] = ["id": "native-object-preview", "kind": "rect",
            "data": ["box": ["x": 0.2, "y": 0.1, "width": 0.25, "height": 0.2]], "style": style]
        let malformed: [String: Any] = ["id": "missing-kind", "data": [:], "style": [:]]
        let idless: [String: Any] = ["kind": "line", "data": ["points": [["x": 0.1, "y": 0.8], ["x": 0.7, "y": 0.9]]],
                                   "style": ["color": "red", "width": 0.01]]
        try await f.scene([canonical, preview, malformed, idless])
        let original = f.surface.objects
        XCTAssertEqual(original.count, 4)
        XCTAssertEqual(original.compactMap { $0["id"] as? String }, ["kept", "native-object-preview", "missing-kind"])
        XCTAssertNil(original[1]["page"], "The page seed is internal; preserve the editor's actual payload")
        XCTAssertEqual(f.surface.objectVisualTokens?.count, 4)
        style["width"] = 0.9; style["color"] = "violet"
        XCTAssertEqual((f.surface.objects[1]["style"] as? [String: Any])?["width"] as? Double, 0.004)
        try Self.assertPixels(f.surface.objects, equalTo: original)
        // A tool-only refresh must not re-read mutable dictionaries from the
        // renderer or drop a valid peer because another row lacks metadata.
        try await f.snapshot([canonical], tool: "eraser")
        XCTAssertEqual((f.surface.objects[1]["style"] as? [String: Any])?["width"] as? Double, 0.004)
        XCTAssertEqual(f.surface.objects.count, 4)
        try await f.snapshot([canonical], tool: "pen")
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["kept"])
        try await f.scene([preview])
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["kept"], "Ink tools ignore editor-scene updates")
    }

    func testEditorCancellationRetainsUnacknowledgedCheckpointAndCanonicalAckOrder() async throws {
        let f = try await Fixture(); defer { f.close() }
        let first = Self.ink("canonical")
        try await f.snapshot([first]); try await f.scene([first])
        let points = [NativePDFPoint(x: 0.2, y: 0.3, p: 0.41, t: 1), NativePDFPoint(x: 0.7, y: 0.4, p: 0.62, t: 2)]
        var stroke = NativePDFCompletedStroke(mutationID: "9D047251-2C91-489A-BF48-765DCB3C9B83", kind: "ink", points: points,
            style: .init(color: "blue", width: 0.008, opacity: 0.7))
        try XCTUnwrap(f.surface.onCheckpoint)(stroke)
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["canonical", stroke.mutationID])
        let pendingPath = try XCTUnwrap(f.surface.objects.last?["_nativeInk"] as? NativePDFPreparedInk)
        for _ in 0..<3 { try await f.scene([first]) }
        XCTAssertTrue((f.surface.objects.last?["_nativeInk"] as? NativePDFPreparedInk) === pendingPath)
        try await f.scene([])
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, [stroke.mutationID],
            "An editor cancellation cannot delete an unacknowledged measured checkpoint")
        stroke.points[0].p = 0.87
        try XCTUnwrap(f.surface.onCheckpoint)(stroke)
        // A corrected checkpoint reaches the journal synchronously; its display update is coalesced (60 ms).
        let deadline = CACurrentMediaTime() + 1
        while (f.surface.objects.last?["_nativeInk"] as? NativePDFPreparedInk) === pendingPath, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse((f.surface.objects.last?["_nativeInk"] as? NativePDFPreparedInk) === pendingPath)
        let journal = try NativePDFJournal(root: f.root)
        try await f.journalQueue.barrier() // Disk-only: keep this measured checkpoint provisional.
        let checkpoint = try XCTUnwrap(journal.pending(courseID: "course", relativePath: "editor.pdf").first)
        XCTAssertEqual(checkpoint.input.data.points, stroke.points); XCTAssertTrue(checkpoint.provisional == true)
        try XCTUnwrap(f.surface.onStroke)(stroke)
        var canonical = try XCTUnwrap(f.surface.objects.last)
        canonical.removeValue(forKey: "_nativeInk"); canonical["id"] = "server-contact"
        try await f.scene([canonical, first])
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["server-contact", "canonical"])
        _ = try await f.host.handle("pdfNative:ack", request: f.identity.merging([
            "clientMutationId": stroke.mutationID, "drawingId": "server-contact"]) { _, new in new })
        XCTAssertEqual(f.surface.objects.count, 2)
        XCTAssertTrue(try journal.pending(courseID: "course", relativePath: "editor.pdf").isEmpty)
        try Self.assertPixels(f.surface.objects, equalTo: [canonical, first])
    }

    private struct BenchmarkOperation {
        let name: String
        let rows: [[String: Any]]
        var selection: [String: Double]? = nil
        var changedIDs: Set<String> = []
        var expectedFullPreparations = 0
        var checkPixels = false
    }
    private struct BenchmarkIdentity {
        let path: ObjectIdentifier
        let token: ObjectIdentifier
    }
    private static func benchmarkOperations(_ rows: [[String: Any]]) throws -> [BenchmarkOperation] {
        var output = [BenchmarkOperation(name: "first-editor", rows: rows, checkPixels: true)]
        for index in 0..<20 {
            let selection: [String: Double] = ["x": 0.1 + Double(index) * 0.001,
                                               "y": 0.2, "width": 0.3, "height": 0.4]
            output.append(BenchmarkOperation(name: "selection-\(index)", rows: rows, selection: selection))
        }
        var deleted = rows; deleted.remove(at: rows.count / 2)
        output.append(BenchmarkOperation(name: "delete-one", rows: deleted, checkPixels: true))
        let reordered = Array(deleted.reversed())
        output.append(BenchmarkOperation(name: "reorder", rows: reordered, checkPixels: true))
        var corrected = reordered
        let changedIndex = corrected.count / 3
        let changedID = try XCTUnwrap(corrected[changedIndex]["id"] as? String)
        var data = try XCTUnwrap(corrected[changedIndex]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        points[points.count / 2]["p"] = 0.97
        data["points"] = points; corrected[changedIndex]["data"] = data
        output.append(BenchmarkOperation(name: "pressure-one", rows: corrected,
            changedIDs: [changedID], expectedFullPreparations: 1, checkPixels: true))
        output.append(BenchmarkOperation(name: "undo-to-original", rows: rows,
            changedIDs: [changedID], expectedFullPreparations: 1, checkPixels: true))
        return output
    }
    private static func benchmarkIdentity(_ objects: [[String: Any]],
        tokens: [NativePDFCommittedVisualToken]?) throws -> [String: BenchmarkIdentity] {
        let tokens = try XCTUnwrap(tokens)
        XCTAssertEqual(tokens.count, objects.count)
        var output: [String: BenchmarkIdentity] = [:]
        for (object, token) in zip(objects, tokens) {
            let id = try XCTUnwrap(object["id"] as? String)
            let ink = try XCTUnwrap(object["_nativeInk"] as? NativePDFPreparedInk)
            XCTAssertNil(output.updateValue(BenchmarkIdentity(path: ObjectIdentifier(ink),
                token: ObjectIdentifier(token)), forKey: id), "The synthetic fixture must have unique IDs")
        }
        XCTAssertEqual(output.count, objects.count)
        return output
    }
    private static func assertBenchmarkIdentity(_ current: [String: BenchmarkIdentity],
        retains previous: [String: BenchmarkIdentity], except changed: Set<String>,
        file: StaticString = #filePath, line: UInt = #line) {
        for (id, value) in current {
            guard let old = previous[id] else { continue }
            if changed.contains(id) {
                XCTAssertNotEqual(value.token, old.token, "A changed pressure needs a new validated token", file: file, line: line)
                XCTAssertNotEqual(value.path, old.path, "A changed pressure needs fresh geometry", file: file, line: line)
            } else {
                XCTAssertEqual(value.token, old.token, "Unchanged row token: \(id)", file: file, line: line)
                XCTAssertEqual(value.path, old.path, "Unchanged visible path: \(id)", file: file, line: line)
            }
        }
    }
    private static func assertBenchmarkPayload(_ actual: [[String: Any]], expected: [[String: Any]],
        file: StaticString = #filePath, line: UInt = #line) throws {
        let clean = actual.map { object -> [String: Any] in
            var value = object; value.removeValue(forKey: "_nativeInk"); value.removeValue(forKey: "_nativeVisualToken")
            return value
        }
        XCTAssertEqual(clean.compactMap { $0["id"] as? String }, expected.compactMap { $0["id"] as? String }, file: file, line: line)
        let a = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        XCTAssertTrue(a == b, "Exact ordered raw JSON changed (\(benchmarkSHA(a)) vs \(benchmarkSHA(b)))", file: file, line: line)
        XCTAssertTrue(try benchmarkPointBits(clean) == benchmarkPointBits(expected),
                      "Ordered x/y/p/t Double bits changed", file: file, line: line)
    }
    private static func benchmarkPointBits(_ rows: [[String: Any]]) throws -> Data {
        var bytes = Data()
        for row in rows {
            let data = try XCTUnwrap(row["data"] as? [String: Any])
            let points = try XCTUnwrap(data["points"] as? [[String: Any]])
            for point in points {
                for key in ["x", "y", "p", "t"] {
                    let number = try XCTUnwrap(point[key] as? NSNumber)
                    var bits = number.doubleValue.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                }
            }
        }
        return bytes
    }
    private static func benchmarkPointType(_ rows: [[String: Any]]) -> [String: String] {
        guard let data = rows.first?["data"] as? [String: Any],
              let points = data["points"] as? [[String: Any]], let point = points.first else { return [:] }
        var output: [String: String] = ["data": String(reflecting: type(of: data)),
            "pointsValue": data["points"].map { String(reflecting: type(of: $0)) } ?? "missing"]
        for key in ["x", "y", "p", "t"] {
            if let number = point[key] as? NSNumber {
                output[key] = "\(type(of: number))/\(String(cString: number.objCType))"
            }
        }
        return output
    }
    private static func benchmarkSHA(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func assertBenchmarkPixels(_ actual: [[String: Any]], expected: [[String: Any]],
        file: StaticString = #filePath, line: UInt = #line) throws {
        let size = CGSize(width: 400, height: 600)
        let mapper = InkCoordinateMapper.whiteboard(size: size)
        func pixels(_ rows: [[String: Any]], raw: Bool) throws -> Data {
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
        let a = try pixels(actual, raw: false), b = try pixels(expected, raw: true)
        XCTAssertTrue(a == b, "Prepared/raw ordered RGBA differ (\(benchmarkSHA(a)) vs \(benchmarkSHA(b)))", file: file, line: line)
    }

    private static func ink(_ id: String, count: Int = 6, y: Double = 0.4) -> [String: Any] {
        var points: [[String: Any]] = []
        let denominator = Double(max(1, count - 1))
        for index in 0..<count {
            let sample = Double(index)
            let x: Double = 0.08 + sample * 0.8 / denominator
            let sampleY: Double = y + sin(sample * 0.2) * 0.004
            let pressure: Double = 0.3 + Double(index % 7) * 0.08
            let time: Double = sample
            points.append(["x": x, "y": sampleY, "p": pressure, "t": time])
        }
        return ["id": id, "page": 1, "kind": "ink", "data": ["inkVersion": 4, "points": points],
                "style": ["color": "blue", "width": 0.004, "opacity": 0.7]]
    }
    private static func pathIDs(_ objects: [[String: Any]]) -> [ObjectIdentifier] {
        objects.compactMap { $0["_nativeInk"] as? NativePDFPreparedInk }.map(ObjectIdentifier.init)
    }
    private static func paths(_ objects: [[String: Any]]) throws -> [NativePDFPreparedInk] {
        try objects.map { try XCTUnwrap($0["_nativeInk"] as? NativePDFPreparedInk) }
    }
    private static func assertPixels(_ actual: [[String: Any]], equalTo reference: [[String: Any]], height: CGFloat = 600,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 400, height: height))
        func raster(_ rows: [[String: Any]], stripMarkers: Bool) throws -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: height), format: {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; return format
            }())
            let image = renderer.image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: height))
                for var object in rows {
                    if stripMarkers { object.removeValue(forKey: "_nativeInk"); object.removeValue(forKey: "_nativeVisualToken") }
                    NativePDFObjectRenderer.draw(object, in: context.cgContext, mapper: mapper, image: nil)
                }
            }
            return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        }
        XCTAssertEqual(try raster(actual, stripMarkers: false), try raster(reference, stripMarkers: true), file: file, line: line)
    }

    @MainActor private final class Fixture {
        let journalQueue: NativePDFJournalQueue
        let root: URL, window: UIWindow, controller: UIViewController, host: NativePDFHost
        let previous: UIWindow?, oldEnabled: Any?
        let identity: [String: Any] = ["surfaceId": "editor-scene", "generation": "one", "courseId": "course", "relPath": "editor.pdf"]
        private(set) var surface: NativePDFInkSurface!
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-editor-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("editor.pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }.write(to: url)
            oldEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
            UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
            let deadline = CACurrentMediaTime() + 2
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
            let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
            journalQueue = NativePDFJournalQueue(root: root)
            host = try NativePDFHost(root: root, journalQueue: journalQueue) { channel, request in
                if channel == "nativePDF:binding" { return ["materialID": "editor-scene", "documentRevision": request["documentRevision"]!] }
                XCTAssertEqual(channel, "nativeMaterial:path"); return url.path
            }
            host.attach(to: controller.view, shell: shell)
            _ = try await host.handle("pdfNative:open", request: identity)
            _ = try await host.handle("pdfNative:layout", request: identity.merging([
                "visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
            try await snapshot([])
            let attachedDeadline = CACurrentMediaTime() + 5
            while CACurrentMediaTime() < attachedDeadline {
                controller.view.layoutIfNeeded(); host.layout()
                if let value = Self.find(in: controller.view).first, value.mapper != nil { surface = value; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            surface = try XCTUnwrap(surface)
        }
        func snapshot(_ rows: [[String: Any]], tool: String = "eraser") async throws {
            _ = try await host.handle("pdfNative:snapshot", request: identity.merging([
                "loading": false, "active": true, "drawings": rows, "annotations": [],
                "tool": ["name": tool, "style": ["color": "blue", "width": 0.004, "opacity": 0.7]]]) { _, new in new })
        }
        func scene(_ rows: [[String: Any]], selection: [String: Double]? = nil,
                   resizable: Bool = false, textHandles: Bool = false) async throws {
            var request: [String: Any] = ["page": 1, "objects": rows, "resizable": resizable, "textHandles": textHandles]
            request["selection"] = selection
            _ = try await host.handle("pdfNative:objectScene", request: identity.merging(request) { _, new in new })
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
