import XCTest
import UIKit
import WebKit
import PDFKit
@testable import Bandal

@MainActor
final class DesktopShellStabilityTests: XCTestCase {
    func testDocumentBarrierAttemptsBothWritersOnceAndPreservesFirstFailure() async throws {
        let nativeFailure = NSError(domain: "NativeCheckpointFailure", code: 1)
        let rendererFailure = NSError(domain: "RendererSaveFailure", code: 2)
        for (nativeFails, rendererFails) in [(true, false), (true, true), (false, true), (false, false)] {
            var attempts: [String] = [], caught: Error?
            do {
                try await DesktopShellController.flushDocumentWriters(native: {
                    attempts.append("native")
                    if nativeFails { throw nativeFailure }
                }, renderer: {
                    attempts.append("renderer")
                    await Task.yield()
                    if rendererFails { throw rendererFailure }
                })
            } catch { caught = error }
            XCTAssertEqual(attempts, ["native", "renderer"], "A failed phase must neither skip nor repeat the other original writer")
            if nativeFails {
                XCTAssertTrue((try XCTUnwrap(caught) as NSError) === nativeFailure, "A later renderer failure cannot replace the native checkpoint failure")
            } else if rendererFails {
                XCTAssertTrue((try XCTUnwrap(caught) as NSError) === rendererFailure)
            } else { XCTAssertNil(caught, "Only two successful phases complete the save barrier") }
        }
    }

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
            if channel == "nativePDF:binding" { return ["materialID": "fixture", "documentRevision": request["documentRevision"]!] }
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
            XCTAssertEqual(channel, "nativeMaterial:path", "A canceled open must not proceed to canonical binding")
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

