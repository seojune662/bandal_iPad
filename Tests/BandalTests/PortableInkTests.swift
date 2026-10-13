import XCTest
import PencilKit
@testable import Bandal

@MainActor
final class PortableInkTests: XCTestCase {
    func testCropBoxCoordinatesRemainUnrotatedAndReversible() {
        for rotation in [0, 90, 180, 270] {
            let geometry = InkPageGeometry(cropBox: CGRect(x: 31, y: 47, width: 595, height: 842), rotation: rotation)
            let topLeft = geometry.normalize(CGPoint(x: 31, y: 889))
            XCTAssertEqual(topLeft.x, 0, accuracy: 0.000001)
            XCTAssertEqual(topLeft.y, 0, accuracy: 0.000001)
            let sample = InkPoint(x: 0.23, y: 0.81, p: 0.7)
            let restored = geometry.normalize(geometry.pdfPoint(sample), pressure: sample.p)
            XCTAssertEqual(restored.x, sample.x, accuracy: 0.000001)
            XCTAssertEqual(restored.y, sample.y, accuracy: 0.000001)
            let rect = CGRect(x: 90, y: 123, width: 56, height: 74)
            XCTAssertEqual(geometry.pdfRect(geometry.normalize(rect)).minY, rect.minY, accuracy: 0.000001)
        }
    }

