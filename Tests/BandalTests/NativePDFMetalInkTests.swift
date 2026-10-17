import XCTest
import UIKit
import MetalKit
@testable import Bandal

private final class DrawableAcquisitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func record() { lock.lock(); calls += 1; lock.unlock() }
}

private final class DrawableAcquisitionTimeline: @unchecked Sendable {
    private struct Event { let start: CFTimeInterval; let requestedSize: CGSize; var end: CFTimeInterval?; var receivedSize: CGSize? }
    private let lock = NSLock()
    private var events: [Event] = []
    func begin(size: CGSize) -> Int {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(start: CACurrentMediaTime(), requestedSize: size)); return events.count - 1
    }
    func end(_ index: Int, size: CGSize?) {
        lock.lock(); defer { lock.unlock() }
        events[index].end = CACurrentMediaTime(); events[index].receivedSize = size
    }
    func summary(since start: CFTimeInterval) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return events.enumerated().map { index, event in
            String(format: "%d@%.1f:%@%.1f", index, (event.start - start) * 1000,
                event.end == nil ? "pending/" : event.receivedSize != nil ? "ready/" : "nil/",
                ((event.end ?? now) - event.start) * 1000) +
                (event.receivedSize.map { $0 != event.requestedSize ? "sizeMismatch\(event.requestedSize)->\($0)" : "" } ?? "")
        }.joined(separator: ",")
    }
}

@MainActor
final class NativePDFMetalInkTests: XCTestCase {
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

    private func waitForDrawable(_ renderer: NativePDFMetalInk) async throws {
        let deadline = CACurrentMediaTime() + 1
        while renderer.readyDrawableCount == 0, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(renderer.readyDrawableCount, 1, "The worker must make a drawable available without blocking UIKit")
    }

