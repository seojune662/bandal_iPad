import XCTest
import UIKit
import Metal
@testable import Bandal

@MainActor
final class NativePDFRetainedObjectTexturesTests: XCTestCase {
    private typealias Cache = NativePDFRetainedObjectTextures
    private let size = CGSize(width: 120, height: 180)

    func testCapturePreservesNativePathPriorityAndRejectsUnsupportedOrMalformedDrawables() throws {
        let path = "M 0.2 0.3 L 0.6 0.3 L 0.6 0.5 L 0.2 0.5 Z"
        // nativePath precedes the kind-specific box renderer, even for textbox.
        let priority: [String: Any] = ["kind": "textbox", "nativePath": path, "data": [:], "style": ["opacity": 0.5]]
        XCTAssertNotNil(Cache.capture(object: priority, pageSize: size))
        XCTAssertNil(Cache.capture(object: ["kind": "unknown", "data": [:], "style": [:]], pageSize: size))
        var malformed = object()
        malformed["data"] = ["box": ["x": 0.1, "y": 0.2, "width": -1, "height": 0.2]]
        XCTAssertNil(Cache.capture(object: malformed, pageSize: size))
        malformed = object(); malformed["style"] = ["width": true]
        XCTAssertNil(Cache.capture(object: malformed, pageSize: size))
        malformed = object(); malformed["nativePath"] = "M nan 1"; malformed["data"] = [:]
        XCTAssertNil(Cache.capture(object: malformed, pageSize: size))
        XCTAssertNil(Cache.capture(object: object(), pageSize: CGSize(width: CGFloat.infinity, height: 1)))
        // An unavailable image has the existing placeholder, not a missing row.
        XCTAssertNotNil(Cache.capture(object: object(kind: "image"), image: nil, pageSize: size))
    }

