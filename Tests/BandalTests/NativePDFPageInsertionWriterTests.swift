import XCTest
import PDFKit
import CoreGraphics
@testable import Bandal

final class NativePDFPageInsertionWriterTests: XCTestCase {
    /// Deliberately includes cycles, inherited properties, binary strings and a
    /// tagged annotation. It does not rely on PDFKit's writer to create fixtures.
    private func fixture(rootExtra: String = "", resourcesExtra: String = "", group: String = "/S /Transparency /CS /DeviceRGB", font: String = "/Type /Font /Subtype /Type1 /BaseFont /Helvetica", streamExtra: String = "", content: String = "q 0.2 0.3 0.8 rg 20 20 80 60 re f Q BT /F#20A 15 Tf 30 140 Td (Original) Tj ET") -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 8 0 R /MarkInfo << /Marked true >> /Outlines 12 0 R /Names << /Dests << /Names [(named) [3 0 R /XYZ 0 200 null]] >> >> \(rootExtra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 240 320] /CropBox [5 10 220 300] /Rotate 90 /Resources 4 0 R >>",
            "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Group << \(group) >> /Annots [9 0 R] /StructParents 0 /PieceInfo 10 0 R >>",
            "<< /Font << /F#20A 6 0 R >> \(resourcesExtra) >>",
            "<< /Length \(content.utf8.count) \(streamExtra) >>\nstream\n\(content)\nendstream",
            "<< \(font) >>",
            "<< /Title (Preserved document) /Author (Fixture) >>",
            "<< /Type /StructTreeRoot /K [11 0 R] /ParentTree << /Nums [0 [11 0 R]] >> /ParentTreeNextKey 1 >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 40 45 65] /Contents <FEFF0041> /P 3 0 R >>",
            "<< /Self 10 0 R /Binary <000AFF80> /Escaped /a#23#2F#E9 /Small 0.00000000001 /Large 9007199254740993 /Real 0.123456789012345 >>",
            "<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /Outlines /First 13 0 R /Last 13 0 R /Count 1 >>",
            "<< /Title (Chapter) /Parent 12 0 R /Dest [3 0 R /XYZ 0 200 null] >>"
        ]
        return makePDF(objects)
    }
    private func makePDF(_ objects: [String]) -> Data {
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count); result.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xref = result.count
        result.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() { result.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8) }
        result.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 7 0 R /ID [<0102030405060708090A0B0C0D0E0F10><1112131415161718191A1B1C1D1E1F20>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return result
    }
    private func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var value: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFDictionaryGetDictionary(parent, key, &value)); return try XCTUnwrap(value)
    }
    private func array(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFArrayRef {
        var value: CGPDFArrayRef?; XCTAssertTrue(CGPDFDictionaryGetArray(parent, key, &value)); return try XCTUnwrap(value)
    }
    private func textBytes(_ parent: CGPDFDictionaryRef, _ key: String) throws -> Data {
        var value: CGPDFStringRef?; XCTAssertTrue(CGPDFDictionaryGetString(parent, key, &value)); let string = try XCTUnwrap(value)
        return Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: CGPDFStringGetLength(string))
    }
    func testInsertionPreservesCyclicTaggedGraphBinaryNamesNumbersAndInheritedGeometry() throws {
        let source = fixture(), recipe = [0, 1, 0, 0]
        let output = try XCTUnwrap(NativePDFPageInsertionWriter.write(source, pages: recipe))
        let sourcePDF = try XCTUnwrap(PDFDocument(data: source)), pdf = try XCTUnwrap(PDFDocument(data: output))
        XCTAssertEqual(pdf.pageCount, 4)
        _ = try NativePDFPageDocument.validate(source: source, target: output, pages: recipe)
        for index in 0..<4 {
            let page = try XCTUnwrap(pdf.page(at: index)), original = try XCTUnwrap(sourcePDF.page(at: 0))
            XCTAssertEqual(page.rotation, 90); XCTAssertEqual(page.bounds(for: .cropBox), original.bounds(for: .cropBox))
            XCTAssertEqual(page.string, original.string)
            XCTAssertEqual(try NativePDFPageDocument.fingerprint(page, annotations: false).pixels, try NativePDFPageDocument.fingerprint(original, annotations: false).pixels)
            XCTAssertEqual(page.annotations.count, index == 1 ? 1 : 0)
        }
        let cg = try XCTUnwrap(pdf.documentRef), page = try XCTUnwrap(cg.page(at: 2)?.dictionary), piece = try dictionary(page, "PieceInfo")
        XCTAssertEqual(try dictionary(piece, "Self").rawValue, piece.rawValue, "dictionary cycle remains a reference")
        XCTAssertEqual(try textBytes(piece, "Binary"), Data([0, 10, 255, 128]))
        var name: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetName(piece, "Escaped", &name))
        XCTAssertEqual(Data(bytes: try XCTUnwrap(name), count: strlen(try XCTUnwrap(name))), Data([97, 35, 47, 233]))
        var small: CGPDFReal = 0, large: CGPDFInteger = 0, real: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(piece, "Small", &small)); XCTAssertEqual(small, 0.00000000001, accuracy: 1e-25)
        XCTAssertTrue(CGPDFDictionaryGetInteger(piece, "Large", &large)); XCTAssertEqual(large, 9_007_199_254_740_993)
        XCTAssertTrue(CGPDFDictionaryGetNumber(piece, "Real", &real)); XCTAssertEqual(real, 0.123456789012345, accuracy: 1e-16)
        var annotation: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(try array(page, "Annots"), 0, &annotation))
        XCTAssertEqual(try dictionary(XCTUnwrap(annotation), "P").rawValue, page.rawValue, "annotation page reference follows the original page")
        let structure = try dictionary(XCTUnwrap(cg.catalog), "StructTreeRoot")
        var element: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(try array(structure, "K"), 0, &element))
        XCTAssertEqual(try dictionary(XCTUnwrap(element), "Pg").rawValue, page.rawValue)
        XCTAssertEqual(try dictionary(XCTUnwrap(element), "P").rawValue, structure.rawValue)
        for number in [1, 3, 4] {
            var property: CGPDFObjectRef?
            XCTAssertFalse(CGPDFDictionaryGetObject(try XCTUnwrap(cg.page(at: number)?.dictionary), "StructParents", &property))
        }
        XCTAssertEqual(pdf.index(for: try XCTUnwrap(pdf.outlineRoot?.child(at: 0)?.destination?.page)), 1)
        XCTAssertEqual(NativePDFPageDocument.fingerprint(source), NativePDFPageDocument.fingerprint(output))
        // Independently check every emitted xref offset, not merely PDFKit's
        // tolerant parser (which can repair an incorrectly indexed PDF).
        let trailer = try XCTUnwrap(String(data: output.suffix(4000), encoding: .isoLatin1))
        let start = try XCTUnwrap(trailer.range(of: "startxref\n", options: .backwards))
        let xref = try XCTUnwrap(Int(trailer[start.upperBound...].split(separator: "\n").first!))
        XCTAssertEqual(String(decoding: output[xref..<(xref + 5)], as: UTF8.self), "xref\n")
        let rows = String(decoding: output[xref...], as: UTF8.self).split(separator: "\n")
        let count = try XCTUnwrap(Int(rows[1].split(separator: " ")[1]))
        for id in 1..<count {
            let offset = try XCTUnwrap(Int(rows[id + 2].split(separator: " ")[0])), expected = "\(id) 0 obj\n"
            XCTAssertEqual(String(decoding: output[offset..<(offset + expected.utf8.count)], as: UTF8.self), expected)
        }
    }
    func testMultipleInsertionAtBeginningMiddleAndEndPreservesEveryOriginalPage() throws {
        let original = fixture(), two = try XCTUnwrap(NativePDFPageInsertionWriter.write(original, pages: [1, 0]))
        let recipe = [0, 1, 0, 2, 0], output = try XCTUnwrap(NativePDFPageInsertionWriter.write(two, pages: recipe))
        _ = try NativePDFPageDocument.validate(source: two, target: output, pages: recipe)
        XCTAssertEqual(PDFDocument(data: output)?.pageCount, 5)
        XCTAssertNil(NativePDFPageInsertionWriter.write(two, pages: [2, 0, 1]))
        XCTAssertNil(NativePDFPageInsertionWriter.write(two, pages: [1, 0]))
    }
    func testUnsupportedCatalogAndNameFeaturesFailClosedWithoutChangingSource() throws {
        for extra in ["/PageLabels << /Nums [0 << /S /D >>] >>", "/Threads []", "/UnknownFeature true"] {
            let source = fixture(rootExtra: extra)
            XCTAssertNil(NativePDFPageInsertionWriter.write(source, pages: [1, 0]))
            XCTAssertEqual(PDFDocument(data: source)?.pageCount, 1)
        }
        XCTAssertNil(NativePDFPageInsertionWriter.write(fixture(resourcesExtra: "/Bad#00Name true"), pages: [1, 0]))
    }
    func testDigestRejectsChangesInFontTypeResourceNameGroupAndContents() throws {
        let source = fixture(), before = try XCTUnwrap(PDFDocument(data: source)), original = try XCTUnwrap(before.page(at: 0)?.pageRef)
        let proof = try XCTUnwrap(NativePDFPageContentDigest().digest(original))
        for changed in [fixture(font: "/Type /Font /Subtype /Type1 /BaseFont /Courier"), fixture(font: "/Type /Font /Subtype /TrueType /BaseFont /Helvetica"), fixture(group: "/S /Transparency /CS /DeviceGray"), fixture(content: "q 1 0 0 rg 20 20 80 60 re f Q")] {
            let other = try XCTUnwrap(PDFDocument(data: changed))
            XCTAssertNotEqual(proof, NativePDFPageContentDigest().digest(try XCTUnwrap(other.page(at: 0)?.pageRef)))
        }
        let renamed = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(of: "/F#20A", with: "/F#20B").utf8)
        let namePDF = try XCTUnwrap(PDFDocument(data: renamed))
        XCTAssertNotEqual(proof, NativePDFPageContentDigest().digest(try XCTUnwrap(namePDF.page(at: 0)?.pageRef)))
        // A cycle in a painting resource is unsupported for a structural proof.
        let cyclic = try XCTUnwrap(PDFDocument(data: fixture(resourcesExtra: "/Cycle 4 0 R")))
        XCTAssertNil(NativePDFPageContentDigest().digest(try XCTUnwrap(cyclic.page(at: 0)?.pageRef)))
    }
    func testDecodedStreamsPreserveBytesAndRejectExternalData() throws {
        let content = "0.3 0.6 0.9 rg 10 20 30 40 re f"
        let hex = content.utf8.map { String(format: "%02X", $0) }.joined() + ">"
        let source = fixture(streamExtra: "/Filter /ASCIIHexDecode", content: hex)
        let output = try XCTUnwrap(NativePDFPageInsertionWriter.write(source, pages: [1, 0]))
        let before = try XCTUnwrap(PDFDocument(data: source)), after = try XCTUnwrap(PDFDocument(data: output))
        let beforePage = try XCTUnwrap(before.page(at: 0)?.pageRef), afterPage = try XCTUnwrap(after.page(at: 0)?.pageRef)
        XCTAssertEqual(NativePDFPageContentDigest().digest(beforePage), NativePDFPageContentDigest().digest(afterPage))
        XCTAssertEqual(try NativePDFPageDocument.fingerprint(XCTUnwrap(before.page(at: 0))).pixels, try NativePDFPageDocument.fingerprint(XCTUnwrap(after.page(at: 0))).pixels)
        _ = try NativePDFPageDocument.validate(source: source, target: output, pages: [1, 0])
        for property in ["/F (unavailable-external-stream)", "/FFilter /ASCIIHexDecode", "/FDecodeParms << >>"] {
            XCTAssertNil(NativePDFPageInsertionWriter.write(fixture(streamExtra: property), pages: [1, 0]))
        }
        XCTAssertNotNil(NativePDFPageInsertionWriter.write(fixture(content: ""), pages: [1, 0]))
    }
    func testAnnotationAppearanceChangesCannotTakeStructuralFastPath() throws {
        func document(color: String) -> Data {
            let stream = "\(color) rg 0 0 25 25 re f"
            return makePDF([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 320] /Resources << >> /Annots [4 0 R] >>",
                "<< /Type /Annot /Subtype /Square /Rect [20 40 45 65] /AP << /N 5 0 R >> >>",
                "<< /Type /XObject /Subtype /Form /BBox [0 0 25 25] /Resources << >> /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
                "null", "<< >>"
            ])
        }
        let before = document(color: "1 0 0"), after = document(color: "0 0 1")
        XCTAssertThrowsError(try NativePDFPageDocument.validate(source: before, target: after, pages: [1]))
        let copied = try XCTUnwrap(NativePDFPageInsertionWriter.write(before, pages: [1, 0]))
        let summary = try NativePDFPageDocument.validate(source: before, target: copied, pages: [1, 0])
        XCTAssertEqual(summary.rasterPages, 1)
    }
    func testWidgetAndLinkTargetsFollowOriginalPageAfterInsertion() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture()))
        let page = try XCTUnwrap(source.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 80, width: 100, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "editable"; field.widgetStringValue = "Retain value"; page.addAnnotation(field)
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 100, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 20, y: 200))); page.addAnnotation(link)
        let bytes = try XCTUnwrap(source.dataRepresentation()), recipe = [0, 1, 0]
        let output = try XCTUnwrap(NativePDFPageInsertionWriter.write(bytes, pages: recipe)), after = try XCTUnwrap(PDFDocument(data: output))
        _ = try NativePDFPageDocument.validate(source: bytes, target: output, pages: recipe)
        let original = try XCTUnwrap(after.page(at: 1))
        XCTAssertEqual(original.annotations.first { $0.fieldName == "editable" }?.widgetStringValue, "Retain value")
        let action = try XCTUnwrap(original.annotations.first { $0.type == "Link" }?.action as? PDFActionGoTo)
        XCTAssertEqual(after.index(for: try XCTUnwrap(action.destination.page)), 1)
        XCTAssertEqual(after.index(for: try XCTUnwrap(after.outlineRoot?.child(at: 0)?.destination?.page)), 1)
        XCTAssertTrue(try XCTUnwrap(after.page(at: 0)).annotations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(after.page(at: 2)).annotations.isEmpty)
    }
    func testEscapedNulNamesDisableStructuralProofDuringRemoteValidation() throws {
        let source = makePDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 40 40] /Resources << /Bad#00Name true >> >>",
            "null", "null", "null", "<< >>"
        ])
        XCTAssertNil(NativePDFPageInsertionWriter.write(source, pages: [1, 0]))
        // CoreGraphics rejects the malformed name on current SDKs. The guard
        // also covers permissive parsers and harmless occurrences in strings.
        XCTAssertThrowsError(try NativePDFPageDocument.validate(source: source, target: source, pages: [1]))
        let potentialEscape = makePDF([
            "<< /Type /Catalog /Pages 2 0 R /Lang (#00) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 40 40] /Resources << >> >>",
            "null", "null", "null", "<< >>"
        ])
        let result = try NativePDFPageDocument.validate(source: potentialEscape, target: potentialEscape, pages: [1])
        XCTAssertEqual(result.structuralPages, 0)
        XCTAssertEqual(result.rasterPages, 1)
    }
    func testChangedPixelsCannotPassContentValidation() throws {
        let source = fixture(), changed = fixture(content: "1 0 0 rg 10 10 100 100 re f")
        XCTAssertThrowsError(try NativePDFPageDocument.validate(source: source, target: changed, pages: [1]))
    }
}
