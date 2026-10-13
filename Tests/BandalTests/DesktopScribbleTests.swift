import XCTest
import WebKit
@testable import Bandal

@MainActor
final class DesktopScribbleTests: XCTestCase {
    func testPolicyAttachesToRealWebKitTextInputAndConvertsDescendantCoordinates() async throws {
        let shell = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let policy = DesktopScribblePolicy()
        policy.attach(to: shell)
        let loaded = expectation(description: "WebKit text input fixture loaded")
        let delegate = ScribbleNavigationDelegate { loaded.fulfill() }
        shell.navigationDelegate = delegate
        shell.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><input aria-label='Search'><div contenteditable='true'>Explicit text</div>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        var pending: [UIView] = [shell], inputViews: [UIView] = []
        while let node = pending.popLast() {
            if node is UITextInput { inputViews.append(node) }
            pending.append(contentsOf: node.subviews)
        }
        XCTAssertFalse(inputViews.isEmpty, "Exercise WebKit's real UITextInput content view, not just a pure geometry function")
        let originalInteractions = inputViews.flatMap(\.interactions).filter { !($0 is UIScribbleInteraction) }
        try policy.update(["revision": 1, "viewport": ["width": 1024.0, "height": 768.0],
            "protected": [["x": 200.0, "y": 100.0, "width": 600.0, "height": 500.0]],
            "editors": [["x": 250.0, "y": 150.0, "width": 300.0, "height": 100.0]],
            "controls": [["x": 270.0, "y": 160.0, "width": 44.0, "height": 44.0]]])
        for input in inputViews {
            XCTAssertEqual(input.interactions.compactMap { $0 as? UIScribbleInteraction }.filter { $0.delegate === policy }.count, 1)
        }
        for original in originalInteractions {
            XCTAssertTrue(original.view?.interactions.contains(where: { $0 === original }) == true, "Do not remove or replace WebKit's own interactions")
        }
        // A newly installed text input has nonzero local origin. Its callback
        // location must be converted before testing the published DOM regions.
        let lateInput = UITextField(frame: CGRect(x: 200, y: 100, width: 400, height: 200))
        shell.addSubview(lateInput)
        policy.refreshAttachments(); policy.refreshAttachments()
        let localInteraction = try XCTUnwrap(lateInput.interactions.compactMap { $0 as? UIScribbleInteraction }.first { $0.delegate === policy })
        XCTAssertEqual(lateInput.interactions.compactMap { $0 as? UIScribbleInteraction }.filter { $0.delegate === policy }.count, 1)
        XCTAssertFalse(policy.scribbleInteraction(localInteraction, shouldBeginAt: CGPoint(x: 25, y: 20)), "A local point near the origin is inside the document in shell coordinates")
        XCTAssertTrue(policy.scribbleInteraction(localInteraction, shouldBeginAt: CGPoint(x: 60, y: 60)), "Only the explicit text editor accepts handwriting")
        XCTAssertFalse(policy.scribbleInteraction(localInteraction, shouldBeginAt: CGPoint(x: 85, y: 75)), "A style palette above an editor owns the Pencil touch")
        let contentInteraction = try XCTUnwrap(inputViews.first?.interactions.compactMap { $0 as? UIScribbleInteraction }.first { $0.delegate === policy })
        let searchPoint = try XCTUnwrap(contentInteraction.view).convert(CGPoint(x: 50, y: 50), from: shell)
        XCTAssertTrue(policy.scribbleInteraction(contentInteraction, shouldBeginAt: searchPoint), "Normal search/address text fields remain eligible")
        policy.reset()
        XCTAssertFalse(policy.scribbleInteraction(localInteraction, shouldBeginAt: CGPoint(x: 60, y: 60)), "A recreated web document cannot reuse old text exceptions")
        XCTAssertEqual(policy.diagnostics["decisions"] as? Int, 5)
        XCTAssertEqual(policy.diagnostics["allowed"] as? Int, 2)
    }

    func testOnlyExplicitTextEditorAcceptsScribbleInsideDrawingSurface() throws {
        let policy = DesktopScribblePolicy(), size = CGSize(width: 1024, height: 768)
        XCTAssertFalse(policy.permitsScribble(at: .zero, in: size))
        try policy.update(["revision": 1, "viewport": ["width": 1024.0, "height": 768.0],
            "protected": [["x": 100.0, "y": 100.0, "width": 800.0, "height": 600.0]],
            "editors": [["x": 200.0, "y": 200.0, "width": 200.0, "height": 100.0]]])
        XCTAssertFalse(policy.permitsScribble(at: CGPoint(x: 150, y: 150), in: size))
        XCTAssertTrue(policy.permitsScribble(at: CGPoint(x: 250, y: 220), in: size))
        XCTAssertTrue(policy.permitsScribble(at: CGPoint(x: 50, y: 50), in: size), "Address and search fields retain Scribble")
        XCTAssertFalse(policy.permitsScribble(at: CGPoint(x: 250, y: 220), in: CGSize(width: 768, height: 1024)), "An old layout cannot target the wrong editor")
        try policy.update(["revision": 2, "viewport": ["width": 1024.0, "height": 768.0],
            "protected": [["x": 100.0, "y": 100.0, "width": 800.0, "height": 600.0]], "editors": [[String: Double]]()])
        XCTAssertFalse(policy.permitsScribble(at: CGPoint(x: 250, y: 220), in: size), "Selecting pen revokes the editing exception")
        policy.reset()
        XCTAssertFalse(policy.permitsScribble(at: CGPoint(x: 50, y: 50), in: size))
    }
}

@MainActor
private final class ScribbleNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: () -> Void
    init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
