import XCTest
@testable import Bandal

@MainActor
final class DesktopScribbleTests: XCTestCase {
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
