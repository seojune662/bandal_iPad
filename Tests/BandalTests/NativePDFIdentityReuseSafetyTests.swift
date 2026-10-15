import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Negative controls for identity-only provenance refresh. A cache image is
/// not a displayed image until its paired Metal submission succeeds.
@MainActor
final class NativePDFIdentityReuseSafetyTests: XCTestCase {
    private typealias Base = NativePDFAsynchronousEditTests

    func testIdentityOnlyReuseAfterFailedClearCannotRelabelPreviouslyDisplayedPixels() async throws {
        let f = try await Base.Fixture.make()
        defer { f.close() }
        try await f.settle()
        let original = [row("A", color: "red", y: 0.55), row("B", color: "green", y: 0.70),
                        row("survivor", color: "blue", y: 0.85)]
        f.replace(original)
        try await f.finishAndAssertPixels()
        f.gate.requests.removeAll(); f.gate.completed = 0
        f.surface.tool = .init(name: "eraser", style: f.penTool.style)
        let oldImage = try XCTUnwrap(f.imageView.image)
        let oldPixels = try Base.pixels(XCTUnwrap(oldImage.cgImage))
        let oldBase = f.baseRevision, full = f.fullRenders
        let oldInstalls = int(f, "progressiveErasureInstalls")

        f.replace(Array(original.dropFirst()))
        let first = try await currentRequest(f)
        XCTAssertTrue(progressive(f))
        let result = try await raster(first)
        try await require { f.metal.readyDrawableCount > 0 }
        let submitted = f.metal.submittedFrameCount
        f.metal.testingFailNextEncoding = true
        // No await between worker adoption, failed clear, metadata reuse and
        // the following deletion: the scheduled retry cannot silently install
        // the newer crop before the assertions exercise the dangerous state.
        first.completion(result)
        XCTAssertFalse(progressive(f), "Latest crop adoption enters the ordinary atomic install path")
        render(f)
        XCTAssertFalse(f.metal.testingFailNextEncoding, "Failure must reach the real Metal encoding path")
        XCTAssertEqual(f.metal.submittedFrameCount, submitted)
        XCTAssertTrue(f.imageView.image === oldImage)
        XCTAssertFalse(f.imageView.isHidden)
        XCTAssertEqual(f.baseRevision, oldBase)
        XCTAssertTrue(try Base.pixels(XCTUnwrap(result.image)) != oldPixels,
                      "The pending crop really has different pixels, rather than being an identity-only no-op")

        // This is identity-only relative to the adopted, NOT displayed, crop.
        // id == clientMutationId deliberately keeps the legacy deletion proof
        // valid, isolating accidental relabelling from the positive metadata-
        // association transition covered by NativePDFErasureIdentityTests.
        let metadataOnly = Array(original.dropFirst()).map { value -> [String: Any] in
            var copy = value
            copy.removeValue(forKey: "clientMutationId")
            copy["updatedAt"] = "receipt-only"
            return copy
        }
        let reuses = int(f, "sceneReuses")
        f.metal.testingFailNextEncoding = true
        f.replace(metadataOnly); render(f)
        XCTAssertEqual(int(f, "sceneReuses"), reuses + 1)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneRenderMode"] as? String, "reuse")
        XCTAssertEqual(f.metal.submittedFrameCount, submitted)
        XCTAssertTrue(f.imageView.image === oldImage)
        XCTAssertFalse(f.imageView.isHidden)
        XCTAssertEqual(f.baseRevision, oldBase)
        XCTAssertTrue(try Base.pixels(XCTUnwrap(f.imageView.image?.cgImage)) == oldPixels)

        f.replace([metadataOnly[1]]); render(f)
        XCTAssertTrue(progressive(f), "Re-entry must describe the actually visible original three-row image")
        XCTAssertTrue(f.imageView.image === oldImage)
        let latest = try await currentRequest(f)
        XCTAssertNotEqual(latest.snapshot.revision, first.snapshot.revision)

        // A replay of the first worker result is now a strict intermediate
        // deletion. If metadata reuse relabelled old pixels as that two-row
        // crop, the strict count/provenance guard would wrongly reject it.
        first.completion(result)
        try await require {
            self.int(f, "progressiveErasureInstalls") == oldInstalls + 1 &&
                f.imageView.image !== oldImage && !f.imageView.isHidden
        }
        XCTAssertTrue(progressive(f), "The newest one-row crop is still held")
        XCTAssertEqual(f.baseObjects, 2)
        XCTAssertTrue(try Base.pixels(XCTUnwrap(f.imageView.image?.cgImage)) == Base.pixels(result.image))
        let intermediate = f.imageView.image
        first.completion(result)
        XCTAssertTrue(f.imageView.image === intermediate)
        XCTAssertEqual(int(f, "progressiveErasureInstalls"), oldInstalls + 1)

        try await f.gate.finish(latest)
        try await assertSettledExactly(f)
        XCTAssertEqual(f.fullRenders, full)
        XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertTrue(try NativePDFJournal(root: f.root).pending(courseID: "async", relativePath: "fixture.pdf").isEmpty)
    }

