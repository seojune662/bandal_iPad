import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativeAssistantAttachmentTests: XCTestCase {
    func testCaptureRestoresAcrossEncodingWithImmutableSourceMetadata() throws {
        let attachment = NativeAssistantAttachment(title: "필기", text: "선택한 문장", imageDataURL: "data:image/png;base64,aGVsbG8=",
            courseID: "course", relativePath: "notes/example.pdf", page: 3, url: "https://example.com", revision: "original:4")
        let restored = try JSONDecoder().decode(NativeAssistantAttachment.self, from: JSONEncoder().encode(attachment))
        XCTAssertEqual(restored, attachment)
        XCTAssertEqual(restored.page, 3)
    }
    func testCancelledOrReplacedCaptureCannotReachAnotherSpace() throws {
        let coordinator = NativeAnnotationCoordinator()
        coordinator.begin(documentID: "a", spaceID: "project-a")
        let first = try XCTUnwrap(coordinator.request)
        coordinator.begin(documentID: "b", spaceID: "project-b")
        let second = try XCTUnwrap(coordinator.request)
        coordinator.complete(.init(title: "late a", text: "a"), requestID: first.id)
        XCTAssertNil(coordinator.completed)
        XCTAssertEqual(coordinator.request, second)
        coordinator.cancel()
        coordinator.complete(.init(title: "late b", text: "b"), requestID: second.id)
        XCTAssertNil(coordinator.completed)
        coordinator.begin(documentID: "a", spaceID: "project-a")
        let current = try XCTUnwrap(coordinator.request)
        coordinator.complete(.init(title: "valid", text: "a"), requestID: current.id)
        XCTAssertEqual(coordinator.completed?.spaceID, "project-a")
        XCTAssertNil(coordinator.request)
        coordinator.consumeCompleted()
        XCTAssertNil(coordinator.completed)
    }
    func testPDFAnnotationCancelRestoresToolAndDoesNotPersistSelectionMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "annotation-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: root)
        let document = NativeDocumentReference(courseID: "course", relativePath: "note.pdf", title: "노트", kind: "pdf")
        let model = NativePDFWorkspaceModel(document: document, store: store, defaults: defaults)
        model.chooseTool("highlighter")
        XCTAssertEqual(model.tool, "highlighter")
        store.annotation.begin(documentID: document.id, spaceID: "course:course")
        XCTAssertEqual(model.tool, "lasso")
        model.setAssistantRegionMode(false)
        XCTAssertEqual(model.tool, "select")
        model.chooseTool("eraser")
        XCTAssertEqual(model.tool, "select", "Tool shortcuts must not turn annotation into an edit")
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: root, documentID: document.id, defaults: defaults).tool, "highlighter")
        store.annotation.cancel()
        XCTAssertEqual(model.tool, "highlighter")
        XCTAssertNil(model.assistantAnnotation)
    }
    func testPDFAnnotationToolTransitionsPreserveLiveHostAndNextCommittedStroke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context)
        let course = try XCTUnwrap((try library.handle("courses:create", ["name": "Annotation", "color": "blue"]) as? [String: Any])?["id"] as? String)
        let note = try XCTUnwrap(try pdf.handle("pdfNotes:create", ["courseId": course, "title": "Annotation", "paper": "blank", "orientation": "portrait"]) as? [String: Any])
        let path = try XCTUnwrap(note["relPath"] as? String)
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start(); XCTAssertTrue(store.isReady)
        try await waitForHost {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let suite = "annotation-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = NativeDocumentReference(courseID: course, relativePath: path, title: "Annotation", kind: "pdf")
        let model = NativePDFWorkspaceModel(document: document, store: store, defaults: defaults)
        defer { model.close() }
        model.attach(to: controller.view); model.layout(controller.view.bounds)
        try await waitForHost { !model.isLoading || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        try await waitForHost {
            self.inkSurfaces(in: controller.view).contains { $0.mapper != nil && $0.renderViewport != nil }
        }
        let surface = try XCTUnwrap(inkSurfaces(in: controller.view).first { $0.mapper != nil && $0.renderViewport != nil })
        let pdfView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? PDFView }.first)
        let gesture = NativePDFPencilGestureRecognizer()
        controller.view.addGestureRecognizer(gesture); gesture.targetAtLocation = { _ in surface }
        defer { controller.view.removeGestureRecognizer(gesture) }
        func commitStroke(_ index: Int) async throws {
            let touch = AnnotationHostTouch(window: window,
                point: surface.convert(CGPoint(x: surface.bounds.width * 0.35, y: surface.bounds.height * (0.20 + Double(index) * 0.05)), to: window))
            let event = AnnotationHostEvent(touch)
            gesture.touchesBegan([touch], with: event)
            touch.point.x += 70; touch.currentTime += 0.04
            gesture.touchesMoved([touch], with: event)
            touch.currentTime += 0.02
            gesture.touchesEnded([touch], with: event); gesture.reset()
            try await model.flush()
            try await waitForHost { model.drawingCount == index || model.errorMessage != nil }
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.drawingCount, index, "Each real host stroke must reach canonical storage")
        }
        try await commitStroke(1)
        model.chooseTool("highlighter")
        try await waitForHost { surface.tool.name == "highlighter" || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        try await commitStroke(2)

        store.annotation.begin(documentID: document.id, spaceID: "course:" + course)
        try await waitForHost { surface.tool.name == "lasso" || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage, "Entering Annotate must advance the host's object-scene epoch")
        model.setAssistantRegionMode(false)
        try await waitForHost { surface.tool.name == "select" || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage, "Text selection must publish a fresh tool generation")
        model.setAssistantRegionMode(true)
        try await waitForHost { surface.tool.name == "lasso" || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        store.annotation.cancel()
        try await waitForHost { surface.tool.name == "highlighter" || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage, "Cancelling must restore the host tool as well as the toolbar")
        XCTAssertTrue(pdfView.isUserInteractionEnabled)
        try await commitStroke(3)
        XCTAssertEqual(try context.query("SELECT id FROM pdf_drawings").count, 3)
        try await model.flush()
        model.close()
        try await waitForHost { pdfView.superview == nil }
    }
    func testViewCaptureContainsOnlySelectedEditorAndBoundsItsMemory() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 300)); parent.backgroundColor = .red
        let editor = UIView(frame: CGRect(x: 200, y: 0, width: 400, height: 300)); editor.backgroundColor = .blue
        parent.addSubview(editor)
        let capture = NativeAnnotationViewCapture(); capture.view = editor
        let image = try XCTUnwrap(capture.image(normalized: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(image.size, CGSize(width: 200, height: 300))
        let pixel = try centerPixel(image)
        XCTAssertLessThan(pixel[0], 3); XCTAssertGreaterThan(pixel[2], 250)
        XCTAssertNil(capture.image(normalized: .zero))
        editor.frame.size = CGSize(width: 5000, height: 5000)
        let large = try XCTUnwrap(capture.image(normalized: CGRect(x: 0, y: 0, width: 1, height: 1))?.cgImage)
        XCTAssertLessThanOrEqual(large.width * large.height, 4_004_001)
    }
    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = ((image.height / 2) * image.width + image.width / 2) * 4
        return Array(data[index..<index + 4])
    }
    private func inkSurfaces(in view: UIView) -> [NativePDFInkSurface] {
        (view as? NativePDFInkSurface).map { [$0] } ?? view.subviews.flatMap { inkSurfaces(in: $0) }
    }
    private func waitForHost(_ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 10
        while !predicate(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "The real PDF host did not finish the requested transition")
    }
}

@MainActor private final class AnnotationHostTouch: UITouch {
    let fixtureWindow: UIWindow
    var point: CGPoint
    var currentTime = CACurrentMediaTime()
    init(window: UIWindow, point: CGPoint) { fixtureWindow = window; self.point = point; super.init() }
    override var window: UIWindow? { fixtureWindow }
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { currentTime }
    override var force: CGFloat { 0.4 }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimatedProperties: UITouch.Properties { [] }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { [] }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: fixtureWindow) ?? fixtureWindow.convert(point, to: nil) }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
@MainActor private final class AnnotationHostEvent: UIEvent {
    let touch: UITouch
    init(_ touch: UITouch) { self.touch = touch; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [touch] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [self.touch] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
