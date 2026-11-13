import CoreGraphics
import Foundation

/// Where an AI note or diagram goes on a PDF page: the free rect nearest to what the question was about,
/// never over the page's text, its drawings or its handwriting.
///
/// Pure: rects are normalised to the displayed page (0…1, top-left origin, like `data.box`), and
/// `aspect` is the page's height over its width. Distances and gaps are measured in page widths,
/// so a gap is the same on screen across and down.
enum NativeAINotePlacement {
    /// What must stay uncovered.
    struct Obstacles: Equatable {
        /// The PDF's own text lines and other printed content.
        var text: [CGRect] = []
        /// Existing drawings and objects on the page.
        var objects: [CGRect] = []
        /// Handwritten lines.
        var handwriting: [CGRect] = []
        var all: [CGRect] { text + objects + handwriting }
    }

    /// Clear space kept around every obstacle in the free-space pass, and in the margin pass.
    static let gap = 0.012, marginGap = 0.006
    /// The paper edge kept clear in the free-space pass, and in the margin pass.
    static let inset = 0.04, marginInset = 0.015

    /// The rect of `size` nearest to `anchor` that stays `gap` clear of every obstacle and inside `region`;
    /// nil when there is none. "Nearest" is the distance between the two rects, then between their centres,
    /// and a spot below the anchor wins a tie with one above (reading order).
    static func nearestFree(size: CGSize, anchor: CGRect, obstacles: Obstacles, aspect: Double,
                            region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), gap: Double = gap) -> CGRect? {
        Grid(obstacles: obstacles.all, aspect: aspect, gap: gap).search(size: size, anchor: anchor, region: region)?.rect
    }

    struct Placement: Equatable {
        let rect: CGRect
        /// Which of the offered sizes fits there.
        let size: Int
        /// The page's margin, after no free space took a full-size note.
        let inMargin: Bool
    }

    /// The free-space pass tries `sizes` (widest first) anywhere on the page away from its edge; failing that,
    /// the margin pass tries `marginSizes` in the strips outside the printed content. A narrower size has to be
    /// clearly nearer to win over a wider one. Nil: neither fits, so the note goes to the page note.
    static func place(sizes: [CGSize], marginSizes: [CGSize] = [], anchor: CGRect, obstacles: Obstacles, aspect: Double) -> Placement? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        let page = CGRect(x: inset, y: inset / aspect, width: 1 - 2 * inset, height: 1 - 2 * inset / aspect)
        if let found = best(sizes, regions: [page], anchor: anchor, grid: Grid(obstacles: obstacles.all, aspect: aspect, gap: gap)) {
            return Placement(rect: found.rect, size: found.size, inMargin: false)
        }
        let regions = margins(around: obstacles.text, aspect: aspect)
        guard !marginSizes.isEmpty, !regions.isEmpty,
              let found = best(marginSizes, regions: regions, anchor: anchor, grid: Grid(obstacles: obstacles.all, aspect: aspect, gap: marginGap)) else { return nil }
        return Placement(rect: found.rect, size: found.size, inMargin: true)
    }

    /// The strips between the printed content and the paper edge. None on a page without content:
    /// the free-space pass already had the whole page.
    static func margins(around content: [CGRect], aspect: Double) -> [CGRect] {
        guard let first = content.first else { return [] }
        let body = content.dropFirst().reduce(first) { $0.union($1) }
        let left = marginInset, right = 1 - marginInset, top = marginInset / aspect, bottom = 1 - marginInset / aspect
        return [CGRect(x: left, y: top, width: body.minX - left, height: bottom - top),
                CGRect(x: body.maxX, y: top, width: right - body.maxX, height: bottom - top),
                CGRect(x: left, y: top, width: right - left, height: body.minY - top),
                CGRect(x: left, y: body.maxY, width: right - left, height: bottom - body.maxY)]
            .filter { $0.width > 0.01 && $0.height > 0.01 }
    }

    /// A narrower size costs this much per page width it gives up, so it wins only when it is clearly nearer.
    private static let narrowingCost = 0.25

    private static func best(_ sizes: [CGSize], regions: [CGRect], anchor: CGRect, grid: Grid) -> (rect: CGRect, size: Int)? {
        guard let widest = sizes.map(\.width).max() else { return nil }
        var result: (rect: CGRect, size: Int, score: Double)?
        for (index, size) in sizes.enumerated() {
            for region in regions {
                guard let found = grid.search(size: size, anchor: anchor, region: region) else { continue }
                let score = found.score + narrowingCost * (widest - size.width)
                if result.map({ score < $0.score }) ?? true { result = (found.rect, index, score) }
            }
        }
        return result.map { ($0.rect, $0.size) }
    }

    /// The page as square cells a little under 3 pt wide on A4. A cell any obstacle (grown by the gap) touches is taken,
    /// so a rect made of free cells never comes within the gap of one. A summed-area table answers "is this rect free"
    /// in constant time, so a search costs the same on an empty page and under thousands of strokes.
    private struct Grid {
        static let columns = 200
        let aspect: Double, cell: Double, rows: Int
        /// Taken-cell counts, summed: `table[(r) * (columns + 1) + c]` covers rows < r and columns < c.
        private var table: [Int32]

        init(obstacles: [CGRect], aspect: Double, gap: Double) {
            self.aspect = aspect; cell = 1 / Double(Self.columns)
            rows = max(1, Int((aspect / cell).rounded(.up)))
            let columns = Self.columns, width = columns + 1
            var coverage = [Int32](repeating: 0, count: (rows + 1) * width)
            for box in obstacles where box.width.isFinite && box.height.isFinite && box.width >= 0 && box.height >= 0 {
                let minX = box.minX - gap, maxX = box.maxX + gap, minY = box.minY * aspect - gap, maxY = box.maxY * aspect + gap
                let c0 = max(0, Int((minX / cell).rounded(.down))), c1 = min(columns - 1, Int((maxX / cell).rounded(.up)) - 1)
                let r0 = max(0, Int((minY / cell).rounded(.down))), r1 = min(rows - 1, Int((maxY / cell).rounded(.up)) - 1)
                guard c0 <= c1, r0 <= r1 else { continue }
                // A difference array: one obstacle costs four writes whatever its size.
                coverage[r0 * width + c0] += 1; coverage[r0 * width + c1 + 1] -= 1
                coverage[(r1 + 1) * width + c0] -= 1; coverage[(r1 + 1) * width + c1 + 1] += 1
            }
            for r in 0..<rows { for c in 0..<columns {
                let up = r > 0 ? coverage[(r - 1) * width + c] : 0, left = c > 0 ? coverage[r * width + c - 1] : 0
                let diagonal = r > 0 && c > 0 ? coverage[(r - 1) * width + c - 1] : 0
                coverage[r * width + c] += up + left - diagonal
            } }
            table = [Int32](repeating: 0, count: (rows + 1) * width)
            for r in 0..<rows { for c in 0..<columns {
                let taken: Int32 = coverage[r * width + c] > 0 ? 1 : 0
                table[(r + 1) * width + c + 1] = taken + table[r * width + c + 1] + table[(r + 1) * width + c] - table[r * width + c]
            } }
        }

        private func taken(column: Int, row: Int, width: Int, height: Int) -> Bool {
            let stride = Self.columns + 1, c1 = column + width, r1 = row + height
            return table[r1 * stride + c1] - table[row * stride + c1] - table[r1 * stride + column] + table[row * stride + column] > 0
        }

        func search(size: CGSize, anchor: CGRect, region: CGRect) -> (rect: CGRect, score: Double)? {
            let width = Double(size.width), height = Double(size.height) * aspect
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            let span = (columns: Int((width / cell - 1e-9).rounded(.up)), rows: Int((height / cell - 1e-9).rounded(.up)))
            let first = (column: max(0, Int((region.minX / cell - 1e-9).rounded(.up))), row: max(0, Int((region.minY * aspect / cell - 1e-9).rounded(.up))))
            let last = (column: min(Self.columns, Int((region.maxX / cell + 1e-9).rounded(.down))) - span.columns,
                        row: min(rows, Int((region.maxY * aspect / cell + 1e-9).rounded(.down))) - span.rows)
            guard first.column <= last.column, first.row <= last.row else { return nil }
            let target = CGRect(x: anchor.minX, y: anchor.minY * aspect, width: anchor.width, height: anchor.height * aspect)
            var best: (column: Int, row: Int, score: Double)?
            for row in first.row...last.row {
                for column in first.column...last.column where !taken(column: column, row: row, width: span.columns, height: span.rows) {
                    let x = Double(column) * cell, y = Double(row) * cell
                    let dx = max(0, target.minX - (x + width), x - target.maxX), dy = max(0, target.minY - (y + height), y - target.maxY)
                    let centre = hypot(x + width / 2 - target.midX, y + height / 2 - target.midY)
                    let score = hypot(dx, dy) + 0.1 * centre + (y + height / 2 < target.midY ? 0.02 : 0)
                    if best.map({ score < $0.score }) ?? true { best = (column, row, score) }
                }
            }
            return best.map { (CGRect(x: Double($0.column) * cell, y: Double($0.row) * cell / aspect, width: width, height: Double(size.height)), $0.score) }
        }
    }
}

