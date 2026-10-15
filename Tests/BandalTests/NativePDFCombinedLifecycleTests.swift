import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

/// Combined production input/cache/Metal paths with controlled asynchronous
/// crop completion. Synthetic input does not prove hardware arbitration or
/// that every CATiledLayer pixel is ready when its revision is installed.
@MainActor
final class NativePDFCombinedLifecycleTests: XCTestCase {
    func testExhaustedHighlighterThenDeleteUnblocksPenWithoutReusingFailedDestination() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        let initialFull = f.fullRenders
        f.loader.alwaysFail = true
        let marker = f.begin(tool: "highlighter")
        let originalClock = try XCTUnwrap(f.metal.pendingInputTiming)
        try await require { f.recoveryState == "exhausted" }
        XCTAssertEqual(f.loader.uploads.count, 3); XCTAssertEqual(f.failures.count, 1)
        XCTAssertFalse(f.frameRequested); XCTAssertFalse(f.retryScheduled)
        XCTAssertFalse(f.submissions.contains { $0.strokeID == marker.id })
        let failedImage = try XCTUnwrap(f.metal.backdrop)

        f.replace(Array(f.rows.dropFirst()))
        try await require {
            f.editActive && f.imageView.isHidden && f.baseCount == 199 &&
                f.recoveryState == "notRequired" && !f.retryScheduled && !f.frameRequested &&
                !f.gate.requests.isEmpty
        }
        XCTAssertEqual(f.gate.completed, 0); XCTAssertFalse(f.gate.requests.isEmpty)
        XCTAssertNil(f.metal.backdrop)
        XCTAssertEqual(f.loader.uploads.count, 3)
        XCTAssertEqual(f.loader.uploads.filter { $0 == ObjectIdentifier(failedImage) }.count, 3)
        XCTAssertEqual(f.failures.count, 1)
        XCTAssertEqual(f.metal.pendingInputTiming?.strokeID, marker.id)
        XCTAssertEqual(f.metal.pendingInputTiming?.firstInputAt, originalClock.firstInputAt)
        XCTAssertFalse(f.submissions.contains { $0.strokeID == marker.id },
            "Replacing the edited tile base is not a highlighter submission")
        XCTAssertEqual(f.fullRenders, initialFull)

