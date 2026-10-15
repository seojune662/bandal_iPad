import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Real Surface + Metal + asynchronous object texture preparation in a UIWindow.
/// Synthetic touches enter the production Pencil methods; this is not UIKit
/// recognizer arbitration, backend durability, or physical-input latency proof.
@MainActor
final class NativePDFRetainedMixedSurfaceTests: XCTestCase {
    func testTwoHundredInkAndThreeObjectKindsStayOnGPUAcrossPanWithoutReupload() async throws {
        let f = try await Fixture(); defer { f.close() }
        let renderer = try XCTUnwrap(f.metal.retainedRenderer)
        XCTAssertEqual(f.metal.retainedItems?.filter { $0.mesh != nil }.count, 200)
        XCTAssertEqual(f.metal.retainedItems?.filter { $0.texture != nil }.count, 3)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedObjectTextures"] as? Int, 3)
        let meshUploads = renderer.meshUploadCount, textureUploads = renderer.textureUploadCount
        let objectRasters = f.surface.inputDiagnostics["retainedObjectRasters"] as? Int
        let fullRenders = f.surface.inputDiagnostics["sceneFullRenders"] as? Int
        let crops = f.cropRequests
        XCTAssertEqual(meshUploads, 200)
        // Attaching the window can upgrade an already-running low-density
        // object capture. Take the reuse baseline only after it settles.
        XCTAssertGreaterThanOrEqual(textureUploads, 3)
        XCTAssertEqual(objectRasters, textureUploads)
        let original = try f.pixels()
        f.assertRGBA(original, point: CGPoint(x: 0.49, y: 0.74), expected: [40, 150, 90, 255])
        f.assertRGBA(original, point: CGPoint(x: 0.26, y: 0.785), expected: [213, 227, 249, 255])
        f.assertRGBA(original, point: CGPoint(x: 0.70, y: 0.74), expected: [235, 146, 151, 255])
        f.assertRGBA(original, point: CGPoint(x: 0.79, y: 0.74), expected: [255, 255, 255, 255], tolerance: 0)
        let previous = f.metal.submittedFrameCount
        f.pan(x: 20, y: 30)
        try await f.settled(after: previous)
        let moved = try f.pixels()
        f.assertRGBA(moved, pixel: CGPoint(x: 0.49*600-20, y: 0.74*800-30), expected: [40, 150, 90, 255])
        let panSubmission = f.metal.submittedFrameCount
        f.pan(x: 0, y: 0)
        try await f.settled(after: panSubmission)
        XCTAssertTrue(try f.pixels() == original, "Restoring the exact viewport restores every GPU byte")
        XCTAssertEqual(renderer.meshUploadCount, meshUploads)
        XCTAssertEqual(renderer.textureUploadCount, textureUploads)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedObjectRasters"] as? Int, objectRasters)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneFullRenders"] as? Int, fullRenders)
        XCTAssertEqual(f.cropRequests, crops, "Pan must not request a completed-ink crop")
        XCTAssertEqual(f.saved.count, 0); XCTAssertEqual(f.checkpoints, 0); XCTAssertTrue(f.errors.isEmpty)
    }

    func testSparseNativeEraseOwnsMixedContactOnceAndUndoRestoresPixelsAndRawRows() async throws {
        let f = try await Fixture(); defer { f.close() }
        let originalRows = f.rows, originalBits = f.inkBits(), original = try f.pixels()
        let renderer = try XCTUnwrap(f.metal.retainedRenderer), meshes = renderer.meshUploadCount
        let crops = f.cropRequests, fullRenders = f.surface.inputDiagnostics["sceneFullRenders"] as? Int
        f.surface.tool = .init(name: "eraser", style: .init(color: "blue", width: 0.006, opacity: 1))
        let touch = LocalTouch(point: CGPoint(x: 0.15*600, y: 0.74*800))
        XCTAssertTrue(f.surface.beginPencilGesture(touch, with: nil))
        XCTAssertEqual(f.surface.inputDiagnostics["nativeEraseContact"] as? Bool, true)
        touch.point.x = 0.62*600; touch.time += 0.008
        f.surface.movePencilGesture(touch, with: nil)
        touch.point.x = 0.91*600; touch.time += 0.008
        let previous = f.metal.submittedFrameCount
        f.surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(f.eraseBegins, 1)
        XCTAssertEqual(f.erases.count, 1)
        XCTAssertEqual(f.erases.first?.map(\.drawingID), ["mixed-text", "mixed-image", "mixed-rect"])
        XCTAssertTrue(f.erases.first?.allSatisfy { $0.mutationID == nil } == true)
        XCTAssertEqual(f.pointerEvents, 0, "Native erasure must not also relay a JS pointer gesture")
        XCTAssertEqual(f.ownership, [true, false])
        try await f.settled(after: previous, expectedItems: 200)
        XCTAssertEqual(f.rows.count, 200)
        let erased = try f.pixels()
        for point in [CGPoint(x: 0.15,y: 0.74),CGPoint(x: 0.49,y: 0.74),CGPoint(x: 0.70,y: 0.74)] {
            f.assertRGBA(erased, point: point, expected: [255,255,255,255], tolerance: 0)
        }
        XCTAssertTrue(f.inkBits() == originalBits)
        XCTAssertEqual(renderer.meshUploadCount, meshes)
        XCTAssertEqual(f.cropRequests, crops)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneFullRenders"] as? Int, fullRenders)
        XCTAssertEqual(f.saved.count, 0); XCTAssertEqual(f.checkpoints, 0)
        // Model restoration represents an authoritative undo response. Writer
        // receipt/operation ordering is tested separately in the Host suite.
        let erasedSubmission = f.metal.submittedFrameCount
        f.surface.erasedIdentifiers = []; f.rows = originalRows; f.applyRows()
        try await f.settled(after: erasedSubmission)
        XCTAssertTrue(try f.pixels() == original, "Undo restores the ordered mixed scene, including object alpha")
        XCTAssertTrue(f.inkBits() == originalBits)
        XCTAssertEqual(renderer.meshUploadCount, meshes)
        XCTAssertTrue(f.errors.isEmpty)
    }

    func testNewPenAboveImagePreservesMeasuredSamplesAndDoesNotRasterCompletedInk() async throws {
        let f = try await Fixture(); defer { f.close() }
        let originalBits = f.inkBits(), renderer = try XCTUnwrap(f.metal.retainedRenderer)
        let meshes = renderer.meshUploadCount, textures = renderer.textureUploadCount
        let rasters = f.surface.inputDiagnostics["retainedObjectRasters"] as? Int
        let crops = f.cropRequests, fullRenders = f.surface.inputDiagnostics["sceneFullRenders"] as? Int
        f.surface.tool = .init(name: "pen", style: .init(color: "red", width: 0.025, opacity: 0.5))
        let touch = LocalTouch(point: CGPoint(x: 0.43*600, y: 0.74*800))
        let before = f.metal.submittedFrameCount
        XCTAssertTrue(f.surface.beginPencilGesture(touch, with: nil))
        touch.point.x = 0.49*600; touch.time += 0.008
        f.surface.movePencilGesture(touch, with: nil)
        try await Self.wait {
            f.metal.submittedFrameCount > before && !f.metal.strokes.isEmpty
        }
        XCTAssertEqual(f.saved.count, 0, "A live frame must be submitted before the synthetic contact lifts")
        touch.point.x = 0.55*600; touch.time += 0.008
        let liveSubmission = f.metal.submittedFrameCount
        f.surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(f.saved.count, 1)
        let stroke = try XCTUnwrap(f.saved.first)
        XCTAssertEqual(stroke.kind, "ink"); XCTAssertEqual(stroke.points.count, 3)
        XCTAssertEqual(stroke.inkVersion, 5)
        for (index, x) in [0.43, 0.49, 0.55].enumerated() {
            XCTAssertEqual(stroke.points[index].x, x, accuracy: 1e-12)
            XCTAssertEqual(stroke.points[index].y, 0.74, accuracy: 1e-12)
            XCTAssertEqual(stroke.points[index].p.bitPattern, Double(0.5).bitPattern)
        }
        XCTAssertLessThan(try XCTUnwrap(stroke.points[0].t), try XCTUnwrap(stroke.points[1].t))
        XCTAssertLessThan(try XCTUnwrap(stroke.points[1].t), try XCTUnwrap(stroke.points[2].t))
        try await f.settled(after: liveSubmission, expectedItems: 204)
        XCTAssertTrue(f.metal.strokes.isEmpty)
        let final = try f.pixels()
        f.assertRGBA(final, point: CGPoint(x: 0.49, y: 0.74), expected: [127,93,68,255])
        f.assertRGBA(final, point: CGPoint(x: 0.49, y: 0.70), expected: [40,150,90,255])
        XCTAssertTrue(f.inkBits(onlyOriginal: true) == originalBits)
        let savedRaw = try XCTUnwrap((f.rows.last?["data"] as? [String: Any])?["points"] as? [[String: Any]])
        for (index, raw) in savedRaw.enumerated() {
            for (key, expected) in [("x",stroke.points[index].x),("y",stroke.points[index].y),("p",stroke.points[index].p)] {
                XCTAssertEqual(try XCTUnwrap(raw[key] as? Double).bitPattern, expected.bitPattern)
            }
        }
        XCTAssertEqual(renderer.meshUploadCount, meshes+1)
        XCTAssertEqual(renderer.textureUploadCount, textures)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedObjectRasters"] as? Int, rasters)
        XCTAssertEqual(f.cropRequests, crops)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneFullRenders"] as? Int, fullRenders)
        XCTAssertEqual(f.pointerEvents, 0); XCTAssertTrue(f.erases.isEmpty); XCTAssertTrue(f.errors.isEmpty)
    }

    func testTwentyV5ContactsAndContinuousNativeEraseKeepOldMeshesTexturesAndRawSamples() async throws {
        let f = try await Fixture(); defer { f.close() }
        let renderer = try XCTUnwrap(f.metal.retainedRenderer)
        let oldPixels = try f.pixels(), oldBits = f.inkBits()
        let oldMeshes = renderer.meshUploadCount, oldTextures = renderer.textureUploadCount
        let oldRasters = try XCTUnwrap(f.surface.inputDiagnostics["retainedObjectRasters"] as? Int)
        let oldFull = try XCTUnwrap(f.surface.inputDiagnostics["sceneFullRenders"] as? Int)
        let oldCrops = f.cropRequests
        let oldPrepared = try f.rows.prefix(200).map { try XCTUnwrap($0["_nativeInk"] as? NativePDFPreparedInk) }
        var callbackMS: [Double] = []
        func record(_ action: () -> Void) {
            let start = CACurrentMediaTime(); action()
            callbackMS.append((CACurrentMediaTime() - start) * 1000)
        }
        f.surface.tool = .init(name: "pen", style: .init(color: "red", width: 0.005, opacity: 0.65))
        for contact in 0..<20 {
            let touch = LocalTouch(point: .zero)
            let beganAt = touch.time
            var expected: [NativePDFPoint] = []
            let initialSubmission = f.metal.submittedFrameCount
            for sample in 0..<96 {
                let u = Double(sample) / 95
                let x = 0.04 + Double(contact % 5) * 0.19 + u * 0.11
                let y = 0.84 + Double(contact / 5) * 0.037 + sin(u * .pi) * 0.006
                touch.point = CGPoint(x: x * 600, y: y * 800)
                touch.pressure = CGFloat(0.05 + 0.9 * sin(u * .pi))
                touch.time = beganAt + Double(sample) * 0.004
                let normalized = try XCTUnwrap(f.surface.mapper).normalized(touch.point, pressure: Double(touch.pressure))
                expected.append(.init(x: normalized.x, y: normalized.y, p: normalized.p,
                    t: max(0, (touch.time - beganAt) * 1000)))
                if sample == 0 { record { XCTAssertTrue(f.surface.beginPencilGesture(touch, with: nil)) } }
                else if sample == 95 { record { f.surface.endPencilGesture(touch, with: nil) } }
                else { record { f.surface.movePencilGesture(touch, with: nil) } }
                if sample == 47 {
                    try await Self.wait { f.metal.submittedFrameCount > initialSubmission && !f.metal.strokes.isEmpty }
                    XCTAssertEqual(f.saved.count, contact, "Every contact submits live ink before its lift")
                }
            }
            XCTAssertEqual(f.saved.count, contact + 1)
            let saved = try XCTUnwrap(f.saved.last)
            XCTAssertEqual(saved.inkVersion, 5); XCTAssertEqual(saved.points.count, 96)
            for (actual, raw) in zip(saved.points, expected) {
                XCTAssertEqual(actual.x.bitPattern, raw.x.bitPattern)
                XCTAssertEqual(actual.y.bitPattern, raw.y.bitPattern)
                XCTAssertEqual(actual.p.bitPattern, raw.p.bitPattern)
                XCTAssertEqual(actual.t?.bitPattern, raw.t?.bitPattern)
            }
            let savedRow = try XCTUnwrap(f.rows.last)
            XCTAssertEqual((savedRow["data"] as? [String: Any])?["inkVersion"] as? Int, 5)
            let serialized = try XCTUnwrap((savedRow["data"] as? [String: Any])?["points"] as? [[String: Any]])
            XCTAssertEqual(serialized.count, saved.points.count)
            for (raw, actual) in zip(serialized, saved.points) {
                for (name, value) in [("x", actual.x), ("y", actual.y), ("p", actual.p)] {
                    XCTAssertEqual(try XCTUnwrap(raw[name] as? Double).bitPattern, value.bitPattern)
                }
                for (name, value) in [("t", actual.t), ("tiltX", actual.tiltX), ("tiltY", actual.tiltY)] {
                    XCTAssertEqual((raw[name] as? Double)?.bitPattern, value?.bitPattern)
                }
            }
            try await f.settled(expectedItems: 204 + contact)
            XCTAssertEqual(renderer.meshUploadCount, oldMeshes + contact + 1, "Only the newly completed V5 mesh may upload")
            XCTAssertEqual(renderer.textureUploadCount, oldTextures)
            XCTAssertEqual(f.surface.inputDiagnostics["retainedObjectRasters"] as? Int, oldRasters)
            XCTAssertEqual(f.surface.inputDiagnostics["sceneFullRenders"] as? Int, oldFull)
            XCTAssertEqual(f.cropRequests, oldCrops)
            XCTAssertTrue(f.inkBits() == oldBits)
            for index in oldPrepared.indices {
                XCTAssertTrue((f.rows[index]["_nativeInk"] as? NativePDFPreparedInk) === oldPrepared[index])
            }
        }
        XCTAssertNotEqual(try f.pixels(), oldPixels, "The 20 new contacts must actually change rendered pixels")
        let newIDs = f.saved.map(\.mutationID)
        let allMeshes = renderer.meshUploadCount
        f.surface.tool = .init(name: "eraser", style: .init(color: "blue", width: 0.005, opacity: 1))
        let eraser = LocalTouch(point: CGPoint(x: 0.015 * 600, y: 0.84 * 800))
        record { XCTAssertTrue(f.surface.beginPencilGesture(eraser, with: nil)) }
        XCTAssertEqual(f.surface.inputDiagnostics["nativeEraseContact"] as? Bool, true)
        // Four sparse horizontal sweeps connected outside the scene bounds of
        // the objects. This must hit all new V5 rows through segment coverage,
        // not just samples at either end, while leaving the old grid untouched.
        var sweep: [CGPoint] = []
        for row in 0..<4 {
            let y = 0.84 + Double(row) * 0.037
            let endX = row.isMultiple(of: 2) ? 0.985 : 0.015
            if row > 0 { sweep.append(CGPoint(x: (row.isMultiple(of: 2) ? 0.015 : 0.985) * 600, y: y * 800)) }
            sweep.append(CGPoint(x: endX * 600, y: y * 800))
        }
        for (index, point) in sweep.enumerated() {
            eraser.point = point; eraser.time += 0.008
            if index == sweep.count - 1 { record { f.surface.endPencilGesture(eraser, with: nil) } }
            else { record { f.surface.movePencilGesture(eraser, with: nil) } }
        }
        XCTAssertEqual(f.eraseBegins, 1); XCTAssertEqual(f.erases.count, 1)
        XCTAssertEqual(f.erases.first?.compactMap(\.drawingID), newIDs)
        XCTAssertEqual(f.pointerEvents, 0, "Neither native pen nor erase may relay a second JS pointer owner")
        try await f.settled(expectedItems: 203)
        XCTAssertTrue(try f.pixels() == oldPixels, "Erase restores the entire original GPU image without ghosts")
        for _ in 0..<3 {
            let before = f.metal.submittedFrameCount
            f.applyRows(); try await f.settled(after: before)
            XCTAssertTrue(try f.pixels() == oldPixels, "An unchanged authoritative scene cannot resurrect erased ink")
        }
        XCTAssertEqual(renderer.meshUploadCount, allMeshes)
        XCTAssertEqual(renderer.textureUploadCount, oldTextures)
        XCTAssertEqual(f.surface.inputDiagnostics["retainedObjectRasters"] as? Int, oldRasters)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneFullRenders"] as? Int, oldFull)
        XCTAssertEqual(f.cropRequests, oldCrops)
        XCTAssertTrue(f.inkBits() == oldBits); XCTAssertEqual(f.saved.count, 20)
        XCTAssertEqual(f.checkpoints, 0); XCTAssertTrue(f.errors.isEmpty)
        XCTAssertEqual(f.ownership, (0..<21).flatMap { _ in [true, false] })
        let maximum: Double = callbackMS.max() ?? 0
        XCTAssertLessThan(maximum, 100, "Synthetic callback work regressed; this is not physical Pencil latency")
        print("V5 mixed Surface: contacts=20 samples=1920 oldRows=200 objects=3 callbackMaxMS=\(maximum) meshes=\(renderer.meshUploadCount-oldMeshes) extraTextures=\(renderer.textureUploadCount-oldTextures) crops=\(f.cropRequests-oldCrops)")
    }

    private static func wait(timeout: TimeInterval = 10, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let ready = await NativePDFAsynchronousEditTests.poll(timeout: timeout, predicate)
        XCTAssertTrue(ready, "Mixed Surface did not reach the requested state")
        if !ready { throw NSError(domain: "MixedSurfaceTimeout", code: 1) }
    }

    @MainActor private final class Fixture {
        let size = CGSize(width: 600, height: 800)
        let window: UIWindow, previous: UIWindow?, pdf: PDFDocument
        let surface: NativePDFInkSurface, metal: NativePDFMetalInk
        let resolvedImage: UIImage
        var rows: [[String: Any]] = []
        var saved: [NativePDFCompletedStroke] = [], erases: [[NativePDFEraseTarget]] = []
        var errors: [Error] = [], ownership: [Bool] = []
        private let cropCounter: Counter
        var cropRequests: Int { cropCounter.value }
        var checkpoints = 0, eraseBegins = 0, pointerEvents = 0
        init() async throws {
            let counter = Counter(); cropCounter = counter
            try await NativePDFRetainedMixedSurfaceTests.wait(timeout: 3) {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible(); window.layoutIfNeeded()
            let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
            let pdfData = UIGraphicsPDFRenderer(bounds: bounds).pdfData { $0.beginPage() }
            pdf = try XCTUnwrap(PDFDocument(data: pdfData))
            resolvedImage = try Self.makeImage()
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: bounds, navigationRasterRequest: { _ in counter.value += 1 }))
            metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
            surface.retainedInkEnabled = true; surface.nativeErasingEnabled = true
            surface.pdfPage = try XCTUnwrap(pdf.page(at: 0)); surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.tool = .init(name: "pen", style: .init(color: "blue", width: 0.006, opacity: 1))
            surface.imageForObject = { [weak self] object in object["id"] as? String == "mixed-image" ? self?.resolvedImage : nil }
            surface.onFailure = { [weak self] in self?.errors.append($0) }
            surface.onInputOwnership = { [weak self] in self?.ownership.append($0) }
            surface.onPointer = { [weak self] _ in self?.pointerEvents += 1 }
            surface.onCheckpoint = { [weak self] _ in self?.checkpoints += 1 }
            surface.onEraseBegin = { [weak self] in self?.eraseBegins += 1 }
            surface.onErase = { [weak self] targets in
                guard let self else { return }
                self.erases.append(targets)
                let deleted = Set(targets.compactMap { $0.drawingID }.map { Data($0.utf8) })
                self.surface.erasedIdentifiers = targets.flatMap { [$0.drawingID,$0.mutationID].compactMap { $0 } }
                self.rows.removeAll { ($0["id"] as? String).map { deleted.contains(Data($0.utf8)) } ?? false }
                self.applyRows()
            }
            surface.onStroke = { [weak self] stroke in
                guard let self else { return }
                self.saved.append(stroke)
                let points: [[String: Any]] = stroke.points.map { point in
                    var value: [String: Any] = ["x":point.x,"y":point.y,"p":point.p]
                    if let t = point.t { value["t"] = t }; if let tilt = point.tiltX { value["tiltX"] = tilt }; if let tilt = point.tiltY { value["tiltY"] = tilt }
                    return value
                }
                self.rows.append(["id":stroke.mutationID,"clientMutationId":stroke.mutationID,"page":1,"kind":stroke.kind,
                    "data":["inkVersion":stroke.inkVersion,"points":points],
                    "style":["color":stroke.style.color,"width":stroke.style.width,"opacity":stroke.style.opacity]])
                self.applyRows()
            }
            rows = Self.makeRows()
            applyRows()
            window.rootViewController!.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
            try await settled()
        }
        func applyRows() {
            for index in rows.indices where rows[index]["_nativeInk"] == nil && ["ink","highlighter"].contains(rows[index]["kind"] as? String ?? "") {
                guard let prepared = NativePDFObjectRenderer.prepareInk(rows[index], aspect: size.height/size.width) else { XCTFail("Fixture ink must prepare"); return }
                rows[index]["_nativeInk"] = prepared
            }
            surface.applyObjects(objects: rows, visualTokens: rows.map(NativePDFCommittedVisualToken.init))
        }
        func settled(after submission: UInt64? = nil, expectedItems: Int = 203) async throws {
            try await NativePDFRetainedMixedSurfaceTests.wait {
                (submission.map { self.metal.submittedFrameCount > $0 } ?? true) &&
                self.surface.inputDiagnostics["retainedInkActive"] as? Bool == true &&
                self.surface.inputDiagnostics["retainedObjectPreparing"] as? Bool == false &&
                self.surface.inputDiagnostics["frameRequested"] as? Bool == false &&
                self.metal.retainedItems?.count == expectedItems && self.metal.strokes.isEmpty
            }
        }
        func pan(x: CGFloat,y: CGFloat) {
            let base = InkCoordinateMapper.whiteboard(size: size)
            surface.mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(translationX: x,y: y).concatenating(base.canvasToPDF),geometry: base.geometry)
        }
        func pixels() throws -> Data { try XCTUnwrap(metal.renderedPixels(width: 600,height: 800)) }
        func assertRGBA(_ bytes: Data, point: CGPoint, expected: [UInt8], tolerance: Int = 1,
                        file: StaticString = #filePath,line: UInt = #line) {
            assertRGBA(bytes, pixel: CGPoint(x: point.x*600,y: point.y*800),expected: expected,tolerance: tolerance,file: file,line: line)
        }
        func assertRGBA(_ bytes: Data, pixel: CGPoint, expected: [UInt8], tolerance: Int = 1,
                        file: StaticString = #filePath,line: UInt = #line) {
            let offset = (Int(pixel.y)*600+Int(pixel.x))*4
            let actual = [bytes[offset+2],bytes[offset+1],bytes[offset],bytes[offset+3]]
            for i in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[i])-Int(expected[i])),tolerance,"RGBA \(actual) vs \(expected)",file: file,line: line) }
        }
        func inkBits(onlyOriginal: Bool = true) -> [UInt64] {
            rows.filter { !onlyOriginal || ($0["id"] as? String)?.hasPrefix("grid-") == true }.flatMap { row in
                let points = (row["data"] as? [String:Any])?["points"] as? [[String:Any]] ?? []
                return points.flatMap { point in ["x","y","p","t"].compactMap { (point[$0] as? Double)?.bitPattern } }
            }
        }
        func close() {
            surface.onStroke = nil; surface.onCheckpoint = nil; surface.onErase = nil; surface.onEraseBegin = nil
            surface.onPointer = nil; surface.onInputOwnership = nil; surface.onFailure = nil; surface.imageForObject = nil
            surface.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        private final class Counter { var value = 0 }
        private static func makeImage() throws -> UIImage {
            let width = 108,height = 96
            var pixels = [UInt8](repeating: 0,count: width*height*4)
            for offset in stride(from: 0,to: pixels.count,by: 4) {
                pixels[offset] = 90; pixels[offset+1] = 150; pixels[offset+2] = 40; pixels[offset+3] = 255
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try XCTUnwrap(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                space: space,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent))
            return UIImage(cgImage: image)
        }
        private static func makeRows() -> [[String:Any]] {
            var result: [[String:Any]] = []
            for index in 0..<200 {
                let column = Double(index%10), row = Double(index/10)
                let points: [[String:Double]] = (0..<96).map { sample in
                    let t = Double(sample)/95
                    return ["x":0.03+column*0.095+t*0.065,"y":0.035+row*0.026+sin(t*Double.pi*2)*0.004,
                            "p":0.2+t*0.6,"t":Double(sample)*4]
                }
                let marker = index == 199
                let style: [String:Any] = ["color":marker ? "yellow":"blue","width":marker ? 0.012:0.0025,"opacity":marker ? 0.3:0.6]
                result.append(["id":"grid-\(index)","page":1,"kind":marker ? "highlighter":"ink","data":["inkVersion":4,"points":points],"style":style])
            }
            let textBox: [String:Double] = ["x":0.1,"y":0.68,"width":0.18,"height":0.12]
            let imageBox: [String:Double] = ["x":0.4,"y":0.68,"width":0.18,"height":0.12]
            let rectBox: [String:Double] = ["x":0.7,"y":0.68,"width":0.18,"height":0.12]
            result.append(["id":"mixed-text","page":1,"kind":"textbox","data":["box":textBox,"text":"W"],
                "style":["color":"blue","fill":"blue","width":0.004,"opacity":1.0,"fontSizePt":14.0]])
            result.append(["id":"mixed-image","page":1,"kind":"image","data":["box":imageBox],
                "style":["color":"blue","width":0.004,"opacity":1.0]])
            result.append(["id":"mixed-rect","page":1,"kind":"rect","data":["box":rectBox],
                "style":["color":"red","width":0.008,"opacity":0.5]])
            return result
        }
    }
    @MainActor private final class LocalTouch: UITouch {
        var point: CGPoint, time = CACurrentMediaTime(), pressure: CGFloat = 0.5
        init(point: CGPoint) { self.point = point; super.init() }
        override var type: UITouch.TouchType { .pencil }
        override var timestamp: TimeInterval { time }
        override var force: CGFloat { pressure }
        override var maximumPossibleForce: CGFloat { 1 }
        override var altitudeAngle: CGFloat { .pi/2 }
        override func location(in view: UIView?) -> CGPoint { point }
        override func preciseLocation(in view: UIView?) -> CGPoint { point }
        override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
    }
}
