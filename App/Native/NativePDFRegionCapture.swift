import PDFKit
import UIKit

/// Crop an immutable page snapshot on a worker; PDF and drawing coordinates
/// share the displayed CropBox plane, including rotated pages.
enum NativePDFRegionCapture {
    private final class ImageBox: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }
    static func image(url: URL, page number: Int, bounds: CGRect) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> ImageBox? in
                guard let document = PDFDocument(url: url), let page = document.page(at: number - 1),
                      let result = render(page: page, bounds: bounds) else { return nil }
                return ImageBox(result)
            }
        }.value?.image
    }
    private struct Composite: @unchecked Sendable {
        let rows: [[String: Any]], annotations: [[String: Any]], images: [String: UIImage]
    }
    static func annotatedImage(url: URL, page number: Int, bounds: CGRect, rows: [[String: Any]], annotations: [[String: Any]], images: [String: UIImage]) async -> UIImage? {
        let snapshot = Composite(rows: rows, annotations: annotations, images: images)
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> ImageBox? in
                guard let document = PDFDocument(url: url), let page = document.page(at: number - 1),
                      let result = render(page: page, bounds: bounds, rows: snapshot.rows, annotations: snapshot.annotations, images: snapshot.images) else { return nil }
                return ImageBox(result)
            }
        }.value?.image
    }
    static func render(page: PDFPage, bounds: CGRect, rows: [[String: Any]] = [], annotations: [[String: Any]] = [], images: [String: UIImage] = [:]) -> UIImage? {
        let bounds = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let reference = page.pageRef, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let coordinates = NativePDFPageCoordinates(page: page)
        let size = CGSize(width: bounds.width * coordinates.width, height: bounds.height * coordinates.height)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true
        format.scale = min(2, 2048 / max(size.width, size.height), sqrt(4_000_000 / (size.width * size.height)))
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            func point(_ value: CGPoint) -> CGPoint {
                let normalized = coordinates.displayNormalized(value)
                return CGPoint(x: (normalized.x - bounds.minX) * coordinates.width,
                               y: (normalized.y - bounds.minY) * coordinates.height)
            }
            context.saveGState()
            let origin = point(.zero), x = point(CGPoint(x: 1, y: 0)), y = point(CGPoint(x: 0, y: 1))
            context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y))
            context.clip(to: coordinates.crop)
            context.drawPDFPage(reference)
            context.restoreGState()
            context.translateBy(x: -bounds.minX * coordinates.width, y: -bounds.minY * coordinates.height)
            let pageSize = CGSize(width: coordinates.width, height: coordinates.height)
            let mapper = InkCoordinateMapper.whiteboard(size: pageSize)
            for annotation in annotations {
                let color: UIColor
                switch annotation["color"] as? String {
                case "green": color = UIColor(red: 0.45, green: 0.83, blue: 0.56, alpha: 1)
                case "pink": color = UIColor(red: 1, green: 0.56, blue: 0.71, alpha: 1)
                case "blue": color = UIColor(red: 0.44, green: 0.73, blue: 1, alpha: 1)
                default: color = UIColor(red: 1, green: 0.9, blue: 0.35, alpha: 1)
                }
                context.saveGState(); context.setBlendMode(.multiply); context.setFillColor(color.withAlphaComponent(0.32).cgColor)
                for rect in annotation["rects"] as? [[String: Any]] ?? [] {
                    if let box = NativePDFRegionCapture.rectangle(rect) {
                        context.fill(CGRect(x: box.minX * pageSize.width, y: box.minY * pageSize.height, width: box.width * pageSize.width, height: box.height * pageSize.height))
                    }
                }
                context.restoreGState()
            }
            let paths = NativePDFInkPathCache(byteLimit: 16 * 1024 * 1024, countLimit: 1024)
            for raw in rows {
                var row = raw
                if row["nativePath"] == nil, ["ink", "highlighter"].contains(row["kind"] as? String ?? ""), (row["data"] as? [String: Any])?["inkVersion"] == nil {
                    row["nativePath"] = try? NativePDFLegacyInk.path(row, aspect: pageSize.height / pageSize.width)
                }
                NativePDFObjectRenderer.drawPrepared(row, in: context, mapper: mapper,
                    image: images[row["id"] as? String ?? ""], preparedInk: paths.prepare(row, aspect: pageSize.height / pageSize.width))
            }
        }
    }
    private static func rectangle(_ value: [String: Any]) -> CGRect? {
        guard let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
