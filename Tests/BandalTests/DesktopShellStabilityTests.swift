import XCTest
import UIKit
import WebKit
import PDFKit
@testable import Bandal

@MainActor
final class DesktopShellStabilityTests: XCTestCase {
    func testRetiredPDFFailedCheckpointStillBlocksRecoveryUntilDurableRetry() async throws {
        try await checkFailedPDFCheckpointRecovery(retiringRenderer: true)
    }

    func testFailedExplicitPDFCloseRetainsGenerationForOriginalWriterRetry() async throws {
        try await checkFailedPDFCheckpointRecovery(retiringRenderer: false)
    }

    func testRecoveryAttemptsEveryFailedPDFDocumentBeforeThrowing() async throws {
        try await checkFailedPDFCheckpointRecovery(retiringRenderer: true, secondDocument: true)
    }

    private func checkFailedPDFCheckpointRecovery(retiringRenderer: Bool, secondDocument: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retired-pdf-save-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(previousEnabled, forKey: "bandal.nativePDF.enabled") }
        let file = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }.write(to: file)
        if secondDocument { try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("second.pdf")) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" { return try NativePDFTestBinding.respond(root: root, file: file, materialID: "fixture") }
            return root.appendingPathComponent(request["relPath"] as? String ?? "fixture.pdf").path
        }
        host.attach(to: controller.view, shell: shell)
        var storageUnavailable = true
        defer { storageUnavailable = false; host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "retiring", "generation": "old", "courseId": "course", "relPath": "fixture.pdf"]
        _ = try await host.handle("pdfNative:open", request: identity)
        _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": true, "revision": 1,
            "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        _ = try await host.handle("pdfNative:snapshot", request: identity.merging(["loading": false, "active": true,
            "drawings": [], "annotations": [], "tool": ["name": "pen", "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]]) { _, new in new })
        func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) } }
        let deadline = Date().addingTimeInterval(10)
        while find(NativePDFInkSurface.self, in: controller.view).first?.mapper == nil, Date() < deadline {
            controller.view.layoutIfNeeded(); host.layout(); try await Task.sleep(for: .milliseconds(30))
        }
        let surface = try XCTUnwrap(find(NativePDFInkSurface.self, in: controller.view).first)
        XCTAssertNotNil(surface.mapper)
        let body = try XCTUnwrap(find(NativePDFApertureView.self, in: controller.view).first)
        let document = try XCTUnwrap(body.document)
        var secondSurface: NativePDFInkSurface?
        if secondDocument {
            let secondIdentity = identity.merging(["surfaceId": "second", "generation": "second", "relPath": "second.pdf"]) { _, new in new }
            _ = try await host.handle("pdfNative:open", request: secondIdentity)
            _ = try await host.handle("pdfNative:layout", request: secondIdentity.merging(["visible": true, "revision": 1,
                "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
            _ = try await host.handle("pdfNative:snapshot", request: secondIdentity.merging(["loading": false, "active": true,
                "drawings": [], "annotations": [], "tool": ["name": "pen", "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]]) { _, new in new })
            let secondBody = try XCTUnwrap(find(NativePDFApertureView.self, in: controller.view).first { $0 !== body })
            let deadline = Date().addingTimeInterval(10)
            while find(NativePDFInkSurface.self, in: secondBody).first?.mapper == nil, Date() < deadline {
                controller.view.layoutIfNeeded(); host.layout(); try await Task.sleep(for: .milliseconds(30))
            }
            secondSurface = try XCTUnwrap(find(NativePDFInkSurface.self, in: secondBody).first)
            XCTAssertNotNil(secondSurface?.mapper)
        }
        let checkpoint = try XCTUnwrap(surface.onCheckpoint), complete = try XCTUnwrap(surface.onStroke)
        var checkpoints: [NativePDFCompletedStroke] = [], retries: [NativePDFCompletedStroke] = []
        var secondCheckpoints: [NativePDFCompletedStroke] = [], secondRetries: [NativePDFCompletedStroke] = []
        surface.onCheckpoint = { stroke in
            checkpoints.append(stroke)
            if storageUnavailable { throw CocoaError(.fileWriteOutOfSpace) }
            try checkpoint(stroke)
        }
        surface.onStroke = { stroke in
            retries.append(stroke)
            if storageUnavailable { throw CocoaError(.fileWriteOutOfSpace) }
            try complete(stroke)
        }
        if let secondSurface {
            let secondCheckpoint = try XCTUnwrap(secondSurface.onCheckpoint), secondComplete = try XCTUnwrap(secondSurface.onStroke)
            secondSurface.onCheckpoint = { stroke in
                secondCheckpoints.append(stroke)
                if storageUnavailable { throw CocoaError(.fileWriteOutOfSpace) }
                try secondCheckpoint(stroke)
            }
            secondSurface.onStroke = { stroke in
                secondRetries.append(stroke)
                if storageUnavailable { throw CocoaError(.fileWriteOutOfSpace) }
                try secondComplete(stroke)
            }
        }
        // This drives actual measured-input/checkpoint code. It does not
        // synthesize hardware Pencil dispatch or the system Scribble service.
        let point = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        let touch = RetiredPDFEstimatedTouch(point: point)
        XCTAssertTrue(surface.beginPencilGesture(touch, with: nil))
        touch.currentPhase = .ended
        surface.endPencilGesture(touch, with: nil)
        if let secondSurface {
            let point = secondSurface.convert(CGPoint(x: secondSurface.bounds.midX, y: secondSurface.bounds.midY), to: nil)
            let touch = RetiredPDFEstimatedTouch(point: point)
            XCTAssertTrue(secondSurface.beginPencilGesture(touch, with: nil)); touch.currentPhase = .ended
            secondSurface.endPencilGesture(touch, with: nil)
            XCTAssertEqual(secondCheckpoints.count, 1)
        }
        XCTAssertEqual(checkpoints.count, 1)
        let measured = try XCTUnwrap(checkpoints.first)
        XCTAssertFalse(measured.points.isEmpty)
        XCTAssertTrue(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").isEmpty)
        func checkStorageFailure(_ error: Error) {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        if retiringRenderer { host.closeAll() }
        else {
            do { _ = try await host.handle("pdfNative:close", request: identity); XCTFail("Failed explicit close must reject") }
            catch { checkStorageFailure(error) }
        }
        XCTAssertTrue(body.superview === controller.view, "A failed close retains its original measured input owner")
        XCTAssertTrue(body.document === document)
        if retiringRenderer {
            XCTAssertTrue(body.isHidden); XCTAssertTrue(body.accessibilityElementsHidden); XCTAssertFalse(body.isUserInteractionEnabled)
            host.setPresentation(blocked: false, inputBlocked: false, overlays: [])
            XCTAssertTrue(body.isHidden, "The next renderer cannot reveal a retired failed document")
        }
        for _ in 0..<3 {
            let firstBefore = retries.count, secondBefore = secondRetries.count
            if retiringRenderer { XCTAssertThrowsError(try host.flushForRecovery(), "Retired checkpoints stay in the save barrier") { checkStorageFailure($0) } }
            else {
                do { _ = try await host.handle("pdfNative:flush", request: identity); XCTFail("The original writer must still reach the failed storage callback") }
                catch { checkStorageFailure(error) }
            }
            if secondDocument {
                XCTAssertEqual(retries.count, firstBefore + 1)
                XCTAssertEqual(secondRetries.count, secondBefore + 1, "An earlier document failure cannot skip another owner's checkpoint")
            }
        }
        XCTAssertGreaterThanOrEqual(retries.count, 4)
        XCTAssertTrue(retries.allSatisfy { $0 == measured }, "Every failed close/recovery retries the same mutation and measured payload")
        if retiringRenderer {
            do {
                _ = try await host.handle("pdfNative:layout", request: identity.merging(["visible": true, "revision": 2]) { _, new in new })
                XCTFail("A retired renderer cannot restore its failed document's layout")
            } catch {}
        }
        storageUnavailable = false
        if retiringRenderer { XCTAssertNoThrow(try host.flushForRecovery()) }
        else { _ = try await host.handle("pdfNative:flush", request: identity) }
        let durable = try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf")
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(durable.first?.input.clientMutationId, measured.mutationID)
        XCTAssertEqual(durable.first?.input.data.points, measured.points)
        if secondDocument {
            let secondMeasured = try XCTUnwrap(secondCheckpoints.first)
            XCTAssertTrue(secondRetries.allSatisfy { $0 == secondMeasured })
            let secondDurable = try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "second.pdf")
            XCTAssertEqual(secondDurable.count, 1)
            XCTAssertEqual(secondDurable.first?.input.clientMutationId, secondMeasured.mutationID)
            XCTAssertEqual(secondDurable.first?.input.data.points, secondMeasured.points)
        }
        let countAfterSave = retries.count
        if retiringRenderer { XCTAssertNoThrow(try host.flushForRecovery()) }
        else { _ = try await host.handle("pdfNative:flush", request: identity) }
        XCTAssertEqual(retries.count, countAfterSave, "A durable retry cannot duplicate the completion")
        if retiringRenderer { host.closeAll() }
        else { _ = try await host.handle("pdfNative:close", request: identity) }
        XCTAssertNil(body.superview); XCTAssertNil(body.document)
    }

    func testExplicitPDFCloseInvalidatesPendingOpenBeforeSurfaceCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-pdf-open-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(previousEnabled, forKey: "bandal.nativePDF.enabled") }
        let file = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }.write(to: file)
        var continuation: CheckedContinuation<String, Never>?
        let host = try NativePDFHost(root: root) { channel, _ in
            XCTAssertEqual(channel, "nativePDF:binding", "A canceled open must not proceed to canonical binding")
            return await withCheckedContinuation { continuation = $0 }
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 900, height: 700)), shell = WKWebView()
        host.attach(to: container, shell: shell)
        defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "opening", "generation": "one", "courseId": "course", "relPath": "fixture.pdf"]
        let pending = Task { try await host.handle("pdfNative:open", request: identity) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let response = try XCTUnwrap(continuation)
        _ = try await host.handle("pdfNative:close", request: identity)
        response.resume(returning: file.path)
        do { _ = try await pending.value; XCTFail("An explicit close must cancel a pending open") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(container.subviews.contains { $0 is NativePDFApertureView })
    }

    func testNativeBrowserDetachRetainsUnsavedFormAndReattachesWithoutShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-browser-detach-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        controller.loadViewIfNeeded()
        let host = DesktopBrowserHost(root: root)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let page = try host.createPage(tabID: "fixture", profileID: "default", isPrivate: false, courseID: "course", configuration: configuration)
        defer { host.destroy("fixture") }
        host.attachNative(to: controller.view, selectedTabID: page.tabID)
        let website = page.webView
        website.loadHTMLString("<!doctype html><title>Native form fixture</title><input id='draft' value='initial'>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while (website.title != "Native form fixture" || website.isLoading), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(website.title, "Native form fixture")
        _ = try await website.evaluateJavaScript("document.getElementById('draft').value = 'unsaved fixture draft'")
        host.detachNative(from: controller.view)
        XCTAssertNil(host.shell)
        XCTAssertTrue(page.liveWebView === website)
        XCTAssertNil(page.bounds)
        XCTAssertTrue(website.isHidden)
        XCTAssertEqual(page.courseID, "course")
        host.attachNative(to: controller.view, selectedTabID: page.tabID)
        XCTAssertFalse(website.isHidden)
        XCTAssertFalse(website.accessibilityElementsHidden)
        let restoredDraft = try await website.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(restoredDraft, "unsaved fixture draft")
        XCTAssertEqual(website.frame, controller.view.bounds)
    }

    func testDialogCompletionSettlesOnlyOnce() {
        var answers: [Bool] = []
        let confirm = DesktopDialogCompletion<Bool> { answers.append($0) }
        confirm.finish(true); confirm.finish(false); confirm.finish(true)
        XCTAssertEqual(answers, [true])
        var promptAnswers: [String?] = []
        let prompt = DesktopDialogCompletion<String?> { promptAnswers.append($0) }
        prompt.finish(nil); prompt.finish("late answer")
        XCTAssertEqual(promptAnswers.count, 1)
        XCTAssertNil(promptAnswers[0])
    }

    func testNativeMaterialSnapshotRetainsBytesWithoutJavaScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("한글 fixture.bin")
        let bytes = Data((0..<(1024 * 1024 + 7)).map { UInt8($0 % 251) })
        try bytes.write(to: input)
        let snapshot = try await DesktopMaterialExport.snapshot(path: input.path, root: root)
        XCTAssertNotEqual(snapshot, input)
        XCTAssertEqual(try Data(contentsOf: snapshot), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
}

@MainActor
private final class RetiredPDFEstimatedTouch: UITouch {
    let point: CGPoint
    var currentPhase: UITouch.Phase = .began
    init(point: CGPoint) { self.point = point; super.init() }
    override var type: UITouch.TouchType { .pencil }
    override var phase: UITouch.Phase { currentPhase }
    override var timestamp: TimeInterval { 100 }
    override var force: CGFloat { 0.5 }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override var estimationUpdateIndex: NSNumber? { 1 }
    override var estimatedProperties: UITouch.Properties { [.force] }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { [.force] }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: nil) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
