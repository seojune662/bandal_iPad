import Foundation

/// The Markdown of an AI answer, as blocks to draw.
///
/// Read-only, unlike `NativeRichTextDocument` (the note editor's projection, which keeps every
/// character's source range for editing). It covers what chat answers use — headings, lists,
/// tables, fenced code, quotes, rules and TeX — and tolerates a half-written answer: with
/// `streaming` the last line may still be cut short, so markup that has not finished yet waits
/// instead of flashing as raw text and turning into something else a moment later.
enum NativeAnswerMarkdown {
    enum Alignment: Equatable { case leading, center, trailing }
    enum Block: Equatable {
        /// Inline Markdown, still to be read by `inlines(_:tail:)`; likewise for paragraphs and cells.
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, start: Int, items: [Item])
        case code(language: String, code: String)
        case quote([Block])
        case table(header: [String], alignments: [Alignment], rows: [[String]])
        /// Display TeX, without its `$$` or `\[ \]`.
        case math(String)
        case rule
    }
    struct Item: Equatable {
        /// `nil` for an ordinary item; a task item is `false` until it is ticked.
        var checked: Bool?
        var blocks: [Block]
    }
    /// One stretch of a paragraph with a single look.
    struct Inline: Equatable {
        var text: String
        var bold = false, italic = false, strike = false, code = false
        /// `text` is TeX to typeset in the line.
        var math = false
        /// The destination; empty while a streaming link's address is still arriving.
        var link: String?
    }

    /// The blocks of `text`, each with the UTF-8 offset of its first line.
    static func parsed(_ text: Substring, streaming: Bool = false) -> [(block: Block, offset: Int)] {
        var lines: [Substring] = [], offsets: [Int] = []
        var lineStart = text.startIndex, lineOffset = 0, position = 0
        var index = text.utf8.startIndex
        while index != text.utf8.endIndex {
            let next = text.utf8.index(after: index)
            if text.utf8[index] == 10 {
                lines.append(text[lineStart..<index]); offsets.append(lineOffset)
                lineStart = next; lineOffset = position + 1
            }
            position += 1; index = next
        }
        lines.append(text[lineStart...]); offsets.append(lineOffset)
        return blocks(lines, streaming: streaming).map { ($0.block, offsets[$0.line]) }
    }
    static func parse(_ text: String, streaming: Bool = false) -> [Block] { parsed(Substring(normalized(text)), streaming: streaming).map(\.block) }
    /// `\r\n` and `\r` as `\n`, so a line always ends at one byte.
    static func normalized(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Blocks

    private static func blocks(_ lines: [Substring], streaming: Bool) -> [(block: Block, line: Int)] {
        var out: [(block: Block, line: Int)] = []
        var paragraph: [Substring] = [], paragraphLine = 0
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append((.paragraph(paragraph.map(trimmed).joined(separator: "\n")), paragraphLine)); paragraph = []
        }
        let last = lines.count - 1
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { flush(); i += 1; continue }
            let rest = indentation(line).rest, tail = streaming && i == last
            // A header row comes before its separator, which may still be arriving.
            if rest.contains("|"), let table = table(lines, at: i, streaming: streaming) { flush(); out.append((table.block, i)); i = table.next; continue }
            if tail && pendingMarkup(rest) { break }
            if let fence = fence(rest) {
                flush()
                let code = code(lines, at: i, fence: fence, indent: indentation(line).width, streaming: streaming)
                if let block = code.block { out.append((block, i)) }
                i = code.next; continue
            }
            if rest.hasPrefix("$$") || rest.hasPrefix("\\["), let math = displayMath(lines, at: i, streaming: streaming) {
                flush()
                if let block = math.block { out.append((block, i)) }
                i = math.next; continue
            }
            if let heading = heading(rest) { flush(); out.append((heading, i)); i += 1; continue }
            if isRule(rest) { flush(); out.append((.rule, i)); i += 1; continue }
            if rest.hasPrefix(">") {
                flush()
                var inner: [Substring] = [], j = i
                while j < lines.count, indentation(lines[j]).width < 4, case let quoted = indentation(lines[j]).rest, quoted.hasPrefix(">") {
                    var body = quoted.dropFirst(); if body.first == " " { body = body.dropFirst() }
                    inner.append(body); j += 1
                }
                let content = blocks(inner, streaming: streaming && j == lines.count).map(\.block)
                if !content.isEmpty { out.append((.quote(content), i)) }
                i = j; continue
            }
            // Inside a paragraph only a bullet or "1." starts a list: "2024. 11월" stays text.
            if let marker = listMarker(line), paragraph.isEmpty || (!marker.ordered || marker.number == 1) && !isBlank(marker.content) {
                flush()
                let list = list(lines, at: i, first: marker, streaming: streaming)
                if let block = list.block { out.append((block, i)) }
                i = list.next; continue
            }
            if paragraph.isEmpty { paragraphLine = i }
            paragraph.append(rest); i += 1
        }
        flush()
        return out
    }

    /// A last line that is markup alone so far ("#", "-", "|", "```", "1.", "$$") could still become
    /// anything; it is left out until there is more of it.
    private static func pendingMarkup(_ rest: Substring) -> Bool {
        let value = rest.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        if value.unicodeScalars.allSatisfy({ "#*-_+=~`>|$\\:".unicodeScalars.contains($0) || $0 == " " || $0 == "\t" }) { return true }
        let digits = value.prefix(while: \.isASCIIDigit)
        return !digits.isEmpty && digits.count <= 9 && (value.count == digits.count || value.count == digits.count + 1 && (value.last == "." || value.last == ")"))
    }
    private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    private static func trimmed(_ line: Substring) -> String { line.trimmingCharacters(in: .whitespaces) }
    /// Columns of leading space (a tab is four) and what follows them.
    private static func indentation(_ line: Substring) -> (width: Int, rest: Substring) {
        var width = 0, index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            width += line[index] == "\t" ? 4 : 1; index = line.index(after: index)
        }
        return (width, line[index...])
    }
    /// `line` without up to `width` columns of its leading space.
    private static func dedented(_ line: Substring, _ width: Int) -> Substring {
        var removed = 0, index = line.startIndex
        while removed < width, index < line.endIndex, line[index] == " " || line[index] == "\t" {
            removed += line[index] == "\t" ? 4 : 1; index = line.index(after: index)
        }
        return line[index...]
    }
    private static func startsBlock(_ rest: Substring) -> Bool {
        fence(rest) != nil || heading(rest) != nil || isRule(rest) || rest.hasPrefix(">") || rest.hasPrefix("$$") || rest.hasPrefix("\\[")
    }

    private static func heading(_ rest: Substring) -> Block? {
        let hashes = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // "## Title ##": the closing hashes are not part of it.
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) { text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return .heading(level: hashes, text: text)
    }
    private static func isRule(_ rest: Substring) -> Bool {
        guard let first = rest.first, "-*_".contains(first) else { return false }
        var count = 0
        for character in rest {
            if character == first { count += 1 } else if character != " " && character != "\t" { return false }
        }
        return count >= 3
    }

    // MARK: Code and display math

    private struct Fence { let character: Character; let count: Int; let info: String }
    private static func fence(_ rest: Substring) -> Fence? {
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let count = rest.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return Fence(character: first, count: count, info: String(info.split(separator: " ").first ?? ""))
    }
    private static func code(_ lines: [Substring], at start: Int, fence: Fence, indent: Int, streaming: Bool) -> (block: Block?, next: Int) {
        let last = lines.count - 1
        // The opening line is still arriving: its language may be cut short.
        if streaming && start == last { return (nil, lines.count) }
        var body: [Substring] = [], j = start + 1
        while j < lines.count {
            let rest = indentation(lines[j]).rest.trimmingCharacters(in: .whitespaces)
            if rest.count >= fence.count, rest.allSatisfy({ $0 == fence.character }) {
                return (.code(language: fence.info, code: body.joined(separator: "\n")), j + 1)
            }
            // The closing fence half typed, or the next line not begun.
            if streaming && j == last, rest.allSatisfy({ $0 == fence.character }) { break }
            body.append(dedented(lines[j], indent)); j += 1
        }
        // Unclosed: CommonMark runs it to the end, which is also where a streaming block is.
        return (.code(language: fence.info, code: body.joined(separator: "\n")), lines.count)
    }
    /// `nil` when the line is a paragraph that begins with an inline formula ("$$x$$ 이므로").
    private static func displayMath(_ lines: [Substring], at start: Int, streaming: Bool) -> (block: Block?, next: Int)? {
        let rest = indentation(lines[start]).rest
        let (opening, closing) = rest.hasPrefix("$$") ? ("$$", "$$") : ("\\[", "\\]")
        var first = rest.dropFirst(opening.count)
        if let end = first.range(of: closing) {
            guard isBlank(first[end.upperBound...]) else { return nil }
            return (.math(first[..<end.lowerBound].trimmingCharacters(in: .whitespaces)), start + 1)
        }
        if first.trimmingCharacters(in: .whitespaces).isEmpty { first = "" }
        var body: [Substring] = first.isEmpty ? [] : [first], j = start + 1
        while j < lines.count {
            if let end = lines[j].range(of: closing) {
                let before = lines[j][..<end.lowerBound]
                if !isBlank(before) { body.append(before) }
                return (.math(body.map(trimmed).joined(separator: "\n")), j + 1)
            }
            body.append(lines[j]); j += 1
        }
        // A formula typeset half way is wrong, not partial: it shows once it is closed.
        if streaming { return (nil, lines.count) }
        return (.math(body.map(trimmed).joined(separator: "\n")), lines.count)
    }

    // MARK: Lists

    private struct Marker {
        let indent: Int, ordered: Bool, number: Int
        /// The column the item's text starts at; its continuation lines are indented as far.
        let contentIndent: Int
        let content: Substring
    }
    private static func listMarker(_ line: Substring) -> Marker? {
        let (indent, rest) = indentation(line)
        guard let first = rest.first else { return nil }
        var width: Int, ordered = false, number = 1
        if "-+*".contains(first) { width = 1 }
        else {
            let digits = rest.prefix(while: \.isASCIIDigit)
            guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            width = digits.count + 1; ordered = true; number = Int(digits) ?? 1
        }
        let after = rest.dropFirst(width)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        let spaces = after.prefix(while: { $0 == " " || $0 == "\t" }).count
        let content = after.dropFirst(spaces)
        let gap = content.isEmpty || spaces > 4 ? 1 : spaces
        return Marker(indent: indent, ordered: ordered, number: number, contentIndent: indent + width + gap, content: spaces > 4 ? after.dropFirst(1) : content)
    }
    private static func list(_ lines: [Substring], at start: Int, first: Marker, streaming: Bool) -> (block: Block?, next: Int) {
        let last = lines.count - 1
        var items: [Item] = [], j = start, marker = first
        while true {
            var content: [Substring] = [marker.content]
            var k = j + 1, end = j + 1
            while k < lines.count {
                let line = lines[k]
                if isBlank(line) { k += 1; continue }
                let (indent, rest) = indentation(line), gap = k > end
                if streaming && k == last && pendingMarkup(rest) { break }
                let nested = listMarker(line)
                var belongs = indent >= marker.contentIndent
                // Chat answers nest by two spaces under "1." as often as by three.
                if !belongs, let nested { belongs = nested.indent > marker.indent }
                // A lazy continuation line of the item's paragraph.
                if !belongs, nested == nil, !gap, !startsBlock(rest) { belongs = true }
                guard belongs else { break }
                content.append(contentsOf: Array(repeating: Substring(""), count: k - end))
                content.append(indent >= marker.contentIndent || nested != nil ? dedented(line, min(indent, marker.contentIndent)) : rest)
                k += 1; end = k
            }
            var checked: Bool?
            let reachesEnd = end == lines.count
            // "[", "[x": a task box still being typed would flash its letter as text.
            if streaming && reachesEnd, content.count == 1, ["[", "[ ", "[x", "[X"].contains(String(content[0])) { content = [] }
            if let box = content.first, box.hasPrefix("[ ]") || box.hasPrefix("[x]") || box.hasPrefix("[X]"), box.count == 3 || box.dropFirst(3).first == " " {
                checked = box.dropFirst(1).first != " "
                content[0] = box.dropFirst(3).drop(while: { $0 == " " })
            }
            let blocks = blocks(content, streaming: streaming && reachesEnd).map(\.block)
            // A streaming item with nothing in it yet is its marker alone.
            if !(streaming && reachesEnd && blocks.isEmpty && checked == nil) { items.append(Item(checked: checked, blocks: blocks)) }
            var n = end
            while n < lines.count, isBlank(lines[n]) { n += 1 }
            guard n < lines.count, !(streaming && n == last && pendingMarkup(indentation(lines[n]).rest)),
                  let next = listMarker(lines[n]), next.ordered == first.ordered, next.indent <= marker.indent else {
                return (items.isEmpty ? nil : .list(ordered: first.ordered, start: first.number, items: items), end)
            }
            j = n; marker = next
        }
    }

    // MARK: Tables

    private static func table(_ lines: [Substring], at start: Int, streaming: Bool) -> (block: Block, next: Int)? {
        let header = cells(lines[start])
        guard !header.isEmpty, header.contains(where: { !$0.isEmpty }) else { return nil }
        let last = lines.count - 1
        var alignments: [Alignment] = [], next = start + 1
        if start < last, isSeparator(lines[start + 1], partial: streaming && start + 1 == last) {
            alignments = cells(lines[start + 1]).map { cell in
                cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .trailing) : .leading
            }
            next = start + 2
        } else if !(streaming && (start == last || start + 1 == last && isBlank(lines[last])) && indentation(lines[start]).rest.hasPrefix("|")) { return nil }
        var rows: [[String]] = []
        while next < lines.count, !isBlank(lines[next]), lines[next].contains("|") {
            let row = cells(lines[next])
            // A row whose first cell has not started yet.
            if streaming && next == last && row.allSatisfy(\.isEmpty) { next += 1; break }
            rows.append(fitted(row, header.count, "")); next += 1
        }
        return (.table(header: header, alignments: fitted(alignments, header.count, .leading), rows: rows), next)
    }
    private static func fitted<T>(_ values: [T], _ count: Int, _ filler: T) -> [T] {
        values.count >= count ? Array(values.prefix(count)) : values + Array(repeating: filler, count: count - values.count)
    }
    private static func isSeparator(_ line: Substring, partial: Bool) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("|"), value.allSatisfy({ "|:- \t".contains($0) }) else { return false }
        if partial { return true }
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { $0.contains("-") }
    }
    /// The cells of a row: split at each `|` that is not escaped or in code.
    static func cells(_ line: Substring) -> [String] {
        let value = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = [], current = "", escaped = false, code = false, endsWithPipe = false
        for character in value {
            endsWithPipe = false
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; current.append(character); continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { cells.append(current); current = ""; endsWithPipe = true; continue }
            current.append(character)
        }
        cells.append(current)
        if value.hasPrefix("|") { cells.removeFirst() }
        if endsWithPipe, !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: Inline

extension NativeAnswerMarkdown {
    /// The runs of one paragraph, heading or cell. With `tail` the source is the end of a streaming
    /// answer: emphasis or code still open there runs to the end, and a link, formula or lone marker
    /// that has not finished waits.
    static func inlines(_ source: String, tail: Bool = false) -> [Inline] {
        let parser = InlineParser(scalars: Array(source.unicodeScalars), tail: tail)
        var merged: [Inline] = []
        for run in parser.parse(0..<parser.scalars.count, Inline(text: ""), depth: 0) where !run.text.isEmpty {
            if var previous = merged.last, !previous.math, !run.math, previous.sameLook(run) {
                previous.text += run.text; merged[merged.count - 1] = previous
            } else { merged.append(run) }
        }
        return merged
    }
    /// The destination a tapped link may open: a web page, or mail and phone. Anything else is drawn as text.
    static func destination(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        if value.lowercased().hasPrefix("www.") { value = "https://" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        if scheme.hasPrefix("http"), url.host?.isEmpty != false { return nil }
        return value
    }
}

private extension NativeAnswerMarkdown.Inline {
    func sameLook(_ other: Self) -> Bool { bold == other.bold && italic == other.italic && strike == other.strike && code == other.code && link == other.link }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private struct InlineParser {
    typealias Inline = NativeAnswerMarkdown.Inline
    let scalars: [Unicode.Scalar]
    let tail: Bool

    func parse(_ range: Range<Int>, _ style: Inline, depth: Int) -> [Inline] {
        let s = scalars
        var out: [Inline] = [], buffer = String.UnicodeScalarView()
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = style; run.text = String(buffer); out.append(run); buffer = .init()
        }
        func emit(_ text: String, _ change: (inout Inline) -> Void) {
            flush(); var run = style; run.text = text; change(&run); out.append(run)
        }
        func string(_ range: Range<Int>) -> String { var view = String.UnicodeScalarView(); view.append(contentsOf: s[range]); return String(view) }
        let end = range.upperBound
        // Only the stretch that reaches the end of a streaming answer is still being written.
        let open = tail && end == s.count
        var i = range.lowerBound
        while i < end {
            let c = s[i]
            switch c {
            case "\\":
                if open && i + 1 == end { flush(); i = end; continue }
                if i + 1 < end {
                    let next = s[i + 1]
                    if next == "(" || next == "[" {
                        let closer: Unicode.Scalar = next == "(" ? ")" : "]"
                        // "\\[주의\\]" is escaped brackets, not a formula.
                        if let j = find(["\\", closer], from: i + 2, end), j > i + 2, next == "(" || !(i + 2..<j).contains(where: { isHangul(s[$0]) }) {
                            emit(string(i + 2..<j).trimmingCharacters(in: .whitespaces)) { $0.math = true }; i = j + 2; continue
                        }
                        if open { flush(); i = end; continue }
                    }
                    if "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(next) {
                        buffer.append(next); i += 2; continue
                    }
                }
                buffer.append(c); i += 1
            case "`":
                let n = run(c, at: i, end)
                if open && i + n == end { flush(); i = end; continue }
                if let j = closingBackticks(n, from: i + n, end) {
                    var code = string(i + n..<j).replacingOccurrences(of: "\n", with: " ")
                    if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) { code = String(code.dropFirst().dropLast()) }
                    emit(code) { $0.code = true }; i = j + n; continue
                }
                if open { if i + n < end { emit(string(i + n..<end)) { $0.code = true } } else { flush() }; i = end; continue }
                buffer.append(contentsOf: s[i..<i + n]); i += n
            case "$":
                if i + 1 < end, s[i + 1] == "$" {
                    if let j = find(["$", "$"], from: i + 2, end), j > i + 2 { emit(string(i + 2..<j).trimmingCharacters(in: .whitespaces)) { $0.math = true }; i = j + 2; continue }
                    if open { flush(); i = end; continue }
                    buffer.append(contentsOf: s[i..<i + 2]); i += 2; continue
                }
                if open && i + 1 == end { flush(); i = end; continue }
                let opens = i + 1 < end && !isSpace(s[i + 1])
                if opens, let j = closingDollar(from: i + 1, end) { emit(string(i + 1..<j)) { $0.math = true }; i = j + 1; continue }
                // "$5 and $10" is money; a short tail with no Hangul may still be a formula.
                if open, opens, end - i <= 80, !(i + 1..<end).contains(where: { isHangul(s[$0]) }) { flush(); i = end; continue }
                buffer.append(c); i += 1
            case "!" where i + 1 < end && s[i + 1] == "[":
                if let link = link(at: i + 1, end) {
                    let alt = string(link.label)
                    emit(alt.isEmpty ? string(link.destination) : alt) { $0.link = NativeAnswerMarkdown.destination(string(link.destination)) }
                    i = link.next; continue
                }
                buffer.append(c); i += 1
            case "[":
                if let link = link(at: i, end) {
                    flush()
                    var inner = style; inner.link = NativeAnswerMarkdown.destination(string(link.destination))
                    out += parse(link.label, inner, depth: depth + 1)
                    i = link.next; continue
                }
                if open, let partial = partialLink(at: i, end) {
                    flush()
                    var inner = style; if partial.addressing { inner.link = "" }
                    out += parse(partial.label, inner, depth: depth + 1)
                    i = end; continue
                }
                buffer.append(c); i += 1
            case "<":
                if let j = find([">"], from: i + 1, end), j - i < 2_048, case let inside = string(i + 1..<j), !inside.contains(" ") || inside.lowercased().hasPrefix("br") {
                    let lower = inside.lowercased()
                    if ["br", "br/", "br /"].contains(lower) { buffer.append("\n"); i = j + 1; continue }
                    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:"), let destination = NativeAnswerMarkdown.destination(inside) {
                        emit(lower.hasPrefix("mailto:") ? String(inside.dropFirst(7)) : inside) { $0.link = destination }; i = j + 1; continue
                    }
                }
                buffer.append(c); i += 1
            case "h" where style.link == nil && (i == 0 || !isWord(s[i - 1])):
                if let j = bareURL(at: i, end), let destination = NativeAnswerMarkdown.destination(string(i..<j)) {
                    emit(string(i..<j)) { $0.link = destination }; i = j; continue
                }
                buffer.append(c); i += 1
            case "*", "_", "~":
                let n = run(c, at: i, end)
                if open && i + n == end { flush(); i = end; continue }
                let after: Unicode.Scalar? = i + n < s.count ? s[i + n] : nil
                let before: Unicode.Scalar? = i > 0 ? s[i - 1] : nil
                // Lenient for Korean: "**반달(Bandal)**은" closes although CommonMark would not.
                let opens = depth < 8 && n <= 3 && after.map { !isSpace($0) } == true && (c != "_" || before.map { !isWord($0) } != false) && (c != "~" || n == 2)
                if opens {
                    var inner = style
                    if c == "~" { inner.strike = true } else { if n != 2 { inner.italic = true }; if n >= 2 { inner.bold = true } }
                    if let j = closer(c, n, from: i + n, end) {
                        flush(); out += parse(i + n..<j, inner, depth: depth + 1); i = j + n; continue
                    }
                    if open { flush(); out += parse(i + n..<end, inner, depth: depth + 1); i = end; continue }
                }
                buffer.append(contentsOf: s[i..<i + n]); i += n
            default:
                buffer.append(c); i += 1
            }
        }
        flush()
        return out
    }

    private func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    private func isWord(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || ("0"..."9").contains(c) }
    private func isHangul(_ c: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(c.value) || (0x1100...0x11FF).contains(c.value) || (0x3130...0x318F).contains(c.value) }
    private func run(_ c: Unicode.Scalar, at i: Int, _ end: Int) -> Int {
        var j = i; while j < end, scalars[j] == c { j += 1 }; return j - i
    }
    private func find(_ needle: [Unicode.Scalar], from start: Int, _ end: Int) -> Int? {
        guard needle.count <= end - start else { return nil }
        var j = start
        while j + needle.count <= end {
            if scalars[j] == "\\" && needle.first != "\\" { j += 2; continue }
            if scalars[j..<j + needle.count].elementsEqual(needle) { return j }
            j += 1
        }
        return nil
    }
    private func closingBackticks(_ n: Int, from start: Int, _ end: Int) -> Int? {
        var j = start
        while j < end {
            if scalars[j] == "`" { let m = run("`", at: j, end); if m == n { return j }; j += m } else { j += 1 }
        }
        return nil
    }
    /// Pandoc's rule: the closing `$` follows a non-space and is not followed by a digit.
    private func closingDollar(from start: Int, _ end: Int) -> Int? {
        var j = start
        while j < end {
            let c = scalars[j]
            if c == "\n" { return nil }
            if c == "\\" { j += 2; continue }
            if c == "$", j > start, !isSpace(scalars[j - 1]), !(j + 1 < end && ("0"..."9").contains(scalars[j + 1])) { return j }
            j += 1
        }
        return nil
    }
    /// A run of `c` that can close `width` of them on the same line, skipping code and escapes.
    /// A longer run closes with its last `width` when no exact one does ("*a **b***").
    private func closer(_ c: Unicode.Scalar, _ width: Int, from start: Int, _ end: Int) -> Int? {
        var j = start, fallback: Int?
        while j < end {
            let x = scalars[j]
            if x == "\n" { break }
            if x == "\\" { j += 2; continue }
            if x == "`" {
                let m = run("`", at: j, end)
                if let close = closingBackticks(m, from: j + m, end) { j = close + m } else { j += m }
                continue
            }
            if x == c {
                let m = run(c, at: j, end)
                let after: Unicode.Scalar? = j + m < scalars.count ? scalars[j + m] : nil
                if j > start, !isSpace(scalars[j - 1]), c != "_" || after.map({ !isWord($0) }) != false {
                    if m == width { return j }
                    if m > width, fallback == nil { fallback = j + m - width }
                }
                j += m; continue
            }
            j += 1
        }
        return fallback
    }
    private struct Link { let label: Range<Int>; let destination: Range<Int>; let next: Int }
    /// `[label](destination "title")` starting at the `[` at `i`.
    private func link(at i: Int, _ end: Int) -> Link? {
        guard let close = labelEnd(from: i + 1, end), close + 1 < end, scalars[close + 1] == "(" else { return nil }
        var k = close + 2
        while k < end, scalars[k] == " " { k += 1 }
        let start: Int, stop: Int
        if k < end, scalars[k] == "<" {
            guard let j = find([">"], from: k + 1, end) else { return nil }
            start = k + 1; stop = j; k = j + 1
        } else {
            start = k
            var depth = 0
            while k < end, !isSpace(scalars[k]) {
                if scalars[k] == "\\" { k += 2; continue }
                if scalars[k] == "(" { depth += 1 } else if scalars[k] == ")" { if depth == 0 { break }; depth -= 1 }
                k += 1
            }
            stop = min(k, end)
        }
        while k < end, scalars[k] == " " { k += 1 }
        // An optional title: "…", '…' or (…).
        if k < end, k > stop, let closing: Unicode.Scalar = scalars[k] == "\"" ? "\"" : scalars[k] == "'" ? "'" : scalars[k] == "(" ? ")" : nil {
            guard let j = find([closing], from: k + 1, end) else { return nil }
            k = j + 1
            while k < end, scalars[k] == " " { k += 1 }
        }
        guard k < end, scalars[k] == ")" else { return nil }
        return Link(label: i + 1..<close, destination: start..<stop, next: k + 1)
    }
    private func labelEnd(from start: Int, _ end: Int) -> Int? {
        var j = start, depth = 0
        while j < end {
            switch scalars[j] {
            case "\\": j += 2; continue
            case "`":
                let m = run("`", at: j, end)
                if let close = closingBackticks(m, from: j + m, end) { j = close + m } else { j += m }
                continue
            case "[": depth += 1
            case "]": if depth == 0 { return j }; depth -= 1
            default: break
            }
            j += 1
        }
        return nil
    }
    /// A link cut off by the end of a streaming answer: its label so far, and whether its address had begun.
    private func partialLink(at i: Int, _ end: Int) -> (label: Range<Int>, addressing: Bool)? {
        guard let close = labelEnd(from: i + 1, end) else { return (i + 1..<end, false) }
        if close + 1 == end { return (i + 1..<close, false) }
        guard scalars[close + 1] == "(" else { return nil }
        return (i + 1..<close, true)
    }
    /// A bare `http(s)://` address. It stops at the first non-ASCII character, since Korean
    /// particles follow it without a space ("https://bandal.app에서").
    private func bareURL(at i: Int, _ end: Int) -> Int? {
        let prefix = ["https://", "http://"].first { candidate in
            let value = Array(candidate.unicodeScalars)
            return i + value.count <= end && scalars[i..<i + value.count].elementsEqual(value)
        }
        guard let prefix else { return nil }
        var j = i + prefix.unicodeScalars.count
        while j < end, scalars[j].isASCII, !isSpace(scalars[j]), !"<>\"`".unicodeScalars.contains(scalars[j]) { j += 1 }
        // Trailing punctuation belongs to the sentence; a ")" only when it has no "(" in the address.
        while j > i + prefix.unicodeScalars.count {
            let last = scalars[j - 1]
            if ".,:;!?'\"*_~".unicodeScalars.contains(last) { j -= 1; continue }
            if last == ")" || last == "]" {
                let opening: Unicode.Scalar = last == ")" ? "(" : "["
                let opened = scalars[i..<j].filter { $0 == opening }.count, closed = scalars[i..<j].filter { $0 == last }.count
                if closed > opened { j -= 1; continue }
            }
            break
        }
        return j > i + prefix.unicodeScalars.count ? j : nil
    }
}

