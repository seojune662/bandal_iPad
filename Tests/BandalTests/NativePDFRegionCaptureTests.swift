import XCTest
import PDFKit
import UIKit
@testable import Bandal

@MainActor
final class NativePDFRegionCaptureTests: XCTestCase {
    func testCropUsesDisplayedCoordinatesForEveryRotationAndOffsetCropBox() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            UIColor.red.setFill(); renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            UIColor.blue.setFill(); renderer.cgContext.fill(CGRect(x: 200, y: 0, width: 200, height: 150))
            UIColor.green.setFill(); renderer.cgContext.fill(CGRect(x: 0, y: 150, width: 200, height: 150))
            UIColor.yellow.setFill(); renderer.cgContext.fill(CGRect(x: 200, y: 150, width: 200, height: 150))
        }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 40, y: 30, width: 320, height: 240), for: .cropBox)
        let region = CGRect(x: 0.08, y: 0.12, width: 0.22, height: 0.24)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let coordinates = NativePDFPageCoordinates(page: page)
            let image = try XCTUnwrap(NativePDFRegionCapture.render(page: page, bounds: region))
            XCTAssertEqual(image.size.width, region.width * coordinates.width, accuracy: 1)
            XCTAssertEqual(image.size.height, region.height * coordinates.height, accuracy: 1)
            let original = coordinates.pdfPoint(CGPoint(x: region.midX, y: region.midY))
            let top = 300 - original.y < 150, left = original.x < 200
            let expected: [UInt8] = top ? (left ? [255, 0, 0] : [0, 0, 255]) : (left ? [0, 255, 0] : [255, 255, 0])
            let actual = try centerPixel(image)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), 2, "rotation \(rotation), channel \(channel)") }
        }
    }
    func testLargeRegionHasBoundedRasterMemoryAndEmptyRegionIsRejected() throws {
        let bounds = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let image = try XCTUnwrap(NativePDFRegionCapture.render(page: page, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))?.cgImage)
        XCTAssertLessThanOrEqual(image.width, 2048); XCTAssertLessThanOrEqual(image.height, 2048)
        XCTAssertLessThanOrEqual(image.width * image.height, 4_004_001)
        XCTAssertNil(NativePDFRegionCapture.render(page: page, bounds: .zero))
        XCTAssertNil(NativePDFRegionCapture.render(page: page, bounds: CGRect(x: 2, y: 2, width: 0.2, height: 0.2)))
    }
    func testAnnotatedCropIncludesImageAfterHighlightAndInkOnRotatedPages() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { renderer in
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let row: [String: Any] = ["id": "image", "kind": "image", "page": 1,
            "data": ["box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.4]],
            "style": ["color": "red", "width": 0.01, "opacity": 1]]
        let highlight: [String: Any] = ["color": "yellow", "rects": [["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0]]]
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let crop = try XCTUnwrap(NativePDFRegionCapture.render(page: page,
                bounds: CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.2), rows: [row], annotations: [highlight], images: ["image": image]))
            let pixel = try centerPixel(crop)
            XCTAssertLessThan(pixel[0], 3, "rotation \(rotation)")
            XCTAssertGreaterThan(pixel[2], 250, "rotation \(rotation)")
        }
    }
    func testHandwrittenOnlyRegionHasVisibleInkAndHighlight() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let ink: [String: Any] = ["id": "ink", "kind": "ink", "page": 1,
            "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.5, "p": 0.8, "t": 0], ["x": 0.8, "y": 0.5, "p": 0.8, "t": 100]]],
            "style": ["color": "blue", "width": 0.04, "opacity": 1]]
        let crop = try XCTUnwrap(NativePDFRegionCapture.render(page: page, bounds: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.1), rows: [ink]))
        let pixel = try centerPixel(crop)
        XCTAssertLessThan(pixel[0], 150)
        XCTAssertGreaterThan(pixel[2], pixel[0])
        let highlighted = try XCTUnwrap(NativePDFRegionCapture.render(page: page, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            annotations: [["color": "yellow", "rects": [["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0]]]]))
        let yellow = try centerPixel(highlighted)
        XCTAssertGreaterThan(yellow[0], yellow[2])
    }
    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return Array(pixels[offset..<(offset + 4)])
    }
}
