import PDFKit
import UIKit

/// What an AI insertion needs to know about one page of the PDF, read off the main thread from the page's
/// immutable original: its text lines, its printed content (text, figures and scans alike) and where the passages
/// it was asked about sit. Rects are normalised to the displayed page, like `data.box`.
struct NativeAINotePageScan: Sendable {
    var textLines: [CGRect] = []
    var content: [CGRect] = []
    /// The first of the requested passages found on the page, as the union of its line boxes.
    var passage: CGRect?
    /// Everything printed on the page, for `NativeAINotePlacement.Obstacles.text`.
    var printed: [CGRect] { textLines + content }

    /// Width of the bitmap the page's printed content is read from; its height follows the page.
    static let renderWidth = 240

    static func read(url: URL, page number: Int, passages: [String]) async -> NativeAINotePageScan? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> NativeAINotePageScan? in
                guard let document = PDFDocument(url: url), let page = document.page(at: number - 1) else { return nil }
                return scan(page, passages: passages)
            }
        }.value
    }

    static func scan(_ page: PDFPage, passages: [String]) -> NativeAINotePageScan {
        let coordinates = NativePDFPageCoordinates(page: page)
        func normalized(_ bounds: CGRect) -> CGRect {
            let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                           CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)].map(coordinates.displayNormalized)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        var result = NativeAINotePageScan()
        let crop = page.bounds(for: .cropBox)
        result.textLines = (page.selection(for: crop)?.selectionsByLine() ?? []).compactMap { line in
            guard !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let box = normalized(line.bounds(for: page))
            return box.isNull || box.width <= 0 || box.height <= 0 ? nil : box
        }
        if let text = page.string {
            for passage in passages {
                guard let range = NativeAINotePlacement.range(of: passage, in: text), let selection = page.selection(for: range) else { continue }
                let boxes = selection.selectionsByLine().map { normalized($0.bounds(for: page)) }.filter { !$0.isNull && $0.width > 0 }
                if let first = boxes.first { result.passage = boxes.dropFirst().reduce(first) { $0.union($1) }; break }
            }
        }
        result.content = renderedContent(page, coordinates: coordinates)
        return result
    }

    /// The page drawn in greyscale at `renderWidth` pixels across, read back as content boxes.
    private static func renderedContent(_ page: PDFPage, coordinates: NativePDFPageCoordinates) -> [CGRect] {
        guard let reference = page.pageRef, coordinates.width > 0, coordinates.height > 0 else { return [] }
        let width = renderWidth, height = max(1, Int((Double(width) * coordinates.height / coordinates.width).rounded()))
        guard height <= 4 * width else { return [] }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Top-left origin, so memory row 0 is the page's top, as in NativePDFRegionCapture.render.
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            func point(_ value: CGPoint) -> CGPoint {
                let normalized = coordinates.displayNormalized(value)
                return CGPoint(x: normalized.x * Double(width), y: normalized.y * Double(height))
            }
            let origin = point(.zero), x = point(CGPoint(x: 1, y: 0)), y = point(CGPoint(x: 0, y: 1))
            context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y))
            context.clip(to: coordinates.crop)
            context.interpolationQuality = .low
            context.drawPDFPage(reference)
            return true
        }
        return drawn ? NativeAINotePlacement.contentBoxes(pixels: pixels, width: width, height: height) : []
    }
}
