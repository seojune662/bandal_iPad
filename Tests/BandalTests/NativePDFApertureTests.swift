import XCTest
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFApertureTests: XCTestCase {
    func testOnlyVisiblePaperContactActivatesAndPaletteHolesRemainOwnedByHTML() {
        let body = NativePDFApertureView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let overlay = UIView(frame: body.bounds); body.addSubview(overlay)
        body.pencilTarget = { _ in overlay }
        body.excludedRects = [CGRect(x: 100, y: 100, width: 200, height: 180)]
        var contacts = 0
        body.onContact = { contacts += 1 }
        for type in [UITouch.TouchType.direct, .pencil] {
            let touch = ApertureContactTouch(kind: type), event = ApertureContactEvent(touch)
            XCTAssertFalse(body.point(inside: CGPoint(x: 150, y: 140), with: event))
            XCTAssertNil(body.hitTest(CGPoint(x: 150, y: 140), with: event), "A palette color/slider touch falls through to HTML")
            XCTAssertEqual(contacts, 0, "Palette input must not close the palette as a paper contact")
            XCTAssertFalse(body.point(inside: CGPoint(x: 700, y: 500), with: event))
            XCTAssertEqual(contacts, 0)
            for state in 0..<3 {
                body.isHidden = state == 0; body.alpha = state == 1 ? 0 : 1; body.isUserInteractionEnabled = state != 2
                XCTAssertFalse(body.point(inside: CGPoint(x: 400, y: 400), with: event))
                XCTAssertNil(body.hitTest(CGPoint(x: 400, y: 400), with: event))
                XCTAssertEqual(contacts, 0, "Hidden/suspended bodies cannot dismiss HTML controls")
            }
            body.isHidden = false; body.alpha = 1; body.isUserInteractionEnabled = true
            XCTAssertTrue(body.point(inside: CGPoint(x: 400, y: 400), with: event))
            XCTAssertEqual(contacts, 1, "Both finger and Pencil begin contacts dismiss a floating palette")
            touch.currentPhase = .moved
            XCTAssertTrue(body.point(inside: CGPoint(x: 400, y: 400), with: event))
            XCTAssertEqual(contacts, 1, "Movement is not another begin contact")
            contacts = 0
        }
    }
}

/// Public UIKit fixtures exercise the hit-test contract, not hardware input.
private final class ApertureContactTouch: UITouch {
    let kind: UITouch.TouchType
    var currentPhase: UITouch.Phase = .began
    init(kind: UITouch.TouchType) { self.kind = kind; super.init() }
    override var type: UITouch.TouchType { kind }
    override var phase: UITouch.Phase { currentPhase }
}

private final class ApertureContactEvent: UIEvent {
    let contact: UITouch
    init(_ contact: UITouch) { self.contact = contact; super.init() }
    override var allTouches: Set<UITouch>? { [contact] }
}
