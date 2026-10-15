import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Actual Surface/Metal/image handoff; the supplied raster queue controls worker
/// completion order. Hierarchy pixels establish deletion, not a tile callback.
@MainActor
final class NativePDFProgressiveErasureTests: XCTestCase {
    typealias Base = NativePDFAsynchronousEditTests

    func testIntermediateDeletionBecomesVisibleBeforeLatestCropAndNeverMovesBackward() async throws {
        let f = try await makeFixture(); defer { f.close() }
        let original = f.rows, full = f.fullRenders
        let before = try await captureUntil(f) { $0.a > 100 && $0.b > 100 && $0.survivor > 100 }
        attach(before.image, name: "progressive-original-A-B-survivor")
        f.replace(Array(original.dropFirst()))
        let first = try await currentRequest(f)
        XCTAssertTrue(active(f)); XCTAssertFalse(f.imageView.isHidden)
        let originalImage = f.imageView.image
        f.replace([original[2]])
        let second = try await currentRequest(f)
        XCTAssertNotEqual(first.snapshot.revision, second.snapshot.revision)
        XCTAssertTrue(f.imageView.image === originalImage)
        XCTAssertEqual(installs(f), 0)

        // R1 is no longer latest but is strictly between displayed O and R2.
        // It must make progress while R2 is still withheld, without empty tiles.
        try await f.gate.finish(first)
        Base.assertTrue(await Base.poll(timeout: 5) { self.installs(f) == 1 && !f.imageView.isHidden })
        XCTAssertTrue(active(f)); XCTAssertEqual(f.gate.completed, 1)
        XCTAssertEqual(f.baseObjects, 2)
        let afterA = try await captureUntil(f) { $0.a == 0 && $0.b > 100 && $0.survivor > 100 }
        attach(afterA.image, name: "progressive-R1-actually-visible-while-R2-held")
        let acceptedImage = try XCTUnwrap(f.imageView.image)
        var maximumA = 0, minimumSurvivor = Int.max
        for _ in 0..<10 {
            let sample = try capture(f)
            maximumA = max(maximumA, sample.counts.a)
            minimumSurvivor = min(minimumSurvivor, sample.counts.survivor)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(maximumA, 0); XCTAssertGreaterThan(minimumSurvivor, 100)
        // Replaying the old worker callback cannot advance backwards, even
        // though the same captured result is still a valid older PDF image.
        try await f.gate.finish(first)
        XCTAssertTrue(f.imageView.image === acceptedImage)
        XCTAssertEqual(installs(f), 1)
        XCTAssertEqual(try capture(f).counts.a, 0)
        try await f.gate.finish(second)
        try await assertSettledExactly(f)
        let final = try await captureUntil(f) { $0.a == 0 && $0.b == 0 && $0.survivor > 100 }
        attach(final.image, name: "progressive-final-A-B-absent-survivor-visible")
        let finalImage = f.imageView.image
        try await f.gate.finish(first)
        XCTAssertTrue(f.imageView.image === finalImage)
        XCTAssertEqual(f.fullRenders, full, "All destructive full rasters must remain on the worker")
        XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        print("[PROGRESSIVE_ERASURE] originalA=\(before.counts.a) intermediateA=\(afterA.counts.a) heldMaxA=\(maximumA) survivorMin=\(minimumSurvivor) installs=\(installs(f)) full=\(full)")
    }

    func testExactCropFailedClearThenNewDeletionRetainsActualDisplayedProvenance() async throws {
        let f = try await makeFixture(); defer { f.close() }
        let original = f.rows, originalImage = try XCTUnwrap(f.imageView.image), full = f.fullRenders
        f.replace(Array(original.dropFirst()))
        let first = try await currentRequest(f)
        XCTAssertTrue(active(f))
        let result = try await raster(first)
        Base.assertTrue(await Base.poll(timeout: 5) { f.metal.readyDrawableCount > 0 })
        let submissions = f.metal.submittedFrameCount
        f.metal.testingFailNextEncoding = true
        // Complete + render synchronously, with no run-loop gap that could
        // consume the injected failure in an unrelated scheduled frame.
        first.completion(result)
        XCTAssertFalse(active(f), "Exact result enters the ordinary atomic handoff path")
        _ = f.surface.perform(NSSelectorFromString("renderPreview"))
        XCTAssertFalse(f.metal.testingFailNextEncoding, "The actual Metal encoder must consume this failure")
        XCTAssertEqual(f.metal.submittedFrameCount, submissions)
        XCTAssertTrue(f.imageView.image === originalImage)
        XCTAssertFalse(f.imageView.isHidden)

        f.replace([original[2]])
        _ = f.surface.perform(NSSelectorFromString("renderPreview"))
        XCTAssertTrue(active(f), "Re-entry must use the old visible image, not the adopted-but-unpresented cache")
        XCTAssertTrue(f.imageView.image === originalImage)
        let latest = try await currentRequest(f)
        XCTAssertNotEqual(latest.snapshot.revision, first.snapshot.revision)
        // That earlier exact result is now a safe intermediate deletion. It
        // may become visible, but the latest B deletion still stays pending.
        first.completion(result)
        Base.assertTrue(await Base.poll(timeout: 5) { self.installs(f) == 1 })
        let afterA = try await captureUntil(f) { $0.a == 0 && $0.b > 100 && $0.survivor > 100 }
        attach(afterA.image, name: "failed-clear-new-delete-safe-intermediate")
        try await f.gate.finish(latest)
        try await assertSettledExactly(f)
        _ = try await captureUntil(f) { $0.a == 0 && $0.b == 0 && $0.survivor > 100 }
        let finalImage = f.imageView.image
        first.completion(result)
        XCTAssertTrue(f.imageView.image === finalImage)
        XCTAssertFalse(active(f)); XCTAssertEqual(f.fullRenders, full)
        XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
    }

    private func makeFixture() async throws -> Base.Fixture {
        let f = try await Base.Fixture.make()
        try await f.settle()
        f.replace([row("A", color: "red", y: 0.55), row("B", color: "green", y: 0.70),
                   row("survivor", color: "blue", y: 0.85)])
        // Prepare the public baseline via the pre-existing ordinary edit path.
        // Only the actual eraser transitions below exercise the new policy.
        try await f.finishAndAssertPixels()
        f.gate.requests.removeAll(); f.gate.completed = 0
        f.surface.tool = .init(name: "eraser", style: f.penTool.style)
        return f
    }
    private func currentRequest(_ f: Base.Fixture) async throws -> NativePDFNavigationRasterizer.Request {
        Base.assertTrue(await Base.poll(timeout: 5) {
            f.gate.requests.last?.snapshot.revision == f.surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64 &&
            f.gate.requests.last?.snapshot.objects.count == f.rows.count
        }, "A worker must capture the current immutable scene")
        return try XCTUnwrap(f.gate.requests.last)
    }
    private func raster(_ request: NativePDFNavigationRasterizer.Request) async throws -> NativePDFNavigationSnapshot.Raster {
        let snapshot = request.snapshot, bounds = request.bounds, scale = request.scale
        let transform = request.transform, prefix = request.stablePrefixCount
        let result = await Task.detached(priority: .userInitiated) {
            autoreleasepool { snapshot.raster(bounds: bounds, scale: scale, canonicalToCanvas: transform, stablePrefixCount: prefix) }
        }.value
        return try XCTUnwrap(result)
    }
    private func assertSettledExactly(_ f: Base.Fixture) async throws {
        Base.assertTrue(await Base.poll(timeout: 8) {
            !f.editActive && f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
            !f.imageView.isHidden && f.metal.strokes.isEmpty && f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        })
        let viewport = try XCTUnwrap(f.surface.renderViewport), mapper = try XCTUnwrap(f.surface.mapper)
        let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in f.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
        let actual = try XCTUnwrap(f.imageView.image?.cgImage)
        XCTAssertEqual(actual.width, reference.width); XCTAssertEqual(actual.height, reference.height)
        XCTAssertTrue(try Base.pixels(actual) == Base.pixels(reference), "Final accepted scene must equal independent one-pass PDF + rows exactly")
    }
    private func active(_ f: Base.Fixture) -> Bool { f.surface.inputDiagnostics["progressiveErasureActive"] as? Bool == true }
    private func installs(_ f: Base.Fixture) -> Int { f.surface.inputDiagnostics["progressiveErasureInstalls"] as? Int ?? -1 }
    private func row(_ id: String, color: String, y: Double) -> [String: Any] {
        ["id": id, "clientMutationId": id, "page": 1, "kind": "ink",
         "data": ["inkVersion": 4, "points": [["x": 0.15, "y": y, "p": 0.8], ["x": 0.85, "y": y, "p": 0.8]]],
         "style": ["color": color, "width": 0.018, "opacity": 1.0]]
    }
    private struct Counts { var a = 0, b = 0, survivor = 0 }
    private struct Capture { let image: CGImage; let counts: Counts }
    private func capture(_ f: Base.Fixture) throws -> Capture {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var success = false
        let rendered = UIGraphicsImageRenderer(size: f.surface.bounds.size, format: format).image { _ in
            success = f.surface.drawHierarchy(in: f.surface.bounds, afterScreenUpdates: false)
        }
        XCTAssertTrue(success)
        let image = try XCTUnwrap(rendered.cgImage), bytes = try Base.pixels(image)
        var counts = Counts()
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index+1]), b = Int(bytes[index+2])
            if r > 160 && g < 90 && b < 100 { counts.a += 1 }
            if g > 95 && r < 120 && b < 170 { counts.b += 1 }
            if b > 140 && r < 100 && g < 180 { counts.survivor += 1 }
        }
        return Capture(image: image, counts: counts)
    }
    private func captureUntil(_ f: Base.Fixture, timeout: TimeInterval = 4,
        _ predicate: (Counts) -> Bool) async throws -> Capture {
        let deadline = CACurrentMediaTime() + timeout
        var sample = try capture(f)
        while !predicate(sample.counts), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20)); sample = try capture(f)
        }
        XCTAssertTrue(predicate(sample.counts), "Missing visible state A=\(sample.counts.a), B=\(sample.counts.b), survivor=\(sample.counts.survivor)")
        guard predicate(sample.counts) else { throw CaptureError.visibleStateMissing }
        return sample
    }
    private func attach(_ image: CGImage, name: String) {
        let item = XCTAttachment(image: UIImage(cgImage: image)); item.name = name
        item.lifetime = .keepAlways; add(item)
    }
    private enum CaptureError: Error { case visibleStateMissing }
}
