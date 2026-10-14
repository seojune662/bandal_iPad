import XCTest
import UIKit
@testable import Bandal

/// These unit fixtures verify routing, de-duplication, and late corrections.
/// Real UIKit dispatch is covered separately by the UI-test-only direct-touch
/// host. Neither fixture substitutes for physical Apple Pencil acceptance.
@MainActor
final class NativePDFPencilGestureTests: XCTestCase {
    private func surface() throws -> NativePDFInkSurface {
        let surface = try XCTUnwrap(NativePDFInkSurface())
        surface.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        surface.mapper = .whiteboard(size: surface.bounds.size)
        surface.tool = .init(name: "pen", style: .init(color: "ink", width: 0.004, opacity: 1))
        surface.isLoading = false
        return surface
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
    init(_ contact: UITouch) { self.contact = contact; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [contact] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [contact] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
