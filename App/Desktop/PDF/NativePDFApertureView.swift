import PDFKit

/// Only explicit web editors/popovers punch holes through the native body.
/// Painting and hit testing use the same rectangles; no invisible native view
/// can consume the Pencil intended for a text field in the original renderer.
@MainActor
final class NativePDFApertureView: PDFView {
    var onContact: (() -> Void)?
    var excludedRects: [CGRect] = [] { didSet { updateMask() } }
    override func layoutSubviews() { super.layoutSubviews(); updateMask() }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.contains(point), event?.allTouches?.contains(where: { $0.phase == .began }) == true { onContact?() }
        guard !excludedRects.contains(where: { $0.contains(point) }) else { return false }
        return super.point(inside: point, with: event)
    }
    private func updateMask() {
        guard !excludedRects.isEmpty else { layer.mask = nil; return }
        let shape = CAShapeLayer(), path = UIBezierPath(rect: bounds)
        for rectangle in excludedRects { path.append(UIBezierPath(rect: rectangle.intersection(bounds))) }
        shape.frame = bounds; shape.path = path.cgPath; shape.fillRule = .evenOdd
        layer.mask = shape
    }
}
