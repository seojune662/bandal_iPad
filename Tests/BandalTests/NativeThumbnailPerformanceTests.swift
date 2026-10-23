import XCTest
import PDFKit
@testable import Bandal

@MainActor
final class NativeThumbnailPerformanceTests: XCTestCase {
    func testDocumentScopedMutationKeepsUnrelatedPreviewCacheKeys() {
        var revisions = NativeLibraryThumbnailRevisions()
        let documents: [(course: String, path: String, affected: Bool)] = [
            ("course-a", "paper.pdf", true), ("course-a", "other.pdf", false),
            ("course-a", "notes/one.pdf", true), ("course-a", "notes/deep/two.pdf", true),
            ("course-a", "notes-copy/three.pdf", false), ("course-b", "paper.pdf", false)
        ]
        let before = documents.map { revisions.key(root: "workspace", course: $0.course, path: $0.path) }
        let payload: [String: Any] = ["changedCourseIDs": ["course-a", "course-b"], "changedDocuments": [
            ["courseId": "course-a", "relPath": "paper.pdf"],
            ["courseId": "course-a", "relPath": "notes", "isDirectory": true]
        ]]
        revisions.receive(NativeWorkspaceEvent(channel: "nativeWorkspace:externalMutationFinished", payload: payload), root: "workspace")
        for (index, document) in documents.enumerated() {
            let after = revisions.key(root: "workspace", course: document.course, path: document.path)
            XCTAssertEqual(before[index] != after, document.affected, "The narrower document scope must win over the course scope")
            XCTAssertEqual(NativeLibraryThumbnailRevisions.affects(payload, course: document.course, path: document.path), document.affected,
                           "Visible cards and offscreen cached cards must agree about which previews need a reload")
        }
    }

    func testCourseAndGlobalThumbnailInvalidationStayWithinWorkspace() {
        var revisions = NativeLibraryThumbnailRevisions()
        let a = revisions.key(root: "workspace", course: "a", path: "paper.pdf")
        let b = revisions.key(root: "workspace", course: "b", path: "paper.pdf")
        let otherRoot = revisions.key(root: "other-workspace", course: "a", path: "paper.pdf")
        revisions.receive(NativeWorkspaceEvent(channel: "nativeWorkspace:externalMutationFinished", payload: ["changedCourseIDs": ["a"]]), root: "workspace")
        let changedA = revisions.key(root: "workspace", course: "a", path: "paper.pdf")
        XCTAssertNotEqual(a, changedA)
        XCTAssertEqual(b, revisions.key(root: "workspace", course: "b", path: "paper.pdf"))
        XCTAssertEqual(otherRoot, revisions.key(root: "other-workspace", course: "a", path: "paper.pdf"))
        let noChange: [String: Any] = ["changedDocuments": [[String: Any]](), "changedCourseIDs": ["a"]]
        revisions.receive(NativeWorkspaceEvent(channel: "nativeWorkspace:externalMutationFinished", payload: noChange), root: "workspace")
        XCTAssertEqual(changedA, revisions.key(root: "workspace", course: "a", path: "paper.pdf"), "An explicitly empty document scope must not invalidate the whole course")
        revisions.receive(NativeWorkspaceEvent(channel: "nativeWorkspace:externalMutationFinished", payload: [:]), root: "workspace")
        XCTAssertNotEqual(changedA, revisions.key(root: "workspace", course: "a", path: "paper.pdf"))
        XCTAssertNotEqual(b, revisions.key(root: "workspace", course: "b", path: "paper.pdf"))
        XCTAssertEqual(otherRoot, revisions.key(root: "other-workspace", course: "a", path: "paper.pdf"))
    }

    func testConcurrentConsumersShareOneLoadAndWarmHitsDoNoWork() async throws {
        let cache = NativeThumbnailImageCache(bytes: 1024 * 1024, count: 10)
        let bitmap = Self.bitmap()
        var loads = 0
        let consumers = (0..<32).map { _ in
            Task { await cache.image(key: "same-page") {
                loads += 1
                try? await Task.sleep(for: .milliseconds(30))
                return bitmap
            } }
        }
        for task in consumers { let image = await task.value; XCTAssertTrue(image === bitmap) }
        for _ in 0..<20 {
            let reused = await cache.image(key: "same-page") { loads += 1; return Self.bitmap() }
            XCTAssertTrue(reused === bitmap)
        }
        XCTAssertEqual(loads, 1, "A cache hit must happen before any database query, fingerprint, or rasterization")
        XCTAssertEqual(cache.pendingCount, 0)
    }

