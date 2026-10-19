import XCTest
import PDFKit
import WebKit
@testable import Bandal

@MainActor
final class NativePDFHostTests: XCTestCase {
    func testLocalPrivateDocumentReplayInvestigatesRepeatedLayouts() async throws {
        // Opt-in local diagnostic. The directory contains paper.pdf and rows.json;
        // no private document contents or machine-specific path is stored in Git.
        guard let fixturePath = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"],
              !fixturePath.isEmpty else { throw XCTSkip("Set BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY for a local document replay") }
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let privatePDF = fixture.appendingPathComponent("paper.pdf"), privateRows = fixture.appendingPathComponent("rows.json")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: privateRows)) as? [[String: Any]])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-private-replay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("replay.pdf"); try FileManager.default.copyItem(at: privatePDF, to: source)
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" { return try NativePDFTestBinding.respond(root: root, file: source, materialID: "replay") }
            return source.path
        }
        host.onDiagnostic = { event, code in
            if code.contains("mapper.") || code.contains("render.") { print("[PRIVATE_REPLAY] \(event) \(code)") }
        }
        host.attach(to: controller.view, shell: shell); defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "private-replay", "generation": "one", "courseId": "private-replay", "relPath": "replay.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        let layoutRequest = identity.merging(["visible": true,
            "rect": ["x": 0.1,"y": 0.3,"width": 1193.8,"height": 765.6],
            "holes": [["x": 64.1,"y": 22.5,"width": 660.0,"height": 62.0]]]) { _, new in new }
        _ = try await host.handle("pdfNative:layout", request: layoutRequest)
        let request = identity.merging(["loading": false,"active": true,"drawings": rows,"annotations": [],
            "tool": ["name": "pen","style": ["color": "blue","width": 0.004,"opacity": 1.0]]]) { _, new in new }
        _ = try await host.handle("pdfNative:snapshot", request: request)
        func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) } }
        let setupDeadline = CACurrentMediaTime() + 10
        while (find(NativePDFInkSurface.self,in: controller.view).first?.mapper == nil) && CACurrentMediaTime() < setupDeadline {
            controller.view.layoutIfNeeded(); host.layout(); try await Task.sleep(for: .milliseconds(20))
        }
        let surface = try XCTUnwrap(find(NativePDFInkSurface.self,in: controller.view).first)
        _ = try await host.handle("pdfNative:navigate", request: identity.merging(["page": 1,"zoom": 1.0,"progress": 0.3,"horizontalProgress": 0.5]) { _, new in new })
        try await Task.sleep(for: .milliseconds(1500))
        print("[PRIVATE_REPLAY] initial \(surface.inputDiagnostics) mapper=\(String(describing: surface.mapper)) viewport=\(String(describing: surface.renderViewport))")
        let initialFull = surface.inputDiagnostics["sceneFullRenders"] as? Int ?? -1
        let initialMapperChanges = surface.inputDiagnostics["mapperInvalidations"] as? Int ?? -1
        for iteration in 0..<12 {
            _ = try await host.handle("pdfNative:layout", request: layoutRequest)
            _ = try await host.handle("pdfNative:snapshot", request: request)
            surface.setNeedsLayout(); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); host.layout()
            try await Task.sleep(for: .milliseconds(50))
            print("[PRIVATE_REPLAY] iteration\(iteration) full=\(surface.inputDiagnostics["sceneFullRenders"]!) mapperChanges=\(surface.inputDiagnostics["mapperInvalidations"]!) viewportChanges=\(surface.inputDiagnostics["navigationRefreshCount"]!) scene=\(surface.inputDiagnostics["sceneRenderMode"]!)")
        }
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int,initialFull)
        XCTAssertEqual(surface.inputDiagnostics["mapperInvalidations"] as? Int,initialMapperChanges)
    }
    func testNativePinchFallbackUsesAbsoluteBeganScaleAndRequiresRepeatedNoOp() throws {
        var session = try XCTUnwrap(NativePDFPinchZoomSession(pdfScale: 1.926, recognizerScale: 1.926))
        XCTAssertNil(session.targetScale(recognizerScale: 2.024, actualPDFScale: 1.926, minimum: 0.77, maximum: 7.7, ended: false))
        XCTAssertFalse(session.usingFallback)
        XCTAssertEqual(try XCTUnwrap(session.targetScale(recognizerScale: 2.118, actualPDFScale: 1.926,
            minimum: 0.77, maximum: 7.7, ended: false)), 2.118, accuracy: 0.000001)
        XCTAssertTrue(session.usingFallback)
        XCTAssertEqual(try XCTUnwrap(session.targetScale(recognizerScale: 3.274, actualPDFScale: 2.118,
            minimum: 0.77, maximum: 7.7, ended: true)), 3.274, accuracy: 0.000001)
    }
    func testWorkingNativePinchNeverEntersFallbackEvenWhenReturningToStartScale() throws {
        var session = try XCTUnwrap(NativePDFPinchZoomSession(pdfScale: 2, recognizerScale: 2))
        XCTAssertNil(session.targetScale(recognizerScale: 2.1, actualPDFScale: 2.1, minimum: 0.8, maximum: 8, ended: false))
        for raw in [2.2, 2.3, 3] as [CGFloat] {
            XCTAssertNil(session.targetScale(recognizerScale: raw, actualPDFScale: 2, minimum: 0.8, maximum: 8, ended: false))
        }
        XCTAssertFalse(session.usingFallback)
    }
    func testDuplicatePinchCallbacksAllowDelayedNativeZoomToCatchUp() throws {
        var session = try XCTUnwrap(NativePDFPinchZoomSession(pdfScale: 3.076, recognizerScale: 3.076))
        for _ in 0..<4 {
            XCTAssertNil(session.targetScale(recognizerScale: 3.034, actualPDFScale: 3.076,
                minimum: 0.77, maximum: 7.7, ended: false))
        }
        XCTAssertFalse(session.usingFallback, "Repeated delivery of one sample must not take ownership from PDFKit")
        XCTAssertNil(session.targetScale(recognizerScale: 2.98, actualPDFScale: 3.034,
            minimum: 0.77, maximum: 7.7, ended: false))
        XCTAssertFalse(session.usingFallback)
    }
    func testNativePinchFinalCapturedScaleSurvivesRecognizerResetAndClamps() throws {
        var short = try XCTUnwrap(NativePDFPinchZoomSession(pdfScale: 1.926, recognizerScale: 1.926))
        // The ended callback captured3.274 before UIKit reset its property to1.
        XCTAssertEqual(try XCTUnwrap(short.targetScale(recognizerScale: 3.274, actualPDFScale: 1.926,
            minimum: 0.77, maximum: 7.7, ended: true)), 3.274, accuracy: 0.000001)
        XCTAssertEqual(short.targetScale(recognizerScale: 100, actualPDFScale: 3.274, minimum: 0.77, maximum: 7.7, ended: false), 7.7)
        XCTAssertEqual(short.targetScale(recognizerScale: 0.01, actualPDFScale: 7.7, minimum: 0.77, maximum: 7.7, ended: true), 0.77)
        XCTAssertNil(short.targetScale(recognizerScale: .nan, actualPDFScale: 1, minimum: 0.77, maximum: 7.7, ended: false))
    }
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
            if channel == "nativePDF:binding" { return try NativePDFTestBinding.respond(root: root, file: source, materialID: "fixture") }
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
        XCTAssertFalse(body.isInMarkupMode, "Pencil routing must preserve PDFKit's native finger navigation")
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
        _ = try await host.handle("pdfNative:flush", request: identity)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual((completions.first?["data"] as? [String: Any])?["inkVersion"] as? Int, 5)
        let points = try XCTUnwrap((completions.first?["data"] as? [String: Any])?["points"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(points.count, 3)
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "input.pdf").count, 1)
        XCTAssertTrue(diagnostics.contains { $0.contains("pen.pencil.begin.1") })
        XCTAssertTrue(diagnostics.contains { $0.contains("pen.pencil.end.1") })
        XCTAssertTrue(diagnostics.contains { $0.contains("ink.commit.1") })
        for (tool, moves) in [("pen", false), ("highlighter", true)] {
            try await snapshot(tool)
            XCTAssertFalse(body.isInMarkupMode, "\(tool) must retain PDFKit's native finger navigation")
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
        _ = try await host.handle("pdfNative:flush", request: identity)
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
    func testImmediateNavigateFlushAndHiddenViewportRetainActualPageAndZoom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-viewport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("three-pages.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            for number in 1...3 { context.beginPage(); ("Page \(number)" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 20)]) }
        }.write(to: url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let host = try NativePDFHost(root: root, directEnabled: true) { channel, request in
            if channel == "nativePDF:binding" { return try NativePDFTestBinding.respond(root: root, file: url, materialID: "viewport") }
            return url.path
        }
        host.attach(to: controller.view); defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "viewport", "generation": "one", "courseId": "course", "relPath": "three-pages.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": true,
            "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        controller.view.layoutIfNeeded(); host.layout()
        var receivedPage = 0
        host.emit = { channel, value in
            guard channel == "pdfNative:event", let event = value as? [String: Any], event["type"] as? String == "viewport" else { return }
            receivedPage = (event["payload"] as? [String: Any])?["page"] as? Int ?? 0
        }
        _ = try await host.handle("pdfNative:navigate", request: identity.merging([
            "page": 2, "zoom": 1.6, "progress": 0.6, "horizontalProgress": 0.5]) { _, new in new })
        // No event-delay sleep: this is the exact close/tab-switch barrier.
        let result = try await host.handle("pdfNative:flush", request: identity) as? [String: Any]
        let viewport = try XCTUnwrap(result?["viewport"] as? [String: Any])
        XCTAssertEqual(viewport["page"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(viewport["zoom"] as? Double), 1.6, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(viewport["progress"] as? Double), 0.6, accuracy: 0.025)
        XCTAssertNotNil(NativePDFWorkspacePreferences.Viewport(revision: "fixture-revision", values: viewport),
                        "The direct host reply must be usable for exact scroll persistence without a JSON bridge")
        let deadline = Date().addingTimeInterval(2)
        while receivedPage != 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(receivedPage, 2, "Programmatic navigation must publish after leaving the navigation guard")
        _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": false]) { _, new in new })
        let hidden = try await host.handle("pdfNative:flush", request: identity) as? [String: Any]
        let hiddenViewport = try XCTUnwrap(hidden?["viewport"] as? [String: Any])
        XCTAssertEqual(hiddenViewport["page"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(hiddenViewport["zoom"] as? Double), 1.6, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(hiddenViewport["progress"] as? Double), 0.6, accuracy: 0.025)
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
                    return try NativePDFTestBinding.respond(root: root, file: url, materialID: "fixture-material").merging(["evidence": "first-observed", "legacyUnverified": false]) { _, new in new }
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
        let pendingStroke = NativePDFCompletedStroke(mutationID: UUID().uuidString.lowercased(), kind: "ink",
            points: [.init(x: 0.2, y: 0.3, p: 0, t: 0), .init(x: 0.2, y: 0.3, p: 1, t: 12)], style: .init(color: "blue", width: 0.004, opacity: 1))
        try surface.onCheckpoint?(pendingStroke)
        let second = try host(); defer { second.closeAll() }
        var secondIdentity = identity; secondIdentity["surfaceId"] = "other-pane"; secondIdentity["generation"] = "other-generation"
        let secondState = try await second.handle("pdfNative:open", request: secondIdentity) as? [String: Any]
        XCTAssertTrue((secondState?["pending"] as? [Any] ?? []).isEmpty, "A duplicate pane cannot recover the first pane's live provisional stroke")
        let provisional = try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf")
        XCTAssertEqual(provisional.first?.provisional, true, "Opening another Host must not finalize a measured checkpoint")
        let secondFlushed = try await second.handle("pdfNative:flush", request: secondIdentity) as? [String: Any]
        XCTAssertTrue((secondFlushed?["pending"] as? [Any] ?? []).isEmpty)
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").first?.provisional, true)
        second.closeAll()
        try surface.onStroke?(pendingStroke)
        _ = try await first.handle("pdfNative:flush", request: identity) // Completion delivery follows durable worker storage.
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
