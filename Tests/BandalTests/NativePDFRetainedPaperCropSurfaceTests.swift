import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

@MainActor
final class NativePDFRetainedPaperCropSurfaceTests: XCTestCase {
    func testCanonicalCropInverseAndImageUVRemainRegisteredThroughAffineNavigation() throws {
        let page = CGSize(width: 400,height: 600), viewport = CGSize(width: 280,height: 320)
        let affines = [CGAffineTransform(a: 3,b: 0,c: 0,d: 3,tx: -100,ty: -150),
                       CGAffineTransform(a: 0,b: 3,c: -3,d: 0,tx: 1000,ty: -100),
                       CGAffineTransform(a: -3,b: 0,c: 0,d: -3,tx: 1000,ty: 1500),
                       CGAffineTransform(a: 0,b: -3,c: 3,d: 0,tx: -100,ty: 1000),
                       CGAffineTransform(a: 3,b: 0.3,c: 0.2,d: 2,tx: -100,ty: -150)]
        for canonical in affines {
            let normalized = CGAffineTransform(a: canonical.a*page.width,b: canonical.b*page.width,
                c: canonical.c*page.height,d: canonical.d*page.height,tx: canonical.tx,ty: canonical.ty)
            let query = try XCTUnwrap(NativePDFInkSurface.retainedPaperCropQuery(normalizedToViewport: normalized,
                pageSize: page, viewportSize: viewport, pixelScale: 2))
            let expected = CGRect(origin: .zero,size: viewport).applying(canonical.inverted())
                .intersection(CGRect(origin: .zero,size: page))
            XCTAssertEqual(query.bounds.minX, expected.minX, accuracy: 1e-10)
            XCTAssertEqual(query.bounds.minY, expected.minY, accuracy: 1e-10)
            XCTAssertEqual(query.bounds.width, expected.width, accuracy: 1e-10)
            XCTAssertEqual(query.bounds.height, expected.height, accuracy: 1e-10)
            XCTAssertGreaterThanOrEqual(query.scale+1e-10, 2*max(hypot(canonical.a,canonical.b),hypot(canonical.c,canonical.d)))
            let imageToViewport = NativePDFInkSurface.retainedPaperCropTransform(bounds: query.bounds,
                pageSize: page, normalizedToViewport: normalized)
            for uv in [CGPoint.zero,CGPoint(x: 1,y: 0),CGPoint(x: 0,y: 1),CGPoint(x: 1,y: 1),CGPoint(x: 0.37,y: 0.63)] {
                let source = CGPoint(x: query.bounds.minX+uv.x*query.bounds.width,y: query.bounds.minY+uv.y*query.bounds.height)
                let a = uv.applying(imageToViewport), b = source.applying(canonical)
                XCTAssertEqual(a.x,b.x,accuracy: 1e-10); XCTAssertEqual(a.y,b.y,accuracy: 1e-10)
            }
        }
        let unzoomed = CGAffineTransform(scaleX: page.width,y: page.height)
        let query = try XCTUnwrap(NativePDFInkSurface.retainedPaperCropQuery(normalizedToViewport: unzoomed,
            pageSize: page,viewportSize: viewport,pixelScale: 2))
        XCTAssertEqual(query.scale,2,"An unzoomed page must not acquire a sqrt(2) density multiplier")
        XCTAssertNil(NativePDFInkSurface.retainedPaperCropQuery(normalizedToViewport: .init(a: 0,b: 0,c: 0,d: 0,tx: 0,ty: 0),
            pageSize: page,viewportSize: viewport,pixelScale: 2))
    }

