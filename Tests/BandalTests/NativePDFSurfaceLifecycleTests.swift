import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import Bandal

private final class SurfaceResumeAcquisitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var sizes: [CGSize] = []
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func arm() { lock.lock(); sizes = []; recording = true; lock.unlock() }
    var requestedSizes: [CGSize] { lock.lock(); defer { lock.unlock() }; return sizes }
    func acquire(_ layer: CAMetalLayer) -> CAMetalDrawable? {
        lock.lock()
        let first = recording && sizes.isEmpty
        if recording { sizes.append(layer.drawableSize) }
        lock.unlock()
        if first {
            entered.signal()
            _ = resume.wait(timeout: .now() + 3)
        }
        return layer.nextDrawable()
    }
    func waitForFirstAcquisition() -> Bool { entered.wait(timeout: .now() + 1) == .success }
    func releaseFirstAcquisition() { resume.signal() }
}

@MainActor
final class NativePDFSurfaceLifecycleTests: XCTestCase {
    /// Keep the main run loop out of this short fixture barrier so UIUpdateLink
    /// cannot consume the first ready drawable, or execute a stale-generation
    /// retry, before we inspect it. This is not an input latency measurement.
    private func waitForWorkerWithoutAdvancingUIKit(_ renderer: NativePDFMetalInk) -> Bool {
        let deadline = CACurrentMediaTime() + 2
        while renderer.pendingDrawableRequestCount != 0, CACurrentMediaTime() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return renderer.pendingDrawableRequestCount == 0
    }

    private func poll(timeout: Double = 3, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        repeat {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(2))
        } while CACurrentMediaTime() < deadline
        return predicate()
    }

    func testOffscreenResumeStagesCurrentViewportBeforeFirstDrawableRequest() async throws {
        let active = try await poll(timeout: 1) {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        XCTAssertTrue(active)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()

        let probe = SurfaceResumeAcquisitionProbe()
        let metal = try XCTUnwrap(NativePDFMetalInk(drawableAcquirer: { probe.acquire($0) }))
        let pageBounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let data = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { renderer in
            renderer.beginPage()
            renderer.cgContext.setFillColor(UIColor.blue.cgColor)
            renderer.cgContext.fill(CGRect(x: 30, y: 40, width: 60, height: 70))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: pageBounds, renderer: metal))
        defer {
            probe.releaseFirstAcquisition()
            surface.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        surface.pdfPage = try XCTUnwrap(document.page(at: 0))
        surface.mapper = .whiteboard(size: pageBounds.size); surface.isLoading = false
        var visible = CGRect(x: 10, y: 20, width: 110, height: 100)
        surface.viewportProvider = { visible }
        controller.view.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        let imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let settled = try await poll {
            imageView.image != nil && !imageView.isHidden && metal.submittedFrameGeometry != nil &&
                surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertTrue(settled, "The initial real Surface image and clear must finish before testing re-entry")
        let oldGeometry = try XCTUnwrap(metal.submittedFrameGeometry)

        visible = .zero; surface.refreshViewport()
        XCTAssertTrue(metal.isHidden); XCTAssertNil(metal.pendingFrameGeometry)
        XCTAssertEqual(metal.readyDrawableCount, 0)
        XCTAssertEqual(surface.inputDiagnostics["frameRequested"] as? Bool, false)
        let drained = try await poll { metal.pendingDrawableRequestCount == 0 }
        XCTAssertTrue(drained, "No acquisition from the previous visible period may contaminate the probe")

        probe.arm()
        visible = CGRect(x: 30, y: 40, width: 210, height: 160)
        surface.refreshViewport()
        let target = try XCTUnwrap(metal.pendingFrameGeometry)
        XCTAssertNotEqual(target.pixelSize, oldGeometry.pixelSize)
        let expectedCrop = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: surface.bounds,
            visibleRect: visible, canvasToWindow: .identity, screenScale: window.screen.scale, stabilized: true))
        XCTAssertEqual(target.canvasRect, expectedCrop.canvasRect)
        XCTAssertFalse(metal.isHidden)
        XCTAssertTrue(probe.waitForFirstAcquisition(), "Re-entry must request a drawable for the staged viewport")
        XCTAssertEqual(probe.requestedSizes, [target.pixelSize],
            "The first worker request must use the new viewport, never the suspended raw MTKView size")
        probe.releaseFirstAcquisition()
        XCTAssertTrue(waitForWorkerWithoutAdvancingUIKit(metal))
        XCTAssertEqual(metal.readyDrawableCount, 1,
            "The first request must belong to the current generation. Unhide-before-stage discards it and needs another UIKit turn")
        XCTAssertEqual(probe.requestedSizes.count, 1,
            "A stale-generation retry must not be needed to make re-entry ready")

        let submittedBefore = metal.submittedFrameCount
        let resumed = try await poll {
            metal.submittedFrameCount > submittedBefore && metal.submittedFrameGeometry == target &&
                imageView.image != nil && !imageView.isHidden && metal.strokes.isEmpty &&
                surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertTrue(resumed, "The real scheduler must install the new crop and synchronized clear after the probe releases UIKit")
        XCTAssertEqual(metal.bounds.size, target.canvasRect.size)
        XCTAssertEqual(metal.contentScaleFactor, target.pixelScale)
    }
}
