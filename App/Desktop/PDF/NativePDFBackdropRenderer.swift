import PDFKit
import UIKit

/// Builds a paper + committed-object backdrop in the overlay's canvas space.
/// The image's (0,0) corresponds to bounds.origin; drawObjects receives the
/// original canvas coordinates, so NativePDFObjectRenderer can use its mapper.
@MainActor
enum NativePDFBackdropRenderer {
    static func render(page: PDFPage, mapper: InkCoordinateMapper, bounds: CGRect, scale: CGFloat,
                       drawObjects: ((CGContext) -> Void)? = nil) -> UIImage? {
        guard let reference = page.pageRef, let transform = pdfToCanvas(page: page, mapper: mapper),
              [bounds.minX, bounds.minY, bounds.width, bounds.height, scale].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, scale > 0 else { return nil }
        // A zoomed PDF overlay can be much larger than the visible window.
        // Bound bitmap memory; its geometry remains exact when Metal samples it.
        let pixelBudget: CGFloat = 16_000_000
        let rasterScale = min(scale, sqrt(pixelBudget / (bounds.width * bounds.height)), 4096 / max(bounds.width, bounds.height))
        guard rasterScale.isFinite, rasterScale > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = rasterScale; format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(origin: .zero, size: bounds.size))
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.saveGState()
            context.concatenate(transform)
            context.clip(to: page.bounds(for: .cropBox))
            // CGPDFPage draws unrotated PDF user space. Applying PDFKit's page
            // drawing transform too would rotate/CropBox-adjust this twice.
            context.drawPDFPage(reference)
            if page.displaysAnnotations, !page.annotations.isEmpty,
               let annotationSpace = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                   bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // PDFAnnotation.draw applies PDFKit's box origin + rotation
                // transform itself. Cancel that transform once so both native
                // annotations and raw CGPDFPage content use the same PDF space.
                page.transform(annotationSpace, for: .cropBox)
                context.concatenate(annotationSpace.ctm.inverted())
                for annotation in page.annotations where annotation.shouldDisplay {
                    context.saveGState(); annotation.draw(with: .cropBox, in: context); context.restoreGState()
                }
            }
            context.restoreGState()
            drawObjects?(context)
        }
    }

    static func pdfToCanvas(page: PDFPage, mapper: InkCoordinateMapper) -> CGAffineTransform? {
        let coordinates = NativePDFPageCoordinates(page: page)
        guard coordinates.crop.width > 0, coordinates.crop.height > 0 else { return nil }
        func canvas(_ point: CGPoint) -> CGPoint {
            let normalized = coordinates.displayNormalized(point)
            return mapper.canvasPoint(InkPoint(x: normalized.x, y: normalized.y, p: 0.5))
        }
        let origin = canvas(.zero), x = canvas(CGPoint(x: 1, y: 0)), y = canvas(CGPoint(x: 0, y: 1))
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
        let determinant = transform.a*transform.d-transform.b*transform.c
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite), abs(determinant) > 1e-12 else { return nil }
        return transform
    }
}
