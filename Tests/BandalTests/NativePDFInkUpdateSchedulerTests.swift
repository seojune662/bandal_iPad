import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFInkUpdateSchedulerTests: XCTestCase {
    func testPendingWorkWakesVisibleViewAndStopsAfterSuccessfulFrame() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let scheduler = NativePDFInkUpdateScheduler(view: controller.view)
        defer { scheduler.stop() }
        var frames = 0
        scheduler.render = { [weak scheduler] in frames += 1; scheduler?.setNeedsFrame(false) }
        scheduler.setNeedsFrame(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(frames, 1, "One successful frame returns to passive observation")
        scheduler.setNeedsFrame(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames, 2, "A later correction wakes the link without a new touch")
        scheduler.stop(); scheduler.setNeedsFrame(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames, 2, "A detached surface cannot keep producing frames")
    }

    func testUpdateActionsDoNotRetainSchedulerOrSurface() {
        weak var released: NativePDFInkUpdateScheduler?
        autoreleasepool {
            let view = UIView()
            let scheduler = NativePDFInkUpdateScheduler(view: view)
            released = scheduler
            scheduler.setNeedsFrame(true)
            scheduler.stop()
        }
        XCTAssertNil(released)
    }
    func testClippedPageKeepsDirtyStateWithoutRunningContinuousUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let surface = try XCTUnwrap(NativePDFInkSurface())
        surface.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        surface.mapper = .whiteboard(size: surface.bounds.size)
        surface.viewportProvider = { .zero }
        controller.view.addSubview(surface); surface.refreshViewport()
        surface.invalidateBackdrop()
        XCTAssertNil(surface.renderViewport)
        XCTAssertEqual(surface.inputDiagnostics["frameRequested"] as? Bool, false)
        surface.viewportProvider = { [weak surface] in surface?.bounds }
        surface.refreshViewport()
        XCTAssertNotNil(surface.renderViewport)
        XCTAssertEqual(surface.inputDiagnostics["frameRequested"] as? Bool, true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(surface.inputDiagnostics["frameRequested"] as? Bool, false)
        surface.viewportProvider = { .zero }; surface.refreshViewport()
        XCTAssertEqual(surface.inputDiagnostics["frameRequested"] as? Bool, false)
        surface.removeFromSuperview()
    }
}
