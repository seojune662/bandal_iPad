import UIKit

/// A page overlay owns input in full-page coordinates, but allocates pixels
/// only for the visible portion. Pixel density includes ancestor transforms:
/// PDFKit can zoom a page without changing that overlay's bounds.
struct NativePDFRenderViewport: Equatable {
    static let maximumPixels: CGFloat = 8_000_000
    static let maximumDimension: CGFloat = 4096
    var canvasRect: CGRect
    var pixelScale: CGFloat
    var pixelSize: CGSize {
        CGSize(width: ceil(canvasRect.width * pixelScale), height: ceil(canvasRect.height * pixelScale))
    }

    init?(canvasBounds: CGRect, visibleRect: CGRect, canvasToWindow: CGAffineTransform, screenScale: CGFloat) {
        let values = [canvasBounds.minX, canvasBounds.minY, canvasBounds.width, canvasBounds.height,
                      visibleRect.minX, visibleRect.minY, visibleRect.width, visibleRect.height,
                      canvasToWindow.a, canvasToWindow.b, canvasToWindow.c, canvasToWindow.d, screenScale]
        guard values.allSatisfy(\.isFinite), screenScale > 0 else { return nil }
        var clipped = canvasBounds.intersection(visibleRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        // Largest singular value also handles a rotated/skewed ancestor,
        // without undersampling either canvas axis.
        let a = canvasToWindow.a, b = canvasToWindow.b, c = canvasToWindow.c, d = canvasToWindow.d
        let trace = a*a+b*b+c*c+d*d, determinant = a*d-b*c
        let magnification = sqrt(max(0, (trace + sqrt(max(0, trace*trace-4*determinant*determinant))) / 2))
        let requestedScale = screenScale * magnification
        guard requestedScale.isFinite, requestedScale > 0 else { return nil }
        // Snap to physical pixels so slow scrolling does not repeatedly change
        // glyph sampling. Expand only within the page; no offscreen full bitmap.
        let left = floor(clipped.minX * requestedScale) / requestedScale
        let top = floor(clipped.minY * requestedScale) / requestedScale
        clipped = CGRect(x: left, y: top,
            width: ceil(clipped.maxX * requestedScale) / requestedScale - left,
            height: ceil(clipped.maxY * requestedScale) / requestedScale - top).intersection(canvasBounds)
        let scale = min(requestedScale, sqrt(Self.maximumPixels / (clipped.width * clipped.height)),
                        Self.maximumDimension / max(clipped.width, clipped.height))
        guard scale.isFinite, scale > 0 else { return nil }
        canvasRect = clipped; pixelScale = scale
    }

    func localPoint(_ canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: canvasPoint.x-canvasRect.minX, y: canvasPoint.y-canvasRect.minY)
    }
}
