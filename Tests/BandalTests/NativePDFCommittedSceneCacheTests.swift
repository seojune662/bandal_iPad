import XCTest
import UIKit
import JavaScriptCore
@testable import Bandal

@MainActor
final class NativePDFCommittedSceneCacheTests: XCTestCase {
    func testOptInPrivateReplayRetainsUnchangedSceneAndCanonicalHandoff() throws {
        // Optional local diagnostics: set this test process environment value
        // to an external JSON file. Private drawings never become test assets.
        guard let path = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_INK_REPLAY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set BANDAL_PRIVATE_INK_REPLAY_PATH to run a local private replay")
        }
        let url = URL(fileURLWithPath: path)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(raw.count, 5, "The local replay needs at least five final ink rows")
        guard raw.count >= 5 else { return }
        let store = NativePDFDrawingSnapshotStore(), cache = NativePDFCommittedSceneCache(), background = paper()
        try store.apply(["drawings": raw], pageCount: 1)
        var objects = store.orderedRows.map { $0.prepared(aspect: 512.0 / 384) }
        var tokens = store.orderedRows.map(\.visualToken)
        let first = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: objects.count)
        let initialMS = cache.lastRenderElapsedMS
        for attempt in 0..<10 {
            try store.apply(["drawings": raw], pageCount: 1)
            objects = store.orderedRows.map { $0.prepared(aspect: 512.0 / 384) }; tokens = store.orderedRows.map(\.visualToken)
            let next = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: objects.count)
            XCTAssertTrue(first === next); XCTAssertEqual(cache.lastRenderMode, "reuse"); XCTAssertEqual(cache.lastDrawnObjectCount, 0)
            XCTAssertEqual(cache.fullRenderCount, 1, "Actual unchanged scene replay \(attempt)")
        }
        print("PRIVATE_INK_REPLAY rows=\(objects.count) initialMS=\(initialMS) noopMS=\(cache.lastRenderElapsedMS) full=\(cache.fullRenderCount)")

        // Replay the actual final five payloads through the native pending,
        // estimated-pressure, finalized and canonical ACK identities. Their
        // private coordinates remain exclusively in the local input file.
        let lifecycle = NativePDFCommittedSceneCache()
        var live = Array(raw.dropLast(5))
        func renderLive(_ boundary: Int) throws {
            let prepared = live.map { object -> [String: Any] in
                var value = object
                value["_nativeInk"] = NativePDFObjectRenderer.prepareInk(object, aspect: 512.0 / 384)
                return value
            }
            _ = try render(lifecycle, paper: background, objects: prepared,
                visualTokens: live.map(NativePDFCommittedVisualToken.init), mutableObjectStartIndex: boundary)
        }
        try renderLive(live.count)
        for (sequence, canonical) in raw.suffix(5).enumerated() {
            let index = live.count, mutation = "private-probe-\(sequence)"
            var pending = canonical; pending["id"] = mutation; pending["clientMutationId"] = mutation
            var data = try XCTUnwrap(pending["data"] as? [String: Any])
            var points = try XCTUnwrap(data["points"] as? [[String: Any]])
            let finalPressure = try XCTUnwrap(points.last?["p"] as? Double)
            points[points.count-1]["p"] = finalPressure < 0.5 ? finalPressure + 0.02 : finalPressure - 0.02
            data["points"] = points; pending["data"] = data
            live.append(pending); try renderLive(index)
            XCTAssertEqual(lifecycle.lastRenderMode, "append")
            XCTAssertEqual(lifecycle.lastDrawnObjectCount, 1)
            points[points.count-1]["p"] = finalPressure
            data["points"] = points; pending["data"] = data; live[index] = pending
            try renderLive(index)
            XCTAssertEqual(lifecycle.lastRenderMode, "tail")
            XCTAssertEqual(lifecycle.lastDrawnObjectCount, 1)
            try renderLive(live.count)
            XCTAssertEqual(lifecycle.lastRenderMode, "reuse")
            var acknowledged = canonical; acknowledged["clientMutationId"] = mutation
            live[index] = acknowledged; try renderLive(live.count)
            XCTAssertEqual(lifecycle.lastRenderMode, "reuse")
            XCTAssertEqual(lifecycle.fullRenderCount, 1)
        }
        print("PRIVATE_INK_LIFECYCLE rows=\(live.count) full=\(lifecycle.fullRenderCount) append=\(lifecycle.appendRenderCount) tail=\(lifecycle.tailRenderCount) noopMS=\(lifecycle.lastRenderElapsedMS)")
    }
    private let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 384, height: 512))

    private func paper(size: CGSize = CGSize(width: 384, height: 512), scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.82, alpha: 1).setFill()
            context.fill(CGRect(x: 17.25, y: 11.5, width: 1.25, height: size.height - 20))
        }
    }

    private func stroke(_ index: Int, count: Int = 12, kind: String = "ink") throws -> [String: Any] {
        let points: [[String: Any]] = (0..<count).map { sample in
            let t = Double(sample) / Double(max(1, count - 1))
            return ["x": 0.1 + t * 0.8, "y": 0.1 + Double(index % 16) * 0.045 + sin(t * .pi * 4) * 0.035,
                    "p": 0.25 + 0.45 * t, "t": Double(sample) * 1000 / 240]
        }
        var object: [String: Any] = ["id": "stroke-\(index)", "clientMutationId": "local-\(index)",
            "kind": kind, "data": ["inkVersion": 4, "points": points],
            "style": ["color": index.isMultiple(of: 2) ? "blue" : "red", "width": kind == "highlighter" ? 0.035 : 0.008, "opacity": 0.42]]
        object["_nativeInk"] = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(object, aspect: 512.0 / 384))
        return object
    }

    private func render(_ cache: NativePDFCommittedSceneCache, paper: UIImage, objects: [[String: Any]],
                        bounds: CGRect? = nil, mapper: InkCoordinateMapper? = nil,
                        highlights: [[String: Any]] = [], visualTokens: [NativePDFCommittedVisualToken]? = nil,
                        mutableObjectStartIndex: Int? = nil) throws -> UIImage {
        let mapping = mapper ?? self.mapper
        return try XCTUnwrap(cache.render(paper: paper, mapper: mapping,
            bounds: bounds ?? CGRect(origin: .zero, size: paper.size), highlights: highlights, objects: objects,
            visualTokens: visualTokens, mutableObjectStartIndex: mutableObjectStartIndex,
            drawHighlights: { context in
                guard !highlights.isEmpty else { return }
                context.saveGState(); defer { context.restoreGState() }
                context.setBlendMode(.multiply); context.setAlpha(0.35)
                context.setFillColor(UIColor.yellow.cgColor)
                context.fill(CGRect(x: 24.5, y: 32.25, width: 260, height: 72.5))
            }, drawObject: { NativePDFObjectRenderer.draw($0, in: $1, mapper: mapping, image: nil) }))
    }

    /// Independent flat replay never uses the scene/checkpoint cache.
    private func flatReplay(paper: UIImage, objects: [[String: Any]], bounds: CGRect? = nil) -> UIImage {
        let bounds = bounds ?? CGRect(origin: .zero, size: paper.size)
        let format = UIGraphicsImageRendererFormat(); format.scale = paper.scale; format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            // The paper already has the requested pixel scale. A fractional
            // logical viewport crops it; it must not squeeze those pixels.
            renderer.cgContext.saveGState()
            renderer.cgContext.interpolationQuality = .none
            paper.draw(at: .zero, blendMode: .copy, alpha: 1)
            renderer.cgContext.restoreGState()
            renderer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            for object in objects { NativePDFObjectRenderer.draw(object, in: renderer.cgContext, mapper: mapper, image: nil) }
        }
    }

    private func correctPressure(_ objects: inout [[String: Any]], at index: Int) throws {
        var data = try XCTUnwrap(objects[index]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        let sample = max(0, points.count - 4)
        points[sample]["p"] = ((points[sample]["p"] as? Double) ?? 0.5) + 0.02
        data["points"] = points; objects[index]["data"] = data
        // Deliberately retain the old _nativeInk. Actual payload validation
        // must reject that prepared reference and build corrected geometry.
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }

    func testAppendMatchesFullReplayForOpacityHighlighterCrossingsAndFractionalViewport() throws {
        for scale: CGFloat in [1, 2] {
            let background = paper(scale: scale), cache = NativePDFCommittedSceneCache()
            let bounds = CGRect(x: 0.25, y: 0.125, width: 383.375, height: 511.25)
            let highlights: [[String: Any]] = [["rects": [["x": 0.1, "y": 0.1, "width": 0.5, "height": 0.2]], "color": "yellow"]]
            var objects: [[String: Any]] = []
            for index in 0..<24 {
                objects.append(try stroke(index % 4, kind: index.isMultiple(of: 3) ? "highlighter" : "ink"))
                let actual = try render(cache, paper: background, objects: objects, bounds: bounds, highlights: highlights)
                if [0, 1, 7, 23].contains(index) {
                    let expected = try render(NativePDFCommittedSceneCache(), paper: background,
                        objects: objects, bounds: bounds, highlights: highlights)
                    XCTAssertTrue(try pixels(actual) == pixels(expected), "Append \(index), scale \(scale) must retain old pixels and object order")
                }
                XCTAssertEqual(cache.lastDrawnObjectCount, index < 4 ? 1 : 2)
            }
            XCTAssertEqual(cache.fullRenderCount, 1); XCTAssertEqual(cache.appendRenderCount, 23)
        }
    }

    func testTransportAcknowledgementDoesNotRenderAgain() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        var objects = try [stroke(0), stroke(1)]
        let original = try render(cache, paper: background, objects: objects)
        for index in objects.indices {
            objects[index]["id"] = "server-\(index)"
            objects[index]["createdAt"] = "2026-10-15T12:00:00Z"
            objects[index]["updatedAt"] = "2026-10-15T12:00:01Z"
            objects[index]["clientMutationId"] = nil
            objects[index]["_nativeInk"] = nil
        }
        let acknowledged = try render(cache, paper: background, objects: objects)
        XCTAssertTrue(original === acknowledged)
        XCTAssertEqual(cache.lastDrawnObjectCount, 0); XCTAssertEqual(cache.reuseCount, 1)
        XCTAssertEqual(cache.fullRenderCount, 1); XCTAssertEqual(cache.appendRenderCount, 0)
    }

    func testCorrectionsDeletionUndoAndOrderChangesRebuildEvenWithStalePreparedInk() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        let initial = try [stroke(0), stroke(1), stroke(2)]
        _ = try render(cache, paper: background, objects: initial)
        var corrected = initial
        var data = try XCTUnwrap(corrected[0]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        points[3]["x"] = 0.75; data["points"] = points; corrected[0]["data"] = data
        XCTAssertTrue((corrected[0]["_nativeInk"] as? NativePDFPreparedInk) === (initial[0]["_nativeInk"] as? NativePDFPreparedInk))
        var changes = [corrected, Array(corrected.dropFirst()), initial, [initial[1], initial[0], initial[2]]]
        var changedStyle = initial; changedStyle[0]["style"] = ["color": "green", "width": 0.02, "opacity": 0.3]
        var changedKind = initial; changedKind[0]["kind"] = "highlighter"
        var changedPath = initial; changedPath[0]["nativePath"] = "M 0 0 L 1 0 L 1 1 Z"
        changes += [changedStyle, changedKind, changedPath]
        for (index, objects) in changes.enumerated() {
            let actual = try render(cache, paper: background, objects: objects)
            let expected = try render(NativePDFCommittedSceneCache(), paper: background, objects: objects)
            XCTAssertTrue(try pixels(actual) == pixels(expected))
            XCTAssertEqual(cache.lastDrawnObjectCount, objects.count)
            XCTAssertEqual(cache.fullRenderCount, index + 2)
        }
    }

    func testPaperViewportMapperHighlightsAndExplicitInvalidationRebuild() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache(), objects = try [stroke(0)]
        _ = try render(cache, paper: background, objects: objects)
        _ = try render(cache, paper: background, objects: objects, bounds: CGRect(x: 1, y: 2, width: 380, height: 500))
        XCTAssertEqual(cache.fullRenderCount, 2)
        var moved = mapper; moved.canvasToPDF.tx = 1
        _ = try render(cache, paper: background, objects: objects, mapper: moved)
        XCTAssertEqual(cache.fullRenderCount, 3)
        let highlights: [[String: Any]] = [["rects": [["x": 0.1, "y": 0.1]], "color": "yellow", "nativeOpacity": 0.4]]
        let first = try render(cache, paper: background, objects: objects, highlights: highlights)
        XCTAssertEqual(cache.fullRenderCount, 4)
        var ack = highlights; ack[0]["id"] = "server-highlight"
        XCTAssertTrue(first === (try render(cache, paper: background, objects: objects, highlights: ack)))
        ack[0]["nativeOpacity"] = 0.6
        _ = try render(cache, paper: background, objects: objects, highlights: ack)
        XCTAssertEqual(cache.fullRenderCount, 5)
        _ = try render(cache, paper: paper(), objects: objects, highlights: ack)
        XCTAssertEqual(cache.fullRenderCount, 6)
        cache.invalidate(); XCTAssertNil(cache.image)
        _ = try render(cache, paper: background, objects: objects, highlights: ack)
        XCTAssertEqual(cache.fullRenderCount, 7)
    }

    func testBooleanAndNumericAppearanceValuesAreDistinct() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        var object = try stroke(0)
        object["style"] = ["width": 1, "color": "blue"]
        _ = try render(cache, paper: background, objects: [object])
        object["style"] = ["width": true, "color": "blue"]
        _ = try render(cache, paper: background, objects: [object])
        XCTAssertEqual(cache.fullRenderCount, 2)
        XCTAssertNil(cache.render(paper: background, mapper: mapper, bounds: .zero,
            highlights: [], objects: [object], drawHighlights: { _ in XCTFail() }, drawObject: { _, _ in XCTFail() }))
        XCTAssertNil(cache.image)
    }

    func testTwoHundredRealStrokesAdvanceCheckpointWithBoundedWorkAndReportTotalSceneCost() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        let objects = try (0..<200).map { try stroke($0, count: 96, kind: $0.isMultiple(of: 8) ? "highlighter" : "ink") }
        // Native store creates a token only when a new or changed row arrives.
        let tokenStart = CACurrentMediaTime(), tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        print("Committed scene tokens: \((CACurrentMediaTime() - tokenStart) * 1000 / 200)ms per new 96-point stroke")
        var appendMS = 0.0, fullMS = 0.0
        for end in 1...objects.count {
            let prefix = Array(objects.prefix(end)), start = CACurrentMediaTime()
            _ = try render(cache, paper: background, objects: prefix, visualTokens: Array(tokens.prefix(end)))
            let elapsed = (CACurrentMediaTime() - start) * 1000
            XCTAssertEqual(cache.lastDrawnObjectCount, end <= 4 ? 1 : 2)
            XCTAssertEqual(cache.lastCheckpointDrawnObjectCount, end <= 4 ? 0 : 1)
            XCTAssertEqual(cache.lastComparedVisualPayloadCount, 0, "Unchanged native rows must not rescan old raw points")
            if [1, 50, 100, 200].contains(end) {
                let baseline = CACurrentMediaTime()
                _ = try render(NativePDFCommittedSceneCache(), paper: background, objects: prefix)
                let full = (CACurrentMediaTime() - baseline) * 1000
                print("Committed scene \(end)x96 samples: native token append \(elapsed)ms; full replay \(full)ms")
                if end == 200 { appendMS = elapsed; fullMS = full }
            }
        }
        XCTAssertEqual(cache.fullRenderCount, 1); XCTAssertEqual(cache.appendRenderCount, 199)
        var acknowledged = objects
        for index in acknowledged.indices { acknowledged[index]["id"] = "server-\(index)"; acknowledged[index]["createdAt"] = index }
        let old = cache.image, ackStart = CACurrentMediaTime()
        let ack = try render(cache, paper: background, objects: acknowledged, visualTokens: tokens)
        let ackMS = (CACurrentMediaTime() - ackStart) * 1000
        XCTAssertTrue(old === ack); XCTAssertEqual(cache.lastDrawnObjectCount, 0)
        XCTAssertEqual(cache.lastComparedVisualPayloadCount, 0)
        print("Committed scene 200x96: native token append \(appendMS)ms; full \(fullMS)ms; metadata ACK \(ackMS)ms")
    }

    func testNewTokensCompareActualAppearanceAndBecomeTheNextFastPrefix() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache(), objects = try [stroke(0), stroke(1)]
        let tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        let first = try render(cache, paper: background, objects: objects, visualTokens: tokens)
        let equivalentTokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        XCTAssertTrue(first === (try render(cache, paper: background, objects: objects, visualTokens: equivalentTokens)))
        XCTAssertEqual(cache.lastComparedVisualPayloadCount, 2)
        _ = try render(cache, paper: background, objects: objects, visualTokens: equivalentTokens)
        XCTAssertEqual(cache.lastComparedVisualPayloadCount, 0)
        var changed = objects; changed[0]["style"] = ["color": "green", "width": 0.012, "opacity": 0.6]
        let changedTokens = [NativePDFCommittedVisualToken(object: changed[0]), equivalentTokens[1]]
        _ = try render(cache, paper: background, objects: changed, visualTokens: changedTokens)
        XCTAssertEqual(cache.fullRenderCount, 2); XCTAssertEqual(cache.lastDrawnObjectCount, 2)
        // A malformed internal call still follows the safe raw payload path.
        _ = try render(cache, paper: background, objects: objects, visualTokens: [])
        XCTAssertEqual(cache.fullRenderCount, 3)
    }

    func testVisualSnapshotFreezesMutablePayloadAndDirectAssignmentInvalidatesTrustedTokens() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        var object = try stroke(0)
        let mutable = NSMutableDictionary(dictionary: ["color": "blue", "width": 0.008, "opacity": 0.42])
        object["style"] = mutable
        let token = NativePDFCommittedVisualToken(object: object)
        _ = try render(cache, paper: background, objects: [object], visualTokens: [token])
        mutable["color"] = "red"
        let updatedToken = NativePDFCommittedVisualToken(object: object)
        _ = try render(cache, paper: background, objects: [object], visualTokens: [updatedToken])
        XCTAssertEqual(cache.fullRenderCount, 2, "The old immutable snapshot must retain blue")
        let surface = try XCTUnwrap(NativePDFInkSurface())
        surface.applyObjects(objects: [object], visualTokens: [updatedToken])
        XCTAssertTrue(surface.objectVisualTokens?.first === updatedToken)
        object["_nativeVisualToken"] = updatedToken
        surface.objects = [object]
        XCTAssertNil(surface.objectVisualTokens, "Dictionary-carried markers never authorize the trusted fast path")
    }
    func testTwoHundredStrokeLatePressureCorrectionsReplayAtMostFourObjects() throws {
        for scale: CGFloat in [1, 2] {
            let background = paper(scale: scale), cache = NativePDFCommittedSceneCache()
            var objects = try (0..<200).map { try stroke($0, count: 96,
                kind: $0.isMultiple(of: 2) ? "highlighter" : "ink") }
            var tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
            _ = try render(cache, paper: background, objects: objects, visualTokens: tokens)
            XCTAssertEqual(cache.lastDrawnObjectCount, 200)
            for index in [199, 198, 196] {
                try correctPressure(&objects, at: index)
                tokens[index] = NativePDFCommittedVisualToken(object: objects[index])
                let start = CACurrentMediaTime()
                let actual = try render(cache, paper: background, objects: objects, visualTokens: tokens)
                let tailMS = (CACurrentMediaTime() - start) * 1000
                let baseline = CACurrentMediaTime(), expected = flatReplay(paper: background, objects: objects)
                let fullMS = (CACurrentMediaTime() - baseline) * 1000
                XCTAssertEqual(cache.lastRenderMode, "tail")
                XCTAssertEqual(cache.lastReplayStartIndex, 196)
                XCTAssertEqual(cache.lastDrawnObjectCount, 4)
                XCTAssertEqual(cache.lastCheckpointDrawnObjectCount, 0)
                XCTAssertEqual(cache.lastComparedVisualPayloadCount, 1)
                XCTAssertTrue(try pixels(actual) == pixels(expected), "Corrected opacity/highlighter pixels must match independent flat replay")
                print("Tail correction200x96 scale=\(scale) index=\(index): bounded4=\(tailMS)ms; flat200=\(fullMS)ms")
            }
            XCTAssertEqual(cache.fullRenderCount, 1); XCTAssertEqual(cache.tailRenderCount, 3)
        }
    }

    func testCheckpointAdvancesAcrossCorrectionThenAppendAndMatchesFractionalPixels() throws {
        let background = paper(scale: 2), cache = NativePDFCommittedSceneCache()
        let bounds = CGRect(x: 0.25, y: 0.125, width: 383.375, height: 511.25)
        var objects: [[String: Any]] = [], tokens: [NativePDFCommittedVisualToken] = []
        _ = try render(cache, paper: background, objects: objects, bounds: bounds, visualTokens: tokens)
        for index in 0..<32 {
            objects.append(try stroke(index, count: 24, kind: index.isMultiple(of: 3) ? "highlighter" : "ink"))
            tokens.append(NativePDFCommittedVisualToken(object: objects[index]))
            _ = try render(cache, paper: background, objects: objects, bounds: bounds, visualTokens: tokens)
            XCTAssertLessThanOrEqual(cache.lastDrawnObjectCount, 2)
            if index >= 5, index.isMultiple(of: 3) {
                let corrected = index - 1
                try correctPressure(&objects, at: corrected)
                tokens[corrected] = NativePDFCommittedVisualToken(object: objects[corrected])
                let actual = try render(cache, paper: background, objects: objects, bounds: bounds, visualTokens: tokens)
                XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastDrawnObjectCount, 4)
                XCTAssertTrue(try pixels(actual) == pixels(flatReplay(paper: background, objects: objects, bounds: bounds)))
            }
        }
        XCTAssertEqual(cache.fullRenderCount, 1, "No tail correction may invalidate the accumulated prefix")
        let final = try render(cache, paper: background, objects: objects, bounds: bounds, visualTokens: tokens)
        XCTAssertEqual(cache.lastRenderMode, "reuse")
        XCTAssertTrue(try pixels(final) == pixels(flatReplay(paper: background, objects: objects, bounds: bounds)))
    }

    func testEarlierEditsDeletionAndTailReorderingStillRebuildFullScene() throws {
        let background = paper(), initial = try (0..<12).map { try stroke($0) }
        var earlier = initial; try correctPressure(&earlier, at: 7)
        var reordered = initial; reordered.swapAt(10, 11)
        let changes = [earlier, Array(initial.dropLast()), reordered, []]
        for objects in changes {
            let cache = NativePDFCommittedSceneCache()
            _ = try render(cache, paper: background, objects: initial)
            let actual = try render(cache, paper: background, objects: objects)
            XCTAssertEqual(cache.lastRenderMode, "full"); XCTAssertEqual(cache.fullRenderCount, 2)
            XCTAssertEqual(cache.lastDrawnObjectCount, objects.count)
            XCTAssertTrue(try pixels(actual) == pixels(flatReplay(paper: background, objects: objects)))
        }
    }

    func testCanonicalAcknowledgementCoalescedWithTailCorrectionKeepsStablePrefix() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        var objects = try (0..<20).map { try stroke($0, count: 24) }
        let tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        _ = try render(cache, paper: background, objects: objects, visualTokens: tokens)
        for index in objects.indices { objects[index]["id"] = "canonical-\(index)" }
        try correctPressure(&objects, at: 18)
        let nextTokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        let actual = try render(cache, paper: background, objects: objects, visualTokens: nextTokens)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.fullRenderCount, 1)
        XCTAssertEqual(cache.lastDrawnObjectCount, 4)
        XCTAssertTrue(try pixels(actual) == pixels(flatReplay(paper: background, objects: objects)))
    }

    func testJavaScriptCanonicalAckReusesIdenticalBinaryPressure() throws {
        // A synthetic force value exercises the actual Swift -> JavaScript ->
        // native JSON path, including a value that Foundation's decimal box
        // previously changed before the canonical acknowledgement arrived.
        let input = NativePDFStrokeInput(courseId: "fixture", relPath: "paper.pdf", page: 1, kind: "ink",
            data: NativePDFStrokeData(points: [
                NativePDFPoint(x: 0.2, y: 0.3, p: 0.5, t: 0),
                NativePDFPoint(x: 0.4, y: 0.5, p: 2.0 / 12345.0, t: 12)
            ]), style: NativePDFInkStyle(color: "blue", width: 0.008, opacity: 0.42),
            clientMutationId: UUID().uuidString)
        var pending = try NativePDFHost.json(input)
        pending["id"] = input.clientMutationId
        let context = try XCTUnwrap(JSContext())
        context.setObject(pending, forKeyedSubscript: "pending" as NSString)
        var canonical = try XCTUnwrap(context.evaluateScript("JSON.parse(JSON.stringify(pending))")?.toDictionary() as? [String: Any])
        XCTAssertNil(context.exception)
        canonical["id"] = "canonical-fixture"
        let store = NativePDFDrawingSnapshotStore()
        let nativeRow = try store.makeRow(pending, pageCount: 1)
        let canonicalRow = try store.makeRow(canonical, pageCount: 1)
        func pressure(_ row: NativePDFDrawingSnapshotStore.Row) throws -> NSNumber {
            let data = try XCTUnwrap(row.object["data"] as? [String: Any])
            let points = try XCTUnwrap(data["points"] as? [[String: Any]])
            return try XCTUnwrap(points.last?["p"] as? NSNumber)
        }
        let nativePressure = try pressure(nativeRow), canonicalPressure = try pressure(canonicalRow)
        XCTAssertEqual(nativePressure.doubleValue.bitPattern, input.data.points[1].p.bitPattern)
        XCTAssertEqual(nativePressure.doubleValue.bitPattern, canonicalPressure.doubleValue.bitPattern)
        XCTAssertTrue(nativeRow.visualToken.hasSameAppearance(as: canonicalRow.visualToken))

        let background = paper(), cache = NativePDFCommittedSceneCache()
        let prefix = try (0..<12).map { try stroke($0) }
        let tokens = prefix.map(NativePDFCommittedVisualToken.init)
        let before = try render(cache, paper: background,
            objects: prefix + [nativeRow.prepared(aspect: 512.0 / 384)],
            visualTokens: tokens + [nativeRow.visualToken], mutableObjectStartIndex: 13)
        let after = try render(cache, paper: background,
            objects: prefix + [canonicalRow.prepared(aspect: 512.0 / 384)],
            visualTokens: tokens + [canonicalRow.visualToken], mutableObjectStartIndex: 13)
        XCTAssertTrue(after === before)
        XCTAssertEqual(cache.lastRenderMode, "reuse")
        XCTAssertEqual(cache.lastDrawnObjectCount, 0)
        XCTAssertEqual(cache.fullRenderCount, 1, "An ACK must not replay all completed ink")
        XCTAssertTrue(try pixels(after) == pixels(flatReplay(paper: background,
            objects: prefix + [canonicalRow.prepared(aspect: 512.0 / 384)])))
    }

    func testVisualNumberComparisonKeepsTypesAndExactBinaryChangesDistinct() {
        func token(_ number: Any) -> NativePDFCommittedVisualToken {
            NativePDFCommittedVisualToken(object: ["kind": "ink", "style": ["width": number]])
        }
        XCTAssertTrue(token(NSNumber(value: 0.5)).hasSameAppearance(as: token(NSDecimalNumber(string: "0.5"))))
        // Non-store callers can still supply Foundation decimal boxes. Match
        // their exact rendered binary values, not their decimal spelling.
        let a = NSDecimalNumber(string: "0.00016200891049007697")
        let b = NSDecimalNumber(string: "0.00016200891049007689")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.doubleValue.bitPattern, b.doubleValue.bitPattern)
        XCTAssertTrue(token(a).hasSameAppearance(as: token(b)))
        XCTAssertTrue(token(NSNumber(value: -0.0)).hasSameAppearance(as: token(NSNumber(value: 0.0))))
        XCTAssertFalse(token(NSNumber(value: 0.5)).hasSameAppearance(as: token(NSNumber(value: Double(0.5).nextUp))))
        XCTAssertFalse(token(NSNumber(value: true)).hasSameAppearance(as: token(NSNumber(value: 1))))
        XCTAssertFalse(token(NSNumber(value: 0.5)).hasSameAppearance(as: token("0.5")))
        for number in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(token(NSNumber(value: number)).hasSameAppearance(as: token(NSNumber(value: number))))
        }
    }

    func testAdoptedNavigationSnapshotKeepsTailCorrectionsAndAppendsPixelExact() throws {
        let background = paper(scale: 2), cache = NativePDFCommittedSceneCache()
        var objects = try (0..<12).map { try stroke($0, count: 24, kind: $0.isMultiple(of: 3) ? "highlighter" : "ink") }
        var tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        let prefix = flatReplay(paper: background, objects: Array(objects.prefix(8)))
        let full = flatReplay(paper: background, objects: objects)
        XCTAssertTrue(cache.adopt(paper: background, image: full, stablePrefixImage: prefix, stablePrefixCount: 8,
            mapper: mapper, bounds: CGRect(origin: .zero, size: background.size), highlights: [], objects: objects, visualTokens: tokens))
        XCTAssertTrue(cache.image === full); XCTAssertEqual(cache.lastRenderMode, "adopt")
        XCTAssertEqual(cache.lastDrawnObjectCount, 0); XCTAssertEqual(cache.adoptCount, 1)
        XCTAssertTrue(full === (try render(cache, paper: background, objects: objects, visualTokens: tokens)))
        try correctPressure(&objects, at: 10); tokens[10] = NativePDFCommittedVisualToken(object: objects[10])
        let corrected = try render(cache, paper: background, objects: objects, visualTokens: tokens)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastDrawnObjectCount, 4)
        XCTAssertTrue(try pixels(corrected) == pixels(flatReplay(paper: background, objects: objects)))
        objects.append(try stroke(12, count: 24)); tokens.append(NativePDFCommittedVisualToken(object: objects[12]))
        let appended = try render(cache, paper: background, objects: objects, visualTokens: tokens)
        XCTAssertEqual(cache.lastRenderMode, "append"); XCTAssertEqual(cache.lastDrawnObjectCount, 2)
        XCTAssertEqual(cache.fullRenderCount, 0)
        XCTAssertTrue(try pixels(appended) == pixels(flatReplay(paper: background, objects: objects)))
    }

    func testInvalidNavigationAdoptionPreservesExistingSceneAndEmptyAdoptionWorks() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache(), objects = try (0..<8).map { try stroke($0) }
        let old = try render(cache, paper: background, objects: objects)
        let prefix = flatReplay(paper: background, objects: Array(objects.prefix(4)))
        let full = flatReplay(paper: background, objects: objects), bounds = CGRect(origin: .zero, size: background.size)
        let wrongSize = paper(size: CGSize(width: 200, height: 200)), wrongScale = paper(scale: 2)
        for (image, prefixImage, count, area) in [(full, Optional(prefix), 3, bounds), (full, nil, 4, bounds),
            (wrongSize, Optional(prefix), 4, bounds), (wrongScale, Optional(prefix), 4, bounds), (full, Optional(prefix), 4, .zero)] {
            XCTAssertFalse(cache.adopt(paper: background, image: image, stablePrefixImage: prefixImage, stablePrefixCount: count,
                mapper: mapper, bounds: area, highlights: [], objects: objects))
            XCTAssertTrue(cache.image === old); XCTAssertEqual(cache.adoptCount, 0)
        }
        XCTAssertTrue(cache.adopt(paper: background, image: background, stablePrefixImage: nil, stablePrefixCount: 0,
            mapper: mapper, bounds: bounds, highlights: [], objects: []))
        XCTAssertTrue(cache.image === background); XCTAssertEqual(cache.lastDrawnObjectCount, 0)
        let appended = try render(cache, paper: background, objects: [try stroke(0)])
        XCTAssertEqual(cache.lastRenderMode, "append"); XCTAssertEqual(cache.lastDrawnObjectCount, 1)
        XCTAssertTrue(try pixels(appended) == pixels(flatReplay(paper: background, objects: [try stroke(0)])))
    }

    func testEightUnresolvedContactsKeepEarliestPressureMutableAndPromoteWithoutReplay() throws {
        let background = paper(), cache = NativePDFCommittedSceneCache()
        var objects = try (0..<200).map { try stroke($0, count: 96, kind: $0.isMultiple(of: 4) ? "highlighter" : "ink") }
        var tokens = objects.map { NativePDFCommittedVisualToken(object: $0) }
        _ = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 200)
        XCTAssertEqual(cache.lastDrawnObjectCount, 200)
        for index in 200..<208 {
            objects.append(try stroke(index, count: 96, kind: index.isMultiple(of: 3) ? "highlighter" : "ink"))
            tokens.append(NativePDFCommittedVisualToken(object: objects[index]))
            _ = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 200)
            XCTAssertEqual(cache.lastRenderMode, "append"); XCTAssertEqual(cache.lastDrawnObjectCount, 1)
            XCTAssertEqual(cache.lastCheckpointDrawnObjectCount, 0)
        }
        try correctPressure(&objects, at: 200); tokens[200] = NativePDFCommittedVisualToken(object: objects[200])
        let corrected = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 200)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastReplayStartIndex, 200)
        XCTAssertEqual(cache.lastDrawnObjectCount, 8); XCTAssertEqual(cache.fullRenderCount, 1)
        let correctionMS = cache.lastRenderElapsedMS
        XCTAssertTrue(try pixels(corrected) == pixels(flatReplay(paper: background, objects: objects)))
        let promoted = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 208)
        XCTAssertTrue(promoted === corrected); XCTAssertEqual(cache.lastRenderMode, "reuse")
        XCTAssertEqual(cache.lastDrawnObjectCount, 0); XCTAssertEqual(cache.lastCheckpointDrawnObjectCount, 0)
        let promotionMS = cache.lastRenderElapsedMS
        objects.append(try stroke(208, count: 96)); tokens.append(NativePDFCommittedVisualToken(object: objects[208]))
        _ = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 208)
        XCTAssertEqual(cache.lastDrawnObjectCount, 1)
        try correctPressure(&objects, at: 208); tokens[208] = NativePDFCommittedVisualToken(object: objects[208])
        let finalized = try render(cache, paper: background, objects: objects, visualTokens: tokens, mutableObjectStartIndex: 209)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastDrawnObjectCount, 1)
        XCTAssertEqual(cache.lastCheckpointDrawnObjectCount, 0); XCTAssertEqual(cache.fullRenderCount, 1)
        XCTAssertTrue(try pixels(finalized) == pixels(flatReplay(paper: background, objects: objects)))
        print("INK_SCENE_UNRESOLVED old=200 pending=8 correctionMS=\(correctionMS) promotionMS=\(promotionMS) correctionDraws=8 promotionDraws=0")
    }

    func testDynamicZeroPrefixPreservesHighlightsAndRejectsPrematureAdoption() throws {
        let background = paper(scale: 2), cache = NativePDFCommittedSceneCache()
        let highlights: [[String: Any]] = [["rects": [["x": 0.1, "y": 0.1]], "color": "yellow"]]
        var objects = try (0..<8).map { try stroke($0, count: 24, kind: $0.isMultiple(of: 2) ? "highlighter" : "ink") }
        _ = try render(cache, paper: background, objects: objects, highlights: highlights, mutableObjectStartIndex: 0)
        try correctPressure(&objects, at: 0)
        let corrected = try render(cache, paper: background, objects: objects, highlights: highlights, mutableObjectStartIndex: 0)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastDrawnObjectCount, 8)
        XCTAssertEqual(cache.fullRenderCount, 1)
        let expected = try render(NativePDFCommittedSceneCache(), paper: background, objects: objects, highlights: highlights)
        XCTAssertTrue(try pixels(corrected) == pixels(expected))
        XCTAssertFalse(cache.adopt(paper: background, image: corrected,
            stablePrefixImage: flatReplay(paper: background, objects: Array(objects.prefix(4))), stablePrefixCount: 4,
            mapper: mapper, bounds: CGRect(origin: .zero, size: background.size), highlights: highlights,
            objects: objects, mutableObjectStartIndex: 0), "A navigation crop must not freeze four unresolved contacts")
        XCTAssertTrue(cache.adopt(paper: background, image: corrected, stablePrefixImage: nil, stablePrefixCount: 0,
            mapper: mapper, bounds: CGRect(origin: .zero, size: background.size), highlights: highlights,
            objects: objects, mutableObjectStartIndex: 0))
        try correctPressure(&objects, at: 0)
        let afterAdoption = try render(cache, paper: background, objects: objects, highlights: highlights, mutableObjectStartIndex: 0)
        XCTAssertEqual(cache.lastRenderMode, "tail"); XCTAssertEqual(cache.lastDrawnObjectCount, 8)
        XCTAssertTrue(try pixels(afterAdoption) == pixels(try render(NativePDFCommittedSceneCache(), paper: background,
            objects: objects, highlights: highlights)))
        let settled = try render(cache, paper: background, objects: objects, highlights: highlights, mutableObjectStartIndex: objects.count)
        XCTAssertTrue(cache.adopt(paper: background, image: settled, stablePrefixImage: settled, stablePrefixCount: objects.count,
            mapper: mapper, bounds: CGRect(origin: .zero, size: background.size), highlights: highlights,
            objects: objects, mutableObjectStartIndex: objects.count))
        XCTAssertEqual(cache.lastDrawnObjectCount, 0)
    }

}