    func testCaptureReusesOnlyFrozenAppearanceImageIdentityAndPageSize() throws {
        let box = NSMutableDictionary(dictionary: ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.2])
        let data = NSMutableDictionary(dictionary: ["box": box, "text": "original"])
        var row: [String: Any] = ["id": "local", "kind": "textbox", "data": data, "style": ["color": "blue", "fontSizePt": 12]]
        let first = try XCTUnwrap(Cache.capture(object: row, pageSize: size))
        row["id"] = "server"; row["updatedAt"] = "ack"
        XCTAssertTrue(Cache.capture(object: row, pageSize: size, reusing: first) === first)
        data["text"] = "changed"
        let second = try XCTUnwrap(Cache.capture(object: row, pageSize: size, reusing: first))
        XCTAssertFalse(second === first)
        XCTAssertFalse(Cache.capture(object: row, pageSize: CGSize(width: 180,height: 120), reusing: second) === second)
        let a = image(.red), b = image(.green), imageRow = object(kind: "image")
        let loaded = try XCTUnwrap(Cache.capture(object: imageRow, image: a, pageSize: size))
        XCTAssertTrue(Cache.capture(object: imageRow, image: a, pageSize: size, reusing: loaded) === loaded)
        XCTAssertFalse(Cache.capture(object: imageRow, image: b, pageSize: size, reusing: loaded) === loaded)
        XCTAssertFalse(Cache.capture(object: imageRow, image: nil, pageSize: size, reusing: loaded) === loaded)
        let incorrect = NativePDFCommittedVisualToken(object: object(kind: "ellipse"))
        XCTAssertNil(Cache.capture(object: imageRow, visualToken: incorrect, image: a, pageSize: size))
    }

    func testTrustedRowTokenReusesCaptureAcrossCanonicalAcknowledgementButChecksResources() throws {
        let row = object(kind: "image"), picture = image(.red)
        let token = NativePDFCommittedVisualToken(object: row)
        let first = try XCTUnwrap(Cache.capture(object: row, visualToken: token, image: picture, pageSize: size))
        XCTAssertTrue(Cache.capture(object: row, visualToken: token, image: picture,
                                    pageSize: size, reusing: first) === first)
        var acknowledged = row
        acknowledged["id"] = "canonical-id"; acknowledged["clientMutationId"] = "local-id"
        let acknowledgedToken = NativePDFCommittedVisualToken(object: acknowledged)
        XCTAssertTrue(Cache.capture(object: acknowledged, visualToken: acknowledgedToken, image: picture,
                                    pageSize: size, reusing: first) === first)
        XCTAssertFalse(Cache.capture(object: row, visualToken: token, image: image(.blue),
                                     pageSize: size, reusing: first) === first)
        XCTAssertFalse(Cache.capture(object: row, visualToken: token, image: picture,
                                     pageSize: CGSize(width: 180, height: 120), reusing: first) === first)
        var changed = row; changed["style"] = ["opacity": 0.25]
        let changedToken = NativePDFCommittedVisualToken(object: changed)
        XCTAssertFalse(Cache.capture(object: changed, visualToken: changedToken, image: picture,
                                     pageSize: size, reusing: first) === first)
    }

    func testTransparentLegacyHighlighterBakesOpacityOnceAndKeepsMultiplyOutsideRecording() throws {
        let row: [String: Any] = ["kind": "highlighter", "nativePath": "M 0.2 0.3 L 0.6 0.3 L 0.6 0.5 L 0.2 0.5 Z",
                                 "data": [:], "style": ["color": "red", "opacity": 0.5]]
        let source = try XCTUnwrap(Cache.capture(object: row, pageSize: size))
        XCTAssertTrue(source.multiply)
        let work = try XCTUnwrap(Cache.work(source: source, scale: 2))
        let bitmap = try XCTUnwrap(Cache.rasterize(work))
        let inside = pixel(bitmap, work: work, x: 0.4*size.width, y: 0.4*size.height)
        XCTAssertEqual(Double(inside[3]), 128, accuracy: 2)
        XCTAssertEqual(Double(inside[2]), 107, accuracy: 2)
        XCTAssertEqual(Double(inside[1]), 18, accuracy: 2)
        XCTAssertEqual(Double(inside[0]), 23, accuracy: 2)
        XCTAssertEqual(bitmap.bytes[3], 0, "Transparent padding must not replace underlying paper/ink")
    }

    func testNegativeFractionalBoundsAndResolutionCapRetainPhysicalPixelExtent() throws {
        let source = try XCTUnwrap(Cache.capture(object: object(x: -0.125, y: 0.137), pageSize: size))
        let work = try XCTUnwrap(Cache.work(source: source, scale: 1.37))
        XCTAssertLessThan(work.bounds.minX, 0)
        XCTAssertLessThanOrEqual(work.bounds.minX, source.bounds.minX)
        XCTAssertGreaterThanOrEqual(work.bounds.maxX, source.bounds.maxX)
        XCTAssertEqual(work.bounds.width, CGFloat(work.width)/work.scale)
        XCTAssertEqual(work.bounds.height, CGFloat(work.height)/work.scale)
        let capped = try XCTUnwrap(Cache.work(source: source, scale: 1_000_000))
        let cappedAgain = try XCTUnwrap(Cache.work(source: source, scale: 2_000_000))
        XCTAssertEqual(capped.scale, cappedAgain.scale)
        XCTAssertEqual(capped.bounds, cappedAgain.bounds)
        XCTAssertLessThanOrEqual(capped.width, 4096); XCTAssertLessThanOrEqual(capped.height, 4096)
        XCTAssertLessThanOrEqual(capped.byteCount, Cache.maximumJobBytes)
        XCTAssertNil(Cache.work(source: source, scale: .nan))
    }

    func testFirstFailureRetriesThreeTimesThenBecomesIdleAndNewSourceCanRecover() async throws {
        let renderer = try renderer(), gate = Gate()
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        let source = try source()
        cache.update(requests: [.init(source: source, scale: 1)])
        for index in 0..<3 {
            try await wait { await gate.count == index+1 }
            await gate.finish(index, result: nil)
        }
        try await wait { cache.status(for: source) == .unavailable }
        for _ in 0..<30 { cache.update(requests: [.init(source: source, scale: 1)]) }
        try await Task.sleep(nanoseconds: 260_000_000)
        let attempts = await gate.count
        XCTAssertEqual(attempts, 3); XCTAssertEqual(renderer.textureUploadCount, 0)
        let replacement = try self.source(kind: "ellipse")
        cache.update(requests: [.init(source: replacement, scale: 1)])
        try await wait { await gate.count == 4 }
        await gate.finish(3, result: try await raster(gate, 3))
        try await wait { cache.status(for: replacement) == .ready }
        XCTAssertEqual(renderer.textureUploadCount, 1)
    }

    func testOneWorkerCoalescesLatestSetAndResetDiscardsInFlightResult() async throws {
        let renderer = try renderer(), gate = Gate()
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        let a = try source(), b = try source(kind: "ellipse"), c = try source(kind: "textbox")
        cache.update(requests: [.init(source: a, scale: 1)])
        try await wait { await gate.count == 1 }
        cache.update(requests: [.init(source: b, scale: 1)])
        cache.update(requests: [.init(source: c, scale: 1)])
        await Task.yield()
        let running = await gate.count
        XCTAssertEqual(running, 1)
        await gate.finish(0, result: try await raster(gate, 0))
        try await wait { await gate.count == 2 }
        XCTAssertNil(cache.resource(for: a)); XCTAssertNil(cache.resource(for: b))
        XCTAssertEqual(renderer.textureUploadCount, 0)
        cache.reset()
        await gate.finish(1, result: try await raster(gate, 1))
        try await wait { cache.accountedBytes == 0 }
        XCTAssertEqual(cache.retainedCount, 0); XCTAssertEqual(renderer.textureUploadCount, 0)
    }

    func testUpgradeWaitingAndFailurePreserveAcceptedLowResolutionWithoutEndlessRetry() async throws {
        let renderer = try renderer(), gate = Gate()
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        let source = try source()
        cache.update(requests: [.init(source: source, scale: 1)])
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: try await raster(gate, 0))
        try await wait { cache.status(for: source) == .ready }
        let low = try XCTUnwrap(cache.resource(for: source))
        cache.update(requests: [.init(source: source, scale: 3)])
        for index in 1...3 {
            try await wait { await gate.count == index+1 }
            XCTAssertTrue(cache.resource(for: source)?.texture === low.texture)
            XCTAssertEqual(cache.status(for: source), .ready)
            await gate.finish(index, result: nil)
        }
        try await Task.sleep(nanoseconds: 260_000_000)
        for _ in 0..<20 { cache.update(requests: [.init(source: source, scale: 3)]) }
        let count = await gate.count
        XCTAssertEqual(count, 4); XCTAssertTrue(cache.resource(for: source)?.texture === low.texture)
        XCTAssertEqual(renderer.textureUploadCount, 1)
    }

    func testBudgetNeverEvictsKeepingResourceAndDeletionReleasesIt() async throws {
        let renderer = try renderer(), gate = Gate(), a = try source(), b = try source(kind: "ellipse")
        let work = try XCTUnwrap(Cache.work(source: a, scale: 1))
        let limit = 2*a.byteCost + 2*work.byteCount
        let cache = Cache(renderer: renderer, byteLimit: limit, rasterize: { await gate.capture($0) })
        cache.update(requests: [.init(source: a, scale: 1)])
        try await wait { await gate.count == 1 }
        XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
        await gate.finish(0, result: try await raster(gate, 0))
        try await wait { cache.status(for: a) == .ready }
        let accepted = try XCTUnwrap(cache.resource(for: a))
        cache.update(requests: [.init(source: b, scale: 3)], keeping: [a])
        XCTAssertEqual(cache.status(for: b), .unavailable)
        XCTAssertTrue(cache.resource(for: a)?.texture === accepted.texture)
        XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
        cache.update(requests: [])
        XCTAssertEqual(cache.accountedBytes, 0); XCTAssertNil(cache.resource(for: a))
    }

    func testSuccessfulUpgradeReplacesTextureAndUnchangedRequestsDoNotReupload() async throws {
        let renderer = try renderer(), gate = Gate(), source = try source()
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        for (index, scale) in [CGFloat(1), CGFloat(2)].enumerated() {
            cache.update(requests: [.init(source: source, scale: scale)])
            try await wait { await gate.count == index+1 }
            await gate.finish(index, result: try await raster(gate, index))
            try await wait { cache.resource(for: source)?.effectiveScale == scale }
        }
        let accepted = try XCTUnwrap(cache.resource(for: source))
        for _ in 0..<100 { cache.update(requests: [.init(source: source, scale: 2)]) }
        XCTAssertTrue(cache.resource(for: source)?.texture === accepted.texture)
        XCTAssertEqual(renderer.textureUploadCount, 2); XCTAssertEqual(cache.resourceCount, 1)
    }

    func testAcceptedOldTextureRemainsBudgetedUntilSceneReleasesItsResourceVersion() async throws {
        let renderer = try renderer(), gate = Gate(), source = try source()
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        cache.update(requests: [.init(source: source, scale: 1)])
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: try await raster(gate, 0))
        try await wait { cache.status(for: source) == .ready }
        let old = try XCTUnwrap(cache.resource(for: source))
        cache.update(requests: [.init(source: source, scale: 2)], keeping: [source], keepingResources: [old])
        try await wait { await gate.count == 2 }
        XCTAssertLessThanOrEqual(cache.accountedBytes, cache.byteLimit)
        await gate.finish(1, result: try await raster(gate, 1))
        try await wait { cache.resource(for: source)?.effectiveScale == 2 }
        let upgraded = try XCTUnwrap(cache.resource(for: source))
        XCTAssertFalse(old.texture === upgraded.texture)
        XCTAssertEqual(cache.accountedBytes, source.byteCost + old.texture.byteCount + upgraded.texture.byteCount)
        cache.update(requests: [.init(source: source, scale: 2)], keeping: [source], keepingResources: [upgraded, upgraded])
        XCTAssertEqual(cache.accountedBytes, source.byteCost + upgraded.texture.byteCount,
                       "Accepted/current aliases are one GPU allocation, not three")
        cache.update(requests: [])
        XCTAssertEqual(cache.accountedBytes, 0)
    }

    func testObsoleteWorkerReleaseNotifiesOwnerToReadmitLatestSource() async throws {
        let renderer = try renderer(), gate = Gate(), a = try source()
        var latestRow = object(kind: "textbox")
        var data = latestRow["data"] as! [String: Any]
        data["syntheticPadding"] = String(repeating: "x", count: 12_288)
        latestRow["data"] = data
        let b = try XCTUnwrap(Cache.capture(object: latestRow, pageSize: size))
        let oldWork = try XCTUnwrap(Cache.work(source: a, scale: 8))
        let newWork = try XCTUnwrap(Cache.work(source: b, scale: 1))
        let oldReservation = a.byteCost + 2*oldWork.byteCount
        let limit = max(a.byteCost + oldReservation, 2*b.byteCost + 2*newWork.byteCount) + 4096
        XCTAssertGreaterThan(b.byteCost + oldReservation, limit,
                             "The old worker must really prevent latest Entry admission")
        let cache = Cache(renderer: renderer, byteLimit: limit, rasterize: { await gate.capture($0) })
        var notifications = 0
        cache.onChange = {
            notifications += 1
            cache.update(requests: [.init(source: b, scale: 1)])
        }
        defer { cache.onChange = nil; cache.reset(); Task { await gate.close() } }
        cache.update(requests: [.init(source: a, scale: 8)])
        try await wait { await gate.count == 1 }
        cache.update(requests: [.init(source: b, scale: 1)])
        XCTAssertEqual(cache.status(for: b), .unavailable)
        XCTAssertEqual(cache.retainedCount, 0, "A is obsolete; B failed admission only because A still owns its worker slot")
        await gate.finish(0, result: try XCTUnwrap(Cache.rasterize(oldWork)))
        // No external model, timer or input event retries admission. The worker
        // release itself must notify the owner to re-submit the unchanged B.
        try await wait { notifications > 0 && cache.status(for: b) == .pending }
        try await wait { await gate.count == 2 }
        XCTAssertEqual(renderer.textureUploadCount, 0)
        await gate.finish(1, result: try XCTUnwrap(Cache.rasterize(newWork)))
        try await wait { cache.status(for: b) == .ready }
        XCTAssertEqual(renderer.textureUploadCount, 1)
        XCTAssertNil(cache.resource(for: a)); XCTAssertNotNil(cache.resource(for: b))
        XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
    }

    func testThirteenInchDensityUndoAdmitsFreshLargeObjectsAtSupportedResolution() async throws {
        let renderer = try renderer(), gate = Gate()
        let page = CGSize(width: 612, height: 792)
        let textRow: [String: Any] = ["id": "old-text", "kind": "textbox",
            "data": ["box": ["x": 0.2, "y": 0.25, "width": 0.6, "height": 0.45],
                     "text": "Mixed native eraser fixture"],
            "style": ["color": "red", "width": 0.004, "opacity": 0.8, "fontSizePt": 14]]
        let rectRow: [String: Any] = ["id": "old-rect", "kind": "rect",
            "data": ["box": ["x": 0.3, "y": 0.35, "width": 0.4, "height": 0.3]],
            "style": ["color": "violet", "width": 0.004, "opacity": 0.8]]
        let highlightRow: [String: Any] = ["id": "surviving-highlight", "kind": "highlighter",
            "nativePath": "M 0.25 0.54 L 0.75 0.54 L 0.75 0.56 L 0.25 0.56 Z",
            "data": [:], "style": ["color": "yellow", "width": 0.02, "opacity": 0.3]]
        let imageRow: [String: Any] = ["id": "surviving-image", "kind": "image",
            "data": ["box": ["x": 0.77, "y": 0.12, "width": 0.16, "height": 0.12]],
            "style": ["width": 0.004, "opacity": 1.0]]
        let picture = image(.blue)
        let text = try XCTUnwrap(Cache.capture(object: textRow, pageSize: page))
        let rect = try XCTUnwrap(Cache.capture(object: rectRow, pageSize: page))
        let highlight = try XCTUnwrap(Cache.capture(object: highlightRow, pageSize: page))
        let pictureSource = try XCTUnwrap(Cache.capture(object: imageRow, image: picture, pageSize: page))
        let original = [text, rect, highlight, pictureSource]
        let cache = Cache(renderer: renderer, rasterize: { await gate.capture($0) })
        defer { cache.reset(); Task { await gate.close() } }
        cache.update(requests: original.map { .init(source: $0, scale: 4) })
        for index in 0..<4 {
            try await wait { await gate.count == index+1 }
            XCTAssertLessThanOrEqual(cache.accountedBytes, cache.byteLimit)
            await gate.finish(index, result: try await raster(gate, index))
        }
        try await wait { original.allSatisfy { cache.status(for: $0) == .ready } }

        // The large objects were erased. Surviving accepted textures are pinned
        // while the 13-inch viewport requests the next power-of-two density.
        let survivors = [highlight, pictureSource]
        let beforeUpgrade = try survivors.map { try XCTUnwrap(cache.resource(for: $0)) }
        cache.update(requests: survivors.map { .init(source: $0, scale: 8) },
                     keeping: survivors, keepingResources: beforeUpgrade)
        for index in 4..<6 {
            try await wait { await gate.count == index+1 }
            XCTAssertLessThanOrEqual(cache.accountedBytes, cache.byteLimit)
            await gate.finish(index, result: try await raster(gate, index))
        }
        try await wait { survivors.allSatisfy { cache.resource(for: $0)?.effectiveScale == 8 } }
        let accepted = try survivors.map { try XCTUnwrap(cache.resource(for: $0)) }
        var undoneText = textRow; undoneText["id"] = "restored-text-new-id"
        var undoneRect = rectRow; undoneRect["id"] = "restored-rect-new-id"
        let newText = try XCTUnwrap(Cache.capture(object: undoneText, pageSize: page))
        let newRect = try XCTUnwrap(Cache.capture(object: undoneRect, pageSize: page))
        XCTAssertFalse(newText === text); XCTAssertFalse(newRect === rect)
        let high = try XCTUnwrap(Cache.work(source: newText, scale: 8))
        XCTAssertEqual(high.width, 2939); XCTAssertEqual(high.height, 2854)
        XCTAssertEqual(high.byteCount, 33_551_624)
        XCTAssertGreaterThan(high.byteCount*2 + accepted[1].texture.byteCount, cache.byteLimit,
                             "The requested job cannot coexist with even the surviving image")
        let restored = [newText, newRect, highlight, pictureSource]
        cache.update(requests: restored.map { .init(source: $0, scale: 8) },
                     keeping: survivors, keepingResources: accepted)
        try await wait { await gate.count == 7 }
        let admitted = await gate.work(6)
        XCTAssertEqual(admitted.scale, 4)
        XCTAssertEqual(admitted.byteCount, 8_712_368)
        XCTAssertTrue(admitted.bounds.contains(newText.bounds))
        XCTAssertEqual(cache.status(for: newText), .pending)
        for index in 6..<8 {
            try await wait { await gate.count == index+1 }
            XCTAssertLessThanOrEqual(cache.accountedBytes, cache.byteLimit)
            await gate.finish(index, result: try await raster(gate, index))
        }
        try await wait { restored.allSatisfy { cache.status(for: $0) == .ready } }
        XCTAssertEqual(cache.resourceCount, 4)
        XCTAssertEqual(cache.resource(for: newText)?.effectiveScale, 4)
        XCTAssertTrue(cache.resource(for: highlight)?.texture === accepted[0].texture)
        XCTAssertTrue(cache.resource(for: pictureSource)?.texture === accepted[1].texture)
        let ready = try restored.map { try XCTUnwrap(cache.resource(for: $0)) }
        for _ in 0..<100 {
            cache.update(requests: restored.map { .init(source: $0, scale: 8) },
                         keeping: restored, keepingResources: ready)
        }
        try await Task.sleep(nanoseconds: 260_000_000)
        let attempts = await gate.count
        XCTAssertEqual(attempts, 8, "Unchanged desired density must not repeat the admitted lower-density raster")
        XCTAssertEqual(renderer.textureUploadCount, 8)
        XCTAssertLessThanOrEqual(cache.accountedBytes, cache.byteLimit)
        print("[OBJECT_TEXTURE_UNDO_BUDGET] requested=8 admitted=4 highBytes=\(high.byteCount) lowBytes=\(admitted.byteCount) ready=\(cache.resourceCount) accounted=\(cache.accountedBytes)")
    }

    func testBudgetReleaseUpgradesSameSourceWithoutDowngradingOrRepeatingAcceptedTexture() async throws {
        let renderer = try renderer(), gate = Gate(), a = try source(), b = try source(kind: "ellipse")
        let lowWork = try XCTUnwrap(Cache.work(source: a, scale: 2))
        let highWork = try XCTUnwrap(Cache.work(source: a, scale: 4))
        let bWork = try XCTUnwrap(Cache.work(source: b, scale: 4))
        let limit = 2*a.byteCost + 2*highWork.byteCount + 2*lowWork.byteCount + 512
        XCTAssertLessThanOrEqual(2*b.byteCost + 2*bWork.byteCount, limit)
        XCTAssertGreaterThan(2*a.byteCost + b.byteCost + bWork.byteCount + 2*highWork.byteCount, limit)
        let cache = Cache(renderer: renderer, byteLimit: limit, rasterize: { await gate.capture($0) })
        defer { cache.reset(); Task { await gate.close() } }
        cache.update(requests: [.init(source: b, scale: 4)])
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: try await raster(gate, 0))
        try await wait { cache.status(for: b) == .ready }
        let kept = try XCTUnwrap(cache.resource(for: b))
        cache.update(requests: [.init(source: a, scale: 4)], keeping: [b], keepingResources: [kept])
        try await wait { await gate.count == 2 }
        let selected = await gate.work(1)
        XCTAssertEqual(selected.scale, 2)
        await gate.finish(1, result: try await raster(gate, 1))
        try await wait { cache.status(for: a) == .ready }
        let low = try XCTUnwrap(cache.resource(for: a))
        for _ in 0..<30 {
            cache.update(requests: [.init(source: a, scale: 4)], keeping: [b], keepingResources: [kept])
        }
        await Task.yield()
        let beforeRelease = await gate.count
        XCTAssertEqual(beforeRelease, 2)
        XCTAssertTrue(cache.resource(for: a)?.texture === low.texture)
        XCTAssertTrue(cache.resource(for: b)?.texture === kept.texture)
        cache.update(requests: [.init(source: a, scale: 4)], keeping: [a], keepingResources: [low])
        try await wait { await gate.count == 3 }
        let upgrade = await gate.work(2)
        XCTAssertEqual(upgrade.scale, 4)
        XCTAssertTrue(cache.resource(for: a)?.texture === low.texture, "Only successful upload may replace the accepted resource")
        XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
        await gate.finish(2, result: try await raster(gate, 2))
        try await wait { cache.resource(for: a)?.effectiveScale == 4 }
        let high = try XCTUnwrap(cache.resource(for: a))
        XCTAssertFalse(high.texture === low.texture)
        cache.update(requests: [.init(source: a, scale: 1)], keeping: [a], keepingResources: [high])
        await Task.yield()
        let afterLowerRequest = await gate.count
        XCTAssertEqual(afterLowerRequest, 3)
        XCTAssertTrue(cache.resource(for: a)?.texture === high.texture, "A smaller request never downgrades a ready texture")
        XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
    }

    func testBudgetSelectedLowerWorkStillExhaustsExactlyThreeFailedAttempts() async throws {
        let renderer = try renderer(), gate = Gate(), source = try source()
        let lowWork = try XCTUnwrap(Cache.work(source: source, scale: 4))
        let limit = 2*source.byteCost + 2*lowWork.byteCount
        let cache = Cache(renderer: renderer, byteLimit: limit, rasterize: { await gate.capture($0) })
        defer { cache.reset(); Task { await gate.close() } }
        cache.update(requests: [.init(source: source, scale: 8)])
        for index in 0..<3 {
            try await wait { await gate.count == index+1 }
            let work = await gate.work(index)
            XCTAssertEqual(work.scale, 4)
            XCTAssertLessThanOrEqual(cache.accountedBytes, limit)
            await gate.finish(index, result: nil)
        }
        try await wait { cache.status(for: source) == .unavailable }
        for _ in 0..<30 { cache.update(requests: [.init(source: source, scale: 8)]) }
        try await Task.sleep(nanoseconds: 260_000_000)
        let attempts = await gate.count
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(renderer.textureUploadCount, 0)
        XCTAssertNil(cache.resource(for: source))
    }

    private func raster(_ gate: Gate, _ index: Int) async throws -> Cache.Bitmap {
        let work = await gate.work(index)
        return try XCTUnwrap(Cache.rasterize(work))
    }
    private func renderer() throws -> NativePDFRetainedInkRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(NativePDFRetainedInkRenderer(device: device))
    }
    private func source(kind: String = "rect") throws -> Cache.Source {
        try XCTUnwrap(Cache.capture(object: object(kind: kind), pageSize: size))
    }
    private func object(kind: String = "rect", x: Double = 0.2, y: Double = 0.3) -> [String: Any] {
        ["id": "object", "kind": kind, "data": ["box": ["x": x, "y": y, "width": 0.4, "height": 0.2], "text": "Hello"],
         "style": ["color": "blue", "width": 0.02, "opacity": 0.5, "fontSizePt": 12]]
    }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10,height: 20)).image { context in color.setFill(); context.fill(CGRect(x: 0,y: 0,width: 10,height: 20)) }
    }
    private func pixel(_ bitmap: Cache.Bitmap, work: Cache.Work, x: CGFloat, y: CGFloat) -> [UInt8] {
        let px = Int(floor((x-work.bounds.minX)*work.scale)), py = Int(floor((y-work.bounds.minY)*work.scale))
        return Array(bitmap.bytes[(py*bitmap.bytesPerRow+px*4)..<(py*bitmap.bytesPerRow+px*4+4)])
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let end = CACurrentMediaTime()+3
        while !(await predicate()), CACurrentMediaTime() < end { try await Task.sleep(nanoseconds: 1_000_000) }
        guard await predicate() else { XCTFail("Timed out waiting for object texture lifecycle"); throw NSError(domain: "ObjectTextureTests",code: 1) }
    }
    private actor Gate {
        struct Pending { let work: Cache.Work; var reply: CheckedContinuation<Cache.Bitmap?, Never>? }
        private var pending: [Pending] = []
        private var closed = false
        var count: Int { pending.count }
        func work(_ index: Int) -> Cache.Work { pending[index].work }
        func capture(_ work: Cache.Work) async -> Cache.Bitmap? {
            guard !closed else { return nil }
            return await withCheckedContinuation { pending.append(Pending(work: work, reply: $0)) }
        }
        func finish(_ index: Int, result: Cache.Bitmap?) {
            let reply = pending[index].reply; pending[index].reply = nil; reply?.resume(returning: result)
        }
        func close() {
            closed = true
            for index in pending.indices { finish(index, result: nil) }
        }
    }
}