    func testRotatedOverlayMapperRoundTripsPortablePoint() {
        let geometry = InkPageGeometry(cropBox: CGRect(x: 10, y: 20, width: 500, height: 700), rotation: 90)
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 0, b: 0.5, c: -0.5, d: 0, tx: 510, ty: 20), geometry: geometry)
        let original = InkPoint(x: 0.35, y: 0.8, p: 0.4)
        let result = mapper.normalized(mapper.canvasPoint(original), pressure: original.p)
        XCTAssertEqual(result.x, original.x, accuracy: 0.000001)
        XCTAssertEqual(result.y, original.y, accuracy: 0.000001)
    }

    func testRevisionMismatchNeverAppliesOldInk() throws {
        let geometry = InkCoordinateMapper.whiteboard(size: CGSize(width: 800, height: 1000)).geometry
        let record = PortableInkPageRecord.empty(materialID: "material", revision: "old", page: 1, geometry: geometry)
        XCTAssertThrowsError(try record.validate(materialID: "material", revision: "new", page: 1, geometry: geometry))
        XCTAssertThrowsError(try record.validate(materialID: "other", revision: "old", page: 1, geometry: geometry))
    }

    func testOldPageWithoutTombstonesDecodes() throws {
        let geometry = InkCoordinateMapper.whiteboard(size: CGSize(width: 800, height: 1000)).geometry
        let record = PortableInkPageRecord.empty(materialID: "material", revision: "1", page: 1, geometry: geometry)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "deletedObjectIDs"); json.removeValue(forKey: "deletedHighlightIDs")
        let decoded = try JSONDecoder().decode(PortableInkPageRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.deletedObjectIDs, [])
        XCTAssertEqual(decoded.deletedHighlightIDs, [])
    }

    func testDeletingAndRestoringStrokePreservesTombstoneWithoutReusingIdentity() throws {
        let canvas = PersistentInkCanvas(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let mapper = InkCoordinateMapper.whiteboard(size: canvas.bounds.size)
        canvas.restore(.empty(materialID: "material", revision: "1", page: 1, geometry: mapper.geometry), mapper: mapper)
        var saved: [PortableInkPageRecord] = []
        canvas.save = { saved.append($0) }
        let drawing = makeDrawing()
        canvas.drawing = drawing; canvas.delegate?.canvasViewDidEndUsingTool?(canvas)
        let original = try XCTUnwrap(saved.last?.objects.first?.id)
        canvas.drawing = PKDrawing(); canvas.delegate?.canvasViewDidEndUsingTool?(canvas)
        XCTAssertEqual(saved.last?.objects.count, 0)
        XCTAssertTrue(try XCTUnwrap(saved.last).deletedObjectIDs.contains(original))
        canvas.drawing = drawing; canvas.delegate?.canvasViewDidEndUsingTool?(canvas)
        XCTAssertNotEqual(saved.last?.objects.first?.id, original)
        XCTAssertTrue(try XCTUnwrap(saved.last).deletedObjectIDs.contains(original))
    }

    func testInitialLoadDoesNotWriteEmptyDrawing() {
        let canvas = PersistentInkCanvas(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let mapper = InkCoordinateMapper.whiteboard(size: canvas.bounds.size)
        var writes = 0
        canvas.save = { _ in writes += 1 }
        canvas.restore(.empty(materialID: "material", revision: "1", page: 1, geometry: mapper.geometry), mapper: mapper)
        canvas.delegate?.canvasViewDrawingDidChange?(canvas); canvas.flush()
        XCTAssertEqual(writes, 0)
    }

    func testCanvasUsesSeparateDelegateAndCompletedToolSavesExactlyOnce() throws {
        let canvas = PersistentInkCanvas(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let delegate = try XCTUnwrap(canvas.delegate)
        XCTAssertFalse((delegate as AnyObject) === canvas)
        XCTAssertFalse(delegate is PKCanvasView)
        let mapper = InkCoordinateMapper.whiteboard(size: canvas.bounds.size)
        canvas.restore(.empty(materialID: "material", revision: "1", page: 1, geometry: mapper.geometry), mapper: mapper)
        var writes: [PortableInkPageRecord] = []
        var beginnings = 0
        canvas.save = { writes.append($0) }
        canvas.onBegin = { beginnings += 1 }
        delegate.canvasViewDidBeginUsingTool?(canvas)
        XCTAssertTrue(canvas.hasActiveTool)
        XCTAssertEqual(beginnings, 1)
        canvas.drawing = makeDrawing()
        delegate.canvasViewDrawingDidChange?(canvas)
        XCTAssertTrue(writes.isEmpty)
        delegate.canvasViewDidEndUsingTool?(canvas)
        XCTAssertFalse(canvas.hasActiveTool)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.objects.count, 1)
        XCTAssertTrue(canvas.accessibilityValue?.hasPrefix("1개의 획") == true)
        canvas.flush()
        XCTAssertEqual(writes.count, 1)
    }

    func testCanvasRetainsItsDelegateWithoutDelegateRetainingCanvas() throws {
        weak var releasedCanvas: PersistentInkCanvas?
        weak var releasedDelegate: AnyObject?
        var retainedDelegate: (any PKCanvasViewDelegate)?
        autoreleasepool {
            let canvas = PersistentInkCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
            releasedCanvas = canvas
            retainedDelegate = canvas.delegate
            releasedDelegate = canvas.delegate
            XCTAssertNotNil(canvas.delegate)
        }
        XCTAssertNil(releasedCanvas)
        XCTAssertNotNil(releasedDelegate)
        retainedDelegate = nil
        XCTAssertNil(releasedDelegate)
    }

    func testWhiteboardFingerDrawingUsesTwoFingerPan() {
        let controller = WhiteboardController(materialID: "board", revision: "1", load: { nil }, save: { _ in })
        controller.install()
        let tools = InkToolState()
        controller.configure(tools)
        XCTAssertEqual(controller.scrollView.panGestureRecognizer.minimumNumberOfTouches, 1)
        tools.fingerDrawing = true
        controller.configure(tools)
        XCTAssertEqual(controller.scrollView.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(controller.canvas.drawingPolicy, .anyInput)
        XCTAssertFalse(controller.scrollView.canCancelContentTouches)
        tools.fingerDrawing = false
        controller.configure(tools)
        XCTAssertEqual(controller.scrollView.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertEqual(controller.canvas.drawingPolicy, .pencilOnly)
    }

    func testWhiteboardRefitsResizedPaneAndPreservesManualZoom() {
        let controller = WhiteboardController(materialID: "board", revision: "1", load: { nil }, save: { _ in })
        controller.install()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.scrollView.layoutIfNeeded()
        controller.fit()
        XCTAssertEqual(controller.scrollView.zoomScale, 1.0 / 3.0, accuracy: 0.001)
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        controller.scrollView.layoutIfNeeded()
        XCTAssertEqual(controller.scrollView.zoomScale, 0.625, accuracy: 0.001)
        controller.scrollViewWillBeginZooming(controller.scrollView, with: controller.canvas)
        controller.scrollView.setZoomScale(1.2, animated: false)
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        controller.scrollView.layoutIfNeeded()
        XCTAssertEqual(controller.scrollView.zoomScale, 1.2, accuracy: 0.001)
    }

    func testChangedPortableInkCannotBeMaskedByStaleNativeCache() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 800, height: 1000))
        let drawing = makeDrawing()
        var record = PortableInkPageRecord.empty(materialID: "material", revision: "1", page: 1, geometry: mapper.geometry)
        record.objects = PortableInkCodec.objects(from: drawing, mapper: mapper, previous: [])
        record.nativeCache = NativeInkCache(drawing: drawing.dataRepresentation(), canvasWidth: 800, canvasHeight: 1000,
                                           portableDigest: PortableInkCodec.digest(record.objects))
        record.objects[0].data.points?[0].x = 0.75
        let restored = PortableInkCodec.restoring(record, mapper: mapper, size: CGSize(width: 800, height: 1000))
        XCTAssertEqual(try XCTUnwrap(restored.strokes.first).path[0].location.x, 600, accuracy: 0.5)
    }

    func testOversizedNativeCacheIsDroppedWithoutChangingPortableInk() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 800, height: 1000))
        var record = PortableInkPageRecord.empty(materialID: "material", revision: "1", page: 1, geometry: mapper.geometry)
        record.objects = PortableInkCodec.objects(from: makeDrawing(), mapper: mapper, previous: [])
        record.deletedObjectIDs = ["deleted"]
        record.nativeCache = NativeInkCache(drawing: Data(repeating: 0, count: 2_500_000), canvasWidth: 800,
                                           canvasHeight: 1000, portableDigest: PortableInkCodec.digest(record.objects))
        let encoded = try PortableInkPersistence.encode(record)
        let decoded = try JSONDecoder().decode(PortableInkPageRecord.self, from: encoded)
        XCTAssertNil(decoded.nativeCache)
        XCTAssertEqual(decoded.objects, record.objects)
        XCTAssertEqual(decoded.deletedObjectIDs, record.deletedObjectIDs)
        XCTAssertLessThan(encoded.count, PortableInkPersistence.nativeCacheBudget)
    }

    private func makeDrawing() -> PKDrawing {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
}