// MARK: - Inputs read off the page and the answer

extension NativeAINotePlacement {
    /// Ink strokes grouped into handwritten lines: strokes that share most of their height and sit within a few
    /// letters of each other. A line box also covers the space between its words, which single strokes leave open.
    static func handwritingLines(_ strokes: [CGRect], aspect: Double) -> [CGRect] {
        var boxes = strokes.filter { $0.width.isFinite && $0.height.isFinite && !$0.isNull }
            .map { CGRect(x: $0.minX, y: $0.minY * aspect, width: $0.width, height: $0.height * aspect) }
        for _ in 0..<4 {
            boxes.sort { $0.midY < $1.midY }
            var parent = Array(boxes.indices)
            func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
            for i in boxes.indices {
                for j in (i + 1)..<boxes.count {
                    // Sorted by centre: once centres are a tall line apart, nothing later joins `i`.
                    if boxes[j].midY - boxes[i].midY > 0.08 { break }
                    let a = boxes[i], b = boxes[j], short = max(min(a.height, b.height), 0.002), tall = max(a.height, b.height, 0.01)
                    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    let apart = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
                    // Words side by side; or a dot, accent or underline just above or below the letters it belongs to.
                    let word = overlap >= 0.4 * short && apart <= 1.5 * tall + 0.01
                    let mark = short <= 0.35 * tall && -overlap <= 0.6 * tall && apart <= 0.2 * tall
                    if word || mark { parent[root(j)] = root(i) }
                }
            }
            var merged: [Int: CGRect] = [:]
            for i in boxes.indices { let r = root(i); merged[r] = merged[r].map { $0.union(boxes[i]) } ?? boxes[i] }
            let next = merged.keys.sorted().map { merged[$0]! }
            if next.count == boxes.count { break }
            boxes = next
        }
        return boxes.map { CGRect(x: $0.minX, y: $0.minY / aspect, width: $0.width, height: $0.height / aspect) }
    }

