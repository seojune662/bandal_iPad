import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Actual Surface -> update scheduler -> Metal regression coverage. Crop work is
/// held through the same navigationInProgress callback used by the PDF host.
/// Submission and view-placement assertions do not claim physical presentation.
@MainActor
final class NativePDFNavigationHighlighterTests: XCTestCase {
    func testControlOrdinaryPenSubmitsBeforeCropAfterPanAndZoom() async throws {
        for motion in Motion.allCases {
            let f = try await Fixture.make(); defer { f.close() }
            try await f.settle()
            try await f.navigateAndHoldCrop(motion)
            let contact = f.begin(tool: "pen")
            let submitted = await Self.poll { f.submissions.contains { $0.timing.strokeID == contact.id } }
            XCTAssertTrue(submitted, "Control must have a functioning drawable and first-dot path: \(motion)")
            XCTAssertTrue(f.isNavigating)
            XCTAssertEqual(f.cropCount, f.cropCountAtHold, "No full crop can explain this first live frame")
            XCTAssertTrue(f.submissions.last?.multiplyFlags == [false])
            XCTAssertFalse(f.submissions.last?.hasBackdrop ?? true)
            f.end(contact)
            try await f.releaseCropAndVerifyFinalScene()
        }
    }

    func testFirstHighlighterAfterPanAndZoomMustSubmitBeforeBackgroundCrop() async throws {
        for motion in Motion.allCases {
            let f = try await Fixture.make(); defer { f.close() }
            try await f.settle()
            try await f.navigateAndHoldCrop(motion)
            let attemptsBefore = f.renderAttempts
            let contact = f.begin(tool: "highlighter")
            let submittedBeforeCrop = await Self.poll { f.submissions.contains { $0.timing.strokeID == contact.id } }
            XCTAssertGreaterThan(f.renderAttempts, attemptsBefore, "The real Surface render path must have been entered")
            XCTAssertTrue(f.isNavigating)
            XCTAssertEqual(f.cropCount, f.cropCountAtHold)
            XCTAssertFalse(f.surface.inputDiagnostics["journalBlocked"] as? Bool ?? true)
            // EXPECTED RED: contains(multiply) returns before updating Metal,
            // reaching its submitFrame(). append() already starts the input clock.
            XCTAssertTrue(submittedBeforeCrop,
                "Accepted highlighter must submit while crop remains outstanding; this is not a drawable timeout")
            f.record("first-highlighter-before-crop", contact: contact)

            // Keep Pencil down while allowing the crop. This separates an
            // absent pre-crop submission from broken persistence/final output.
            f.holdCrop = false
            let eventuallySubmitted = await Self.poll(timeout: 5) {
                !f.isNavigating && f.submissions.contains { $0.timing.strokeID == contact.id }
            }
            XCTAssertTrue(eventuallySubmitted, "Current source should recover only after its opaque crop exists")
            f.move(contact, dx: 16, dy: 4)
            f.end(contact)
            try await f.releaseCropAndVerifyFinalScene()
        }
    }

