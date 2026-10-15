import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Production Surface/input/crop handoff with synthetic Pencil contacts. The
/// held crop seam does not prove worker scheduling, actual tile pixels or
/// hardware Pencil-to-photon latency; separate erasure tests cover pixels.
@MainActor
final class NativePDFErasureLifecycleTests: XCTestCase {
    private typealias Base = NativePDFAsynchronousEditTests

    func testProgressiveErasureKeepsTwoPensAndLateForceOrderedAndBitExact() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle()
        let originalRows = f.rows, full = f.fullRenders
        try await enterProgressiveErasure(f)
        let first = f.begin(estimate: 2801)
        let firstLocation = first.touch.point
        first.touch.estimate = nil; first.touch.expecting = []
        f.move(first, dx: 20, dy: 6)
        try await require { f.submitted.contains(first.id) }
        f.end(first)
        let firstCheckpoint = try XCTUnwrap(f.checkpoints.first)
        XCTAssertTrue(f.saved.isEmpty)

        let second = f.begin()
        f.move(second, dx: 17, dy: 9)
        try await require { f.submitted.contains(second.id) }
        XCTAssertEqual(f.gate.completed, 0, "Both contacts must submit while the exact edited crop is held")
        f.end(second)
        XCTAssertTrue(f.saved.isEmpty, "The second completion must not overtake the first unresolved force")
        let secondCheckpoint = try XCTUnwrap(f.checkpoints.last)
        XCTAssertNotEqual(firstCheckpoint.mutationID, secondCheckpoint.mutationID)
        XCTAssertEqual(firstCheckpoint.points.count, 3)
        XCTAssertEqual(secondCheckpoint.points.count, 3)

