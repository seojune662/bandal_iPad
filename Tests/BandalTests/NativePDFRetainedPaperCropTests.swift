import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFRetainedPaperCropTests: XCTestCase {
    private typealias Crop = NativePDFRetainedPaperCrop

    func testFractionalCropUsesOutwardPhysicalGridAndBoundedActualImageSize() async throws {
        let snapshot = try snapshot(), gate = Gate()
        let crop = Crop(rasterize: { await gate.capture($0) })
        let query = CGRect(x: 10.13, y: 11.27, width: 70.31, height: 60.43), scale: CGFloat = 2.9411765056892487
        crop.update(snapshot: snapshot, bounds: query, scale: scale)
        try await wait { await gate.count == 1 }
        let request = await gate.request(0)
        XCTAssertEqual(request.pixelOrigin.x, floor(query.minX*scale))
        XCTAssertEqual(request.pixelOrigin.y, floor(query.minY*scale))
        XCTAssertEqual(request.pixelWidth, Int(ceil(query.maxX*scale)-floor(query.minX*scale)))
        XCTAssertEqual(request.pixelHeight, Int(ceil(query.maxY*scale)-floor(query.minY*scale)))
        let image = try render(request)
        XCTAssertEqual(image.image.width, request.pixelWidth); XCTAssertEqual(image.image.height, request.pixelHeight)
        await gate.finish(0, result: image)
        try await wait { crop.presentation(for: snapshot, bounds: query, scale: scale) != nil }
        let shown = try XCTUnwrap(crop.presentation(for: snapshot, bounds: query, scale: scale))
        XCTAssertTrue(shown.image === image.image)
        XCTAssertEqual(shown.bounds.width, CGFloat(shown.image.width)/scale)
        XCTAssertEqual(shown.bounds.height, CGFloat(shown.image.height)/scale)
        XCTAssertEqual(shown.bounds.origin, request.bounds.origin)

        let large = try self.snapshot(size: CGSize(width: 4000, height: 5000))
        for bounds in [CGRect(x: 0,y: 0,width: 3000,height: 3000), CGRect(x: 0.125,y: 0.375,width: 3999.5,height: 600),
                       CGRect(x: -100,y: -90,width: 4200,height: 5200)] {
            let capped = try XCTUnwrap(Crop.request(snapshot: large, bounds: bounds, scale: 20))
            XCTAssertLessThanOrEqual(capped.pixelWidth, 4096); XCTAssertLessThanOrEqual(capped.pixelHeight, 4096)
            XCTAssertLessThanOrEqual(capped.pixelWidth*capped.pixelHeight, 8_020_000)
            XCTAssertEqual(Int(ceil(capped.bounds.width*capped.scale)), capped.pixelWidth)
            XCTAssertEqual(Int(ceil(capped.bounds.height*capped.scale)), capped.pixelHeight)
        }
    }

    func testRapidViewportUpdatesDebounceToLatestPaperOnlyRequest() async throws {
        let snapshot = try snapshot(), gate = Gate(), crop = Crop(rasterize: { await gate.capture($0) })
        var latest = CGRect.zero
        for index in 0..<30 {
            latest = CGRect(x: 10+index*3,y: 20,width: 60,height: 70)
            crop.update(snapshot: snapshot, bounds: latest, scale: 3)
        }
        let immediateCount = await gate.count
        XCTAssertEqual(immediateCount, 0, "A viewport update never begins CG work synchronously")
        try await wait { await gate.count == 1 }
        let request = await gate.request(0)
        XCTAssertTrue(request.snapshot === snapshot); XCTAssertTrue(request.snapshot.objects.isEmpty)
        XCTAssertEqual(request.pixelOrigin.x, floor(latest.minX*3))
        await gate.finish(0, result: try render(request))
        try await wait { crop.presentation(for: snapshot, bounds: latest, scale: 3) != nil }
        XCTAssertEqual(crop.rasterCount, 1)
        XCTAssertNil(crop.presentation(for: snapshot, bounds: CGRect(x: 0,y: 0,width: 50,height: 50), scale: 3))
    }

    func testSlowSupersededCompletionAndResetCannotInstallOldViewport() async throws {
        let snapshot = try snapshot(), gate = Gate(), crop = Crop(rasterize: { await gate.capture($0) })
        let a = CGRect(x: 0,y: 0,width: 60,height: 80), b = CGRect(x: 70,y: 0,width: 60,height: 80)
        let c = CGRect(x: 140,y: 30,width: 60,height: 80)
        var ready = 0; crop.onReady = { ready += 1 }
        crop.update(snapshot: snapshot, bounds: a, scale: 2)
        try await wait { await gate.count == 1 }
        crop.update(snapshot: snapshot, bounds: b, scale: 2)
        crop.update(snapshot: snapshot, bounds: c, scale: 2)
        try await Task.sleep(nanoseconds: 120_000_000)
        let stillOne = await gate.count
        XCTAssertEqual(stillOne, 1, "A canceled detached raster is still occupying the only worker slot")
        await gate.finish(0, result: try render(await gate.request(0)))
        try await wait { await gate.count == 2 }
        XCTAssertEqual(ready, 0); XCTAssertNil(crop.presentation(for: snapshot, bounds: a, scale: 2))
        let newestRequest = await gate.request(1)
        XCTAssertEqual(newestRequest.pixelOrigin.x, floor(c.minX*2))
        crop.reset()
        await gate.finish(1, result: try render(await gate.request(1)))
        await Task.yield()
        XCTAssertEqual(ready, 0); XCTAssertEqual(crop.rasterCount, 0)
        XCTAssertNil(crop.presentation(for: snapshot, bounds: c, scale: 2))
        crop.update(snapshot: snapshot, bounds: a, scale: 2)
        try await wait { await gate.count == 3 }
        await gate.finish(2, result: try render(await gate.request(2)))
        try await wait { ready == 1 }
    }

    func testReversePanKeepsCoveredAcceptedCropAndRejectsLateOutsideResult() async throws {
        let snapshot = try snapshot(), gate = Gate(), crop = Crop(rasterize: { await gate.capture($0) })
        let a = CGRect(x: 0,y: 0,width: 120,height: 140), b = CGRect(x: 160,y: 0,width: 60,height: 70)
        crop.update(snapshot: snapshot, bounds: a, scale: 3)
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: try render(await gate.request(0)))
        try await wait { crop.presentation(for: snapshot, bounds: a, scale: 3) != nil }
        let accepted = try XCTUnwrap(crop.presentation(for: snapshot, bounds: a, scale: 3)).image
        crop.update(snapshot: snapshot, bounds: b, scale: 3)
        XCTAssertNil(crop.presentation(for: snapshot, bounds: b, scale: 3))
        try await wait { await gate.count == 2 }
        let inside = CGRect(x: 20,y: 20,width: 50,height: 60)
        crop.update(snapshot: snapshot, bounds: inside, scale: 2)
        XCTAssertTrue(crop.presentation(for: snapshot, bounds: inside, scale: 2)?.image === accepted)
        await gate.finish(1, result: try render(await gate.request(1)))
        await Task.yield()
        XCTAssertTrue(crop.presentation(for: snapshot, bounds: inside, scale: 2)?.image === accepted)
        XCTAssertNil(crop.presentation(for: snapshot, bounds: b, scale: 3))
        XCTAssertEqual(crop.rasterCount, 1)
    }

    func testInsufficientDensityAndNewSnapshotNeverBorrowOldPresentation() async throws {
        let first = try snapshot(), second = try snapshot(marked: true), gate = Gate()
        let crop = Crop(rasterize: { await gate.capture($0) }), bounds = CGRect(x: 20,y: 30,width: 80,height: 100)
        crop.update(snapshot: first, bounds: bounds, scale: 1)
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: try render(await gate.request(0)))
        try await wait { crop.presentation(for: first, bounds: bounds, scale: 1) != nil }
        XCTAssertNil(crop.presentation(for: first, bounds: bounds, scale: 2))
        crop.update(snapshot: first, bounds: bounds, scale: 2)
        try await wait { await gate.count == 2 }
        crop.update(snapshot: second, bounds: bounds, scale: 2)
        await gate.finish(1, result: try render(await gate.request(1)))
        try await wait { await gate.count == 3 }
        XCTAssertNil(crop.presentation(for: second, bounds: bounds, scale: 1))
        await gate.finish(2, result: try render(await gate.request(2)))
        try await wait { crop.presentation(for: second, bounds: bounds, scale: 2) != nil }
        XCTAssertNil(crop.presentation(for: first, bounds: bounds, scale: 1))
    }

    func testFailuresAreBoundedAndInkSnapshotsNeverEnterTheWorker() async throws {
        let snapshot = try snapshot(), gate = Gate(), crop = Crop(rasterize: { await gate.capture($0) })
        let bounds = CGRect(x: 10,y: 20,width: 70,height: 80)
        var failures = 0; crop.onFailure = { _ in failures += 1 }
        crop.update(snapshot: snapshot, bounds: bounds, scale: 2)
        for index in 0..<3 {
            try await wait { await gate.count == index+1 }
            await gate.finish(index, result: nil)
        }
        try await wait { failures == 1 }
        for _ in 0..<100 { crop.update(snapshot: snapshot, bounds: bounds, scale: 2) }
        try await Task.sleep(nanoseconds: 260_000_000)
        let exhaustedCount = await gate.count
        XCTAssertEqual(exhaustedCount, 3); XCTAssertNil(crop.presentation(for: snapshot, bounds: bounds, scale: 2))
        let path = CGPath(rect: CGRect(x: 20,y: 20,width: 40,height: 50), transform: nil)
        let ink = NativePDFNavigationSnapshot.Command(bounds: path.boundingBoxOfPath,
            content: .path(path, UIColor.blue.cgColor, 0.5, false))
        let mixed = NativePDFNavigationSnapshot(paper: snapshot.paper, highlights: snapshot.highlights, objects: [ink], revision: snapshot.revision+1)
        XCTAssertNil(Crop.request(snapshot: mixed, bounds: bounds, scale: 2))
        crop.update(snapshot: mixed, bounds: bounds, scale: 2)
        XCTAssertNil(crop.presentation(for: mixed, bounds: bounds, scale: 2))
        crop.update(snapshot: snapshot, bounds: bounds.offsetBy(dx: 3,dy: 0), scale: 2)
        try await wait { await gate.count == 4 }
        await gate.finish(3, result: try render(await gate.request(3)))
        try await wait { crop.rasterCount == 1 }
        XCTAssertEqual(failures, 1)
        for invalid in [CGRect.zero, CGRect(x: 1000,y: 1000,width: 10,height: 10)] {
            XCTAssertNil(Crop.request(snapshot: snapshot, bounds: invalid, scale: 2))
        }
        XCTAssertNil(Crop.request(snapshot: snapshot, bounds: bounds, scale: CGFloat.infinity))
    }

    private func snapshot(size: CGSize = CGSize(width: 240,height: 320), marked: Bool = false) throws -> NativePDFNavigationSnapshot {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero,size: size)).pdfData { renderer in
            renderer.beginPage()
            if marked { UIColor.gray.setFill(); renderer.cgContext.fill(CGRect(x: 40,y: 50,width: 40,height: 30)) }
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let highlight: [String: Any] = ["rects": [["x": 0.1,"y": 0.2,"width": 0.2,"height": 0.1]], "color": "yellow", "nativeOpacity": 0.3]
        return try XCTUnwrap(NativePDFNavigationSnapshotBuilder().make(page: page, objects: [], tokens: [], highlights: [highlight], image: { _ in nil }))
    }
    private func render(_ request: Crop.Request) throws -> NativePDFNavigationSnapshot.Raster {
        try XCTUnwrap(request.snapshot.raster(bounds: request.bounds, scale: request.scale, canonicalToCanvas: .identity))
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime()+3
        while !(await predicate()), CACurrentMediaTime()<deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard await predicate() else { XCTFail("Paper crop lifecycle timed out"); throw NSError(domain: "PaperCropTest",code: 1) }
    }
    private actor Gate {
        struct Pending { let request: Crop.Request; let continuation: CheckedContinuation<NativePDFNavigationSnapshot.Raster?,Never> }
        private var requests: [Pending] = []
        var count: Int { requests.count }
        func request(_ index: Int) -> Crop.Request { requests[index].request }
        func capture(_ request: Crop.Request) async -> NativePDFNavigationSnapshot.Raster? {
            await withCheckedContinuation { requests.append(Pending(request: request, continuation: $0)) }
        }
        func finish(_ index: Int, result: NativePDFNavigationSnapshot.Raster?) { requests[index].continuation.resume(returning: result) }
    }
}
