import PDFKit
import UIKit

/// The printed text inside a lasso, read on a worker from the page's immutable original: the PDF's text layer,
/// or, on a page that has none (a scan), the area drawn without ink and read by Vision on the device.
/// Also the heading line above the area, which says what the text is about.
enum NativeQuickLookupPDFText {
    struct Reading: Equatable, Sendable {
        let text: String
        let heading: String?
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
            // No text layer at all: read what is printed there.
            guard let image = NativePDFRegionCapture.render(page: page, bounds: region)?.cgImage,
                  let recognized = try? NativeHandwritingRecognizer.recognize(image), !recognized.isEmpty else { return nil }
            let text = recognized.map(\.text).joined(separator: "\n")
            return Reading(text: String(text.prefix(maximumCharacters)), heading: nil)
        }
        // Only the characters inside the area: PDFKit selects the text of a page rectangle.
        let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)].map(coordinates.pdfPoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let inside = (page.selection(for: rect)?.selectionsByLine() ?? []).compactMap { selection -> Line? in
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let box = normalized(selection.bounds(for: page), coordinates: coordinates)
            // A line the area only grazes (its middle is outside) is not part of it.
            guard !text.isEmpty, !box.isNull, box.midY >= region.minY, box.midY <= region.maxY else { return nil }
            return Line(text: text, box: box)
        }
        let text = inside.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return Reading(text: String(text.prefix(maximumCharacters)), heading: heading(above: region, lines: lines, inside: inside))
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
}
