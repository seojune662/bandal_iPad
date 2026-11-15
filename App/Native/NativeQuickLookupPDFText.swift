import PDFKit
import UIKit

/// What a lasso holds, read on a worker from the page's immutable original: the printed lines it touches (the PDF's
/// text layer, or Vision on a page that has none), the heading above them, and whether the area has to be seen
/// to be understood (a figure, formulas, a scan). Also the area as a small picture for the model that reads it.
enum NativeQuickLookupPDFText {
    struct Reading: Equatable, Sendable {
        let text: String
        let heading: String?
        /// The text alone would not say what the area is about (NativeQuickLookupRegion).
        var picture = false
    }
    /// A page's worth of text is more than any lookup reads.
    static let maximumCharacters = 2_000

    static func read(url: URL, page number: Int, region: CGRect) async -> Reading? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> Reading? in
                guard let document = PDFDocument(url: url), let page = document.page(at: number - 1) else { return nil }
                return read(page, region: region)
            }
        }.value
    }

    struct Line: Equatable {
        let text: String
        /// Normalised to the displayed page, top left origin.
        let box: CGRect
    }

    static func read(_ page: PDFPage, region: CGRect) -> Reading? {
        let region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        let coordinates = NativePDFPageCoordinates(page: page)
        let lines = textLines(page, coordinates: coordinates)
        if lines.isEmpty, (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No text layer at all (a scan): what Vision reads there, and the area is looked at as well. A part
            // of the scan Vision reads nothing in (a figure) is looked at when something is printed there.
            guard let image = NativePDFRegionCapture.render(page: page, bounds: region)?.cgImage else { return nil }
            let text = ((try? NativeHandwritingRecognizer.recognize(image)) ?? []).map(\.text).joined(separator: "\n")
            if text.isEmpty {
                let printed = NativeQuickLookupRegion.bitmap(image).map { NativeQuickLookupRegion.figureShare($0, text: []) } ?? 0
                guard printed >= NativeQuickLookupRegion.figureThreshold else { return nil }
            }
            return Reading(text: String(text.prefix(maximumCharacters)), heading: nil, picture: true)
        }
        let touched = lines.filter { touches($0.box, region) }
        // One line the lasso covers only a part of is a term circled in a sentence: the characters inside, as before.
        // Anything more is read by whole lines, so a lasso that crosses its lines does not leave half of each out.
        let text: String
        if touched.count == 1, let line = touched.first, region.intersection(line.box).width < line.box.width * 0.6 {
            text = inside(page, region: region, coordinates: coordinates).map(\.text).joined(separator: "\n")
        } else {
            text = touched.map(\.text).joined(separator: "\n")
        }
        let figure = figureShare(page, region: region, lines: lines)
        let picture = NativeQuickLookupRegion.needsPicture(text: text, figure: figure)
        // Nothing printed there, or nothing to read and nothing to see.
        guard !text.isEmpty || figure >= NativeQuickLookupRegion.figureThreshold else { return nil }
        return Reading(text: String(text.prefix(maximumCharacters)), heading: heading(above: region, lines: lines, inside: touched), picture: picture)
    }

    /// How much of the area is print that is not a text line (NativeQuickLookupRegion.figureShare), from the area drawn by itself.
    private static func figureShare(_ page: PDFPage, region: CGRect, lines: [Line]) -> Double {
        guard let image = NativePDFRegionCapture.render(page: page, bounds: region)?.cgImage, let bitmap = NativeQuickLookupRegion.bitmap(image) else { return 0 }
        // A line's box is drawn a little tight around its glyphs.
        let text = lines.map { $0.box.insetBy(dx: -0.004, dy: -0.004) }.filter { $0.intersects(region) }.map { box in
            CGRect(x: (box.minX - region.minX) / region.width, y: (box.minY - region.minY) / region.height, width: box.width / region.width, height: box.height / region.height)
        }
        return NativeQuickLookupRegion.figureShare(bitmap, text: text)
    }

    /// A line is in the area when the area crosses at least half its height and some of its width.
    static func touches(_ line: CGRect, _ region: CGRect) -> Bool {
        let shared = line.intersection(region)
        return !shared.isNull && shared.height >= line.height * 0.5 && shared.width >= min(line.width, region.width) * 0.1
    }

    /// Only the characters inside the area: PDFKit selects the text of a page rectangle.
    private static func inside(_ page: PDFPage, region: CGRect, coordinates: NativePDFPageCoordinates) -> [Line] {
        let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)].map(coordinates.pdfPoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return (page.selection(for: rect)?.selectionsByLine() ?? []).compactMap { selection -> Line? in
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let box = normalized(selection.bounds(for: page), coordinates: coordinates)
            // A line the area only grazes (its middle is outside) is not part of it.
            guard !text.isEmpty, !box.isNull, box.midY >= region.minY, box.midY <= region.maxY else { return nil }
            return Line(text: text, box: box)
        }
    }

    /// The page's text lines with their boxes.
    static func textLines(_ page: PDFPage, coordinates: NativePDFPageCoordinates) -> [Line] {
        (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).compactMap { selection in
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let box = normalized(selection.bounds(for: page), coordinates: coordinates)
            return text.isEmpty || box.isNull || box.height <= 0 ? nil : Line(text: text, box: box)
        }
    }

    /// The nearest line above the area that is set larger than the text in it (a heading), within the area's columns.
    static func heading(above region: CGRect, lines: [Line], inside: [Line]) -> String? {
        let heights = (inside.isEmpty ? lines : inside).map(\.box.height).sorted()
        guard !heights.isEmpty else { return nil }
        let body = heights[heights.count / 2]
        let above = lines.filter { line in
            line.box.midY < region.minY && line.box.maxX > region.minX - 0.1 && line.box.minX < region.maxX + 0.1
        }.sorted { $0.box.maxY > $1.box.maxY }
        return above.first { $0.box.height >= body * 1.2 && $0.text.count <= 80 }.map(\.text)
    }

    private static func normalized(_ bounds: CGRect, coordinates: NativePDFPageCoordinates) -> CGRect {
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)].map(coordinates.displayNormalized)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: the picture

    /// The longer side of the picture sent to the model, in pixels: enough to read a slide's formulas, and a
    /// fraction of what a full page costs.
    static let pictureSide: CGFloat = 1024

    /// The area as a JPEG (base64, no `data:` prefix), a little wider than the lasso so nothing at its edge is cut.
    static func picture(url: URL, page number: Int, region: CGRect) async -> String? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> String? in
                guard let document = PDFDocument(url: url), let page = document.page(at: number - 1) else { return nil }
                let padded = region.insetBy(dx: -0.012, dy: -0.012).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let image = NativePDFRegionCapture.render(page: page, bounds: padded) else { return nil }
                return jpeg(image)
            }
        }.value
    }

    static func jpeg(_ image: UIImage) -> String? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, pictureSide / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: max(1, (pixels.width * factor).rounded()), height: max(1, (pixels.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.jpegData(compressionQuality: 0.6)?.base64EncodedString()
    }
}
