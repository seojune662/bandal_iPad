import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFRetainedPaperTests: XCTestCase {
    func testFirstFailureRetriesTheSameSnapshotAndPublishesOnlyRecoveredImage() async throws {
        let gate = Gate(), page = try page()
        let paper = NativePDFRetainedPaper(rasterize: { await gate.capture($0, scale: $1) })
        var ready = 0, failures = 0
        paper.onReady = { ready += 1 }; paper.onFailure = { _ in failures += 1 }
        paper.update(page: page, highlights: [])
        try await wait { await gate.count == 1 }
        await gate.finish(0, result: nil)
        for _ in 0..<20 { paper.update(page: page, highlights: []) }
        try await wait { await gate.count == 2 }
        let first = await gate.snapshot(0), retry = await gate.snapshot(1)
        XCTAssertTrue(first === retry)
        XCTAssertNil(paper.image); XCTAssertFalse(paper.ready)
        let image = try raster(retry)
        await gate.finish(1, result: image)
        try await wait { paper.ready }
        XCTAssertTrue(paper.image === image.image)
        XCTAssertEqual(paper.rasterCount, 1); XCTAssertEqual(ready, 1); XCTAssertEqual(failures, 0)
    }

    func testThreeFailuresStopUntilNewSnapshotAndPreserveLastAcceptedImage() async throws {
        let gate = Gate(), firstPage = try page(), secondPage = try page()
        let paper = NativePDFRetainedPaper(rasterize: { await gate.capture($0, scale: $1) })
        var failures = 0
        paper.onFailure = { _ in failures += 1 }
        paper.update(page: firstPage, highlights: [])
        try await wait { await gate.count == 1 }
        let previous = try raster(await gate.snapshot(0))
        await gate.finish(0, result: previous)
        try await wait { paper.ready }
        paper.update(page: secondPage, highlights: [])
        XCTAssertFalse(paper.ready); XCTAssertTrue(paper.image === previous.image)
        for index in 1...3 {
            try await wait { await gate.count == index + 1 }
            await gate.finish(index, result: nil)
        }
        try await wait { failures == 1 }
        for _ in 0..<100 { paper.update(page: secondPage, highlights: []) }
        // Even after the previous backoff interval, a terminal generation must
        // not spawn work merely because another input frame checks readiness.
        try await Task.sleep(nanoseconds: 260_000_000)
        let count = await gate.count
        XCTAssertEqual(count, 4); XCTAssertEqual(failures, 1)
        XCTAssertFalse(paper.ready); XCTAssertTrue(paper.image === previous.image)
        XCTAssertEqual(paper.rasterCount, 1)
        paper.update(page: try page(), highlights: [])
        try await wait { await gate.count == 5 }
        let next = try raster(await gate.snapshot(4))
        await gate.finish(4, result: next)
        try await wait { paper.ready }
        XCTAssertTrue(paper.image === next.image); XCTAssertEqual(paper.rasterCount, 2)
    }

    func testSupersededAndResetCompletionsCannotPublishAndOnlyNewestRequestRuns() async throws {
        let gate = Gate(), a = try page(), b = try page(), c = try page()
        let paper = NativePDFRetainedPaper(rasterize: { await gate.capture($0, scale: $1) })
        var ready = 0, failures = 0
        paper.onReady = { ready += 1 }; paper.onFailure = { _ in failures += 1 }
        paper.update(page: a, highlights: [])
        try await wait { await gate.count == 1 }
        let old = await gate.snapshot(0)
        paper.update(page: b, highlights: []); paper.update(page: c, highlights: [])
        await Task.yield()
        let pendingCount = await gate.count
        XCTAssertEqual(pendingCount, 1, "An in-flight raster must finish before the latest request starts")
        await gate.finish(0, result: try raster(old))
        try await wait { await gate.count == 2 }
        XCTAssertNil(paper.image); XCTAssertEqual(ready, 0); XCTAssertEqual(failures, 0)
        let latest = await gate.snapshot(1)
        XCTAssertFalse(latest === old)
        paper.reset(); paper.update(page: a, highlights: [])
        await gate.finish(1, result: nil)
        try await wait { await gate.count == 3 }
        XCTAssertNil(paper.image); XCTAssertFalse(paper.ready)
        let final = try raster(await gate.snapshot(2))
        await gate.finish(2, result: final)
        try await wait { paper.ready }
        XCTAssertTrue(paper.image === final.image)
        XCTAssertEqual(ready, 1); XCTAssertEqual(failures, 0); XCTAssertEqual(paper.rasterCount, 1)
    }

    private func page() throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 64, height: 96)).pdfData { $0.beginPage() }
        return try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
    }
    private func raster(_ snapshot: NativePDFNavigationSnapshot) throws -> NativePDFNavigationSnapshot.Raster {
        try XCTUnwrap(snapshot.raster(bounds: CGRect(origin: .zero, size: snapshot.size), scale: 1, canonicalToCanvas: .identity))
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 3
        while !(await predicate()), CACurrentMediaTime() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard await predicate() else { XCTFail("Timed out waiting for paper lifecycle"); throw NSError(domain: "RetainedPaperTest", code: 1) }
    }
    private actor Gate {
        struct Request { let snapshot: NativePDFNavigationSnapshot; let continuation: CheckedContinuation<NativePDFNavigationSnapshot.Raster?, Never> }
        private var requests: [Request] = []
        var count: Int { requests.count }
        func snapshot(_ index: Int) -> NativePDFNavigationSnapshot { requests[index].snapshot }
        func capture(_ snapshot: NativePDFNavigationSnapshot, scale: CGFloat) async -> NativePDFNavigationSnapshot.Raster? {
            await withCheckedContinuation { continuation in requests.append(Request(snapshot: snapshot, continuation: continuation)) }
        }
        func finish(_ index: Int, result: NativePDFNavigationSnapshot.Raster?) { requests[index].continuation.resume(returning: result) }
    }
}