    func testHeldHighResolutionPaperDoesNotDelayPenOrRebuildCompletedInk() async throws {
        let loader = BaseOnlyLoader(successfulUploads: 2)
        let f = try await Fixture(loader: loader); defer { f.close() }
        let base = try XCTUnwrap(f.metal.backdrop), uploads = try XCTUnwrap(f.metal.retainedRenderer).meshUploadCount
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperRasters"] as? Int,1)
        f.zoom()
        try await wait { await f.gate.count == 1 }
        try await wait { f.surface.inputDiagnostics["frameRequested"] as? Bool == false }
        XCTAssertTrue(f.metal.backdrop === base)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperCropActive"] as? Bool,false)
        let beforePixels = try XCTUnwrap(f.metal.renderedPixels(width: 400,height: 600))
        let before = f.metal.submittedFrameCount
        let touch = LocalTouch(point: CGPoint(x: 260,y: 300))
        XCTAssertTrue(f.surface.beginPencilGesture(touch,with: nil))
        try await wait { f.metal.submittedFrameCount > before && !f.metal.strokes.isEmpty }
        XCTAssertTrue(f.metal.backdrop === base,"Waiting for detail must keep the ready opaque base")
        touch.point.x += 20; touch.time += 0.008
        f.surface.movePencilGesture(touch,with: nil)
        touch.point.x += 20; touch.time += 0.008
        f.surface.endPencilGesture(touch,with: nil)
        XCTAssertEqual(f.saved.count,1); XCTAssertEqual(f.saved[0].points.count,3)
        XCTAssertEqual(f.saved[0].points[0].p.bitPattern,Double(0.5).bitPattern)
        XCTAssertEqual(f.saved[0].points[0].x,(30+260.0/4)/400,accuracy: 1e-12)
        try await wait { f.metal.retainedItems?.count == 2 && f.metal.strokes.isEmpty }
        let request = await f.gate.request(0)
        XCTAssertTrue(request.snapshot.objects.isEmpty)
        let result = try XCTUnwrap(request.snapshot.raster(bounds: request.bounds,scale: request.scale,canonicalToCanvas: .identity))
        await f.gate.finish(0,result: result)
        try await wait { f.surface.inputDiagnostics["retainedPaperCropActive"] as? Bool == true }
        XCTAssertTrue(f.metal.backdrop === result.image)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperRasters"] as? Int,1)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperCropRasters"] as? Int,1)
        XCTAssertEqual(f.metal.retainedRenderer?.meshUploadCount,uploads+1,"Only the newly completed pen uploads geometry")
        let afterPixels = try XCTUnwrap(f.metal.renderedPixels(width: 400,height: 600))
        // Deep inside the same opaque PDF rectangle, unrelated to the new
        // pen: crop/base registration and color must agree exactly.
        let offset = (100*400+100)*4
        XCTAssertEqual(beforePixels[offset..<offset+4],afterPixels[offset..<offset+4])
        XCTAssertNotEqual(Array(afterPixels[offset..<offset+3]),[255,255,255])
        XCTAssertEqual(loader.attempts,2,"One base and one detail upload")
        let installed = f.metal.submittedFrameCount
        f.zoom(origin: CGPoint(x: 180,y: 250))
        try await wait { f.metal.submittedFrameCount > installed && f.surface.inputDiagnostics["retainedPaperCropActive"] as? Bool == false }
        XCTAssertTrue(f.metal.backdrop === base)
        XCTAssertEqual(loader.attempts,2,"Leaving crop coverage must restore the original GPU base without uploading it again")
        XCTAssertEqual(loader.rejected,0,"Any third upload would fail in this fixture")
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperRasters"] as? Int,1)
        XCTAssertNotNil(f.metal.renderedPixels(width: 400,height: 600))
        XCTAssertTrue(f.errors.isEmpty)
    }

    func testCropUploadFailureKeepsBaseAndDoesNotBlockOrRetryEveryPenFrame() async throws {
        let loader = BaseOnlyLoader(), f = try await Fixture(loader: loader); defer { f.close() }
        let base = try XCTUnwrap(f.metal.backdrop)
        f.zoom(); try await wait { await f.gate.count == 1 }
        let request = await f.gate.request(0)
        let result = try XCTUnwrap(request.snapshot.raster(bounds: request.bounds,scale: request.scale,canonicalToCanvas: .identity))
        await f.gate.finish(0,result: result)
        try await wait { loader.rejected == 1 }
        XCTAssertTrue(f.metal.backdrop === base)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedPaperCropActive"] as? Bool,false)
        let before = f.metal.submittedFrameCount, touch = LocalTouch(point: CGPoint(x: 260,y: 300))
        XCTAssertTrue(f.surface.beginPencilGesture(touch,with: nil))
        for _ in 0..<4 { touch.point.x += 5; touch.time += 0.008; f.surface.movePencilGesture(touch,with: nil); await Task.yield() }
        try await wait { f.metal.submittedFrameCount > before && !f.metal.strokes.isEmpty }
        touch.point.x += 5; touch.time += 0.008
        f.surface.endPencilGesture(touch,with: nil)
        try await wait { f.metal.retainedItems?.count == 2 && f.metal.strokes.isEmpty }
        XCTAssertEqual(loader.rejected,1,"An optional failed texture must not reset its budget on every base fallback")
        XCTAssertEqual(loader.attempts,2,"After the first base succeeds every upload fails; recovery must not try to upload that base again")
        XCTAssertEqual(f.saved.count,1); XCTAssertEqual(f.saved[0].points.count,6)
        XCTAssertTrue(f.metal.backdrop === base); XCTAssertTrue(f.errors.isEmpty)
        XCTAssertEqual(f.diagnostics.filter { $0 == "paper.crop.texture.failed.base-fallback" }.count,1)
    }

    func testOptionalSelectionPreservesRecoveryAndInputOnFailureAndReleasesFallbackOnReset() throws {
        let loader = BaseOnlyLoader(successfulUploads: 2)
        let metal = try XCTUnwrap(NativePDFMetalInk(textureLoader: loader.load,clock: { 0 }))
        let base = try opaqueImage(.white), crop = try opaqueImage(.yellow), failing = try opaqueImage(.cyan)
        metal.backdrop = base
        XCTAssertEqual(metal.prepareBackdropForFrame(required: true),.ready, "Fixture base upload failed: \(String(describing: metal.backdropUploadErrorDescription))")
        metal.noteInputReceived(at: 1000,strokeID: 42)
        metal.noteInputReceived(at: 1000.02,strokeID: 42)
        XCTAssertTrue(metal.selectOptionalBackdrop(crop,preserving: base))
        let generation = metal.backdropRecoveryGeneration, attempts = metal.backdropUploadAttemptCount
        XCTAssertFalse(metal.selectOptionalBackdrop(failing,preserving: base))
        XCTAssertTrue(metal.backdrop === crop)
        XCTAssertEqual(metal.prepareBackdropForFrame(required: true),.ready)
        XCTAssertEqual(metal.backdropRecoveryGeneration,generation)
        XCTAssertEqual(metal.backdropUploadAttemptCount,attempts)
        XCTAssertNil(metal.backdropUploadErrorDescription)
        XCTAssertEqual(metal.pendingInputTiming?.firstInputAt,1000)
        XCTAssertEqual(metal.pendingInputTiming?.latestInputAt,1000.02)
        metal.backdrop = base
        XCTAssertEqual(loader.attempts,3)
        XCTAssertEqual(metal.prepareBackdropForFrame(required: true),.ready)
        XCTAssertTrue(metal.backdrop === base)
        // An explicit page reset must release the saved GPU dependency, so
        // selecting that same old image now needs a fresh (failing) upload.
        metal.resetBackdropRecovery(); metal.backdrop = base
        XCTAssertEqual(loader.attempts,4)
        if case .waiting = metal.prepareBackdropForFrame(required: true) {} else { XCTFail("Reset must not reuse a texture from the prior page") }
    }

    func testNilAndUnrelatedImageDropTheOptionalFallbackInsteadOfCachingPages() throws {
        let loader = BaseOnlyLoader(successfulUploads: 20)
        let metal = try XCTUnwrap(NativePDFMetalInk(textureLoader: loader.load,clock: { 0 }))
        let base = try opaqueImage(.white), crop = try opaqueImage(.yellow), nextPage = try opaqueImage(.cyan)
        metal.backdrop = base
        XCTAssertEqual(metal.prepareBackdropForFrame(required: true),.ready, "Fixture base upload failed: \(String(describing: metal.backdropUploadErrorDescription))")
        XCTAssertTrue(metal.selectOptionalBackdrop(crop,preserving: base))
        XCTAssertEqual(loader.attempts,2)
        metal.backdrop = nil; metal.backdrop = base
        XCTAssertEqual(loader.attempts,3,"nil releases both optional resource identities")
        XCTAssertTrue(metal.selectOptionalBackdrop(crop,preserving: base))
        metal.backdrop = nextPage; metal.backdrop = base
        XCTAssertEqual(loader.attempts,6,"An unrelated page does not retain the earlier fallback")
        XCTAssertTrue(metal.selectOptionalBackdrop(crop,preserving: base))
        metal.resetBackdropRecovery(); metal.backdrop = base
        XCTAssertEqual(loader.attempts,8,"Explicit reset while a crop is selected releases its preserved base too")
        XCTAssertEqual(metal.prepareBackdropForFrame(required: true),.ready)
    }

    /// Match the paper renderer's explicit 8-bit BGRA storage. A default
    /// UIGraphicsImageRenderer may choose a grayscale/extended representation
    /// for a solid white fixture, which MTKTextureLoader can reject before the
    /// optional-selection behavior under test is reached.
    private func opaqueImage(_ color: UIColor) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = try XCTUnwrap(CGContext(data: nil,width: 4,height: 4,bitsPerComponent: 8,
            bytesPerRow: 16,space: space,bitmapInfo: info))
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0,y: 0,width: 4,height: 4))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(image.bitsPerComponent,8); XCTAssertEqual(image.bitsPerPixel,32)
        return image
    }

    private static func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime()+5
        while !(await predicate()), CACurrentMediaTime()<deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard await predicate() else { XCTFail("Retained crop Surface condition timed out"); throw NSError(domain: "PaperCropSurfaceTest",code: 1) }
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws { try await Self.wait(predicate) }
    private actor Gate {
        struct Pending { let request: NativePDFRetainedPaperCrop.Request; var continuation: CheckedContinuation<NativePDFNavigationSnapshot.Raster?,Never>? }
        private var requests: [Pending] = []
        private var closed = false
        var count: Int { requests.count }
        func request(_ index: Int) -> NativePDFRetainedPaperCrop.Request { requests[index].request }
        func capture(_ request: NativePDFRetainedPaperCrop.Request) async -> NativePDFNavigationSnapshot.Raster? {
            guard !closed else { return nil }
            return await withCheckedContinuation { requests.append(Pending(request: request,continuation: $0)) }
        }
        func finish(_ index: Int,result: NativePDFNavigationSnapshot.Raster?) {
            let continuation = requests[index].continuation; requests[index].continuation = nil
            continuation?.resume(returning: result)
        }
        func cancelAll() { closed = true; for index in requests.indices { finish(index,result: nil) } }
    }
    @MainActor private final class BaseOnlyLoader {
        let successfulUploads: Int
        var attempts = 0, rejected = 0
        init(successfulUploads: Int = 1) { self.successfulUploads = successfulUploads }
        func load(_ device: MTLDevice,_ image: CGImage) throws -> MTLTexture {
            attempts += 1
            guard attempts <= successfulUploads else { rejected += 1; throw NSError(domain: "CropUploadFixture",code: 1) }
            return try MTKTextureLoader(device: device).newTexture(cgImage: image,options: [.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft])
        }
    }
    @MainActor private final class Fixture {
        let gate: Gate, window: UIWindow, previous: UIWindow?, surface: NativePDFInkSurface, metal: NativePDFMetalInk
        let size = CGSize(width: 400,height: 600)
        var rows: [[String: Any]] = [], saved: [NativePDFCompletedStroke] = []
        var errors: [Error] = [], diagnostics: [String] = []
        init(loader: BaseOnlyLoader? = nil) async throws {
            let gate = Gate(), size = CGSize(width: 400,height: 600); self.gate = gate
            try await NativePDFRetainedPaperCropSurfaceTests.wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible(); window.layoutIfNeeded()
            metal = try XCTUnwrap(NativePDFMetalInk(textureLoader: loader.map { value in { try value.load($0,$1) } }))
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero,size: size),renderer: metal,
                navigationRasterRequest: { _ in },retainedPaperCropRasterize: { await gate.capture($0) }))
            // Keep the initial physical density at 1 px/canonical point on
            // both 2x and 3x hosts. The later 4x mapper zoom requires detail.
            surface.transform = CGAffineTransform(scaleX: 1/window.screen.scale,y: 1/window.screen.scale)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero,size: size)).pdfData { renderer in
                renderer.beginPage(); UIColor(white: 0.75,alpha: 1).setFill()
                renderer.cgContext.fill(CGRect(x: 40,y: 50,width: 40,height: 30))
            }
            surface.pdfPage = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
            surface.retainedInkEnabled = true; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.tool = .init(name: "pen",style: .init(color: "blue",width: 0.006,opacity: 0.45))
            rows = [["id":"saved-marker","page":1,"kind":"highlighter",
                "data":["inkVersion":4,"points":[["x":0.2,"y":0.7,"p":0.5],["x":0.7,"y":0.7,"p":0.5]]],
                "style":["color":"yellow","width":0.03,"opacity":0.3]]]
            surface.onFailure = { [weak self] in self?.errors.append($0) }
            surface.onDiagnostic = { [weak self] in self?.diagnostics.append($0) }
            surface.onStroke = { [weak self] stroke in
                guard let self else { return }; self.saved.append(stroke)
                let points = stroke.points.map { p -> [String: Any] in
                    var point: [String: Any] = ["x":p.x,"y":p.y,"p":p.p]
                    if let t = p.t { point["t"] = t }; if let v = p.tiltX { point["tiltX"] = v }; if let v = p.tiltY { point["tiltY"] = v }
                    return point
                }
                self.rows.append(["id":stroke.mutationID,"clientMutationId":stroke.mutationID,"page":1,"kind":stroke.kind,
                    "data":["inkVersion":4,"points":points],
                    "style":["color":stroke.style.color,"width":stroke.style.width,"opacity":stroke.style.opacity]])
                self.applyRows()
            }
            applyRows()
            window.rootViewController!.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
            try await NativePDFRetainedPaperCropSurfaceTests.wait {
                (self.surface.inputDiagnostics["retainedInkInstalls"] as? Int ?? 0)>0 && self.surface.inputDiagnostics["frameRequested"] as? Bool == false
            }
        }
        func applyRows() {
            for index in rows.indices where rows[index]["_nativeInk"] == nil {
                guard let prepared = NativePDFObjectRenderer.prepareInk(rows[index],aspect: size.height/size.width) else {
                    XCTFail("Valid fixture ink must prepare"); return
                }
                rows[index]["_nativeInk"] = prepared
            }
            surface.applyObjects(objects: rows,visualTokens: rows.map(NativePDFCommittedVisualToken.init))
        }
        func zoom(origin: CGPoint = CGPoint(x: 30,y: 40)) {
            let base = InkCoordinateMapper.whiteboard(size: size)
            let displayToCanonical = CGAffineTransform(a: 0.25,b: 0,c: 0,d: 0.25,tx: origin.x,ty: origin.y)
            surface.mapper = InkCoordinateMapper(canvasToPDF: displayToCanonical.concatenating(base.canvasToPDF),geometry: base.geometry)
        }
        func close() { surface.onStroke = nil; surface.onFailure = nil; surface.onDiagnostic = nil; surface.removeFromSuperview(); Task { await gate.cancelAll() }; window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
    }
    @MainActor private final class LocalTouch: UITouch {
        var point: CGPoint, time = CACurrentMediaTime()
        init(point: CGPoint) { self.point = point; super.init() }
        override var type: UITouch.TouchType { .pencil }
        override var timestamp: TimeInterval { time }
        override var force: CGFloat { 0.5 }
        override var maximumPossibleForce: CGFloat { 1 }
        override var altitudeAngle: CGFloat { .pi/2 }
        override func location(in view: UIView?) -> CGPoint { point }
        override func preciseLocation(in view: UIView?) -> CGPoint { point }
        override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
    }
}
