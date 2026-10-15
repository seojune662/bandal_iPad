import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Baseline for already-resolved eraser edits. Real Surface + real bounded
/// raster worker; no held completions, artificial sleep, or timing pass limit.
/// This deliberately excludes JS hit testing, its bridge, and physical display.
@MainActor
final class NativePDFErasureLatencyTests: XCTestCase {
    private typealias Base = NativePDFAsynchronousEditTests

    func testTenStationaryDeletionsMeasureRealCropWorkerAndVisibleImageInstallation() async throws {
        let f = try await Fixture.make()
        defer { f.close() }
        try await require(timeout: 20) { f.settled }
        let initialFull = f.integer("sceneFullRenders")
        XCTAssertEqual(initialFull, 1)
        XCTAssertEqual(f.recorder.worker.completedCount, 0)
        let viewport = try XCTUnwrap(f.surface.renderViewport)
        XCTAssertGreaterThan(viewport.pixelSize.width * viewport.pixelSize.height, 1_000_000,
                             "This baseline must cover a real full-iPad visible crop, not the small unit fixture")
        let originalRows = f.rows
        let deletedIDs = (84..<94).map { "latency-\($0)" }
        for (index, id) in deletedIDs.enumerated() {
            let at = try XCTUnwrap(f.rows.firstIndex { $0["id"] as? String == id })
            f.rows.remove(at: at); f.tokens.remove(at: at)
            let sample = Sample(index: index, deletedID: id, expectedCount: f.rows.count,
                                previousImage: try XCTUnwrap(f.image.image))
            f.recorder.active = sample; f.recorder.samples.append(sample)
            sample.startedAt = CACurrentMediaTime()
            f.surface.applyObjects(objects: f.rows, visualTokens: f.tokens)
            sample.applyReturnedAt = CACurrentMediaTime()
            try await require(timeout: 20) { sample.installedAt != nil && f.settled }
            XCTAssertFalse(sample.requests.isEmpty)
            XCTAssertTrue(sample.requests.allSatisfy { $0.progressiveAtEnqueue }, "Each settled deletion must use protected erasure")
            XCTAssertTrue(sample.requests.contains { $0.completedAt != nil && $0.succeeded })
            XCTAssertNotNil(sample.installedAt)
            XCTAssertTrue(f.image.image !== sample.previousImage)
            XCTAssertEqual(f.integer("sceneFullRenders"), initialFull, "No deletion may replay the full page on MainActor")
            XCTAssertEqual(f.integer("asynchronousEditTileInstalls"), 0, "Deletion must not expose an empty replacement tile layer")
            XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, f.rows.compactMap { $0["id"] as? String })
            f.recorder.active = nil
        }
        XCTAssertEqual(f.rows.count, 190)
        XCTAssertEqual(f.inputWrites, 0)
        XCTAssertEqual(f.integer("sceneFullRenders"), initialFull)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, false)
        // Deleting rows must not rewrite surviving raw samples or reorder them.
        let expected = originalRows.filter { !deletedIDs.contains($0["id"] as? String ?? "") }
        XCTAssertEqual(f.rows.compactMap { $0["id"] as? String }, expected.compactMap { $0["id"] as? String })
        for (actual, original) in zip(f.surface.objects, expected) {
            let a = try XCTUnwrap((actual["data"] as? [String: Any])?["points"] as? [[String: Double]])
            let b = try XCTUnwrap((original["data"] as? [String: Any])?["points"] as? [[String: Double]])
            XCTAssertEqual(a.count, 96); XCTAssertEqual(a.count, b.count)
            for (left, right) in zip(a, b) {
                XCTAssertEqual(Set(left.keys), Set(right.keys))
                for key in right.keys { XCTAssertEqual(left[key]?.bitPattern, right[key]?.bitPattern) }
            }
        }
        try assertFinalPixels(f)

        // Separate off-main direct replay controls use the identical immutable
        // paper/crop. Their difference is descriptive, not subtraction proof of
        // isolated ink cost; allocation and graphics caches can differ.
        let request = try XCTUnwrap(f.recorder.lastRequest)
        let controls = await Task.detached(priority: .userInitiated) {
            let paperOnly = NativePDFNavigationSnapshot(paper: request.snapshot.paper,
                highlights: [], objects: [], revision: request.snapshot.revision)
            return autoreleasepool { () -> [String: Double] in
                let startPaper = CACurrentMediaTime()
                let paper = paperOnly.raster(bounds: request.bounds, scale: request.scale,
                    canonicalToCanvas: request.transform, stablePrefixCount: 0)
                let paperMS = (CACurrentMediaTime() - startPaper) * 1000
                let startFull = CACurrentMediaTime()
                let full = request.snapshot.raster(bounds: request.bounds, scale: request.scale,
                    canonicalToCanvas: request.transform, stablePrefixCount: request.stablePrefixCount)
                return ["paperOnlyMS": paperMS, "full190RowsMS": (CACurrentMediaTime() - startFull) * 1000,
                        "paperSucceeded": paper == nil ? 0 : 1, "fullSucceeded": full == nil ? 0 : 1]
            }
        }.value
        XCTAssertEqual(controls["paperSucceeded"], 1); XCTAssertEqual(controls["fullSucceeded"], 1)
        let records = f.recorder.samples.map(\.json)
        let metrics = ["applyCallMS", "applyToEnqueueMS", "enqueueToCompletionMS", "completionToInstallMS", "applyToInstallMS"]
        var distributions: [String: Any] = [:]
        for key in metrics {
            let values = records.compactMap { $0[key] as? Double }
            distributions[key] = summary(values)
        }
        let payload: [String: Any] = [
            "scope": "Surface.applyObjects with immutable prepared rows -> real NativePDFNavigationRasterizer completion -> onSceneInstalled; no JS/bridge/physical-presentation timing",
            "fixture": ["initialRows": 200, "pointsPerRow": 96, "deletions": 10,
                        "canvasWidth": f.size.width, "canvasHeight": f.size.height,
                        "cropX": viewport.canvasRect.minX, "cropY": viewport.canvasRect.minY,
                        "cropWidth": viewport.canvasRect.width, "cropHeight": viewport.canvasRect.height,
                        "pixelWidth": viewport.pixelSize.width, "pixelHeight": viewport.pixelSize.height,
                        "pixelScale": viewport.pixelScale],
            "samples": records, "distributions": distributions, "directOffMainControls": controls,
            "workerCompletedCount": f.recorder.worker.completedCount,
            "fullRenderGrowth": f.integer("sceneFullRenders") - initialFull, "inputWrites": f.inputWrites,
            "limits": ["enqueueToCompletion combines worker queue, raster, and MainActor callback delivery; worker-start is not separately observable without a product seam",
                       "onSceneInstalled is the successful synchronized UIImage/Metal install, not physical display presentation",
                       "sequential stationary edits intentionally await each prior scene; this does not measure continuous-drag queue saturation",
                       "synthetic PDF with 200 grid strokes; no real document complexity or shared-host load attribution"]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "ERASURE-LATENCY-STAGES.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("[ERASURE_LATENCY] " + String(decoding: try JSONSerialization.data(withJSONObject: distributions, options: [.sortedKeys]), as: UTF8.self))
    }

    @MainActor private final class RequestSample {
        let enqueuedAt = CACurrentMediaTime()
        let revision: UInt64, objectCount: Int, progressiveAtEnqueue: Bool
        var completedAt: CFTimeInterval?, succeeded = false
        init(_ request: NativePDFNavigationRasterizer.Request, progressive: Bool) {
            revision = request.snapshot.revision; objectCount = request.snapshot.objects.count
            progressiveAtEnqueue = progressive
        }
    }
    @MainActor private final class Sample {
        let index: Int, deletedID: String, expectedCount: Int, previousImage: UIImage
        var startedAt: CFTimeInterval = 0, applyReturnedAt: CFTimeInterval = 0, installedAt: CFTimeInterval?
        var requests: [RequestSample] = []
        init(index: Int, deletedID: String, expectedCount: Int, previousImage: UIImage) {
            self.index = index; self.deletedID = deletedID; self.expectedCount = expectedCount; self.previousImage = previousImage
        }
        var json: [String: Any] {
            var result: [String: Any] = ["index": index, "deletedID": deletedID, "remainingRows": expectedCount,
                "applyCallMS": (applyReturnedAt-startedAt)*1000, "requestCount": requests.count]
            if let first = requests.first { result["applyToEnqueueMS"] = (first.enqueuedAt-startedAt)*1000 }
            if let completed = requests.first(where: { $0.completedAt != nil && $0.succeeded }), let end = completed.completedAt {
                result["enqueueToCompletionMS"] = (end-completed.enqueuedAt)*1000
                if let installedAt { result["completionToInstallMS"] = (installedAt-end)*1000 }
            }
            if let installedAt { result["applyToInstallMS"] = (installedAt-startedAt)*1000 }
            result["requests"] = requests.map { request -> [String: Any] in
                var row: [String: Any] = ["revision": request.revision, "rows": request.objectCount,
                    "enqueueFromApplyMS": (request.enqueuedAt-startedAt)*1000,
                    "progressiveAtEnqueue": request.progressiveAtEnqueue, "succeeded": request.succeeded]
                if let end = request.completedAt { row["completionFromApplyMS"] = (end-startedAt)*1000 }
                return row
            }
            return result
        }
    }
    @MainActor private final class Recorder {
        let worker = NativePDFNavigationRasterizer()
        weak var surface: NativePDFInkSurface?
        weak var image: UIImageView?
        var active: Sample?, samples: [Sample] = []
        var lastRequest: NativePDFNavigationRasterizer.Request?
        func enqueue(_ request: NativePDFNavigationRasterizer.Request) {
            let record = RequestSample(request, progressive: surface?.inputDiagnostics["progressiveErasureActive"] as? Bool == true)
            if let active, active.expectedCount == request.snapshot.objects.count { active.requests.append(record) }
            lastRequest = request
            worker.request(.init(snapshot: request.snapshot, bounds: request.bounds, scale: request.scale,
                transform: request.transform, stablePrefixCount: request.stablePrefixCount) { result in
                    record.completedAt = CACurrentMediaTime(); record.succeeded = result != nil
                    request.completion(result)
                })
        }
        func installed() {
            guard let active, active.installedAt == nil, let surface, let image,
                  !image.isHidden, image.image !== active.previousImage,
                  surface.inputDiagnostics["navigationBaseObjects"] as? Int == active.expectedCount else { return }
            active.installedAt = CACurrentMediaTime()
        }
    }
    @MainActor private final class Fixture {
        let window: UIWindow, previous: UIWindow?, size: CGSize, document: PDFDocument, page: PDFPage
        let surface: NativePDFInkSurface, image: UIImageView, metal: NativePDFMetalInk, recorder: Recorder
        var rows: [[String: Any]], tokens: [NativePDFCommittedVisualToken], inputWrites = 0
        static func make() async throws -> Fixture {
            Base.assertTrue(await Base.poll(timeout: 3) {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            return try Fixture(scene)
        }
        init(_ scene: UIWindowScene) throws {
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
            window.layoutIfNeeded(); size = window.bounds.size
            XCTAssertGreaterThan(size.width, 600); XCTAssertGreaterThan(size.height, 600)
            let bounds = CGRect(origin: .zero, size: size)
            let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage(); context.cgContext.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
                context.cgContext.fill(CGRect(x: 31, y: 47, width: 181, height: 137))
            }
            document = try XCTUnwrap(PDFDocument(data: pdf)); page = try XCTUnwrap(document.page(at: 0))
            rows = NativePDFErasureLatencyTests.rows()
            for index in rows.indices { rows[index]["_nativeInk"] = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(rows[index], aspect: size.height/size.width)) }
            tokens = rows.map(NativePDFCommittedVisualToken.init)
            let observer = Recorder(); recorder = observer
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: bounds,
                navigationRasterRequest: { [weak observer] in observer?.enqueue($0) }))
            image = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
            observer.surface = surface; observer.image = image
            surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.tool = .init(name: "eraser", style: .init(color: "blue", width: 0.008, opacity: 1))
            surface.onSceneInstalled = { [weak observer] in observer?.installed() }
            surface.onStroke = { [weak self] _ in self?.inputWrites += 1; XCTFail("No Pencil writes belong to this deletion fixture") }
            surface.onCheckpoint = { [weak self] _ in self?.inputWrites += 1; XCTFail("No Pencil checkpoints belong to this deletion fixture") }
            surface.onFailure = { XCTFail("Unexpected Surface failure: \($0)") }
            surface.applyObjects(objects: rows, visualTokens: tokens)
            window.rootViewController!.view.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        var settled: Bool {
            image.image != nil && !image.isHidden && metal.strokes.isEmpty &&
                surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                surface.inputDiagnostics["asynchronousEditDisplayActive"] as? Bool == false &&
                surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        func integer(_ key: String) -> Int { surface.inputDiagnostics[key] as? Int ?? -1 }
        func close() {
            surface.onSceneInstalled = nil; surface.onFailure = nil; surface.onStroke = nil; surface.onCheckpoint = nil
            recorder.active = nil; recorder.worker.cancel(); recorder.lastRequest = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
    }
    private static func rows() -> [[String: Any]] {
        (0..<200).map { index in
            let column = Double(index % 8), row = Double(index / 8)
            let points: [[String: Double]] = (0..<96).map { point in
                let t = Double(point)/95
                return ["x": 0.02 + column*0.12 + t*0.095,
                        "y": 0.035 + row*0.037 + sin(t*Double.pi*4)*0.008,
                        "p": 0.2 + t*0.6, "t": Double(point)*4]
            }
            let marker = index.isMultiple(of: 7)
            let data: [String: Any] = ["inkVersion": 4, "points": points]
            let style: [String: Any] = ["color": marker ? "yellow" : "blue",
                                       "width": marker ? 0.012 : 0.0025, "opacity": marker ? 0.24 : 0.45]
            return ["id": "latency-\(index)", "clientMutationId": "latency-\(index)", "page": 1,
                    "kind": marker ? "highlighter" : "ink", "data": data, "style": style]
        }
    }
    private func assertFinalPixels(_ f: Fixture) throws {
        let viewport = try XCTUnwrap(f.surface.renderViewport), mapper = try XCTUnwrap(f.surface.mapper)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in f.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
        let actual = try XCTUnwrap(f.image.image?.cgImage)
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertTrue(try Base.pixels(actual) == Base.pixels(expected), "Final independent PDF + ordered objects RGBA must remain exact")
    }
    private func require(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async throws {
        let passed = await Base.poll(timeout: timeout, condition)
        XCTAssertTrue(passed, "Stationary erasure scene did not settle")
        guard passed else { throw Failure.timeout }
    }
    private func summary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        return ["count": values.count, "mean": values.reduce(0,+)/Double(values.count),
                "min": sorted[0], "median": sorted[sorted.count/2], "p95": sorted[min(sorted.count-1, Int(ceil(Double(sorted.count)*0.95))-1)],
                "max": sorted[sorted.count-1]]
    }
    private enum Failure: Error { case timeout }
}
