import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Bandal

@MainActor
final class InkConcurrentRefreshTests: XCTestCase {
    func testRemoteSnapshotArrivingDuringPencilStrokeSurvivesLocalSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-race-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { $0.beginPage() }.write(to: url)
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 600, height: 800))
        let originalDrawing = drawing(at: CGPoint(x: 50, y: 50))
        var baseline = PortableInkPageRecord.empty(materialID: "material", revision: "revision", page: 1, geometry: mapper.geometry)
        baseline.objects = PortableInkCodec.objects(from: originalDrawing, mapper: mapper, previous: [])
        baseline.nativeCache = NativeInkCache(drawing: originalDrawing.dataRepresentation(), canvasWidth: 600, canvasHeight: 800,
                                             portableDigest: PortableInkCodec.digest(baseline.objects))
        var backing = try PortableInkPersistence.encode(baseline)
        let controller = PDFWorkspaceController(documentURL: url, materialID: "material", revision: "revision",
            loadPage: { _ in backing }, savePage: { _, data in backing = data }, onExport: { _ in })
        controller.install(tools: InkToolState())
        let page = try XCTUnwrap(controller.document?.page(at: 0))
        let overlay = try XCTUnwrap(controller.pdfView(controller.pdfView, overlayViewFor: page))
        let canvas = try XCTUnwrap(overlay.subviews.compactMap { $0 as? PersistentInkCanvas }.first)
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        canvas.restore(baseline, mapper: mapper)
        canvas.delegate?.canvasViewDidBeginUsingTool?(canvas)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + drawing(at: CGPoint(x: 180, y: 180)).strokes)

        var remote = baseline
        var remoteObject = try XCTUnwrap(PortableInkCodec.objects(from: drawing(at: CGPoint(x: 350, y: 350)), mapper: mapper, previous: []).first)
        remoteObject.id = "remote-stroke"
        remote.objects.append(remoteObject); remote.nativeCache = nil
        backing = try PortableInkPersistence.encode(remote)
        NotificationCenter.default.post(name: Notification.Name("app.bandal.records.changed"), object: nil)
        canvas.delegate?.canvasViewDidEndUsingTool?(canvas)

        let saved = try JSONDecoder().decode(PortableInkPageRecord.self, from: backing)
        XCTAssertTrue(saved.objects.contains { $0.id == "remote-stroke" })
        XCTAssertTrue(saved.objects.contains { $0.id == baseline.objects[0].id })
        XCTAssertEqual(saved.objects.count, 3)
    }

    func testSimultaneousObjectEditsBecomeExplicitCopies() throws {
        var base = page()
        base.objects = [object(id: "same", x: 0.1)]
        var local = base; local.objects[0].data.points?[0].x = 0.2
        var remote = base; remote.objects[0].data.points?[0].x = 0.3
        let result = try PortableInkThreeWayMerge.merge(base: base, local: local, remote: remote)
        XCTAssertTrue(result.preservedConflicts)
        XCTAssertEqual(result.record.objects.count, 2)
        XCTAssertEqual(Set(result.record.objects.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.record.objects.compactMap { $0.data.points?.first?.x }), [0.2, 0.3])
    }

    func testEditDeleteConflictPreservesEditedCopyAndTombstone() throws {
        var base = page(); base.objects = [object(id: "same", x: 0.1)]
        var local = base; local.objects = []; local.deletedObjectIDs = ["same"]
        var remote = base; remote.objects[0].data.points?[0].x = 0.4
        let result = try PortableInkThreeWayMerge.merge(base: base, local: local, remote: remote)
        XCTAssertTrue(result.preservedConflicts)
        XCTAssertEqual(result.record.objects.count, 1)
        XCTAssertNotEqual(result.record.objects.first?.id, "same")
        XCTAssertTrue(result.record.deletedObjectIDs.contains("same"))
        XCTAssertEqual(result.record.objects.first?.data.points?.first?.x, 0.4)
    }

    private func page() -> PortableInkPageRecord {
        .empty(materialID: "material", revision: "revision", page: 1,
               geometry: InkPageGeometry(cropBox: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 0))
    }
    private func object(id: String, x: Double) -> PortableInkObject {
        PortableInkObject(id: id, kind: "ink", data: InkGeometry(points: [InkPoint(x: x, y: 0.2, p: 0.5)]),
                          style: InkStyle(color: "ink", width: 0.005, opacity: 1), createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }
    private func drawing(at point: CGPoint) -> PKDrawing {
        let samples = [point, CGPoint(x: point.x + 50, y: point.y + 30)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: samples, creationDate: Date()))])
    }
}