        // Only force was estimated. Even a changed touch position must not
        // replace the earlier canonical coordinates, timestamp or tilt.
        first.touch.point = CGPoint(x: firstLocation.x + 90, y: firstLocation.y + 70)
        first.touch.estimate = 2801; first.touch.expecting = []; first.touch.pressure = 0.93
        f.surface.updatePencilGestureProperties([first.touch])
        XCTAssertEqual(f.saved.map(\.mutationID), [firstCheckpoint.mutationID, secondCheckpoint.mutationID])
        XCTAssertEqual(f.saved.map(\.kind), ["ink", "ink"])
        let corrected = try XCTUnwrap(f.saved.first)
        var expected = firstCheckpoint.points
        expected[0].p = 0.93
        assertBits(corrected.points, expected)
        assertBits(try XCTUnwrap(f.saved.last).points, secondCheckpoint.points)
        XCTAssertEqual(Array(f.rows.prefix(199)).compactMap { $0["id"] as? String },
                       Array(originalRows.dropFirst()).compactMap { $0["id"] as? String })
        XCTAssertEqual(f.rows.suffix(2).compactMap { $0["clientMutationId"] as? String }, f.saved.map(\.mutationID))
        XCTAssertEqual(f.fullRenders, full)
        try f.assertDurableMatchesSaved()
        try await finishLatestAndAssertPixels(f)
        XCTAssertEqual(f.fullRenders, full)
    }

    func testProgressiveErasureHighlighterThenPenKeepsFreshDestinationAndFinalColor() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }
        try await f.settle(); let full = f.fullRenders
        try await enterProgressiveErasure(f)
        f.surface.tool = .init(name: "highlighter", style: .init(color: "yellow", width: 0.045, opacity: 0.3))
        let marker = f.begin(setPen: false)
        f.move(marker, dx: 25, dy: 3)
        let markerClock = try XCTUnwrap(f.metal.pendingInputTiming)
        try await require { f.surface.inputDiagnostics["frameRequested"] as? Bool == false }
        XCTAssertFalse(f.submitted.contains(marker.id), "A stale erased backdrop is not a valid multiply destination")
        XCTAssertEqual(f.metal.pendingInputTiming?.firstInputAt, markerClock.firstInputAt)
        XCTAssertEqual(f.gate.completed, 0)
        f.end(marker)
        let markerPoints = try XCTUnwrap(f.saved.first).points
        let pen = f.begin(); f.move(pen, dx: 18, dy: -3)
        XCTAssertEqual(f.gate.completed, 0)
        XCTAssertEqual(f.metal.pendingInputTiming?.strokeID, pen.id)
        let penClock = try XCTUnwrap(f.metal.pendingInputTiming)

        // An unbaked highlighter may keep this pen waiting. Supply the exact
        // latest crop while the pen is still down, then prove live submission.
        // This makes no claim of highlighter progress before its fresh crop.
        try await completeLatestCrop(f)
        try await require { f.submitted.contains(pen.id) }
        XCTAssertGreaterThan(f.gate.completed, 0)
        XCTAssertEqual(f.metal.lastSubmittedFrame?.strokeID, pen.id)
        XCTAssertEqual(f.metal.lastSubmittedFrame?.firstInputAt, penClock.firstInputAt)
        f.end(pen)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        assertBits(try XCTUnwrap(f.saved.first).points, markerPoints)
        XCTAssertEqual(f.saved.map { $0.style.opacity }, [0.3, 0.45])
        try f.assertDurableMatchesSaved()
        try await finishLatestAndAssertPixels(f)
        XCTAssertEqual(f.fullRenders, full)
    }

    func testProgressiveCapturedDeletionCannotOverwriteUndoStyleOrViewportChange() async throws {
        enum Change: CaseIterable { case undo, style, viewport }
        for change in Change.allCases {
            let f = try await Base.Fixture.make(); defer { f.close() }
            try await f.settle()
            let original = f.rows, full = f.fullRenders
            try await enterProgressiveErasure(f)
            let firstDelete = try await latestRequest(f)
            f.replace(Array(original.dropFirst(2)))
            let secondDelete = try await latestRequest(f)
            XCTAssertNotEqual(firstDelete.snapshot.revision, secondDelete.snapshot.revision)
            let installedBefore = int(f, "progressiveErasureInstalls")
            switch change {
            case .undo:
                f.replace(original)
            case .style:
                var modified = f.rows
                modified[7]["style"] = ["color": "red", "width": 0.025, "opacity": 0.37]
                f.replace(modified)
            case .viewport:
                var mapper = try XCTUnwrap(f.surface.mapper)
                mapper.canvasToPDF.tx += 19; mapper.canvasToPDF.ty -= 23
                f.surface.frame.origin = CGPoint(x: -14, y: -17)
                f.surface.mapper = mapper
                f.surface.refreshViewport()
            }
            // Both workers were captured before the invalidating change.
            // Their completion must not advance the deletion-only provenance.
            try await f.gate.finish(firstDelete)
            try await f.gate.finish(secondDelete)
            XCTAssertEqual(int(f, "progressiveErasureInstalls"), installedBefore, "Rejected change: \(change)")
            XCTAssertTrue(f.editActive)
            XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
            XCTAssertEqual(f.fullRenders, full)
            try await finishLatestAndAssertPixels(f)
            XCTAssertEqual(f.fullRenders, full)
            XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
            let pending = try NativePDFJournal(root: f.root).pending(courseID: "async", relativePath: "fixture.pdf")
            XCTAssertTrue(pending.isEmpty)
            if case .undo = change {
                XCTAssertEqual(f.rows.compactMap { $0["id"] as? String }, original.compactMap { $0["id"] as? String })
            }
        }
    }

    private func enterProgressiveErasure(_ f: Base.Fixture) async throws {
        f.surface.tool = .init(name: "eraser", style: f.penTool.style)
        let image = try XCTUnwrap(f.imageView.image)
        let before = int(f, "progressiveErasureInstalls")
        f.replace(Array(f.rows.dropFirst()))
        try await require {
            f.editActive && f.surface.inputDiagnostics["progressiveErasureActive"] as? Bool == true &&
                !f.gate.requests.isEmpty && !f.imageView.isHidden
        }
        XCTAssertTrue(f.imageView.image === image, "Entering progressive erasure retains its actual installed opaque scene")
        XCTAssertEqual(int(f, "progressiveErasureInstalls"), before)
        XCTAssertEqual(f.gate.completed, 0)
    }

    private func latestRequest(_ f: Base.Fixture) async throws -> NativePDFNavigationRasterizer.Request {
        try await require {
            guard let request = f.gate.requests.last, let viewport = f.surface.renderViewport,
                  let mapper = f.surface.mapper,
                  let transform = NativePDFObjectRenderer.pageTransform(mapper) else { return false }
            return request.snapshot.revision == f.surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64 &&
                request.snapshot.objects.count == f.rows.count && request.bounds == viewport.canvasRect &&
                request.scale == viewport.pixelScale && request.transform == transform
        }
        return try XCTUnwrap(f.gate.requests.last)
    }

    private func completeLatestCrop(_ f: Base.Fixture) async throws {
        let request = try await latestRequest(f)
        f.gate.requests.removeAll()
        try await f.gate.finish(request)
    }

    private func finishLatestAndAssertPixels(_ f: Base.Fixture) async throws {
        // The displayed progressive base intentionally lags the latest scene.
        // Do not require baseRevision == currentRevision before worker finish.
        if f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true {
            try await completeLatestCrop(f)
        }
        try await require(timeout: 8) {
            !f.editActive && f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                !f.imageView.isHidden && f.metal.strokes.isEmpty &&
                f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        let viewport = try XCTUnwrap(f.surface.renderViewport), mapper = try XCTUnwrap(f.surface.mapper)
        let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in f.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
        let actual = try XCTUnwrap(f.imageView.image?.cgImage)
        XCTAssertEqual(actual.width, reference.width); XCTAssertEqual(actual.height, reference.height)
        XCTAssertTrue(try Base.pixels(actual) == Base.pixels(reference),
            "Settled scene must equal direct PDF + current ordered objects at every RGBA byte")
    }

    private func assertBits(_ actual: [NativePDFPoint], _ expected: [NativePDFPoint],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x.bitPattern, b.x.bitPattern, file: file, line: line)
            XCTAssertEqual(a.y.bitPattern, b.y.bitPattern, file: file, line: line)
            XCTAssertEqual(a.p.bitPattern, b.p.bitPattern, file: file, line: line)
            XCTAssertEqual(a.t?.bitPattern, b.t?.bitPattern, file: file, line: line)
            XCTAssertEqual(a.tiltX?.bitPattern, b.tiltX?.bitPattern, file: file, line: line)
            XCTAssertEqual(a.tiltY?.bitPattern, b.tiltY?.bitPattern, file: file, line: line)
        }
    }
    private func int(_ f: Base.Fixture, _ key: String) -> Int { f.surface.inputDiagnostics[key] as? Int ?? -1 }
    private enum FixtureError: Error { case timeout }
    private func require(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let passed = await Base.poll(timeout: timeout, condition)
        XCTAssertTrue(passed, "Required erasure lifecycle state timed out", file: file, line: line)
        if !passed { throw FixtureError.timeout }
    }
}
