import UIKit

extension NSAttributedString.Key {
    static let nativeTableColumns = NSAttributedString.Key("BandalTableColumns")
    static let nativeTableHeader = NSAttributedString.Key("BandalTableHeader")
}

/// Draws a native table grid behind the editable text. The source remains in
/// the projection; no attachment or secondary editor owns a copy of cell text.
final class NativeRichTextLayoutManager: NSLayoutManager {
    /// Resolved against `UITraitCollection.current` while drawing, so it follows light and dark.
    private static let ruleColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.12) }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let graphics = UIGraphicsGetCurrentContext(), storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let source = storage.string as NSString
        var position = characters.location
        graphics.saveGState(); defer { graphics.restoreGState() }
        while position < NSMaxRange(characters), position < source.length {
            let row = source.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(row)
            guard let columns = storage.attribute(.nativeTableColumns, at: row.location, effectiveRange: nil) as? Int, columns > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: row, actualCharacterRange: nil)
            guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { continue }
            var bounds = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in bounds = bounds.union(rect) }
            guard !bounds.isNull else { continue }
            bounds.origin.x = origin.x; bounds.origin.y += origin.y
            bounds.size.width = container.size.width
            // The editor already paints the app ground; cells take it as is (a system
            // background here is pure black in dark mode). Header rows are told
            // apart by weight, not by a band.
            graphics.setStrokeColor(Self.ruleColor.cgColor); graphics.setLineWidth(1)
            graphics.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
            for column in 1..<columns {
                let x = bounds.minX + bounds.width * CGFloat(column) / CGFloat(columns)
                graphics.move(to: CGPoint(x: x, y: bounds.minY)); graphics.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            graphics.strokePath()
        }
    }
}
