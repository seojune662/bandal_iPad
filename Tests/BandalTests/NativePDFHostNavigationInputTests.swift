import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit
import WebKit
@testable import Bandal

/// Exercises the actual Host's navigation-began wiring and its real on-disk
/// journal. The recognizer action and Pencil samples are synthetic: this is not
/// a UIKit gesture-arbitration, physical Pencil, or presentation-latency test.
@MainActor
final class NativePDFHostNavigationInputTests: XCTestCase {
    func testPanBeginKeepsActivePencilContactUntilItsActualLift() async throws {
        try await checkActiveContact(.pan)
    }

    func testPinchBeginKeepsActivePencilContactUntilItsActualLift() async throws {
        try await checkActiveContact(.pinch)
    }

    func testPanBeginDoesNotFinalizeLiftedStrokeAwaitingPressureCorrection() async throws {
        try await checkWaitingCorrection(.pan)
    }

    func testPinchBeginDoesNotFinalizeLiftedStrokeAwaitingPressureCorrection() async throws {
        try await checkWaitingCorrection(.pinch)
    }

    func testExplicitHostFlushStillFinalizesAndDurablyPreservesActiveInk() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let touch = fixture.touch(at: CGPoint(x: 0.25, y: 0.35), pressure: 1.0 / 12345)
        touch.estimateIndex = 401; touch.expecting = .force
        let event = HostNavigationEvent(touch)
        fixture.pencil.touchesBegan([touch], with: event)
        XCTAssertTrue(fixture.events.strokes.isEmpty)
        XCTAssertTrue(try fixture.records().isEmpty)

        _ = try await fixture.host.handle("pdfNative:flush", request: fixture.identity)

