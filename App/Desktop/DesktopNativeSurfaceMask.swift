import UIKit

enum DesktopNativeSurfaceMask {
    /// Subtract the union of HTML rectangles. Even-odd masks would paint a
    /// native island wherever two popovers (or local/global holes) overlap.
    static func path(bounds: CGRect, excluding holes: [CGRect]) -> CGPath {
        var visible = [bounds]
        for hole in holes where !hole.isEmpty && !hole.isNull {
            visible = visible.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(hole)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY-rect.minY),
                    CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY-cut.maxY),
                    CGRect(x: rect.minX, y: cut.minY, width: cut.minX-rect.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX-cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
        }
        let path = CGMutablePath()
        visible.forEach { path.addRect($0) }
        return path
    }
}
