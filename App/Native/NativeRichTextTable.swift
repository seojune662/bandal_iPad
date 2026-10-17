import Foundation

/// Structural table commands patch only the selected table. Cell source is
/// retained exactly, including escaped pipes, links and inline code.
enum NativeRichTextTable {
    private struct Line {
        var range: NSRange; var text: String; var cells: [NSRange]; var leading: Bool; var trailing: Bool
        init(_ range: NSRange, source: NSString) {
            self.range = range; text = source.substring(with: range)
            let body = text.trimmingCharacters(in: .newlines) as NSString
            var separators: [Int] = [], escaped = false, code = false
            for index in 0..<body.length {
                let character = body.character(at: index)
                if escaped { escaped = false; continue }
                if character == 92 { escaped = true; continue }
                if character == 96 { code.toggle() }
                if character == 124 && !code { separators.append(index) }
            }
            leading = separators.first.map { body.substring(to: $0).trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            trailing = separators.last.map { body.substring(from: $0 + 1).trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            let boundaries = [-1] + separators + [body.length]
            cells = zip(boundaries, boundaries.dropFirst()).map { NSRange(location: $0 + 1, length: $1 - $0 - 1) }
            if trailing { cells.removeLast() }; if leading { cells.removeFirst() }
        }
        var separator: Bool { text.range(of: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, options: .regularExpression) != nil }
        func rebuilt(_ values: [String]) -> String { (leading ? "|" : "") + values.joined(separator: "|") + (trailing ? "|" : "") + (text.hasSuffix("\r\n") ? "\r\n" : text.hasSuffix("\n") ? "\n" : "") }
    }
    static func cellRanges(_ text: String) -> [NSRange] {
        Line(NSRange(location: 0, length: text.utf16.count), source: text as NSString).cells
    }
    static func edit(_ command: String, markdown: String, selection: NSRange) -> NativeRichTextCommands.Edit? {
        let source = markdown as NSString
        var all: [Line] = [], position = 0
        while position < source.length { let range = source.lineRange(for: NSRange(location: position, length: 0)); all.append(Line(range, source: source)); position = NSMaxRange(range) }
        guard let current = all.firstIndex(where: { NSLocationInRange(selection.location, $0.range) || selection.location == source.length && NSMaxRange($0.range) == source.length }), all[current].cells.count >= 2 else { return nil }
        var first = current, last = current
        while first > 0 && all[first - 1].cells.count >= 2 { first -= 1 }
        while last + 1 < all.count && all[last + 1].cells.count >= 2 { last += 1 }
        guard last > first, all[first + 1].separator else { return nil }
        let line = all[current], offset = selection.location - line.range.location
        let column = line.cells.firstIndex(where: { offset <= NSMaxRange($0) }) ?? line.cells.count - 1
        if command == "table-next" || command == "table-previous" {
            var row = current, cell = column + (command == "table-next" ? 1 : -1)
            if cell >= line.cells.count { row += 1; if row == first + 1 { row += 1 }; cell = 0 }
            if cell < 0 { row -= 1; if row == first + 1 { row -= 1 }; if row >= first { cell = all[row].cells.count - 1 } }
            guard row >= first, row <= last, all[row].cells.indices.contains(cell) else { return nil }
            let target = all[row].cells[cell], value = (all[row].text as NSString).substring(with: target)
            let leading = value.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
            return .init(markdown: markdown, sourceSelection: NSRange(location: all[row].range.location + target.location + leading, length: value.trimmingCharacters(in: .whitespaces).utf16.count))
        }
        if command == "table-row-after" || command == "table-row-before" {
            let index = max(first + 2, command == "table-row-before" ? current : current + 1)
            let at = index <= last ? all[index].range.location : NSMaxRange(all[last].range)
            let newline = line.text.hasSuffix("\r\n") ? "\r\n" : "\n"
            let row = "|" + Array(repeating: "  ", count: all[first].cells.count).joined(separator: "|") + "|" + newline
            let prefix = at == source.length && !markdown.hasSuffix("\n") ? newline : ""
            return .init(markdown: source.replacingCharacters(in: NSRange(location: at, length: 0), with: prefix + row), sourceSelection: NSRange(location: at + prefix.utf16.count + 2, length: 0))
        }
        if command == "table-row-delete" {
            guard current > first + 1 else { return nil }
            return .init(markdown: source.replacingCharacters(in: line.range, with: ""), sourceSelection: NSRange(location: min(line.range.location, source.length - line.range.length), length: 0))
        }
        guard ["table-column-after", "table-column-delete"].contains(command), command != "table-column-delete" || all[first].cells.count > 2 else { return nil }
        var replacement = ""
        for row in all[first...last] {
            var values = row.cells.map { (row.text as NSString).substring(with: $0) }
            guard values.indices.contains(column) else { return nil }
            if command == "table-column-after" { values.insert(row.separator ? " --- " : "  ", at: column + 1) } else { values.remove(at: column) }
            replacement += row.rebuilt(values)
        }
        let range = NSRange(location: all[first].range.location, length: NSMaxRange(all[last].range) - all[first].range.location)
        return .init(markdown: source.replacingCharacters(in: range, with: replacement), sourceSelection: NSRange(location: range.location + 2, length: 0))
    }
}
