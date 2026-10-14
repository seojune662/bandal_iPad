import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFMetalInkTests: XCTestCase {
    func testGPUAffineProjectionMatchesCPUTransformedGeometry() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let circle = (0..<32).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / 32
            return CGPoint(x: 17.2 + cos(angle)*5.1, y: 13.8 + sin(angle)*5.1)
        }
        let polygons = [circle, [CGPoint(x: 2.3, y: 8.1), CGPoint(x: 25.4, y: 21.3),
                                 CGPoint(x: 23.8, y: 24.2), CGPoint(x: 0.7, y: 11.0)]]
        let transforms = [
            CGAffineTransform.identity,
            CGAffineTransform(translationX: 18.3, y: 9.7).rotated(by: .pi/5).scaledBy(x: 0.75, y: 0.60),
            CGAffineTransform(a: 0, b: 1.3, c: -0.8, d: 0, tx: 45.4, ty: 7.2)
        ]
        for transform in transforms {
            renderer.strokes = [.init(polygons: polygons.map { $0.map { $0.applying(transform) } }, color: .blue, opacity: 0.5)]
            let reference = try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64))
            renderer.strokes = [.init(polygons: polygons, color: .blue, opacity: 0.5, transform: transform)]
            let actual = try XCTUnwrap(renderer.renderedPixels(width: 64, height: 64))
            if transform.isIdentity { XCTAssertEqual(actual, reference); continue }
            var changedPixels = 0, totalDifference = 0, maxDifference = 0
            for pixel in 0..<(64*64) {
                var changed = false
                for component in 0..<4 {
                    let index = pixel*4+component, difference = abs(Int(actual[index])-Int(reference[index]))
                    changed = changed || difference > 0
                    totalDifference += difference; maxDifference = max(maxDifference, difference)
                }
                if changed { changedPixels += 1 }
            }
            // CGFloat CPU and Float GPU arithmetic may move an edge across one
            // MSAA sample. Allow that quantization, never a visible displacement.
            XCTAssertLessThanOrEqual(changedPixels, 4)
            XCTAssertLessThanOrEqual(maxDifference, 64)
            XCTAssertLessThanOrEqual(totalDifference, 512)
        }
    }

    func testSmallDiagonalAndRoundDotHaveFractionalGPUCoverage() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let diagonal = [CGPoint(x: 3.15, y: 4.05), CGPoint(x: 26.65, y: 21.35),
                        CGPoint(x: 25.75, y: 22.55), CGPoint(x: 2.25, y: 5.25)]
        renderer.strokes = [.init(polygons: [diagonal], color: .black, opacity: 1)]
        let line = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        let supported = [4, 2, 1].first { renderer.device!.supportsTextureSampleCount($0) }!
        XCTAssertEqual(renderer.rasterSampleCount, supported, "Use the best supported union coverage, with 2x/1x fallback")
        guard supported > 1 else { throw XCTSkip("This GPU does not support multisample coverage") }
        func alpha(_ data: Data) -> [UInt8] { stride(from: 3, to: data.count, by: 4).map { data[$0] } }
        XCTAssertGreaterThan(alpha(line).filter { $0 > 0 && $0 < 255 }.count, 20,
            "A thin diagonal must have covered edge samples instead of binary stair steps")
        let radius = 3.75, center = CGPoint(x: 16.2, y: 15.7)
        let circle = (0..<24).map { step in
            let angle = Double(step) * 2 * .pi / 24
            return CGPoint(x: center.x + cos(angle)*radius, y: center.y + sin(angle)*radius)
        }
        renderer.strokes = [.init(polygons: [circle], color: .black, opacity: 1)]
        let dot = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32)), dotAlpha = alpha(dot)
        XCTAssertGreaterThan(dotAlpha.filter { $0 > 0 && $0 < 255 }.count, 8)
        let coverage = dotAlpha.reduce(0.0) { $0 + Double($1)/255 }
        let polygonArea = 24 * radius * radius * sin(2 * .pi / 24) / 2
        XCTAssertEqual(coverage, polygonArea, accuracy: 2,
            "Antialiasing represents the original dot area rather than blurring/spreading it")
    }

    func testMultisampleUnionDoesNotAccumulateOpacityAtEdgesOrCrossings() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let a = [CGPoint(x: 3.2, y: 4.4), CGPoint(x: 28.1, y: 22.8),
                 CGPoint(x: 25.7, y: 26.0), CGPoint(x: 0.8, y: 7.6)]
        let b = [CGPoint(x: 5.4, y: 25.8), CGPoint(x: 27.2, y: 2.6),
                 CGPoint(x: 29.4, y: 4.8), CGPoint(x: 7.6, y: 28.0)]
        renderer.strokes = [.init(polygons: [a,b], color: .blue, opacity: 0.5)]
        let once = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        renderer.strokes = [.init(polygons: [a,b,a,b], color: .blue, opacity: 0.5)]
        let repeated = try XCTUnwrap(renderer.renderedPixels(width: 32, height: 32))
        XCTAssertEqual(once, repeated, "Covered MSAA samples are replaced, never alpha blended per polygon")
        let alpha = stride(from: 3, to: once.count, by: 4).map { once[$0] }
        XCTAssertEqual(alpha.max(), 128)
        XCTAssertTrue(alpha.allSatisfy { $0 <= 128 }, "A half-opacity stroke cannot darken itself")
        if renderer.rasterSampleCount > 1 {
            XCTAssertTrue(alpha.contains { $0 > 0 && $0 < 128 })
        }
    }

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
