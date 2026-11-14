import CoreGraphics
import Foundation

/// 짚어주기: where a passage the model quoted sits on its page. The model copies a short passage from the
/// text `read_material` gave it; the PDF keeps that text broken over lines, spaced its own way and sometimes
/// with Hangul decomposed or ligatures, so both sides are compared without whitespace, case or compatibility
/// forms. Pure text work: the PDF host turns the ranges into rectangles.
enum NativePDFGuideResolver {
    /// One recognised handwritten line, as `NativeHandwritingLine` stores it: the box is normalised to the
    /// displayed page from the top left.
    struct Line: Equatable {
        let text: String
        let box: CGRect
    }

    /// A quote shorter than this (after folding) would point at too many places to mean one.
    static let minimumLength = 2

    /// Every place `quote` occurs in `text`, in text order, as UTF-16 ranges of `text` (what `PDFPage.selection(for:)`
    /// takes). Whitespace never counts. Punctuation counts unless no occurrence matches with it: the model
    /// sometimes drops a comma or straightens a dash.
    static func ranges(of quote: String, in text: String) -> [NSRange] {
        for strict in [true, false] {
            let needle = folded(quote, punctuation: strict).map(\.scalar)
            guard needle.count >= minimumLength else { continue }
            let units = folded(text, punctuation: strict)
            let starts = occurrences(of: needle, in: units.map(\.scalar))
            if !starts.isEmpty {
                return starts.map { start in
                    let first = units[start].range, last = units[start + needle.count - 1].range
                    return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                }
            }
        }
        return []
    }

    /// The occurrence to point at when a page repeats the passage: the first one after `after` (the UTF-16
    /// offset the previous step on this page pointed at), so a walk down the page moves on; else the first.
    static func pick(_ ranges: [NSRange], after: Int?) -> NSRange? {
        guard let after else { return ranges.first }
        return ranges.first { $0.location > after } ?? ranges.first
    }

    /// The recognised lines `quote` runs through, in their stored order (`line_index`): a passage written
    /// over two lines is found across them. Empty when the handwriting does not have it.
    static func boxes(of quote: String, in lines: [Line]) -> [CGRect] {
        for strict in [true, false] {
            let needle = folded(quote, punctuation: strict).map(\.scalar)
            guard needle.count >= minimumLength else { continue }
            var units: [Unit] = []
            for (index, line) in lines.enumerated() {
                units += folded(line.text, punctuation: strict).map { Unit(scalar: $0.scalar, range: NSRange(location: index, length: 1)) }
            }
            if let start = occurrences(of: needle, in: units.map(\.scalar)).first {
                let first = units[start].range.location, last = units[start + needle.count - 1].range.location
                return lines[first...last].map(\.box)
            }
        }
        return []
    }

    // MARK: Folding

    /// One compared scalar and the characters of the source it came from.
    private struct Unit { let scalar: UInt32; let range: NSRange }

    private static func folded(_ text: String, punctuation: Bool) -> [Unit] {
        let string = text as NSString
        var units: [Unit] = []
        units.reserveCapacity(string.length)
        var index = 0
        while index < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: index)
            index = NSMaxRange(range)
            // NFKC joins decomposed Hangul and splits ligatures; a character can fold to several scalars.
            let piece = string.substring(with: range).precomposedStringWithCompatibilityMapping.lowercased()
            for scalar in piece.unicodeScalars where kept(scalar, punctuation: punctuation) {
                units.append(Unit(scalar: substitute(scalar), range: range))
            }
        }
        return units
    }

    private static func kept(_ scalar: Unicode.Scalar, punctuation: Bool) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        switch scalar.properties.generalCategory {
        // Soft hyphens, zero-width spaces and joiners, byte-order marks.
        case .format, .control: return false
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return punctuation
        default: return true
        }
    }

    /// Dashes and quotation marks the model and the PDF disagree on.
    private static func substitute(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63: return 0x2D
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: return 0x27
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: return 0x22
        default: return scalar.value
        }
    }

    /// Start indices of `needle` in `haystack`, not overlapping.
    private static func occurrences(of needle: [UInt32], in haystack: [UInt32]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var starts: [Int] = [], index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) {
                starts.append(index); index += needle.count
            } else { index += 1 }
        }
        return starts
    }
}

/// Where the caption goes: beside what it explains, never over it or the pointer; with no room there,
/// along the bottom like a subtitle. A pure function of the target and the caption's height at a width,
/// so the overlay's `Layout` can place the caption in one pass without reading anything back.
enum NativePDFGuidePlacement {
    enum Side: Equatable { case below, above, trailing, leading, subtitle }
    static let gap: CGFloat = 14, margin: CGFloat = 12, width: CGFloat = 340, subtitleWidth: CGFloat = 560
    /// Room the pointer takes left of the passage's first line.
    static let pointerReach: CGFloat = 26

    /// `bounds`: the page area. `top` and `bottom`: bands the caption keeps out of (the palette, the bars under it).
    /// `height(width)`: the caption's height when it is that wide.
    static func place(target: CGRect?, in bounds: CGRect, top: CGFloat, bottom: CGFloat, height: (CGFloat) -> CGFloat) -> (side: Side, frame: CGRect) {
        let area = CGRect(x: bounds.minX + margin, y: bounds.minY + top + margin, width: max(0, bounds.width - 2 * margin), height: max(0, bounds.height - top - bottom - 2 * margin))
        func subtitle() -> (side: Side, frame: CGRect) {
            let wide = min(subtitleWidth, area.width), tall = min(height(wide), area.height)
            return (.subtitle, CGRect(x: area.midX - wide / 2, y: area.maxY - tall, width: wide, height: tall))
        }
        guard let target, !target.isNull, target.intersects(area) else { return subtitle() }
        let avoid = CGRect(x: target.minX - pointerReach, y: target.minY - 6, width: target.width + pointerReach + 6, height: target.height + 12)
        let width = min(width, area.width), tall = height(width)
        func clampedX(_ x: CGFloat) -> CGFloat { min(max(x, area.minX), area.maxX - width) }
        func clampedY(_ y: CGFloat) -> CGFloat { min(max(y, area.minY), area.maxY - tall) }
        if avoid.maxY + gap + tall <= area.maxY {
            return (.below, CGRect(x: clampedX(avoid.minX), y: avoid.maxY + gap, width: width, height: tall))
        }
        if avoid.minY - gap - tall >= area.minY {
            return (.above, CGRect(x: clampedX(avoid.minX), y: avoid.minY - gap - tall, width: width, height: tall))
        }
        if tall <= area.height {
            if avoid.maxX + gap + width <= area.maxX {
                return (.trailing, CGRect(x: avoid.maxX + gap, y: clampedY(avoid.midY - tall / 2), width: width, height: tall))
            }
            if avoid.minX - gap - width >= area.minX {
                return (.leading, CGRect(x: avoid.minX - gap - width, y: clampedY(avoid.midY - tall / 2), width: width, height: tall))
            }
        }
        return subtitle()
    }
}