    func testBlockedAcquisitionIsBoundedAndInvalidationDiscardsItsCompletion() async throws {
        let probe = DrawableAcquisitionProbe(), release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "The superseded worker finishes")
        let mailbox = NativePDFInkDrawableMailbox { _ in
            XCTAssertFalse(Thread.isMainThread)
            probe.record()
            _ = release.wait(timeout: .now() + 2)
            return nil
        }
        let layer = CAMetalLayer()
        mailbox.request(layer: layer, width: 64, height: 64) { result in
            guard case .stale = result else { XCTFail("Invalidation must reject a late result"); completed.fulfill(); return }
            completed.fulfill()
        }
        for _ in 0..<100 {
            XCTAssertNil(mailbox.take(width: 64, height: 64))
            mailbox.request(layer: layer, width: 64, height: 64) { _ in XCTFail("Only one acquisition may be queued") }
        }
        XCTAssertEqual(mailbox.requestCount, 1); XCTAssertEqual(mailbox.readyCount, 0)
        mailbox.invalidate()
        XCTAssertNil(mailbox.take(width: 96, height: 96))
        release.signal()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(probe.count, 1); XCTAssertEqual(mailbox.requestCount, 0); XCTAssertEqual(mailbox.readyCount, 0)
    }

    func testImmediateNilAcquisitionDoesNotRetryContinuouslyWhileIdle() async throws {
        let probe = DrawableAcquisitionProbe()
        let renderer = try XCTUnwrap(NativePDFMetalInk(drawableAcquirer: { _ in
            XCTAssertFalse(Thread.isMainThread); probe.record(); return nil
        }))
        let windowScene = try await activeWindowScene()
        let previous = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), controller = UIViewController()
        window.rootViewController = controller; renderer.frame = CGRect(x: 20, y: 20, width: 64, height: 64)
        controller.view.addSubview(renderer); window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let settledCount = probe.count
        XCTAssertGreaterThan(settledCount, 0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(probe.count, settledCount, "An unavailable layer waits for another requested frame")
        XCTAssertEqual(renderer.readyDrawableCount, 0)
    }

    func testColdLatestFrameResizeHideAndDetachPreserveHandoff() async throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 20, y: 20, width: 64, height: 64)
        renderer.noteInputReceived(at: 100, strokeID: 7)
        var oldChanges = 0, latestChanges = 0
        for _ in 0..<100 { XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { oldChanges += 1 })) }
        XCTAssertEqual(oldChanges, 0); XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 100)
        XCTAssertEqual(renderer.pendingDrawableRequestCount, 0)
        let windowScene = try await activeWindowScene()
        let previous = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(renderer)
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitForDrawable(renderer)
        renderer.autoResizeDrawable = false
        renderer.drawableSize = CGSize(width: 96, height: 80)
        renderer.mtkView(renderer, drawableSizeWillChange: renderer.drawableSize)
        XCTAssertEqual(renderer.readyDrawableCount, 0)
        XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { oldChanges += 1 }))
        XCTAssertEqual((renderer.layer as? CAMetalLayer)?.drawableSize, renderer.drawableSize,
            "Direct rendering must propagate MetalKit's manual pixel size before background acquisition")
        renderer.strokes = [.init(polygons: [[CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 25, y: 40)]], color: .blue, opacity: 0.5)]
        renderer.noteInputReceived(at: 101, strokeID: 7)
        try await waitForDrawable(renderer)
        XCTAssertTrue(renderer.submitFrame(synchronizedUpdate: { latestChanges += 1 }))
        XCTAssertEqual(renderer.rebuiltVertexCount, 3, "The worker must not capture old geometry")
        XCTAssertEqual(oldChanges, 0); XCTAssertEqual(latestChanges, 1)
        XCTAssertEqual(renderer.lastSubmittedFrame?.firstInputAt, 100)
        XCTAssertEqual(renderer.lastSubmittedFrame?.latestInputAt, 101)
        try await waitForDrawable(renderer)
        renderer.isHidden = true
        XCTAssertEqual(renderer.readyDrawableCount, 0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(renderer.readyDrawableCount, 0)
        XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { oldChanges += 1 }))
        renderer.isHidden = false
        try await waitForDrawable(renderer)
        renderer.removeFromSuperview()
        XCTAssertEqual(renderer.readyDrawableCount, 0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(renderer.readyDrawableCount, 0); XCTAssertEqual(oldChanges, 0)
    }

    func testDrawableBudgetRejectsFullPoolAndIgnoresDuplicateRetirement() throws {
        let budget = NativePDFInkDrawableBudget()
        let first = try XCTUnwrap(budget.acquire()), second = try XCTUnwrap(budget.acquire())
        XCTAssertEqual(budget.count, 2); XCTAssertNil(budget.acquire())
        budget.release(first)
        let replacement = try XCTUnwrap(budget.acquire())
        XCTAssertNotEqual(first, replacement)
        budget.release(first)
        XCTAssertEqual(budget.count, 2, "A late error or skipped callback cannot retire another drawable")
        budget.release(second); budget.release(replacement)
        XCTAssertEqual(budget.count, 0)
    }

    func testRapidInkAndSynchronizedClearNeverWaitForDrawableTimeout() async throws {
        let testStartedAt = CACurrentMediaTime(), acquisition = DrawableAcquisitionTimeline()
        let windowScene = try await activeWindowScene()
        let previous = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), controller = UIViewController()
        window.rootViewController = controller
        let renderer = try XCTUnwrap(NativePDFMetalInk(drawableAcquirer: { layer in
            let index = acquisition.begin(size: layer.drawableSize)
            let drawable = layer.nextDrawable()
            acquisition.end(index, size: drawable.map { CGSize(width: $0.texture.width, height: $0.texture.height) })
            return drawable
        }))
        renderer.frame = CGRect(x: 20, y: 20, width: 64, height: 64)
        controller.view.addSubview(renderer); window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let initialReady = renderer.readyDrawableCount, initialPending = renderer.pendingDrawableRequestCount
        let initialWindowState = windowScene.windows.map { window in
            "\(type(of: window)):key\(window.isKeyWindow):hidden\(window.isHidden):level\(window.windowLevel.rawValue):\(window.frame)"
        }.joined(separator: ";")
        let stroke = NativePDFMetalInk.Stroke(polygons: [[CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10),
            CGPoint(x: 40, y: 40), CGPoint(x: 10, y: 40)]], color: .blue, opacity: 0.5)
        var maximumMS = 0.0, submitted = 0, deferred = 0, changes = 0
        var worstAcquireMS = 0.0, worstEncodeMS = 0.0, worstScheduleMS = 0.0
        for burst in 0..<50 {
            // Several short contacts can arrive within one UIKit transaction.
            // Waiting for nextDrawable here prevents that transaction retiring.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for phase in 0..<8 {
                let clear = phase.isMultiple(of: 2) == false
                renderer.strokes = clear ? [] : [stroke]
                if !clear { renderer.noteInputReceived(at: CACurrentMediaTime(), strokeID: UInt64(burst * 8 + phase + 1)) }
                let start = CACurrentMediaTime()
                let accepted = renderer.submitFrame(synchronizedUpdate: clear ? { changes += 1 } : nil)
                let elapsed = (CACurrentMediaTime() - start) * 1000
                if elapsed > maximumMS {
                    maximumMS = elapsed
                    worstAcquireMS = renderer.lastDrawableAcquisitionMS
                    worstEncodeMS = renderer.lastEncodingMS
                    worstScheduleMS = renderer.lastSchedulingMS
                }
                if accepted { submitted += 1 } else { deferred += 1 }
                if elapsed > 250 { break }
            }
            CATransaction.commit()
            if maximumMS > 250 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("Rapid Metal ink/clear: maximum CPU \(maximumMS)ms (acquire \(worstAcquireMS), encode \(worstEncodeMS), scheduling \(worstScheduleMS)); submitted \(submitted); deferred \(deferred); synchronized images \(changes)")
        print("Rapid Metal acquisition timeline ms: \(acquisition.summary(since: testStartedAt)); initialReady=\(initialReady) initialPending=\(initialPending); windows=\(initialWindowState); ready=\(renderer.readyDrawableCount) pending=\(renderer.pendingDrawableRequestCount) inflight=\(renderer.inFlightDrawableCount)")
        XCTAssertGreaterThan(submitted, 25, "The background worker must continue supplying drawables throughout all bursts")
        XCTAssertGreaterThan(deferred, 0, "A burst coalesces excess frames instead of exhausting drawable slots")
        XCTAssertLessThanOrEqual(renderer.readyDrawableCount, 1)
        XCTAssertLessThanOrEqual(renderer.pendingDrawableRequestCount, 1)
        XCTAssertLessThan(maximumMS, 250, "Backpressure must defer a frame instead of entering CAMetalLayer's one-second drawable timeout")
    }

    func testPendingInputClockKeepsOldestUnsubmittedSampleAcrossBurst() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.noteInputReceived(at: 100, strokeID: 7)
        renderer.noteInputReceived(at: 100.29, strokeID: 7)
        renderer.noteInputReceived(at: .nan, strokeID: 7)
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 100)
        XCTAssertEqual(renderer.pendingInputTiming?.latestInputAt, 100.29)
        renderer.noteInputReceived(at: 101, strokeID: 8)
        XCTAssertEqual(renderer.pendingInputTiming?.strokeID, 8)
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 101)
        XCTAssertEqual(renderer.pendingInputTiming?.latestInputAt, 101)
    }

    func testDroppedFrameRetryPreservesOldestClockAndCannotResetNewStroke() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        let dropped = NativePDFMetalInk.FrameTiming(sequence: 1, strokeID: 7,
            firstInputAt: 100, latestInputAt: 100.1, drawStartedAt: 100.1,
            drawableAcquiredAt: 100.1, submittedAt: 100.11, presentedAt: nil)
        renderer.noteInputReceived(at: 100.2, strokeID: 7)
        XCTAssertTrue(renderer.retryUnpresentedFrame(dropped, forStrokeID: 7))
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 100)
        XCTAssertEqual(renderer.pendingInputTiming?.latestInputAt, 100.2)
        XCTAssertFalse(renderer.retryUnpresentedFrame(dropped, forStrokeID: 7), "One dropped callback schedules at most one retry")
        var shown = dropped; shown.presentedAt = 100.12
        XCTAssertFalse(renderer.retryUnpresentedFrame(shown, forStrokeID: 7))
        renderer.noteInputReceived(at: 101, strokeID: 8)
        XCTAssertFalse(renderer.retryUnpresentedFrame(dropped, forStrokeID: 8))
        XCTAssertFalse(renderer.retryUnpresentedFrame(dropped, forStrokeID: 7), "Even an incorrect old caller ID cannot restore an old clock")
        XCTAssertEqual(renderer.pendingInputTiming?.strokeID, 8)
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 101)
        XCTAssertEqual(renderer.pendingInputTiming?.latestInputAt, 101)
    }

    func testExplicitOnscreenDrawReportsSubmissionAndActualPresentationSeparately() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator Metal cannot report actual drawable presentation timestamps")
        #else
        let windowScene = try await activeWindowScene()
        let previous = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController(); window.rootViewController = controller
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 20, y: 20, width: 64, height: 64)
        controller.view.addSubview(renderer); window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { renderer.onFramePresented = nil; window.isHidden = true; previous?.makeKeyAndVisible() }
        XCTAssertTrue(renderer.isPaused); XCTAssertFalse(renderer.enableSetNeedsDisplay)
        // UIWindow attachment must reach the compositor before timing starts.
        // The live first-contact retry is covered independently below.
        try await Task.sleep(for: .milliseconds(100))
        let presented = expectation(description: "An actual drawable becomes visible")
        var actualPresentation: NativePDFMetalInk.FrameTiming?
        var retries = 0
        renderer.onFramePresented = { frame in
            guard frame.strokeID == 7 else { return }
            if frame.presentedAt == nil {
                retries += 1
                guard retries <= 10 else {
                    XCTFail("No drawable was displayed after ten explicit retries"); presented.fulfill(); return
                }
                XCTAssertTrue(renderer.retryUnpresentedFrame(frame, forStrokeID: 7))
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    try? await self.waitForDrawable(renderer)
                    XCTAssertTrue(renderer.submitFrame())
                }
                return
            }
            actualPresentation = frame; presented.fulfill()
        }
        renderer.strokes = [.init(polygons: [[CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10),
                                             CGPoint(x: 40, y: 40), CGPoint(x: 10, y: 40)]], color: .black, opacity: 1)]
        let received = CACurrentMediaTime() - 0.29
        renderer.noteInputReceived(at: received, strokeID: 7)
        renderer.noteInputReceived(at: CACurrentMediaTime(), strokeID: 7)
        try await waitForDrawable(renderer)
        XCTAssertTrue(renderer.submitFrame())
        let submitted = try XCTUnwrap(renderer.lastSubmittedFrame)
        XCTAssertEqual(submitted.firstInputAt, received)
        XCTAssertGreaterThanOrEqual(submitted.receiveToSubmitMS, 290,
            "Later samples cannot hide an earlier 290ms queue stall")
        XCTAssertNil(submitted.presentedAt, "Submitting commands is not proof of screen presentation")
        XCTAssertNil(renderer.pendingInputTiming)
        await fulfillment(of: [presented], timeout: 3)
        let actual = try XCTUnwrap(actualPresentation)
        XCTAssertGreaterThanOrEqual(actual.sequence, submitted.sequence)
        XCTAssertEqual(actual.firstInputAt, received, "A dropped drawable must not reset the input age")
        XCTAssertFalse(renderer.retryUnpresentedFrame(submitted, forStrokeID: 7), "A frame at or before the visible sequence needs no retry")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(actual.presentedAt), actual.submittedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(actual.receiveToPresentMS), actual.receiveToSubmitMS)
        renderer.strokes = []
        try await waitForDrawable(renderer)
        XCTAssertTrue(renderer.submitFrame(), "Explicit drawing also clears the last live frame")
        XCTAssertEqual(renderer.lastSubmittedFrame?.sequence, actual.sequence,
            "A clear frame must not count as nonempty handwriting")
        #endif
    }

    func testSynchronizedClearUpdatesUIImageOnlyAfterSuccessfulEncoding() async throws {
        let windowScene = try await activeWindowScene()
        let previous = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), controller = UIViewController()
        window.rootViewController = controller
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 20, y: 20, width: 64, height: 64)
        let scene = UIImageView(frame: renderer.frame)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let paper = UIGraphicsImageRenderer(size: renderer.bounds.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(renderer.bounds)
        }
        let completed = UIGraphicsImageRenderer(size: renderer.bounds.size, format: format).image { context in
            paper.draw(at: .zero)
            UIColor.blue.withAlphaComponent(0.5).setFill(); context.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
        }
        scene.image = paper; controller.view.addSubview(scene); controller.view.addSubview(renderer)
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        renderer.strokes = [.init(polygons: [[CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10),
                                             CGPoint(x: 40, y: 40), CGPoint(x: 10, y: 40)]], color: .blue, opacity: 0.5)]
        try await waitForDrawable(renderer)
        XCTAssertTrue(renderer.submitFrame())
        XCTAssertFalse(renderer.presentsWithTransaction, "Ordinary live ink stays asynchronous")
        let before = renderer.submittedFrameCount
        renderer.strokes = []
        var changes = 0
        #if DEBUG
        renderer.testingFailNextEncoding = true
        try await waitForDrawable(renderer)
        XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { changes += 1; scene.image = completed }))
        XCTAssertTrue(scene.image === paper)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(renderer.submittedFrameCount, before)
        XCTAssertFalse(renderer.presentsWithTransaction)
        #endif
        try await waitForDrawable(renderer)
        XCTAssertTrue(renderer.submitFrame(synchronizedUpdate: {
            XCTAssertTrue(renderer.presentsWithTransaction)
            XCTAssertTrue(CATransaction.disableActions())
            XCTAssertFalse(renderer.submitFrame(), "An image-update callback cannot reenter drawable submission")
            changes += 1; scene.image = completed
        }))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(scene.image === completed)
        XCTAssertEqual(renderer.submittedFrameCount, before + 1)
        XCTAssertFalse(renderer.presentsWithTransaction, "Transaction presentation is scoped to the handoff")
        let cleared = try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64))
        XCTAssertTrue(cleared.allSatisfy { $0 == 0 }, "The same successful clear encoder removes live alpha entirely")
    }

    func testGPUAffineProjectionMatchesCPUTransformedGeometry() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let circle = (0..<32).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / 32
            return CGPoint(x: 17.2 + cos(angle)*5.1, y: 13.8 + sin(angle)*5.1)
        }
        let polygons = [circle, [CGPoint(x: 2.3, y: 8.1), CGPoint(x: 25.4, y: 21.3),
                                 CGPoint(x: 23.8, y: 24.2), CGPoint(x: 0.7, y: 11.0)]]
        let transforms = [
            CGAffineTransform.identity,
            CGAffineTransform(translationX: 18.3, y: 9.7).rotated(by: .pi/5).scaledBy(x: 0.75, y: 0.60),
            CGAffineTransform(a: 0, b: 1.3, c: -0.8, d: 0, tx: 45.4, ty: 7.2)
        ]
        for transform in transforms {
            renderer.strokes = [.init(polygons: polygons.map { $0.map { $0.applying(transform) } }, color: .blue, opacity: 0.5)]
            let reference = try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64))
            renderer.strokes = [.init(polygons: polygons, color: .blue, opacity: 0.5, transform: transform)]
            let actual = try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64))
            if transform.isIdentity { XCTAssertEqual(actual, reference); continue }
            var changedPixels = 0, totalDifference = 0, maxDifference = 0
            for pixel in 0..<(64*64) {
                var changed = false
                for component in 0..<4 {
                    let index = pixel*4+component, difference = abs(Int(actual[index])-Int(reference[index]))
                    changed = changed || difference > 0
                    totalDifference += difference; maxDifference = max(maxDifference, difference)
                }
                if changed { changedPixels += 1 }
            }
            // CGFloat CPU and Float GPU arithmetic may move an edge across one
            // MSAA sample. Allow that quantization, never a visible displacement.
            XCTAssertLessThanOrEqual(changedPixels, 4)
            XCTAssertLessThanOrEqual(maxDifference, 64)
            XCTAssertLessThanOrEqual(totalDifference, 512)
        }
    }

    func testIncrementalMeshPixelsMatchFullReplayAcrossPredictionReplacementAndCorrection() throws {
        let live = try XCTUnwrap(NativePDFMetalInk()), reference = try XCTUnwrap(NativePDFMetalInk())
        live.frame = CGRect(x: 0, y: 0, width: 64, height: 64); reference.frame = live.frame
        let geometry = NativePDFInkGeometryV3Cache()
        let points: [NativePDFPoint] = (0..<32).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.02, y: 0.4 + sin(step * 0.2) * 0.15,
                         p: 0.4 + sin(step * 0.3) * 0.2, t: step * 1000 / 240)
        }
        var predictions = Array(points.prefix(28))
        for index in 24..<28 { predictions[index].y += 0.12 }
        var corrected = Array(points.prefix(28)); corrected[4].y -= 0.09; corrected[4].p = 1
        let updates = [Array(points.prefix(20)), Array(points.prefix(24)), predictions,
                       Array(points.prefix(28)), corrected, Array(corrected.prefix(8)), [points[0]]]
        for (index, update) in updates.enumerated() {
            let polygons = geometry.polygons(points: update, width: 0.04, aspect: 1, highlighter: false)
            let transform = CGAffineTransform(scaleX: 64, y: 64)
            live.strokes = [.init(polygons: polygons, color: .blue, opacity: 0.5, transform: transform,
                retainedPrefixPolygonCount: geometry.retainedPrefixPolygonCount, geometryRevision: geometry.revision)]
            reference.strokes = [.init(polygons: polygons, color: .blue, opacity: 0.5, transform: transform,
                retainedPrefixPolygonCount: 0, geometryRevision: geometry.revision)]
            let actual = try XCTUnwrap(live.renderedPixels(width: 64, height: 64))
            let expected = try XCTUnwrap(reference.renderedPixels(width: 64, height: 64))
            XCTAssertEqual(actual, expected, "Incremental GPU upload differs after update \(index)")
            if index == 1 || index == 3 { XCTAssertEqual(live.rebuiltVertexCount, 4 * 96) }
        }
    }

    func testSmallDiagonalAndRoundDotHaveFractionalGPUCoverage() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let diagonal = [CGPoint(x: 3.15, y: 4.05), CGPoint(x: 26.65, y: 21.35),
                        CGPoint(x: 25.75, y: 22.55), CGPoint(x: 2.25, y: 5.25)]
        renderer.strokes = [.init(polygons: [diagonal], color: .black, opacity: 1)]
        let line = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        let supported = [4, 2, 1].first { renderer.device!.supportsTextureSampleCount($0) }!
        XCTAssertEqual(renderer.rasterSampleCount, supported, "Use the best supported union coverage, with 2x/1x fallback")
        guard supported > 1 else { throw XCTSkip("This GPU does not support multisample coverage") }
        func alpha(_ data: Data) -> [UInt8] { stride(from: 3, to: data.count, by: 4).map { data[$0] } }
        XCTAssertGreaterThan(alpha(line).filter { $0 > 0 && $0 < 255 }.count, 20,
            "A thin diagonal must have covered edge samples instead of binary stair steps")
        let radius = 3.75, center = CGPoint(x: 16.2, y: 15.7)
        let circle = (0..<24).map { step in
            let angle = Double(step) * 2 * .pi / 24
            return CGPoint(x: center.x + cos(angle)*radius, y: center.y + sin(angle)*radius)
        }
        renderer.strokes = [.init(polygons: [circle], color: .black, opacity: 1)]
        let dot = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32)), dotAlpha = alpha(dot)
        XCTAssertGreaterThan(dotAlpha.filter { $0 > 0 && $0 < 255 }.count, 8)
        let coverage = dotAlpha.reduce(0.0) { $0 + Double($1)/255 }
        let polygonArea = 24 * radius * radius * sin(2 * .pi / 24) / 2
        XCTAssertEqual(coverage, polygonArea, accuracy: 2,
            "Antialiasing represents the original dot area rather than blurring/spreading it")
    }

    func testMultisampleUnionDoesNotAccumulateOpacityAtEdgesOrCrossings() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let a = [CGPoint(x: 3.2, y: 4.4), CGPoint(x: 28.1, y: 22.8),
                 CGPoint(x: 25.7, y: 26.0), CGPoint(x: 0.8, y: 7.6)]
        let b = [CGPoint(x: 5.4, y: 25.8), CGPoint(x: 27.2, y: 2.6),
                 CGPoint(x: 29.4, y: 4.8), CGPoint(x: 7.6, y: 28.0)]
        renderer.strokes = [.init(polygons: [a,b], color: .blue, opacity: 0.5)]
        let once = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        renderer.strokes = [.init(polygons: [a,b,a,b], color: .blue, opacity: 0.5)]
        let repeated = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(once, repeated, "Covered MSAA samples are replaced, never alpha blended per polygon")
        let alpha = stride(from: 3, to: once.count, by: 4).map { once[$0] }
        XCTAssertEqual(alpha.max(), 128)
        XCTAssertTrue(alpha.allSatisfy { $0 <= 128 }, "A half-opacity stroke cannot darken itself")
        if renderer.rasterSampleCount > 1 {
            XCTAssertTrue(alpha.contains { $0 > 0 && $0 < 128 })
        }
    }

    func testLiveHighlighterUsesPDFBackdropAndSelfCrossingHasOneOpacity() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.black.setFill(); context.fill(CGRect(x: 6, y: 4, width: 4, height: 24))
        }
        renderer.backdrop = backdrop.cgImage
        let a = [CGPoint(x: 2,y: 12), CGPoint(x: 22,y: 12), CGPoint(x: 22,y: 20), CGPoint(x: 2,y: 20)]
        let b = [CGPoint(x: 14,y: 12), CGPoint(x: 30,y: 12), CGPoint(x: 30,y: 20), CGPoint(x: 14,y: 20)]
        renderer.strokes = [.init(polygons: [a,b], color: .yellow, opacity: 0.5, multiply: true)]
        let pixels = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y*32+x)*4..<(y*32+x)*4+4]) }
        XCTAssertEqual(pixel(8,16), [0,0,0,255], "Highlighter must not wash out black PDF glyphs")
        let single = pixel(12,16), crossing = pixel(18,16)
        XCTAssertEqual(single, crossing, "One stroke must keep one opacity at a crossing")
        XCTAssertEqual(single[0], 128, accuracy: 1); XCTAssertEqual(single[1], 255); XCTAssertEqual(single[2], 255)
        XCTAssertEqual(pixel(12,3), [255,255,255,255])
        renderer.strokes = [.init(polygons: [a,b], color: .blue, opacity: 1)]
        let pen = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(Array(pen[(16*32+8)*4..<(16*32+8)*4+4]), [255,0,0,255], "Opaque pen still paints over PDF text")
        renderer.strokes = []
        let cleared = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertTrue(cleared.allSatisfy { $0 == 0 }, "Finished live ink must release its backdrop frame")
    }

    func testGrayPaperStaysNeutralInLiveAndRetainedHighlighterFramesAndAfterErasure() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        // Explicit gray input is deterministic; UIGraphicsImageRenderer may
        // choose either R8 or RGB depending on device/OS and image content.
        var gray = [UInt8](repeating: 255, count: 32 * 32)
        for y in 0..<32 { for x in 6..<10 { gray[y * 32 + x] = 0 } }
        renderer.backdrop = try grayPaper(gray, alpha: false)
        let polygon = [CGPoint(x: 2, y: 12), CGPoint(x: 30, y: 12),
                       CGPoint(x: 30, y: 20), CGPoint(x: 2, y: 20)]
        renderer.strokes = [.init(polygons: [polygon], color: .yellow, opacity: 0.5, multiply: true)]
        let live = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        func pixel(_ data: Data, _ x: Int, _ y: Int) -> [UInt8] {
            Array(data[(y * 32 + x) * 4..<(y * 32 + x) * 4 + 4])
        }
        XCTAssertEqual(pixel(live, 16, 3), [255, 255, 255, 255], "Gray paper must not become a red R8 sample")
        XCTAssertEqual(pixel(live, 8, 16), [0, 0, 0, 255], "Highlighter preserves dark paper content")
        let highlighted = pixel(live, 16, 16)
        XCTAssertEqual(highlighted[0], 128, accuracy: 1)
        XCTAssertEqual(Array(highlighted[1...]), [255, 255, 255])

        let retained = try XCTUnwrap(renderer.retainedRenderer)
        let mesh = try XCTUnwrap(retained.makeMesh(convexPolygons: [polygon]))
        renderer.strokes = []
        renderer.retainedItems = [.init(mesh: mesh, color: SIMD4<Float>(0.5, 0.5, 0, 0.5), multiply: true)]
        let committed = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(pixel(committed, 16, 3), [255, 255, 255, 255])
        XCTAssertEqual(pixel(committed, 8, 16), [0, 0, 0, 255])
        let committedHighlight = pixel(committed, 16, 16)
        // Live ink quantizes the half-alpha union texture before compositing;
        // the retained stencil pass blends once, so one BGRA8 LSB may differ.
        XCTAssertEqual(committedHighlight[0], highlighted[0], accuracy: 1)
        XCTAssertEqual(Array(committedHighlight[1...]), [255, 255, 255])

        renderer.retainedItems = []
        let erased = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(pixel(erased, 16, 16), [255, 255, 255, 255], "Erasing the last mark reveals neutral paper")
        XCTAssertEqual(pixel(erased, 8, 16), [0, 0, 0, 255])
    }

    func testGrayAlphaPaperPreservesPremultiplicationAndImageOrientation() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        var grayAlpha = [UInt8](repeating: 0, count: 32 * 32 * 2)
        for y in 0..<32 { for x in 0..<32 {
            let alpha: UInt8 = y < 16 ? 128 : 64
            grayAlpha[(y * 32 + x) * 2] = alpha // Premultiplied white.
            grayAlpha[(y * 32 + x) * 2 + 1] = alpha
        } }
        renderer.backdrop = try grayPaper(grayAlpha, alpha: true)
        renderer.retainedItems = []
        let pixels = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        for (y, expected) in [(4, UInt8(128)), (28, UInt8(64))] {
            let offset = (y * 32 + 16) * 4
            XCTAssertEqual(Array(pixels[offset..<offset + 4]), [expected, expected, expected, expected],
                "Gray expansion preserves all color channels, alpha, and top-to-bottom row order")
        }
    }

    private func grayPaper(_ bytes: [UInt8], alpha: Bool) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8,
            bitsPerPixel: alpha ? 16 : 8, bytesPerRow: alpha ? 64 : 32,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : .none).rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        return image
    }

    func testCommittedHighlighterKeepsDarkPDFContentAndUniformUnionOpacity() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: 32), geometry: InkPageGeometry(cropBox: CGRect(x: 0,y: 0,width: 32,height: 32), rotation: 0))
        let object: [String: Any] = ["kind": "highlighter", "data": [:], "style": ["color": "yellow", "width": 0.05, "opacity": 0.5],
                                   "nativePath": "M 0.05 0.25 L 0.7 0.25 L 0.7 0.75 L 0.05 0.75 Z M 0.4 0.25 L 0.95 0.25 L 0.95 0.75 L 0.4 0.75 Z"]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 32), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 32,height: 32))
            UIColor.black.setFill(); context.fill(CGRect(x: 6,y: 0,width: 4,height: 32))
            NativePDFObjectRenderer.draw(object, in: context.cgContext, mapper: mapper, image: nil)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 32*32*4)
        let context = try XCTUnwrap(CGContext(data: &pixels,width: 32,height: 32,bitsPerComponent: 8,bytesPerRow: 128,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0,y: 0,width: 32,height: 32))
        func pixel(_ x: Int) -> [UInt8] { Array(pixels[(16*32+x)*4..<(16*32+x)*4+4]) }
        XCTAssertEqual(pixel(8), [0,0,0,255]); XCTAssertEqual(pixel(12),pixel(18))
        XCTAssertLessThan(pixel(12)[2],200); XCTAssertGreaterThan(pixel(12)[0],240)
    }
}
