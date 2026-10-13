import XCTest
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFBackdropTests: XCTestCase {
    func testColoredPDFBackdropMatchesDisplayInkAtEveryRotationWithAnOffsetCropAndCanvas() throws {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        pdf.beginPDFPage(nil)
        pdf.setFillColor(UIColor.magenta.cgColor); pdf.fill(media)
        let crop = CGRect(x: 60, y: 70, width: 160, height: 240)
        let colors: [UIColor] = [.red, .green, .blue, .yellow]
        let rectangles = [CGRect(x: 60, y: 190, width: 80, height: 120), CGRect(x: 140, y: 190, width: 80, height: 120),
                          CGRect(x: 60, y: 70, width: 80, height: 120), CGRect(x: 140, y: 70, width: 80, height: 120)]
        for (rectangle, color) in zip(rectangles, colors) { pdf.setFillColor(color.cgColor); pdf.fill(rectangle) }
        pdf.endPDFPage(); pdf.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data)), page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let coordinates = NativePDFPageCoordinates(page: page)
            let bounds = CGRect(x: 11, y: 7, width: coordinates.width * 1.3 + 34, height: coordinates.height * 1.3 + 26)
            let physicalToCanvas = CGAffineTransform(a: 1.3, b: 0, c: 0, d: -1.3, tx: bounds.minX + 17, ty: bounds.minY + 13 + coordinates.height * 1.3)
            let mapper = InkCoordinateMapper(canvasToPDF: physicalToCanvas.inverted(), geometry: coordinates.geometry)
            let image = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper, bounds: bounds, scale: 2) { context in
                // Closure receives original canvas coordinates, not PDF points.
                context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(x: bounds.minX + 1, y: bounds.minY + 1, width: 5, height: 5))
            })
            let expected: [[Int]] = [[255,0,0], [0,255,0], [0,0,255], [255,255,0]]
            for (index, rectangle) in rectangles.enumerated() {
                let normalized = coordinates.displayNormalized(CGPoint(x: rectangle.midX, y: rectangle.midY))
                let canvas = mapper.canvasPoint(InkPoint(x: normalized.x, y: normalized.y, p: 0.5))
                let rgb = try pixel(image, point: CGPoint(x: canvas.x - bounds.minX, y: canvas.y - bounds.minY))
                for channel in 0..<3 { XCTAssertEqual(Double(rgb[channel]), Double(expected[index][channel]), accuracy: 5, "rotation \(rotation), quadrant \(index)") }
            }
            let outside = try pixel(image, point: CGPoint(x: 10, y: 10))
            XCTAssertTrue(outside.prefix(3).allSatisfy { $0 > 245 }, "CropBox must clip magenta media-box margins")
            let overlay = try pixel(image, point: CGPoint(x: 3, y: 3))
            XCTAssertTrue(overlay.prefix(3).allSatisfy { $0 < 5 }, "Committed objects are composited in canvas coordinates")
        }
    }
    func testImportedAnnotationAppearanceIsPreservedAtEveryRotationAndHiddenAnnotationsStayHidden() throws {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        pdf.beginPDFPage(nil); pdf.setFillColor(UIColor.white.cgColor); pdf.fill(media); pdf.endPDFPage(); pdf.closePDF()
        let source = try XCTUnwrap(PDFDocument(data: data as Data)), original = try XCTUnwrap(source.page(at: 0))
        original.setBounds(CGRect(x: 60, y: 70, width: 160, height: 240), for: .cropBox)
        let visible = PDFAnnotation(bounds: CGRect(x: 80, y: 90, width: 30, height: 30), forType: .square, withProperties: nil)
        visible.color = .red; visible.interiorColor = .red; original.addAnnotation(visible)
        let hidden = PDFAnnotation(bounds: CGRect(x: 150, y: 90, width: 30, height: 30), forType: .square, withProperties: nil)
        hidden.color = .blue; hidden.interiorColor = .blue; hidden.shouldDisplay = false; original.addAnnotation(hidden)
        // Saving writes the appearance stream; loading again exercises imported
        // PDF content instead of only live, newly created PDFKit annotations.
        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(source.dataRepresentation())))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(page.annotations.contains(where: \.hasAppearanceStream))
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let coordinates = NativePDFPageCoordinates(page: page)
            let bounds = CGRect(x: 0, y: 0, width: coordinates.width, height: coordinates.height)
            let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: coordinates.height), geometry: coordinates.geometry)
            let image = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper, bounds: bounds, scale: 1))
            func sample(_ position: CGPoint) throws -> [UInt8] {
                let normalized = coordinates.displayNormalized(position)
                return try pixel(image, point: mapper.canvasPoint(InkPoint(x: normalized.x, y: normalized.y, p: 0.5)))
            }
            let red = try sample(CGPoint(x: 95, y: 105)), white = try sample(CGPoint(x: 165, y: 105))
            XCTAssertGreaterThan(red[0], 245); XCTAssertLessThan(red[1], 10); XCTAssertLessThan(red[2], 10)
            XCTAssertTrue(white.prefix(3).allSatisfy { $0 > 245 }, "Hidden annotations stay hidden at rotation \(rotation)")
        }
    }
    private func pixel(_ image: UIImage, point: CGPoint) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<offset+4])
    }
}
