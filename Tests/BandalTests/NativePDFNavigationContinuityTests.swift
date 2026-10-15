import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFNavigationContinuityTests: XCTestCase {
    typealias Base = NativePDFAsynchronousEditTests

    func testActualHeldTileDrawKeepsOpaquePixelsRatherThanWhiteHoles() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle()
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        let builder = NativePDFNavigationSnapshotBuilder()
        let original = try XCTUnwrap(builder.make(page: f.page, objects: f.rows, tokens: f.tokens, highlights: [], image: { _ in nil }))
        let retained = try XCTUnwrap(NativePDFRetainedInkBackdrop(image: XCTUnwrap(f.imageView.image), snapshot: original,
            mapper: mapper, viewport: viewport, objects: f.rows, tokens: f.tokens, highlights: [], imageForObject: { _ in nil }))
        let gate = TileGate(); defer { gate.open() }
        let navigation = NativePDFNavigationView(frame: f.surface.bounds, beforeTileDraw: { _ in gate.enter() })
        let backing = UIView(frame: f.surface.frame); backing.backgroundColor = .magenta
        backing.addSubview(navigation); f.window.rootViewController!.view.addSubview(backing)
        defer { navigation.removeSnapshot(); backing.removeFromSuperview() }
        navigation.retainContinuity(retained, mapper: mapper, viewport: viewport)
        await settleTransaction()
        let baseline = try capture(backing)
        let bytes = try Base.pixels(baseline)
        XCTAssertGreaterThan(bytes.enumerated().filter { $0.offset % 4 < 3 && $0.element < 180 }.count, 10_000)
        let changed = Array(f.rows.dropFirst(5))
        let snapshot = try XCTUnwrap(builder.make(page: f.page, objects: changed,
            tokens: changed.map(NativePDFCommittedVisualToken.init), highlights: [], image: { _ in nil }))
        navigation.install(snapshot, mapper: mapper)
        Base.assertTrue(await Base.poll(timeout: 3) { gate.entered > 0 }, "Must observe actual CATiledLayer draw callback")
        await settleTransaction()
        let during = try capture(backing)
        XCTAssertTrue(try Base.pixels(during) == bytes, "Held replacement tiles must reveal the exact completed crop underneath")
        XCTAssertEqual(navigation.continuityBitmapCount, 1)
        // Negative control: removing the fallback while that SAME real tile
        // callback remains held must change the captured compositor pixels.
        navigation.clearContinuity(); await settleTransaction()
        let without = try capture(backing)
        XCTAssertFalse(try Base.pixels(without) == bytes)
        XCTAssertEqual(navigation.continuityBitmapCount, 0)
        let attachment = XCTAttachment(image: UIImage(cgImage: during)); attachment.name = "held-tiles-completed-ink-visible"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTwoCompletedContactsAndPressureCorrectionRecomposeFromOriginalWithoutDoubleAlpha() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle(); let originalRows = f.rows, originalImage = try XCTUnwrap(f.imageView.image)
        let navigation = try XCTUnwrap(f.surface.subviews.compactMap { $0 as? NativePDFNavigationView }.first)
        let full = f.fullRenders
        // The first contact started BEFORE the edit. Eligibility must come
        // from its actual completion identity, not the mode at touch-down.
        let first = f.begin(estimate: 917), firstLocation = first.touch.point
        f.replace(Array(originalRows.dropFirst()))
        Base.assertTrue(await Base.poll(timeout: 5) { f.editActive && f.imageView.isHidden && !f.gate.requests.isEmpty })
        first.touch.estimate = nil; first.touch.expecting = []
        f.move(first, dx: 22, dy: 8); f.end(first)
        Base.assertTrue(await Base.poll(timeout: 5) { navigation.continuityAddedObjectCount == 1 })
        let second = f.begin(); f.move(second, dx: 35, dy: 13); f.end(second)
        Base.assertTrue(await Base.poll(timeout: 5) { navigation.continuityAddedObjectCount == 2 })
        XCTAssertEqual(f.gate.completed, 0); XCTAssertEqual(f.saved.count, 0)
        let retainedOriginal = try XCTUnwrap(navigation.continuityImage)
        XCTAssertTrue(retainedOriginal === originalImage)
        let beforeCorrection = try renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))
        let beforeCount = navigation.continuityVectorUpdateCount
        first.touch.point = firstLocation; first.touch.estimate = 917
        first.touch.pressure = 0.94; first.touch.expecting = []
        f.surface.updatePencilGestureProperties([first.touch])
        Base.assertTrue(await Base.poll(timeout: 5) { navigation.continuityVectorUpdateCount > beforeCount })
        XCTAssertEqual(navigation.continuityAddedObjectCount, 2); XCTAssertEqual(navigation.continuityBitmapCount, 1)
        XCTAssertTrue(navigation.continuityImage === retainedOriginal)
        XCTAssertEqual(f.saved.count, 2); try f.assertDurableMatchesSaved()
        let latest = try renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))
        XCTAssertFalse(try Base.pixels(latest) == Base.pixels(beforeCorrection),
            "The actual fallback subtree must change while retaining the same original crop")
        // Independent full replay includes the original deleted row too: the
        // fallback deliberately retains old pixels until opaque tiles replace
        // them. Only the two real contacts may be added to that original.
        let newRows = f.rows.filter { row in f.saved.contains { $0.mutationID == row["clientMutationId"] as? String } }
        let flatExpected = try fullReplay(f, rows: originalRows + newRows)
        let originalExpected = try fullReplay(f, rows: originalRows)
        // A fallback promises preservation of the already displayed pixels.
        // The initial cold UIKit paper copy has an existing one-level gray
        // rounding difference from a fresh full replay; record it explicitly.
        // Compare additions independently using ObjectRenderer, not snapshot
        // commands, then retain the strict final full PDF replay check below.
        let expected = try composeReference(f, original: originalImage, added: newRows)
        print("CONTINUITY initial-baseline", try difference(originalImage.cgImage!, originalExpected),
              "full-reference", try difference(latest, flatExpected),
              "original-plus-ObjectRenderer", try difference(latest, expected))
        for (name, image) in [("continuity-composite", latest), ("continuity-reference", expected), ("continuity-original", originalImage.cgImage!)] {
            let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(try Base.pixels(latest) == Base.pixels(expected), "Correction must replay original + latest additions once")
        XCTAssertFalse(try Base.pixels(latest) == Base.pixels(originalImage.cgImage!))
        XCTAssertEqual(f.fullRenders, full)
        // Restore an old row with a NEW backend ID: it is not a locally
        // measured new contact and must not be blended onto stale old pixels.
        var undo = originalRows[0]; undo["id"] = "undo-new-id"; undo["clientMutationId"] = "undo-new-id"
        let previous = f.baseRevision; f.replace(f.rows + [undo])
        Base.assertTrue(await Base.poll(timeout: 5) { f.baseRevision != previous })
        XCTAssertEqual(navigation.continuityAddedObjectCount, 2)
        XCTAssertTrue(navigation.continuityImage === retainedOriginal)
        XCTAssertTrue(try Base.pixels(renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))) == Base.pixels(expected))
        // Delete a local completed contact before the replacement crop. Its
        // allowlist identity must retire too, even though absent from that crop.
        let deletedLocal = f.saved[1].mutationID
        let beforeDelete = f.baseRevision
        f.replace(f.rows.filter { $0["clientMutationId"] as? String != deletedLocal })
        Base.assertTrue(await Base.poll(timeout: 5) { f.baseRevision != beforeDelete && navigation.continuityAddedObjectCount == 1 })
        let surviving = newRows.filter { $0["clientMutationId"] as? String != deletedLocal }
        XCTAssertTrue(navigation.continuityImage === retainedOriginal)
        XCTAssertTrue(try Base.pixels(renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))) == Base.pixels(composeReference(f, original: originalImage, added: surviving)))
        try await f.finishAndAssertPixels()
        XCTAssertNil(navigation.continuityImage); XCTAssertEqual(navigation.continuityBitmapCount, 0)
        XCTAssertEqual(f.surface.inputDiagnostics["continuityLocalInkCount"] as? Int, 0)
        XCTAssertEqual(f.fullRenders, full)
    }

    func testDeferredAndFailedInstallPreserveFallbackUntilSuccessfulOpaqueTransaction() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle()
        let navigation = try XCTUnwrap(f.surface.subviews.compactMap { $0 as? NativePDFNavigationView }.first)
        let previous = try XCTUnwrap(f.imageView.image), base = f.baseRevision
        Base.assertTrue(await Base.poll { f.metal.readyDrawableCount > 0 })
        f.metal.testingFailNextEncoding = true
        f.replace(Array(f.rows.dropFirst()))
        let live = f.begin()
        XCTAssertNil(navigation.continuityImage); XCTAssertEqual(f.baseRevision, base)
        XCTAssertTrue(f.imageView.image === previous); XCTAssertFalse(f.imageView.isHidden)
        Base.assertTrue(await Base.poll(timeout: 5) { navigation.continuityImage != nil && !f.gate.requests.isEmpty })
        f.move(live, dx: 12, dy: 6); f.end(live)
        Base.assertTrue(await Base.poll(timeout: 5) {
            navigation.continuityAddedObjectCount == 1 &&
            f.gate.requests.last?.snapshot.revision == f.baseRevision &&
            f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        })
        let retainedOriginal = try XCTUnwrap(navigation.continuityImage)
        let fallback = try renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))
        let vectorUpdates = navigation.continuityVectorUpdateCount
        let request = try XCTUnwrap(f.gate.requests.last)
        // Completion/adoption must not retire anything before an actual Metal
        // replacement succeeds. Force the first attempt to fail inline.
        Base.assertTrue(await Base.poll { f.metal.readyDrawableCount > 0 })
        f.metal.testingFailNextEncoding = true
        try await f.gate.finish(request)
        XCTAssertTrue(navigation.continuityImage === retainedOriginal)
        XCTAssertEqual(navigation.continuityVectorUpdateCount, vectorUpdates)
        XCTAssertTrue(try Base.pixels(renderContinuity(navigation, viewport: XCTUnwrap(f.surface.renderViewport))) == Base.pixels(fallback),
            "An encoding failure must preserve the complete fallback, including vector additions")
        XCTAssertTrue(f.imageView.isHidden)
        Base.assertTrue(await Base.poll(timeout: 5) { !f.imageView.isHidden && navigation.continuityImage == nil })
        XCTAssertEqual(navigation.continuityBitmapCount, 0)
        XCTAssertTrue(try Base.pixels(f.imageView.image!.cgImage!) == Base.pixels(fullReplay(f, rows: f.rows)))
    }

    func testReprojectionClipsCurrentViewportAndGeometryResetDropsOldCrop() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle()
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        let snapshot = try XCTUnwrap(NativePDFNavigationSnapshotBuilder().make(page: f.page, objects: f.rows,
            tokens: f.tokens, highlights: [], image: { _ in nil }))
        let retained = try XCTUnwrap(NativePDFRetainedInkBackdrop(image: XCTUnwrap(f.imageView.image), snapshot: snapshot,
            mapper: mapper, viewport: viewport, objects: f.rows, tokens: f.tokens, highlights: [], imageForObject: { _ in nil }))
        let view = NativePDFNavigationView(frame: f.surface.bounds)
        view.retainContinuity(retained, mapper: mapper, viewport: viewport)
        let transform = CGAffineTransform(translationX: 350, y: 0).rotated(by: .pi / 2).scaledBy(x: 0.7, y: 0.7)
        let moved = InkCoordinateMapper(canvasToPDF: transform.inverted().concatenating(mapper.canvasToPDF), geometry: mapper.geometry)
        let crop = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: f.surface.bounds,
            visibleRect: CGRect(x: 80, y: 50, width: 160, height: 210), canvasToWindow: .identity, screenScale: 2))
        view.reprojectContinuity(mapper: moved, viewport: crop)
        let clip = try XCTUnwrap(view.continuityLayer), pixels = try XCTUnwrap(clip.sublayers?.first)
        XCTAssertTrue(pixels.masksToBounds, "Additions and original pixels must share the source crop footprint")
        XCTAssertTrue(clip.masksToBounds); XCTAssertEqual(clip.frame, crop.canvasRect)
        let source = viewport.canvasRect.origin.applying(transform)
        XCTAssertEqual(pixels.position.x, source.x-crop.canvasRect.minX, accuracy: 1e-9)
        XCTAssertEqual(pixels.position.y, source.y-crop.canvasRect.minY, accuracy: 1e-9)
        XCTAssertEqual(pixels.affineTransform().a, transform.a, accuracy: 1e-9)
        XCTAssertEqual(pixels.affineTransform().b, transform.b, accuracy: 1e-9)
        XCTAssertEqual(pixels.affineTransform().c, transform.c, accuracy: 1e-9)
        XCTAssertEqual(pixels.affineTransform().d, transform.d, accuracy: 1e-9)
        view.reprojectContinuity(mapper: .whiteboard(size: CGSize(width: 512, height: 384)), viewport: crop)
        XCTAssertNil(view.continuityImage); XCTAssertEqual(view.continuityBitmapCount, 0)
    }

    /// Observe the actual fallback tree without reparenting it or capturing tiles.
    /// CALayer.render uses the receiver's local coordinate system, so explicitly
    /// remove the viewport origin and then place that root at its canvas frame.
    /// This keeps nonzero viewport origins from becoming a second translation.
    /// No product-side bitmap composition or alternate vector renderer is used.
    private func renderContinuity(_ navigation: NativePDFNavigationView,
                                  viewport: NativePDFRenderViewport) throws -> CGImage {
        let clip = try XCTUnwrap(navigation.continuityLayer)
        XCTAssertEqual(clip.frame, viewport.canvasRect)
        XCTAssertEqual(clip.bounds.origin, .zero)
        XCTAssertTrue(clip.affineTransform().isIdentity)
        let format = UIGraphicsImageRendererFormat()
        format.scale = viewport.pixelScale
        format.opaque = false // Missing coverage remains visible in the alpha comparison.
        let rendered = UIGraphicsImageRenderer(size: viewport.canvasRect.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: -viewport.canvasRect.minX, y: -viewport.canvasRect.minY)
            context.translateBy(x: clip.frame.minX, y: clip.frame.minY)
            clip.render(in: context)
        }
        return try XCTUnwrap(rendered.cgImage)
    }
    private func difference(_ a: CGImage, _ b: CGImage) throws -> String {
        let x = try Base.pixels(a), y = try Base.pixels(b)
        var count = 0, maxDifference = 0, minX = a.width, minY = a.height, maxX = 0, maxY = 0
        for (index, pair) in zip(x, y).enumerated() where pair.0 != pair.1 {
            count += 1; maxDifference = max(maxDifference, abs(Int(pair.0)-Int(pair.1)))
            let px = index/4 % a.width, py = index/4 / a.width
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
        }
        return "channels=\(count),max=\(maxDifference),bounds=[\(minX),\(minY),\(maxX),\(maxY)]"
    }
    private func composeReference(_ f: Base.Fixture, original: UIImage, added: [[String: Any]]) throws -> CGImage {
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        let format = UIGraphicsImageRendererFormat(); format.scale = original.scale; format.opaque = true
        let image = UIGraphicsImageRenderer(size: viewport.canvasRect.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.saveGState(); context.interpolationQuality = .none
            original.draw(at: .zero, blendMode: .copy, alpha: 1); context.restoreGState()
            context.translateBy(x: -viewport.canvasRect.minX, y: -viewport.canvasRect.minY)
            for row in added { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }
        return try XCTUnwrap(image.cgImage)
    }
    private func fullReplay(_ f: Base.Fixture, rows: [[String: Any]]) throws -> CGImage {
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        return try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
    }
    private func capture(_ view: UIView) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var success = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            success = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        XCTAssertTrue(success)
        return try XCTUnwrap(image.cgImage)
    }
    private func settleTransaction() async {
        CATransaction.flush()
        try? await Task.sleep(for: .milliseconds(80))
    }
}

private final class TileGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, count = 0
    var entered: Int { condition.lock(); defer { condition.unlock() }; return count }
    func enter() {
        condition.lock(); count += 1
        let deadline = Date().addingTimeInterval(5)
        while held, condition.wait(until: deadline) {}
        condition.unlock()
    }
    func open() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
}
