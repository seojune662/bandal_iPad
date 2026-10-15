import XCTest
import UIKit
import PDFKit
import WebKit
import JavaScriptCore
@testable import Bandal

@MainActor
final class NativePDFCanonicalHandoffTests: XCTestCase {
    func testEstimatedPressureFinalizationAndJavaScriptCanonicalAckReuseScene() async throws {
        try await exerciseCanonicalHandoff(pressure: 2.0 / 12345, useBackend: false)
    }
    func testDesktopBackendRoundTripsVariedRawPressuresWithoutFullSceneReplay() async throws {
        for numerator in [1.0, 2.0, 17.0] {
            try await exerciseCanonicalHandoff(pressure: numerator / 12345, useBackend: true)
        }
    }
    private func exerciseCanonicalHandoff(pressure expectedPressure: Double, useBackend: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-ack-roundtrip-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData {
            $0.beginPage()
        }.write(to: source)
        let runtime: DesktopRuntime?, courseID: String
        if useBackend {
            let backend = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            try await backend.start(); runtime = backend
            let value = try await backend.invoke("courses:create", request: ["name": "Canonical ink regression", "color": "blue"])
            courseID = try XCTUnwrap((value as? [String: Any])?["id"] as? String)
            _ = try await backend.invoke("materials:writeFile", request: ["courseId": courseID, "dirRelPath": "",
                "fileName": "paper.pdf", "encoding": "base64", "data": try Data(contentsOf: source).base64EncodedString()])
        } else { runtime = nil; courseID = "course" }
        let oldEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(oldEnabled, forKey: "bandal.nativePDF.enabled") }
        let activeDeadline = CACurrentMediaTime() + 1
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), CACurrentMediaTime() < activeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        if useBackend {
            shell.loadHTMLString("<html><body>Native ink bridge fixture</body></html>", baseURL: nil)
            let webDeadline = CACurrentMediaTime() + 5
            while shell.isLoading, CACurrentMediaTime() < webDeadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        let host = try NativePDFHost(root: root) { channel, request in
            if let runtime { return try await runtime.invokePrivate(channel, request: request) }
            if channel == "nativePDF:binding" { return ["materialID": "fixture", "documentRevision": request["documentRevision"]!] }
            return source.path
        }
        host.attach(to: controller.view, shell: shell); defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "roundtrip", "generation": "one", "courseId": courseID, "relPath": "paper.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": true,
            "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        var canonical: [[String: Any]] = []
        for index in 0..<71 {
            let points = (0..<96).map { sample -> NativePDFPoint in
                let t = Double(sample) / 95
                return .init(x: 0.1 + t * 0.8, y: 0.1 + Double(index % 16) * 0.045 + sin(t * .pi * 4) * 0.025, p: 0.25 + 0.45 * t)
            }
            let input = NativePDFStrokeInput(courseId: courseID, relPath: "paper.pdf", page: 1, kind: "ink",
                data: .init(points: points), style: .init(color: "blue", width: 0.004, opacity: 0.45), clientMutationId: "base-\(index)")
            var object = try NativePDFHost.json(input); object["id"] = "drawing-\(index)"; canonical.append(object)
        }
        func publish() async throws {
            _ = try await host.handle("pdfNative:snapshot", request: identity.merging(["loading": false, "active": true,
                "drawings": canonical, "annotations": [], "tool": ["name": "pen",
                "style": ["color": "blue", "width": 0.004, "opacity": 0.45]]]) { _, new in new })
        }
        try await publish()
        func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        let readyDeadline = CACurrentMediaTime() + 10
        while find(NativePDFInkSurface.self, in: controller.view).first?.mapper == nil, CACurrentMediaTime() < readyDeadline {
            controller.view.layoutIfNeeded(); host.layout(); try await Task.sleep(for: .milliseconds(20))
        }
        let surface = try XCTUnwrap(find(NativePDFInkSurface.self, in: controller.view).first)
        let imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        while (imageView.image == nil || surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true), CACurrentMediaTime() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(imageView.image)
        let initialFull = try XCTUnwrap(surface.inputDiagnostics["sceneFullRenders"] as? Int)
        let baselineImage = try XCTUnwrap(imageView.image)
        let baselineObjects = surface.objects
        var emitted: [[String: Any]] = []
        host.emit = { channel, body in
            guard channel == "pdfNative:event", let event = body as? [String: Any], event["type"] as? String == "stroke",
                  let payload = event["payload"] as? [String: Any] else { return }
            emitted.append(payload)
        }
        let touch = CanonicalHandoffTouch(point: surface.convert(CGPoint(x: surface.bounds.width * 0.4,
            y: surface.bounds.height * 0.45), to: window))
        let event = CanonicalHandoffEvent(touch), gesture = NativePDFPencilGestureRecognizer()
        controller.view.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        touch.estimateIndex = 501; touch.expecting = .force
        gesture.touchesBegan([touch], with: event)
        gesture.touchesEnded([touch], with: event); gesture.reset()
        XCTAssertTrue(emitted.isEmpty, "Estimated pressure must remain checkpointed before final correction")
        try await Task.sleep(for: .milliseconds(40))
        touch.pressure = CGFloat(expectedPressure); touch.expecting = []
        let provisionalImage = imageView.image
        gesture.touchesEstimatedPropertiesUpdated([touch])
        _ = try await host.handle("pdfNative:flush", request: identity) // Durable transport is asynchronous; the measured correction is already final.
        XCTAssertEqual(emitted.count, 1)
        let payload = try XCTUnwrap(emitted.first), mutation = try XCTUnwrap(payload["clientMutationId"] as? String)
        let finalizedDeadline = CACurrentMediaTime() + 3
        while (surface.inputDiagnostics["sceneRenderMode"] as? String != "tail" || imageView.image === provisionalImage || !metal.strokes.isEmpty), CACurrentMediaTime() < finalizedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, initialFull)
        XCTAssertEqual(surface.inputDiagnostics["sceneLastDrawnObjects"] as? Int, 1)
        XCTAssertFalse(imageView.image === provisionalImage)
        XCTAssertTrue(metal.strokes.isEmpty)
        let finalizedImage = try XCTUnwrap(imageView.image)
        let finalizedObjects = surface.objects
        let finalizedPixels = try pixels(finalizedImage)
        let pending = try XCTUnwrap(NativePDFJournal(root: root).pending(courseID: courseID, relativePath: "paper.pdf").first)
        XCTAssertEqual(pending.input.data.points.map(\.p), [expectedPressure])
        XCTAssertNotEqual(pending.provisional, true)
        let row: [String: Any], canonicalID: String
        if let runtime {
            // Cross real WebKit value bridges around the bundled repository,
            // SQLite transaction and runtime JSON completion callback.
            func webRoundtrip(_ value: Any) async throws -> [String: Any] {
                let result: Any? = try await withCheckedThrowingContinuation { continuation in
                    shell.callAsyncJavaScript("return JSON.parse(JSON.stringify(input));", arguments: ["input": value],
                        in: nil, in: .page) { result in continuation.resume(with: result) }
                }
                return try XCTUnwrap(result as? [String: Any])
            }
            let input = try await webRoundtrip(payload)
            let created = try await runtime.invoke("drawings:create", request: input)
            let webReply = try await webRoundtrip(created)
            var canonicalRow = webReply
            canonicalID = try XCTUnwrap(canonicalRow["id"] as? String)
            canonicalRow["clientMutationId"] = mutation
            row = canonicalRow
            let listed = try await runtime.invoke("drawings:listForFile", request: ["courseId": courseID, "relPath": "paper.pdf"])
            let persisted = try XCTUnwrap((listed as? [[String: Any]])?.first)
            let decoded = try JSONDecoder().decode(NativePDFStrokeData.self,
                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(persisted["data"] as? [String: Any])))
            XCTAssertEqual(decoded.points, pending.input.data.points,
                "The actual backend and completion JSON must preserve raw measured values exactly")
        } else {
            let js = try XCTUnwrap(JSContext()); js.setObject(payload, forKeyedSubscript: "input" as NSString)
            var value = try XCTUnwrap(js.evaluateScript("JSON.parse(JSON.stringify(input))")?.toDictionary() as? [String: Any])
            canonicalID = "canonical-final"; value["id"] = canonicalID; row = value
        }
        canonical.append(row)
        let nativePressure = try XCTUnwrap(((payload["data"] as? [String: Any])?["points"] as? [[String: Any]])?.first?["p"] as? NSNumber)
        let webPressure = try XCTUnwrap(((row["data"] as? [String: Any])?["points"] as? [[String: Any]])?.first?["p"] as? NSNumber)
        XCTAssertEqual(nativePressure.doubleValue.bitPattern, webPressure.doubleValue.bitPattern)
        if useBackend {
            XCTAssertEqual(nativePressure.doubleValue.bitPattern, expectedPressure.bitPattern,
                "The native event must preserve the journal's exact binary pressure")
            XCTAssertEqual(webPressure.doubleValue.bitPattern, expectedPressure.bitPattern,
                "Creation, SQLite and completion must preserve the same binary pressure")
        }
        print("ACK_ROUNDTRIP backend=\(useBackend) pressure=\(expectedPressure) native=\(nativePressure) JS=\(webPressure) NSNumberEqual=\(nativePressure == webPressure) DoubleEqual=\(nativePressure.doubleValue == webPressure.doubleValue)")
        let reuseBefore = try XCTUnwrap(surface.inputDiagnostics["sceneReuses"] as? Int)
        try await publish()
        _ = try await host.handle("pdfNative:ack", request: identity.merging(["clientMutationId": mutation, "drawingId": canonicalID]) { _, new in new })
        let ackDeadline = CACurrentMediaTime() + 3
        while (surface.inputDiagnostics["sceneReuses"] as? Int ?? 0) == reuseBefore &&
                (surface.inputDiagnostics["sceneFullRenders"] as? Int) == initialFull && CACurrentMediaTime() < ackDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        print("ACK_ROUNDTRIP mode=\(surface.inputDiagnostics["sceneRenderMode"]!) fullBefore=\(initialFull) fullAfter=\(surface.inputDiagnostics["sceneFullRenders"]!) drawn=\(surface.inputDiagnostics["sceneLastDrawnObjects"]!)")
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, initialFull,
            "Canonical JSON must not replay all old strokes when the rendering Double values are exactly unchanged")
        XCTAssertEqual(surface.inputDiagnostics["sceneRenderMode"] as? String, "reuse")
        XCTAssertEqual(surface.inputDiagnostics["sceneLastDrawnObjects"] as? Int, 0)
        XCTAssertTrue(imageView.image === finalizedImage, "The exact opaque scene must survive the canonical ACK")
        XCTAssertEqual(surface.objects.count, 72)
        XCTAssertTrue(try NativePDFJournal(root: root).pending(courseID: courseID, relativePath: "paper.pdf").isEmpty)
        // Both rows must supply the same exact measured numbers to rendering.
        // The backend path above also compares persisted Codable raw values
        // with the original journal rather than tolerating transport rounding.
        func renderedPoints(_ object: [String: Any]) throws -> [[String: Double]] {
            let raw = try XCTUnwrap((object["data"] as? [String: Any])?["points"] as? [[String: Any]])
            return raw.map { sample in sample.compactMapValues { ($0 as? NSNumber)?.doubleValue } }
        }
        XCTAssertEqual(try renderedPoints(XCTUnwrap(finalizedObjects.last)),
            try renderedPoints(XCTUnwrap(surface.objects.last)))
        XCTAssertTrue(try pixels(XCTUnwrap(imageView.image)) == finalizedPixels,
            "The ACK must preserve every pixel of the final displayed native scene")
        let mapper = try XCTUnwrap(surface.mapper), viewport = try XCTUnwrap(surface.renderViewport)
        let page = try XCTUnwrap(surface.pdfPage)
        func fullReplay(_ objects: [[String: Any]]) throws -> UIImage {
            try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
                for object in objects { NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: nil) }
            })
        }
        let nativeReplay = try fullReplay(finalizedObjects), canonicalReplay = try fullReplay(surface.objects)
        XCTAssertTrue(try pixels(nativeReplay) == pixels(canonicalReplay),
            "Independent full replays of the native and canonical rows must be byte-identical")
        // Compare with a direct PDF + objects replay, without resizing an
        // intermediate paper image into fractional logical viewport bounds.
        // Initial navigation pixels and the ACK handoff must both stay exact.
        let referencePixels = try pixels(canonicalReplay), baselinePixels = try pixels(baselineImage)
        let baselineReferencePixels = try pixels(fullReplay(baselineObjects))
        XCTAssertEqual(baselinePixels.count, baselineReferencePixels.count)
        XCTAssertTrue(baselinePixels == baselineReferencePixels,
            "The initial asynchronous crop must match an independent full replay")
        XCTAssertTrue(finalizedPixels == referencePixels,
            "Incremental native ink must match an independent full replay")
        let delta = zip(finalizedPixels, referencePixels).map { Int($0.0) - Int($0.1) }
        let baselineDelta = zip(baselinePixels, baselineReferencePixels).map { Int($0.0) - Int($0.1) }
        print("ACK_BASELINE rasterChannelDifferences=\(baselineDelta.filter { $0 != 0 }.count) maxDelta=\(baselineDelta.map(abs).max() ?? 0) ACKAddedDifferenceChannels=\(zip(delta, baselineDelta).filter { $0 != $1 }.count)")
        let attachment = XCTAttachment(image: finalizedImage)
        attachment.name = "Canonical ACK retains the exact 72-stroke scene"; attachment.lifetime = .keepAlways; add(attachment)
        let second = CanonicalHandoffTouch(point: touch.point.applying(CGAffineTransform(translationX: 40, y: 20)))
        let secondEvent = CanonicalHandoffEvent(second)
        let previousSubmit = metal.onFrameSubmitted
        var secondFirstSubmit: NativePDFMetalInk.FrameTiming?
        metal.onFrameSubmitted = { timing in
            previousSubmit?(timing)
            if timing.strokeID == 2, secondFirstSubmit == nil { secondFirstSubmit = timing }
        }
        defer { metal.onFrameSubmitted = previousSubmit }
        gesture.touchesBegan([second], with: secondEvent)
        let secondDeadline = CACurrentMediaTime() + 1
        while secondFirstSubmit == nil, CACurrentMediaTime() < secondDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(secondFirstSubmit, "The next contact must submit live ink while Pencil remains down")
        XCTAssertLessThan(try XCTUnwrap(secondFirstSubmit).receiveToSubmitMS, 200)
        XCTAssertEqual(emitted.count, 1, "A live submission must precede the second contact's completion")
        gesture.touchesEnded([second], with: secondEvent)
        _ = try await host.handle("pdfNative:flush", request: identity)
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(surface.objects.count, 73)
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: courseID, relativePath: "paper.pdf").count, 1)
    }
    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }
}

@MainActor private final class CanonicalHandoffTouch: UITouch {
    var point: CGPoint; var pressure: CGFloat = 0.4
    var estimateIndex: NSNumber?; var expecting: UITouch.Properties = []
    init(point: CGPoint) { self.point = point; super.init() }
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { 10 }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { estimateIndex }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: nil) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
@MainActor private final class CanonicalHandoffEvent: UIEvent {
    let touch: UITouch
    init(_ touch: UITouch) { self.touch = touch; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [touch] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [touch] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
