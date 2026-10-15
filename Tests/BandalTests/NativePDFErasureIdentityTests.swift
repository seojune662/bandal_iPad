import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// The canonical snapshot decorates recent saved rows with their session's
/// clientMutationId; the editor scene currently sends id-only rows. Both carry
/// exactly the same measured geometry. This fixture reproduces that real wire
/// sequence on the actual Surface, without an unresolved input/journal oracle.
@MainActor
final class NativePDFErasureIdentityTests: XCTestCase {
    private typealias Base = NativePDFAsynchronousEditTests

    func testCanonicalToEditorIdentityReuseCannotReexposePreviouslyErasedInk() async throws {
        let f = try await Fixture.make(canonical: true)
        defer { f.close() }
        try await f.settle()
        let canonical = f.rows, originalImage = try XCTUnwrap(f.image.image)
        let originalPixels = try Base.pixels(try XCTUnwrap(originalImage.cgImage))
        let full = f.int("sceneFullRenders"), reused = f.int("sceneReuses")
        let baselineRevision = f.revision
        XCTAssertEqual(f.int("asynchronousEditTileInstalls"), 0)
        _ = try await captureUntil(f) { $0.a > 100 && $0.b > 100 && $0.survivors > 200 }

        // A real editor publication omits only the receipt association. The
        // saved IDs/data/style remain identical, including two recent survivors.
        let editor = withoutMutationIDs(canonical)
        f.replace(editor)
        try await require {
            f.int("sceneReuses") > reused && f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertTrue(f.image.image === originalImage)
        XCTAssertFalse(f.image.isHidden)
        XCTAssertEqual(f.revision, baselineRevision, "The immutable vector builder must prove unchanged appearance")
        XCTAssertEqual(f.int("sceneFullRenders"), full)
        XCTAssertEqual(f.surface.inputDiagnostics["sceneRenderMode"] as? String, "reuse")
        XCTAssertTrue(try Base.pixels(XCTUnwrap(f.image.image?.cgImage)) == originalPixels)
        XCTAssertEqual(f.inputWrites, 0); XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, false)

        f.replace(Array(editor.dropFirst())) // Erase old A, keep both recent rows.
        let first = try await latestRequest(f)
        let usesProgressive = f.progressive
        XCTAssertTrue(usesProgressive,
            "Same visible pixels with refreshed canonical/editor identity must still enter protected erasure")

        // On the protected implementation R1 must be rendered by the worker.
        // On baseline28 the erroneous tile path already renders R1; keep its
        // crop held so a full-image completion cannot hide the faulty R1->R2
        // replacement. Both branches must reach the same actual A-absent pixels.
        if usesProgressive { try await f.rasters.finish(first) }
        let afterA = try await captureUntil(f) { $0.a == 0 && $0.b > 100 && $0.survivors > 200 }
        attach(afterA.image, name: "identity-R1-A-actually-absent")
        if usesProgressive {
            try await require { f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false && !f.image.isHidden }
        } else {
            XCTAssertTrue(f.image.isHidden)
            XCTAssertGreaterThan(f.int("asynchronousEditTileInstalls"), 0)
        }
        let firstVisibleRevision = try XCTUnwrap(f.navigation.revision)
        f.tiles.hold(after: firstVisibleRevision)
        let tileInstallsBeforeSecond = f.int("asynchronousEditTileInstalls")
        f.replace(Array(editor.dropFirst(2))) // Erase old B; neither new row is erased.
        let second = try await latestRequest(f)
        XCTAssertNotEqual(second.snapshot.revision, first.snapshot.revision)
        XCTAssertTrue(f.progressive, "The second deletion must retain the accepted A-absent image")
        if !f.progressive {
            try await require(timeout: 3) { f.tiles.heldEntries > 0 }
        }

        var maxA = 0, minimumSurvivors = Int.max
        for _ in 0..<10 {
            let sample = try capture(f)
            maxA = max(maxA, sample.counts.a)
            minimumSurvivors = min(minimumSurvivors, sample.counts.survivors)
            if sample.counts.a > 0 { attach(sample.image, name: "identity-R2-held-A-reappeared") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(f.tiles.mainEntries, 0)
        XCTAssertEqual(f.tiles.timeouts, 0)
        XCTAssertGreaterThan(minimumSurvivors, 200, "A blank frame cannot satisfy deletion continuity")
        XCTAssertEqual(maxA, 0, "A was visibly absent, and must not reappear while B's newer revision waits")
        XCTAssertEqual(f.int("asynchronousEditTileInstalls"), tileInstallsBeforeSecond,
            "No empty replacement tile layer may replace the accepted deletion image")
        print("[ERASURE_IDENTITY] sameImage=1 reuse=\(f.int("sceneReuses")) protectedR1=\(usesProgressive ? 1 : 0) firstAbsentA=\(afterA.counts.a) heldMaxA=\(maxA) survivorsMin=\(minimumSurvivors) heldTiles=\(f.tiles.heldEntries)")

        f.tiles.open()
        try await f.rasters.finish(second)
        try await finishExactly(f)
        _ = try await captureUntil(f) { $0.a == 0 && $0.b == 0 && $0.survivors > 200 }
        XCTAssertEqual(f.int("sceneFullRenders"), full)
        XCTAssertEqual(f.inputWrites, 0)
    }

    func testEditorToCanonicalIdentityReusePreservesPixelsAndProtectedDeletion() async throws {
        let f = try await Fixture.make(canonical: false)
        defer { f.close() }
        try await f.settle()
        let image = try XCTUnwrap(f.image.image), full = f.int("sceneFullRenders"), reuse = f.int("sceneReuses")
        let bytes = try Base.pixels(try XCTUnwrap(image.cgImage))
        // The session map can become available after the first canonical row
        // was shown. Native provenance must also accept this reverse transition.
        f.replace(Self.fixtureRows(canonical: true))
        try await require {
            f.int("sceneReuses") > reuse && f.surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertTrue(f.image.image === image)
        XCTAssertTrue(try Base.pixels(XCTUnwrap(f.image.image?.cgImage)) == bytes)
        f.replace(Array(f.rows.dropFirst()))
        let first = try await latestRequest(f)
        XCTAssertTrue(f.progressive, "Receipt metadata arriving later must not force the unprotected tile path")
        try await f.rasters.finish(first)
        try await finishExactly(f)
        XCTAssertEqual(f.int("sceneFullRenders"), full); XCTAssertEqual(f.inputWrites, 0)
    }

    private func withoutMutationIDs(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.map { row in var copy = row; copy.removeValue(forKey: "clientMutationId"); return copy }
    }
    private static func fixtureRows(canonical: Bool) -> [[String: Any]] {
        let specs: [(String, String, Double, String?)] = [
            ("old-A", "red", 0.40, nil), ("old-B", "green", 0.55, nil),
            ("saved-C", "blue", 0.70, "00000000-0000-4000-8000-000000000001"),
            ("saved-D", "blue", 0.85, "00000000-0000-4000-8000-000000000002")]
        return specs.map { id, color, y, mutation in
            var row: [String: Any] = ["id": id, "page": 1, "kind": "ink",
                "data": ["inkVersion": 4, "points": [["x": 0.15, "y": y, "p": 0.8], ["x": 0.85, "y": y, "p": 0.8]]],
                "style": ["color": color, "width": 0.018, "opacity": 1.0]]
            if canonical, let mutation { row["clientMutationId"] = mutation }
            return row
        }
    }

    @MainActor private final class Fixture {
        let window: UIWindow, previous: UIWindow?, document: PDFDocument, page: PDFPage
        let surface: NativePDFInkSurface, image: UIImageView, metal: NativePDFMetalInk, navigation: NativePDFNavigationView
        let tiles: IdentityTileGate, rasters: Base.Gate
        var rows: [[String: Any]], inputWrites = 0
        var revision: UInt64 { surface.inputDiagnostics["navigationCurrentRevision"] as? UInt64 ?? 0 }
        var progressive: Bool { surface.inputDiagnostics["progressiveErasureActive"] as? Bool == true }
        static func make(canonical: Bool) async throws -> Fixture {
            Base.assertTrue(await Base.poll(timeout: 2) {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            return try Fixture(scene: scene, canonical: canonical)
        }
        private init(scene: UIWindowScene, canonical: Bool) throws {
            let size = CGSize(width: 384, height: 512)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { c in
                c.beginPage(); c.cgContext.setFillColor(UIColor(white: 0.8, alpha: 1).cgColor)
                c.cgContext.fill(CGRect(x: 30, y: 40, width: 150, height: 100))
            }
            document = try XCTUnwrap(PDFDocument(data: data)); page = try XCTUnwrap(document.page(at: 0))
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            rows = NativePDFErasureIdentityTests.fixtureRows(canonical: canonical)
            let tileGate = IdentityTileGate(), rasterGate = Base.Gate()
            tiles = tileGate; rasters = rasterGate
            surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: size),
                navigationRasterRequest: { [weak rasterGate] in rasterGate?.requests.append($0) },
                navigationTileDraw: { revision in tileGate.enter(revision) }))
            image = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
            metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
            navigation = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFNavigationView }.first)
            surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
            surface.tool = .init(name: "eraser", style: .init(color: "blue", width: 0.009, opacity: 0.45))
            surface.applyObjects(objects: rows, visualTokens: rows.map(NativePDFCommittedVisualToken.init))
            surface.onStroke = { [weak self] _ in self?.inputWrites += 1; XCTFail("No new Pencil input belongs to this identity-only test") }
            surface.onCheckpoint = { [weak self] _ in self?.inputWrites += 1; XCTFail("No pending estimate belongs to this test") }
            surface.onFailure = { XCTFail("Unexpected Surface failure: \($0)") }
            window.rootViewController!.view.addSubview(surface)
            window.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func replace(_ values: [[String: Any]]) {
            rows = values; surface.applyObjects(objects: values, visualTokens: values.map(NativePDFCommittedVisualToken.init))
        }
        func int(_ key: String) -> Int { surface.inputDiagnostics[key] as? Int ?? -1 }
        func settle() async throws {
            Base.assertTrue(await Base.poll(timeout: 8) {
                self.image.image != nil && !self.image.isHidden && self.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                    self.surface.inputDiagnostics["frameRequested"] as? Bool == false
            })
            _ = try XCTUnwrap(image.image)
            XCTAssertEqual(int("sceneFullRenders"), 1); XCTAssertTrue(rasters.requests.isEmpty)
        }
        func close() {
            tiles.open() // Workers must exit before their view/window is removed.
            surface.onFailure = nil; surface.onStroke = nil; surface.onCheckpoint = nil
            rasters.requests.removeAll(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
    private func latestRequest(_ f: Fixture) async throws -> NativePDFNavigationRasterizer.Request {
        try await require {
            f.rasters.requests.last?.snapshot.revision == f.revision &&
                f.rasters.requests.last?.snapshot.objects.count == f.rows.count
        }
        return try XCTUnwrap(f.rasters.requests.last)
    }
    private func finishExactly(_ f: Fixture) async throws {
        try await require(timeout: 8) {
            f.surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false && !f.image.isHidden &&
                f.surface.inputDiagnostics["frameRequested"] as? Bool == false && f.metal.strokes.isEmpty
        }
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: f.page, mapper: mapper,
            bounds: viewport.canvasRect, scale: viewport.pixelScale) { context in
            for row in f.rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        }?.cgImage)
        let actual = try XCTUnwrap(f.image.image?.cgImage)
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertTrue(try Base.pixels(actual) == Base.pixels(expected), "Final authoritative one-pass RGBA must remain exact")
    }
    private struct Counts { var a = 0, b = 0, survivors = 0 }
    private struct Capture { let image: CGImage; let counts: Counts }
    private func capture(_ f: Fixture) throws -> Capture {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var success = false
        let value = UIGraphicsImageRenderer(size: f.surface.bounds.size, format: format).image { _ in
            success = f.surface.drawHierarchy(in: f.surface.bounds, afterScreenUpdates: false)
        }
        XCTAssertTrue(success)
        let image = try XCTUnwrap(value.cgImage), bytes = try Base.pixels(image)
        var counts = Counts()
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index+1]), b = Int(bytes[index+2])
            if r > 160 && g < 90 && b < 100 { counts.a += 1 }
            if g > 95 && r < 120 && b < 170 { counts.b += 1 }
            if b > 140 && r < 100 && g < 180 { counts.survivors += 1 }
        }
        return Capture(image: image, counts: counts)
    }
    private func captureUntil(_ f: Fixture, timeout: TimeInterval = 4, _ predicate: (Counts) -> Bool) async throws -> Capture {
        let deadline = CACurrentMediaTime() + timeout
        var value = try capture(f)
        while !predicate(value.counts), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20)); value = try capture(f)
        }
        XCTAssertTrue(predicate(value.counts), "Missing hierarchy state A=\(value.counts.a) B=\(value.counts.b) survivors=\(value.counts.survivors)")
        guard predicate(value.counts) else { throw FixtureError.timeout }
        return value
    }
    private func require(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
        let value = await Base.poll(timeout: timeout, condition)
        XCTAssertTrue(value, "Required identity handoff state timed out")
        guard value else { throw FixtureError.timeout }
    }
    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private enum FixtureError: Error { case timeout }
}

private final class IdentityTileGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var threshold: UInt64?
    private var held = 0, main = 0, expired = 0
    var heldEntries: Int { condition.lock(); defer { condition.unlock() }; return held }
    var mainEntries: Int { condition.lock(); defer { condition.unlock() }; return main }
    var timeouts: Int { condition.lock(); defer { condition.unlock() }; return expired }
    func hold(after revision: UInt64) { condition.lock(); threshold = revision; condition.unlock() }
    func open() { condition.lock(); threshold = nil; condition.broadcast(); condition.unlock() }
    func enter(_ revision: UInt64) {
        condition.lock(); defer { condition.unlock() }
        guard let boundary = threshold, revision > boundary else { return }
        held += 1
        guard !Thread.isMainThread else { main += 1; return }
        let deadline = Date().addingTimeInterval(8)
        while let boundary = threshold, revision > boundary {
            if !condition.wait(until: deadline) { expired += 1; break }
        }
    }
}
