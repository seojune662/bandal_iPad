import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFFractionalRasterTests: XCTestCase {
    private let fractionalScale: CGFloat = 2.9411765056892487

    func testBlankFractionalPaperAndSeventyOneStrokesMatchDirectReplay() throws {
        let document = try makeDocument(pattern: false), page = try XCTUnwrap(document.page(at: 0))
        let mapper = InkCoordinateMapper.whiteboard(size: CGSize(width: 400, height: 600))
        // This allocates 1177 pixels for 1176.47 physical pixels of logical
        // width. The old paper.draw(in:) produced 9695 differing channels,
        // max 68/255, in the two rightmost columns of this exact fixture.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 1385 / fractionalScale)
        let rows = makeRows(count: 71, samples: 96, mixed: false)
        let builder = NativePDFNavigationSnapshotBuilder()
        let snapshot = try XCTUnwrap(builder.make(page: page, objects: rows, tokens: nil,
            highlights: [], image: { _ in nil }))
        let raster = try XCTUnwrap(snapshot.raster(bounds: bounds, scale: fractionalScale,
            canonicalToCanvas: try XCTUnwrap(NativePDFObjectRenderer.pageTransform(mapper))))
        let paper = try directReplay(page: page, mapper: mapper, bounds: bounds, scale: fractionalScale, rows: [])
        let reference = try directReplay(page: page, mapper: mapper, bounds: bounds, scale: fractionalScale, rows: rows)
        try assertPixels(raster.paper, equal: paper, label: "blank paper")
        try assertPixels(raster.image, equal: reference, label: "71-row navigation snapshot")
        let cache = NativePDFCommittedSceneCache()
        let scene = try render(cache, paper: paper, mapper: mapper, bounds: bounds, rows: rows)
        try assertPixels(XCTUnwrap(scene.cgImage), equal: reference, label: "71-row committed scene")
    }

    func testPatternPDFRotationCropOpacityAndPressureCorrectionRemainPixelExact() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(pattern: true), page = try XCTUnwrap(document.page(at: 0))
            page.setBounds(CGRect(x: 17.25, y: 23.125, width: 351.625, height: 519.875), for: .cropBox)
            page.rotation = rotation
            let coordinates = NativePDFPageCoordinates(page: page)
            let size = CGSize(width: coordinates.width, height: coordinates.height)
            let mapper = InkCoordinateMapper.whiteboard(size: size)
            let transform = try XCTUnwrap(NativePDFObjectRenderer.pageTransform(mapper))
            let rows = makeRows(count: 9, samples: 37, mixed: true)
            let snapshot = try XCTUnwrap(NativePDFNavigationSnapshotBuilder().make(page: page,
                objects: rows, tokens: nil, highlights: [], image: { _ in nil }))
            let crops = [CGRect(origin: .zero, size: size),
                CGRect(x: 12.125, y: 17.375, width: size.width - 31.7, height: size.height - 43.2),
                CGRect(x: size.width - 100.375, y: size.height - 80.1875, width: 100.375, height: 80.1875)]
            for (cropIndex, bounds) in crops.enumerated() {
                for scale in [CGFloat(2), fractionalScale] {
                    try autoreleasepool {
                        let label = "rotation=\(rotation) crop=\(cropIndex) scale=\(scale)"
                        let paper = try directReplay(page: page, mapper: mapper, bounds: bounds, scale: scale, rows: [])
                        let reference = try directReplay(page: page, mapper: mapper, bounds: bounds, scale: scale, rows: rows)
                        let raster = try XCTUnwrap(snapshot.raster(bounds: bounds, scale: scale, canonicalToCanvas: transform))
                        try assertPixels(raster.paper, equal: paper, label: "paper \(label)")
                        try assertPixels(raster.image, equal: reference, label: "snapshot \(label)")

                        let cache = NativePDFCommittedSceneCache()
                        let firstRows = Array(rows.prefix(6))
                        let first = try render(cache, paper: paper, mapper: mapper, bounds: bounds, rows: firstRows)
                        try assertPixels(XCTUnwrap(first.cgImage), equal: directReplay(page: page, mapper: mapper,
                            bounds: bounds, scale: scale, rows: firstRows), label: "initial scene \(label)")
                        let appended = try render(cache, paper: paper, mapper: mapper, bounds: bounds, rows: rows)
                        XCTAssertEqual(cache.lastRenderMode, "append", label)
                        try assertPixels(XCTUnwrap(appended.cgImage), equal: reference, label: "appended scene \(label)")

                        var corrected = rows
                        var data = try XCTUnwrap(corrected[7]["data"] as? [String: Any])
                        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
                        points[points.count - 3]["p"] = 0.97
                        data["points"] = points; corrected[7]["data"] = data
                        let revised = try render(cache, paper: paper, mapper: mapper, bounds: bounds, rows: corrected)
                        XCTAssertEqual(cache.lastRenderMode, "tail", label)
                        try assertPixels(XCTUnwrap(revised.cgImage), equal: directReplay(page: page, mapper: mapper,
                            bounds: bounds, scale: scale, rows: corrected), label: "pressure-corrected scene \(label)")
                    }
                }
            }
        }
    }

    private func makeDocument(pattern: Bool) throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { renderer in
            renderer.beginPage()
            guard pattern else { return }
            let context = renderer.cgContext
            context.setFillColor(UIColor(red: 0.8, green: 0.35, blue: 0.1, alpha: 1).cgColor)
            context.fill(CGRect(x: 19.25, y: 30.1, width: 219.15, height: 90.25))
            context.setFillColor(UIColor(red: 0.1, green: 0.25, blue: 0.15, alpha: 1).cgColor)
            // Fine PDF detail exposes resampling throughout the page, where
            // a blank-paper fixture can only detect the outer-edge artifact.
            for x in stride(from: 0.0, to: 400.0, by: 1.75) {
                context.fill(CGRect(x: x, y: 250.1, width: 0.25, height: 159.7))
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func makeRows(count: Int, samples: Int, mixed: Bool) -> [[String: Any]] {
        (0..<count).map { index in
            let highlighter = mixed && (index == 2 || index == 6)
            let points: [[String: Double]] = (0..<samples).map { sample in
                let t = Double(sample) / Double(samples - 1)
                return ["x": mixed ? 0.04 + t * 0.92 : 0.1 + t * 0.8,
                    "y": mixed ? 0.1 + Double(index) * 0.085 + sin(t * .pi * 3) * 0.055
                        : 0.1 + Double(index % 16) * 0.045 + sin(t * .pi * 4) * 0.025,
                    "p": mixed ? 0.08 + 0.87 * t : 0.25 + 0.45 * t]
            }
            return ["id": "fractional-\(index)", "kind": highlighter ? "highlighter" : "ink",
                "data": ["inkVersion": 4, "points": points],
                "style": ["color": highlighter ? "yellow" : "blue",
                    "width": highlighter ? 0.045 : (mixed ? 0.006 : 0.004),
                    "opacity": mixed ? [0.15, 0.45, 0.75, 1][index % 4] : 0.45]]
        }
    }

    /// Independent one-pass PDF + object replay. It has no intermediate paper
    /// image, snapshot display list, scene checkpoint, or cached-image copy.
    private func directReplay(page: PDFPage, mapper: InkCoordinateMapper, bounds: CGRect,
                              scale: CGFloat, rows: [[String: Any]]) throws -> UIImage {
        try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper, bounds: bounds, scale: scale) { context in
            for row in rows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
        })
    }

    private func render(_ cache: NativePDFCommittedSceneCache, paper: UIImage, mapper: InkCoordinateMapper,
                        bounds: CGRect, rows: [[String: Any]]) throws -> UIImage {
        try XCTUnwrap(cache.render(paper: paper, mapper: mapper, bounds: bounds, highlights: [], objects: rows,
            drawHighlights: { _ in }, drawObject: { NativePDFObjectRenderer.draw($0, in: $1, mapper: mapper, image: nil) }))
    }

    private func assertPixels(_ actual: CGImage, equal expected: UIImage, label: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let reference = try XCTUnwrap(expected.cgImage, file: file, line: line)
        XCTAssertEqual(actual.width, reference.width, label, file: file, line: line)
        XCTAssertEqual(actual.height, reference.height, label, file: file, line: line)
        guard actual.width == reference.width, actual.height == reference.height else { return }
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                count: image.width * image.height * 4))
        }
        let a = try pixels(actual), b = try pixels(reference)
        var changed = 0, maximum = 0, nonopaque = 0
        for index in a.indices {
            let difference = abs(Int(a[index]) - Int(b[index]))
            if difference > 0 { changed += 1 }; maximum = max(maximum, difference)
            if index % 4 == 3, a[index] != 255 || b[index] != 255 { nonopaque += 1 }
        }
        XCTAssertEqual(changed, 0, "\(label): changed=\(changed), max=\(maximum)/255", file: file, line: line)
        XCTAssertEqual(nonopaque, 0, "\(label): every allocated backdrop pixel must be opaque", file: file, line: line)
    }
}
