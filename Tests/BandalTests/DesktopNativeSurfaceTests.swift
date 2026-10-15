import XCTest
import UIKit
import WebKit
import PDFKit
@testable import Bandal

@MainActor
final class DesktopNativeSurfaceTests: XCTestCase {
    func testOldSessionAndOutOfOrderMessagesCannotUncoverModal() throws {
        let state = DesktopNativeSurfaceState()
        let session = state.sessionID
        func update(_ revision: Int, blocked: Bool, sessionID: String? = nil) throws {
            _ = try state.apply(["sessionId": sessionID ?? session, "revision": revision,
                "blocked": blocked, "inputBlocked": false, "overlays": []])
        }
        try update(1, blocked: false)
        try update(3, blocked: true)
        try update(2, blocked: false)
        XCTAssertTrue(state.blocked)
        XCTAssertEqual(state.revision, 3)
        state.reset()
        XCTAssertThrowsError(try update(4, blocked: false))
        XCTAssertTrue(state.blocked)
        try update(1, blocked: false, sessionID: state.sessionID)
        XCTAssertFalse(state.blocked)
        XCTAssertThrowsError(try state.apply(["sessionId": state.sessionID, "revision": 2,
            "blocked": false, "inputBlocked": false, "overlays": [["x": Double.nan, "y": 0, "width": 10, "height": 10]]]))
        XCTAssertEqual(state.revision, 1, "Invalid geometry cannot advance the committed revision")
    }

