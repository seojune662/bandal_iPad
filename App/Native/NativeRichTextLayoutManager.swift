import UIKit

extension NSAttributedString.Key {
    static let nativeTableColumns = NSAttributedString.Key("BandalTableColumns")
    static let nativeTableHeader = NSAttributedString.Key("BandalTableHeader")
}

/// Draws a native table grid behind the editable text. The source remains in
/// the projection; no attachment or secondary editor owns a copy of cell text.
final class NativeRichTextLayoutManager: NSLayoutManager {
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
            let header = storage.attribute(.nativeTableHeader, at: row.location, effectiveRange: nil) as? Bool ?? false
            graphics.setFillColor((header ? UIColor.secondarySystemBackground : UIColor.systemBackground).cgColor)
            graphics.fill(bounds)
            graphics.setStrokeColor(UIColor.separator.withAlphaComponent(0.6).cgColor); graphics.setLineWidth(0.75)
            graphics.stroke(bounds.insetBy(dx: 0.375, dy: 0.375))
            for column in 1..<columns {
                let x = bounds.minX + bounds.width * CGFloat(column) / CGFloat(columns)
                graphics.move(to: CGPoint(x: x, y: bounds.minY)); graphics.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            graphics.strokePath()
        }
    }
}
