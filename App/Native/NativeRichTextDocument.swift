import Foundation

/// An editable projection, not a Markdown serializer. Every visible character
/// retains its original UTF-16 source range; untouched syntax stays byte exact.
struct NativeRichTextDocument {
    struct Run {
        var source: NSRange
        var visible: NSRange
        var styles: Set<String>
        var destination: String?
        var atomic: Bool = false
    }
    private struct Span { var visible: NSRange; var full: NSRange; var opening: String; var closing: String }
    private var spans: [Span] = []
    let markdown: String
    private(set) var text = ""
    private(set) var runs: [Run] = []
    init(_ markdown: String, sourceMode: Bool = false) {
        self.markdown = markdown
        if sourceMode { append(NSRange(location: 0, length: (markdown as NSString).length)); return }
        parse()
    }
    private mutating func append(_ source: NSRange, display: String? = nil, styles: Set<String> = [], destination: String? = nil, atomic: Bool = false) {
        let value = display ?? (markdown as NSString).substring(with: source)
        guard !value.isEmpty else { return }
        let range = NSRange(location: (text as NSString).length, length: (value as NSString).length)
        text += value; runs.append(Run(source: source, visible: range, styles: styles, destination: destination, atomic: atomic))
    }
    func sourceRange(for visible: NSRange) -> NSRange {
        let length = (text as NSString).length
        let lower = max(0, min(visible.location, length)), upper = min(length, lower + max(0, visible.length))
        func offset(_ position: Int, end: Bool) -> Int {
            let candidate = end ? runs.last(where: { $0.visible.location < position && NSMaxRange($0.visible) >= position }) : runs.first(where: { $0.visible.location <= position && NSMaxRange($0.visible) > position })
            if let run = candidate {
                if run.atomic { return end ? NSMaxRange(run.source) : run.source.location }
                return run.source.location + min(run.source.length, max(0, position - run.visible.location))
            }
            if let last = runs.last { return NSMaxRange(last.source) }
            return (markdown as NSString).length
        }
        // A caret always maps to one source position. In particular, position
        // zero has no preceding run and must never fall back to the document end.
        if lower == upper {
            if let preceding = runs.last(where: { NSMaxRange($0.visible) == lower && !$0.atomic }), !preceding.styles.isEmpty {
                return NSRange(location: NSMaxRange(preceding.source), length: 0)
            }
            if let run = runs.first(where: { $0.visible.location <= lower && NSMaxRange($0.visible) > lower }) {
                let position = run.atomic ? run.source.location : run.source.location + min(run.source.length, lower - run.visible.location)
                return NSRange(location: position, length: 0)
            }
            return NSRange(location: runs.last.map { NSMaxRange($0.source) } ?? (markdown as NSString).length, length: 0)
        }
        let start = offset(lower, end: false), end = offset(upper, end: true)
        return NSRange(location: start, length: max(0, end - start))
    }
    func visibleOffset(for source: Int) -> Int {
        for run in runs {
            if source < run.source.location { return run.visible.location }
            if source <= NSMaxRange(run.source) {
                if run.atomic { return source >= NSMaxRange(run.source) ? NSMaxRange(run.visible) : run.visible.location }
                return run.visible.location + min(run.visible.length, source - run.source.location)
            }
        }
        return (text as NSString).length
    }
    func replacing(_ visible: NSRange, with replacement: String) -> (markdown: String, sourceCaret: Int) {
        var range = sourceRange(for: visible)
        if replacement.contains("\n"), visible.length == 0 {
            let caret = visible.location
            let inside = spans.filter { $0.visible.location < caret && caret < NSMaxRange($0.visible) }
            if !inside.isEmpty {
                let closing = inside.sorted { NSMaxRange($0.full) < NSMaxRange($1.full) }.map(\.closing).joined()
                let opening = inside.sorted { $0.full.location < $1.full.location }.map(\.opening).joined()
                let value = closing + replacement + opening
                return ((markdown as NSString).replacingCharacters(in: range, with: value), range.location + value.utf16.count)
            }
            if let end = spans.filter({ NSMaxRange($0.visible) == caret }).map({ NSMaxRange($0.full) }).max() { range.location = end }
            else if let start = spans.filter({ $0.visible.location == caret }).map({ $0.full.location }).min() { range.location = start }
        }
        var closing = "", opening = ""
        if visible.length > 0 {
            let selectedEnd = NSMaxRange(visible)
            for span in spans where visible.location <= span.visible.location && selectedEnd >= NSMaxRange(span.visible) {
                if !replacement.isEmpty && visible == span.visible { continue }
                let start = min(range.location, span.full.location), end = max(NSMaxRange(range), NSMaxRange(span.full))
                range = NSRange(location: start, length: end - start)
            }
            closing = spans.filter { $0.visible.location < visible.location && visible.location < NSMaxRange($0.visible) && NSMaxRange($0.visible) < selectedEnd }
                .sorted { NSMaxRange($0.full) < NSMaxRange($1.full) }.map(\.closing).joined()
            opening = spans.filter { visible.location < $0.visible.location && $0.visible.location < selectedEnd && selectedEnd < NSMaxRange($0.visible) }
                .sorted { $0.full.location < $1.full.location }.map(\.opening).joined()
        }
        let inserted = replacement + closing + opening
        return ((markdown as NSString).replacingCharacters(in: range, with: inserted), range.location + (replacement as NSString).length)
    }
    /// UIKit/IME may replace several characters at once. Compute one source edit
    /// against the pre-composition projection, never reparse marked text midway.
    func incorporating(_ display: String) -> (markdown: String, sourceCaret: Int) {
        let before = Array(text.utf16), after = Array(display.utf16)
        var first = 0, last = 0
        while first < min(before.count, after.count), before[first] == after[first] { first += 1 }
        while last < min(before.count - first, after.count - first), before[before.count - last - 1] == after[after.count - last - 1] { last += 1 }
        // Do not split a surrogate pair at an edit boundary.
        if first > 0, first < before.count, (0xDC00...0xDFFF).contains(before[first]) { first -= 1 }
        if last > 0, before.count - last < before.count, (0xDC00...0xDFFF).contains(before[before.count - last]) { last -= 1 }
        let replacement = String(decoding: after[first..<(after.count - last)], as: UTF16.self)
        return replacing(NSRange(location: first, length: before.count - first - last), with: replacement)
    }
    private mutating func span(from visibleStart: Int, full: NSRange, content: NSRange) {
        let length = text.utf16.count - visibleStart
        guard length > 0 else { return }
        let source = markdown as NSString
        spans.append(Span(visible: NSRange(location: visibleStart, length: length), full: full,
                          opening: source.substring(with: NSRange(location: full.location, length: content.location - full.location)),
                          closing: source.substring(with: NSRange(location: NSMaxRange(content), length: NSMaxRange(full) - NSMaxRange(content)))))
    }
    private mutating func parse() {
        let source = markdown as NSString
        var position = 0, fence: String?, firstLine = true
        var table = false
        while position < source.length {
            let line = source.lineRange(for: NSRange(location: position, length: 0)), raw = source.substring(with: line)
            let body = raw.trimmingCharacters(in: .newlines), count = (body as NSString).length
            let range = NSRange(location: line.location, length: count)
            let newline = NSRange(location: line.location + count, length: line.length - count)
            var nextLinePosition = NSMaxRange(line)
            defer { position = nextLinePosition; firstLine = false }
            if let active = fence {
                let closing = body.trimmingCharacters(in: .whitespaces)
                if closing.count >= active.count, closing.allSatisfy({ $0 == active.first }) { fence = nil; append(newline); continue }
                append(range, styles: ["codeblock"]); append(newline, styles: ["codeblock"]); continue
            }
            if body == "$$", let end = markdown.range(of: "\n$$", range: String.Index(utf16Offset: NSMaxRange(line), in: markdown)..<markdown.endIndex) {
                let closing = NSRange(end, in: markdown), content = NSRange(location: NSMaxRange(line), length: closing.location - NSMaxRange(line))
                let whole = NSRange(location: line.location, length: NSMaxRange(closing) - line.location)
                append(whole, display: "\u{fffc}", styles: ["math"], destination: source.substring(with: content), atomic: true)
                nextLinePosition = NSMaxRange(source.lineRange(for: NSRange(location: closing.location + 1, length: 0)))
                if nextLinePosition > NSMaxRange(closing) { append(NSRange(location: NSMaxRange(closing), length: nextLinePosition - NSMaxRange(closing))) }
                continue
            }
            if firstLine, body == "---" {
                var cursor = NSMaxRange(line), ending: NSRange?
                while cursor < source.length {
                    let candidate = source.lineRange(for: NSRange(location: cursor, length: 0))
                    let value = source.substring(with: candidate).trimmingCharacters(in: .newlines)
                    if value == "---" || value == "..." { ending = candidate; break }
                    cursor = NSMaxRange(candidate)
                }
                if let ending {
                    let terminator = source.substring(with: ending).trimmingCharacters(in: .newlines).utf16.count
                    let end = ending.location + terminator
                    append(NSRange(location: line.location, length: end - line.location), display: "文 문서 속성", styles: ["metadata"], atomic: true)
                    append(NSRange(location: end, length: NSMaxRange(ending) - end))
                    nextLinePosition = NSMaxRange(ending); continue
                }
            }
            if let match = Self.match(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, body) {
                fence = (body as NSString).substring(with: match.range(at: 1))
                append(newline, styles: ["codeblock"]); continue
            }
            if body.range(of: #"^ {0,3}([-*_])(?:[ ]*\1){2,}[ ]*$"#, options: .regularExpression) != nil {
                append(range, display: "────────────────────", styles: ["rule"], atomic: true); append(newline); continue
            }
            if body.hasPrefix("<!--"), body.hasSuffix("-->") {
                append(range, display: "문서 메타데이터", styles: ["metadata"], atomic: true); append(newline); continue
            }
            if body.contains("|"), body.range(of: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, options: .regularExpression) != nil { table = true; continue }
            let nextPosition = NSMaxRange(line)
            let nextLine = nextPosition < source.length ? source.substring(with: source.lineRange(for: NSRange(location: nextPosition, length: 0))) : ""
            if body.contains("|"), table || nextLine.range(of: #"^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil {
                let cells = NativeRichTextTable.cellRanges(body)
                let tableStyles: Set<String> = !table ? ["table", "tableheader"] : ["table"]
                for (index, cell) in cells.enumerated() {
                    inline(NSRange(location: range.location + cell.location, length: cell.length), styles: tableStyles)
                    if index + 1 < cells.count {
                        let separator = range.location + NSMaxRange(cell)
                        append(NSRange(location: separator, length: cells[index + 1].location - NSMaxRange(cell)), display: "\t", styles: tableStyles, atomic: true)
                    }
                }
                append(newline, styles: tableStyles); continue
            }
            table = false
            var content = range, styles = Set<String>()
            if let heading = Self.match(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#, body) {
                content.location += heading.range.length; content.length -= heading.range.length
                styles.insert("h\(heading.range(at: 1).length)")
            } else if let task = Self.match(#"^(\s*)[-+*] \[([ xX])\][ \t]+"#, body) {
                let checked = (body as NSString).substring(with: task.range(at: 2)).lowercased() == "x"
                append(NSRange(location: range.location, length: task.range.length), display: checked ? "☑ " : "☐ ", styles: [checked ? "checked" : "task"], atomic: true)
                content.location += task.range.length; content.length -= task.range.length; styles.insert("list")
            } else if let list = Self.match(#"^(\s*)([-+*]|\d+[.)])[ \t]+"#, body) {
                let marker = (body as NSString).substring(with: list.range(at: 2))
                append(NSRange(location: range.location, length: list.range.length), display: marker.first?.isNumber == true ? marker + " " : "• ", styles: ["listmarker"], atomic: true)
                content.location += list.range.length; content.length -= list.range.length; styles.insert("list")
            } else if let quote = Self.match(#"^ {0,3}>[ ]?(?:\[!([A-Za-z]+)\][-+]?[ ]?)?"#, body) {
                content.location += quote.range.length; content.length -= quote.range.length; styles.insert("quote")
                if quote.range(at: 1).location != NSNotFound {
                    let name = (body as NSString).substring(with: quote.range(at: 1))
                    append(NSRange(location: range.location, length: quote.range.length), display: "◈ " + name.capitalized + "  ", styles: ["callout"], atomic: true)
                }
            } else if body.hasPrefix("    ") || body.hasPrefix("\t") {
                append(range, styles: ["codeblock"]); append(newline, styles: ["codeblock"]); continue
            }
            inline(content, styles: styles); append(newline, styles: styles)
        }
    }
    private mutating func inline(_ range: NSRange, styles: Set<String> = [], depth: Int = 0) {
        guard range.length > 0 else { return }
        guard depth < 12 else { append(range, styles: styles); return }
        let source = markdown as NSString
        var index = range.location, plain = index
        func substring(_ location: Int, _ length: Int) -> String { source.substring(with: NSRange(location: location, length: length)) }
        while index < NSMaxRange(range) {
            let remaining = source.substring(with: NSRange(location: index, length: NSMaxRange(range) - index))
            if remaining.hasPrefix("\\"), index + 1 < NSMaxRange(range), "\\`*{}[]()#+-.!_>|~".contains(substring(index + 1, 1)) {
                append(NSRange(location: plain, length: index - plain), styles: styles)
                append(NSRange(location: index, length: 2), display: substring(index + 1, 1), styles: styles, atomic: true); index += 2; plain = index; continue
            }
            if remaining.hasPrefix("`") {
                let width = remaining.prefix(while: { $0 == "`" }).count
                var cursor = index + width
                var closing: Int?
                while cursor < NSMaxRange(range) {
                    if source.character(at: cursor) == 96 {
                        var end = cursor
                        while end < NSMaxRange(range), source.character(at: end) == 96 { end += 1 }
                        if end - cursor == width { closing = cursor; break }; cursor = end
                    } else { cursor += 1 }
                }
                if let closing {
                    append(NSRange(location: plain, length: index - plain), styles: styles)
                    var content = NSRange(location: index + width, length: closing - index - width)
                    let raw = source.substring(with: content)
                    if raw.hasPrefix(" "), raw.hasSuffix(" "), !raw.trimmingCharacters(in: .whitespaces).isEmpty { content.location += 1; content.length -= 2 }
                    let visibleStart = text.utf16.count
                    append(content, styles: styles.union(["code"]))
                    span(from: visibleStart, full: NSRange(location: index, length: closing + width - index), content: content)
                    index = closing + width; plain = index; continue
                }
                index += width; continue
            }
            if let wiki = Self.match(#"^!?\[\[([^\]\n]+)\]\]"#, remaining) {
                let token = (remaining as NSString).substring(with: wiki.range(at: 1)), pieces = token.components(separatedBy: "|")
                append(NSRange(location: plain, length: index - plain), styles: styles)
                append(NSRange(location: index, length: wiki.range.length), display: pieces.last ?? token, styles: styles.union(["wikilink"]), destination: "bandal-wiki:" + (pieces.first ?? token), atomic: true)
                index += wiki.range.length; plain = index; continue
            }
            if let link = Self.match(#"^(!?)\[([^\]\n]*)\]\(([^\s)]+)(?:\s+\"[^\"]*\")?\)"#, remaining) {
                append(NSRange(location: plain, length: index - plain), styles: styles)
                let href = (remaining as NSString).substring(with: link.range(at: 3))
                if link.range(at: 1).length > 0 {
                    append(NSRange(location: index, length: link.range.length), display: "\u{fffc}", styles: styles.union(["image"]), destination: href, atomic: true)
                } else {
                    let label = link.range(at: 2)
                    let firstRun = runs.count, visibleStart = text.utf16.count
                    let content = NSRange(location: index + label.location, length: label.length)
                    inline(content, styles: styles.union(["link"]), depth: depth + 1)
                    for item in firstRun..<runs.count { runs[item].destination = href }
                    span(from: visibleStart, full: NSRange(location: index, length: link.range.length), content: content)
                }
                index += link.range.length; plain = index; continue
            }
            if remaining.hasPrefix("$"), !remaining.hasPrefix("$$"), let end = String(remaining.dropFirst()).firstIndex(of: "$"), !String(remaining.dropFirst())[..<end].contains("\n") {
                let formula = String(String(remaining.dropFirst())[..<end])
                if !formula.isEmpty {
                    append(NSRange(location: plain, length: index - plain), styles: styles)
                    let length = formula.utf16.count + 2
                    append(NSRange(location: index, length: length), display: "\u{fffc}", styles: styles.union(["math"]), destination: formula, atomic: true)
                    index += length; plain = index; continue
                }
            }
            var consumed = false
            for (marker, kind) in [("***", "bolditalic"), ("**", "bold"), ("__", "bold"), ("~~", "strike"), ("*", "italic"), ("_", "italic")] where remaining.hasPrefix(marker) {
                let width = marker.utf16.count
                guard Self.delimiterCanOpen(marker, at: index, source: source) else { continue }
                var search = index + width, closing: Int?
                while search < NSMaxRange(range) {
                    let match = source.range(of: marker, options: [], range: NSRange(location: search, length: NSMaxRange(range) - search))
                    if match.location == NSNotFound { break }
                    var slashes = 0, previous = match.location - 1
                    while previous >= 0 && source.character(at: previous) == 92 { slashes += 1; previous -= 1 }
                    if slashes % 2 == 0, Self.delimiterCanClose(marker, at: match.location, source: source) { closing = match.location; break }
                    search = NSMaxRange(match)
                }
                guard let closing, closing > index + width, !source.substring(with: NSRange(location: index + width, length: closing - index - width)).contains("\n") else { continue }
                let bodyLength = closing - index - width
                append(NSRange(location: plain, length: index - plain), styles: styles)
                let content = NSRange(location: index + width, length: bodyLength), visibleStart = text.utf16.count
                if kind == "code" || kind == "math" { append(content, styles: styles.union([kind])) }
                else { inline(content, styles: styles.union([kind]), depth: depth + 1) }
                span(from: visibleStart, full: NSRange(location: index, length: width * 2 + bodyLength), content: content)
                index += width * 2 + bodyLength; plain = index; consumed = true; break
            }
            if !consumed { index += 1 }
        }
        append(NSRange(location: plain, length: NSMaxRange(range) - plain), styles: styles)
    }
    private static func flanking(_ marker: String, at index: Int, source: NSString) -> (left: Bool, right: Bool, previousPunctuation: Bool, nextPunctuation: Bool) {
        let end = index + marker.utf16.count
        func classifications(_ position: Int) -> (space: Bool, punctuation: Bool) {
            guard position >= 0, position < source.length else { return (true, false) }
            var start = position, length = 1
            let unit = source.character(at: position)
            if (0xDC00...0xDFFF).contains(unit), position > 0 { start -= 1; length = 2 }
            else if (0xD800...0xDBFF).contains(unit), position + 1 < source.length { length = 2 }
            guard let scalar = source.substring(with: NSRange(location: start, length: length)).unicodeScalars.first else { return (false, false) }
            return (CharacterSet.whitespacesAndNewlines.contains(scalar), CharacterSet.punctuationCharacters.union(.symbols).contains(scalar))
        }
        let before = classifications(index - 1), after = classifications(end)
        let left = !after.space && (!after.punctuation || before.space || before.punctuation)
        let right = !before.space && (!before.punctuation || after.space || after.punctuation)
        return (left, right, before.punctuation, after.punctuation)
    }
    private static func delimiterCanOpen(_ marker: String, at index: Int, source: NSString) -> Bool {
        let f = flanking(marker, at: index, source: source)
        return f.left && (!marker.hasPrefix("_") || !f.right || f.previousPunctuation)
    }
    private static func delimiterCanClose(_ marker: String, at index: Int, source: NSString) -> Bool {
        let f = flanking(marker, at: index, source: source)
        return f.right && (!marker.hasPrefix("_") || !f.left || f.nextPunctuation)
    }
    private static func match(_ pattern: String, _ value: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length))
    }
}

