import UIKit

/// One search match on a page. `rects` are normalised to the displayed page with a top-left origin:
/// the lines of a text match, or the box of a recognised handwritten line.
struct NativePDFSearchMark: Equatable {
    var rects: [CGRect]
    /// A handwritten line: drawn dashed, because its box is an estimate around the ink.
    var handwriting = false
    /// The match the viewer is on.
    var current = false

    init(rects: [CGRect], handwriting: Bool = false, current: Bool = false) { self.rects = rects; self.handwriting = handwriting; self.current = current }
    init?(_ value: [String: Any]) {
        guard let raw = value["rects"] as? [[Double]] else { return nil }
        rects = raw.compactMap { $0.count == 4 && $0.allSatisfy(\.isFinite) ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        guard !rects.isEmpty else { return nil }
        handwriting = value["handwriting"] as? Bool == true; current = value["current"] as? Bool == true
    }
}

/// Search matches drawn over one page. It sits above the page's ink, takes no touches, and follows the
/// page through scroll and zoom because it is laid out in the page overlay's own bounds.
final class NativePDFSearchMarksView: UIView {
    static let match = UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1), currentMatch = UIColor(red: 1, green: 0.58, blue: 0.1, alpha: 1)
    var marks: [NativePDFSearchMark] = [] { didSet { if marks != oldValue { isHidden = marks.isEmpty; setNeedsLayout() } } }
    private var shapes: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        while shapes.count > marks.count { shapes.removeLast().removeFromSuperlayer() }
        while shapes.count < marks.count { let shape = CAShapeLayer(); layer.addSublayer(shape); shapes.append(shape) }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        for (shape, mark) in zip(shapes, marks) {
            let path = UIBezierPath()
            for rect in mark.rects {
                let frame = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height).insetBy(dx: -2, dy: -2)
                path.append(UIBezierPath(roundedRect: frame, cornerRadius: 3))
            }
            let tint = mark.current ? Self.currentMatch : Self.match
            shape.frame = bounds; shape.path = path.cgPath
            shape.fillColor = tint.withAlphaComponent(mark.handwriting ? 0.16 : mark.current ? 0.45 : 0.32).cgColor
            shape.strokeColor = mark.handwriting ? tint.cgColor : nil
            shape.lineWidth = mark.handwriting ? (mark.current ? 2.5 : 1.5) : 0
            shape.lineDashPattern = mark.handwriting ? [6, 4] : nil
        }
    }
}
