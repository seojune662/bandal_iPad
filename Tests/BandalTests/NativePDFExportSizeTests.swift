import XCTest
import PDFKit
import UIKit
@testable import Bandal

@MainActor
final class NativePDFExportSizeTests: XCTestCase {
    /// A six-page handwritten assignment once exported as 72 MB because every
    /// constant-width sample became a quad plus a disk; viewers showed blank pages.
    func testConstantWidthInkExportsAsStrokedCenterlineAndStaysSmall() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
        let source = renderer.pdfData { $0.beginPage() }
        let points: [[String: Any]] = (0..<400).map { index in
            let t = Double(index) / 399
            return ["x": 0.1 + 0.8 * t, "y": 0.5 + 0.2 * sin(t * 12), "p": 0.25, "t": Double(index) * 4]
        }
        let style: [String: Any] = ["color": "ink", "width": 0.00125, "opacity": 1.0, "fixedWidth": true]
        let row: [String: Any] = ["id": "pen", "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": style]
        let exported = try NativePDFExport.render(source: source, drawings: [row], annotations: [], images: [])
        XCTAssertLessThan(exported.count, 60_000, "constant-width ink must export as one stroked polyline")
        let page = try XCTUnwrap(PDFDocument(data: exported)?.page(at: 0))
        let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let x = Int(Double(image.width) * 0.1), y = Int(Double(image.height) * 0.5), offset = (y * image.width + x) * 4
        XCTAssertLessThan(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]), 300, "the stroke start must be inked")
        let dot: [String: Any] = ["id": "dot", "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": [["x": 0.5, "y": 0.1, "p": 0.25]]], "style": style]
        let prepared = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(dot, aspect: 841.89 / 595.28))
        XCTAssertNotNil(prepared.centerline, "a single sample strokes as a zero-length round-capped segment")
        let pressure: [String: Any] = ["id": "pressure", "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": points], "style": ["color": "ink", "width": 0.004, "opacity": 1.0]]
        XCTAssertNil(try XCTUnwrap(NativePDFObjectRenderer.prepareInk(pressure, aspect: 841.89 / 595.28)).centerline, "pressure ink keeps its variable-width polygons")
    }
}