    /// Passages the answer quotes: “…”, "…", ‘…’, 「…」, 『…』 and `>` lines, longest first. Short ones
    /// (a term in quotes) would match too much of the page to say where the answer points.
    static func quotes(in answer: String) -> [String] {
        let patterns = ["“([^”\\n]{4,300})”", "\"([^\"\\n]{4,300})\"", "‘([^’\\n]{4,300})’", "「([^」\\n]{4,300})」", "『([^』\\n]{4,300})』", "(?m)^>\\s*(.{4,300})$"]
        var found: [String] = []
        let text = answer as NSString
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: answer, range: NSRange(location: 0, length: text.length)) {
                let quote = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if quote.filter({ !$0.isWhitespace }).count >= 4, !found.contains(quote) { found.append(quote) }
            }
        }
        return found.sorted { $0.count > $1.count }
    }

    /// Where `quote` sits in `text` (UTF-16, as PDFKit's page string counts), ignoring case and all whitespace:
    /// a PDF's text breaks lines and sometimes splits or joins words where the answer quoting it does not.
    /// An answer that quotes the start of a sentence and then paraphrases still finds that start (down to 10 characters).
    static func range(of quote: String, in text: String) -> NSRange? {
        let source = text as NSString
        var squeezed = "", offsets: [Int] = []
        var index = 0
        while index < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: index)
            let piece = source.substring(with: range)
            if !piece.allSatisfy(\.isWhitespace) {
                squeezed += piece
                for _ in 0..<(piece as NSString).length { offsets.append(range.location) }
                offsets[offsets.count - 1] = NSMaxRange(range) - 1
            }
            index = NSMaxRange(range)
        }
        let needle = String(quote.filter { !$0.isWhitespace })
        guard needle.count >= 4 else { return nil }
        let haystack = squeezed as NSString
        var candidates = [needle]
        for length in [24, 16, 10] where needle.count > length { candidates.append(String(needle.prefix(length))) }
        for candidate in candidates {
            let found = haystack.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive])
            guard found.location != NSNotFound, found.length > 0 else { continue }
            let start = source.rangeOfComposedCharacterSequence(at: offsets[found.location]).location
            let end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: offsets[NSMaxRange(found) - 1]))
            return NSRange(location: start, length: end - start)
        }
        return nil
    }

    /// Printed content as boxes, from a page rendered to a small greyscale bitmap: what differs clearly from the
    /// paper colour. This catches scans and figures that have no text layer. App paper ruling (about 0.11 from
    /// white) stays below the threshold. `pixels` is row-major from the top; each `cell × cell` block that holds
    /// one such pixel is taken, and runs of taken blocks in a row become one box.
    static func contentBoxes(pixels: [UInt8], width: Int, height: Int, cell: Int = 2, threshold: Double = 0.2) -> [CGRect] {
        guard width > 0, height > 0, cell > 0, pixels.count >= width * height else { return [] }
        var histogram = [Int](repeating: 0, count: 16)
        for value in pixels.prefix(width * height) { histogram[Int(value) >> 4] += 1 }
        let paper = (Double(histogram.indices.max { histogram[$0] < histogram[$1] } ?? 15) * 16 + 8) / 255
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var boxes: [CGRect] = []
        for row in 0..<rows {
            var taken = [Bool](repeating: false, count: columns)
            for y in (row * cell)..<min(height, (row + 1) * cell) {
                for x in 0..<width where abs(Double(pixels[y * width + x]) / 255 - paper) > threshold { taken[x / cell] = true }
            }
            var column = 0
            while column < columns {
                guard taken[column] else { column += 1; continue }
                var end = column
                // A one-block hole (between letters) does not split a run.
                while end + 1 < columns, taken[end + 1] || (end + 2 < columns && taken[end + 2]) { end += 1 }
                let x0 = Double(column * cell) / Double(width), x1 = min(1, Double((end + 1) * cell) / Double(width))
                let y0 = Double(row * cell) / Double(height), y1 = min(1, Double((row + 1) * cell) / Double(height))
                boxes.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                column = end + 1
            }
        }
        return boxes
    }
}
