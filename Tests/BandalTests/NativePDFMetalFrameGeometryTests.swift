import XCTest
import UIKit
import MetalKit
@testable import Bandal

private final class FrameGeometryAcquisitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var waiting = false
    private let release = DispatchSemaphore(value: 0)
    func arm() { lock.lock(); armed = true; lock.unlock() }
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func acquire(_ layer: CAMetalLayer) -> CAMetalDrawable? {
        lock.lock(); let block = armed; armed = false; waiting = block; lock.unlock()
        if block { _ = release.wait(timeout: .now() + 3) }
        lock.lock(); waiting = false; lock.unlock()
        return layer.nextDrawable()
    }
    func resume() { release.signal() }
}

@MainActor
final class NativePDFMetalFrameGeometryTests: XCTestCase {
    @MainActor private struct WindowFixture {
        let window: UIWindow
        let view: UIView
        let previous: UIWindow?
        func close(_ renderer: NativePDFMetalInk) {
            renderer.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
    private func attach(_ renderer: NativePDFMetalInk) async throws -> WindowFixture {
        let deadline = CACurrentMediaTime() + 1
        var scene: UIWindowScene?
        repeat {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if scene != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while CACurrentMediaTime() < deadline
        let active = try XCTUnwrap(scene), previous = active.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: active), controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(renderer)
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        return WindowFixture(window: window, view: controller.view, previous: previous)
    }
    private func waitReady(_ renderer: NativePDFMetalInk) async throws {
        let deadline = CACurrentMediaTime() + 1
        while renderer.readyDrawableCount == 0, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(renderer.readyDrawableCount, 1)
    }
    private func geometry(_ rect: CGRect, scale: CGFloat = 1, canvasToPage: CGAffineTransform = .identity) throws -> NativePDFMetalInk.FrameGeometry {
        try XCTUnwrap(.init(canvasRect: rect, pixelScale: scale, canvasToPage: canvasToPage))
    }
    private func assertPlacement(_ renderer: NativePDFMetalInk, in view: UIView,
                                 source: NativePDFMetalInk.FrameGeometry, destination: CGAffineTransform,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for local in [CGPoint.zero, CGPoint(x: source.canvasRect.width, y: 0),
                      CGPoint(x: 0, y: source.canvasRect.height), CGPoint(x: source.canvasRect.width, y: source.canvasRect.height)] {
            let sourceCanvas = CGPoint(x: source.canvasRect.minX + local.x, y: source.canvasRect.minY + local.y)
            let expected = sourceCanvas.applying(source.canvasToPage).applying(destination.inverted())
            let actual = renderer.convert(local, to: view)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
        }
    }
    private var stroke: NativePDFMetalInk.Stroke {
        .init(polygons: [[CGPoint(x: 5, y: 7), CGPoint(x: 45, y: 7), CGPoint(x: 45, y: 39), CGPoint(x: 5, y: 39)]], color: .blue, opacity: 0.5)
    }

    func testGeometryAcceptsViewportCeilingAndRejectsNonfiniteOrUnboundedInput() throws {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 900)
        let viewport = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: rect, visibleRect: rect,
            canvasToWindow: CGAffineTransform(scaleX: 100, y: 100), screenScale: 3))
        XCTAssertGreaterThan(viewport.pixelSize.width * viewport.pixelSize.height, NativePDFRenderViewport.maximumPixels)
        let accepted = try geometry(viewport.canvasRect, scale: viewport.pixelScale)
        XCTAssertEqual(accepted.pixelSize, viewport.pixelSize, "Ceiled viewport pixels must be accepted by both raster and Metal")
        XCTAssertNil(NativePDFMetalInk.FrameGeometry(canvasRect: .zero, pixelScale: 1, canvasToPage: .identity))
        XCTAssertNil(NativePDFMetalInk.FrameGeometry(canvasRect: rect, pixelScale: .infinity, canvasToPage: .identity))
        XCTAssertNil(NativePDFMetalInk.FrameGeometry(canvasRect: rect, pixelScale: 100, canvasToPage: .identity))
        XCTAssertNil(NativePDFMetalInk.FrameGeometry(canvasRect: rect, pixelScale: 1, canvasToPage: CGAffineTransform(scaleX: 0, y: 1)))
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        XCTAssertFalse(renderer.stageFrame(accepted, presentingIn: CGAffineTransform(a: 1,b: 0,c: 0,d: 1,tx: .nan,ty: 0)))
        XCTAssertNil(renderer.pendingFrameGeometry)
    }

    func testColdStagingLeavesBoundsUntouchedUntilSuccessfulClear() async throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        let target = try geometry(CGRect(x: 20, y: 30, width: 80, height: 64), scale: 1.5)
        XCTAssertTrue(renderer.stageFrame(target))
        XCTAssertEqual(renderer.bounds, .zero); XCTAssertNil(renderer.submittedFrameGeometry)
        var changes = 0
        XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { changes += 1 }))
        XCTAssertEqual(changes, 0); XCTAssertEqual(renderer.bounds, .zero)
        let fixture = try await attach(renderer); defer { fixture.close(renderer) }
        try await waitReady(renderer)
        XCTAssertEqual(renderer.bounds, .zero, "Worker acquisition cannot relocate or stretch the front layer")
        XCTAssertTrue(renderer.submitFrame(synchronizedUpdate: {
            changes += 1
            XCTAssertTrue(renderer.presentsWithTransaction); XCTAssertTrue(CATransaction.disableActions())
            XCTAssertEqual(renderer.submittedFrameGeometry, target)
        }))
        XCTAssertEqual(changes, 1); XCTAssertEqual(renderer.frame, target.canvasRect)
        XCTAssertEqual(renderer.contentScaleFactor, target.pixelScale)
    }

    func testStagedProjectionUsesNewLogicalSizeBeforeViewGeometryChanges() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk()), reference = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 10, y: 20, width: 32, height: 24)
        let oldFrame = renderer.frame, oldScale = renderer.contentScaleFactor
        let next = try geometry(CGRect(x: 90, y: 80, width: 80, height: 64), scale: 1.5)
        XCTAssertTrue(renderer.stageFrame(next))
        renderer.strokes = [stroke]
        reference.frame = CGRect(origin: .zero, size: next.canvasRect.size); reference.strokes = [stroke]
        let actual = try XCTUnwrap(renderer.renderedPixels(width: Int(next.pixelSize.width), height: Int(next.pixelSize.height)))
        let expected = try XCTUnwrap(reference.renderedPixels(width: Int(next.pixelSize.width), height: Int(next.pixelSize.height)))
        XCTAssertTrue(actual == expected, "GPU projection must use the staged logical size rather than the retained UIView bounds")
        XCTAssertEqual(renderer.frame, oldFrame); XCTAssertEqual(renderer.contentScaleFactor, oldScale)
        XCTAssertNil(renderer.submittedFrameGeometry)
    }

    func testDeferredResizeRotationAndFailedClearKeepRetainedPagePlacement() async throws {
        let gate = FrameGeometryAcquisitionGate()
        let renderer = try XCTUnwrap(NativePDFMetalInk(drawableAcquirer: { gate.acquire($0) }))
        renderer.frame = CGRect(x: 20, y: 30, width: 64, height: 64)
        let old = try geometry(renderer.frame, canvasToPage: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: 600))
        XCTAssertTrue(renderer.stageFrame(old)); renderer.strokes = [stroke]
        let fixture = try await attach(renderer); defer { gate.resume(); fixture.close(renderer) }
        try await waitReady(renderer)
        gate.arm()
        XCTAssertTrue(renderer.submitFrame())
        XCTAssertEqual(renderer.submittedFrameGeometry, old)
        let deadline = CACurrentMediaTime() + 1
        while !gate.isWaiting, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.isWaiting)
        let rotation = CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: 300,ty: 20)
        let obsolete = try geometry(CGRect(x: 90,y: 30,width: 96,height: 80), scale: 1.5)
        let newest = try geometry(CGRect(x: 110,y: 70,width: 120,height: 90), scale: 2, canvasToPage: rotation)
        XCTAssertTrue(renderer.stageFrame(obsolete, presentingIn: rotation))
        XCTAssertTrue(renderer.stageFrame(newest, presentingIn: rotation))
        XCTAssertEqual(renderer.bounds.size, old.canvasRect.size)
        XCTAssertEqual(renderer.contentScaleFactor, old.pixelScale)
        assertPlacement(renderer, in: fixture.view, source: old, destination: rotation)
        renderer.strokes = []
        let before = renderer.submittedFrameCount
        var changes = 0
        for _ in 0..<100 { XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { changes += 1 })) }
        XCTAssertEqual(renderer.pendingFrameGeometry, newest); XCTAssertEqual(renderer.submittedFrameGeometry, old)
        XCTAssertEqual(renderer.pendingDrawableRequestCount, 1); XCTAssertEqual(changes, 0)
        XCTAssertEqual(renderer.submittedFrameCount, before)
        assertPlacement(renderer, in: fixture.view, source: old, destination: rotation)
        gate.resume()
        try await waitReady(renderer)
        #if DEBUG
        renderer.testingFailNextEncoding = true
        XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { changes += 1 }))
        XCTAssertEqual(renderer.submittedFrameGeometry, old); XCTAssertEqual(changes, 0)
        XCTAssertEqual(renderer.bounds.size, old.canvasRect.size)
        assertPlacement(renderer, in: fixture.view, source: old, destination: rotation)
        try await waitReady(renderer)
        #endif
        XCTAssertTrue(renderer.submitFrame(synchronizedUpdate: {
            changes += 1
            XCTAssertTrue(renderer.presentsWithTransaction); XCTAssertTrue(CATransaction.disableActions())
            XCTAssertEqual(renderer.submittedFrameGeometry, newest)
            XCTAssertEqual(renderer.bounds.size, newest.canvasRect.size)
            XCTAssertEqual(renderer.contentScaleFactor, newest.pixelScale)
        }))
        XCTAssertEqual(changes, 1); XCTAssertEqual(renderer.submittedFrameCount, before + 1)
        assertPlacement(renderer, in: fixture.view, source: newest, destination: rotation)
        XCTAssertTrue(try XCTUnwrap(renderer.renderedPixels(width: 120, height: 90)).allSatisfy { $0 == 0 })
    }

    func testRetainedSourceBasisPersistsAcrossSubmissionAndSuspendResume() async throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        let source = try geometry(CGRect(x: 30,y: 40,width: 80,height: 64), scale: 1.5,
                                  canvasToPage: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: 600))
        let destination = CGAffineTransform(a: 0,b: 2,c: 2,d: 0,tx: 15,ty: -40)
        renderer.frame = source.canvasRect
        XCTAssertTrue(renderer.stageFrame(source, presentingIn: destination)); renderer.strokes = [stroke]
        let fixture = try await attach(renderer); defer { fixture.close(renderer) }
        try await waitReady(renderer); XCTAssertTrue(renderer.submitFrame())
        assertPlacement(renderer, in: fixture.view, source: source, destination: destination)
        let newerDestination = CGAffineTransform(a: 1.3,b: 0.2,c: 0.1,d: -1.1,tx: -40,ty: 650)
        XCTAssertTrue(renderer.reprojectRetainedFrame(to: newerDestination))
        try await waitReady(renderer); XCTAssertTrue(renderer.submitFrame())
        assertPlacement(renderer, in: fixture.view, source: source, destination: newerDestination)
        XCTAssertEqual(renderer.submittedFrameGeometry, source)
        renderer.suspendFrame()
        XCTAssertTrue(renderer.isHidden); XCTAssertEqual(renderer.readyDrawableCount, 0)
        XCTAssertFalse(renderer.submitFrame()); XCTAssertNil(renderer.pendingFrameGeometry)
        XCTAssertTrue(renderer.stageFrame(source, presentingIn: newerDestination))
        try await waitReady(renderer); XCTAssertTrue(renderer.submitFrame())
        XCTAssertFalse(renderer.isHidden)
        assertPlacement(renderer, in: fixture.view, source: source, destination: newerDestination)
        renderer.removeFromSuperview()
        XCTAssertEqual(renderer.readyDrawableCount, 0); XCTAssertFalse(renderer.submitFrame())
    }

    func testUncoveredRetainedCropCannotConsumeOrReportCurrentInputClock() async throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        let target = try geometry(CGRect(x: 20,y: 30,width: 64,height: 64))
        XCTAssertTrue(renderer.stageFrame(target))
        let fixture = try await attach(renderer); defer { fixture.close(renderer) }
        let original = CACurrentMediaTime() - 0.25
        renderer.noteInputReceived(at: original, strokeID: 44)
        renderer.strokes = [.init(polygons: [[CGPoint(x: 500,y: 500), CGPoint(x: 520,y: 500), CGPoint(x: 510,y: 520)]], color: .blue, opacity: 1)]
        var inputCallbacks = 0
        renderer.onFrameSubmitted = { _ in inputCallbacks += 1 }
        try await waitReady(renderer)
        XCTAssertTrue(renderer.submitFrame(reportsInput: false))
        XCTAssertEqual(renderer.submittedFrameCount, 1, "The retained scene itself was still submitted")
        XCTAssertEqual(inputCallbacks, 0); XCTAssertNil(renderer.lastSubmittedFrame)
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, original)
        XCTAssertTrue(try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64)).allSatisfy { $0 == 0 },
            "A nonempty mesh clipped outside this crop is not visible input")
        renderer.noteInputReceived(at: CACurrentMediaTime(), strokeID: 44)
        renderer.strokes = [stroke]
        try await waitReady(renderer); XCTAssertTrue(renderer.submitFrame(reportsInput: true))
        XCTAssertEqual(inputCallbacks, 1); XCTAssertNil(renderer.pendingInputTiming)
        XCTAssertEqual(renderer.lastSubmittedFrame?.firstInputAt, original)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(renderer.lastSubmittedFrame?.receiveToSubmitMS), 250)
        renderer.onFrameSubmitted = nil
    }
}
