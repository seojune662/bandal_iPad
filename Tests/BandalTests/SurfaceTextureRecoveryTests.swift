import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

/// Real Surface scheduling and durability with an injected Metal texture loader.
/// Submission/image checks do not claim physical Pencil presentation latency.
@MainActor
final class SurfaceTextureRecoveryTests: XCTestCase {
    func testTwoUploadFailuresPauseGeometryAndRecoverLatestMeasuredInput() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        f.probe.failuresRemaining = 2
        let contact = f.begin("highlighter")
        XCTAssertEqual(f.state, "waiting"); XCTAssertEqual(f.probe.uploads.count, 1)
        XCTAssertFalse(f.frameRequested); XCTAssertTrue(f.retryScheduled)
        let firstPending = try XCTUnwrap(f.metal.pendingInputTiming)
        let revision = f.geometryRevision, acquisitions = f.probe.acquisitions.count
        let submitted = f.metal.submittedFrameCount
        for _ in 0..<100 { f.move(contact, dx: 0.25, dy: 0.04) }
        // No await: only genuine input delivery occurs here. It may dirty the
        // latest stroke but cannot create per-sample GPU or texture work.
        XCTAssertEqual(f.probe.uploads.count, 1)
        XCTAssertEqual(f.geometryRevision, revision)
        XCTAssertEqual(f.probe.acquisitions.count, acquisitions)
        XCTAssertEqual(f.metal.submittedFrameCount, submitted)
        XCTAssertFalse(f.frameRequested); XCTAssertTrue(f.retryScheduled)
        let resumed = await Self.poll(timeout: 2) { f.submissions.contains { $0.strokeID == contact.id } }
        XCTAssertTrue(resumed)
        XCTAssertEqual(f.probe.uploads.count, 3)
        let times = f.probe.uploads.map(\.time)
        if times.count == 3 {
            XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.049)
            XCTAssertGreaterThanOrEqual(times[2] - times[1], 0.199)
        }
        XCTAssertEqual(Set(f.probe.uploads.map(\.image)).count, 1)
        XCTAssertEqual(f.state, "ready"); XCTAssertFalse(f.retryScheduled)
        XCTAssertTrue(f.failures.isEmpty)
        let firstSubmission = try XCTUnwrap(f.submissions.first { $0.strokeID == contact.id })
        XCTAssertEqual(firstSubmission.firstInputAt, firstPending.firstInputAt,
            "Recovery must retain the original oldest input clock")
        XCTAssertGreaterThan(f.geometryRevision, revision)
        f.end(contact)
        XCTAssertEqual(f.saved.count, 1); XCTAssertEqual(f.saved[0].points.count, 102)
        try f.verifyJournal()
        try await f.settleAndVerifyPixels()
    }

    func testExhaustionIdlesOnceWhileEstimatedPointsStillCheckpointAndClear() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        f.probe.alwaysFail = true
        let contact = f.begin("highlighter", estimate: 71), firstPoint = contact.touch.point
        contact.touch.estimate = nil; contact.touch.expecting = []
        let exhausted = await Self.poll(timeout: 2) { f.state == "exhausted" }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(f.probe.uploads.count, 3); XCTAssertEqual(f.failures.count, 1)
        XCTAssertFalse(f.frameRequested); XCTAssertFalse(f.retryScheduled)
        let revision = f.geometryRevision, acquisitions = f.probe.acquisitions.count
        for _ in 0..<40 { f.move(contact, dx: 0.4, dy: 0.05) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(f.probe.uploads.count, 3); XCTAssertEqual(f.failures.count, 1)
        XCTAssertEqual(f.geometryRevision, revision)
        XCTAssertEqual(f.probe.acquisitions.count, acquisitions)
        XCTAssertFalse(f.frameRequested); XCTAssertFalse(f.retryScheduled)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, false)

        f.end(contact)
        XCTAssertEqual(f.checkpoints.count, 1); XCTAssertTrue(f.saved.isEmpty)
        XCTAssertEqual(f.checkpoints[0].points.count, 42)
        let originalTime = f.checkpoints[0].points[0].t
        let clearReady = await Self.poll {
            f.imageView.image !== f.lastEndImage && !f.imageView.isHidden &&
                f.metal.strokes.isEmpty && !f.frameRequested
        }
        XCTAssertTrue(clearReady, "A committed checkpoint can install via clear without the failed live texture")
        XCTAssertEqual(f.probe.uploads.count, 3)
        // Correct the original estimated point after lift. It must survive
        // terminal display failure, retaining its measured time and ordering.
        contact.touch.point = firstPoint; contact.touch.estimate = 71
        contact.touch.pressure = 0.91; contact.touch.expecting = []
        f.surface.updatePencilGestureProperties([contact.touch])
        XCTAssertEqual(f.saved.count, 1); XCTAssertEqual(f.saved[0].points.count, 42)
        XCTAssertEqual(f.saved[0].points[0].p, 0.91)
        XCTAssertEqual(f.saved[0].points[0].t, originalTime)
        XCTAssertEqual(f.failures.count, 1)
        try f.verifyJournal()
        try await f.settleAndVerifyPixels()
        let pen = f.begin("pen"); f.move(pen, dx: 12, dy: 3)
        let penReady = await Self.poll { f.submissions.contains { $0.strokeID == pen.id } }
        XCTAssertTrue(penReady, "A plain pen after the installed clear needs no failed texture")
        XCTAssertEqual(f.probe.uploads.count, 3)
        XCTAssertNil(f.metal.backdrop)
        f.end(pen); try f.verifyJournal(); try await f.settleAndVerifyPixels()
    }

    func testNewBackdropAfterTerminalFailureGetsFreshBudgetWithoutDuplicateNotification() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        f.probe.alwaysFail = true
        let first = f.begin("highlighter")
        let exhausted = await Self.poll(timeout: 2) { f.state == "exhausted" }
        XCTAssertTrue(exhausted)
        let failedImage = try XCTUnwrap(f.metal.backdrop)
        // Equivalent object refresh is allowed one dependency review but must
        // not reset the same image's three-attempt budget or repeat the error.
        for _ in 0..<5 {
            let beforeReview = try XCTUnwrap(f.surface.inputDiagnostics["renderAttempts"] as? Int)
            f.publishRows()
            // This is a bounded functional state wait, not a latency target.
            // An elapsed 5 ms does not guarantee a UIUpdateLink phase occurred.
            let reviewedAndIdle = await Self.poll(timeout: 2) {
                (f.surface.inputDiagnostics["renderAttempts"] as? Int ?? beforeReview) > beforeReview &&
                    f.state == "exhausted" && !f.frameRequested && !f.retryScheduled
            }
            XCTAssertTrue(reviewedAndIdle,
                "The refreshed dependency must be reviewed and return to terminal idle within 2 seconds; " +
                "diagnostics=\(f.surface.inputDiagnostics)")
        }
        XCTAssertTrue(f.metal.backdrop === failedImage)
        XCTAssertEqual(f.probe.uploads.count, 3); XCTAssertEqual(f.failures.count, 1)
        XCTAssertFalse(f.frameRequested)
        XCTAssertFalse(f.retryScheduled)

        // Once that actual review has completed, no input or dependency changes
        // occur during this observation interval. A retry/render loop must fail.
        let idleUploads = f.probe.uploads.count, idleAcquisitions = f.probe.acquisitions.count
        let idleGeometry = f.geometryRevision
        let idleAttempts = try XCTUnwrap(f.surface.inputDiagnostics["renderAttempts"] as? Int)
        let idleWakes = try XCTUnwrap(f.surface.inputDiagnostics["backdropRetryWakeCount"] as? Int)
        let idleGeneration = f.metal.backdropRecoveryGeneration
        let idleSubmissions = f.metal.submittedFrameCount
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(f.probe.uploads.count, idleUploads)
        XCTAssertEqual(f.probe.acquisitions.count, idleAcquisitions)
        XCTAssertEqual(f.geometryRevision, idleGeometry)
        XCTAssertEqual(f.surface.inputDiagnostics["renderAttempts"] as? Int, idleAttempts)
        XCTAssertEqual(f.surface.inputDiagnostics["backdropRetryWakeCount"] as? Int, idleWakes)
        XCTAssertEqual(f.metal.backdropRecoveryGeneration, idleGeneration)
        XCTAssertEqual(f.metal.submittedFrameCount, idleSubmissions)
        XCTAssertEqual(f.failures.count, 1)
        XCTAssertTrue(f.metal.backdrop === failedImage)
        XCTAssertEqual(f.state, "exhausted")
        XCTAssertFalse(f.frameRequested)
        XCTAssertFalse(f.retryScheduled)
        f.end(first); try await f.settleAndVerifyPixels()
        f.probe.alwaysFail = false
        let second = f.begin("highlighter")
        let ready = await Self.poll { f.submissions.contains { $0.strokeID == second.id } }
        XCTAssertTrue(ready)
        XCTAssertEqual(f.probe.uploads.count, 4)
        XCTAssertNotEqual(f.probe.uploads.last?.image, ObjectIdentifier(failedImage))
        XCTAssertEqual(f.failures.count, 1)
        f.end(second); try f.verifyJournal(); try await f.settleAndVerifyPixels()
    }

    func testNavigationFailedHighlighterKeepsFollowingPenOrderedUntilUrgentCrop() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); try await f.navigateAndHoldCrop()
        f.probe.failuresRemaining = 1
        let highlighter = f.begin("highlighter")
        XCTAssertEqual(f.state, "waiting")
        XCTAssertTrue(f.holdCrop); XCTAssertEqual(f.cropCount, f.cropCountAtHold)
        XCTAssertFalse(f.submissions.contains { $0.strokeID == highlighter.id })
        f.end(highlighter)
        let pen = f.begin("pen")
        // No run-loop turn has allowed the new crop to arrive. The following
        // pen must not use transparent fallback over the missing H suffix.
        XCTAssertFalse(f.submissions.contains { $0.strokeID == pen.id })
        XCTAssertEqual(f.probe.uploads.count, 1)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter"])
        let restored = await Self.poll(timeout: 5) {
            f.cropCount > f.cropCountAtHold && f.submissions.contains { $0.strokeID == pen.id }
        }
        XCTAssertTrue(restored, "Exact new crop must recover even while navigation remains active")
        XCTAssertTrue(f.holdCrop)
        f.move(pen, dx: 16, dy: 4); f.end(pen)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        XCTAssertEqual(f.rows.compactMap { $0["kind"] as? String }, ["highlighter", "ink"])
        try f.verifyJournal(); try await f.settleAndVerifyPixels()
    }

    func testStationaryOutsideCropHighlighterRecoversWithoutAnotherInputEvent() async throws {
        let f = try await Fixture.make(pageSize: CGSize(width: 768, height: 1024)); defer { f.close() }
        try await f.settle()
        let oldCrop = try XCTUnwrap(f.surface.renderViewport).canvasRect
        try await f.navigateAndHoldCrop(outside: true)
        let newCrop = try XCTUnwrap(f.surface.renderViewport).canvasRect
        XCTAssertFalse(oldCrop.intersects(newCrop))
        f.probe.failFirstImageOnly = true
        let contact = f.begin("highlighter")
        XCTAssertFalse(oldCrop.contains(contact.touch.preciseLocation(in: f.surface)))
        XCTAssertEqual(f.probe.uploads.count, 1); XCTAssertEqual(f.state, "waiting")
        let restored = await Self.poll(timeout: 5) {
            f.cropCount > f.cropCountAtHold && f.submissions.contains { $0.strokeID == contact.id }
        }
        XCTAssertTrue(restored, "First-point failure must request its exact new crop without a move or lift")
        XCTAssertTrue(f.holdCrop); XCTAssertEqual(contact.touch.touchPhase, .began)
        XCTAssertTrue(f.metal.convert(f.metal.bounds, to: f.surface).contains(contact.touch.preciseLocation(in: f.surface)))
        XCTAssertEqual(Set(f.probe.uploads.map(\.image)).count, 2)
        XCTAssertTrue(f.failures.isEmpty)
        f.end(contact); try f.verifyJournal(); try await f.settleAndVerifyPixels()
    }

    func testNavigationAlwaysFailingUploadSettlesToOneNewCropAndTerminalIdle() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); try await f.navigateAndHoldCrop()
        f.probe.alwaysFail = true
        let contact = f.begin("highlighter")
        let stopped = await Self.poll(timeout: 5) { !f.navigating && f.state == "exhausted" }
        XCTAssertTrue(stopped)
        let count = f.probe.uploads.count, cropCount = f.cropCount
        XCTAssertEqual(cropCount, f.cropCountAtHold + 1,
            "A failed retained image permits one exact crop, not an endless sequence of fresh-image budgets")
        XCTAssertEqual(Set(f.probe.uploads.map(\.image)).count, 2)
        XCTAssertLessThanOrEqual(count, 6)
        let currentImage = try XCTUnwrap(f.probe.uploads.last?.image)
        XCTAssertEqual(f.probe.uploads.filter { $0.image == currentImage }.count, 3)
        let errors = f.failures.count
        XCTAssertFalse(f.frameRequested); XCTAssertFalse(f.retryScheduled)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(f.cropCount, cropCount); XCTAssertEqual(f.probe.uploads.count, count)
        XCTAssertEqual(f.failures.count, errors)
        f.end(contact); try f.verifyJournal(); try await f.settleAndVerifyPixels()
    }

    func testDetachCancelsOldWakeAndNewPageDoesNotReceiveItsErrorOrInputClock() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle()
        f.probe.alwaysFail = true
        _ = f.begin("highlighter")
        XCTAssertEqual(f.state, "waiting"); XCTAssertTrue(f.retryScheduled)
        f.surface.removeFromSuperview()
        XCTAssertFalse(f.retryScheduled); XCTAssertFalse(f.frameRequested)
        XCTAssertEqual(f.saved.count, 1, "Detachment must still durably finish measured ink")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(f.probe.uploads.count, 1); XCTAssertTrue(f.failures.isEmpty)
        XCTAssertEqual(f.surface.inputDiagnostics["backdropRetryWakeCount"] as? Int, 0)

        f.probe.alwaysFail = false
        let newPage = try XCTUnwrap(PDFPage(image: UIGraphicsImageRenderer(size: f.surface.bounds.size).image { r in
            UIColor.cyan.setFill(); r.fill(f.surface.bounds)
        }))
        f.page = newPage; f.rows = []; f.tokens = []
        f.surface.pdfPage = newPage; f.publishRows()
        f.holder.addSubview(f.surface); f.surface.layoutIfNeeded(); f.surface.refreshViewport()
        try await f.settle()
        let contact = f.begin("highlighter")
        let original = try XCTUnwrap(f.metal.pendingInputTiming ?? f.metal.lastSubmittedFrame.map {
            NativePDFMetalInk.InputTiming(strokeID: $0.strokeID, firstInputAt: $0.firstInputAt, latestInputAt: $0.latestInputAt)
        })
        let submitted = await Self.poll { f.submissions.contains { $0.strokeID == contact.id } }
        XCTAssertTrue(submitted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(f.probe.uploads.count, 2); XCTAssertTrue(f.failures.isEmpty)
        XCTAssertFalse(f.retryScheduled)
        XCTAssertEqual(f.submissions.first { $0.strokeID == contact.id }?.firstInputAt, original.firstInputAt)
        f.end(contact); try await f.settleAndVerifyPixels()
    }

    @MainActor private final class UploadProbe {
        struct Upload { let image: ObjectIdentifier; let time: CFTimeInterval }
        var failuresRemaining = 0, alwaysFail = false, failFirstImageOnly = false
        private var firstFailedImage: ObjectIdentifier?
        var uploads: [Upload] = []
        let acquisitions = AcquisitionCounter()
        func load(_ device: MTLDevice, _ image: CGImage) throws -> MTLTexture {
            uploads.append(.init(image: ObjectIdentifier(image), time: CACurrentMediaTime()))
            if failFirstImageOnly, firstFailedImage == nil { firstFailedImage = ObjectIdentifier(image) }
            if alwaysFail || failuresRemaining > 0 || (failFirstImageOnly && firstFailedImage == ObjectIdentifier(image)) {
                if failuresRemaining > 0 { failuresRemaining -= 1 }
                throw TestFailure.upload
            }
            return try MTKTextureLoader(device: device).newTexture(cgImage: image,
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
        }
    }
    private final class AcquisitionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func acquire(_ layer: CAMetalLayer) -> CAMetalDrawable? {
            lock.lock(); value += 1; lock.unlock()
            return layer.nextDrawable()
        }
    }
    private enum TestFailure: Error { case upload, inactiveScene, notSettled }
    private struct Contact { let id: UInt64; let touch: RecoveryTouch }
    @MainActor private final class Fixture {
        let window: UIWindow, controller: UIViewController, holder: UIView, previous: UIWindow?
        let surface: NativePDFInkSurface, metal: NativePDFMetalInk, imageView: UIImageView
        let document: PDFDocument, root: URL, journal: NativePDFJournal
        var page: PDFPage
        let probe: UploadProbe
        var rows: [[String: Any]] = [], tokens: [NativePDFCommittedVisualToken] = []
        var saved: [NativePDFCompletedStroke] = [], checkpoints: [NativePDFCompletedStroke] = []
        var submissions: [NativePDFMetalInk.FrameTiming] = [], failures: [String] = []
        var holdCrop = false, sequence: UInt64 = 0
        var lastEndImage: UIImage?, lastEndSubmitted: UInt64 = 0, cropCountAtHold = 0
        var state: String { surface.inputDiagnostics["backdropRecoveryState"] as? String ?? "unknown" }
        var frameRequested: Bool { surface.inputDiagnostics["frameRequested"] as? Bool == true }
        var retryScheduled: Bool { surface.inputDiagnostics["backdropRetryScheduled"] as? Bool == true }
        var geometryRevision: UInt64 { surface.inputDiagnostics["previewGeometryRevision"] as? UInt64 ?? 0 }
        var cropCount: Int { surface.inputDiagnostics["navigationAsyncRasterCount"] as? Int ?? -1 }
        var navigating: Bool { surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true }
        static func make(pageSize: CGSize = CGSize(width: 384, height: 512)) async throws -> Fixture {
            let active = await SurfaceTextureRecoveryTests.poll(timeout: 2) {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            }
            guard active, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { throw TestFailure.inactiveScene }
            return try Fixture(scene: scene, pageSize: pageSize)
        }
        private init(scene: UIWindowScene, pageSize: CGSize) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("surface-texture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            journal = try NativePDFJournal(root: root)
            let size = pageSize
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { r in
                r.beginPage(); r.cgContext.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
                r.cgContext.fill(CGRect(x: 40, y: 30, width: 15, height: 180))
                r.cgContext.setFillColor(UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).cgColor)
                r.cgContext.fill(CGRect(x: 85, y: 65, width: 120, height: 100))
            }
            document = try XCTUnwrap(PDFDocument(data: pdf)); page = try XCTUnwrap(document.page(at: 0))
            probe = UploadProbe()
            let probe = probe, counter = probe.acquisitions
            metal = try XCTUnwrap(NativePDFMetalInk(drawableAcquirer: { counter.acquire($0) },
                textureLoader: { try probe.load($0, $1) }))
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: size), renderer: metal))
            imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene); controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible()
            holder = UIView(frame: CGRect(x: 20, y: 20, width: 230, height: 240)); holder.clipsToBounds = true
            controller.view.addSubview(holder)
            surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.viewportProvider = { [weak surface, weak holder] in
                guard let surface, let holder else { return nil }; return surface.convert(holder.bounds, from: holder)
            }
            surface.navigationInProgress = { [weak self] in self?.holdCrop ?? false }
            surface.onStroke = { [weak self] stroke in try self?.persist(stroke, provisional: false) }
            surface.onCheckpoint = { [weak self] stroke in try self?.persist(stroke, provisional: true) }
            surface.onFailure = { [weak self] in self?.failures.append(String(describing: $0)) }
            let original = metal.onFrameSubmitted
            metal.onFrameSubmitted = { [weak self] in original?($0); self?.submissions.append($0) }
            holder.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func settle() async throws {
            let ready = await SurfaceTextureRecoveryTests.poll(timeout: 5) {
                !self.navigating && !self.imageView.isHidden && self.imageView.image != nil &&
                    self.metal.strokes.isEmpty && !self.frameRequested &&
                    self.metal.readyDrawableCount > 0 && self.metal.pendingDrawableRequestCount == 0
            }
            XCTAssertTrue(ready, "Initial real Surface must settle with a ready drawable")
            guard ready else { throw TestFailure.notSettled }
        }
        func publishRows() { surface.applyObjects(objects: rows, visualTokens: tokens) }
        private func persist(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
            let input = NativePDFStrokeInput(courseId: "texture", relPath: "paper.pdf", page: 1,
                kind: stroke.kind, data: .init(points: stroke.points), style: stroke.style,
                clientMutationId: stroke.mutationID, documentRevision: "test-revision")
            if provisional { try journal.checkpoint(input, documentRevision: "test-revision"); checkpoints.append(stroke) }
            else { try journal.append(input, documentRevision: "test-revision"); saved.append(stroke) }
            var row = try XCTUnwrap(DesktopJSON.decode(JSONEncoder().encode(input)) as? [String: Any])
            row["id"] = stroke.mutationID
            if let index = rows.firstIndex(where: { $0["id"] as? String == stroke.mutationID }) {
                rows[index] = row; tokens[index] = NativePDFCommittedVisualToken(object: row)
            } else { rows.append(row); tokens.append(NativePDFCommittedVisualToken(object: row)) }
            publishRows()
        }
        func verifyJournal() throws {
            let records = try journal.pending(courseID: "texture", relativePath: "paper.pdf")
            for stroke in saved {
                let record = try XCTUnwrap(records.first { $0.input.clientMutationId == stroke.mutationID })
                XCTAssertEqual(record.input.data.points, stroke.points)
                XCTAssertEqual(record.input.style, stroke.style)
                XCTAssertEqual(record.input.kind, stroke.kind)
                XCTAssertFalse(record.provisional == true)
            }
        }
        func begin(_ tool: String, estimate: NSNumber? = nil) -> Contact {
            surface.tool = .init(name: tool, style: .init(color: tool == "highlighter" ? "yellow" : "blue",
                width: tool == "highlighter" ? 0.045 : 0.009, opacity: 0.45))
            let rect = surface.renderViewport!
            let touch = RecoveryTouch(point: surface.convert(CGPoint(x: rect.canvasRect.minX + 65,
                y: rect.canvasRect.minY + 85), to: window))
            touch.estimate = estimate; touch.expecting = estimate == nil ? [] : .force
            XCTAssertTrue(surface.beginPencilGesture(touch, with: nil)); sequence += 1
            return Contact(id: sequence, touch: touch)
        }
        func move(_ contact: Contact, dx: CGFloat, dy: CGFloat) {
            contact.touch.point.x += dx; contact.touch.point.y += dy
            contact.touch.time += 0.001; contact.touch.touchPhase = .moved
            surface.movePencilGesture(contact.touch, with: nil)
        }
        func end(_ contact: Contact) {
            contact.touch.point.x += 1; contact.touch.time += 0.001; contact.touch.touchPhase = .ended
            surface.endPencilGesture(contact.touch, with: nil)
            lastEndImage = imageView.image; lastEndSubmitted = metal.submittedFrameCount
        }
        func navigateAndHoldCrop(outside: Bool = false) async throws {
            holdCrop = true; cropCountAtHold = cropCount
            surface.frame.origin = outside ? CGPoint(x: -24, y: -600) : CGPoint(x: -30, y: -35)
            surface.refreshViewport(); surface.layoutIfNeeded()
            let ready = await SurfaceTextureRecoveryTests.poll {
                self.navigating && !self.frameRequested && self.metal.readyDrawableCount > 0
            }
            XCTAssertTrue(ready); XCTAssertEqual(cropCount, cropCountAtHold)
        }
        func settleAndVerifyPixels() async throws {
            holdCrop = false
            let ready = await SurfaceTextureRecoveryTests.poll(timeout: 5) {
                !self.navigating && !self.imageView.isHidden && self.imageView.image != nil &&
                    self.metal.strokes.isEmpty && !self.frameRequested &&
                    (self.lastEndImage == nil || (self.imageView.image !== self.lastEndImage &&
                        self.metal.submittedFrameCount > self.lastEndSubmitted))
            }
            XCTAssertTrue(ready, "Canonical image/clear must replace the retained preview")
            guard ready else { return }
            let mapper = try XCTUnwrap(surface.mapper), viewport = try XCTUnwrap(surface.renderViewport)
            let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
                    for row in self.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
                }?.cgImage)
            let actual = try XCTUnwrap(imageView.image?.cgImage)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try SurfaceTextureRecoveryTests.pixels(actual), try SurfaceTextureRecoveryTests.pixels(expected))
            XCTAssertFalse(retryScheduled)
            lastEndImage = nil
        }
        func close() {
            holdCrop = false; try? surface.flush(); surface.removeFromSuperview()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: root)
        }
    }
    private static func poll(timeout: TimeInterval = 2, _ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate(), CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return predicate()
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }
}

@MainActor private final class RecoveryTouch: UITouch {
    var point: CGPoint, time = ProcessInfo.processInfo.systemUptime
    var touchPhase: UITouch.Phase = .began, pressure: CGFloat = 0.5
    var estimate: NSNumber?, expecting: UITouch.Properties = []
    init(point: CGPoint) { self.point = point; super.init() }
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { time }
    override var phase: UITouch.Phase { touchPhase }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { estimate }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: view?.window) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