    func testBrowserRendererRetirementPreservesDocumentWithoutOldBoundsOrOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-retire-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ShellDialogFixture()
        defer { fixture.close() }
        try await fixture.load()
        let container = try XCTUnwrap(fixture.presenter.view), shell = fixture.webView
        let host = DesktopBrowserHost(root: root); host.attach(to: container, shell: shell)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let page = try host.createPage(tabID: "fixture", profileID: "default", isPrivate: false, courseID: "old-course", configuration: configuration)
        defer { host.destroy("fixture") }
        let website = page.webView
        page.bounds = CGRect(x: 0, y: 40, width: 700, height: 600)
        page.layoutRevision = 20; page.ownershipRevision = 30
        host.layoutPages()
        XCTAssertFalse(website.isHidden)
        let navigation = ShellDialogNavigation()
        website.navigationDelegate = navigation
        website.loadHTMLString("<!doctype html><title>Retirement fixture</title><input id='draft' value='initial'>", baseURL: nil)
        try await fixture.wait { navigation.finished || navigation.error != nil }
        if let error = navigation.error { throw error }
        website.navigationDelegate = page
        _ = try await website.evaluateJavaScript("document.getElementById('draft').value = 'unsaved fixture draft'")
        host.retireRenderer()
        XCTAssertTrue(page.liveWebView === website, "Retiring chrome must preserve the website and unsaved forms")
        XCTAssertNil(page.bounds); XCTAssertNil(page.courseID)
        XCTAssertEqual(page.layoutRevision, 21, "Pending bounds/preview replies must be invalidated")
        XCTAssertEqual(page.ownershipRevision, 31, "Host ownership must remain monotonic across renderer reloads")
        XCTAssertTrue(website.isHidden); XCTAssertTrue(website.accessibilityElementsHidden)
        host.setPresentation(blocked: false, inputBlocked: false, overlays: [])
        XCTAssertTrue(website.isHidden, "New renderer bootstrap cannot reveal old rectangles")
        let assigned = try await host.handle(channel: "browser:setCourse", request: ["tabId": "fixture", "courseId": "new-course", "expectedWebContentsId": page.id, "revision": 1]) as? [String: Bool]
        XCTAssertEqual(assigned?["ok"], true)
        XCTAssertEqual(page.courseID, "new-course")
        XCTAssertEqual(page.ownershipRevision, 32)
        let late = try await host.handle(channel: "browser:setCourse", request: ["tabId": "fixture", "courseId": "stale", "expectedWebContentsId": page.id, "revision": 1]) as? [String: Bool]
        XCTAssertEqual(late?["ok"], false)
        XCTAssertEqual(page.courseID, "new-course")
        _ = try await host.handle(channel: "browser:pageBounds", request: ["tabId": "fixture", "bounds": ["x": 20.0, "y": 50.0, "width": 600.0, "height": 500.0]])
        XCTAssertFalse(website.isHidden)
        XCTAssertTrue(page.liveWebView === website)
        let draft = try await website.evaluateJavaScript("document.getElementById('draft').value")
        XCTAssertEqual(draft as? String, "unsaved fixture draft", "Fresh shell geometry must not reload or replace the external website")
    }

    func testRealWKShellDialogsApproveCancelAndReturnPromptText() async throws {
        let fixture = try ShellDialogFixture()
        defer { fixture.close() }
        try await fixture.load()
        let accepted = try await fixture.evaluate("JSON.stringify(confirm('fixture confirm'))", response: .accepted) { alert in
            XCTAssertEqual(alert.message, "fixture confirm")
            XCTAssertEqual(alert.actions.map(\.title), ["취소", "확인"])
        }
        XCTAssertEqual(accepted, "true")
        let cancelled = try await fixture.evaluate("JSON.stringify(confirm('fixture cancel'))", response: .cancelled)
        XCTAssertEqual(cancelled, "false")
        let prompt = try await fixture.evaluate("JSON.stringify(prompt('fixture prompt', 'original'))", response: .text("edited 한글")) { alert in
            XCTAssertEqual(alert.textFields?.first?.text, "original")
        }
        XCTAssertEqual(prompt, "\"edited 한글\"")
        let empty = try await fixture.evaluate("JSON.stringify(prompt('empty prompt', 'original'))", response: .text(""))
        XCTAssertEqual(empty, "\"\"")
        let noPrompt = try await fixture.evaluate("JSON.stringify(prompt('cancel prompt'))", response: .cancelled)
        XCTAssertEqual(noPrompt, "null")
        let alert = try await fixture.evaluate("alert('fixture alert'); 'continued'", response: .accepted)
        XCTAssertEqual(alert, "continued")
    }

    func testRealWKDialogTeardownAndLateReplyCannotAnswerNextDialog() async throws {
        let fixture = try ShellDialogFixture()
        defer { fixture.close() }
        try await fixture.load()
        var first: Result<String?, Error>?, firstCount = 0
        fixture.webView.evaluateJavaScript("JSON.stringify(confirm('retiring document'))") { value, error in
            firstCount += 1; first = error.map { .failure($0) } ?? .success(value as? String)
        }
        try await fixture.wait { fixture.dialogs.activeDialogIdentifier != nil }
        let retired = try XCTUnwrap(fixture.dialogs.activeDialogIdentifier)
        fixture.dialogs.cancelAll(); fixture.dialogs.cancelAll()
        try await fixture.wait { first != nil && fixture.presenter.presentedViewController == nil }
        XCTAssertEqual(try first?.get(), "false"); XCTAssertEqual(firstCount, 1)

        var next: Result<String?, Error>?, nextCount = 0
        fixture.webView.evaluateJavaScript("JSON.stringify(confirm('new document'))") { value, error in
            nextCount += 1; next = error.map { .failure($0) } ?? .success(value as? String)
        }
        try await fixture.wait { fixture.dialogs.activeDialogIdentifier != nil }
        let current = try XCTUnwrap(fixture.dialogs.activeDialogIdentifier)
        XCTAssertNotEqual(current, retired)
        fixture.dialogs.resolveDialog(retired, response: .accepted)
        XCTAssertEqual(fixture.dialogs.activeDialogIdentifier, current); XCTAssertEqual(nextCount, 0)
        fixture.dialogs.resolveDialog(current, response: .accepted)
        try await fixture.wait { next != nil && fixture.presenter.presentedViewController == nil }
        XCTAssertEqual(try next?.get(), "true"); XCTAssertEqual(nextCount, 1)
        let tornPrompt = try await fixture.evaluate("JSON.stringify(prompt('teardown prompt'))", response: nil)
        XCTAssertEqual(tornPrompt, "null")
        let tornAlert = try await fixture.evaluate("alert('teardown alert'); 'continued'", response: nil)
        XCTAssertEqual(tornAlert, "continued")
    }

    func testRealWKForeignOriginCannotPresentShellDialog() async throws {
        let fixture = try ShellDialogFixture()
        defer { fixture.close() }
        try await fixture.load(host: "foreign")
        let result = try await fixture.webView.evaluateJavaScript("JSON.stringify(confirm('foreign frame'))")
        XCTAssertEqual(result as? String, "false")
        XCTAssertNil(fixture.dialogs.activeDialogIdentifier)
        XCTAssertNil(fixture.presenter.presentedViewController)
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

    func testUnsupportedMethodIsExplicitAndOperationErrorsStayFailures() {
        let capabilities = DesktopBridgeContract.capabilities(backendChannels: ["notes:write", "plugins:approve"])
        let channels = capabilities["channels"] as? [String] ?? []
        XCTAssertTrue(channels.contains("notes:write"))
        XCTAssertTrue(channels.contains("materials:share"))
        XCTAssertTrue(channels.contains("pdfNative:open"))
        XCTAssertTrue(channels.contains("runtime:nativeSurfaces"))
        XCTAssertFalse(channels.contains("materials:startDrag"))
        XCTAssertFalse(channels.contains("plugins:approve"))
        let methods = capabilities["methods"] as? [String: [String: String]]
        XCTAssertEqual(methods?["startMaterialDrag"]?["state"], "unsupported")
        let readiness = capabilities["readiness"] as? [String: [String: Any]]
        XCTAssertEqual(readiness?["ai"]?["channel"] as? String, "agent:availability")
        XCTAssertEqual(readiness?["account"]?["channel"] as? String, "auth:getState")
        XCTAssertEqual(readiness?["appleCalendar"]?["scope"] as? String, "configuration")
        let error = DesktopBridgeContract.failure(DesktopRuntimeError("disk full", code: "SQLITE_FULL"), channel: "notes:write", requestID: "fixture")
        let failure = error["__bandalError"] as? [String: Any]
        XCTAssertEqual(failure?["code"] as? String, "SQLITE_FULL")
        XCTAssertEqual(failure?["channel"] as? String, "notes:write")
        XCTAssertEqual(failure?["requestId"] as? String, "fixture")
        XCTAssertEqual(failure?["retryable"] as? Bool, false)
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

@MainActor
private final class ShellDialogFixture {
    let dialogs = DesktopShellDialogs()
    let presenter = UIViewController()
    let webView: WKWebView
    private let window: UIWindow
    private weak var previousWindow: UIWindow?
    private let scheme = ShellDialogScheme()
    private let navigation = ShellDialogNavigation()

    init() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("A test-host window scene is required for actual WK dialog presentation") }
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "bandal-app")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        window.rootViewController = presenter
        presenter.loadViewIfNeeded(); presenter.view.addSubview(webView)
        dialogs.presenter = presenter; dialogs.webView = webView
        webView.uiDelegate = dialogs; webView.navigationDelegate = navigation
        window.makeKeyAndVisible()
    }
    func close() {
        dialogs.cancelAll(); webView.stopLoading()
        webView.uiDelegate = nil; webView.navigationDelegate = nil
        window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
    func load(host: String = "shell") async throws {
        navigation.finished = false; navigation.error = nil
        webView.load(URLRequest(url: URL(string: "bandal-app://\(host)/index.html")!))
        try await wait { navigation.finished || navigation.error != nil }
        if let error = navigation.error { throw error }
        try await wait { UIApplication.shared.applicationState == .active }
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw NSError(domain: "ShellDialogFixtureTimeout", code: 1) }
    }
    func evaluate(_ script: String, response: DesktopShellDialogs.Response?, inspect: (UIAlertController) -> Void = { _ in }) async throws -> String? {
        var result: Result<String?, Error>?, count = 0
        webView.evaluateJavaScript(script) { value, error in
            count += 1; result = error.map { .failure($0) } ?? .success(value as? String)
        }
        try await wait { dialogs.activeDialogIdentifier != nil }
        try await wait { presenter.presentedViewController?.isBeingPresented == false }
        let identifier = try XCTUnwrap(dialogs.activeDialogIdentifier)
        inspect(try XCTUnwrap(presenter.presentedViewController as? UIAlertController))
        if let response {
            dialogs.resolveDialog(identifier, response: response)
            dialogs.resolveDialog(identifier, response: .cancelled)
        } else { dialogs.cancelAll(); dialogs.cancelAll() }
        try await wait { result != nil && presenter.presentedViewController == nil }
        XCTAssertEqual(count, 1, "The actual WK evaluation must complete exactly once")
        return try XCTUnwrap(result).get()
    }
}

@MainActor
private final class ShellDialogScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let data = Data("<!doctype html><meta name='viewport' content='width=device-width'><title>Isolated shell dialog fixture</title><body>Fixture only</body>".utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
private final class ShellDialogNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error }
}