/// Replace one page body without serializing its manifest or other sections.
/// Future manifest fields, fingerprint spelling and removed-page appendix are
/// retained byte-for-byte when the rich editor edits ordinary page content.
enum NativeMarkdownPageProjection {
    static func replacing(in markdown: String, page: Int, appendix: Bool, text: String) -> String? {
        guard markdown.hasPrefix("<!-- bandal:pdf-page-note "),
              let regex = try? NSRegularExpression(pattern: #"^<!-- bandal:page (\d+) -->[ \t]*$"#, options: .anchorsMatchLines) else { return nil }
        let source = markdown as NSString, matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        guard matches.indices.contains(page), matches.enumerated().allSatisfy({ Int(source.substring(with: $0.element.range(at: 1))) == $0.offset + 1 }) else { return nil }
        let marker = "<!-- bandal:appendix -->", appendixRange = source.range(of: marker)
        let clean = NativePDFPageNoteDocument.safeContent(text)
        if appendix {
            if appendixRange.location == NSNotFound { return markdown + (clean.isEmpty ? "" : "\n" + marker + "\n\n" + clean + "\n") }
            return source.replacingCharacters(in: NSRange(location: NSMaxRange(appendixRange), length: source.length - NSMaxRange(appendixRange)), with: "\n\n" + clean + "\n")
        }
        let start = NSMaxRange(matches[page].range)
        let end = page + 1 < matches.count ? matches[page + 1].range.location : appendixRange.location == NSNotFound ? source.length : appendixRange.location
        guard end >= start else { return nil }
        return source.replacingCharacters(in: NSRange(location: start, length: end - start), with: (clean.isEmpty ? "\n\n" : "\n\n" + clean + (end < source.length ? "\n\n" : "\n")))
    }
}
