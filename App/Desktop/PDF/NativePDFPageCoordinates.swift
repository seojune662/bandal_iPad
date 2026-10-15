import PDFKit

/// Desktop Drawing/Annotation currently store DISPLAY-normalized coordinates
/// (PDF.js getViewport includes page.rotation), despite an older type comment.
/// Sync converts those to unrotated portable coordinates at its own boundary.
/// Do not migrate or rotate the canonical rows again when opening on iPad.
struct NativePDFPageCoordinates {
    let crop: CGRect
    let rotation: Int
    init(page: PDFPage) { crop = page.bounds(for: .cropBox); rotation = ((page.rotation % 360) + 360) % 360 }
    var width: Double { rotation == 90 || rotation == 270 ? crop.height : crop.width }
    var height: Double { rotation == 90 || rotation == 270 ? crop.width : crop.height }
    var geometry: InkPageGeometry { InkPageGeometry(cropBox: CGRect(x: 0, y: 0, width: width, height: height), rotation: 0) }
    func displayNormalized(_ pdfPoint: CGPoint) -> CGPoint {
        let x = (pdfPoint.x - crop.minX) / crop.width, y = (crop.maxY - pdfPoint.y) / crop.height
        switch rotation {
        case 90: return CGPoint(x: 1-y, y: x)
        case 180: return CGPoint(x: 1-x, y: 1-y)
        case 270: return CGPoint(x: y, y: 1-x)
        default: return CGPoint(x: x, y: y)
        }
    }
    func pdfPoint(_ normalized: CGPoint) -> CGPoint {
        let x: Double, y: Double
        switch rotation {
        case 90: x = normalized.y; y = 1-normalized.x
        case 180: x = 1-normalized.x; y = 1-normalized.y
        case 270: x = 1-normalized.y; y = normalized.x
        default: x = normalized.x; y = normalized.y
        }
        return CGPoint(x: crop.minX+x*crop.width, y: crop.maxY-y*crop.height)
    }
    func displayPhysical(_ pdfPoint: CGPoint) -> CGPoint {
        let p = displayNormalized(pdfPoint)
        return CGPoint(x: p.x * width, y: (1-p.y) * height)
    }
    func normalizedRect(_ rect: CGRect) -> [String: Double] {
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(displayNormalized)
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? 0, y = ys.min() ?? 0
        return ["x": x, "y": y, "width": (xs.max() ?? x)-x, "height": (ys.max() ?? y)-y]
    }
}

/// Coordinate conversion crosses several scaled PDFKit views. Sample a whole
/// page basis instead of subtracting adjacent unit points at a large offset.
/// Preserve an existing map only when the entire page differs by less than
/// 1/1024 of a physical pixel; this does not quantize stored Pencil samples.
enum NativePDFCoordinateMapping {
    static func sample(bounds: CGRect, convert: (CGPoint) -> CGPoint) -> CGAffineTransform? {
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let origin = convert(CGPoint(x: bounds.minX, y: bounds.minY))
        let x = convert(CGPoint(x: bounds.maxX, y: bounds.minY))
        let y = convert(CGPoint(x: bounds.minX, y: bounds.maxY))
        let a = (x.x-origin.x)/bounds.width, b = (x.y-origin.y)/bounds.width
        let c = (y.x-origin.x)/bounds.height, d = (y.y-origin.y)/bounds.height
        let result = CGAffineTransform(a: a, b: b, c: c, d: d,
            tx: origin.x-a*bounds.minX-c*bounds.minY,
            ty: origin.y-b*bounds.minX-d*bounds.minY)
        return valid(result) ? result : nil
    }
    static func isPixelEquivalent(_ lhs: InkCoordinateMapper, _ rhs: InkCoordinateMapper,
                                  bounds: CGRect, pixelScale: CGFloat) -> Bool {
        guard lhs.geometry == rhs.geometry, valid(lhs.canvasToPDF), valid(rhs.canvasToPDF),
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              pixelScale.isFinite, pixelScale > 0 else { return false }
        let inverse = lhs.canvasToPDF.inverted()
        guard valid(inverse) else { return false }
        // Affine displacement reaches its maximum on a rectangle at a corner.
        return [CGPoint(x: bounds.minX,y: bounds.minY), CGPoint(x: bounds.maxX,y: bounds.minY),
                CGPoint(x: bounds.minX,y: bounds.maxY), CGPoint(x: bounds.maxX,y: bounds.maxY)].allSatisfy { point in
            let projected = point.applying(rhs.canvasToPDF).applying(inverse)
            let error = hypot(projected.x-point.x, projected.y-point.y) * pixelScale
            return error.isFinite && error <= 1.0/1024.0
        }
    }
    private static func valid(_ value: CGAffineTransform) -> Bool {
        let determinant = value.a*value.d-value.b*value.c
        return [value.a,value.b,value.c,value.d,value.tx,value.ty,determinant].allSatisfy(\.isFinite)
            && determinant != 0
    }
}