/// Keeps the blocks of an answer between updates, so a streaming answer re-reads only its end.
///
/// A block before the last two cannot change as text is added: only the last line is ever read
/// tentatively, and what it turns into can fold back only into the block right above it
/// (a header row that never gets its separator rejoins the paragraph).
final class NativeAnswerMarkdownCache {
    private var text = ""
    private var streaming = false
    private var blocks: [NativeAnswerMarkdown.Block] = []
    /// Where the last two blocks begin (UTF-8 offset) and how many blocks come before them.
    private var settledOffset = 0, settledCount = 0
    /// UTF-8 bytes read so far, for tests of the incremental path.
    private(set) var parsedBytes = 0

    func blocks(for value: String, streaming: Bool) -> [NativeAnswerMarkdown.Block] {
        let value = NativeAnswerMarkdown.normalized(value)
        if value == text && streaming == self.streaming && (!blocks.isEmpty || value.isEmpty) { return blocks }
        let extends = value.utf8.count >= text.utf8.count && value.utf8.starts(with: text.utf8)
        let offset = extends ? settledOffset : 0
        let kept = extends ? Array(blocks.prefix(settledCount)) : []
        let start = value.utf8.index(value.utf8.startIndex, offsetBy: offset)
        let parsed = NativeAnswerMarkdown.parsed(value[start...], streaming: streaming)
        parsedBytes += value.utf8.count - offset
        blocks = kept + parsed.map(\.block)
        if parsed.count >= 2 {
            settledOffset = offset + parsed[parsed.count - 2].offset; settledCount = kept.count + parsed.count - 2
        } else if parsed.count == 1 && kept.isEmpty {
            settledOffset = offset + parsed[0].offset; settledCount = 0
        } else {
            // Nothing new settled: keep reading from the same place.
            settledOffset = offset; settledCount = kept.count
        }
        text = value; self.streaming = streaming
        return blocks
    }
}
