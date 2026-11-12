import UIKit
import PDFKit
import Vision

/// On-device handwriting recognition: Apple Vision only, nothing leaves the iPad.
enum NativeHandwritingRecognizer {
    static let minimumConfidence = 0.3
    /// Pixels per page point.
    static let scale: CGFloat = 2
    /// A poster-sized page is read at a lower scale instead of allocating a huge bitmap.
    private static let maximumSide: CGFloat = 4096

    /// The displayed size of a page in points, or nil when the file has no such page.
    static func pageSize(of document: PDFDocument, page: Int) -> CGSize? {
        guard let pdfPage = document.page(at: page - 1) else { return nil }
        let coordinates = NativePDFPageCoordinates(page: pdfPage)
        guard coordinates.width > 0, coordinates.height > 0 else { return nil }
        return CGSize(width: coordinates.width, height: coordinates.height)
    }

    /// The ink layer alone, dark on white: the PDF's own text is searched from its text layer, and a
    /// yellow or half-transparent pen reads as well as a black one.
    static func image(rows: [[String: Any]], pageSize: CGSize) -> UIImage {
        let factor = min(scale, maximumSide / max(pageSize.width, pageSize.height))
        let size = CGSize(width: (pageSize.width * factor).rounded(), height: (pageSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let paper = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        let ink = rows.map { row -> [String: Any] in
            var row = row
            row["style"] = (row["style"] as? [String: Any] ?? [:]).merging(["color": "ink", "opacity": 1.0]) { _, new in new }
            return row
        }
        return NativeLibraryDocumentThumbnailCache.composite(base: paper, rows: ink, annotations: [], images: [:])
    }

    /// One entry per recognised line, top to bottom as Vision returns them. Low-confidence lines are dropped.
    static func recognize(_ image: CGImage) throws -> [NativeHandwritingLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, Double(candidate.confidence) >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision's box is normalised with a bottom-left origin.
            let box = observation.boundingBox
            return NativeHandwritingLine(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height), confidence: Double(candidate.confidence))
        }
    }

    static func lines(rows: [[String: Any]], pageSize: CGSize) throws -> [NativeHandwritingLine] {
        guard !rows.isEmpty, let image = image(rows: rows, pageSize: pageSize).cgImage else { return [] }
        return try recognize(image)
    }
}
