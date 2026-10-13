import XCTest
import PDFKit
@testable import Bandal

final class NativePDFInkTests: XCTestCase {
    func testLatePressureCorrectionsCannotReorderOverlappingStrokesAndFlushRetryKeepsIdentity() throws {
        struct Entry: Equatable { var stroke: NativePDFCompletedStroke; var corrected: Bool }
        let queue = NativePDFOrderedCompletions<Entry>()
        func entry(_ id: String, corrected: Bool) -> Entry {
            .init(stroke: .init(mutationID: id, kind: "highlighter", points: [.init(x: 0.3, y: 0.4, p: 0)],
                style: .init(color: "yellow", width: 0.02, opacity: 0.34)), corrected: corrected)
        }
        let firstID = UUID().uuidString, secondID = UUID().uuidString, thirdID = UUID().uuidString
        try queue.append(entry(firstID, corrected: false), id: firstID)
        try queue.append(entry(secondID, corrected: true), id: secondID)
        var writes: [NativePDFCompletedStroke] = []
        queue.drain(ready: { $0.corrected }) { writes.append($0.stroke) }
        XCTAssertTrue(writes.isEmpty, "The already-corrected second stroke waits for the first")
        var first = queue[firstID]!
        first.stroke.points[0].p = 0.7; first.corrected = true; queue[firstID] = first
        queue.drain(ready: { $0.corrected }) { writes.append($0.stroke) }
        XCTAssertEqual(writes.map(\.mutationID), [firstID, secondID])
        XCTAssertEqual(writes.first?.points.first?.p, 0.7)
        try queue.append(entry(thirdID, corrected: false), id: thirdID)
        let fourthID = UUID().uuidString
        try queue.append(entry(fourthID, corrected: true), id: fourthID)
        var failed: NativePDFCompletedStroke?
        XCTAssertThrowsError(try queue.flush { failed = $0.stroke; throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(queue.ids, [thirdID, fourthID])
        queue.flush { writes.append($0.stroke) }
        XCTAssertEqual(writes.suffix(2).map(\.mutationID), [thirdID, fourthID])
        XCTAssertEqual(failed, writes[2], "Explicit tool-change/background flush retries exact measured data")
        XCTAssertTrue(queue.isEmpty)
    }
    func testEstimatedCheckpointSurvivesReopenAndBecomesImmutableOnlyAfterFinalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NativePDFJournal(root: root), revision = String(repeating: "a", count: 64)
        var input = NativePDFStrokeInput(courseId: "course", relPath: "a.pdf", page: 1, kind: "ink",
            data: .init(points: [.init(x: 0.2, y: 0.3, p: 0, t: 18, tiltX: 0, tiltY: 0)]),
            style: .init(color: "ink", width: 0.004, opacity: 1), clientMutationId: UUID().uuidString, documentRevision: revision)
        try journal.checkpoint(input, documentRevision: revision)
        let reopened = try NativePDFJournal(root: root)
        XCTAssertEqual(try reopened.pending(courseID: "course", relativePath: "a.pdf").first?.provisional, true)
        input.data.points[0].p = 0.7; input.data.points[0].tiltX = 21
        try reopened.checkpoint(input, documentRevision: revision)
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "a.pdf").first?.input, input)
        var differentOwner = input; differentOwner.relPath = "other.pdf"
        XCTAssertThrowsError(try reopened.checkpoint(differentOwner, documentRevision: revision))
        var differentTiming = input; differentTiming.data.points[0].t = 19
        XCTAssertThrowsError(try reopened.checkpoint(differentTiming, documentRevision: revision))
        try reopened.append(input, documentRevision: revision)
        XCTAssertNil(try reopened.pending(courseID: "course", relativePath: "a.pdf").first?.provisional)
        try reopened.append(input, documentRevision: revision)
        var late = input; late.data.points[0].p = 0.9
        XCTAssertThrowsError(try reopened.checkpoint(late, documentRevision: revision))
        XCTAssertThrowsError(try reopened.append(late, documentRevision: revision))
        XCTAssertEqual(try reopened.pending(courseID: "course", relativePath: "a.pdf").first?.input, input)
    }
    func testFailedCompletionRetainsExactMeasuredPayloadAndMutationUntilDurableRetry() throws {
        let buffer = NativePDFCompletionBuffer()
        let stroke = NativePDFCompletedStroke(mutationID: UUID().uuidString, kind: "ink",
            points: [.init(x: 0.2, y: 0.3, p: 0, t: 12, tiltX: -11, tiltY: 18)],
            style: .init(color: "blue", width: 0.004, opacity: 0.7))
        try buffer.retain(stroke)
        var attempts: [NativePDFCompletedStroke] = []
        for _ in 0..<3 {
            XCTAssertThrowsError(try buffer.flush { captured in
                attempts.append(captured); throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertEqual(buffer.pending, stroke)
        }
        var other = stroke; other.mutationID = UUID().uuidString
        XCTAssertThrowsError(try buffer.retain(other))
        try buffer.flush { attempts.append($0) }
        XCTAssertNil(buffer.pending)
        XCTAssertEqual(attempts, Array(repeating: stroke, count: 4))
        try buffer.flush { _ in XCTFail("Acknowledged completions cannot be written twice") }
    }
    func testDisplayCoordinatesPreserveDesktopRowsForCropBoxAndEveryRotation() {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 800, height: 900), for: .mediaBox)
        page.setBounds(CGRect(x: 73, y: 81, width: 400, height: 600), for: .cropBox)
        let pdfPoint = CGPoint(x: 153, y: 501) // unrotated top-left fraction .2,.3
        let expected = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.3, y: 0.8)]
        for (index, rotation) in [0, 90, 180, 270].enumerated() {
            page.rotation = rotation
            let map = NativePDFPageCoordinates(page: page)
            let value = map.displayNormalized(pdfPoint)
            XCTAssertEqual(value.x, expected[index].x, accuracy: 1e-10)
            XCTAssertEqual(value.y, expected[index].y, accuracy: 1e-10)
            let roundTrip = map.pdfPoint(value)
            XCTAssertEqual(roundTrip.x, pdfPoint.x, accuracy: 1e-10)
            XCTAssertEqual(roundTrip.y, pdfPoint.y, accuracy: 1e-10)
            XCTAssertEqual(map.width, rotation % 180 == 0 ? 400 : 600)
            XCTAssertEqual(map.height, rotation % 180 == 0 ? 600 : 400)
            let physical = map.displayPhysical(pdfPoint)
            XCTAssertEqual(physical.x, value.x * map.width, accuracy: 1e-10)
            XCTAssertEqual(physical.y, (1-value.y) * map.height, accuracy: 1e-10)
        }
    }
    func testDotsAndPressureOnlyChangesProduceFiniteGeometry() {
        let dot = NativePDFPoint(x: 0.2, y: 0.3, p: 0)
        let polygons = NativePDFInkGeometry.polygons(points: [dot], width: 0.01, aspect: 2, highlighter: false)
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(polygons[0].count, 24)
        XCTAssertEqual(polygons[0][0].x, 0.20175, accuracy: 1e-12)
        XCTAssertEqual(polygons[0][6].y, 0.300875, accuracy: 1e-12)
        let pressure = NativePDFInkGeometry.polygons(points: [dot, .init(x: 0.2, y: 0.3, p: 1)], width: 0.01, aspect: 2, highlighter: false)
        XCTAssertEqual(pressure.count, 2)
        XCTAssertEqual(pressure[1][0].x, 0.205, accuracy: 1e-12)
        XCTAssertTrue(pressure.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
    func testSharedPolygonOrderAndWinding() {
        let polygons = NativePDFInkGeometry.polygons(points: [.init(x: 0.1, y: 0.1, p: 0), .init(x: 0.4, y: 0.2, p: 1)], width: 0.02, aspect: 1.5, highlighter: true)
        XCTAssertEqual(polygons.map(\.count), [24, 4, 24])
        for polygon in polygons {
            let area = polygon.indices.reduce(0.0) { sum, i in
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                return sum + a.x * b.y - b.x * a.y
            }
            XCTAssertGreaterThan(area, 0, "One nonzero fill requires consistent polygon winding")
        }
    }
    func testJournalPreservesMetadataAndRequiresSameDocumentOwnerForACK() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NativePDFJournal(root: root)
        let id = UUID().uuidString
        let input = NativePDFStrokeInput(courseId: "course", relPath: "a.pdf", page: 2, kind: "ink",
            data: .init(points: [.init(x: 0.1, y: 0.2, p: 0, t: 12, tiltX: 31, tiltY: -24)]),
            style: .init(color: "ink", width: 0.004, opacity: 0.8), clientMutationId: id)
        try journal.append(input, documentRevision: "document-v1")
        try journal.append(input, documentRevision: "document-v1")
        let reopened = try NativePDFJournal(root: root)
        XCTAssertEqual(try reopened.pending(courseID: "course", relativePath: "a.pdf").map(\.input), [input])
        XCTAssertThrowsError(try reopened.append(input, documentRevision: "different-pdf"))
        XCTAssertThrowsError(try reopened.acknowledge(id, courseID: "course", relativePath: "other.pdf"))
        XCTAssertEqual(try reopened.pending(courseID: "course", relativePath: "a.pdf").count, 1)
        try reopened.acknowledge(id, courseID: "course", relativePath: "a.pdf")
        XCTAssertEqual(try reopened.pending(courseID: "course", relativePath: "a.pdf").count, 0)
    }
}
