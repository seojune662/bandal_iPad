import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFObjectRendererTests: XCTestCase {
    func testRichRunsKeepUTF16OffsetsAndCanRemoveBaseFormatting() throws {
        let data: [String: Any] = ["text": "가😀나다", "textRuns": [
            ["from": 1, "to": 3, "style": ["bold": false, "underline": false, "color": "red", "fontSizePt": 20]],
            ["from": 2, "to": 5, "style": ["strike": true]],
            ["from": -1, "to": 2, "style": ["bold": false]]
        ]]
        let text = NativePDFObjectRenderer.attributedText(data: data, style: ["bold": true, "underline": true, "fontSizePt": 14, "align": "right"], surfaceWidth: 600)
        XCTAssertEqual(text.length, 5)
        let base = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let emoji = try XCTUnwrap(text.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(base.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(emoji.fontDescriptor.symbolicTraits.contains(.traitBold)); XCTAssertEqual(emoji.pointSize, 20)
        XCTAssertEqual(text.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int, 0)
        XCTAssertEqual(text.attribute(.strikethroughStyle, at: 3, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        let legacy = NativePDFObjectRenderer.attributedText(data: ["text": "legacy"], style: ["fontScale": 2], surfaceWidth: 600)
        XCTAssertEqual((legacy.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0, 31.2, accuracy: 0.001)
        let invalid = NativePDFObjectRenderer.attributedText(data: ["text": "invalid"], style: ["fontSizePt": true, "fontScale": false], surfaceWidth: 600)
        XCTAssertEqual((invalid.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0, 15.6, accuracy: 0.001)
    }
    func testImageRotatesAsAnObjectWithThePDFInsteadOfOnlyMovingItsBox() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.blue.setFill(); context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), geometry: InkPageGeometry(cropBox: CGRect(x: 0, y: 0, width: 100, height: 200), rotation: 90))
        let object: [String: Any] = ["kind": "image", "data": ["box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.1]], "style": ["color": "ink", "width": 0.0, "opacity": 1.0]]
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            NativePDFObjectRenderer.draw(object, in: context.cgContext, mapper: mapper, image: image)
        }
        let first = try pixel(rendered, x: 130, y: 25), second = try pixel(rendered, x: 130, y: 55)
        XCTAssertGreaterThan(first[0], 200); XCTAssertLessThan(first[2], 30)
        XCTAssertGreaterThan(second[2], 200); XCTAssertLessThan(second[0], 30)
        let bounds = try XCTUnwrap(NativePDFObjectRenderer.hitBounds(object, mapper: mapper))
        XCTAssertEqual(bounds.minX, 120, accuracy: 0.01); XCTAssertEqual(bounds.minY, 20, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 20, accuracy: 0.01); XCTAssertEqual(bounds.height, 40, accuracy: 0.01)
    }
    func testHistoricalCurvedPathAndStraightNativePathRemainSupportedWithoutIgnoringGarbage() throws {
        let curve = try XCTUnwrap(NativePDFObjectRenderer.path("M 0.1 0.2 Q 0.4 0.1 0.6 0.5 L 0.2 0.8 Z", width: 100, height: 200))
        XCTAssertFalse(curve.isEmpty)
        let outline = try XCTUnwrap(NativePDFObjectRenderer.path("M 0 0 L 1 0 L 1 1 Z M 0.5 0.5 L 0.6 0.5 L 0.6 0.6 Z", width: 100, height: 200))
        XCTAssertEqual(outline.boundingBox.width, 100); XCTAssertEqual(outline.boundingBox.height, 200)
        XCTAssertNil(NativePDFObjectRenderer.path("M 0 0 X 1 1 Z", width: 100, height: 200))
        XCTAssertNil(NativePDFObjectRenderer.path("M nan 0 Z", width: 100, height: 200))
    }
    func testCanonicalAndPreparedNativeInkMatchLegacyPathPixelsAndRotatedHitBounds() throws {
        let points: [NativePDFPoint] = [.init(x: 0.2, y: 0.3, p: 0.1, t: 0), .init(x: 0.5, y: 0.4, p: 0.3, t: 4), .init(x: 0.7, y: 0.5, p: 0.2, t: 8)]
        let data: [[String: Any]] = points.map { ["x": $0.x, "y": $0.y, "p": $0.p, "t": $0.t!] }
        let style: [String: Any] = ["color": "blue", "width": 0.012, "opacity": 0.6]
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), geometry: InkPageGeometry(cropBox: CGRect(x: 20, y: 40, width: 100, height: 200), rotation: 90))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        func render(_ object: [String: Any]) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 220, height: 160), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 220, height: 160))
                NativePDFObjectRenderer.draw(object, in: context.cgContext, mapper: mapper, image: nil)
            }
        }
        for version in [2, 3, 4, 5] {
            for kind in ["ink", "highlighter"] {
                var canonical: [String: Any] = ["id": "fixture", "kind": kind, "data": ["inkVersion": version, "points": data], "style": style]
                let prepared = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(canonical, aspect: 2))
                let polygons = version == 5
                    ? NativePDFInkGeometryV5.polygons(points: points, width: 0.012, aspect: 2, highlighter: kind == "highlighter")
                    : version == 4
                    ? NativePDFInkGeometryV4.polygons(points: points, width: 0.012, aspect: 2, highlighter: kind == "highlighter")
                    : version == 3
                    ? NativePDFInkGeometryV3.polygons(points: points, width: 0.012, aspect: 2, highlighter: kind == "highlighter")
                    : NativePDFInkGeometry.polygons(points: points, width: 0.012, aspect: 2, highlighter: kind == "highlighter")
                let encoded = polygons.map { polygon in polygon.enumerated().map { "\($0.offset == 0 ? "M" : "L") \($0.element.x) \($0.element.y)" }.joined(separator: " ") + " Z" }.joined(separator: " ")
                let legacy: [String: Any] = ["kind": kind, "data": ["points": data], "style": style, "nativePath": encoded]
                let expected = render(legacy)
                XCTAssertEqual(render(canonical).pngData(), expected.pngData())
                canonical["_nativeInk"] = prepared
                XCTAssertEqual(render(canonical).pngData(), expected.pngData())
                XCTAssertEqual(NativePDFObjectRenderer.hitBounds(canonical, mapper: mapper), NativePDFObjectRenderer.hitBounds(legacy, mapper: mapper))
            }
        }
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let start = (y * width + x) * 4
        return Array(bytes[start..<start+4])
    }
}
