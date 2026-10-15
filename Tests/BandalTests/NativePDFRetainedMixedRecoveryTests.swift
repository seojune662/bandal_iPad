import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

/// A real Surface's stationary contact must wake when an initially unavailable
/// mixed scene obtains its textures. The injected failure belongs only to the
/// old legacy whole-scene backdrop; its three-attempt budget must stay exhausted.
@MainActor
final class NativePDFRetainedMixedRecoveryTests: XCTestCase {
    func testReadyObjectTextureReviewsExhaustedLegacyBackdropWithoutAnotherTouch() async throws {
        let gate = Gate(), loader = OldImageFailure()
        try await wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); window.layoutIfNeeded()
        let size = CGSize(width: 300, height: 400), bounds = CGRect(origin: .zero, size: size)
        let document = try XCTUnwrap(PDFDocument(data: UIGraphicsPDFRenderer(bounds: bounds).pdfData { $0.beginPage() }))
        let metal = try XCTUnwrap(NativePDFMetalInk(textureLoader: { try loader.load($0, $1) }))
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: bounds, renderer: metal,
            retainedObjectRasterize: { await gate.capture($0) }))
        var errors: [Error] = [], saved: [NativePDFCompletedStroke] = []
        surface.onFailure = { errors.append($0) }; surface.onStroke = { saved.append($0) }
        defer {
            // The actor gate never blocks the main thread, including failure
            // cleanup; closed gates also answer any later retry immediately.
            Task { await gate.close() }
            surface.finishMeasuredStroke(); surface.removeFromSuperview()
            surface.onFailure = nil; surface.onStroke = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        surface.pdfPage = try XCTUnwrap(document.page(at: 0)); surface.mapper = .whiteboard(size: size)
        surface.isLoading = false
        surface.tool = .init(name: "pen", style: .init(color: "blue", width: 0.01, opacity: 1))
        let object: [String: Any] = ["id": "held-rect", "page": 1, "kind": "rect",
            "data": ["box": ["x": 0.15, "y": 0.15, "width": 0.3, "height": 0.2]],
            "style": ["color": "blue", "width": 0.01, "opacity": 0.6]]
        surface.applyObjects(objects: [object], visualTokens: [NativePDFCommittedVisualToken(object: object)])
        // Establish the first nonempty candidate before enabling the new owner;
        // an accepted empty GPU scene would intentionally remain active instead.
        surface.retainedInkEnabled = true
        window.rootViewController!.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
        try await wait { await gate.count == 1 }
        let sceneImage = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        try await wait {
            sceneImage.image != nil && !sceneImage.isHidden &&
            surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertEqual(surface.inputDiagnostics["retainedInkActive"] as? Bool, false)
        XCTAssertEqual(surface.inputDiagnostics["retainedObjectPreparing"] as? Bool, true)
        XCTAssertEqual(loader.attempts, 0, "The ordinary initial clear needs no backdrop upload")

        surface.tool = .init(name: "highlighter", style: .init(color: "yellow", width: 0.03, opacity: 0.4))
        let touch = StationaryTouch(point: CGPoint(x: 150, y: 220))
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        let originalInput = try XCTUnwrap(metal.pendingInputTiming)
        try await wait {
            surface.inputDiagnostics["backdropRecoveryState"] as? String == "exhausted" &&
            surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertEqual(loader.attempts, 3); XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(surface.inputDiagnostics["backdropRetryScheduled"] as? Bool, false)
        XCTAssertEqual(surface.inputDiagnostics["retainedInkActive"] as? Bool, false)
        XCTAssertTrue(saved.isEmpty)
        let rejectedImage = try XCTUnwrap(loader.failedImage)
        XCTAssertTrue(metal.backdrop === rejectedImage)
        let before = metal.submittedFrameCount
        let attemptsBeforeRelease = surface.inputDiagnostics["renderAttempts"] as? Int ?? -1
        let pendingWork = await gate.currentWork()
        let work = try XCTUnwrap(pendingWork)
        let bitmap = await Task.detached { NativePDFRetainedObjectTextures.rasterize(work) }.value
        XCTAssertNotNil(bitmap)
        await gate.finish(bitmap)

        // No move, lift, new row, tool assignment, layout call, or manual render
        // occurs here. Only resource readiness is allowed to wake the pipeline.
        try await wait {
            metal.submittedFrameCount > before && !metal.strokes.isEmpty &&
            surface.inputDiagnostics["retainedInkActive"] as? Bool == true &&
            surface.inputDiagnostics["retainedObjectPreparing"] as? Bool == false
        }
        XCTAssertGreaterThan(surface.inputDiagnostics["renderAttempts"] as? Int ?? -1, attemptsBeforeRelease)
        XCTAssertEqual(surface.inputDiagnostics["retainedObjectUploads"] as? Int, 1)
        XCTAssertEqual(metal.retainedItems?.filter { $0.texture != nil }.count, 1)
        XCTAssertEqual(surface.inputDiagnostics["backdropRecoveryState"] as? String, "ready")
        XCTAssertFalse(metal.backdrop === rejectedImage)
        XCTAssertEqual(loader.failedAttempts, 3, "Resource readiness must not revive the old image's exhausted budget")
        XCTAssertEqual(errors.count, 1); XCTAssertTrue(saved.isEmpty)
        let submitted = try XCTUnwrap(metal.lastSubmittedFrame)
        XCTAssertEqual(submitted.strokeID, originalInput.strokeID)
        XCTAssertEqual(submitted.firstInputAt, originalInput.firstInputAt)
        XCTAssertEqual(touch.phase, .began)
        // Readback proves the recovered stationary highlighter is not an empty
        // accepted frame. This is GPU pixel content, not display presentation.
        let bytes = try XCTUnwrap(metal.renderedPixels(width: 300, height: 400))
        let offset = (220 * 300 + 150) * 4
        XCTAssertEqual(bytes[offset + 3], 255)
        XCTAssertLessThan(bytes[offset], 245, "Yellow multiply ink must lower the white paper's blue channel")
        touch.time += 0.01; surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(saved.count, 1)
        let stroke = try XCTUnwrap(saved.first)
        XCTAssertEqual(stroke.kind, "highlighter"); XCTAssertEqual(stroke.points.count, 2)
        for point in stroke.points {
            XCTAssertEqual(point.x.bitPattern, Double(0.5).bitPattern)
            XCTAssertEqual(point.y.bitPattern, Double(0.55).bitPattern)
            XCTAssertEqual(point.p.bitPattern, Double(0.5).bitPattern)
        }
    }

    /// Reproduces the 13-inch fixture's density-8 undo boundary through the
    /// actual model/cache and CG raster worker. No Surface or synthetic failure
    /// is needed: restored IDs require fresh textures while survivors stay owned.
    func testDensityEightMixedUndoNewIDsKeepsSurvivorsAndRecoversWithinBudget() async throws {
        typealias Textures = NativePDFRetainedObjectTextures
        typealias Scene = NativePDFRetainedMixedScene
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(NativePDFRetainedInkRenderer(device: device))
        let audit = RasterAudit()
        let textures = Textures(renderer: renderer, rasterize: { work in
            await audit.record(work)
            let bitmap = await Task.detached { Textures.rasterize(work) }.value
            await audit.finished()
            return bitmap
        })
        let model = Scene(renderer: renderer, textures: textures)
        let pageSize = CGSize(width: 612, height: 792)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor.systemYellow.setFill(); context.fill(CGRect(x: 8, y: 6, width: 16, height: 12))
        }
        let text: [String: Any] = ["id": "text-original", "kind": "textbox",
            "data": ["box": ["x": 0.2, "y": 0.25, "width": 0.6, "height": 0.45], "text": "Mixed native eraser fixture"],
            "style": ["color": "red", "width": 0.004, "opacity": 0.8, "fontSizePt": 14]]
        let rect: [String: Any] = ["id": "rect-original", "kind": "rect",
            "data": ["box": ["x": 0.3, "y": 0.35, "width": 0.4, "height": 0.3]],
            "style": ["color": "violet", "width": 0.004, "opacity": 0.8]]
        let legacy: [String: Any] = ["id": "surviving-legacy", "kind": "highlighter",
            "data": ["points": [["x": 0.25, "y": 0.55, "p": 0.4], ["x": 0.5, "y": 0.55, "p": 0.6], ["x": 0.75, "y": 0.55, "p": 0.5]]],
            "nativePath": "M 0.25 0.542 L 0.75 0.542 L 0.75 0.558 L 0.25 0.558 Z",
            "style": ["color": "yellow", "width": 0.02, "opacity": 0.3]]
        let imageRow: [String: Any] = ["id": "surviving-image", "kind": "image",
            "data": ["box": ["x": 0.77, "y": 0.12, "width": 0.16, "height": 0.12],
                     "image": ["relPath": "synthetic-only.png"]],
            "style": ["color": "ink", "width": 0.004, "opacity": 1.0]]
        var desired = [text, rect, legacy, imageRow]
        var scale: CGFloat = 4
        var lastResult = Scene.UpdateResult.unsupported
        func update() -> Scene.UpdateResult {
            model.update(objects: desired, visualTokens: nil, pageSize: pageSize, scale: scale,
                         image: { ($0["kind"] as? String) == "image" ? image : nil })
        }
        model.onResourcesChanged = { lastResult = update() }
        defer { model.onResourcesChanged = nil; model.reset() }
        XCTAssertEqual(update(), .preparing)
        try await wait { lastResult == .supported && model.objectCount == 4 }
        XCTAssertLessThanOrEqual(textures.accountedBytes, textures.byteLimit)

        // Initial layout can accept density 4; the larger viewport requests 8.
        // Erase the textbox/rect, retaining the same image and legacy marker.
        let uploadsBeforeDeletion = textures.uploadCount
        desired = [legacy, imageRow]; scale = 8
        lastResult = update()
        // Both survivors must finish their density upgrade before measuring
        // undo ownership; an accepted old resource alone is not a settled job.
        try await wait {
            lastResult == .supported && model.objectCount == 2 &&
                textures.uploadCount == uploadsBeforeDeletion + 2
        }
        try await wait { await audit.idle }
        lastResult = update()
        let survivorItems = model.items(transform: .identity, excludingIDs: [])
        XCTAssertEqual(survivorItems.count, 2)
        let survivorLegacy = try XCTUnwrap(survivorItems[0].texture)
        let survivorImage = try XCTUnwrap(survivorItems[1].texture)
        let acceptedRevision = model.acceptedRevision
        let textSource = try XCTUnwrap(Textures.capture(object: text, pageSize: pageSize))
        let desiredTextWork = try XCTUnwrap(Textures.work(source: textSource, scale: scale))
        XCTAssertGreaterThan(desiredTextWork.byteCount * 2 + survivorImage.byteCount, textures.byteLimit,
            "The actual fixture must exceed the old density-8 admission budget even before other ownership charges")

        var restoredText = text; restoredText["id"] = "text-undo-new-id"
        var restoredRect = rect; restoredRect["id"] = "rect-undo-new-id"
        desired = [restoredText, restoredRect, legacy, imageRow]
        lastResult = update()
        XCTAssertEqual(lastResult, .preparing, "Budget adaptation must retain the GPU owner while preparing undo")
        XCTAssertTrue(model.hasAcceptedScene)
        XCTAssertEqual(model.acceptedRevision, acceptedRevision)
        let pendingItems = model.items(transform: .identity, excludingIDs: [])
        XCTAssertEqual(pendingItems.count, 2)
        XCTAssertTrue(pendingItems[0].texture === survivorLegacy)
        XCTAssertTrue(pendingItems[1].texture === survivorImage)
        try await wait { lastResult == .supported && model.objectCount == 4 && !model.preparing }
        try await wait { await audit.idle }
        let restored = model.items(transform: .identity, excludingIDs: [])
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(restored.map(\.multiply), [false, false, true, false])
        XCTAssertTrue(restored[2].texture === survivorLegacy)
        XCTAssertTrue(restored[3].texture === survivorImage)
        let textTexture = try XCTUnwrap(restored[0].texture)
        let actualTextScale = CGFloat(textTexture.texture.width) / (restored[0].transform.a * pageSize.width)
        XCTAssertGreaterThan(actualTextScale, 0)
        XCTAssertLessThan(actualTextScale, scale, "The fresh large textbox must use an admitted lower-density texture")
        XCTAssertLessThanOrEqual(textures.accountedBytes, textures.byteLimit)
        XCTAssertEqual(model.items(transform: .identity, excludingIDs: ["text-original", "rect-original"]).count, 4)
        XCTAssertEqual(model.items(transform: .identity, excludingIDs: ["text-undo-new-id", "rect-undo-new-id"]).count, 2)
        let uploads = textures.uploadCount, rasters = textures.rasterCount
        let jobs = await audit.startedCount
        for _ in 0..<20 {
            XCTAssertEqual(update(), .supported)
            XCTAssertLessThanOrEqual(textures.accountedBytes, textures.byteLimit)
            await Task.yield()
        }
        let jobsAfter = await audit.startedCount
        XCTAssertEqual(jobsAfter, jobs, "Unchanged desired density must not repeatedly raster the admitted lower-density resource")
        XCTAssertEqual(textures.uploadCount, uploads); XCTAssertEqual(textures.rasterCount, rasters)
    }

    private actor RasterAudit {
        private(set) var startedCount = 0
        private(set) var finishedCount = 0
        func record(_ work: NativePDFRetainedObjectTextures.Work) { startedCount += 1 }
        func finished() { finishedCount += 1 }
        var idle: Bool { finishedCount == startedCount }
    }

    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let end = CACurrentMediaTime() + 5
        while !(await predicate()), CACurrentMediaTime() < end { try await Task.sleep(nanoseconds: 2_000_000) }
        guard await predicate() else { XCTFail("Mixed recovery state timed out"); throw NSError(domain: "MixedRecovery", code: 1) }
    }
    private actor Gate {
        private var work: NativePDFRetainedObjectTextures.Work?
        private var reply: CheckedContinuation<NativePDFRetainedObjectTextures.Bitmap?, Never>?
        private var closed = false
        private(set) var count = 0
        func currentWork() -> NativePDFRetainedObjectTextures.Work? { work }
        func capture(_ work: NativePDFRetainedObjectTextures.Work) async -> NativePDFRetainedObjectTextures.Bitmap? {
            guard !closed else { return nil }
            count += 1; self.work = work
            return await withCheckedContinuation { reply = $0 }
        }
        func finish(_ bitmap: NativePDFRetainedObjectTextures.Bitmap?) { let current = reply; reply = nil; current?.resume(returning: bitmap) }
        func close() { closed = true; finish(nil) }
    }
    @MainActor private final class OldImageFailure {
        var failedImage: CGImage?
        var attempts = 0, failedAttempts = 0
        func load(_ device: MTLDevice, _ image: CGImage) throws -> MTLTexture {
            attempts += 1
            if failedImage == nil { failedImage = image }
            if image === failedImage { failedAttempts += 1; throw NSError(domain: "OldBackdropFixture", code: 1) }
            return try MTKTextureLoader(device: device).newTexture(cgImage: image,
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        }
    }
    @MainActor private final class StationaryTouch: UITouch {
        var point: CGPoint, time = CACurrentMediaTime()
        init(point: CGPoint) { self.point = point; super.init() }
        override var type: UITouch.TouchType { .pencil }
        override var phase: UITouch.Phase { .began }
        override var timestamp: TimeInterval { time }
        override var force: CGFloat { 0.5 }
        override var maximumPossibleForce: CGFloat { 1 }
        override var altitudeAngle: CGFloat { .pi / 2 }
        override func location(in view: UIView?) -> CGPoint { point }
        override func preciseLocation(in view: UIView?) -> CGPoint { point }
        override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
    }
}