        XCTAssertEqual(fixture.events.strokes.count, 1)
        let final = try XCTUnwrap(fixture.records().first)
        XCTAssertNotEqual(final.provisional, true)
        XCTAssertEqual(final.input.data.points.count, 1)
        XCTAssertEqual(final.input.data.points.first?.p.bitPattern, (1.0 / 12345).bitPattern)
        try assertEmissionMatchesDisk(fixture, record: final)
        XCTAssertTrue(fixture.events.errors.isEmpty, fixture.events.errors.joined(separator: "; "))
    }

    private func checkActiveContact(_ navigation: Navigation) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let pressure = 17.0 / 12345
        let touch = fixture.touch(at: CGPoint(x: 0.25, y: 0.35), pressure: pressure)
        let event = HostNavigationEvent(touch)
        let startedAt = touch.currentTime
        var expected: [(x: UInt64, y: UInt64, p: UInt64, t: UInt64)] = []
        func captureExpected() throws {
            let mapper = try XCTUnwrap(fixture.surface.mapper)
            let point = mapper.normalized(touch.preciseLocation(in: fixture.surface), pressure: Double(touch.pressure))
            expected.append((point.x.bitPattern, point.y.bitPattern, point.p.bitPattern,
                             max(0, (touch.currentTime - startedAt) * 1000).bitPattern))
        }
        try captureExpected()
        fixture.pencil.touchesBegan([touch], with: event)
        XCTAssertTrue(fixture.events.strokes.isEmpty)

        try fixture.navigationBegan(navigation)
        try fixture.journalQueue.barrierSynchronously() // Test-only disk fence, without yielding/resetting the synthetic active recognizer.

        // RED's Host calls the real flush here: it emits only the first point
        // and discards this same contact's later moved/end callbacks.
        XCTAssertEqual(fixture.events.strokes.count, 0, "Navigation began must not emit a premature final stroke")
        XCTAssertTrue(try fixture.records().isEmpty, "The active contact must not be finalized by navigation")
        touch.currentPhase = .moved; touch.currentTime += 0.012
        fixture.place(touch, at: CGPoint(x: 0.37, y: 0.39))
        try captureExpected()
        fixture.pencil.touchesMoved([touch], with: event)
        touch.currentPhase = .ended; touch.currentTime += 0.012
        fixture.place(touch, at: CGPoint(x: 0.49, y: 0.43))
        try captureExpected()
        fixture.pencil.touchesEnded([touch], with: event)
        try await fixture.diskFence(expectedCompletions: 1)

        XCTAssertEqual(fixture.events.strokes.count, 1, "One Pencil contact must create exactly one completion")
        let records = try fixture.records()
        XCTAssertEqual(records.count, 1)
        let final = try XCTUnwrap(records.first)
        XCTAssertNotEqual(final.provisional, true)
        XCTAssertEqual(final.input.data.points.count, expected.count, "The post-navigation moved and lift samples must survive")
        for (point, sample) in zip(final.input.data.points, expected) {
            XCTAssertEqual(point.x.bitPattern, sample.x)
            XCTAssertEqual(point.y.bitPattern, sample.y)
            XCTAssertEqual(point.p.bitPattern, sample.p)
            XCTAssertEqual(point.t?.bitPattern, sample.t)
        }
        try assertEmissionMatchesDisk(fixture, record: final)
        XCTAssertTrue(fixture.events.errors.isEmpty, fixture.events.errors.joined(separator: "; "))
    }

    private func checkWaitingCorrection(_ navigation: Navigation) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let initialPressure = 1.0 / 12345, correctedPressure = 17.0 / 12345
        let touch = fixture.touch(at: CGPoint(x: 0.29, y: 0.41), pressure: initialPressure)
        touch.estimateIndex = 703; touch.expecting = .force
        let event = HostNavigationEvent(touch)
        fixture.pencil.touchesBegan([touch], with: event)
        // Re-delivering the same estimated sample at lift must keep one point.
        touch.currentPhase = .ended
        fixture.pencil.touchesEnded([touch], with: event)
        fixture.pencil.reset()
        try fixture.journalQueue.barrierSynchronously() // Test-only disk fence, without yielding/resetting the synthetic active recognizer.
        let before = try XCTUnwrap(fixture.records().first)
        XCTAssertEqual(before.provisional, true)
        XCTAssertEqual(before.input.data.points.count, 1)
        XCTAssertTrue(fixture.events.strokes.isEmpty, "An unresolved pressure estimate has only a durable provisional checkpoint")

        try fixture.navigationBegan(navigation)
        try fixture.journalQueue.barrierSynchronously() // Test-only disk fence, without yielding/resetting the synthetic active recognizer.

        let afterNavigation = try XCTUnwrap(fixture.records().first)
        XCTAssertEqual(afterNavigation.provisional, true, "Navigation must not force an unresolved checkpoint into canonical completion")
        XCTAssertEqual(afterNavigation.input.clientMutationId, before.input.clientMutationId)
        XCTAssertEqual(fixture.events.strokes.count, 0, "No premature canonical stroke event is allowed")
        assertPointBits(afterNavigation.input.data.points, before.input.data.points)

        touch.pressure = CGFloat(correctedPressure); touch.expecting = []
        fixture.pencil.touchesEstimatedPropertiesUpdated([touch])
        try await fixture.diskFence(expectedCompletions: 1)

        let records = try fixture.records()
        XCTAssertEqual(records.count, 1)
        let final = try XCTUnwrap(records.first)
        XCTAssertNotEqual(final.provisional, true)
        XCTAssertEqual(final.input.clientMutationId, before.input.clientMutationId, "Correction must promote the same durable mutation")
        XCTAssertEqual(fixture.events.strokes.count, 1)
        let oldPoint = try XCTUnwrap(before.input.data.points.first)
        let corrected = try XCTUnwrap(final.input.data.points.first)
        XCTAssertEqual(corrected.p.bitPattern, correctedPressure.bitPattern)
        XCTAssertEqual(corrected.x.bitPattern, oldPoint.x.bitPattern)
        XCTAssertEqual(corrected.y.bitPattern, oldPoint.y.bitPattern)
        XCTAssertEqual(corrected.t?.bitPattern, oldPoint.t?.bitPattern)
        XCTAssertEqual(corrected.tiltX?.bitPattern, oldPoint.tiltX?.bitPattern)
        XCTAssertEqual(corrected.tiltY?.bitPattern, oldPoint.tiltY?.bitPattern)
        try assertEmissionMatchesDisk(fixture, record: final)
        XCTAssertTrue(fixture.events.errors.isEmpty, fixture.events.errors.joined(separator: "; "))
    }

    private func assertPointBits(_ actual: [NativePDFPoint], _ expected: [NativePDFPoint],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x.bitPattern, b.x.bitPattern, file: file, line: line)
            XCTAssertEqual(a.y.bitPattern, b.y.bitPattern, file: file, line: line)
            XCTAssertEqual(a.p.bitPattern, b.p.bitPattern, file: file, line: line)
            XCTAssertEqual(a.t?.bitPattern, b.t?.bitPattern, file: file, line: line)
            XCTAssertEqual(a.tiltX?.bitPattern, b.tiltX?.bitPattern, file: file, line: line)
            XCTAssertEqual(a.tiltY?.bitPattern, b.tiltY?.bitPattern, file: file, line: line)
        }
    }

    private func assertEmissionMatchesDisk(_ fixture: Fixture, record: NativePDFPendingStroke) throws {
        let emitted = try XCTUnwrap(fixture.events.strokes.last)
        XCTAssertEqual(emitted["clientMutationId"] as? String, record.input.clientMutationId)
        XCTAssertEqual(emitted["documentRevision"] as? String, record.documentRevision)
        let payload = try XCTUnwrap(emitted["data"] as? [String: Any])
        let points = try XCTUnwrap(payload["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, record.input.data.points.count)
        for (wire, disk) in zip(points, record.input.data.points) {
            for (key, expected) in [("x", disk.x), ("y", disk.y), ("p", disk.p)] {
                XCTAssertEqual((wire[key] as? Double)?.bitPattern, expected.bitPattern)
            }
            for (key, expected) in [("t", disk.t), ("tiltX", disk.tiltX), ("tiltY", disk.tiltY)] {
                XCTAssertEqual((wire[key] as? Double)?.bitPattern, expected?.bitPattern)
            }
        }
        XCTAssertEqual(fixture.events.durableAtEmission.count, fixture.events.strokes.count)
        let alreadyDurable = try XCTUnwrap(fixture.events.durableAtEmission.last)
        XCTAssertEqual(alreadyDurable.input.clientMutationId, record.input.clientMutationId)
        XCTAssertNotEqual(alreadyDurable.provisional, true, "The real file barrier must complete before Host emits canonical ink")
        assertPointBits(alreadyDurable.input.data.points, record.input.data.points)
    }

    private enum Navigation { case pan, pinch }

    @MainActor private final class Events {
        var strokes: [[String: Any]] = []
        var durableAtEmission: [NativePDFPendingStroke] = []
        var errors: [String] = []
    }

    @MainActor private final class Fixture {
        let journalQueue: NativePDFJournalQueue
        let root: URL, host: NativePDFHost, window: UIWindow, controller: UIViewController
        let shell: WKWebView, surface: NativePDFInkSurface, pencil: NativePDFPencilGestureRecognizer
        let identity: [String: Any], events: Events
        let previousWindow: UIWindow?, previousEnabled: Any?
        init(root: URL, host: NativePDFHost, journalQueue: NativePDFJournalQueue, window: UIWindow, controller: UIViewController, shell: WKWebView,
             surface: NativePDFInkSurface, identity: [String: Any], events: Events,
             previousWindow: UIWindow?, previousEnabled: Any?) {
            self.journalQueue = journalQueue
            self.root = root; self.host = host; self.window = window; self.controller = controller
            self.shell = shell; self.surface = surface; self.identity = identity; self.events = events
            self.previousWindow = previousWindow; self.previousEnabled = previousEnabled
            pencil = NativePDFPencilGestureRecognizer()
            pencil.targetAtLocation = { [weak surface] _ in surface }
            controller.view.addGestureRecognizer(pencil)
        }
        func diskFence(expectedCompletions: Int) async throws {
            // Do not call Host.flush: it would finalize the unresolved pressure
            // sample whose preservation this navigation regression verifies.
            try await journalQueue.barrier()
            let deadline = CACurrentMediaTime() + 2
            while events.strokes.count < expectedCompletions, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertEqual(events.strokes.count, expectedCompletions)
        }
        func records() throws -> [NativePDFPendingStroke] {
            try NativePDFJournal(root: root).pending(courseID: "navigation-course", relativePath: "fixture.pdf")
        }
        func place(_ touch: HostNavigationTouch, at normalized: CGPoint) {
            guard let mapper = surface.mapper else { XCTFail("Fixture lost its page mapper"); return }
            let canvas = mapper.canvasPoint(InkPoint(x: Double(normalized.x), y: Double(normalized.y), p: 0.5))
            touch.point = surface.convert(canvas, to: window)
        }
        func touch(at normalized: CGPoint, pressure: Double) -> HostNavigationTouch {
            let touch = HostNavigationTouch(window: window, pressure: pressure)
            place(touch, at: normalized); return touch
        }
        func navigationBegan(_ navigation: Navigation) throws {
            // Mirror only the app-owned dictionary. Never inspect PDFKit/UIKit
            // private objects or manufacture a stand-in document implementation.
            let storage = try XCTUnwrap(Mirror(reflecting: host).children.first { $0.label == "documents" }?.value)
            let entry = try XCTUnwrap(Mirror(reflecting: storage).children.first?.value)
            let fields = Array(Mirror(reflecting: entry).children)
            XCTAssertEqual(fields.first?.value as? String, identity["surfaceId"] as? String)
            let document = try XCTUnwrap(fields.last?.value as? NSObject)
            let selector = NSSelectorFromString(navigation == .pan ? "panChanged:" : "pinchChanged:")
            XCTAssertTrue(document.responds(to: selector), "Test must invoke the actual Host document selector")
            guard document.responds(to: selector) else { return }
            let recognizer: UIGestureRecognizer = navigation == .pan
                ? HostNavigationBeganPan(target: nil, action: nil)
                : HostNavigationBeganPinch(target: nil, action: nil)
            _ = document.perform(selector, with: recognizer)
        }
        func close() {
            host.closeAll(); host.emit = { _, _ in }
            controller.view.removeGestureRecognizer(pencil)
            window.isHidden = true; previousWindow?.makeKeyAndVisible()
            UserDefaults.standard.set(previousEnabled, forKey: "bandal.nativePDF.enabled")
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-navigation-input-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        var completed = false
        defer {
            if !completed {
                UserDefaults.standard.set(previousEnabled, forKey: "bandal.nativePDF.enabled")
                try? FileManager.default.removeItem(at: root)
            }
        }
        let source = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage(); context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }.write(to: source)
        let deadline = CACurrentMediaTime() + 3
        while !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene && $0.activationState == .foregroundActive }), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "The isolated UIKit host must have an active scene")
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { if !completed { window.isHidden = true; previousWindow?.makeKeyAndVisible() } }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let shell = WKWebView(frame: controller.view.bounds, configuration: configuration)
        controller.view.addSubview(shell)
        let journalQueue = NativePDFJournalQueue(root: root)
        let host = try NativePDFHost(root: root, journalQueue: journalQueue) { channel, request in
            if channel == "nativeMaterial:path" { return source.path }
            if channel == "nativePDF:binding" {
                return ["materialID": "navigation-fixture", "documentRevision": try XCTUnwrap(request["documentRevision"] as? String)]
            }
            XCTFail("Unexpected private backend call: \(channel)")
            throw NSError(domain: "HostNavigationFixture", code: 1)
        }
        defer { if !completed { host.closeAll() } }
        let events = Events()
        host.emit = { channel, value in
            guard channel == "pdfNative:event", let event = value as? [String: Any], let payload = event["payload"] as? [String: Any] else { return }
            if event["type"] as? String == "stroke" {
                events.strokes.append(payload)
                do {
                    let records = try NativePDFJournal(root: root).pending(courseID: "navigation-course", relativePath: "fixture.pdf")
                    if let record = records.first(where: { $0.input.clientMutationId == payload["clientMutationId"] as? String }) {
                        events.durableAtEmission.append(record)
                    } else { events.errors.append("Canonical event had no matching on-disk record") }
                } catch { events.errors.append(error.localizedDescription) }
            } else if event["type"] as? String == "error" { events.errors.append(payload["message"] as? String ?? "Unknown Host error") }
        }
        host.attach(to: controller.view, shell: shell)
        let identity: [String: Any] = ["surfaceId": "navigation-input", "generation": UUID().uuidString,
                                       "courseId": "navigation-course", "relPath": "fixture.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging([
            "visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]
        ]) { _, next in next })
        _ = try await host.handle("pdfNative:snapshot", request: identity.merging([
            "loading": false, "active": true, "drawings": [], "annotations": [],
            "tool": ["name": "pen", "style": ["color": "blue", "width": 0.004, "opacity": 0.7]]
        ]) { _, next in next })
        func surfaces(_ view: UIView) -> [NativePDFInkSurface] {
            (view as? NativePDFInkSurface).map { [$0] } ?? view.subviews.flatMap(surfaces)
        }
        let readyDeadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < readyDeadline {
            controller.view.layoutIfNeeded(); host.layout()
            if let surface = surfaces(controller.view).first, surface.mapper != nil,
               surface.window === window, surface.renderViewport != nil {
                completed = true
                return Fixture(root: root, host: host, journalQueue: journalQueue, window: window, controller: controller, shell: shell,
                    surface: surface, identity: identity, events: events,
                    previousWindow: previousWindow, previousEnabled: previousEnabled)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Actual Host page overlay did not acquire its mapper and viewport")
        throw NSError(domain: "HostNavigationFixture", code: 2)
    }
}

@MainActor
private final class HostNavigationTouch: UITouch {
    let fixtureWindow: UIWindow
    var point = CGPoint.zero
    var pressure: CGFloat
    var currentTime = CACurrentMediaTime()
    var currentPhase: UITouch.Phase = .began
    var estimateIndex: NSNumber?
    var expecting: UITouch.Properties = []
    init(window: UIWindow, pressure: Double) { fixtureWindow = window; self.pressure = CGFloat(pressure); super.init() }
    override var window: UIWindow? { fixtureWindow }
    override var type: UITouch.TouchType { .pencil }
    override var phase: UITouch.Phase { currentPhase }
    override var timestamp: TimeInterval { currentTime }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { estimateIndex }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint {
        view?.convert(point, from: fixtureWindow) ?? fixtureWindow.convert(point, to: nil)
    }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

@MainActor
private final class HostNavigationEvent: UIEvent {
    let contact: UITouch
    init(_ contact: UITouch) { self.contact = contact; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [contact] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [contact] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}

@MainActor
private final class HostNavigationBeganPan: UIPanGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .began } set {} }
}

@MainActor
private final class HostNavigationBeganPinch: UIPinchGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .began } set {} }
}