    func testUnadoptedHighlighterAlsoBlocksFollowingPenAndKeepsCorrectionOrder() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); try await f.navigateAndHoldCrop(.pan)
        let highlighter = f.begin(tool: "highlighter", estimatedIndex: 501)
        let estimatedLocation = highlighter.touch.point
        // Keep the first sample unresolved while later measured samples form
        // a real crossing stroke rather than replacing the same estimate.
        highlighter.touch.estimate = nil; highlighter.touch.expecting = []
        f.move(highlighter, dx: 28, dy: 4)
        f.end(highlighter)
        XCTAssertEqual(f.rows.last?["kind"] as? String, "highlighter", "The provisional row must enter the actual frozen-base suffix")
        XCTAssertEqual(f.saved.count, 0, "An unresolved pressure estimate is only checkpointed")
        highlighter.touch.point = estimatedLocation; highlighter.touch.estimate = 501
        highlighter.touch.pressure = 0.91; highlighter.touch.expecting = []
        f.surface.updatePencilGestureProperties([highlighter.touch])
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter"])
        XCTAssertTrue(f.saved.first?.points.contains { $0.p == 0.91 } == true)
        // Changing Surface.tool deliberately flushes estimates, so resolve
        // this estimate before selecting pen instead of inventing an ordering
        // state that the actual tool-switch contract cannot retain.

        let pen = f.begin(tool: "pen")
        f.move(pen, dx: 16, dy: -3)
        let penSubmittedBeforeCrop = await Self.poll { f.submissions.contains { $0.timing.strokeID == pen.id } }
        XCTAssertTrue(f.isNavigating); XCTAssertEqual(f.cropCount, f.cropCountAtHold)
        // EXPECTED RED independently of the first highlighter: the suffix
        // contains multiply even though the currently selected tool is pen.
        XCTAssertTrue(penSubmittedBeforeCrop,
            "A completed highlighter must not suppress the following ordinary pen while the crop is outstanding")
        f.record("following-pen-before-crop", contact: pen)
        f.end(pen)
        XCTAssertEqual(f.rows.suffix(2).compactMap { $0["kind"] as? String }, ["highlighter", "ink"])
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        XCTAssertTrue(f.saved.first?.points.contains { $0.p == 0.91 } == true)
        try await f.releaseCropAndVerifyFinalScene()
    }

    func testSubmittedOpaqueHighlighterCannotKeepAnUnchangedDrawableOnNewGeometry() async throws {
        for motion in Motion.allCases {
            let f = try await Fixture.make(); defer { f.close() }
            try await f.settle()
            let contact = f.begin(tool: "highlighter")
            let initialReady = await Self.poll { f.submissions.contains { $0.timing.strokeID == contact.id && $0.hasBackdrop } }
            XCTAssertTrue(initialReady)
            let old = try XCTUnwrap(f.submissions.last(where: { $0.timing.strokeID == contact.id && $0.hasBackdrop }))
            let countBefore = f.metal.submittedFrameCount
            let oldViewport = try XCTUnwrap(f.surface.renderViewport)
            try await f.navigateAndHoldCrop(motion)
            XCTAssertNotEqual(f.surface.renderViewport, oldViewport)
            XCTAssertTrue(f.imageView.isHidden, "The frozen tiled base, not the settled UIImage, now owns the page")
            XCTAssertTrue(f.isNavigating)
            let replaced = await Self.poll { f.metal.submittedFrameCount > countBefore }

            // Evaluate the actual UIView placement of the already submitted
            // texture. A future fix may keep its old bounds/transform and
            // reproject it without submitting another drawable. Do not demand
            // a new frame if that placement correctly retains the old anchor.
            let oldTextureAnchor = try XCTUnwrap(old.firstLocalVertex)
            let normalized = CGPoint(x: (oldTextureAnchor.x - old.bounds.minX) / old.bounds.width,
                                     y: (oldTextureAnchor.y - old.bounds.minY) / old.bounds.height)
            let nowLocal = CGPoint(x: f.metal.bounds.minX + normalized.x * f.metal.bounds.width,
                                   y: f.metal.bounds.minY + normalized.y * f.metal.bounds.height)
            let nowCanvas = f.metal.convert(nowLocal, to: f.surface)
            let oldCanvas = try XCTUnwrap(old.firstCanvasVertex)
            let anchorError = hypot(nowCanvas.x - oldCanvas.x, nowCanvas.y - oldCanvas.y)
            // EXPECTED RED for an active highlighter: refreshViewport changes
            // the visible Metal frame but the multiply guard submits nothing.
            let replacementKeepsInk = replaced && !f.metal.strokes.isEmpty
            let retainedPlacementKeepsInk = !f.metal.isHidden && f.metal.alpha > 0 && anchorError <= 1 / 1024
            XCTAssertTrue(replacementKeepsInk || retainedPlacementKeepsInk,
                "Old opaque frame requires replacement or valid reprojection; anchor error=\(anchorError) canvas points")
            f.record("opaque-frame-after-motion", contact: contact,
                extra: ["replacementSubmitted": replaced, "oldAnchorDisplacement": anchorError,
                        "oldGeometryWasOpaque": old.hasBackdrop])
            // This assertion establishes a submission/placement failure only.
            // It deliberately does NOT claim a CAMetalLayer front-buffer pixel
            // was observed; the display-pixel probe/hook is described in README.
            f.holdCrop = false
            let cropAdopted = await Self.poll(timeout: 5) { !f.isNavigating }
            XCTAssertTrue(cropAdopted)
            f.end(contact)
            try await f.releaseCropAndVerifyFinalScene()
        }
    }

    func testSuccessiveHeldViewportsSettleOnlyToLatestCropWithOrderedInk() async throws {
        let f = try await Fixture.make(); defer { f.close() }
        try await f.settle(); try await f.navigateAndHoldCrop(.pan)
        let h = f.begin(tool: "highlighter"); f.move(h, dx: 30, dy: 0); f.end(h)
        let p = f.begin(tool: "pen"); f.move(p, dx: 22, dy: 4); f.end(p)
        let intermediate = f.surface.renderViewport
        f.surface.frame.origin.x -= 24; f.surface.refreshViewport()
        let latest = try XCTUnwrap(f.surface.renderViewport)
        XCTAssertNotEqual(latest, intermediate)
        XCTAssertEqual(f.cropCount, f.cropCountAtHold)
        try await f.releaseCropAndVerifyFinalScene()
        XCTAssertEqual(f.surface.renderViewport, latest)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        // This exercises latest *queued* capture. It does not pretend to test
        // rejection of an already-running obsolete crop; that requires the
        // deterministic completion barrier proposed in README.
    }

    func testFirstHighlighterAndFollowingPenOutsideOldCropRequestDestinationDuringNavigation() async throws {
        let f = try await Fixture.make(pageSize: CGSize(width: 768, height: 1024)); defer { f.close() }
        try await f.settle()
        let oldCrop = try XCTUnwrap(f.surface.renderViewport).canvasRect
        try await f.navigateOutsideOldCrop()
        let newCrop = try XCTUnwrap(f.surface.renderViewport).canvasRect
        XCTAssertFalse(oldCrop.intersects(newCrop), "The fixture must not reuse covered pixels from the old crop")

        let highlighter = f.begin(tool: "highlighter")
        let firstPoint = highlighter.touch.preciseLocation(in: f.surface)
        XCTAssertFalse(oldCrop.contains(firstPoint)); XCTAssertTrue(newCrop.contains(firstPoint))
        f.move(highlighter, dx: 45, dy: 6)
        let firstSubmitted = await Self.poll(timeout: 5) {
            f.cropCount > f.cropCountAtHold && f.submissions.contains { $0.timing.strokeID == highlighter.id }
        }
        XCTAssertTrue(firstSubmitted, "Newly exposed highlighter must obtain its destination while navigation remains active and Pencil stays down")
        XCTAssertTrue(f.holdCrop, "Urgent input work must bypass the host's navigation quiet gate")
        XCTAssertGreaterThan(f.cropCount, f.cropCountAtHold)
        XCTAssertEqual(highlighter.touch.touchPhase, .moved, "No lift may trigger the first live submission")
        XCTAssertTrue(f.metal.convert(f.metal.bounds, to: f.surface).contains(firstPoint),
            "A submitted old-crop drawable clipped away from the new input does not satisfy live coverage")
        XCTAssertTrue(f.submissions.last(where: { $0.timing.strokeID == highlighter.id })?.hasBackdrop == true)
        f.end(highlighter)

        let pen = f.begin(tool: "pen")
        f.move(pen, dx: 32, dy: -8)
        let followingSubmitted = await Self.poll { f.submissions.contains { $0.timing.strokeID == pen.id } }
        XCTAssertTrue(followingSubmitted, "The outside-crop highlighter must not block the following pen")
        XCTAssertTrue(f.holdCrop)
        f.end(pen)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink"])
        XCTAssertEqual(f.rows.compactMap { $0["kind"] as? String }, ["highlighter", "ink"])
        try await f.releaseCropAndVerifyFinalScene()
    }

    func testCorrectedHighlighterUndoAndNewContactPreserveCanonicalOrderOutsideOldCrop() async throws {
        let f = try await Fixture.make(pageSize: CGSize(width: 768, height: 1024)); defer { f.close() }
        try await f.settle(); try await f.navigateOutsideOldCrop()
        let highlighter = f.begin(tool: "highlighter", estimatedIndex: 801)
        let estimatedLocation = highlighter.touch.point
        highlighter.touch.estimate = nil; highlighter.touch.expecting = []
        f.move(highlighter, dx: 45, dy: 6); f.end(highlighter)
        XCTAssertEqual(f.saved.count, 0)
        XCTAssertEqual(f.rows.count, 1, "Provisional stroke must remain visible while its force is unresolved")
        let highlighterID = try XCTUnwrap(f.rows.first?["id"] as? String)
        highlighter.touch.point = estimatedLocation; highlighter.touch.estimate = 801
        highlighter.touch.pressure = 0.91; highlighter.touch.expecting = []
        f.surface.updatePencilGestureProperties([highlighter.touch])
        XCTAssertEqual(f.saved.count, 1)
        XCTAssertEqual(f.saved[0].points.first?.p, 0.91)
        XCTAssertEqual(f.rows.first?["id"] as? String, highlighterID)

        let pen = f.begin(tool: "pen"); f.move(pen, dx: 32, dy: -8); f.end(pen)
        XCTAssertEqual(f.rows.compactMap { $0["kind"] as? String }, ["highlighter", "ink"])
        let penID = try XCTUnwrap(f.rows.last?["id"] as? String)
        // Undo the latest contact, as the host's canonical snapshot does.
        // The earlier corrected highlighter must retain its exact pressure.
        f.removeRow(id: penID)
        XCTAssertEqual(f.rows.compactMap { $0["id"] as? String }, [highlighterID])
        let replacement = f.begin(tool: "pen"); f.move(replacement, dx: 40, dy: 2)
        let submitted = await Self.poll(timeout: 5) { f.submissions.contains { $0.timing.strokeID == replacement.id } }
        XCTAssertTrue(submitted, "Undo must remove the old pen without blocking its replacement behind a corrected highlighter")
        XCTAssertTrue(f.holdCrop)
        f.end(replacement)
        XCTAssertEqual(f.saved.map(\.kind), ["highlighter", "ink", "ink"])
        XCTAssertEqual(f.saved.map { $0.points.count }, [3, 3, 3], "Undo cannot discard or rewrite already captured measured samples")
        XCTAssertEqual(f.rows.compactMap { $0["kind"] as? String }, ["highlighter", "ink"])
        XCTAssertEqual(f.rows.first?["id"] as? String, highlighterID)
        XCTAssertFalse(f.rows.contains { $0["id"] as? String == penID })
        XCTAssertEqual(f.saved[0].points.first?.p, 0.91)
        try await f.releaseCropAndVerifyFinalScene()
    }

    func testUndoFrozenBaseHighlighterBeforeNewlyExposedInputDoesNotReuseRemovedInk() async throws {
        let f = try await Fixture.make(pageSize: CGSize(width: 768, height: 1024)); defer { f.close() }
        let originalID = "frozen-base-highlighter"
        f.appendCommittedRow([
            "id": originalID, "clientMutationId": originalID, "kind": "highlighter",
            "data": ["inkVersion": 4, "points": [
                ["x": 0.12, "y": 0.67, "p": 0.5], ["x": 0.24, "y": 0.69, "p": 0.8]]],
            "style": ["color": "yellow", "width": 0.045, "opacity": 0.45]])
        try await f.settle()
        try await f.navigateOutsideOldCrop()
        f.removeRow(id: originalID)
        XCTAssertTrue(f.rows.isEmpty)
        let replacement = f.begin(tool: "highlighter"); f.move(replacement, dx: 45, dy: 6)
        let submitted = await Self.poll(timeout: 5) {
            f.cropCount > f.cropCountAtHold && f.submissions.contains { $0.timing.strokeID == replacement.id }
        }
        XCTAssertTrue(submitted, "An invalidated frozen prefix must obtain a new destination without waiting for finger navigation to stop")
        XCTAssertTrue(f.holdCrop)
        XCTAssertEqual(replacement.touch.touchPhase, .moved)
        f.end(replacement)
        XCTAssertEqual(f.rows.count, 1)
        XCTAssertFalse(f.rows.contains { $0["id"] as? String == originalID })
        try await f.releaseCropAndVerifyFinalScene()
    }

    enum Motion: String, CaseIterable { case pan, zoom }
    struct Contact { let id: UInt64; let touch: NavigationHighlighterTestTouch }
    struct Submitted {
        let timing: NativePDFMetalInk.FrameTiming
        let multiplyFlags: [Bool]
        let hasBackdrop: Bool
        let bounds: CGRect
        let firstLocalVertex: CGPoint?
        let firstCanvasVertex: CGPoint?
    }
    enum SetupError: Error { case inactiveScene, rendererNotReady, notSettled }

    @MainActor
    final class Fixture {
        let window: UIWindow, controller: UIViewController, holder: UIView
        let surface: NativePDFInkSurface, metal: NativePDFMetalInk, imageView: UIImageView
        let document: PDFDocument, page: PDFPage
        let previousWindow: UIWindow?
        var rows: [[String: Any]] = [], tokens: [NativePDFCommittedVisualToken] = []
        var saved: [NativePDFCompletedStroke] = [], submissions: [Submitted] = []
        var holdCrop = false, nextContact: UInt64 = 0
        var cropCountAtHold = 0
        var lastEnd: (image: UIImage?, submitted: UInt64, requiresNewImage: Bool)?
        var isNavigating: Bool { surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true }
        var cropCount: Int { surface.inputDiagnostics["navigationAsyncRasterCount"] as? Int ?? -1 }
        var renderAttempts: Int { surface.inputDiagnostics["renderAttempts"] as? Int ?? -1 }

        static func make(pageSize: CGSize = CGSize(width: 384, height: 512)) async throws -> Fixture {
            let ready = await NativePDFNavigationHighlighterTests.poll(timeout: 2) { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
            guard ready, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { throw SetupError.inactiveScene }
            return try Fixture(scene: scene, pageSize: pageSize)
        }
        private init(scene: UIWindowScene, pageSize: CGSize) throws {
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { r in
                r.beginPage();r.cgContext.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
                r.cgContext.fill(CGRect(x: 32, y: 40, width: 17, height: 140))
                r.cgContext.setFillColor(UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1).cgColor)
                r.cgContext.fill(CGRect(x: 100, y: 80, width: 120, height: 55))
                if pageSize.height > 512 {
                    // A newly revealed region has its own colored destination;
                    // a stale top-of-page texture cannot accidentally look right.
                    r.cgContext.setFillColor(UIColor(red: 0.55, green: 0.25, blue: 0.75, alpha: 1).cgColor)
                    r.cgContext.fill(CGRect(x: 48, y: 640, width: 150, height: 110))
                    r.cgContext.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
                    r.cgContext.fill(CGRect(x: 78, y: 620, width: 9, height: 180))
                }
            }
            document = try XCTUnwrap(PDFDocument(data: pdf)); page = try XCTUnwrap(document.page(at: 0))
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene); controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible()
            holder = UIView(frame: CGRect(x: 20, y: 20, width: 230, height: 240)); holder.clipsToBounds = true
            controller.view.addSubview(holder)
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: pageSize)))
            surface.pdfPage = page; surface.mapper = .whiteboard(size: pageSize); surface.isLoading = false
            metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
            imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            surface.viewportProvider = { [weak surface, weak holder] in
                guard let surface, let holder else { return nil };return surface.convert(holder.bounds, from: holder)
            }
            surface.navigationInProgress = { [weak self] in self?.holdCrop ?? false }
            surface.onStroke = { [weak self] stroke in self?.saved.append(stroke); self?.upsert(stroke) }
            surface.onCheckpoint = { [weak self] stroke in self?.upsert(stroke) }
            surface.onFailure = { error in XCTFail("Surface failed independently of navigation: \(error)") }
            let prior = metal.onFrameSubmitted
            metal.onFrameSubmitted = { [weak self] timing in
                prior?(timing)
                guard let self else { return }
                let stroke = self.metal.strokes.first
                let local: CGPoint?
                if let stroke, let vertex = stroke.polygons.first?.first { local = vertex.applying(stroke.transform) }
                else { local = nil }
                self.submissions.append(.init(timing: timing, multiplyFlags: self.metal.strokes.map(\.multiply),
                    hasBackdrop: self.metal.backdrop != nil, bounds: self.metal.bounds,
                    firstLocalVertex: local, firstCanvasVertex: local.map { self.metal.convert($0, to: self.surface) }))
            }
            holder.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func settle() async throws {
            guard await NativePDFNavigationHighlighterTests.poll(timeout: 5, { !self.isNavigating && !self.imageView.isHidden && self.imageView.image != nil && self.metal.strokes.isEmpty && self.surface.inputDiagnostics["frameRequested"] as? Bool == false }) else {
                XCTFail("Fixture never settled before navigation; this is not the highlighter regression");throw SetupError.notSettled
            }
            try await readyDrawable(context: "settle")
        }
        func readyDrawable(context: String) async throws {
            print("NAV_DRAWABLE_READY before context=\(context) \(drawableState())")
            let ready = await NativePDFNavigationHighlighterTests.poll(timeout: 2, { self.metal.readyDrawableCount > 0 })
            print("NAV_DRAWABLE_READY after context=\(context) ready=\(ready) \(drawableState())")
            guard ready else {
                XCTFail("No drawable was ready before contact (\(context)); \(drawableState())");throw SetupError.rendererNotReady
            }
        }
        func drawableState() -> String {
            "drawable=\(metal.drawableSize) pendingGeometry=\(String(describing: metal.pendingFrameGeometry)) submittedGeometry=\(String(describing: metal.submittedFrameGeometry)) bounds=\(metal.bounds) scale=\(metal.contentScaleFactor) layerScale=\(metal.layer.contentsScale) autoResize=\(metal.autoResizeDrawable) ready=\(metal.readyDrawableCount) requesting=\(metal.pendingDrawableRequestCount) hidden=\(metal.isHidden) attached=\(metal.window != nil) \(finalState())"
        }
        func navigateAndHoldCrop(_ motion: Motion) async throws {
            holdCrop = true;cropCountAtHold = cropCount
            switch motion {
            case .pan: surface.frame.origin = CGPoint(x: -60, y: -80)
            case .zoom:
                surface.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
                surface.frame.origin = CGPoint(x: -40, y: -50)
            }
            surface.refreshViewport();surface.layoutIfNeeded()
            XCTAssertTrue(isNavigating)
            // Let the ordinary no-ink clear run, then explicitly establish
            // drawable readiness. Holding crop is a public host callback, not
            // a private render override or artificially slow PDF interpreter.
            try await Task.sleep(for: .milliseconds(80));try await readyDrawable(context: "navigate.\(motion.rawValue)")
            XCTAssertEqual(cropCount, cropCountAtHold)
        }
        func navigateOutsideOldCrop() async throws {
            holdCrop = true; cropCountAtHold = cropCount
            surface.frame.origin = CGPoint(x: -24, y: -600)
            surface.refreshViewport(); surface.layoutIfNeeded()
            XCTAssertTrue(isNavigating)
            try await readyDrawable(context: "outside-old-crop")
            XCTAssertEqual(cropCount, cropCountAtHold)
        }
        func appendCommittedRow(_ row: [String: Any]) {
            rows.append(row); tokens.append(NativePDFCommittedVisualToken(object: row))
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func removeRow(id: String) {
            guard let index = rows.firstIndex(where: { $0["id"] as? String == id }) else {
                XCTFail("Undo target must exist"); return
            }
            rows.remove(at: index); tokens.remove(at: index)
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func begin(tool: String, estimatedIndex: NSNumber? = nil) -> Contact {
            surface.tool = .init(name: tool, style: .init(color: tool == "highlighter" ? "yellow" : "blue",
                width: tool == "highlighter" ? 0.045 : 0.009, opacity: 0.45))
            let rect = surface.renderViewport!.canvasRect
            let touch = NavigationHighlighterTestTouch(point: surface.convert(CGPoint(x: rect.minX + 85, y: rect.minY + 95), to: window))
            touch.estimate = estimatedIndex;touch.expecting = estimatedIndex == nil ? [] : .force
            XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
            nextContact += 1;return Contact(id: nextContact, touch: touch)
        }
        func move(_ contact: Contact, dx: CGFloat, dy: CGFloat) {
            contact.touch.point.x += dx;contact.touch.point.y += dy
            contact.touch.time = ProcessInfo.processInfo.systemUptime;contact.touch.touchPhase = .moved
            surface.movePencilGesture(contact.touch, with: nil)
        }
        func end(_ contact: Contact) {
            contact.touch.time = ProcessInfo.processInfo.systemUptime;contact.touch.touchPhase = .ended
            let priorRows = rows.count
            print("NAV_FINAL_END before \(finalState())")
            surface.endPencilGesture(contact.touch, with: nil)
            lastEnd = (imageView.image, metal.submittedFrameCount, rows.count > priorRows)
            print("NAV_FINAL_END after \(finalState())")
        }
        func finalState() -> String {
            "image=\(String(describing: imageView.image.map(ObjectIdentifier.init))) submitted=\(metal.submittedFrameCount) attempts=\(renderAttempts) mode=\(surface.inputDiagnostics["sceneRenderMode"] ?? "nil") requested=\(surface.inputDiagnostics["frameRequested"] ?? "nil") rows=\(rows.count) nav=\(isNavigating) strokes=\(metal.strokes.count)"
        }
        private func upsert(_ stroke: NativePDFCompletedStroke) {
            let row: [String: Any] = ["id": stroke.mutationID, "clientMutationId": stroke.mutationID,
                "kind": stroke.kind, "data": ["inkVersion": stroke.inkVersion, "points": stroke.points.map { point -> [String: Double] in
                    var value = ["x": point.x, "y": point.y, "p": point.p]
                    if let time = point.t { value["t"] = time }
                    if let tilt = point.tiltX { value["tiltX"] = tilt }
                    if let tilt = point.tiltY { value["tiltY"] = tilt }
                    return value
                }],
                "style": ["color": stroke.style.color, "width": stroke.style.width, "opacity": stroke.style.opacity]]
            if let index = rows.firstIndex(where: { $0["id"] as? String == stroke.mutationID }) {
                rows[index] = row;tokens[index] = NativePDFCommittedVisualToken(object: row)
            } else {rows.append(row);tokens.append(NativePDFCommittedVisualToken(object: row))}
            surface.applyObjects(objects: rows, visualTokens: tokens)
        }
        func releaseCropAndVerifyFinalScene() async throws {
            holdCrop = false
            print("NAV_FINAL_WAIT before \(finalState())")
            let ready = await NativePDFNavigationHighlighterTests.poll(timeout: 5) {
                let handoff = self.lastEnd.map { prior in
                    !prior.requiresNewImage || (self.imageView.image !== prior.image && self.metal.submittedFrameCount > prior.submitted)
                } ?? true
                return !self.isNavigating && !self.imageView.isHidden && self.imageView.image != nil && self.metal.strokes.isEmpty && self.surface.inputDiagnostics["frameRequested"] as? Bool == false && handoff
            }
            print("NAV_FINAL_WAIT after ready=\(ready) \(finalState())")
            XCTAssertTrue(ready, "The outstanding crop must eventually adopt and clear its ordered live suffix")
            guard ready else {return}
            let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
            let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale) { c in
                for row in self.rows { NativePDFObjectRenderer.draw(row, in: c, mapper: mapper, image: nil) }
            }?.cgImage)
            let actual = try XCTUnwrap(imageView.image?.cgImage)
            let aa = try NativePDFNavigationHighlighterTests.pixels(actual),bb = try NativePDFNavigationHighlighterTests.pixels(expected)
            XCTAssertEqual(actual.width, expected.width);XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(aa.count, bb.count)
            let delta = zip(aa,bb).map {abs(Int($0)-Int($1))}
            XCTAssertEqual(delta.filter { $0 > 0 }.count, 0, "Settled scene must preserve measured order and multiply exactly; max=\(delta.max() ?? 0)")
        }
        func record(_ phase: String, contact: Contact, extra: [String: Any] = [:]) {
            let row: [String: Any] = ["phase": phase, "strokeID": contact.id, "navigationActive": isNavigating,
                "cropCount": cropCount, "cropCountAtHold": cropCountAtHold, "renderAttempts": renderAttempts,
                "strokeSubmissionCount": submissions.filter { $0.timing.strokeID == contact.id }.count,
                "allFrameCount": metal.submittedFrameCount, "readyDrawables": metal.readyDrawableCount,
                "deferredFrames": metal.deferredFrameCount, "metalStrokes": metal.strokes.count,
                "metalHasBackdrop": metal.backdrop != nil, "frameRequested": surface.inputDiagnostics["frameRequested"] ?? false,
                "pendingInputStrokeID": metal.pendingInputTiming?.strokeID as Any,
                "extra": extra]
            print("NAV_HIGHLIGHTER_REPRO \(row)")
        }
        func close() {
            holdCrop = false;try? surface.flush()
            window.isHidden = true;window.rootViewController = nil;previousWindow?.makeKeyAndVisible()
        }
    }
    static func poll(timeout: TimeInterval = 0.25, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let c = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

@MainActor
final class NavigationHighlighterTestTouch: UITouch {
    var point: CGPoint, time = ProcessInfo.processInfo.systemUptime
    var touchPhase: UITouch.Phase = .began, pressure: CGFloat = 0.5
    var estimate: NSNumber?, expecting: UITouch.Properties = []
    init(point: CGPoint) {self.point = point;super.init()}
    override var type: UITouch.TouchType {.pencil}
    override var timestamp: TimeInterval {time}
    override var phase: UITouch.Phase {touchPhase}
    override var force: CGFloat {pressure}
    override var maximumPossibleForce: CGFloat {1}
    override var altitudeAngle: CGFloat {.pi / 2}
    override var estimationUpdateIndex: NSNumber? {estimate}
    override var estimatedProperties: UITouch.Properties {expecting}
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties {expecting}
    override func location(in view: UIView?) -> CGPoint {view?.convert(point, from: view?.window) ?? point}
    override func preciseLocation(in view: UIView?) -> CGPoint {location(in: view)}
    override func azimuthAngle(in view: UIView?) -> CGFloat {0}
}
