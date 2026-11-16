import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

/// These unit fixtures verify routing, de-duplication, and late corrections.
/// Real UIKit dispatch is covered separately by the UI-test-only direct-touch
/// host. Neither fixture substitutes for physical Apple Pencil acceptance.
@MainActor
final class NativePDFPencilGestureTests: XCTestCase {
    func testPencilPressureCalibrationLiftsOrdinaryWritingAndKeepsLightTapsVisible() {
        // Under XCTest the knobs default to identity so fixture pressures round-trip; this test uses the product values.
        let saved = (NativePDFInkSurface.pressureGain, NativePDFInkSurface.pressureFloor)
        defer { (NativePDFInkSurface.pressureGain, NativePDFInkSurface.pressureFloor) = saved }
        NativePDFInkSurface.pressureGain = 2.5; NativePDFInkSurface.pressureFloor = 0.25
        XCTAssertEqual(NativePDFInkSurface.calibratedPressure(0), 0, "a zero estimate stays zero until UIKit corrects it")
        XCTAssertEqual(NativePDFInkSurface.calibratedPressure(0.05), 0.25, accuracy: 1e-9)
        XCTAssertEqual(NativePDFInkSurface.calibratedPressure(0.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NativePDFInkSurface.calibratedPressure(0.35), 0.875, accuracy: 1e-9)
        XCTAssertEqual(NativePDFInkSurface.calibratedPressure(0.6), 1)
    }
    private func activeWindowScene() async throws -> UIWindowScene {
        let deadline = CACurrentMediaTime() + 1
        repeat {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) { return scene }
            try await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < deadline
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }), "The test host must become foreground-active within one second")
    }
    private func surface() throws -> NativePDFInkSurface {
        let surface = try XCTUnwrap(NativePDFInkSurface())
        surface.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        surface.mapper = .whiteboard(size: surface.bounds.size)
        surface.tool = .init(name: "pen", drawAndHold: true, style: .init(color: "ink", width: 0.004, opacity: 1))
        surface.isLoading = false
        return surface
    }
    func testSelectedLassoAcceptsFingerAndRetainsUnboundedPointerAcrossNavigation() throws {
        let surface = try surface(), touch = PencilGestureTouch(kind: .direct)
        surface.tool = .init(name: "lasso", style: .init(color: "ink", width: 0.004, opacity: 1))
        surface.selectionBox = ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3]
        surface.selectionResizable = true
        XCTAssertNil(surface.selectionInputTarget(at: CGPoint(x: 500, y: 350)), "Empty paper must continue to scroll")
        XCTAssertTrue(surface.selectionInputTarget(at: touch.point) === surface)
        var events: [[String: Any]] = []
        surface.onPointer = { events.append($0) }
        XCTAssertTrue(surface.beginSelectionGesture(touch, with: nil))
        surface.retainsObjectDrag = true
        touch.point = CGPoint(x: 700, y: 500); touch.currentTime += 0.1
        surface.movePencilGesture(touch, with: nil)
        let moved = try XCTUnwrap((events.last?["points"] as? [[String: Any]])?.last)
        XCTAssertGreaterThan(try XCTUnwrap(moved["x"] as? Double), 1)
        XCTAssertGreaterThan(try XCTUnwrap(moved["y"] as? Double), 1)
        try surface.prepareForNavigation()
        XCTAssertEqual(events.last?["phase"] as? String, "move", "Page scrolling must not prematurely end a selected group's drag")
        surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(events.last?["phase"] as? String, "up")
    }
    func testOneShapeSelectionTakesHandlesWithin22PointsAndAFingerOnAShapeNamesIt() throws {
        let surface = try surface(), aspect = 400.0 / 600
        surface.tool = .init(name: "select", style: .init(color: "ink", width: 0.004, opacity: 1))
        let figure = NativePDFShapeFigure(kind: .polygon, name: "rect", vertices: [CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.3, y: 0.3)])
        let fit = NativePDFHeldShape(figure, width: 0.004, aspect: aspect).correction(kind: "ink", style: ["color": "ink", "width": 0.006, "opacity": 1])
        surface.objects = [["id": "rect", "kind": fit.kind, "data": fit.data, "style": fit.style]]
        // Canvas: x 180...360, y 60...180 on the 600 × 400 test page.
        XCTAssertEqual(surface.shapeTarget(at: CGPoint(x: 270, y: 60 + 18)), "rect", "A finger within 22 pt of the line")
        XCTAssertNil(surface.shapeTarget(at: CGPoint(x: 270, y: 120)), "Inside the box a finger still scrolls")
        let direct = PencilGestureTouch(kind: .direct); direct.point = CGPoint(x: 270, y: 62)
        XCTAssertTrue(surface.hitTest(direct.point, with: PencilGestureEvent(direct)) === surface)
        var events: [[String: Any]] = []
        surface.onPointer = { events.append($0) }
        surface.touchesBegan([direct], with: PencilGestureEvent(direct))
        XCTAssertEqual(events.last?["shape"] as? String, "rect", "The workspace selects the shape the finger landed on")
        surface.touchesEnded([direct], with: PencilGestureEvent(direct))
        // Selected: four corner handles, each taken from up to 22 pt away.
        surface.selectionBox = ["x": 0.3, "y": 0.15, "width": 0.3, "height": 0.3]
        surface.selectionResizable = true; surface.selectionHandles = ("corners", [])
        XCTAssertEqual(surface.selectionHandle(at: CGPoint(x: 360 + 15, y: 60 - 15)), "ne")
        XCTAssertEqual(surface.selectionHandle(at: CGPoint(x: 180 - 10, y: 180 + 10)), "sw")
        XCTAssertNil(surface.selectionHandle(at: CGPoint(x: 360 + 20, y: 60 - 20)), "28 pt is too far")
        XCTAssertTrue(surface.selectionInputTarget(at: CGPoint(x: 360 + 15, y: 60 - 15)) === surface, "The handle's target reaches past the box")
        let grab = PencilGestureTouch(kind: .direct); grab.point = CGPoint(x: 362, y: 58)
        XCTAssertTrue(surface.beginSelectionGesture(grab, with: nil))
        XCTAssertEqual(events.last?["handle"] as? String, "ne")
        surface.endPencilGesture(grab, with: nil)
        // A line shows its two ends instead.
        surface.selectionHandles = ("ends", [CGPoint(x: 0.3, y: 0.15), CGPoint(x: 0.6, y: 0.45)])
        XCTAssertEqual(surface.selectionHandle(at: CGPoint(x: 362, y: 178)), "end1")
        XCTAssertNil(surface.selectionHandle(at: CGPoint(x: 362, y: 58)), "No corners on a line")
        // The lasso takes a finger on a shape too, and a Pencil there may be starting a loop.
        surface.selectionBox = nil; surface.selectionResizable = false
        surface.tool = .init(name: "lasso", style: .init(color: "ink", width: 0.004, opacity: 1))
        XCTAssertTrue(surface.hitTest(direct.point, with: PencilGestureEvent(direct)) === surface)
        let pencil = PencilGestureTouch(kind: .pencil); pencil.point = CGPoint(x: 270, y: 62)
        XCTAssertTrue(surface.beginPencilGesture(pencil, with: nil))
        XCTAssertNil(events.last?["shape"])
        surface.endPencilGesture(pencil, with: nil)
    }
    func testLaserTrailsStayUntilThreeSecondsAfterTheLastContactOnAnyPage() throws {
        let clock = ManualLaserClock()
        let session = NativePDFLaserSession(schedule: clock.schedule)
        let first = try surface(), second = try surface()
        var saved = 0, pointers = 0
        for page in [first, second] {
            page.tool = .init(name: "laser", style: .init(color: "ink", width: 0.004, opacity: 1))
            page.laserSession = session
            page.onStroke = { _ in saved += 1 }; page.onPointer = { _ in pointers += 1 }
        }
        func draw(on page: NativePDFInkSurface, moves: Int) {
            let touch = PencilGestureTouch(kind: .pencil)
            XCTAssertTrue(page.beginPencilGesture(touch, with: nil))
            for i in 1...moves {
                touch.point = CGPoint(x: 100 + Double(i) * 3, y: 120); touch.currentTime += 0.01
                page.movePencilGesture(touch, with: nil)
            }
            page.endPencilGesture(touch, with: nil)
        }
        // One second of pointing: the whole trail stays, not only its last 0.6 s.
        draw(on: first, moves: 100)
        XCTAssertEqual(first.laserTrail.strokes.count, 1)
        XCTAssertEqual(first.laserTrail.strokes[0].count, 101, "Every sample of the stroke stays on screen")
        XCTAssertTrue(session.isWaitingToFade)
        clock.advance(2)
        XCTAssertEqual(session.strokeCount, 1, "Two seconds after lifting, the trail is still there")
        // Pointing again on the next page restarts the one shared countdown.
        draw(on: second, moves: 10)
        XCTAssertEqual(session.strokeCount, 2)
        clock.advance(2.9)
        XCTAssertEqual(session.strokeCount, 2, "The countdown restarted when the second trail ended")
        clock.advance(0.2)
        XCTAssertEqual(session.strokeCount, 0, "Three seconds without the laser: every trail fades together")
        XCTAssertFalse(session.isWaitingToFade)
        // A contact still down keeps everything; another tool clears at once.
        draw(on: first, moves: 5)
        let held = PencilGestureTouch(kind: .pencil)
        XCTAssertTrue(second.beginPencilGesture(held, with: nil))
        clock.advance(5)
        XCTAssertEqual(session.strokeCount, 2, "No fade while the Pencil is still pointing")
        second.endPencilGesture(held, with: nil)
        first.tool = .init(name: "pen", style: .init(color: "ink", width: 0.004, opacity: 1))
        XCTAssertEqual(session.strokeCount, 0, "Choosing another tool removes the laser immediately")
        XCTAssertFalse(session.isWaitingToFade)
        XCTAssertEqual(saved, 0); XCTAssertEqual(pointers, 0, "The laser is never saved or sent to the editor")
    }
    func testDrawAndHoldThenMovingTurnsAndStretchesTheLineAndUndoKeepsTheHandwriting() async throws {
        let surface = try surface(), touch = PencilGestureTouch(kind: .pencil)
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        for i in 1...20 {
            touch.point = CGPoint(x: 100 + i * 8, y: 100 + (i % 2)); touch.currentTime += 0.01
            surface.movePencilGesture(touch, with: nil)
        }
        try await Task.sleep(for: .milliseconds(650))
        let fit = try XCTUnwrap(surface.heldShape, "A clean preview must exist while contact is still down")
        XCTAssertEqual(fit.kind, "line")
        XCTAssertTrue(saved.isEmpty, "A hold must not prematurely commit the raw stroke")
        // Moving on keeps the shape: its start stays, its end follows the pen.
        for step in 1...10 {
            touch.point = CGPoint(x: 260 + step * 4, y: 101 + step * 9); touch.currentTime += 0.01
            surface.movePencilGesture(touch, with: nil)
            XCTAssertNotNil(surface.heldShape, "Moving after the shape appeared never cancels it")
        }
        let moved = try XCTUnwrap(surface.heldShape)
        let first = try XCTUnwrap(moved.points.first), last = try XCTUnwrap(moved.points.last)
        XCTAssertEqual(first.x, fit.points.first!.x, accuracy: 0.002); XCTAssertEqual(first.y, fit.points.first!.y, accuracy: 0.003)
        XCTAssertEqual(last.x, 300.0 / 600, accuracy: 0.004); XCTAssertEqual(last.y, 191.0 / 400, accuracy: 0.004)
        surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(saved[0].holdSnap)
        XCTAssertEqual(saved[0].heldShape, moved, "Lift keeps the shape as adjusted")
        // The measured stroke saved with it (what one undo restores) ends where the shape appeared.
        XCTAssertEqual(saved[0].points.count, 21)
        XCTAssertEqual(saved[0].points.last?.x ?? 0, 260.0 / 600, accuracy: 0.001)
        // 8 pt per 10 ms on a 600 pt page: V5 draws it 12 % thinner for speed.
        XCTAssertEqual(saved[0].heldShape?.width ?? 0, 0.004 * NativePDFInkGeometryV5.baseFactor(pressure: 0.5, speed: 1.33), accuracy: 0.0001,
                       "The shape takes the drawn stroke's width")
    }
    func testHeldRectangleGrowsAndTurnsAboutItsCentreAndSnapsLevel() async throws {
        let surface = try surface(), touch = PencilGestureTouch(kind: .pencil)
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        touch.point = CGPoint(x: 200, y: 100)
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        for corner in [CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 260), CGPoint(x: 200, y: 260), CGPoint(x: 200, y: 100)] {
            let from = touch.point
            for step in 1...25 {
                let t = Double(step) / 25
                touch.point = CGPoint(x: from.x + (corner.x - from.x) * t, y: from.y + (corner.y - from.y) * t); touch.currentTime += 0.008
                surface.movePencilGesture(touch, with: nil)
            }
        }
        try await Task.sleep(for: .milliseconds(650))
        let fit = try XCTUnwrap(surface.heldShape)
        XCTAssertEqual(fit.kind, "rect")
        func centre(_ shape: NativePDFHeldShape) -> CGPoint { CGPoint(x: shape.box[0] + shape.box[2] / 2, y: shape.box[1] + shape.box[3] / 2) }
        // Pull the corner away from the centre, half as far again: the rectangle grows 1.5× about its centre.
        touch.point = CGPoint(x: 150, y: 60); touch.currentTime += 0.01
        surface.movePencilGesture(touch, with: nil)
        let grown = try XCTUnwrap(surface.heldShape)
        XCTAssertEqual(centre(grown).x, centre(fit).x, accuracy: 0.002); XCTAssertEqual(centre(grown).y, centre(fit).y, accuracy: 0.003)
        XCTAssertEqual(grown.box[2] / fit.box[2], 1.5, accuracy: 0.03)
        // Turn the pen 2° around the centre: the rectangle settles back level instead of tilting 2°.
        let c = CGPoint(x: 300, y: 180), a = 2 * Double.pi / 180
        touch.point = CGPoint(x: c.x + (150 - c.x) * cos(a) - (60 - c.y) * sin(a), y: c.y + (150 - c.x) * sin(a) + (60 - c.y) * cos(a))
        touch.currentTime += 0.01; surface.movePencilGesture(touch, with: nil)
        let level = try XCTUnwrap(surface.heldShape)
        XCTAssertEqual(level.box[2], grown.box[2], accuracy: 0.002, "Still level: the 2° turn snapped back")
        // 20° turns it.
        let b = 20 * Double.pi / 180
        touch.point = CGPoint(x: c.x + (150 - c.x) * cos(b) - (60 - c.y) * sin(b), y: c.y + (150 - c.x) * sin(b) + (60 - c.y) * cos(b))
        touch.currentTime += 0.01; surface.movePencilGesture(touch, with: nil)
        let turned = try XCTUnwrap(surface.heldShape)
        XCTAssertGreaterThan(turned.box[2], grown.box[2] * 1.05, "A turned rectangle's box is wider")
        surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(saved.first?.heldShape, turned)
        XCTAssertEqual(saved.first?.heldShape?.figure, "polygon")
        XCTAssertEqual(turned.width, fit.width, "Resizing never changes the line's width")
    }
    func testDrawAndHoldCancellationKeepsRawStrokeAndDisablingPreventsRecognition() async throws {
        for enabled in [true, false] {
            let surface = try surface(), touch = PencilGestureTouch(kind: .pencil)
            surface.tool.drawAndHold = enabled
            var saved: [NativePDFCompletedStroke] = []
            surface.onStroke = { saved.append($0) }
            XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
            for _ in 1...15 {
                touch.point.x += 8; touch.currentTime += 0.01
                surface.movePencilGesture(touch, with: nil)
            }
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(surface.heldShape != nil, enabled)
            surface.cancelPencilGesture(touch, with: nil)
            XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].points.count, 16)
            XCTAssertFalse(saved[0].holdSnap, "Interruption must not replace handwriting with a shape")
            XCTAssertNil(saved[0].heldShape)
        }
    }
    func testDrawAndHoldLiftRetainsPreviewFitAlongsideOriginalMeasuredPressure() async throws {
        let surface = try surface(), touch = PencilGestureTouch(kind: .pencil)
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        for i in 1...16 {
            touch.point.x += 8; touch.currentTime += 0.01; touch.pressure = i.isMultiple(of: 2) ? 0.2 : 0.8
            surface.movePencilGesture(touch, with: nil)
        }
        try await Task.sleep(for: .milliseconds(650))
        let fit = try XCTUnwrap(surface.heldShape)
        surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(saved[0].holdSnap)
        XCTAssertEqual(saved[0].heldShape, fit)
        XCTAssertEqual(saved[0].points.count, 17, "Raw samples remain available for undo and durability recovery")
        XCTAssertEqual(Set(saved[0].points.map(\.p)), [0.2, 0.5, 0.8])
        XCTAssertTrue(fit.points.allSatisfy { $0.p == 0.5 })
    }
    func testHighlighterHoldUsesScreenPointToleranceAndKeepsMeasuredSource() async throws {
        let surface = try surface(), touch = PencilGestureTouch(kind: .pencil)
        surface.tool = .init(name: "highlighter", drawAndHold: true, style: .init(color: "yellow", width: 0.014, opacity: 0.32))
        // Multiply ink must have the same opaque PDF destination as production.
        surface.pdfPage = PDFPage(image: UIGraphicsImageRenderer(size: surface.bounds.size).image { renderer in
            UIColor.white.setFill(); renderer.fill(surface.bounds)
        })
        let scene = try await activeWindowScene(), controller = UIViewController()
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        for _ in 1...15 { touch.point.x += 8; touch.currentTime += 0.01; surface.movePencilGesture(touch, with: nil) }
        try await Task.sleep(for: .milliseconds(650))
        let fit = try XCTUnwrap(surface.heldShape)
        XCTAssertEqual(fit.kind, "line")
        touch.point.x += 2; touch.currentTime += 0.01; surface.movePencilGesture(touch, with: nil)
        XCTAssertEqual(surface.heldShape, fit, "Sub-3pt tip jitter keeps the accepted preview")
        surface.endPencilGesture(touch, with: nil)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].kind, "highlighter")
        XCTAssertEqual(saved[0].heldShape, fit); XCTAssertEqual(saved[0].points.count, 16, "The measured source is kept beside the fit")
        XCTAssertEqual(saved[0].style.opacity, 0.32)
        XCTAssertFalse(NativePDFInkSurface.Tool().drawAndHold, "Non-PDF surfaces must explicitly opt into fitted-geometry persistence")
    }
    func testDeliveryTimingSeesPreviousCompletionBlockingAndRejectsSyntheticEpochs() throws {
        let surface = try surface()
        let first = PencilGestureTouch(kind: .pencil); first.currentTime = CACurrentMediaTime()
        XCTAssertTrue(surface.beginPencilGesture(first, with: nil))
        // A new hardware contact can already be timestamped while the main
        // thread is still processing the preceding contact's durable writer.
        let second = PencilGestureTouch(kind: .pencil); second.currentTime = CACurrentMediaTime()
        var writes = 0
        surface.onStroke = { _ in writes += 1; if writes == 1 { Thread.sleep(forTimeInterval: 0.04) } }
        surface.endPencilGesture(first, with: nil)
        XCTAssertTrue(surface.beginPencilGesture(second, with: nil))
        let delivery = try XCTUnwrap(surface.inputDiagnostics["inputDeliveryTiming"] as? [String: Any])
        XCTAssertEqual(delivery["count"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(delivery["lastMS"] as? Double), 40)
        surface.endPencilGesture(second, with: nil)
        for timestamp in [-1.0, CACurrentMediaTime() + 60, 1] {
            let synthetic = PencilGestureTouch(kind: .pencil); synthetic.currentTime = timestamp
            XCTAssertTrue(surface.beginPencilGesture(synthetic, with: nil))
            surface.endPencilGesture(synthetic, with: nil)
        }
        XCTAssertEqual(surface.inputDiagnostics["invalidInputDeliveryTimestamps"] as? Int, 3)
        XCTAssertEqual((surface.inputDiagnostics["inputDeliveryTiming"] as? [String: Any])?["count"] as? Int, 2)
        XCTAssertEqual(writes, 5, "Invalid diagnostic timestamps must never discard measured ink")
    }
    func testLiveInkSubmitsWhilePencilIsStillDown() async throws {
        let surface = try surface(), controller = UIViewController()
        surface.tool = .init(name: "pen", style: .init(color: "ink", width: 0.004, opacity: 0.45))
        surface.pdfPage = PDFPage(image: UIGraphicsImageRenderer(size: surface.bounds.size).image { renderer in
            UIColor.white.setFill(); renderer.fill(surface.bounds)
        })
        let scene = try await activeWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let gesture = NativePDFPencilGestureRecognizer()
        controller.view.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let touch = PencilGestureTouch(kind: .pencil), event = PencilGestureEvent(touch)
        var saves = 0, timingPublications = 0, presentations = NativePDFInkFrameStatistics()
        var saved: [NativePDFCompletedStroke] = []
        let store = NativePDFDrawingSnapshotStore()
        surface.onStroke = { _ in saves += 1 }
        surface.onTiming = { _, _ in timingPublications += 1 }
        surface.onPresentation = { presentations = $0 }
        defer { surface.onStroke = nil; surface.onTiming = nil; surface.onPresentation = nil }
        // Let initial layout finish, then hold the same Pencil contact open.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(surface.renderViewport)
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        let beforeInputFrames = metal.submittedFrameCount
        XCTAssertFalse(metal.isHidden)
        gesture.touchesBegan([touch], with: event)
        try await Task.sleep(for: .milliseconds(50))
        #if !targetEnvironment(simulator)
        XCTAssertGreaterThan(presentations.framesBeforeLift, 0, "The stationary first dot must appear before any move or lift")
        #endif
        for _ in 0..<12 {
            touch.point.x += 4; touch.currentTime += 0.008
            gesture.touchesMoved([touch], with: event)
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(saves, 0, "The contact is still down; no completion may manufacture the preview")
        XCTAssertGreaterThan(metal.strokes.count, 0, "The frame tick must have built live geometry")
        XCTAssertNil(metal.backdrop, "Normal pen must not upload the entire PDF raster on its first point")
        let frames = metal.submittedFrameCount - beforeInputFrames
        XCTAssertGreaterThan(frames, 2, "Live ink must reach the GPU repeatedly before Pencil lifts")
        XCTAssertLessThan(timingPublications, Int(frames), "Accessibility telemetry must not run on every rendered frame")
        #if !targetEnvironment(simulator)
        XCTAssertGreaterThan(presentations.framesBeforeLift, 0, "A submitted command alone is not proof of actual presentation")
        XCTAssertEqual(presentations.strokesBeforeLift, 1)
        XCTAssertEqual(presentations.strokesAfterLift, 0)
        print("Live ink before lift: \(frames) submissions; first presentation \(presentations.firstPresentationP95MS)ms, receive→present p95 \(presentations.receiveToPresentP95MS)ms")
        #endif
        let previousSequence = metal.lastSubmittedFrame?.sequence ?? 0
        let committedScene = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let beforeCommit = try XCTUnwrap(committedScene.image)
        let mapper = try XCTUnwrap(surface.mapper), viewport = try XCTUnwrap(surface.renderViewport)
        surface.onStroke = { stroke in
            saves += 1
            saved.append(stroke)
            // A final live submission can defer while the worker acquires a
            // drawable. Preserve the displayed ink until its canonical image
            // can replace it atomically; resource availability cannot gate saving.
            XCTAssertGreaterThanOrEqual(metal.lastSubmittedFrame?.sequence ?? 0, previousSequence)
            XCTAssertEqual(metal.lastSubmittedFrame?.sequence, metal.submittedFrameCount,
                "No transparent clear may be submitted before the canonical image is ready")
            XCTAssertFalse(metal.strokes.isEmpty)
            XCTAssertTrue(committedScene.image === beforeCommit)
            let input = NativePDFStrokeInput(courseId: "live-stroke-fixture", relPath: "paper.pdf", page: 1,
                kind: stroke.kind, data: .init(points: stroke.points), style: stroke.style,
                clientMutationId: stroke.mutationID)
            var object = try NativePDFHost.json(input); object["id"] = stroke.mutationID
            try store.apply(["drawings": [object]], pageCount: 1)
            let rows = store.orderedRows
            surface.applyObjects(objects: rows.map { $0.prepared(aspect: mapper.geometry.height / mapper.geometry.width) },
                visualTokens: rows.map(\.visualToken))
            XCTAssertTrue(committedScene.image === beforeCommit,
                "Canonical storage alone must not expose the new image underneath the old live ink")
        }
        // Give lift a unique position, force, and timestamp so losing its final
        // measured sample cannot pass through deduplication with the last move.
        touch.point.x += 4; touch.currentTime += 0.008; touch.pressure = 0.8
        let finalX = Double(touch.point.x / surface.bounds.width)
        let finalY = Double(touch.point.y / surface.bounds.height)
        let finalTime = (touch.currentTime - 10) * 1000
        gesture.touchesEnded([touch], with: event)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(saved.count, 1)
        let savedStroke = try XCTUnwrap(saved.first)
        XCTAssertEqual(savedStroke.points.count, 14)
        let final = try XCTUnwrap(savedStroke.points.last)
        XCTAssertEqual(final.x, finalX, accuracy: 1e-12); XCTAssertEqual(final.y, finalY, accuracy: 1e-12)
        XCTAssertEqual(final.p, 0.8); XCTAssertEqual(try XCTUnwrap(final.t), finalTime, accuracy: 1e-9)
        XCTAssertEqual(savedStroke.points.filter { $0 == final }.count, 1)
        let row = try XCTUnwrap(store.orderedRows.first)
        let canonical = try JSONDecoder().decode(NativePDFStrokeInput.self,
            from: JSONSerialization.data(withJSONObject: row.object))
        XCTAssertEqual(canonical.data.points, savedStroke.points)
        XCTAssertEqual(surface.objects.count, 1)
        XCTAssertTrue(committedScene.image === beforeCommit)
        XCTAssertFalse(metal.strokes.isEmpty, "Lift must keep the existing live frame until the next successful handoff")
        let deadline = CACurrentMediaTime() + 0.5
        while (committedScene.image === beforeCommit || !metal.strokes.isEmpty), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = try XCTUnwrap(committedScene.image)
        XCTAssertFalse(actual === beforeCommit, "The committed image must replace the preview after storage")
        XCTAssertTrue(metal.strokes.isEmpty, "A saved stroke must not remain as a second translucent live layer")
        let reference = try XCTUnwrap(NativePDFCommittedSceneCache().render(paper: beforeCommit, mapper: mapper,
            bounds: viewport.canvasRect, highlights: [], objects: surface.objects,
            visualTokens: surface.objectVisualTokens, drawHighlights: { _ in },
            drawObject: { NativePDFObjectRenderer.draw($0, in: $1, mapper: mapper, image: nil) }))
        XCTAssertTrue(try rgbaPixels(actual) == rgbaPixels(reference),
            "The displayed canonical image must include the unique final sample exactly once")
    }
    func testTwentyRapidPencilStrokesKeepCallbacksResponsiveAndCommitExactlyOnce() async throws {
        let surface = try surface(), controller = UIViewController()
        // Translucent ink makes an accidental retained live copy visible.
        surface.tool = .init(name: "pen", style: .init(color: "blue", width: 0.008, opacity: 0.45))
        surface.pdfPage = PDFPage(image: UIGraphicsImageRenderer(size: surface.bounds.size).image { renderer in
            UIColor.white.setFill(); renderer.fill(surface.bounds)
        })
        let scene = try await activeWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let store = NativePDFDrawingSnapshotStore()
        var saved: [NativePDFCompletedStroke] = [], failures: [String] = [], diagnostics: [String] = []
        var beginMS: [Double] = [], endMS: [Double] = []
        var cancellationEvents: [String] = []
        surface.onFailure = { failures.append($0.localizedDescription) }
        surface.onDiagnostic = { diagnostics.append($0) }
        defer { surface.onStroke = nil; surface.onFailure = nil; surface.onDiagnostic = nil }
        surface.onStroke = { stroke in
            let input = NativePDFStrokeInput(courseId: "rapid-stroke-fixture", relPath: "paper.pdf", page: 1,
                kind: stroke.kind, data: .init(points: stroke.points), style: stroke.style,
                clientMutationId: stroke.mutationID)
            var object = try NativePDFHost.json(input); object["id"] = stroke.mutationID
            let order = saved.map(\.mutationID) + [stroke.mutationID]
            try store.apply(["drawingPatch": ["reset": saved.isEmpty,
                "baseRevision": store.revision, "revision": store.revision + 1,
                "order": order, "upserts": [object]]], pageCount: 1)
            let mapper = try XCTUnwrap(surface.mapper), rows = store.orderedRows
            surface.applyObjects(objects: rows.map { $0.prepared(aspect: mapper.geometry.height / mapper.geometry.width) },
                visualTokens: rows.map(\.visualToken))
            saved.append(stroke)
        }
        // Only the initial window attachment settles here. The actual burst
        // has no UI-automation idle waits between independent contacts.
        try await Task.sleep(for: .milliseconds(100))
        let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        let committedScene = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let emptyScene = try XCTUnwrap(committedScene.image)
        for index in 0..<20 {
            // Direct fake touches are absent from UIKit's tracked-touch set.
            // A reused terminal recognizer can receive UIKit's queued reset
            // after the next fake begin. Give each contact a fresh production
            // recognizer while sharing the Surface, Metal renderer, and store.
            // Reuse with actual UIKit touch dispatch is covered by UI tests.
            let gesture = NativePDFPencilGestureRecognizer()
            controller.view.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
            gesture.onDiagnostic = { event in
                if event.contains("cancel") { cancellationEvents.append("contact \(index + 1): \(event)") }
            }
            defer { gesture.onDiagnostic = nil; controller.view.removeGestureRecognizer(gesture) }
            XCTAssertEqual(gesture.state, .possible)
            let touch = PencilGestureTouch(kind: .pencil), event = PencilGestureEvent(touch)
            touch.point = CGPoint(x: 70, y: 30 + index * 16)
            touch.currentTime = 10 + Double(index) * 0.032; touch.pressure = 0.25
            let began = CACurrentMediaTime()
            gesture.touchesBegan([touch], with: event)
            beginMS.append((CACurrentMediaTime() - began) * 1000)
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertEqual(gesture.state, .began)
            XCTAssertEqual(saved.count, index, "A contact cannot complete before its move")
            touch.point.x += 35; touch.currentTime += 0.008; touch.pressure = 0.65
            gesture.touchesMoved([touch], with: event)
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertEqual(gesture.state, .changed)
            XCTAssertEqual(saved.count, index, "A contact cannot complete before lift")
            touch.point.x += 20; touch.currentTime += 0.016; touch.pressure = 0.4
            let ended = CACurrentMediaTime()
            gesture.touchesEnded([touch], with: event)
            endMS.append((CACurrentMediaTime() - ended) * 1000)
            XCTAssertEqual(saved.count, index + 1, "Every contact must commit before the following contact")
            XCTAssertEqual(surface.objects.count, index + 1)
            XCTAssertEqual(store.order, saved.map(\.mutationID))
            XCTAssertEqual(Set(store.order).count, index + 1, "A handoff must not duplicate a canonical stroke")
            XCTAssertEqual(surface.objectVisualTokens?.count, index + 1)
            for (row, token) in zip(store.orderedRows, surface.objectVisualTokens ?? []) {
                XCTAssertTrue(row.visualToken === token, "The displayed rows use the validated store identities")
            }
            if let stroke = saved.last {
                XCTAssertEqual(stroke.points.count, 3, "The begin, move, and final measured samples must all survive")
                XCTAssertEqual(stroke.points.map(\.p), [0.25, 0.65, 0.4])
                let row = try XCTUnwrap(store.row(id: stroke.mutationID))
                let encoded = try JSONSerialization.data(withJSONObject: row.object)
                let canonical = try JSONDecoder().decode(NativePDFStrokeInput.self, from: encoded)
                XCTAssertEqual(canonical.data.points, stroke.points, "Rendering must not rewrite the canonical samples")
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        // Short contacts can legitimately present after lift. This regression
        // checks blocking and loss/duplication, not before-lift presentation.
        try await Task.sleep(for: .milliseconds(100))
        let submitMS = diagnostics.compactMap { message -> Double? in
            guard message.hasPrefix("submit.first."), message.hasSuffix("ms") else { return nil }
            return Double(message.dropFirst("submit.first.".count).dropLast(2))
        }
        print("Rapid Pencil 20 x 24ms/8ms: begin ms \(beginMS); end ms \(endMS); first submit ms \(submitMS)")
        print("Rapid Pencil submission stages: \(diagnostics.filter { $0.hasPrefix("submit.stages.") })")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertTrue(cancellationEvents.isEmpty, cancellationEvents.joined(separator: "; "))
        XCTAssertEqual(saved.count, 20); XCTAssertEqual(saved.reduce(0) { $0 + $1.points.count }, 60)
        XCTAssertLessThan(beginMS.max() ?? .infinity, 200, "Pencil begin must not wait for the drawable pool's one-second timeout")
        XCTAssertLessThan(endMS.max() ?? .infinity, 200, "Completion and scene handoff must return without blocking the main thread")
        // Admission can coalesce a short contact into its canonical image if
        // earlier drawables still occupy the pool. The store must retain all
        // 20 contacts regardless; a live submission is not a durability ACK.
        XCTAssertFalse(submitMS.isEmpty, "The burst must exercise actual live GPU submissions")
        XCTAssertLessThanOrEqual(submitMS.count, 20)
        XCTAssertLessThan(submitMS.max() ?? .infinity, 200, "The first live submission cannot stall behind previous strokes")
        XCTAssertTrue(metal.strokes.isEmpty, "The last committed stroke must not remain as a second translucent live layer")
        let actual = try XCTUnwrap(committedScene.image)
        XCTAssertFalse(actual === emptyScene)
        let reference = try XCTUnwrap(NativePDFCommittedSceneCache().render(paper: emptyScene, mapper: mapper,
            bounds: viewport.canvasRect, highlights: [], objects: surface.objects,
            visualTokens: surface.objectVisualTokens, drawHighlights: { _ in },
            drawObject: { NativePDFObjectRenderer.draw($0, in: $1, mapper: mapper, image: nil) }))
        XCTAssertTrue(try rgbaPixels(actual) == rgbaPixels(reference),
            "The final displayed scene must contain every stroke exactly once, matching a clean full replay")
    }
    func testLatePressureCorrectionsOnTwoHundredStrokesKeepNextPencilContactLiveAndDurable() async throws {
        let surface = try surface(), controller = UIViewController()
        surface.pdfPage = PDFPage(image: UIGraphicsImageRenderer(size: surface.bounds.size).image { renderer in
            UIColor.white.setFill(); renderer.fill(surface.bounds)
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let journal = try NativePDFJournal(root: root), revision = String(repeating: "a", count: 64)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativePDFDrawingSnapshotStore(), course = "late-pressure-fixture", path = "paper.pdf"
        var initial: [[String: Any]] = []
        for index in 0..<200 {
            let points = (0..<96).map { sample -> NativePDFPoint in
                let t = Double(sample) / 95
                return .init(x: 0.1 + t * 0.8, y: 0.1 + Double(index % 16) * 0.045 + sin(t * .pi * 4) * 0.035,
                    p: 0.25 + 0.45 * t, t: Double(sample) * 1000 / 240)
            }
            let input = NativePDFStrokeInput(courseId: course, relPath: path, page: 1,
                kind: index.isMultiple(of: 8) ? "highlighter" : "ink", data: .init(points: points),
                style: .init(color: "blue", width: 0.008, opacity: 0.42), clientMutationId: UUID().uuidString)
            var object = try NativePDFHost.json(input); object["id"] = input.clientMutationId; initial.append(object)
        }
        try store.apply(["drawings": initial], pageCount: 1)
        func publishRows() {
            let rows = store.orderedRows
            surface.applyObjects(objects: rows.map { $0.prepared(aspect: 400.0 / 600) }, visualTokens: rows.map(\.visualToken))
        }
        publishRows()
        let scene = try await activeWindowScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.addSubview(surface)
        surface.layoutIfNeeded(); surface.refreshViewport()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        let imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let setupDeadline = CACurrentMediaTime() + 3
        while imageView.image == nil, CACurrentMediaTime() < setupDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(imageView.image)
        try await Task.sleep(for: .milliseconds(50))
        let initialFullCount = try XCTUnwrap(surface.inputDiagnostics["sceneFullRenders"] as? Int)
        var checkpoints: [NativePDFCompletedStroke] = [], saved: [NativePDFCompletedStroke] = [], errors: [String] = []
        func publish(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
            let input = NativePDFStrokeInput(courseId: course, relPath: path, page: 1, kind: stroke.kind,
                data: .init(points: stroke.points), style: stroke.style, clientMutationId: stroke.mutationID)
            if provisional { try journal.checkpoint(input, documentRevision: revision); checkpoints.append(stroke) }
            else { try journal.append(input, documentRevision: revision); saved.append(stroke) }
            var object = try NativePDFHost.json(input); object["id"] = stroke.mutationID
            let order = store.order.contains(stroke.mutationID) ? store.order : store.order + [stroke.mutationID]
            try store.apply(["drawingPatch": ["reset": false, "baseRevision": store.revision,
                "revision": store.revision + 1, "order": order, "upserts": [object]]], pageCount: 1)
            publishRows()
        }
        surface.onCheckpoint = { try publish($0, provisional: true) }
        surface.onStroke = { try publish($0, provisional: false) }
        surface.onFailure = { errors.append($0.localizedDescription) }
        defer { surface.onCheckpoint = nil; surface.onStroke = nil; surface.onFailure = nil }
        let oldSubmitted = metal.onFrameSubmitted, oldPresented = metal.onFramePresented
        var nextFirstSubmit: NativePDFMetalInk.FrameTiming?, nextFirstPresent: NativePDFMetalInk.FrameTiming?
        metal.onFrameSubmitted = { frame in
            oldSubmitted?(frame)
            if frame.strokeID == 2, nextFirstSubmit == nil { nextFirstSubmit = frame }
        }
        metal.onFramePresented = { frame in
            oldPresented?(frame)
            if frame.strokeID == 2, frame.presentedAt != nil, nextFirstPresent == nil { nextFirstPresent = frame }
        }
        defer { metal.onFrameSubmitted = oldSubmitted; metal.onFramePresented = oldPresented }
        let priorGesture = NativePDFPencilGestureRecognizer(), nextGesture = NativePDFPencilGestureRecognizer()
        for gesture in [priorGesture, nextGesture] {
            controller.view.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        }
        let priorSamples = (0..<3).map { index -> PencilGestureTouch in
            let touch = PencilGestureTouch(kind: .pencil)
            touch.point = CGPoint(x: 100 + index * 20, y: 100); touch.currentTime += Double(index) * 0.004
            touch.pressure = CGFloat([0.2, 0.3, 0.4][index]); touch.estimateIndex = NSNumber(value: 900 + index); touch.expecting = .force
            return touch
        }
        let prior = priorSamples[0], priorEvent = PencilGestureEvent(prior); priorEvent.coalesced = priorSamples
        priorGesture.touchesBegan([prior], with: priorEvent)
        try await Task.sleep(for: .milliseconds(8))
        priorGesture.touchesEnded([prior], with: priorEvent); priorGesture.reset()
        XCTAssertEqual(checkpoints.count, 1); XCTAssertTrue(saved.isEmpty)
        let priorID = try XCTUnwrap(checkpoints.first?.mutationID)
        try await Task.sleep(for: .milliseconds(24))
        let next = PencilGestureTouch(kind: .pencil), nextEvent = PencilGestureEvent(next)
        next.point = CGPoint(x: 100, y: 150); next.currentTime = 11; next.pressure = 0.6
        nextGesture.touchesBegan([next], with: nextEvent)
        var correctionMS: [Double] = []
        for (step, pressure) in [0.35, 0.5, 0.65, 0.8].enumerated() {
            let beforeTail = try XCTUnwrap(surface.inputDiagnostics["sceneTailRenders"] as? Int)
            prior.pressure = CGFloat(pressure)
            if step == 3 { for sample in priorSamples { sample.expecting = [] } }
            let started = CACurrentMediaTime()
            priorGesture.touchesEstimatedPropertiesUpdated(Set(step == 3 ? priorSamples : [prior]))
            correctionMS.append((CACurrentMediaTime() - started) * 1000)
            let durable = try XCTUnwrap(NativePDFJournal(root: root).pending(courseID: course, relativePath: path).first)
            XCTAssertEqual(durable.input.clientMutationId, priorID)
            XCTAssertEqual(durable.input.data.points[0].p, pressure, "Every late estimate must survive reopening the on-disk journal")
            XCTAssertEqual(durable.provisional == true, step < 3)
            let deadline = CACurrentMediaTime() + 0.3
            while (surface.inputDiagnostics["sceneTailRenders"] as? Int ?? 0) == beforeTail, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertEqual(surface.inputDiagnostics["sceneTailRenders"] as? Int, beforeTail + 1)
            XCTAssertEqual(surface.inputDiagnostics["sceneRenderMode"] as? String, "tail")
            XCTAssertEqual(surface.inputDiagnostics["sceneLastDrawnObjects"] as? Int, 1,
                "Only the prior unresolved contact is committed; the second contact remains live")
            XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, initialFullCount)
            XCTAssertFalse(metal.strokes.isEmpty, "Updating the prior committed stroke must keep the second contact live")
            XCTAssertEqual(saved.count, step == 3 ? 1 : 0)
            next.point.x += 12; next.currentTime += 0.016
            nextGesture.touchesMoved([next], with: nextEvent)
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNotNil(nextFirstSubmit, "The second contact must submit while old pressure corrections are arriving")
        XCTAssertLessThan(try XCTUnwrap(nextFirstSubmit).receiveToSubmitMS, 200)
        #if !targetEnvironment(simulator)
        XCTAssertNotNil(nextFirstPresent, "Physical Metal must display the second contact before lift")
        XCTAssertLessThan(try XCTUnwrap(nextFirstPresent?.receiveToPresentMS), 200)
        #endif
        XCTAssertLessThan(correctionMS.max() ?? .infinity, 200)
        let liveViewport = try XCTUnwrap(surface.renderViewport)
        let liveLayer = try XCTUnwrap(metal.layer as? CAMetalLayer)
        let liveSize = liveLayer.drawableSize
        print("Late-pressure live readback geometry: MTK raw=\(metal.drawableSize), layer=\(liveSize), pending=\(String(describing: metal.pendingFrameGeometry)), submitted=\(String(describing: metal.submittedFrameGeometry)), viewport=\(liveViewport.pixelSize)")
        XCTAssertGreaterThan(liveSize.width, 0); XCTAssertGreaterThan(liveSize.height, 0)
        XCTAssertEqual(liveSize, liveViewport.pixelSize)
        XCTAssertEqual(metal.pendingFrameGeometry?.pixelSize, liveViewport.pixelSize)
        XCTAssertEqual(metal.submittedFrameGeometry?.pixelSize, liveViewport.pixelSize)
        XCTAssertEqual(metal.pendingFrameGeometry?.canvasRect, liveViewport.canvasRect)
        XCTAssertEqual(metal.submittedFrameGeometry?.canvasRect, liveViewport.canvasRect)
        let readbackSize = try XCTUnwrap(liveSize.width.isFinite && liveSize.height.isFinite &&
            liveSize.width > 0 && liveSize.height > 0 && liveSize.width <= 4096 && liveSize.height <= 4096 ? liveSize : nil)
        let livePixels = try XCTUnwrap(metal.renderedPixels(width: Int(readbackSize.width), height: Int(readbackSize.height)))
        XCTAssertTrue(stride(from: 3, to: livePixels.count, by: 4).contains { livePixels[$0] > 0 },
            "The current live stroke must still have nonzero coverage after every prior-pressure correction")
        let beforeFinalCommit = imageView.image
        next.point.x += 12; next.currentTime += 0.016; next.pressure = 0.7
        nextGesture.touchesEnded([next], with: nextEvent)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertEqual(saved.count, 2); XCTAssertEqual(saved.first?.mutationID, priorID)
        XCTAssertEqual(saved.first?.points.map(\.p), [0.8, 0.3, 0.4])
        XCTAssertEqual(Array(store.order.suffix(2)), saved.map(\.mutationID))
        let recovered = try NativePDFJournal(root: root).pending(courseID: course, relativePath: path)
        XCTAssertEqual(recovered.map { $0.input.clientMutationId }, saved.map(\.mutationID))
        XCTAssertEqual(recovered.map { $0.input.data.points }, saved.map(\.points))
        XCTAssertTrue(recovered.allSatisfy { $0.provisional != true })
        XCTAssertEqual(surface.objects.count, 202)
        let settledDeadline = CACurrentMediaTime() + 0.5
        while (imageView.image === beforeFinalCommit || !metal.strokes.isEmpty), CACurrentMediaTime() < settledDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = try XCTUnwrap(imageView.image)
        XCTAssertFalse(actual === beforeFinalCommit); XCTAssertTrue(metal.strokes.isEmpty)
        let mapper = try XCTUnwrap(surface.mapper), viewport = try XCTUnwrap(surface.renderViewport)
        let paper = try XCTUnwrap(NativePDFBackdropRenderer.render(page: try XCTUnwrap(surface.pdfPage), mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale))
        let format = UIGraphicsImageRendererFormat(); format.scale = paper.scale; format.opaque = true
        let reference = UIGraphicsImageRenderer(size: viewport.canvasRect.size, format: format).image { renderer in
            paper.draw(in: CGRect(origin: .zero, size: viewport.canvasRect.size))
            renderer.cgContext.translateBy(x: -viewport.canvasRect.minX, y: -viewport.canvasRect.minY)
            for object in surface.objects { NativePDFObjectRenderer.draw(object, in: renderer.cgContext, mapper: mapper, image: nil) }
        }
        XCTAssertTrue(try rgbaPixels(actual) == rgbaPixels(reference),
            "The final202-stroke image must match flat replay of the durable final pressures, without a duplicate live layer")
        let attachment = XCTAttachment(image: actual); attachment.name = "200-stroke late-pressure final scene"; attachment.lifetime = .keepAlways
        add(attachment)
        print("Late real-estimate fixture on200×96: correction callbacks \(correctionMS)ms; second firstsubmit \(nextFirstSubmit?.receiveToSubmitMS as Any)ms; fullrenders \(initialFullCount)")
    }

    private func rgbaPixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }
    func testRecognizerStartsImmediatelyAndResponderCannotDuplicateOrCancelItsStroke() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer()
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let touch = PencilGestureTouch(kind: .pencil), event = PencilGestureEvent(touch)
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        XCTAssertEqual(gesture.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.pencil.rawValue)])
        XCTAssertFalse(gesture.delaysTouchesBegan); XCTAssertFalse(gesture.delaysTouchesEnded)
        XCTAssertTrue(gesture.cancelsTouchesInView)
        XCTAssertFalse(gesture.canBePrevented(by: UILongPressGestureRecognizer()))
        gesture.touchesBegan([touch], with: event)
        XCTAssertEqual(gesture.state, .began)
        surface.touchesBegan([touch], with: event)
        surface.touchesCancelled([touch], with: event)
        XCTAssertTrue(saved.isEmpty, "Responder cancellation cannot truncate recognizer-owned ink")
        touch.point.x += 20; touch.currentTime += 0.01
        gesture.touchesMoved([touch], with: event)
        touch.currentTime += 0.01
        gesture.touchesEnded([touch], with: event)
        surface.touchesEnded([touch], with: event)
        XCTAssertEqual(saved.count, 1)
        XCTAssertGreaterThanOrEqual(saved[0].points.count, 2)
        XCTAssertEqual(gesture.state, .ended)
    }
    func testEstimatedCorrectionsReachTheirSurfaceAfterRecognizerReset() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer()
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let touch = PencilGestureTouch(kind: .pencil), event = PencilGestureEvent(touch)
        touch.estimateIndex = 7; touch.expecting = .force; touch.pressure = 0
        var checkpoints: [NativePDFCompletedStroke] = [], saved: [NativePDFCompletedStroke] = []
        surface.onCheckpoint = { checkpoints.append($0) }; surface.onStroke = { saved.append($0) }
        gesture.touchesBegan([touch], with: event)
        gesture.touchesEnded([touch], with: event)
        XCTAssertEqual(checkpoints.count, 1); XCTAssertTrue(saved.isEmpty)
        gesture.reset()
        touch.pressure = 0.8; touch.expecting = []
        gesture.touchesEstimatedPropertiesUpdated([touch])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.mutationID, checkpoints.first?.mutationID)
        XCTAssertEqual(saved.first?.points.first?.p, 0.8)
        XCTAssertEqual(saved.first?.points.first?.t, 0)
    }
    func testBatchedEstimatedSamplesCheckpointOnceBeforeCanonicalCompletion() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer()
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let first = PencilGestureTouch(kind: .pencil), second = PencilGestureTouch(kind: .pencil)
        first.estimateIndex = 31; second.estimateIndex = 32
        first.expecting = .force; second.expecting = .force
        first.pressure = 0.1; second.pressure = 0.2
        second.point.x += 20; second.currentTime += 0.004
        let event = PencilGestureEvent(first); event.coalesced = [first, second]
        var checkpoints: [NativePDFCompletedStroke] = [], saved: [NativePDFCompletedStroke] = [], order: [String] = []
        surface.onCheckpoint = { checkpoints.append($0); order.append("checkpoint") }
        surface.onStroke = { saved.append($0); order.append("commit") }
        gesture.touchesBegan([first], with: event)
        gesture.touchesEnded([first], with: event)
        XCTAssertEqual(checkpoints.count, 1); XCTAssertTrue(saved.isEmpty)
        gesture.reset()
        first.pressure = 0.3; second.pressure = 0.7
        first.expecting = []; second.expecting = []
        gesture.touchesEstimatedPropertiesUpdated([first, second])
        XCTAssertEqual(checkpoints.count, 2, "Corrected points reach disk before ordered completion")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(order, ["checkpoint", "checkpoint", "commit"])
        XCTAssertEqual(saved.first?.points.map(\.p), [0.3, 0.7], "Canonical completion uses both final corrected samples")
        XCTAssertEqual(saved.first?.points.map(\.t), checkpoints.first?.points.map(\.t))
        XCTAssertEqual(saved.first?.mutationID, checkpoints.first?.mutationID)
    }
    func testMissingTargetDoesNotStealEditorOrControlInput() throws {
        let surface = try surface(), gesture = NativePDFPencilGestureRecognizer(), host = UIView()
        var diagnostics: [String] = [], inputEvents: [String] = [], saved: [NativePDFCompletedStroke] = []
        gesture.onDiagnostic = { diagnostics.append($0) }
        surface.onDiagnostic = { inputEvents.append($0) }
        surface.onStroke = { saved.append($0) }
        host.addGestureRecognizer(gesture)
        gesture.targetAtLocation = { _ in nil }
        let touch = PencilGestureTouch(kind: .pencil)
        gesture.touchesBegan([touch], with: PencilGestureEvent(touch))
        // UIKit may immediately reset a failed recognizer back to .possible.
        // Assert the routing outcome rather than that transient state.
        XCTAssertTrue(diagnostics.contains("pencil.ignored-target"))
        XCTAssertTrue(inputEvents.isEmpty)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(gesture.canPrevent(UITapGestureRecognizer()))
    }
    func testFailedFinalCorrectionRetainsCorrectedStrokeForDurableRetry() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer()
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let touch = PencilGestureTouch(kind: .pencil), event = PencilGestureEvent(touch)
        touch.estimateIndex = 50; touch.expecting = .force; touch.pressure = 0.1
        var checkpoints: [NativePDFCompletedStroke] = [], saved: [NativePDFCompletedStroke] = [], failures = 0
        surface.onCheckpoint = { checkpoints.append($0) }
        surface.onStroke = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        surface.onFailure = { _ in failures += 1 }
        gesture.touchesBegan([touch], with: event); gesture.touchesEnded([touch], with: event); gesture.reset()
        touch.pressure = 0.8; touch.expecting = []
        gesture.touchesEstimatedPropertiesUpdated([touch])
        XCTAssertEqual(failures, 1); XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints.last?.points.first?.p, 0.8)
        XCTAssertEqual(surface.inputDiagnostics["journalBlocked"] as? Bool, true)
        surface.onStroke = { saved.append($0) }
        try surface.flush()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.points.first?.p, 0.8)
        XCTAssertEqual(saved.first?.mutationID, checkpoints.first?.mutationID)
        XCTAssertEqual(surface.inputDiagnostics["journalBlocked"] as? Bool, false)
    }
    func testCorrectionBlockedByEarlierStrokeIsCheckpointedBeforeOrderedCompletion() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer()
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let first = PencilGestureTouch(kind: .pencil), second = PencilGestureTouch(kind: .pencil)
        first.estimateIndex = 60; second.estimateIndex = 61
        first.expecting = .force; second.expecting = .force
        var checkpoints: [NativePDFCompletedStroke] = [], saved: [NativePDFCompletedStroke] = []
        surface.onCheckpoint = { checkpoints.append($0) }; surface.onStroke = { saved.append($0) }
        for touch in [first, second] {
            let event = PencilGestureEvent(touch)
            gesture.touchesBegan([touch], with: event); gesture.touchesEnded([touch], with: event); gesture.reset()
        }
        XCTAssertEqual(checkpoints.count, 2)
        second.pressure = 0.9; second.expecting = []
        gesture.touchesEstimatedPropertiesUpdated([second])
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(checkpoints.count, 3)
        XCTAssertEqual(checkpoints.last?.points.first?.p, 0.9)
        first.pressure = 0.7; first.expecting = []
        gesture.touchesEstimatedPropertiesUpdated([first])
        XCTAssertEqual(checkpoints.count, 4)
        XCTAssertEqual(saved.map(\.mutationID), checkpoints.prefix(2).map(\.mutationID))
        XCTAssertEqual(saved.map { $0.points[0].p }, [0.7, 0.9])
    }
    #if DEBUG
    func testDirectDispatchFixtureUsesTheSameInkOwnerAndPersistsAZeroPressureDot() throws {
        let surface = try surface(), host = UIView(frame: surface.bounds)
        host.addSubview(surface)
        let gesture = NativePDFPencilGestureRecognizer(testTouchType: .direct)
        host.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        let touch = PencilGestureTouch(kind: .direct), event = PencilGestureEvent(touch)
        touch.pressure = 0
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { saved.append($0) }
        gesture.touchesBegan([touch], with: event)
        // UIKit's recognizer may cancel an already-delivered responder touch.
        surface.touchesCancelled([touch], with: event)
        XCTAssertTrue(saved.isEmpty)
        gesture.touchesEnded([touch], with: event)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.points.count, 1)
        XCTAssertEqual(saved.first?.points.first?.p, 0)
    }
    #endif
}

/// A clock the laser session schedules on, advanced by hand.
@MainActor
private final class ManualLaserClock {
    private var now: TimeInterval = 0, serial = 0
    private var timers: [(id: Int, due: TimeInterval, body: @MainActor () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void {
        serial += 1; let id = serial
        timers.append((id, now + delay, body))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        while let next = timers.filter({ $0.due <= now }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }; next.body()
        }
    }
}

@MainActor
private final class PencilGestureTouch: UITouch {
    let kind: UITouch.TouchType
    var point = CGPoint(x: 100, y: 100)
    var currentTime: TimeInterval = 10
    var pressure: CGFloat = 0.5
    var estimateIndex: NSNumber?
    var expecting: UITouch.Properties = []
    init(kind: UITouch.TouchType) { self.kind = kind; super.init() }
    override var type: UITouch.TouchType { kind }
    override var timestamp: TimeInterval { currentTime }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { estimateIndex }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { point }
    override func preciseLocation(in view: UIView?) -> CGPoint { point }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

@MainActor
private final class PencilGestureEvent: UIEvent {
    let contact: UITouch
    var coalesced: [UITouch]?
    init(_ contact: UITouch) { self.contact = contact; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [contact] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { coalesced ?? [contact] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