        f.move(marker, dx: 15, dy: 4); f.end(marker)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter"])
        let pen = f.begin(tool: "pen")
        f.move(pen, dx: 22, dy: 6)
        try await require { f.submissions.contains { $0.strokeID == pen.id } }
        XCTAssertEqual(f.gate.completed, 0, "The following pen must submit before the held exact crop")
        XCTAssertNil(f.metal.backdrop); XCTAssertEqual(f.loader.uploads.count, 3)
        XCTAssertFalse(f.retryScheduled); XCTAssertEqual(f.failures.count, 1)
        XCTAssertEqual(f.recoveryState, "notRequired")
        f.end(pen)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        try f.assertJournalExactly()
        try await f.finishLatestCropAndAssertPixels()
        XCTAssertEqual(f.fullRenders, initialFull)
        XCTAssertEqual(f.loader.uploads.count, 3); XCTAssertEqual(f.failures.count, 1)
    }

    func testHeldEditCropAndSamePageNavigationPreserveEstimatedSamplesAndOrderedCompletion() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); let initialFull = f.fullRenders
        f.replace(Array(f.rows.dropFirst()))
        try await require { f.editActive && f.imageView.isHidden && !f.gate.requests.isEmpty }
        let stale = try XCTUnwrap(f.gate.requests.last)
        let oldViewport = try XCTUnwrap(f.surface.renderViewport)
        let oldMapper = try XCTUnwrap(f.surface.mapper)

        let first = f.begin(tool: "pen", estimate: 811)
        let originalPoint = f.expectedPoint(first.touch, start: first.touch.time)
        let firstWindowPoint = first.touch.point
        try await require { f.submissions.contains { $0.strokeID == first.id } }
        XCTAssertEqual(f.gate.completed, 0)
        try f.surface.prepareForNavigation()
        XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertEqual(f.ownership.last, true, "Finger navigation cannot release the active Pencil")

        var nextMapper = oldMapper
        nextMapper.canvasToPDF.tx += 19
        nextMapper.canvasToPDF.ty -= 23
        f.surface.frame.origin = CGPoint(x: -14, y: -17)
        f.surface.mapper = nextMapper
        f.surface.refreshViewport()
        XCTAssertNotEqual(f.surface.mapper?.canvasToPDF, oldMapper.canvasToPDF)
        XCTAssertNotEqual(f.surface.renderViewport, oldViewport)
        XCTAssertTrue(f.saved.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertEqual(f.ownership.last, true)
        try await f.gate.finish(stale)
        XCTAssertTrue(f.editActive, "A raster captured before the changed mapper/crop must be rejected")
        XCTAssertTrue(f.imageView.isHidden)
        XCTAssertEqual(f.fullRenders, initialFull)

        // This later sample uses the new mapper, while the original unresolved
        // force sample keeps the old canonical position/time/tilt bits.
        first.touch.estimate = nil; first.touch.expecting = []
        f.move(first, dx: 27, dy: 11)
        let expectedLater = f.expectedPoint(first.touch, start: first.startedAt)
        f.end(first)
        let before = try XCTUnwrap(f.checkpoints.first)
        XCTAssertEqual(before.points.count, 3)
        XCTAssertTrue(f.saved.isEmpty)
        if before.points.count == 3 {
            Self.assertBits(before.points[0], originalPoint)
            Self.assertBits(before.points[1], expectedLater)
        }
        let second = f.begin(tool: "pen")
        f.move(second, dx: 17, dy: 5)
        try await require { f.submissions.contains { $0.strokeID == second.id } }
        f.end(second)
        XCTAssertTrue(f.saved.isEmpty, "The later contact must not overtake an earlier unresolved force")
        XCTAssertEqual(f.checkpoints.count, 2)
        let orderedIDs = f.checkpoints.prefix(2).map(\.mutationID)
        let untouchedSecond = try XCTUnwrap(f.checkpoints.last?.points)
        try f.surface.prepareForNavigation()
        XCTAssertTrue(f.saved.isEmpty)

        first.touch.point = CGPoint(x: firstWindowPoint.x + 90, y: firstWindowPoint.y + 70)
        first.touch.estimate = 811; first.touch.expecting = []
        first.touch.pressure = 0.91; first.touch.altitude = 0.2; first.touch.azimuth = 1.1
        f.surface.updatePencilGestureProperties([first.touch])
        XCTAssertEqual(f.saved.map(\.mutationID), orderedIDs)
        XCTAssertEqual(f.saved.count, 2)
        if f.saved.count == 2 {
            let after = f.saved[0].points
            XCTAssertEqual(after.count, before.points.count)
            var correctedExpected = before.points[0]; correctedExpected.p = 0.91
            Self.assertBits(after[0], correctedExpected)
            for (a, b) in zip(after.dropFirst(), before.points.dropFirst()) { Self.assertBits(a, b) }
            for (a, b) in zip(f.saved[1].points, untouchedSecond) { Self.assertBits(a, b) }
        }
        XCTAssertFalse(f.surface.inputDiagnostics["journalBlocked"] as? Bool ?? true)
        XCTAssertTrue(f.failures.isEmpty); XCTAssertEqual(f.loader.uploads.count, 0)
        try f.assertJournalExactly()
        try await f.finishLatestCropAndAssertPixels()
        XCTAssertEqual(f.fullRenders, initialFull)
    }

    private enum TestFailure: Error { case upload, inactiveScene, timeout }
    @MainActor private final class Loader {
        var alwaysFail = false
        var uploads: [ObjectIdentifier] = []
        func load(_ device: MTLDevice, _ image: CGImage) throws -> MTLTexture {
            uploads.append(ObjectIdentifier(image))
            if alwaysFail { throw TestFailure.upload }
            return try MTKTextureLoader(device: device).newTexture(cgImage: image,
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
        }
    }
    @MainActor private final class Gate {
        var requests: [NativePDFNavigationRasterizer.Request] = []
        var completed = 0
        func finish(_ request: NativePDFNavigationRasterizer.Request) async throws {
            let snapshot = request.snapshot, bounds = request.bounds, scale = request.scale
            let transform = request.transform, prefix = request.stablePrefixCount
            let output = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    snapshot.raster(bounds: bounds, scale: scale,
                        canonicalToCanvas: transform, stablePrefixCount: prefix)
                }
            }.value
            let raster = try XCTUnwrap(output)
            completed += 1; request.completion(raster)
        }
    }
    private struct Contact {
        let id: UInt64
        let touch: CombinedLifecycleTouch
        let startedAt: TimeInterval
    }
    @MainActor private final class Fixture {
        let window: UIWindow, previous: UIWindow?, holder: UIView
        let surface: NativePDFInkSurface, metal: NativePDFMetalInk, imageView: UIImageView
        let document: PDFDocument, page: PDFPage
        let loader: Loader, gate: Gate
        let root: URL, journal: NativePDFJournal
        static let course = "combined-lifecycle", path = "synthetic.pdf"
        static let documentRevision = String(repeating: "b", count: 64)
        var rows: [[String: Any]], tokens: [NativePDFCommittedVisualToken]
        var saved: [NativePDFCompletedStroke] = [], checkpoints: [NativePDFCompletedStroke] = []
        var failures: [String] = [], ownership: [Bool] = []
        var submissions: [NativePDFMetalInk.FrameTiming] = []
        var sequence: UInt64 = 0
        var fullRenders: Int { surface.inputDiagnostics["sceneFullRenders"] as? Int ?? -1 }
        var editActive: Bool { surface.inputDiagnostics["asynchronousEditDisplayActive"] as? Bool == true }
        var baseCount: Int { surface.inputDiagnostics["navigationBaseObjects"] as? Int ?? -1 }
        var baseRevision: UInt64 { surface.inputDiagnostics["navigationBaseRevision"] as? UInt64 ?? 0 }
        var currentRevision: UInt64 { surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64 ?? 0 }
        var frameRequested: Bool { surface.inputDiagnostics["frameRequested"] as? Bool == true }
        var retryScheduled: Bool { surface.inputDiagnostics["backdropRetryScheduled"] as? Bool == true }
        var recoveryState: String { surface.inputDiagnostics["backdropRecoveryState"] as? String ?? "missingDiagnostic" }

        static func make() async throws -> Fixture {
            let deadline = CACurrentMediaTime() + 2
            while CACurrentMediaTime() < deadline {
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }) { return try Fixture(scene: scene) }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw TestFailure.inactiveScene
        }
        private init(scene: UIWindowScene) throws {
            let size = CGSize(width: 384, height: 512)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("combined-ink-\(UUID())")
            journal = try NativePDFJournal(root: root)
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { renderer in
                renderer.beginPage()
                renderer.cgContext.setFillColor(UIColor(white: 0.75, alpha: 1).cgColor)
                renderer.cgContext.fill(CGRect(x: 33.25, y: 41.5, width: 173.75, height: 127.5))
            }
            document = try XCTUnwrap(PDFDocument(data: pdf)); page = try XCTUnwrap(document.page(at: 0))
            let capturedLoader = Loader(), capturedGate = Gate()
            loader = capturedLoader; gate = capturedGate
            metal = try XCTUnwrap(NativePDFMetalInk(textureLoader: { try capturedLoader.load($0, $1) }))
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: size), renderer: metal,
                navigationRasterRequest: { [weak capturedGate] in capturedGate?.requests.append($0) }))
            imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            let controller = UIViewController(); window.rootViewController = controller
            window.makeKeyAndVisible()
            holder = UIView(frame: CGRect(x: 20, y: 20, width: 300, height: 400)); holder.clipsToBounds = true
            controller.view.addSubview(holder)
            rows = try Self.syntheticRows(count: 200); tokens = rows.map(NativePDFCommittedVisualToken.init)
            surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.viewportProvider = { [weak surface, weak holder] in
                guard let surface, let holder else { return nil }
                return surface.convert(holder.bounds, from: holder)
            }
            surface.onStroke = { [weak self] in try self?.persist($0, provisional: false) }
            surface.onCheckpoint = { [weak self] in try self?.persist($0, provisional: true) }
            surface.onFailure = { [weak self] in self?.failures.append(String(describing: $0)) }
            surface.onInputOwnership = { [weak self] in self?.ownership.append($0) }
            let previousSubmission = metal.onFrameSubmitted
            metal.onFrameSubmitted = { [weak self] in previousSubmission?($0); self?.submissions.append($0) }
            surface.applyObjects(objects: rows, visualTokens: tokens)
            holder.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func settle() async throws {
            try await NativePDFCombinedLifecycleTests.wait {
                self.imageView.image != nil && !self.imageView.isHidden && !self.editActive &&
                    self.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                    !self.frameRequested && self.metal.readyDrawableCount > 0
            }
            XCTAssertEqual(fullRenders, 1); XCTAssertTrue(gate.requests.isEmpty)
        }
        func replace(_ values: [[String: Any]]) {
            rows = values; tokens = values.map(NativePDFCommittedVisualToken.init)
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func begin(tool: String, estimate: NSNumber? = nil) -> Contact {
            let color = tool == "highlighter" ? "yellow" : "blue"
            let style = NativePDFInkStyle(color: color, width: tool == "highlighter" ? 0.045 : 0.009, opacity: 0.45)
            surface.tool = .init(name: tool, style: style)
            let viewport = surface.renderViewport!.canvasRect
            let local = CGPoint(x: viewport.minX + 80, y: viewport.minY + 110)
            let touch = CombinedLifecycleTouch(point: surface.convert(local, to: window), window: window)
            touch.estimate = estimate; touch.expecting = estimate == nil ? [] : .force
            sequence += 1
            XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
            return Contact(id: sequence, touch: touch, startedAt: touch.time)
        }
        func move(_ contact: Contact, dx: CGFloat, dy: CGFloat) {
            contact.touch.point.x += dx; contact.touch.point.y += dy
            contact.touch.time += 0.001; contact.touch.touchPhase = .moved
            surface.movePencilGesture(contact.touch, with: nil)
        }
        func end(_ contact: Contact) {
            contact.touch.time += 0.001; contact.touch.touchPhase = .ended
            surface.endPencilGesture(contact.touch, with: nil)
        }
        func expectedPoint(_ touch: CombinedLifecycleTouch, start: TimeInterval) -> NativePDFPoint {
            let location = touch.preciseLocation(in: surface)
            let p = Double(touch.pressure)
            let point = surface.mapper!.normalized(location, pressure: p)
            let altitude = max(Double(touch.altitude), 0.001), angle = Double(touch.azimuth)
            return NativePDFPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)), p: p,
                t: max(0, (touch.time - start) * 1000),
                tiltX: atan(cos(angle) / tan(altitude)) * 180 / .pi,
                tiltY: atan(sin(angle) / tan(altitude)) * 180 / .pi)
        }
        private func persist(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
            let data = NativePDFStrokeData(points: stroke.points)
            let input = NativePDFStrokeInput(courseId: Self.course, relPath: Self.path, page: 1, kind: stroke.kind,
                data: data, style: stroke.style, clientMutationId: stroke.mutationID, documentRevision: Self.documentRevision)
            try input.validate()
            if provisional { try journal.checkpoint(input, documentRevision: Self.documentRevision); checkpoints.append(stroke) }
            else { try journal.append(input, documentRevision: Self.documentRevision); saved.append(stroke) }
            var row = try NativePDFHost.json(input); row["id"] = stroke.mutationID
            if let index = rows.firstIndex(where: { $0["clientMutationId"] as? String == stroke.mutationID }) {
                rows[index] = row; tokens[index] = NativePDFCommittedVisualToken(object: row)
            } else { rows.append(row); tokens.append(NativePDFCommittedVisualToken(object: row)) }
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func assertJournalExactly() throws {
            let records = try NativePDFJournal(root: root).pending(courseID: Self.course, relativePath: Self.path)
            XCTAssertEqual(records.map { $0.input.clientMutationId }, saved.map(\.mutationID))
            XCTAssertEqual(records.count, saved.count)
            for (record, stroke) in zip(records, saved) {
                XCTAssertEqual(record.input.kind, stroke.kind); XCTAssertEqual(record.input.style, stroke.style)
                XCTAssertFalse(record.provisional == true)
                XCTAssertEqual(record.input.data.points.count, stroke.points.count)
                for (a, b) in zip(record.input.data.points, stroke.points) { NativePDFCombinedLifecycleTests.assertBits(a, b) }
            }
        }
        func finishLatestCropAndAssertPixels() async throws {
            try await NativePDFCombinedLifecycleTests.wait {
                guard let request = self.gate.requests.last, let viewport = self.surface.renderViewport,
                      let mapper = self.surface.mapper else { return false }
                return request.snapshot.revision == self.currentRevision && self.baseRevision == self.currentRevision &&
                    self.baseCount == self.rows.count && request.bounds == viewport.canvasRect &&
                    request.transform == NativePDFObjectRenderer.pageTransform(mapper)
            }
            let request = try XCTUnwrap(gate.requests.last)
            gate.requests.removeAll(); try await gate.finish(request)
            try await NativePDFCombinedLifecycleTests.wait {
                !self.editActive && self.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                    !self.imageView.isHidden && self.metal.strokes.isEmpty && !self.frameRequested
            }
            let mapper = try XCTUnwrap(surface.mapper), viewport = try XCTUnwrap(surface.renderViewport)
            let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
                    for row in self.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
                }?.cgImage)
            let image = try XCTUnwrap(imageView.image?.cgImage)
            XCTAssertEqual(image.width, reference.width); XCTAssertEqual(image.height, reference.height)
            let actual = try NativePDFCombinedLifecycleTests.pixels(image)
            let expected = try NativePDFCombinedLifecycleTests.pixels(reference)
            XCTAssertTrue(actual == expected, "Final display must equal independent full PDF + ordered object RGBA")
            XCTAssertFalse(retryScheduled)
        }
        func close() {
            surface.onStroke = nil; surface.onCheckpoint = nil; surface.onFailure = nil
            gate.requests.removeAll(); surface.removeFromSuperview()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: root)
        }
        private static func syntheticRows(count: Int) throws -> [[String: Any]] {
            var output: [[String: Any]] = []
            for index in 0..<count {
                var points: [NativePDFPoint] = []
                for sample in 0..<37 {
                    let t = Double(sample) / 36
                    let x = 0.04 + t * 0.9
                    let y = 0.08 + Double(index % 20) * 0.042 + sin(t * 6.28) * 0.018
                    points.append(NativePDFPoint(x: x, y: y, p: 0.1 + 0.8 * t, t: Double(sample * 4)))
                }
                let marker = index.isMultiple(of: 7)
                let style = NativePDFInkStyle(color: marker ? "yellow" : "blue", width: marker ? 0.024 : 0.003,
                    opacity: marker ? 0.24 : 0.45)
                let mutation = String(format: "00000000-0000-4000-8000-%012d", index + 1)
                let input = NativePDFStrokeInput(courseId: course, relPath: path, page: 1, kind: marker ? "highlighter" : "ink",
                    data: NativePDFStrokeData(points: points), style: style, clientMutationId: mutation,
                    documentRevision: documentRevision)
                try input.validate()
                var row = try NativePDFHost.json(input); row["id"] = mutation
                output.append(row)
            }
            return output
        }
    }
    private func require(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                         _ predicate: @escaping @MainActor () -> Bool) async throws {
        do { try await Self.wait(timeout: timeout, predicate) }
        catch { XCTFail("Combined lifecycle state did not become ready", file: file, line: line); throw error }
    }
    private static func wait(timeout: TimeInterval = 8, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard predicate() else { throw TestFailure.timeout }
    }
    private static func assertBits(_ actual: NativePDFPoint, _ expected: NativePDFPoint,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x.bitPattern, expected.x.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.y.bitPattern, expected.y.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.p.bitPattern, expected.p.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.t?.bitPattern, expected.t?.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.tiltX?.bitPattern, expected.tiltX?.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.tiltY?.bitPattern, expected.tiltY?.bitPattern, file: file, line: line)
    }
    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}

@MainActor private final class CombinedLifecycleTouch: UITouch {
    var point: CGPoint, time = ProcessInfo.processInfo.systemUptime
    weak var containingWindow: UIWindow?
    var touchPhase: UITouch.Phase = .began, pressure: CGFloat = 0.4
    var altitude: CGFloat = .pi / 3, azimuth: CGFloat = .pi / 4
    var estimate: NSNumber?, expecting: UITouch.Properties = []
    init(point: CGPoint, window: UIWindow) { self.point = point; containingWindow = window; super.init() }
    override var window: UIWindow? { containingWindow }
    override var type: UITouch.TouchType { .pencil }
    override var phase: UITouch.Phase { touchPhase }
    override var timestamp: TimeInterval { time }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { altitude }
    override var estimationUpdateIndex: NSNumber? { estimate }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: containingWindow) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { azimuth }
}
