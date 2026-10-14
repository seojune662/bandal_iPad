import XCTest
import PDFKit
import WebKit
@testable import Bandal

@MainActor
final class NativePDFHostTests: XCTestCase {
    /// Public UITouch/UIEvent fixtures exercise UIKit hit testing and the real
    /// measured gesture callbacks. This fixture does not exercise UIKit dispatch
    /// arbitration; the workspace UI test does. Neither synthesizes hardware Pencil input
    /// or claim to exercise the system's handwriting recognizer.
    func testPencilRoutesThroughPDFBodyAndCompletesMeasuredInkWithoutScribble() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-input-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        let source = root.appendingPathComponent("input.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage(); ("Select this original PDF text" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }.write(to: source)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" { return ["materialID": "fixture", "documentRevision": request["documentRevision"]!] }
            return source.path
        }
        host.attach(to: controller.view, shell: shell); defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "input", "generation": "one", "courseId": "course", "relPath": "input.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        func snapshot(_ name: String, loading: Bool = false) async throws {
            _ = try await host.handle("pdfNative:snapshot", request: identity.merging(["loading": loading, "active": false, "drawings": [], "annotations": [],
                "tool": ["name": name, "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]]) { _, new in new })
        }
        try await snapshot("pen")
        func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) } }
        let deadline = Date().addingTimeInterval(10)
        while (find(NativePDFInkSurface.self, in: controller.view).first?.mapper == nil) && Date() < deadline {
            controller.view.layoutIfNeeded(); host.layout(); try await Task.sleep(for: .milliseconds(30))
        }
        let surface = try XCTUnwrap(find(NativePDFInkSurface.self, in: controller.view).first)
        let body = try XCTUnwrap(find(NativePDFApertureView.self, in: controller.view).first)
        XCTAssertTrue(body.isInMarkupMode, "Drawing tools must enable PDFKit's overlay interaction")
        let point = surface.convert(CGPoint(x: surface.bounds.width * 0.35, y: surface.bounds.height * 0.45), to: window)
        let touch = NativePDFTestTouch(point: point, kind: .pencil), event = NativePDFTestEvent(touch: touch)
        var activations = 0, diagnostics: [String] = [], completions: [[String: Any]] = []
        host.onDiagnostic = { event, code in diagnostics.append("\(event):\(code)") }
        host.emit = { _, payload in
            guard let value = payload as? [String: Any] else { return }
            if value["type"] as? String == "activate" { activations += 1 }
            if value["type"] as? String == "stroke", let stroke = value["payload"] as? [String: Any] { completions.append(stroke) }
        }
        let target = window.hitTest(point, with: event)
        XCTAssertTrue(target === surface, "Pencil must reach the actual provider overlay through the entire UIKit hierarchy")
        XCTAssertGreaterThan(activations, 0, "First Pencil contact must activate an inactive split")
        let bodyScribble = try XCTUnwrap(body.interactions.compactMap { $0 as? UIScribbleInteraction }.first)
        let inkScribble = try XCTUnwrap(surface.interactions.compactMap { $0 as? UIScribbleInteraction }.first)
        XCTAssertFalse(body.scribbleInteraction(bodyScribble, shouldBeginAt: body.convert(point, from: window)))
        XCTAssertFalse(surface.scribbleInteraction(inkScribble, shouldBeginAt: surface.convert(point, from: window)))
        func recognizer() -> NativePDFPencilGestureRecognizer {
            let value = NativePDFPencilGestureRecognizer()
            value.targetAtLocation = { body.pencilInputTarget(at: $0) as? NativePDFInkSurface }
            body.addGestureRecognizer(value)
            return value
        }
        let gesture = recognizer()
        gesture.touchesBegan([touch], with: event)
        touch.currentPhase = .moved; touch.currentTime += 0.012; touch.point.x += 25
        gesture.touchesMoved([touch], with: event)
        touch.currentPhase = .ended; touch.currentTime += 0.012; touch.point.x += 25
        gesture.touchesEnded([touch], with: event)
        body.removeGestureRecognizer(gesture)
        XCTAssertEqual(completions.count, 1)
        let points = try XCTUnwrap((completions.first?["data"] as? [String: Any])?["points"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(points.count, 3)
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "input.pdf").count, 1)
        XCTAssertTrue(diagnostics.contains { $0.contains("pen.pencil.begin.1") })
        XCTAssertTrue(diagnostics.contains { $0.contains("pen.pencil.end.1") })
        XCTAssertTrue(diagnostics.contains { $0.contains("ink.commit.1") })
        for (tool, moves) in [("pen", false), ("highlighter", true)] {
            try await snapshot(tool)
            let contact = NativePDFTestTouch(point: point, kind: .pencil)
            if !moves { contact.currentForce = 0 }
            let contactEvent = NativePDFTestEvent(touch: contact), recipient = window.hitTest(point, with: contactEvent)
            XCTAssertTrue(recipient === surface, tool)
            let contactGesture = recognizer()
            contactGesture.touchesBegan([contact], with: contactEvent)
            if moves {
                contact.currentPhase = .moved; contact.currentTime += 0.012; contact.point.x += 30
                contactGesture.touchesMoved([contact], with: contactEvent)
                contact.currentTime += 0.012; contact.point.x += 30
            }
            // A dot contains one actual sample: do not invent a move or time.
            contact.currentPhase = .ended
            contactGesture.touchesEnded([contact], with: contactEvent)
            body.removeGestureRecognizer(contactGesture)
        }
        XCTAssertEqual(completions.compactMap { $0["kind"] as? String }, ["ink", "ink", "highlighter"])
        let dotPoints = try XCTUnwrap((completions[1]["data"] as? [String: Any])?["points"] as? [[String: Any]])
        XCTAssertEqual(dotPoints.count, 1, "A single Pencil tap is a persisted dot")
        XCTAssertEqual(dotPoints.first?["p"] as? Double, 0, "A real zero pressure sample remains zero")
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "input.pdf").count, 3)
        XCTAssertTrue(diagnostics.contains { $0.contains("highlighter.pencil.begin.1") })
        XCTAssertTrue(diagnostics.contains { $0.contains("highlighter.commit.1") })
        try await snapshot("select")
        XCTAssertFalse(body.isInMarkupMode, "Finger text selection keeps PDFKit's normal reading mode")
        touch.currentPhase = .began
        XCTAssertTrue(window.hitTest(touch.point, with: event) === surface, "Pencil object selection still reaches the overlay in reading mode")
        let finger = NativePDFTestTouch(point: touch.point, kind: .direct)
        XCTAssertFalse(window.hitTest(finger.point, with: NativePDFTestEvent(touch: finger)) === surface, "A finger on blank paper belongs to PDFKit")
        let aperturePoint = body.convert(touch.point, from: window)
        body.excludedRects = [CGRect(x: aperturePoint.x-5, y: aperturePoint.y-5, width: 10, height: 10)]
        XCTAssertFalse(window.hitTest(touch.point, with: event) === surface, "Explicit text editor holes pass through to the web editor")
        body.excludedRects = []
        try await snapshot("pen", loading: true)
        XCTAssertNil(body.pencilInputTarget(at: body.convert(touch.point, from: window)))
        XCTAssertTrue(diagnostics.contains { $0.contains("pen.pencil.blocked.loading") })
    }
    func testDevelopmentComparisonTogglePersistsWithoutReplacingOpenDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-setting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        UserDefaults.standard.set(false, forKey: "bandal.nativePDF.enabled")
        let host = try NativePDFHost(root: root) { _, _ in XCTFail("A setting must not read or replace a PDF"); return NSNull() }
        let before = try await host.handle("pdfNative:capabilities", request: [:]) as? [String: Any]
        XCTAssertEqual(before?["enabled"] as? Bool, false)
        XCTAssertEqual(before?["development"] as? Bool, true)
        let changed = try await host.handle("pdfNative:setEnabled", request: ["enabled": true]) as? [String: Any]
        XCTAssertEqual(changed?["enabled"] as? Bool, true)
        let reopened = try NativePDFHost(root: root) { _, _ in XCTFail("A setting must not open a PDF"); return NSNull() }
        let after = try await reopened.handle("pdfNative:capabilities", request: [:]) as? [String: Any]
        XCTAssertEqual(after?["enabled"] as? Bool, true)
        do { _ = try await reopened.handle("pdfNative:setEnabled", request: ["enabled": "yes"]); XCTFail("Reject malformed setting values") } catch {}
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "bandal.nativePDF.enabled"))
    }
    func testNativeCompletionIsJournaledBeforeEventAndReplayedAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-host-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        let url = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage(); ("Native PDF fixture" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }.write(to: url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        func host() throws -> NativePDFHost {
            let value = try NativePDFHost(root: root) { channel, request in
                XCTAssertEqual(request["relPath"] as? String, "fixture.pdf")
                if channel == "nativePDF:binding" {
                    return ["materialID": "fixture-material", "documentRevision": request["documentRevision"]!, "evidence": "first-observed", "legacyUnverified": false]
                }
                XCTAssertEqual(channel, "nativeMaterial:path")
                return url.path
            }
            value.attach(to: controller.view, shell: shell); return value
        }
        let first = try host(), identity: [String: Any] = ["surfaceId": "test", "generation": "one", "courseId": "course", "relPath": "fixture.pdf"]
        defer { first.closeAll() }
        let opened = try await first.handle("pdfNative:open", request: identity) as? [String: Any]
        XCTAssertEqual(opened?["numPages"] as? Int, 1)
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        _ = try await first.handle("pdfNative:snapshot", request: identity.merging(["loading": false, "drawings": [], "annotations": [], "tool": ["name": "pen", "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]]) { _, new in new })
        func surfaces(_ view: UIView) -> [NativePDFInkSurface] { (view as? NativePDFInkSurface).map { [$0] } ?? view.subviews.flatMap(surfaces) }
        let deadline = Date().addingTimeInterval(10)
        while surfaces(controller.view).isEmpty && Date() < deadline {
            controller.view.layoutIfNeeded(); first.layout(); try await Task.sleep(for: .milliseconds(30))
        }
        let surface = try XCTUnwrap(surfaces(controller.view).first)
        var completed: [String: Any]?
        first.emit = { channel, body in
            guard channel == "pdfNative:event", let event = body as? [String: Any], event["type"] as? String == "stroke" else { return }
            completed = event["payload"] as? [String: Any]
            XCTAssertEqual(try? NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").count, 1, "Journal must precede completion delivery")
        }
        try surface.onStroke?(.init(mutationID: UUID().uuidString.lowercased(), kind: "ink", points: [.init(x: 0.2, y: 0.3, p: 0, t: 0), .init(x: 0.2, y: 0.3, p: 1, t: 12)], style: .init(color: "blue", width: 0.004, opacity: 1)))
        let completedID = try XCTUnwrap(completed?["clientMutationId"] as? String)
        XCTAssertEqual(completed?["documentRevision"] as? String, opened?["revision"] as? String)
        _ = try await first.handle("pdfNative:navigate", request: identity.merging(["page": 1, "zoom": 1.6, "progress": 0.45]) { _, new in new })
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": false]) { _, new in new })
        let sleeping = try await first.handle("pdfNative:diagnostics", request: identity) as? [String: Any]
        XCTAssertEqual(sleeping?["suspended"] as? Bool, true)
        XCTAssertEqual(sleeping?["retainedPages"] as? Int, 0, "Inactive tab must release page/Metal surfaces")
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").count, 1)
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        let awake = try await first.handle("pdfNative:diagnostics", request: identity) as? [String: Any]
        XCTAssertEqual(awake?["suspended"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(awake?["zoom"] as? Double), 1.6, accuracy: 0.01, "Restoration must retain the original viewport")
        first.closeAll()
        let reopened = try host(); defer { reopened.closeAll() }
        var next = identity; next["generation"] = "two"
        let state = try await reopened.handle("pdfNative:open", request: next) as? [String: Any]
        let pending = try XCTUnwrap(state?["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?["clientMutationId"] as? String, completedID)
        let measured = (pending.first?["data"] as? [String: Any])?["points"] as? [[String: Any]]
        XCTAssertEqual(measured?.count, 2); XCTAssertEqual(measured?.first?["p"] as? Double, 0)
        _ = try await reopened.handle("pdfNative:ack", request: next.merging(["clientMutationId": completedID, "drawingId": "durable-backend-id"]) { _, new in new })
        let drained = try await reopened.handle("pdfNative:flush", request: next) as? [String: Any]
        XCTAssertEqual((drained?["pending"] as? [Any])?.count, 0)
        do { _ = try await reopened.handle("pdfNative:snapshot", request: identity); XCTFail("Old generation must not update a replacement PDF surface") } catch {}
    }
}

@MainActor
private final class NativePDFTestTouch: UITouch {
    var point: CGPoint
    let kind: UITouch.TouchType
    var currentPhase: UITouch.Phase = .began
    var currentTime: TimeInterval = 100
    var currentForce: CGFloat = 0.5
    init(point: CGPoint, kind: UITouch.TouchType) { self.point = point; self.kind = kind; super.init() }
    override var type: UITouch.TouchType { kind }
    override var phase: UITouch.Phase { currentPhase }
    override var timestamp: TimeInterval { currentTime }
    override var force: CGFloat { currentForce }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { nil }
    override var estimatedProperties: UITouch.Properties { [] }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { [] }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: nil) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

@MainActor
private final class NativePDFTestEvent: UIEvent {
    let touch: UITouch
    init(touch: UITouch) { self.touch = touch; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [touch] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [touch] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
