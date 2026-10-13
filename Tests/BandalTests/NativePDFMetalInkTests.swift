import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFMetalInkTests: XCTestCase {
    func testLiveHighlighterUsesPDFBackdropAndSelfCrossingHasOneOpacity() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.black.setFill(); context.fill(CGRect(x: 6, y: 4, width: 4, height: 24))
        }
        renderer.backdrop = backdrop.cgImage
        let a = [CGPoint(x: 2,y: 12), CGPoint(x: 22,y: 12), CGPoint(x: 22,y: 20), CGPoint(x: 2,y: 20)]
        let b = [CGPoint(x: 14,y: 12), CGPoint(x: 30,y: 12), CGPoint(x: 30,y: 20), CGPoint(x: 14,y: 20)]
        renderer.strokes = [.init(polygons: [a,b], color: .yellow, opacity: 0.5, multiply: true)]
        let pixels = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y*32+x)*4..<(y*32+x)*4+4]) }
        XCTAssertEqual(pixel(8,16), [0,0,0,255], "Highlighter must not wash out black PDF glyphs")
        let single = pixel(12,16), crossing = pixel(18,16)
        XCTAssertEqual(single, crossing, "One stroke must keep one opacity at a crossing")
        XCTAssertEqual(single[0], 128, accuracy: 1); XCTAssertEqual(single[1], 255); XCTAssertEqual(single[2], 255)
        XCTAssertEqual(pixel(12,3), [255,255,255,255])
        renderer.strokes = [.init(polygons: [a,b], color: .blue, opacity: 1)]
        let pen = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(Array(pen[(16*32+8)*4..<(16*32+8)*4+4]), [255,0,0,255], "Opaque pen still paints over PDF text")
        renderer.strokes = []
        let cleared = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertTrue(cleared.allSatisfy { $0 == 0 }, "Finished live ink must release its backdrop frame")
    }

    func testCommittedHighlighterKeepsDarkPDFContentAndUniformUnionOpacity() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: 32), geometry: InkPageGeometry(cropBox: CGRect(x: 0,y: 0,width: 32,height: 32), rotation: 0))
        let object: [String: Any] = ["kind": "highlighter", "data": [:], "style": ["color": "yellow", "width": 0.05, "opacity": 0.5],
                                   "nativePath": "M 0.05 0.25 L 0.7 0.25 L 0.7 0.75 L 0.05 0.75 Z M 0.4 0.25 L 0.95 0.25 L 0.95 0.75 L 0.4 0.75 Z"]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 32), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 32,height: 32))
            UIColor.black.setFill(); context.fill(CGRect(x: 6,y: 0,width: 4,height: 32))
            NativePDFObjectRenderer.draw(object, in: context.cgContext, mapper: mapper, image: nil)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 32*32*4)
        let context = try XCTUnwrap(CGContext(data: &pixels,width: 32,height: 32,bitsPerComponent: 8,bytesPerRow: 128,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0,y: 0,width: 32,height: 32))
        func pixel(_ x: Int) -> [UInt8] { Array(pixels[(16*32+x)*4..<(16*32+x)*4+4]) }
        XCTAssertEqual(pixel(8), [0,0,0,255]); XCTAssertEqual(pixel(12),pixel(18))
        XCTAssertLessThan(pixel(12)[2],200); XCTAssertGreaterThan(pixel(12)[0],240)
    }
}
