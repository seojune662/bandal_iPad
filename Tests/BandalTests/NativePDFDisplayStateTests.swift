import XCTest
import PDFKit
import WebKit
@testable import Bandal

/// A committed scene may change with no live-ink timing callback. Its actual
/// image/clear handoff and the Host's published diagnostics must still agree.
@MainActor
final class NativePDFDisplayStateTests: XCTestCase {
    func testCanonicalSnapshotSceneInstallPublishesActualAppendWithoutLiveInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-display-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(oldEnabled, forKey: "bandal.nativePDF.enabled") }
        let url = root.appendingPathComponent("display.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { renderer in
            renderer.beginPage()
            renderer.cgContext.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
            renderer.cgContext.fill(CGRect(x: 55, y: 120, width: 150, height: 120))
        }.write(to: url)
        let foreground = await poll(timeout: 2) {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        XCTAssertTrue(foreground)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" {
                return ["materialID": "display-state", "documentRevision": request["documentRevision"]!]
            }
            XCTAssertEqual(channel, "nativeMaterial:path")
            return url.path
        }
        host.attach(to: controller.view, shell: shell); defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "display-state", "generation": "one",
            "courseId": "course", "relPath": "display.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging([
            "visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        let state: [String: Any] = ["loading": false, "active": true, "drawings": [], "annotations": [],
            "tool": ["name": "pen", "style": ["color": "blue", "width": 0.008, "opacity": 0.65]]]
        _ = try await host.handle("pdfNative:snapshot", request: identity.merging(state) { _, new in new })
        let attached = await poll(timeout: 5) {
            self.find(NativePDFInkSurface.self, in: controller.view).first?.mapper != nil
        }
        XCTAssertTrue(attached)
        let surface = try XCTUnwrap(find(NativePDFInkSurface.self, in: controller.view).first)
        let metal = try XCTUnwrap(find(NativePDFMetalInk.self, in: surface).first)
        let imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let body = try XCTUnwrap(find(PDFView.self, in: controller.view)
            .first { $0.accessibilityIdentifier == "bandal-native-pdf-body" })
        let settled = await poll(timeout: 5) {
            surface.renderViewport != nil && imageView.image != nil && !imageView.isHidden &&
            surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
            surface.inputDiagnostics["frameRequested"] as? Bool == false && metal.strokes.isEmpty
        }
        XCTAssertTrue(settled)
        let originalImage = try XCTUnwrap(imageView.image)
        let originalSubmitted = metal.submittedFrameCount
        let originalAppends = try XCTUnwrap(surface.inputDiagnostics["sceneAppendRenders"] as? Int)
        var timingCallbacks = 0, presentationCallbacks = 0
        let originalTiming = surface.onTiming, originalPresentation = surface.onPresentation
        surface.onTiming = { p95, count in timingCallbacks += 1; originalTiming?(p95, count) }
        surface.onPresentation = { value in presentationCallbacks += 1; originalPresentation?(value) }

        let drawing: [String: Any] = ["id": "canonical-display-stroke", "clientMutationId": "display-mutation",
            "page": 1, "kind": "ink", "data": ["inkVersion": 4, "points": [
                ["x": 0.20, "y": 0.30, "p": 0.4], ["x": 0.36, "y": 0.34, "p": 0.8]]],
            "style": ["color": "blue", "width": 0.008, "opacity": 0.65]]
        var updated = state; updated["drawings"] = [drawing]
        _ = try await host.handle("pdfNative:snapshot", request: identity.merging(updated) { _, new in new })
        let publishedBeforeHandoff = body.accessibilityValue ?? ""
        let installed = await poll(timeout: 5) {
            imageView.image !== originalImage && !imageView.isHidden && metal.strokes.isEmpty &&
            metal.submittedFrameCount > originalSubmitted &&
            surface.inputDiagnostics["frameRequested"] as? Bool == false &&
            (surface.inputDiagnostics["sceneAppendRenders"] as? Int ?? -1) == originalAppends + 1
        }
        XCTAssertTrue(installed, "A real UIImage+clear submission must finish independently of the accessibility assertion")
        let actualAppends = try XCTUnwrap(surface.inputDiagnostics["sceneAppendRenders"] as? Int)
        let publishedAfterHandoff = body.accessibilityValue ?? ""
        print("DISPLAY_STATE before=\(publishedBeforeHandoff) after=\(publishedAfterHandoff) actualAppend=\(actualAppends) submittedBefore=\(originalSubmitted) submittedAfter=\(metal.submittedFrameCount) timing=\(timingCallbacks) presentation=\(presentationCallbacks)")
        XCTAssertEqual(actualAppends, originalAppends + 1)
        XCTAssertEqual(timingCallbacks, 0, "A clear has no live-ink timing event")
        XCTAssertEqual(presentationCallbacks, 0, "Do not fake a Pencil presentation to refresh diagnostics")
        XCTAssertEqual(metric("drawings", in: publishedAfterHandoff), 1)
        XCTAssertEqual(metric("sceneAppend", in: publishedAfterHandoff), actualAppends,
            "Host diagnostics must publish the completed scene append without another touch, layout, snapshot or timing callback")

        // Independently distinguish stale diagnostics from missing committed
        // scene pixels. This is encoder/image evidence, not a display timestamp.
        let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
        let page = try XCTUnwrap(surface.pdfPage)
        let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            NativePDFObjectRenderer.draw(drawing, in: context, mapper: mapper, image: nil)
        }?.cgImage)
        let actual = try XCTUnwrap(imageView.image?.cgImage)
        XCTAssertEqual(actual.width, reference.width); XCTAssertEqual(actual.height, reference.height)
        XCTAssertEqual(try pixels(actual), try pixels(reference), "The committed scene must actually contain the canonical stroke")
    }

    private func metric(_ key: String, in value: String) -> Int? {
        value.split(separator: " ").first { $0.hasPrefix(key + "=") }
            .flatMap { Int($0.dropFirst(key.count + 1)) }
    }
    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func poll(timeout: TimeInterval, _ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate(), CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }
}
