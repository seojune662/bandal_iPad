import PDFKit

/// Only explicit web editors/popovers punch holes through the native body.
/// Painting and hit testing use the same rectangles; no invisible native view
/// can consume the Pencil intended for a text field in the original renderer.
@MainActor
final class NativePDFApertureView: PDFView, UIScribbleInteractionDelegate {
    var onContact: (() -> Void)?
    var pencilTarget: ((CGPoint) -> UIView?)?
    var excludedRects: [CGRect] = [] { didSet { updateMask() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addInteraction(UIScribbleInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
    /// Select mode retains PDFKit's finger text selection. Pencil input still
    /// belongs to our overlay even when PDFKit's read-mode page host skips it.
    /// Uses only the provider's own views, never PDFKit private view classes.
    func pencilInputTarget(at point: CGPoint) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point),
              !excludedRects.contains(where: { $0.contains(point) }) else { return nil }
        return pencilTarget?(point)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true,
           let target = pencilInputTarget(at: point) {
            if event?.allTouches?.contains(where: { $0.phase == .began }) == true { onContact?() }
            return target
        }
        return super.hitTest(point, with: event)
    }
    override func layoutSubviews() { super.layoutSubviews(); updateMask() }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point),
              !excludedRects.contains(where: { $0.contains(point) }),
              super.point(inside: point, with: event) else { return false }
        // A web palette/editor inside a hole owns its gesture. Do not report
        // it as paper contact, which would dismiss the menu before its action.
        if event?.allTouches?.contains(where: { $0.phase == .began }) == true { onContact?() }
        return true
    }
    private func updateMask() {
        guard !excludedRects.isEmpty else { layer.mask = nil; return }
        let shape = CAShapeLayer(), path = UIBezierPath(rect: bounds)
        for rectangle in excludedRects { path.append(UIBezierPath(rect: rectangle.intersection(bounds))) }
        shape.frame = bounds; shape.path = path.cgPath; shape.fillRule = .evenOdd
        layer.mask = shape
    }
}
