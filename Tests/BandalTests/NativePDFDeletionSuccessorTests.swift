import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFDeletionSuccessorTests: XCTestCase {
    func testSameSceneOrderedDeletionAndEmptyResultFormMonotonicChain() throws {
        let f = try Fixture()
        let rows = [row("A"), row("B"), row("C"), row("D")]
        let displayed = try f.content(rows)
        let equal = try f.content(rows)
        let captured = try f.content([rows[0], rows[2], rows[3]])
        let latest = try f.content([rows[2]])
        let empty = try f.content([])
        XCTAssertTrue(equal.isDeletionSuccessor(of: displayed))
        XCTAssertTrue(captured.isDeletionSuccessor(of: displayed))
        XCTAssertTrue(latest.isDeletionSuccessor(of: captured))
        XCTAssertTrue(latest.isDeletionSuccessor(of: displayed))
        XCTAssertTrue(empty.isDeletionSuccessor(of: latest))
        XCTAssertTrue(empty.isDeletionSuccessor(of: empty))
        XCTAssertFalse(displayed.isDeletionSuccessor(of: captured), "Undo/addition is not a deletion successor")
        XCTAssertFalse(captured.isDeletionSuccessor(of: latest), "An older completed crop must not resurrect B/D")
    }

    func testAppendReorderReplacementAndUndoAreRejectedEvenWithIdenticalPixels() throws {
        let f = try Fixture(), a = row("A"), b = row("B"), c = row("C")
        let original = try f.content([a, b, c])
        for changed in [[a, b, c, row("D")], [b, a, c], [a, row("replacement"), c]] {
            XCTAssertFalse(try f.content(changed).isDeletionSuccessor(of: original))
        }
        let afterDelete = try f.content([a, c])
        XCTAssertFalse(original.isDeletionSuccessor(of: afterDelete))
        // Both links are necessary: a result can precede latest but already be
        // behind the visible deletion frontier.
        XCTAssertTrue(afterDelete.isDeletionSuccessor(of: original))
        XCTAssertFalse(original.isDeletionSuccessor(of: afterDelete))
    }

    func testSurvivingPressureStyleKindAndNativePathChangesAreNotDeletion() throws {
        let f = try Fixture(), originalRows = [row("A"), row("B")]
        let original = try f.content(originalRows)
        for operation in 0..<4 {
            var survivor = originalRows[1]
            switch operation {
            case 0:
                survivor["data"] = ["inkVersion": 4, "points": [["x": 0.2, "y": 0.3, "p": 0.9], ["x": 0.7, "y": 0.5, "p": 0.8]]]
            case 1:
                survivor["style"] = ["color": "red", "width": 0.02, "opacity": 0.45]
            case 2:
                survivor["kind"] = "highlighter"
            default:
                survivor["nativePath"] = "M 0 0 L 1 1"
            }
            XCTAssertFalse(try f.content([survivor]).isDeletionSuccessor(of: original), "operation=\(operation)")
        }
        XCTAssertTrue(try f.content([originalRows[1]]).isDeletionSuccessor(of: original))
    }

    func testCanonicalAcknowledgementMetadataKeepsLogicalMutationIdentity() throws {
        let f = try Fixture()
        let source = row("A")
        let original = try f.content([source])
        var acknowledged = source
        acknowledged["id"] = "server-A"; acknowledged["updatedAt"] = "later"
        XCTAssertTrue(try f.content([acknowledged]).isDeletionSuccessor(of: original),
            "The existing Content contract uses clientMutationId before canonical id")
        acknowledged["clientMutationId"] = "another-contact"
        XCTAssertFalse(try f.content([acknowledged]).isDeletionSuccessor(of: original))
    }

    func testMissingEmptyAndAmbiguousIdentifiersAreConservativelyRejected() throws {
        let f = try Fixture(), valid = row("A")
        let good = try f.content([valid]), empty = try f.content([])
        var missing = valid; missing.removeValue(forKey: "id"); missing.removeValue(forKey: "clientMutationId")
        var blank = valid; blank["clientMutationId"] = ""
        for badRows in [[missing], [blank], [valid, valid]] {
            let bad = try f.content(badRows)
            XCTAssertFalse(bad.isDeletionSuccessor(of: good))
            XCTAssertFalse(good.isDeletionSuccessor(of: bad))
            XCTAssertFalse(empty.isDeletionSuccessor(of: bad), "Even deleting all ambiguous rows needs the exact-only path")
            XCTAssertFalse(bad.isDeletionSuccessor(of: bad))
        }
    }

    func testIdentifierComparisonUsesExactUTF8NotCanonicalUnicodeEquality() throws {
        let f = try Fixture()
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift's String equivalence is the adversarial condition")
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let a = row(composed), b = row(decomposed)
        let one = try f.content([a])
        XCTAssertFalse(try f.content([b]).isDeletionSuccessor(of: one))
        let twoDistinctWireIDs = try f.content([a, b])
        XCTAssertTrue(try f.content([b]).isDeletionSuccessor(of: twoDistinctWireIDs))
        XCTAssertFalse(try f.content([b, a]).isDeletionSuccessor(of: twoDistinctWireIDs))
    }

    func testPaperGeometryHighlightsAndSurvivingImageIdentityMustMatch() throws {
        let f = try Fixture()
        let rows = [row("A"), imageRow("resource")]
        let resource = image(.red), replacement = image(.red)
        let highlights: [[String: Any]] = [["rects": [["x": 0.1, "y": 0.2, "width": 0.4, "height": 0.1]], "color": "yellow", "nativeOpacity": 0.4]]
        let original = try f.content(rows, highlights: highlights, image: resource)
        XCTAssertTrue(try f.content([rows[1]], highlights: highlights, image: resource).isDeletionSuccessor(of: original))
        XCTAssertFalse(try f.content([rows[1]], highlights: highlights, image: replacement).isDeletionSuccessor(of: original),
            "Equal pixels in a newly resolved image are not an identity proof")
        XCTAssertFalse(try f.content([rows[1]], highlights: highlights).isDeletionSuccessor(of: original))
        XCTAssertTrue(try f.content([rows[0]], highlights: highlights).isDeletionSuccessor(of: original),
            "Deleting the resource row itself does not require retaining its old image")
        var changedHighlights = highlights; changedHighlights[0]["nativeOpacity"] = 0.6
        XCTAssertFalse(try f.content([rows[0]], highlights: changedHighlights).isDeletionSuccessor(of: original))
        let changedMapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 420, height: 600))
        XCTAssertFalse(try f.content([rows[0]], highlights: highlights, mapper: changedMapper).isDeletionSuccessor(of: original))
        let otherPaper = try Fixture()
        XCTAssertFalse(try otherPaper.content(rows, highlights: highlights, image: resource).isDeletionSuccessor(of: original))
    }

    func testProofReadsOnlyFrozenMetadataAfterMutableSourcesChange() throws {
        let f = try Fixture()
        let point = NSMutableDictionary(dictionary: ["x": 0.2, "y": 0.3, "p": 0.3])
        let style = NSMutableDictionary(dictionary: ["color": "blue", "width": 0.02, "opacity": 0.45])
        let box = NSMutableDictionary(dictionary: ["x": 0.1, "y": 0.2, "width": 0.4, "height": 0.1])
        var source = row("A")
        source["data"] = ["inkVersion": 4, "points": [point, NSMutableDictionary(dictionary: ["x": 0.7, "y": 0.5, "p": 0.8])]]
        source["style"] = style
        let highlights: [[String: Any]] = [["rects": [box], "color": "yellow"]]
        let before = try f.content([source], highlights: highlights)
        let sameFrozen = try f.content([source], highlights: highlights)
        point["p"] = 0.95; style["color"] = "red"; box["width"] = 0.8
        XCTAssertTrue(sameFrozen.isDeletionSuccessor(of: before),
            "Previously captured metadata must not begin reading its caller's mutated containers")
        XCTAssertFalse(try f.content([source], highlights: highlights).isDeletionSuccessor(of: before))
    }

    private func row(_ identifier: String) -> [String: Any] {
        ["id": identifier, "clientMutationId": identifier, "kind": "ink",
         "data": ["inkVersion": 4, "points": [["x": 0.2, "y": 0.3, "p": 0.3], ["x": 0.7, "y": 0.5, "p": 0.8]]],
         "style": ["color": "blue", "width": 0.02, "opacity": 0.45]]
    }
    private func imageRow(_ identifier: String) -> [String: Any] {
        ["id": identifier, "kind": "image", "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.2, "height": 0.3]], "style": [:]]
    }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
    @MainActor
    private final class Fixture {
        let document: PDFDocument
        let page: PDFPage
        let builder = NativePDFNavigationSnapshotBuilder()
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 400, height: 600))
        init() throws {
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
                context.beginPage(); UIColor.gray.setFill()
                context.cgContext.fill(CGRect(x: 30, y: 40, width: 70, height: 80))
            }
            document = try XCTUnwrap(PDFDocument(data: data))
            page = try XCTUnwrap(document.page(at: 0))
        }
        func content(_ rows: [[String: Any]], highlights: [[String: Any]] = [],
                     image: UIImage? = nil, mapper suppliedMapper: InkCoordinateMapper? = nil) throws -> NativePDFRetainedInkBackdrop.Content {
            let tokens = rows.map(NativePDFCommittedVisualToken.init)
            let snapshot = try XCTUnwrap(builder.make(page: page, objects: rows, tokens: tokens,
                highlights: highlights, image: { _ in image }))
            return try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: snapshot,
                mapper: suppliedMapper ?? mapper, objects: rows, tokens: tokens, highlights: highlights, imageForObject: { _ in image }))
        }
    }
}