    func testCancellingOneConsumerKeepsTheOtherAndCancellingLastReleasesProducer() async throws {
        let cache = NativeThumbnailImageCache(bytes: 1024 * 1024, count: 10)
        let bitmap = Self.bitmap()
        let started = expectation(description: "shared producer started")
        let survivor = Task { await cache.image(key: "shared") {
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(60))
            return bitmap
        } }
        await fulfillment(of: [started], timeout: 2)
        let disappearing = Task { await cache.image(key: "shared") { XCTFail("Must reuse the running producer"); return nil } }
        await Task.yield()
        disappearing.cancel()
        let cancelledImage = await disappearing.value
        XCTAssertNil(cancelledImage)
        let survivingImage = await survivor.value
        XCTAssertTrue(survivingImage === bitmap)
        let cancelled = expectation(description: "last consumer cancels producer")
        let pending = Task { await cache.image(key: "offscreen") {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { cancelled.fulfill() }
            return nil
        } }
        while cache.pendingCount == 0 { await Task.yield() }
        await Task.yield()
        pending.cancel()
        let offscreenImage = await pending.value
        XCTAssertNil(offscreenImage)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(cache.pendingCount, 0)
    }

    func testCancelledQueuedRasterNeverDecodesAndMainActorRemainsAvailable() async throws {
        let queue = NativeThumbnailWorkQueue(name: "thumbnail-cancellation-test")
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "worker holds its only slot")
        let bitmap = NativeThumbnailWorkQueue.ImageBox(Self.bitmap())
        let first = Task { await queue.image {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return bitmap.image
        } }
        defer { gate.signal() }
        await fulfillment(of: [started], timeout: 2)
        let offscreen = Task { await queue.image { XCTFail("Cancelled queued work must not open or decode its PDF"); return bitmap.image } }
        await Task.yield()
        offscreen.cancel()
        let cancelledImage = await offscreen.value
        XCTAssertNil(cancelledImage, "Cancelling a cell must not wait behind another PDF render")
        XCTAssertTrue(Thread.isMainThread, "The main actor stays available while the worker is blocked")
        gate.signal()
        let completed = await first.value
        XCTAssertNotNil(completed)
    }

    func testPageSourceCoalescesAndCachesCompositesByInkRevision() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePaper(root.appendingPathComponent("PDFOriginals/revision.pdf"))
        let source = NativePDFPageThumbnailSource(root: root, revision: "revision")
        let rows = [Self.shape(color: "blue")]
        async let first = source.image(page: 1, rows: rows, inkRevision: 1)
        async let second = source.image(page: 1, rows: rows, inkRevision: 1)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "Concurrent consumers must share the final composed bitmap")
        let next = await source.image(page: 1, rows: [Self.shape(color: "red")], inkRevision: 2)
        XCTAssertNotEqual(a?.pngData(), next?.pngData(), "A same-ID style edit must invalidate the composite")
        let warm = await source.image(page: 1, rows: [Self.shape(color: "red")], inkRevision: 2)
        XCTAssertTrue(warm === next)
        let original = await source.image(page: 1)
        XCTAssertNotEqual(next?.pngData(), original?.pngData())
    }

    func testWorkerObjectRendererMatchesMainRendererWithoutSharingInkCache() async throws {
        let base = Self.bitmap(size: CGSize(width: 240, height: 320))
        let rows = [Self.shape(color: "red"), Self.ink()]
        let expected = UIGraphicsImageRenderer(size: base.size, format: Self.format()).image { renderer in
            base.draw(at: .zero)
            let mapper = InkCoordinateMapper.whiteboard(size: base.size)
            for row in rows { NativePDFObjectRenderer.draw(row, in: renderer.cgContext, mapper: mapper, image: nil, compact: true) }
        }
        let input = NativeThumbnailCompositeInput(base: base, rows: rows)
        let queue = NativeThumbnailWorkQueue(name: "thumbnail-renderer-parity")
        let actual = await queue.image {
            XCTAssertFalse(Thread.isMainThread)
            return input.render()
        }
        XCTAssertEqual(actual?.image.pngData(), expected.pngData())
    }

    func testLocalPrivateDocumentThumbnailBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Local opt-in benchmark requires the existing private PDF replay fixture.")
        }
        let fixture = URL(fileURLWithPath: path, isDirectory: true)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("rows.json"))) as? [[String: Any]])
        let rows = raw.filter { ($0["page"] as? NSNumber)?.intValue == 1 }
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("PDFOriginals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let target = originals.appendingPathComponent("benchmark.pdf")
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("paper.pdf"), to: target)

        // Replay the previous synchronous thumbnail path as the local baseline.
        // Only aggregate timings/counts are printed; fixture bytes stay private.
        NativePDFObjectRenderer.releaseInkPaths()
        let legacyStart = CACurrentMediaTime()
        let page = try XCTUnwrap(PDFDocument(url: target)?.page(at: 0))
        let coordinates = NativePDFPageCoordinates(page: page)
        let base = page.thumbnail(of: CGSize(width: 260, height: min(520, max(64, 260 * coordinates.height / max(1, coordinates.width)))), for: .cropBox)
        let legacyRows = try rows.map { original -> [String: Any] in
            var row = original
            if ["ink", "highlighter"].contains(row["kind"] as? String ?? ""), (row["data"] as? [String: Any])?["inkVersion"] == nil {
                row["nativePath"] = try NativePDFLegacyInk.path(row, aspect: coordinates.height / coordinates.width)
            }
            return row
        }
        let legacy = UIGraphicsImageRenderer(size: base.size, format: Self.format()).image { renderer in
            base.draw(at: .zero)
            let mapper = InkCoordinateMapper.whiteboard(size: base.size)
            for row in legacyRows { NativePDFObjectRenderer.draw(row, in: renderer.cgContext, mapper: mapper, image: nil) }
        }
        let legacyMS = (CACurrentMediaTime() - legacyStart) * 1000
        XCTAssertNotNil(legacy.cgImage)
        let source = NativePDFPageThumbnailSource(root: root, revision: "benchmark")
        let coldStart = CACurrentMediaTime()
        let cold = await source.image(page: 1, rows: rows, inkRevision: 0)
        let coldMS = (CACurrentMediaTime() - coldStart) * 1000
        let warmStart = CACurrentMediaTime()
        for _ in 0..<20 { let warm = await source.image(page: 1, rows: rows, inkRevision: 0); XCTAssertTrue(warm === cold) }
        let warmMS = (CACurrentMediaTime() - warmStart) * 1000 / 20
        XCTAssertNotNil(cold)
        print(String(format: "[THUMBNAIL_BENCHMARK] rows=%d legacy_main_ms=%.3f worker_cold_ms=%.3f cached_mean_ms=%.3f", rows.count, legacyMS, coldMS, warmMS))
    }

    private static func shape(color: String) -> [String: Any] {
        ["id": "shape", "page": 1, "kind": "rect", "data": ["box": ["x": 0.2, "y": 0.2, "width": 0.5, "height": 0.4]], "style": ["color": color, "width": 0.02, "opacity": 1.0]]
    }
    private static func ink() -> [String: Any] {
        let points: [[String: Double]] = (0..<180).map { n in
            let position = Double(n)
            return ["x": 0.1 + position * 0.004, "y": 0.7 + sin(position * 0.1) * 0.1, "p": 0.5]
        }
        return ["id": "ink", "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": ["color": "blue", "width": 0.006, "opacity": 1.0]]
    }
    private static func bitmap(size: CGSize = CGSize(width: 40, height: 60)) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: format()).image { renderer in UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size)) }
    }
    private static func format() -> UIGraphicsImageRendererFormat { let value = UIGraphicsImageRendererFormat(); value.scale = 1; return value }
    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private static func writePaper(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 450)).writePDF(to: url) { renderer in renderer.beginPage() }
    }
}
