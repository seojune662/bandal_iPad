import XCTest
import PDFKit
import WebKit
@testable import Bandal

@MainActor
final class NativePDFHostTests: XCTestCase {
    func testDevelopmentComparisonTogglePersistsWithoutReplacingOpenDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-setting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        UserDefaults.standard.set(false, forKey: "bandal.nativePDF.enabled")
        let host = try NativePDFHost(root: root) { _, _ in XCTFail("A setting must not read or replace a PDF"); return NSNull() }
        let before = try await host.handle("pdfNative:capabilities", request: [:]) as? [String: Any]
        XCTAssertEqual(before?["enabled"] as? Bool, false)
        XCTAssertEqual(before?["development"] as? Bool, true)
        let changed = try await host.handle("pdfNative:setEnabled", request: ["enabled": true]) as? [String: Any]
        XCTAssertEqual(changed?["enabled"] as? Bool, true)
        let reopened = try NativePDFHost(root: root) { _, _ in XCTFail("A setting must not open a PDF"); return NSNull() }
        let after = try await reopened.handle("pdfNative:capabilities", request: [:]) as? [String: Any]
        XCTAssertEqual(after?["enabled"] as? Bool, true)
        do { _ = try await reopened.handle("pdfNative:setEnabled", request: ["enabled": "yes"]); XCTFail("Reject malformed setting values") } catch {}
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "bandal.nativePDF.enabled"))
    }
    func testNativeCompletionIsJournaledBeforeEventAndReplayedAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-host-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(old, forKey: "bandal.nativePDF.enabled") }
        let url = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage(); ("Native PDF fixture" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }.write(to: url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
        func host() throws -> NativePDFHost {
            let value = try NativePDFHost(root: root) { channel, request in
                XCTAssertEqual(request["relPath"] as? String, "fixture.pdf")
                if channel == "nativePDF:binding" {
                    return ["materialID": "fixture-material", "documentRevision": request["documentRevision"]!, "evidence": "first-observed", "legacyUnverified": false]
                }
                XCTAssertEqual(channel, "nativeMaterial:path")
                return url.path
            }
            value.attach(to: controller.view, shell: shell); return value
        }
        let first = try host(), identity: [String: Any] = ["surfaceId": "test", "generation": "one", "courseId": "course", "relPath": "fixture.pdf"]
        defer { first.closeAll() }
        let opened = try await first.handle("pdfNative:open", request: identity) as? [String: Any]
        XCTAssertEqual(opened?["numPages"] as? Int, 1)
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        _ = try await first.handle("pdfNative:snapshot", request: identity.merging(["loading": false, "drawings": [], "annotations": [], "tool": ["name": "pen", "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]]) { _, new in new })
        func surfaces(_ view: UIView) -> [NativePDFInkSurface] { (view as? NativePDFInkSurface).map { [$0] } ?? view.subviews.flatMap(surfaces) }
        let deadline = Date().addingTimeInterval(10)
        while surfaces(controller.view).isEmpty && Date() < deadline {
            controller.view.layoutIfNeeded(); first.layout(); try await Task.sleep(for: .milliseconds(30))
        }
        let surface = try XCTUnwrap(surfaces(controller.view).first)
        var completed: [String: Any]?
        first.emit = { channel, body in
            guard channel == "pdfNative:event", let event = body as? [String: Any], event["type"] as? String == "stroke" else { return }
            completed = event["payload"] as? [String: Any]
            XCTAssertEqual(try? NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").count, 1, "Journal must precede completion delivery")
        }
        try surface.onStroke?(.init(mutationID: UUID().uuidString.lowercased(), kind: "ink", points: [.init(x: 0.2, y: 0.3, p: 0, t: 0), .init(x: 0.2, y: 0.3, p: 1, t: 12)], style: .init(color: "blue", width: 0.004, opacity: 1)))
        let completedID = try XCTUnwrap(completed?["clientMutationId"] as? String)
        XCTAssertEqual(completed?["documentRevision"] as? String, opened?["revision"] as? String)
        _ = try await first.handle("pdfNative:navigate", request: identity.merging(["page": 1, "zoom": 1.6, "progress": 0.45]) { _, new in new })
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": false]) { _, new in new })
        let sleeping = try await first.handle("pdfNative:diagnostics", request: identity) as? [String: Any]
        XCTAssertEqual(sleeping?["suspended"] as? Bool, true)
        XCTAssertEqual(sleeping?["retainedPages"] as? Int, 0, "Inactive tab must release page/Metal surfaces")
        XCTAssertEqual(try NativePDFJournal(root: root).pending(courseID: "course", relativePath: "fixture.pdf").count, 1)
        _ = try await first.handle("pdfNative:layout", request: identity.merging(["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]]) { _, new in new })
        let awake = try await first.handle("pdfNative:diagnostics", request: identity) as? [String: Any]
        XCTAssertEqual(awake?["suspended"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(awake?["zoom"] as? Double), 1.6, accuracy: 0.01, "Restoration must retain the original viewport")
        first.closeAll()
        let reopened = try host(); defer { reopened.closeAll() }
        var next = identity; next["generation"] = "two"
        let state = try await reopened.handle("pdfNative:open", request: next) as? [String: Any]
        let pending = try XCTUnwrap(state?["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?["clientMutationId"] as? String, completedID)
        let measured = (pending.first?["data"] as? [String: Any])?["points"] as? [[String: Any]]
        XCTAssertEqual(measured?.count, 2); XCTAssertEqual(measured?.first?["p"] as? Double, 0)
        _ = try await reopened.handle("pdfNative:ack", request: next.merging(["clientMutationId": completedID, "drawingId": "durable-backend-id"]) { _, new in new })
        let drained = try await reopened.handle("pdfNative:flush", request: next) as? [String: Any]
        XCTAssertEqual((drained?["pending"] as? [Any])?.count, 0)
        do { _ = try await reopened.handle("pdfNative:snapshot", request: identity); XCTFail("Old generation must not update a replacement PDF surface") } catch {}
    }
}
