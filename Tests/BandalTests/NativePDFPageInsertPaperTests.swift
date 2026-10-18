import XCTest
import PDFKit
@testable import Bandal

/// Generated paper (lines/grid) is never byte-stable across a PDFKit save: thin
/// lines shift by a hair of anti-aliasing. Every page edit must still work on it.
final class NativePDFPageInsertPaperTests: XCTestCase {
    func testGeneratedPaperSurvivesInsertReorderAndDelete() throws {
        for paper in ["lines", "grid", "dots", "blank"] {
            let bytes = try NativePDFRepository.paperData(title: "노트", paper: paper, orientation: "portrait")
            let two = try NativePDFPageDocument.rewrite(bytes, pages: [1, 0])
            XCTAssertEqual(PDFDocument(data: two)?.pageCount, 2, paper)
            let reordered = try NativePDFPageDocument.rewrite(two, pages: [2, 1])
            XCTAssertEqual(PDFDocument(data: reordered)?.pageCount, 2, paper)
            XCTAssertEqual(PDFDocument(data: try NativePDFPageDocument.rewrite(reordered, pages: [2]))?.pageCount, 1, paper)
        }
    }
    func testTolerantPixelMatchStillRejectsInkAndFlattenedContent() throws {
        let bytes = try NativePDFRepository.paperData(title: "노트", paper: "lines", orientation: "portrait")
        let page = try XCTUnwrap(PDFDocument(data: bytes)?.page(at: 0))
        let clean = try NativePDFPageDocument.fingerprint(page)
        XCTAssertTrue(NativePDFPageDocument.matches(clean, try NativePDFPageDocument.fingerprint(page)))
        // A stroke-sized change (a 20pt square) must not pass.
        var inked = clean.pixels
        let width = Int(ceil(page.bounds(for: .cropBox).width * 1.5))
        for y in 300..<330 { for x in 300..<330 { for c in 0..<3 { inked[(y * width + x) * 4 + c] = 0 } } }
        XCTAssertFalse(NativePDFPageDocument.matches(clean, NativePDFPageDocument.Fingerprint(meta: clean.meta, pixels: inked)))
        var faint = clean.pixels; faint[0] = faint[0] &- 20
        XCTAssertFalse(NativePDFPageDocument.matches(clean, NativePDFPageDocument.Fingerprint(meta: clean.meta, pixels: faint)), "a single strong pixel change is not anti-aliasing noise")
    }
}
