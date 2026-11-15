import CoreGraphics
import Foundation

/// Whether a lassoed area can be understood from its text, or has to be seen: a figure, or formulas, whose
/// characters a PDF's text layer gives back in pieces ("q w ~ 1 R" for q̇_w ∼ 1/√R). Decided on the device from
/// what the page already says about the area, so the picture is sent only when the text would not do.
enum NativeQuickLookupRegion {
    /// From this share of formula pieces among the area's words, the text alone is not worth reading.
    static let mathThreshold = 0.3
    /// A line this much made of formula pieces is a formula, whatever the rest of the area is.
    static let formulaLineThreshold = 0.6
    /// From this share of the area touched by print that is not a line of text, it holds a figure (or a formula
    /// set as a picture, a table's rules, a scan).
    static let figureThreshold = 0.08

    /// One- and two-letter English words, which are not symbols.
    private static let shortWords: Set<String> = ["a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my", "no",
                                                  "of", "on", "or", "so", "to", "up", "us", "we", "vs", "cf", "eq", "ex"]

    private static let punctuation = CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’·•")

    /// A word that reads as part of a formula: it has an operator, a Greek or mathematical letter, or is one or
    /// two Latin letters, or a letter and a digit, standing alone (a symbol with or without its index).
    static func isFormulaPiece(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: punctuation)
        guard !core.isEmpty else { return word.unicodeScalars.contains { isOperator($0) } }
        if core.unicodeScalars.contains(where: { isOperator($0) || isMathLetter($0) }) { return true }
        let plain = core.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) }
        return plain && core.count <= 2 && core.contains(where: \.isLetter) && !shortWords.contains(core.lowercased())
    }
    /// A bare number ("1", "2.5", "10%") says nothing either way: a list's numbers are not a formula, and a
    /// formula's coefficients are not prose. It is left out of the count.
    static func isNumber(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: punctuation)
        return !core.isEmpty && core.unicodeScalars.allSatisfy { $0.properties.numericType != nil || ".,%".unicodeScalars.contains($0) }
    }
    private static func isOperator(_ scalar: Unicode.Scalar) -> Bool {
        if "=+<>^_~|/\\*".unicodeScalars.contains(scalar) { return true }
        switch scalar.value {
        case 0x00B1, 0x00D7, 0x00F7, 0x2190...0x21FF, 0x2200...0x22FF, 0x27C0...0x27EF, 0x2980...0x2AFF: return true
        default: return false
        }
    }
    private static func isMathLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0370...0x03FF, 0x1D400...0x1D7FF, 0x2100...0x214F: return true
        default: return false
        }
    }

    private static func pieces(_ line: Substring) -> (formula: Int, all: Int) {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init).filter { !isNumber($0) }
        return (words.filter(isFormulaPiece).count, words.count)
    }

    /// The share of the text's words (numbers aside) that are formula pieces.
    static func mathShare(of text: String) -> Double {
        let counts = text.split(whereSeparator: \.isNewline).map(pieces)
        let all = counts.reduce(0) { $0 + $1.all }
        return all == 0 ? 0 : Double(counts.reduce(0) { $0 + $1.formula }) / Double(all)
    }

    /// Whether one of the text's lines is a formula: at least two words (numbers aside), most of them formula pieces.
    static func hasFormulaLine(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let count = pieces(line)
            return count.all >= 2 && Double(count.formula) / Double(count.all) >= formulaLineThreshold
        }
    }

    /// The area drawn in greyscale, row-major from the top.
    struct Bitmap {
        let pixels: [UInt8]
        let width: Int, height: Int
    }
    /// The longer side of that bitmap, in pixels. The area is looked at by itself and not on a small picture of the
    /// whole page, so that a figure's hairlines are still there to be seen.
    static let analysisSide = 640

    static func bitmap(_ image: CGImage, side: Int = analysisSide) -> Bitmap? {
        let factor = min(1, Double(side) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Bitmap(pixels: pixels, width: width, height: height) : nil
    }

    /// The share of the area taken by what is printed there and is not a line of text: of a 20 by 20 grid over
    /// the area, the squares that such ink touches. Touching, not covering, because a lecture's figure is mostly
    /// thin lines: an outline and a few arrows cover little and cross many squares, while one rule under a line
    /// of text crosses a twentieth of them. Ink is what differs clearly from the area's most common shade (its
    /// paper, white or not); the app's own paper ruling stays below that.
    /// `text`: the page's text lines as fractions of the area (0…1 both ways, from the top left).
    static func figureShare(_ bitmap: Bitmap, text: [CGRect], contrast: Double = 0.2) -> Double {
        let width = bitmap.width, height = bitmap.height
        guard width > 0, height > 0, bitmap.pixels.count >= width * height else { return 0 }
        var histogram = [Int](repeating: 0, count: 16)
        for value in bitmap.pixels.prefix(width * height) { histogram[Int(value) >> 4] += 1 }
        let paper = (histogram.indices.max { histogram[$0] < histogram[$1] } ?? 15) * 16 + 8
        let limit = Int(contrast * 255)
        // The pixels of a text line are its glyphs.
        var glyphs = [Bool](repeating: false, count: width * height)
        for line in text {
            let x0 = max(0, Int((line.minX * Double(width)).rounded(.down))), x1 = min(width, Int((line.maxX * Double(width)).rounded(.up)))
            let y0 = max(0, Int((line.minY * Double(height)).rounded(.down))), y1 = min(height, Int((line.maxY * Double(height)).rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { glyphs[y * width + x] = true } }
        }
        let steps = 20
        var touched = [Bool](repeating: false, count: steps * steps)
        // The outermost pixels are left out: an area whose size is not a whole number of pixels is drawn with a
        // half-covered last row and column, which is the renderer's edge and nothing printed.
        let edge = min(width, height) > 8 ? 2 : 0
        for y in edge..<(height - edge) {
            let row = min(steps - 1, y * steps / height)
            for x in edge..<(width - edge) where !glyphs[y * width + x] && abs(Int(bitmap.pixels[y * width + x]) - paper) > limit {
                touched[row * steps + min(steps - 1, x * steps / width)] = true
            }
        }
        return Double(touched.filter { $0 }.count) / Double(steps * steps)
    }

    /// The area has to be seen: a figure in it, a formula line, or mostly formula pieces.
    static func needsPicture(text: String, figure: Double) -> Bool {
        figure >= figureThreshold || hasFormulaLine(text) || mathShare(of: text) >= mathThreshold
    }
}
