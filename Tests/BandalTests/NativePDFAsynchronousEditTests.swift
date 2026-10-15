import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFAsynchronousEditTests: XCTestCase {
    func testMetadataDeferralDoesNotDrawOrReplaceAcceptedCacheAndDefaultReplayStillWorks() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 192, height: 256))
        let bounds = CGRect(origin: .zero, size: CGSize(width: 192, height: 256))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let paper = UIGraphicsImageRenderer(size: bounds.size, format: format).image { c in
            UIColor.white.setFill(); c.fill(bounds)
        }
        let cache = NativePDFCommittedSceneCache(), rows = Self.rows(8)
        var draws = 0, highlights = 0
        func render(_ values: [[String: Any]], allow: Bool = true) -> UIImage? {
            cache.render(paper: paper, mapper: mapper, bounds: bounds, highlights: [], objects: values,
                mutableObjectStartIndex: values.count, allowFullReplay: allow,
                drawHighlights: { _ in highlights += 1 }, drawObject: { row, context in
                    draws += 1; NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil)
                })
        }
        let original = try XCTUnwrap(render(rows))
        let fullCount = cache.fullRenderCount, originalDraws = draws, originalHighlights = highlights
        let deleted = Array(rows.dropFirst())
        XCTAssertNil(render(deleted, allow: false))
        XCTAssertTrue(cache.deferredFullReplay); XCTAssertEqual(cache.lastRenderMode, "deferred")
        XCTAssertTrue(cache.image === original)
        XCTAssertEqual(cache.fullRenderCount, fullCount); XCTAssertEqual(draws, originalDraws)
        XCTAssertEqual(highlights, originalHighlights); XCTAssertEqual(cache.lastDrawnObjectCount, 0)
        // Deferred classification must not adopt the deleted identities. The
        // still-accepted old scene can be reused exactly, then appended to.
        XCTAssertTrue(render(rows, allow: false) === original)
        XCTAssertFalse(cache.deferredFullReplay); XCTAssertEqual(cache.lastRenderMode, "reuse")
        let appended = rows + [Self.rows(9).last!]
        XCTAssertNotNil(render(appended, allow: false)); XCTAssertEqual(cache.lastRenderMode, "append")
        XCTAssertEqual(cache.lastDrawnObjectCount, 1)
        let actual = try XCTUnwrap(render(deleted))
        XCTAssertEqual(cache.fullRenderCount, fullCount + 1)
        let reference = NativePDFCommittedSceneCache().render(paper: paper, mapper: mapper, bounds: bounds,
            highlights: [], objects: deleted, drawHighlights: { _ in },
            drawObject: { NativePDFObjectRenderer.draw($0, in: $1, mapper: mapper, image: nil) })
        XCTAssertTrue(try Self.pixels(actual.cgImage!) == Self.pixels(XCTUnwrap(reference?.cgImage)))
    }

    func testSettledDeletionInstallsNewTilesOnlyWithSuccessfulReplacementAndKeepsPenLiveWhileCropHeld() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        let originalImage = try XCTUnwrap(f.imageView.image), full = f.fullRenders
        let oldBase = f.baseRevision, submitted = f.metal.submittedFrameCount
        f.surface.tool = f.penTool
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll { f.metal.readyDrawableCount > 0 })
        f.metal.testingFailNextEncoding = true
        f.replace(Array(f.rows.dropFirst()))
        let contact = f.begin()
        // beginInput renders inline. Its injected encoding failure must not
        // clear the old frame or publish a new tile revision prematurely.
        XCTAssertEqual(f.metal.submittedFrameCount, submitted)
        XCTAssertEqual(f.baseRevision, oldBase); XCTAssertTrue(f.imageView.image === originalImage)
        XCTAssertFalse(f.imageView.isHidden)
        XCTAssertEqual(f.metal.pendingInputTiming?.strokeID, contact.id)
        XCTAssertEqual(f.fullRenders, full)
        let installed = await Self.poll(timeout: 5) {
            f.baseRevision != oldBase && f.imageView.isHidden && f.submitted.contains(contact.id) &&
            f.surface.inputDiagnostics["navigationBaseObjects"] as? Int == 199
        }
        XCTAssertTrue(installed, "New tile revision and replacement live frame must succeed before any crop completes")
        XCTAssertGreaterThan(f.gate.requests.count, 0); XCTAssertEqual(f.gate.completed, 0)
        XCTAssertTrue(f.editActive); XCTAssertNil(f.metal.backdrop)
        XCTAssertFalse(f.metal.strokes.isEmpty); XCTAssertEqual(f.fullRenders, full)
        f.move(contact, dx: 18, dy: 7); f.end(contact)
        XCTAssertEqual(f.saved.count, 1); XCTAssertEqual(f.saved[0].points.count, 3)
        try f.assertDurableMatchesSaved()
        try await f.finishAndAssertPixels()
        XCTAssertEqual(f.fullRenders, full)
    }

    func testDeleteUndoStyleAndRapidLatestRejectOldCapturedRasterAndDoNotFreezeDeletedTileBase() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); let initial = f.rows, full = f.fullRenders
        f.replace(Array(initial.dropFirst()))
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.gate.requests.count > 0 && f.imageView.isHidden })
        let obsolete = f.gate.requests.removeFirst()
        let afterDelete = f.baseRevision
        f.replace(initial) // Undo before the old delete crop completes.
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.baseRevision != afterDelete && f.baseObjects == 200 })
        var edited = initial
        edited[7]["style"] = ["color": "red", "width": 0.025, "opacity": 0.37]
        let beforeStyle = f.baseRevision; f.replace(edited)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.baseRevision != beforeStyle })
        edited.swapAt(5, 9)
        let beforeReorder = f.baseRevision; f.replace(edited)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.baseRevision != beforeReorder })
        let beforeLatest = f.baseRevision
        f.replace(Array(edited.dropLast()))
        f.replace(Array(edited.dropFirst(2)))
        let finalRows = Array(edited.dropFirst(3)); f.replace(finalRows)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.baseRevision != beforeLatest && f.baseObjects == finalRows.count })
        let latestBase = f.baseRevision
        try await f.gate.finish(obsolete)
        XCTAssertTrue(f.editActive, "A completed obsolete delete raster must not settle the newer edit")
        XCTAssertEqual(f.baseRevision, latestBase); XCTAssertTrue(f.imageView.isHidden)
        XCTAssertEqual(f.fullRenders, full)
        try await f.finishAndAssertPixels()
        XCTAssertEqual(f.fullRenders, full)
    }

    func testTwoOrderedEstimatedContactsRemainLiveAndDurableDuringHeldEditCrop() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); let full = f.fullRenders
        f.replace(Array(f.rows.dropFirst()))
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.editActive && f.imageView.isHidden })
        let first = f.begin(estimate: 701), location = first.touch.point
        first.touch.estimate = nil; first.touch.expecting = []
        f.move(first, dx: 20, dy: 6); f.end(first)
        XCTAssertEqual(f.saved.count, 0)
        let second = f.begin()
        f.move(second, dx: 13, dy: 9)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.submitted.contains(second.id) })
        XCTAssertEqual(f.gate.completed, 0, "A real live submit must precede any opaque crop result")
        f.end(second)
        XCTAssertEqual(f.saved.count, 0, "Later completion must wait for the earlier estimate")
        let before = try XCTUnwrap(f.checkpoints.first)
        first.touch.point = location; first.touch.estimate = 701
        first.touch.pressure = 0.93; first.touch.expecting = []
        f.surface.updatePencilGestureProperties([first.touch])
        XCTAssertEqual(f.saved.count, 2)
        XCTAssertEqual(f.saved[0].mutationID, before.mutationID)
        XCTAssertEqual(f.saved[0].points.count, 3); XCTAssertEqual(f.saved[1].points.count, 3)
        XCTAssertEqual(f.saved[0].points[0].p, 0.93)
        XCTAssertEqual(f.saved[0].points[0].x.bitPattern, before.points[0].x.bitPattern)
        XCTAssertEqual(f.saved[0].points[0].y.bitPattern, before.points[0].y.bitPattern)
        XCTAssertEqual(f.saved[0].points[0].t?.bitPattern, before.points[0].t?.bitPattern)
        XCTAssertEqual(Array(f.saved[0].points.dropFirst()), Array(before.points.dropFirst()))
        try f.assertDurableMatchesSaved()
        XCTAssertEqual(f.fullRenders, full)
        try await f.finishAndAssertPixels()
        XCTAssertEqual(f.fullRenders, full)
    }

    func testHighlighterWaitsForFreshDestinationWithoutConsumingClockAndFollowingPenUsesCurrentTiles() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); let full = f.fullRenders
        f.replace(Array(f.rows.dropFirst()))
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.imageView.isHidden && f.editActive })
        f.surface.tool = .init(name: "highlighter", style: .init(color: "yellow", width: 0.045, opacity: 0.3))
        let marker = f.begin(setPen: false)
        f.move(marker, dx: 25, dy: 3)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 2) { f.surface.inputDiagnostics["frameRequested"] as? Bool == false })
        XCTAssertFalse(f.submitted.contains(marker.id)); XCTAssertNil(f.metal.backdrop)
        XCTAssertEqual(f.metal.pendingInputTiming?.strokeID, marker.id)
        XCTAssertEqual(f.gate.completed, 0)
        f.end(marker)
        let pen = f.begin(); f.move(pen, dx: 18, dy: -3)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.submitted.contains(pen.id) })
        XCTAssertEqual(f.gate.completed, 0)
        f.end(pen)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        try f.assertDurableMatchesSaved()
        try await f.finishAndAssertPixels()
        XCTAssertEqual(f.fullRenders, full)
    }

    func testFailedFinalWritePreservesFrontAndCorrectedRawCheckpointUntilExplicitFlush() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); let full = f.fullRenders
        f.replace(Array(f.rows.dropFirst()))
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) { f.editActive && f.imageView.isHidden })
        let contact = f.begin(estimate: 902), initialLocation = contact.touch.point
        contact.touch.estimate = nil; contact.touch.expecting = []
        f.move(contact, dx: 15, dy: 4); f.end(contact)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll(timeout: 5) {
            f.baseObjects == 200 && f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        })
        let lastBase = f.baseRevision, lastSubmission = f.metal.submittedFrameCount
        let lastImage = f.imageView.image, checkpoint = try XCTUnwrap(f.checkpoints.first)
        var failures = 0
        f.surface.onFailure = { _ in failures += 1 }
        f.failFinalWrite = true
        contact.touch.point = initialLocation; contact.touch.estimate = 902
        contact.touch.pressure = 0.89; contact.touch.expecting = []
        f.surface.updatePencilGestureProperties([contact.touch])
        XCTAssertEqual(failures, 1); XCTAssertEqual(f.saved.count, 0)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, true)
        NativePDFAsynchronousEditTests.assertTrue(await Self.poll {
            f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        })
        if let captured = f.gate.requests.last { try await f.gate.finish(captured) }
        XCTAssertTrue(f.editActive); XCTAssertEqual(f.baseRevision, lastBase)
        XCTAssertEqual(f.metal.submittedFrameCount, lastSubmission)
        XCTAssertTrue(f.imageView.image === lastImage)
        XCTAssertNil(f.surface.pencilInputTarget(at: CGPoint(x: 90, y: 130)))
        let durable = try XCTUnwrap(try NativePDFJournal(root: f.root)
            .pending(courseID: "async", relativePath: "fixture.pdf").first?.input)
        XCTAssertEqual(durable.clientMutationId, checkpoint.mutationID)
        XCTAssertEqual(durable.data.points[0].p, 0.89)
        XCTAssertEqual(durable.data.points[0].x.bitPattern, checkpoint.points[0].x.bitPattern)
        XCTAssertEqual(durable.data.points[0].y.bitPattern, checkpoint.points[0].y.bitPattern)
        XCTAssertEqual(Array(durable.data.points.dropFirst()), Array(checkpoint.points.dropFirst()))
        f.failFinalWrite = false
        try f.surface.flush()
        XCTAssertEqual(f.saved.count, 1)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, false)
        try f.assertDurableMatchesSaved()
        try await f.finishAndAssertPixels()
        XCTAssertEqual(f.fullRenders, full)
    }

    @MainActor final class Gate {
        var requests: [NativePDFNavigationRasterizer.Request] = []
        var completed = 0
        func finish(_ request: NativePDFNavigationRasterizer.Request) async throws {
            let snapshot = request.snapshot, bounds = request.bounds, scale = request.scale
            let transform = request.transform, prefix = request.stablePrefixCount
            let result = await Task.detached(priority: .userInitiated) {
                autoreleasepool { snapshot.raster(bounds: bounds, scale: scale, canonicalToCanvas: transform, stablePrefixCount: prefix) }
            }.value
            XCTAssertNotNil(result); completed += 1; request.completion(result)
        }
    }
    struct Contact { let id: UInt64; let touch: AsynchronousEditTouch }
    @MainActor final class Fixture {
        let surface: NativePDFInkSurface, metal: NativePDFMetalInk, imageView: UIImageView
        let window: UIWindow, previousWindow: UIWindow?, document: PDFDocument, page: PDFPage
        let gate: Gate, root: URL, journal: NativePDFJournal
        let revision = String(repeating: "a", count: 64)
        var rows: [[String: Any]], tokens: [NativePDFCommittedVisualToken]
        var saved: [NativePDFCompletedStroke] = [], checkpoints: [NativePDFCompletedStroke] = [], submitted: [UInt64] = []
        var failFinalWrite = false
        var sequence: UInt64 = 0
        var fullRenders: Int { surface.inputDiagnostics["sceneFullRenders"] as? Int ?? -1 }
        var editActive: Bool { surface.inputDiagnostics["asynchronousEditDisplayActive"] as? Bool == true }
        var baseRevision: UInt64 { surface.inputDiagnostics["navigationBaseRevision"] as? UInt64 ?? 0 }
        var baseObjects: Int { surface.inputDiagnostics["navigationBaseObjects"] as? Int ?? -1 }
        var penTool: NativePDFInkSurface.Tool { .init(name: "pen", style: .init(color: "blue", width: 0.009, opacity: 0.45)) }
        static func make() async throws -> Fixture {
            NativePDFAsynchronousEditTests.assertTrue(await NativePDFAsynchronousEditTests.poll(timeout: 2) {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            return try Fixture(scene)
        }
        init(_ scene: UIWindowScene) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-async-edit-\(UUID())")
            journal = try NativePDFJournal(root: root)
            let size = CGSize(width: 384, height: 512)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { renderer in
                renderer.beginPage(); renderer.cgContext.setFillColor(UIColor(white: 0.8, alpha: 1).cgColor)
                renderer.cgContext.fill(CGRect(x: 37.25, y: 44.125, width: 180.5, height: 133.75))
            }
            document = try XCTUnwrap(PDFDocument(data: data)); page = try XCTUnwrap(document.page(at: 0))
            previousWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); let controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible()
            let capturedGate = Gate(); gate = capturedGate
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: size),
                navigationRasterRequest: { [weak capturedGate] in capturedGate?.requests.append($0) }))
            metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
            imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            rows = NativePDFAsynchronousEditTests.rows(200); tokens = rows.map(NativePDFCommittedVisualToken.init)
            surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.tool = penTool; surface.applyObjects(objects: rows, visualTokens: tokens)
            surface.onCheckpoint = { [weak self] stroke in try self?.publish(stroke, provisional: true) }
            surface.onStroke = { [weak self] stroke in try self?.publish(stroke, provisional: false) }
            surface.onFailure = { XCTFail("Unexpected Surface failure: \($0)") }
            let prior = metal.onFrameSubmitted
            metal.onFrameSubmitted = { [weak self] in prior?($0); self?.submitted.append($0.strokeID) }
            controller.view.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func settle() async throws {
            NativePDFAsynchronousEditTests.assertTrue(await NativePDFAsynchronousEditTests.poll(timeout: 8) {
                self.imageView.image != nil && !self.imageView.isHidden && !self.editActive &&
                self.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                self.surface.inputDiagnostics["frameRequested"] as? Bool == false
            })
            XCTAssertEqual(gate.requests.count, 0, "Initial full raster remains on the existing path")
            XCTAssertEqual(fullRenders, 1)
        }
        func replace(_ values: [[String: Any]]) {
            rows = values; tokens = rows.map(NativePDFCommittedVisualToken.init)
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func publish(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
            if !provisional, failFinalWrite { throw NativePDFError.invalid("Injected final journal write failure") }
            let input = NativePDFStrokeInput(courseId: "async", relPath: "fixture.pdf", page: 1, kind: stroke.kind,
                data: NativePDFStrokeData(points: stroke.points), style: stroke.style,
                clientMutationId: stroke.mutationID, documentRevision: revision)
            if provisional { try journal.checkpoint(input, documentRevision: revision); checkpoints.append(stroke) }
            else { try journal.append(input, documentRevision: revision); saved.append(stroke) }
            var row = try NativePDFHost.json(input); row["id"] = stroke.mutationID
            if let index = rows.firstIndex(where: { $0["id"] as? String == stroke.mutationID }) { rows[index] = row }
            else { rows.append(row) }
            tokens = rows.map(NativePDFCommittedVisualToken.init)
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func begin(estimate: NSNumber? = nil, setPen: Bool = true) -> Contact {
            if setPen { surface.tool = penTool }
            let touch = AsynchronousEditTouch(point: surface.convert(CGPoint(x: 85, y: 120), to: window))
            touch.estimate = estimate; touch.expecting = estimate == nil ? [] : .force
            sequence += 1
            XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
            return Contact(id: sequence, touch: touch)
        }
        func move(_ contact: Contact, dx: CGFloat, dy: CGFloat) {
            contact.touch.point.x += dx; contact.touch.point.y += dy
            contact.touch.time = ProcessInfo.processInfo.systemUptime; contact.touch.touchPhase = .moved
            surface.movePencilGesture(contact.touch, with: nil)
        }
        func end(_ contact: Contact) {
            contact.touch.time = ProcessInfo.processInfo.systemUptime; contact.touch.touchPhase = .ended
            surface.endPencilGesture(contact.touch, with: nil)
        }
        func assertDurableMatchesSaved() throws {
            let recovered = try NativePDFJournal(root: root).pending(courseID: "async", relativePath: "fixture.pdf")
            XCTAssertEqual(recovered.map { $0.input.clientMutationId }, saved.map(\.mutationID))
            XCTAssertEqual(recovered.map { $0.input.data.points }, saved.map(\.points))
            for (record, stroke) in zip(recovered, saved) {
                for (a, b) in zip(record.input.data.points, stroke.points) {
                    XCTAssertEqual(a.x.bitPattern, b.x.bitPattern); XCTAssertEqual(a.y.bitPattern, b.y.bitPattern)
                    XCTAssertEqual(a.p.bitPattern, b.p.bitPattern); XCTAssertEqual(a.t?.bitPattern, b.t?.bitPattern)
                    XCTAssertEqual(a.tiltX?.bitPattern, b.tiltX?.bitPattern); XCTAssertEqual(a.tiltY?.bitPattern, b.tiltY?.bitPattern)
                }
            }
        }
        func finishAndAssertPixels() async throws {
            await Task.yield()
            NativePDFAsynchronousEditTests.assertTrue(await NativePDFAsynchronousEditTests.poll(timeout: 5) {
                let revision = self.surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64
                return self.gate.requests.last?.snapshot.revision == revision && self.baseRevision == revision && self.baseObjects == self.rows.count
            })
            let latest = try XCTUnwrap(gate.requests.last); gate.requests.removeAll()
            try await gate.finish(latest)
            NativePDFAsynchronousEditTests.assertTrue(await NativePDFAsynchronousEditTests.poll(timeout: 8) {
                !self.editActive && self.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                !self.imageView.isHidden && self.metal.strokes.isEmpty &&
                self.surface.inputDiagnostics["frameRequested"] as? Bool == false
            })
            let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
            let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
                for row in self.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
            }?.cgImage)
            let actual = try XCTUnwrap(imageView.image?.cgImage)
            XCTAssertEqual(actual.width, reference.width); XCTAssertEqual(actual.height, reference.height)
            let a = try NativePDFAsynchronousEditTests.pixels(actual), b = try NativePDFAsynchronousEditTests.pixels(reference)
            XCTAssertTrue(a == b, "Asynchronous edited scene must match independent full PDF+object replay exactly")
        }
        func close() {
            surface.onStroke = nil; surface.onCheckpoint = nil; surface.onFailure = nil
            gate.requests.removeAll(); window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKeyAndVisible(); try? FileManager.default.removeItem(at: root)
        }
    }
    static func rows(_ count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            let points: [[String: Double]] = (0..<37).map { sample in
                let t = Double(sample) / 36
                return ["x": 0.04+t*0.90, "y": 0.08+Double(index%20)*0.042+sin(t*6.28)*0.018,
                    "p": 0.1+0.8*t, "t": Double(sample*4)]
            }
            return ["id": "old-\(index)", "clientMutationId": "old-\(index)", "page": 1,
                "kind": index.isMultiple(of: 7) ? "highlighter" : "ink", "data": ["inkVersion": 4, "points": points],
                "style": ["color": index.isMultiple(of: 7) ? "yellow" : "blue", "width": index.isMultiple(of: 7) ? 0.024 : 0.003,
                    "opacity": index.isMultiple(of: 7) ? 0.24 : 0.45]]
        }
    }
    static func assertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    static func poll(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
    static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width*image.height*4)
    }
}

final class AsynchronousEditTouch: UITouch {
    var point: CGPoint, time = ProcessInfo.processInfo.systemUptime
    var touchPhase: UITouch.Phase = .began, pressure: CGFloat = 0.4
    var estimate: NSNumber?, expecting: UITouch.Properties = []
    init(point: CGPoint) { self.point = point; super.init() }
    override var type: UITouch.TouchType { .pencil }
    override var phase: UITouch.Phase { touchPhase }
    override var timestamp: TimeInterval { time }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi/2 }
    override var estimationUpdateIndex: NSNumber? { estimate }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: view?.window) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
