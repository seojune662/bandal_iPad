import XCTest
import UIKit
import MetalKit
@testable import Bandal

/// Isolated resource-failure regressions. These tests need the scratch loader
/// and clock seam; no production test target has been modified to include them.
@MainActor
final class NativePDFMetalTextureRecoveryTests: XCTestCase {
    private enum UploadError: Error { case injected }
    private let size = 32
    private func image(_ color: UIColor) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.cgImage!
    }
    private func load(_ device: MTLDevice, _ image: CGImage) throws -> MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: image,
            options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
    }
    private func configure(_ renderer: NativePDFMetalInk) {
        renderer.frame = CGRect(x: 0, y: 0, width: size, height: size)
    }
    private func stroke(multiply: Bool) -> NativePDFMetalInk.Stroke {
        .init(polygons: [[CGPoint(x: 8, y: 8), CGPoint(x: 24, y: 8), CGPoint(x: 24, y: 24), CGPoint(x: 8, y: 24)]],
            color: UIColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1), opacity: 0.45, multiply: multiply)
    }
    private func pixels(_ renderer: NativePDFMetalInk) -> Data? { renderer.renderedPixels(width: size, height: size) }
    private func assertPendingInput(_ renderer: NativePDFMetalInk, latest: CFTimeInterval = 1_000.02,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(renderer.pendingInputTiming?.strokeID, 42, file: file, line: line)
        XCTAssertEqual(renderer.pendingInputTiming?.firstInputAt, 1_000, file: file, line: line)
        XCTAssertEqual(renderer.pendingInputTiming?.latestInputAt, latest, file: file, line: line)
        XCTAssertEqual(renderer.submittedFrameCount, 0, file: file, line: line)
        XCTAssertNil(renderer.lastSubmittedFrame, file: file, line: line)
        XCTAssertNil(renderer.lastPresentedFrame, file: file, line: line)
    }

    func testThrownUploadAndMissingDestinationNeverBecomeNormalAlphaMultiply() throws {
        var attempts = 0
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { _, _ in
            attempts += 1; throw UploadError.injected
        }, clock: { 10 }))
        configure(renderer); renderer.strokes = [stroke(multiply: true)]
        XCTAssertNil(pixels(renderer), "A highlighter requires real destination pixels")
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: true), .missing)
        renderer.backdrop = image(.cyan)
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(pixels(renderer), "The loader threw: successful normal-alpha pixels are an incorrect fallback")
        XCTAssertEqual(renderer.submittedFrameCount, 0, "Offscreen pixel encoding is not a presentation")
    }

    func testIdenticalImageRecoversAfterDeadlineWithExactReferencePixels() throws {
        var attempts = 0, time: CFTimeInterval = 0
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { device, image in
            attempts += 1
            if attempts == 1 { throw UploadError.injected }
            return try self.load(device, image)
        }, clock: { time }))
        configure(renderer); let backdrop = image(.cyan)
        renderer.noteInputReceived(at: 1_000, strokeID: 42)
        renderer.noteInputReceived(at: 1_000.02, strokeID: 42)
        renderer.backdrop = backdrop; renderer.strokes = [stroke(multiply: true)]
        XCTAssertNil(pixels(renderer))
        assertPendingInput(renderer)
        for _ in 0..<100 { renderer.backdrop = backdrop }
        XCTAssertEqual(attempts, 1)
        time = 0.049; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 1)
        time = 0.05; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 2)
        let reference = try XCTUnwrap(NativePDFMetalInk()); configure(reference)
        reference.backdrop = backdrop; reference.strokes = [stroke(multiply: true)]
        let actual = try XCTUnwrap(pixels(renderer)), expected = try XCTUnwrap(pixels(reference))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: true), .ready)
        XCTAssertNil(renderer.backdropUploadErrorDescription)
        assertPendingInput(renderer)
        renderer.noteInputReceived(at: 1_000.03, strokeID: 42)
        assertPendingInput(renderer, latest: 1_000.03)
        for _ in 0..<100 { time += 1; renderer.backdrop = backdrop }
        XCTAssertEqual(attempts, 2, "Once uploaded, same-image assignments keep the fast path")
    }

    func testNilDetachDoesNotResetBoundedClockRetriesButNewPageOrImageDoes() throws {
        var attempts = 0, time: CFTimeInterval = 0
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { _, _ in
            attempts += 1; throw UploadError.injected
        }, clock: { time }))
        configure(renderer); let backdrop = image(.cyan)
        renderer.backdrop = backdrop; renderer.strokes = [stroke(multiply: true)]
        let generation = renderer.backdropRecoveryGeneration
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: true), .waiting(generation: generation, retryAt: 0.05))
        for _ in 0..<100 {
            renderer.backdrop = nil; renderer.backdrop = backdrop; XCTAssertNil(pixels(renderer))
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(renderer.backdropRecoveryGeneration, generation)
        time = 0.049; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 1)
        time = 0.05; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 2)
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: true), .waiting(generation: generation, retryAt: 0.25))
        time = 0.249; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 2)
        time = 0.25; renderer.backdrop = backdrop; XCTAssertEqual(attempts, 3)
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: true), .exhausted(generation: generation))
        for _ in 0..<100 {
            time += 10; renderer.backdrop = nil; renderer.backdrop = backdrop; XCTAssertNil(pixels(renderer))
        }
        XCTAssertEqual(attempts, 3, "Permanent failure cannot create an unlimited OOM upload loop")
        XCTAssertEqual(renderer.backdropRecoveryGeneration, generation)
        XCTAssertEqual(renderer.backdropRecoveryTime, time)
        XCTAssertNotNil(renderer.backdropUploadErrorDescription)
        renderer.resetBackdropRecovery(); renderer.backdrop = backdrop
        XCTAssertEqual(attempts, 4, "Explicit page replacement starts a new recovery budget")
        XCTAssertNotEqual(renderer.backdropRecoveryGeneration, generation)
        renderer.backdrop = image(.orange); XCTAssertEqual(attempts, 5)
    }

    func testClearAndNoBackdropOrdinarySucceedButFailedCompoundOrdinaryIsRejected() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { _, _ in throw UploadError.injected }, clock: { 0 }))
        configure(renderer); renderer.backdrop = image(.cyan)
        renderer.strokes = [stroke(multiply: true)]; XCTAssertNil(pixels(renderer))
        renderer.strokes = []; XCTAssertTrue(try XCTUnwrap(pixels(renderer)).allSatisfy { $0 == 0 })
        XCTAssertEqual(renderer.prepareBackdropForFrame(required: false), .notRequired)
        renderer.strokes = [stroke(multiply: false)]
        XCTAssertNil(pixels(renderer), "Explicit compound-frame backdrop cannot silently disappear even for ordinary pen")
        renderer.backdrop = nil
        let actual = try XCTUnwrap(pixels(renderer))
        let reference = try XCTUnwrap(NativePDFMetalInk()); configure(reference); reference.strokes = renderer.strokes
        XCTAssertEqual(actual, try XCTUnwrap(pixels(reference)))
    }

    func testFailedOffscreenAttemptsPreserveOriginalPendingInputAndNeverReportPresentation() throws {
        var attempts = 0, time: CFTimeInterval = 0
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { _, _ in
            attempts += 1; throw UploadError.injected
        }, clock: { time }))
        configure(renderer); let backdrop = image(.cyan)
        renderer.strokes = [stroke(multiply: true)]
        renderer.noteInputReceived(at: 1_000, strokeID: 42)
        renderer.noteInputReceived(at: 1_000.02, strokeID: 42)
        var callbacks = 0, sceneChanges = 0
        renderer.onFrameSubmitted = { _ in callbacks += 1 }
        renderer.onFramePresented = { _ in callbacks += 1 }
        renderer.onSubmission = { _ in callbacks += 1 }
        for deadline in [0.0, 0.05, 0.25, 1_000.0] {
            time = deadline; renderer.backdrop = backdrop
            XCTAssertNil(pixels(renderer))
            // Deliberately no window: no assertion here claims that a physical
            // drawable was acquired or that the texture guard caused the false.
            XCTAssertFalse(renderer.submitFrame(synchronizedUpdate: { sceneChanges += 1 }))
            assertPendingInput(renderer)
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(sceneChanges, 0)
    }

    func testFailedReplacementCannotMixOldTextureIntoNewBackground() throws {
        var attempts = 0, time: CFTimeInterval = 50
        let renderer = try XCTUnwrap(NativePDFMetalInk(textureLoader: { device, image in
            attempts += 1
            if attempts == 2 { throw UploadError.injected }
            return try self.load(device, image)
        }, clock: { time }))
        configure(renderer); renderer.strokes = [stroke(multiply: true)]
        renderer.backdrop = image(.cyan)
        let previous = try XCTUnwrap(pixels(renderer))
        let replacement = image(.orange); renderer.backdrop = replacement
        XCTAssertEqual(attempts, 2); XCTAssertNil(pixels(renderer))
        time += 0.050001; renderer.backdrop = replacement
        let actual = try XCTUnwrap(pixels(renderer))
        let reference = try XCTUnwrap(NativePDFMetalInk()); configure(reference)
        reference.backdrop = replacement; reference.strokes = renderer.strokes
        XCTAssertEqual(actual, try XCTUnwrap(pixels(reference))); XCTAssertNotEqual(actual, previous)
        renderer.backdrop = nil; XCTAssertNil(pixels(renderer), "nil must not retain the previous GPU texture")
    }
}