    func testMatchingRowIdentityDoesNotAuthorizeChangedRetainedAppearanceOrOrder() throws {
        let size = CGSize(width: 384, height: 512)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let mapper = InkCoordinateMapper.whiteboard(size: size)
        let builder = NativePDFNavigationSnapshotBuilder()
        let original = [row("A", color: "red", y: 0.55), row("B", color: "green", y: 0.70),
                        row("survivor", color: "blue", y: 0.85)]
        func content(_ rows: [[String: Any]], highlights: [[String: Any]] = []) throws -> NativePDFRetainedInkBackdrop.Content {
            let snapshot = try XCTUnwrap(builder.make(page: page, objects: rows, tokens: nil,
                                                     highlights: highlights, image: { _ in nil }))
            return try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: snapshot, mapper: mapper,
                objects: rows, tokens: nil, highlights: highlights, imageForObject: { _ in nil }))
        }
        let accepted = try content(original), deleted = Array(original.dropFirst())
        XCTAssertTrue(try content(deleted).isDeletionSuccessor(of: accepted))
        for change in 0..<4 {
            var changed = deleted
            switch change {
            case 0:
                var data = try XCTUnwrap(changed[0]["data"] as? [String: Any])
                var points = try XCTUnwrap(data["points"] as? [[String: Double]])
                points[0]["p"] = 0.3; data["points"] = points; changed[0]["data"] = data
            case 1:
                changed[0]["style"] = ["color": "green", "width": 0.018, "opacity": 0.45]
            case 2:
                changed.reverse()
            default:
                changed[0]["kind"] = "highlighter"
            }
            XCTAssertFalse(try content(changed).isDeletionSuccessor(of: accepted),
                           "Equal row IDs do not prove unchanged pressure/style/order/blend: case \(change)")
        }
        let highlight: [String: Any] = ["rects": [["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.1]],
                                       "color": "yellow", "nativeOpacity": 0.4]
        XCTAssertFalse(try content(deleted, highlights: [highlight]).isDeletionSuccessor(of: accepted))
        XCTAssertTrue(try content(deleted).isDeletionSuccessor(of: accepted),
                      "Failed comparisons must not mutate the captured content")
    }

    private func row(_ id: String, color: String, y: Double) -> [String: Any] {
        let points: [[String: Double]] = [["x": 0.15, "y": y, "p": 0.8], ["x": 0.85, "y": y, "p": 0.8]]
        let data: [String: Any] = ["inkVersion": 4, "points": points]
        let style: [String: Any] = ["color": color, "width": 0.018, "opacity": 1.0]
        return ["id": id, "clientMutationId": id, "page": 1, "kind": "ink", "data": data, "style": style]
    }
    private func int(_ f: Base.Fixture, _ key: String) -> Int { f.surface.inputDiagnostics[key] as? Int ?? -1 }
    private func progressive(_ f: Base.Fixture) -> Bool { f.surface.inputDiagnostics["progressiveErasureActive"] as? Bool == true }
    private func render(_ f: Base.Fixture) { _ = f.surface.perform(NSSelectorFromString("renderPreview")) }
    private func require(_ condition: @escaping @MainActor () -> Bool) async throws {
        let passed = await Base.poll(timeout: 5, condition)
        XCTAssertTrue(passed, "Required identity safety state timed out")
        guard passed else { throw Failure.timeout }
    }
    private func currentRequest(_ f: Base.Fixture) async throws -> NativePDFNavigationRasterizer.Request {
        try await require {
            f.gate.requests.last?.snapshot.revision == f.surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64 &&
                f.gate.requests.last?.snapshot.objects.count == f.rows.count
        }
        return try XCTUnwrap(f.gate.requests.last)
    }
    private func raster(_ request: NativePDFNavigationRasterizer.Request) async throws -> NativePDFNavigationSnapshot.Raster {
        let snapshot = request.snapshot, bounds = request.bounds, scale = request.scale
        let transform = request.transform, prefix = request.stablePrefixCount
        let value = await Task.detached(priority: .userInitiated) {
            autoreleasepool { snapshot.raster(bounds: bounds, scale: scale, canonicalToCanvas: transform, stablePrefixCount: prefix) }
        }.value
        return try XCTUnwrap(value)
    }
    private func assertSettledExactly(_ f: Base.Fixture) async throws {
        try await require {
            !f.editActive && f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                !f.imageView.isHidden && f.metal.strokes.isEmpty &&
                f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        let viewport = try XCTUnwrap(f.surface.renderViewport), mapper = try XCTUnwrap(f.surface.mapper)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in f.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
        let actual = try XCTUnwrap(f.imageView.image?.cgImage)
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertTrue(try Base.pixels(actual) == Base.pixels(expected), "Final one-pass PDF + ordered objects must be exact")
    }
    private enum Failure: Error { case timeout }
}
