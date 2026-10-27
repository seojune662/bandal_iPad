import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativeWorkspacePreviewTests: XCTestCase {
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
    }
    private func fixture() -> (NativeWorkspacePreviewController, UIWindow, UIView, URL) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let host = UIViewController(); window.rootViewController = host; window.isHidden = false
        host.view.frame = window.bounds; host.view.backgroundColor = .red
        let anchor = UIView(frame: CGRect(x: 40, y: 20, width: 160, height: 140))
        anchor.backgroundColor = .green; host.view.addSubview(anchor)
        let controller = NativeWorkspacePreviewController(); controller.anchor = anchor
        return (controller, window, anchor, FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func pixel(_ image: UIImage, at point: CGPoint) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -point.x, y: -point.y)
        context.draw(image.cgImage!, in: CGRect(origin: .zero, size: image.size))
        return pixel
    }
    func testCompositeCropsDockAndRestoresLatestImageWithoutOtherProfileOrWindow() async throws {
        let (controller, window, anchor, root) = fixture()
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        let surface = UIView(frame: CGRect(x: 10, y: 10, width: 80, height: 60)); anchor.addSubview(surface)
        let blue = image(.blue)
        controller.register(UUID(), view: surface, id: "public", privateContent: { false }, capture: { blue })
        let captured = await controller.capture(root: root, workspaceID: "course", windowID: "one")
        XCTAssertTrue(captured)
        let restored = NativeWorkspacePreviewController()
        let cached = try XCTUnwrap(restored.image(root: root, workspaceID: "course", windowID: "one"))
        XCTAssertEqual(cached.size, anchor.bounds.size)
        XCTAssertNil(restored.image(root: root, workspaceID: "course", windowID: "two"))
        XCTAssertNil(restored.image(root: root.appendingPathComponent("other-profile"), workspaceID: "course", windowID: "one"))
        let outside = pixel(cached, at: CGPoint(x: 130, y: 100))
        XCTAssertGreaterThan(outside[1], 200); XCTAssertLessThan(outside[0], 35, "The surrounding red app chrome must not enter the dock crop")
        let pixels = [pixel(cached, at: CGPoint(x: 30, y: 30)), pixel(cached, at: CGPoint(x: 30, y: 110))]
        XCTAssertTrue(pixels.contains { $0[2] > 200 && $0[0] < 35 && $0[1] < 35 }, "The actual native surface pixels must be composited")
        try restored.remove(root: root, workspaceID: "course", windowID: "one")
        XCTAssertNil(restored.image(root: root, workspaceID: "course", windowID: "one"))
    }
    func testPrivateSurfaceNeverCallsCaptureAndMasksPixelsBeforeCache() async throws {
        let (controller, window, anchor, root) = fixture()
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        let surface = UIView(frame: anchor.bounds); surface.backgroundColor = .red; anchor.addSubview(surface)
        var calls = 0
        controller.register(UUID(), view: surface, id: "private", privateContent: { true }, capture: {
            calls += 1; return self.image(.red)
        })
        let captured = await controller.capture(root: root, workspaceID: "course", windowID: "private-window")
        XCTAssertTrue(captured); XCTAssertEqual(calls, 0)
        let cached = try XCTUnwrap(NativeWorkspacePreviewController().image(root: root, workspaceID: "course", windowID: "private-window"))
        let value = pixel(cached, at: CGPoint(x: 5, y: 5))
        XCTAssertLessThan(abs(Int(value[0]) - Int(value[1])), 12)
        XCTAssertLessThan(abs(Int(value[1]) - Int(value[2])), 12)
    }
    func testIsolatedDockCapturesUnderOpenDrawerWithoutHidingOrMovingIt() async throws {
        let (controller, window, anchor, root) = fixture()
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        controller.capturesAnchorContents = true
        let drawer = UIView(frame: anchor.convert(anchor.bounds, to: window)); drawer.backgroundColor = .red
        window.addSubview(drawer)
        let originalFrame = drawer.frame
        controller.register(UUID(), view: drawer, id: "open-drawer", privateContent: { false }, capture: nil, excluded: true, occludesContent: true)
        let captured = await controller.capture(root: root, workspaceID: "course", windowID: "one")
        XCTAssertTrue(captured)
        XCTAssertFalse(drawer.isHidden); XCTAssertEqual(drawer.alpha, 1); XCTAssertEqual(drawer.frame, originalFrame)
        let cached = try XCTUnwrap(controller.image(root: root, workspaceID: "course", windowID: "one"))
        let value = pixel(cached, at: CGPoint(x: 80, y: 70))
        XCTAssertGreaterThan(value[1], 200); XCTAssertLessThan(value[0], 35, "The green dock remains visible in its own capture beneath the red drawer")
    }
    func testFailedStaleAndOccludedCapturesKeepPreviousBytes() async throws {
        let (controller, window, anchor, root) = fixture()
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        let first = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertTrue(first)
        let url = NativeWorkspacePreviewController.fileURL(root: root, workspaceID: "c", windowID: "w")
        let previous = try Data(contentsOf: url), token = UUID()
        controller.register(token, view: anchor, id: "failed", privateContent: { false }, capture: { nil })
        let failed = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertFalse(failed); XCTAssertEqual(try Data(contentsOf: url), previous)
        controller.register(token, view: anchor, id: "stale", privateContent: { false }, capture: {
            controller.invalidate(); return self.image(.blue)
        })
        let stale = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertFalse(stale); XCTAssertEqual(try Data(contentsOf: url), previous)
        controller.register(token, view: anchor, id: "drawer", privateContent: { false }, capture: nil, excluded: true, occludesContent: true)
        let occluded = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertFalse(occluded); XCTAssertEqual(try Data(contentsOf: url), previous)
    }
    func testCacheNamesContainNoDocumentAddressOrWindowNameAndDoNotCollide() {
        let root = URL(fileURLWithPath: "/tmp/profile")
        let first = NativeWorkspacePreviewController.fileURL(root: root, workspaceID: "../private/course", windowID: "../secret?url")
        XCTAssertEqual(first.deletingLastPathComponent(), root.appendingPathComponent("NativeWorkspacePreviews", isDirectory: true))
        XCTAssertEqual(first.pathExtension, "jpg")
        XCTAssertEqual(first.deletingPathExtension().lastPathComponent.count, 64)
        XCTAssertNotEqual(first, NativeWorkspacePreviewController.fileURL(root: root, workspaceID: "../private", windowID: "course../secret?url"))
    }
    func testOneSecondDeadlineKeepsCacheAndDiscardsLateNativeSnapshot() async throws {
        let (controller, window, anchor, root) = fixture()
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        let first = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertTrue(first)
        let url = NativeWorkspacePreviewController.fileURL(root: root, workspaceID: "c", windowID: "w")
        let previous = try Data(contentsOf: url)
        var reply: CheckedContinuation<UIImage?, Never>?
        controller.register(UUID(), view: anchor, id: "slow-webkit", privateContent: { false }, capture: {
            await withCheckedContinuation { reply = $0 }
        })
        let started = Date()
        let result = await controller.capture(root: root, workspaceID: "c", windowID: "w")
        XCTAssertFalse(result); XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertEqual(try Data(contentsOf: url), previous)
        let pending = try XCTUnwrap(reply); pending.resume(returning: image(.blue))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(try Data(contentsOf: url), previous, "A native completion after timeout must never replace the last valid preview")
    }

    func testRealPDFWorkspacePreviewCompositesSavedInkAndSurvivesHideRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-preview-ink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context), repository = try NativePDFRepository(context: context)
        let course = try XCTUnwrap((try library.handle("courses:create", ["name": "Preview Ink", "color": "blue"]) as? [String: Any])?["id"] as? String)
        let note = try XCTUnwrap(try repository.handle("pdfNotes:create", ["courseId": course, "title": "Synthetic preview", "paper": "blank", "orientation": "portrait"]) as? [String: Any])
        let path = try XCTUnwrap(note["relPath"] as? String)
        let identity: [String: Any] = ["courseId": course, "relPath": path]
        let binding = try XCTUnwrap(try repository.handle("nativePDF:binding", identity) as? [String: Any])
        _ = try repository.handle("drawings:create", identity.merging([
            "documentRevision": try XCTUnwrap(binding["documentRevision"] as? String),
            "clientMutationId": UUID().uuidString, "page": 1, "kind": "ink",
            "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.8, "t": 0], ["x": 0.8, "y": 0.3, "p": 0.8, "t": 100]]],
            "style": ["color": "red", "width": 0.025, "opacity": 1]
        ]) { _, value in value })
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start(); XCTAssertTrue(store.isReady)
        try await waitForPreviewHost { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible(); window.layoutIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let suite = "workspace-preview-ink-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = NativePDFWorkspaceModel(document: .init(courseID: course, relativePath: path, title: "Synthetic preview", kind: "pdf"), store: store, defaults: defaults)
        defer { model.close() }
        model.setAvailableWidth(host.view.bounds.width)
        model.attach(to: host.view); model.layout(host.view.bounds)
        try await waitForPreviewHost { !model.isLoading || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.drawingCount, 1)
        let pdfView = try XCTUnwrap(host.view.subviews.compactMap { $0 as? PDFView }.first)
        try await waitForPreviewHost { !pdfView.visiblePages.isEmpty }
        let rendered = try await model.workspacePreview()
        XCTAssertGreaterThan(try redPixelCount(XCTUnwrap(rendered)), 100, "The actual PDF provider must include saved ink, not only its white PDF page")

        let preview = NativeWorkspacePreviewController(); preview.anchor = host.view; preview.capturesAnchorContents = true
        preview.register(UUID(), view: pdfView, id: "real-pdf", privateContent: { false }, capture: { try await model.workspacePreview() })
        let captured = await preview.capture(root: root, workspaceID: course, windowID: "one")
        XCTAssertTrue(captured)
        let cached = try XCTUnwrap(NativeWorkspacePreviewController().image(root: root, workspaceID: course, windowID: "one"))
        XCTAssertGreaterThan(try redPixelCount(cached), 100, "The final JPEG must retain the provider's ink pixels")
        model.setVisible(false)
        try await waitForPreviewHost { pdfView.document == nil }
        let hidden = try await model.workspacePreview()
        XCTAssertNil(hidden)
        model.setVisible(true)
        try await waitForPreviewHost { !pdfView.visiblePages.isEmpty }
        let restored = try await model.workspacePreview()
        XCTAssertGreaterThan(try redPixelCount(XCTUnwrap(restored)), 100)
        model.close()
        try await waitForPreviewHost { pdfView.superview == nil }
    }

    private func waitForPreviewHost(_ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 10
        while !predicate(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "The PDF preview host did not settle")
    }

    private func redPixelCount(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) {
            $0 + (pixels[$1] > 150 && pixels[$1 + 1] < 125 && pixels[$1 + 2] < 125 ? 1 : 0)
        }
    }
}