    func testOverlappingMasksAndHitTestingExcludeTheSameUnion() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let holes = [CGRect(x: 20, y: 30, width: 100, height: 100), CGRect(x: 70, y: 70, width: 100, height: 100)]
        let path = DesktopNativeSurfaceMask.path(bounds: bounds, excluding: holes + [holes[0]])
        let pdf = NativePDFApertureView(frame: bounds)
        let browser = DesktopBrowserWebView(frame: bounds, configuration: WKWebViewConfiguration())
        pdf.excludedRects = holes; browser.excludedRects = holes
        for point in [CGPoint(x: 30, y: 40), CGPoint(x: 90, y: 90), CGPoint(x: 150, y: 150)] {
            XCTAssertFalse(path.contains(point), "Overlapping masks must not paint a native island")
            XCTAssertFalse(pdf.point(inside: point, with: nil))
            XCTAssertFalse(browser.point(inside: point, with: nil))
        }
        XCTAssertTrue(path.contains(CGPoint(x: 230, y: 250)))
        XCTAssertTrue(pdf.point(inside: CGPoint(x: 230, y: 250), with: nil))
        XCTAssertTrue(browser.point(inside: CGPoint(x: 230, y: 250), with: nil))
    }

    func testRepeatedPDFLayoutRetainsMaskUntilItsGeometryChanges() throws {
        let pdf = NativePDFApertureView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let holes = [CGRect(x: 20, y: 30, width: 100, height: 100)]
        pdf.excludedRects = holes
        let original = try XCTUnwrap(pdf.layer.mask as? CAShapeLayer)
        for _ in 0..<100 {
            pdf.excludedRects = holes
            pdf.setNeedsLayout(); pdf.layoutIfNeeded()
            XCTAssertTrue(pdf.layer.mask === original, "Unchanged host geometry must not replace the compositor mask")
            XCTAssertFalse(pdf.point(inside: CGPoint(x: 40, y: 40), with: nil))
        }
        pdf.excludedRects = [CGRect(x: 150, y: 30, width: 100, height: 100)]
        let moved = try XCTUnwrap(pdf.layer.mask as? CAShapeLayer)
        XCTAssertFalse(moved === original)
        XCTAssertTrue(try XCTUnwrap(moved.path).contains(CGPoint(x: 40, y: 40)))
        XCTAssertTrue(pdf.point(inside: CGPoint(x: 40, y: 40), with: nil))
        XCTAssertFalse(pdf.point(inside: CGPoint(x: 180, y: 40), with: nil))
        pdf.bounds.size.height = 500
        pdf.setNeedsLayout(); pdf.layoutIfNeeded()
        let resized = try XCTUnwrap(pdf.layer.mask as? CAShapeLayer)
        XCTAssertFalse(resized === moved)
        XCTAssertTrue(try XCTUnwrap(resized.path).contains(CGPoint(x: 40, y: 450)))
        // Do not mistake a mask replaced by UIKit for our cached mask.
        pdf.layer.mask = CALayer()
        pdf.setNeedsLayout(); pdf.layoutIfNeeded()
        XCTAssertTrue(pdf.layer.mask is CAShapeLayer)
        XCTAssertFalse(pdf.layer.mask === resized)
        pdf.excludedRects = []
        XCTAssertNil(pdf.layer.mask)
        XCTAssertTrue(pdf.point(inside: CGPoint(x: 180, y: 40), with: nil))
    }

    func testSettingsOcclusionRetainsDocumentAndCannotBeUndoneByLateLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-surfaces-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(previousEnabled, forKey: "bandal.nativePDF.enabled") }
        let file = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage(); ("Occlusion fixture" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }.write(to: file)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        let shell = WKWebView(frame: container.bounds); container.addSubview(shell)
        let host = try NativePDFHost(root: root) { channel, request in
            if channel == "nativePDF:binding" { return ["materialID": "fixture", "documentRevision": request["documentRevision"]!] }
            return file.path
        }
        host.attach(to: container, shell: shell)
        defer { host.closeAll() }
        let identity: [String: Any] = ["surfaceId": "pdf", "generation": "one", "courseId": "course", "relPath": "fixture.pdf"]
        func call(_ channel: String, _ body: [String: Any] = [:]) async throws -> Any {
            try await host.handle("pdfNative:" + channel, request: identity.merging(body) { _, new in new })
        }
        _ = try await call("open")
        let rect: [String: Double] = ["x": 40, "y": 60, "width": 600, "height": 700]
        _ = try await call("layout", ["visible": true, "revision": 1, "rect": rect])
        _ = try await call("snapshot", ["loading": false, "drawings": [], "annotations": [], "active": true,
            "tool": ["name": "pen", "style": ["color": "ink", "width": 0.004, "opacity": 0.95]]])
        let body = try XCTUnwrap(container.subviews.compactMap { $0 as? NativePDFApertureView }.first)
        let document = try XCTUnwrap(body.document)
        host.setPresentation(blocked: true, inputBlocked: false, overlays: [])
        XCTAssertTrue(body.isHidden)
        XCTAssertTrue(body.accessibilityElementsHidden)
        XCTAssertFalse(body.isUserInteractionEnabled)
        _ = try await call("layout", ["visible": true, "revision": 3, "rect": rect])
        XCTAssertTrue(body.isHidden, "Late layouts cannot uncover a settings screen")
        _ = try await call("layout", ["visible": false, "revision": 2])
        XCTAssertTrue(body.document === document, "A stale tab suspension must be ignored")
        let state = try await call("diagnostics") as? [String: Any]
        XCTAssertEqual(state?["suspended"] as? Bool, false)
        host.setPresentation(blocked: false, inputBlocked: false, overlays: [CGRect(x: 60, y: 80, width: 100, height: 60)])
        XCTAssertFalse(body.isHidden)
        XCTAssertTrue(body.document === document, "Temporary settings must not reload the PDF")
        XCTAssertFalse(body.point(inside: CGPoint(x: 30, y: 30), with: nil), "Global CSS overlay coordinates map into the PDF viewport")
        host.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        XCTAssertFalse(body.isUserInteractionEnabled)
        XCTAssertFalse(body.isHidden, "Moving a palette keeps the paper on screen")
        host.setPresentation(blocked: false, inputBlocked: false, overlays: [])
        _ = try await call("layout", ["visible": true, "occluded": true, "revision": 4, "rect": rect])
        XCTAssertTrue(body.isHidden)
        XCTAssertTrue(body.document === document, "Local dialogs also use temporary occlusion")
        _ = try await call("layout", ["visible": true, "occluded": false, "revision": 5, "rect": rect])
        XCTAssertFalse(body.isHidden)
        for index in 0..<100 {
            host.setPresentation(blocked: true, inputBlocked: false, overlays: [])
            _ = try await call("layout", ["visible": true, "revision": index + 6, "rect": rect])
            XCTAssertTrue(body.isHidden)
            host.setPresentation(blocked: false, inputBlocked: false, overlays: [])
            XCTAssertTrue(body.document === document)
            XCTAssertEqual(container.subviews.compactMap { $0 as? NativePDFApertureView }.count, 1)
        }
        _ = try await call("layout", ["visible": false, "revision": 106])
        XCTAssertNil(body.document, "Real tab suspension still releases PDF page resources")
        _ = try await call("layout", ["visible": true, "revision": 107, "rect": rect])
        XCTAssertFalse(body.isHidden)
        host.closeAll()
        host.setPresentation(blocked: false, inputBlocked: false, overlays: [])
        XCTAssertNil(body.superview, "Unblocking a fresh renderer cannot reveal the retired paper")
        do {
            _ = try await call("layout", ["visible": true, "revision": 108, "rect": rect])
            XCTFail("A retired renderer cannot reclaim its old native surface")
        } catch { /* The old ownership is invalid even after the new session unblocks. */ }
    }

    func testClosingRendererInvalidatesPendingOpenBeforeItCreatesSurface() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-surface-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
        UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
        defer { UserDefaults.standard.set(previous, forKey: "bandal.nativePDF.enabled") }
        let file = root.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 200)).pdfData { $0.beginPage() }.write(to: file)
        var continuation: CheckedContinuation<String, Never>?
        let host = try NativePDFHost(root: root) { channel, _ in
            XCTAssertEqual(channel, "nativeMaterial:path", "Canceled opening must stop before reading the canonical binding")
            return await withCheckedContinuation { continuation = $0 }
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        let shell = WKWebView(frame: container.bounds); container.addSubview(shell)
        host.attach(to: container, shell: shell)
        let pending = Task { try await host.handle("pdfNative:open", request: ["surfaceId": "pending", "generation": "old", "courseId": "course", "relPath": "fixture.pdf"]) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let response = try XCTUnwrap(continuation)
        host.closeAll()
        response.resume(returning: file.path)
        do { _ = try await pending.value; XCTFail("The old renderer's pending open must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(container.subviews.compactMap { $0 as? NativePDFApertureView }.isEmpty)
    }
}
