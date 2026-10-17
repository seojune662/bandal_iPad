import Foundation

enum NativeRichTextCommands {
    struct Edit { var markdown: String; var sourceSelection: NSRange }
    static let insertions: [(id: String, title: String, keywords: String)] = [
        ("h1", "제목 1", "heading title"), ("h2", "제목 2", "heading subtitle"), ("h3", "제목 3", "heading"),
        ("bullet", "글머리 목록", "bullet list"), ("number", "번호 목록", "number ordered"), ("task", "할 일 목록", "task todo check"),
        ("quote", "인용", "quote"), ("callout", "콜아웃", "note tip warning"), ("link", "링크", "link url"),
        ("page", "새 페이지", "page new note"), ("wikilink", "노트 연결", "wiki page"), ("image", "이미지", "image photo"), ("codeblock", "코드 블록", "code"),
        ("rule", "구분선", "divider hr"), ("table", "표", "table grid"), ("math", "수식", "math latex")]
    static func apply(_ command: String, to document: NativeRichTextDocument, selection: NSRange) -> Edit {
        let source = document.markdown as NSString
        var range = document.sourceRange(for: selection)
        let text = source.substring(with: range)
        func edit(_ replacement: String, selectionOffset: Int = 0, length: Int = 0) -> Edit {
            Edit(markdown: source.replacingCharacters(in: range, with: replacement), sourceSelection: NSRange(location: range.location + selectionOffset, length: length))
        }
        if command == "unlink" {
            guard let link = link(in: document, selection: selection) else { return Edit(markdown: document.markdown, sourceSelection: range) }
            let label = source.substring(with: link.label)
            let offset = min(label.utf16.count, max(0, range.location - link.label.location))
            return Edit(markdown: source.replacingCharacters(in: link.full, with: label), sourceSelection: NSRange(location: link.full.location + offset, length: min(range.length, label.utf16.count - offset)))
        }
        if command.hasPrefix("code-language:") {
            guard let block = codeBlock(in: document, selection: selection) else { return Edit(markdown: document.markdown, sourceSelection: range) }
            let language = String(command.dropFirst("code-language:".count))
            guard codeLanguages.contains(where: { $0.id == language }) else { return Edit(markdown: document.markdown, sourceSelection: range) }
            let updated = source.replacingCharacters(in: block.languageRange, with: language)
            let delta = language.utf16.count - block.languageRange.length
            let location = range.location >= NSMaxRange(block.languageRange) ? range.location + delta : range.location
            return Edit(markdown: updated, sourceSelection: NSRange(location: max(0, location), length: range.length))
        }
        let markers = ["bold": "**", "italic": "_", "strike": "~~", "code": "`", "math": "$"]
        if let marker = markers[command] {
            let width = marker.utf16.count
            if range.location >= width, NSMaxRange(range) + width <= source.length,
               source.substring(with: NSRange(location: range.location - width, length: width)) == marker,
               source.substring(with: NSRange(location: NSMaxRange(range), length: width)) == marker {
                range = NSRange(location: range.location - width, length: range.length + 2 * width)
                return edit(text, length: text.utf16.count)
            }
            let value = text.isEmpty ? (command == "math" ? "x^2" : "텍스트") : text
            return edit(marker + value + marker, selectionOffset: width, length: value.utf16.count)
        }
        if command.hasPrefix("replace-math:") {
            let value = String(command.dropFirst("replace-math:".count))
            let block = text.hasPrefix("$$")
            return edit(block ? "$$\n" + value + "\n$$" : "$" + value + "$", selectionOffset: block ? 3 : 1, length: value.utf16.count)
        }
        if command.hasPrefix("link:") || command.hasPrefix("image:") {
            let image = command.hasPrefix("image:"), prefix = image ? "image:" : "link:"
            let address = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
            guard !address.isEmpty else { return Edit(markdown: document.markdown, sourceSelection: range) }
            if !image, let link = link(in: document, selection: selection) {
                return Edit(markdown: source.replacingCharacters(in: link.destinationRange, with: address), sourceSelection: range)
            }
            let label = text.isEmpty ? (image ? "이미지" : "링크") : text
            return edit((image ? "!" : "") + "[" + label + "](" + address + ")", selectionOffset: image ? 2 : 1, length: label.utf16.count)
        }
        if command.hasPrefix("insert:") { let value = String(command.dropFirst(7)); return edit(value, selectionOffset: value.utf16.count) }
        if command == "wikilink" { return edit("[[노트 제목]]", selectionOffset: 2, length: 5) }
        if command == "rule" { return edit("\n\n---\n\n", selectionOffset: 7) }
        if command == "table" { return edit("\n| 제목 1 | 제목 2 | 제목 3 |\n| --- | --- | --- |\n| 내용 | 내용 | 내용 |\n| 내용 | 내용 | 내용 |\n", selectionOffset: 3, length: 4) }
        if command == "codeblock" { let value = text.isEmpty ? "코드" : text; return edit("\n```\n" + value + "\n```\n", selectionOffset: 5, length: value.utf16.count) }
        if command == "callout" { return edit("> [!NOTE] 메모\n> " + (text.isEmpty ? "내용" : text) + "\n", selectionOffset: 10, length: 2) }
        if command == "indent" { range = source.lineRange(for: range); return edit("  " + source.substring(with: range), selectionOffset: 2) }
        if command == "outdent" {
            range = source.lineRange(for: range)
            let line = source.substring(with: range), trim = line.hasPrefix("    ") ? 4 : line.hasPrefix("  ") ? 2 : line.hasPrefix("\t") ? 1 : 0
            return edit(String(line.dropFirst(trim)))
        }
        range = source.lineRange(for: range)
        let current = source.substring(with: range)
        let prefix = ["h1": "# ", "h2": "## ", "h3": "### ", "bullet": "- ", "number": "1. ", "task": "- [ ] ", "quote": "> "][command] ?? ""
        let regex = try? NSRegularExpression(pattern: #"^ {0,3}(?:#{1,6}[ \t]+|[-+*] (?:\[[ xX]\] )?|\d+[.)] |> ?)(?:\[![A-Za-z]+\][-+]? ?)?"#, options: .anchorsMatchLines)
        let clean = regex?.stringByReplacingMatches(in: current, range: NSRange(location: 0, length: current.utf16.count), withTemplate: "") ?? current
        let lines = clean.components(separatedBy: "\n")
        let value = lines.enumerated().map { index, line in index == lines.count - 1 && line.isEmpty && current.hasSuffix("\n") ? "" : prefix + line }.joined(separator: "\n")
        return edit(value, selectionOffset: prefix.utf16.count, length: max(0, clean.utf16.count - (clean.hasSuffix("\n") ? 1 : 0)))
    }
    static func continuedLine(in document: NativeRichTextDocument, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let source = document.markdown as NSString, caret = document.sourceRange(for: selection).location
        let lineRange = source.lineRange(for: NSRange(location: min(caret, source.length), length: 0)), line = source.substring(with: lineRange)
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*)([-+*] (?:\[[ xX]\] )?|\d+[.)] |> ?)"#), let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return nil }
        let prefix = (line as NSString).substring(with: match.range)
        let content = (line as NSString).substring(from: match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return Edit(markdown: source.replacingCharacters(in: NSRange(location: lineRange.location, length: match.range.length), with: ""), sourceSelection: NSRange(location: lineRange.location, length: 0)) }
        var next = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        if let number = next.range(of: #"\d+"#, options: .regularExpression), let value = Int(next[number]) { next.replaceSubrange(number, with: String(value + 1)) }
        let inserted = "\n" + next
        let change = document.replacing(selection, with: inserted)
        return Edit(markdown: change.markdown, sourceSelection: NSRange(location: change.sourceCaret, length: 0))
    }

    struct LinkContext { let full: NSRange; let label: NSRange; let destinationRange: NSRange; let destination: String }
    static func link(in document: NativeRichTextDocument, selection: NSRange) -> LinkContext? {
        let source = document.markdown as NSString, selected = document.sourceRange(for: selection)
        guard let regex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]*)\]\(([^\s)]+)(?:\s+\"[^\"]*\")?\)"#) else { return nil }
        for match in regex.matches(in: document.markdown, range: NSRange(location: 0, length: source.length)) {
            let label = match.range(at: 1)
            guard selected.location >= label.location, NSMaxRange(selected) <= NSMaxRange(label) else { continue }
            let projection = document.text == document.markdown ? NativeRichTextDocument(document.markdown) : document
            guard projection.runs.contains(where: { $0.styles.contains("link") && NSIntersectionRange($0.source, label).length > 0 }) else { continue }
            return LinkContext(full: match.range, label: label, destinationRange: match.range(at: 2), destination: source.substring(with: match.range(at: 2)))
        }
        return nil
    }

    static let codeLanguages: [(id: String, title: String)] = [("", "언어 없음"), ("typescript", "TypeScript"), ("javascript", "JavaScript"), ("python", "Python"), ("bash", "Bash"), ("json", "JSON")]
    struct CodeBlockContext { let language: String; let languageRange: NSRange }
    static func codeBlock(in document: NativeRichTextDocument, selection: NSRange) -> CodeBlockContext? {
        let source = document.markdown as NSString, selected = document.sourceRange(for: selection)
        guard let regex = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([ \t]*)([^ \t\r\n]*)"#) else { return nil }
        var cursor = 0
        var opening: (start: Int, fence: String, context: CodeBlockContext)?
        while cursor < source.length {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0)), raw = source.substring(with: line)
            defer { cursor = NSMaxRange(line) }
            if let active = opening {
                let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= active.fence.count, candidate.allSatisfy({ $0 == active.fence.first }) {
                    if selected.location >= active.start, NSMaxRange(selected) <= line.location { return active.context }
                    opening = nil
                }
            } else if let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)) {
                let text = raw as NSString, range = match.range(at: 3)
                opening = (line.location, text.substring(with: match.range(at: 1)), CodeBlockContext(language: text.substring(with: range), languageRange: NSRange(location: line.location + range.location, length: range.length)))
            }
        }
        if let active = opening, selected.location >= active.start, NSMaxRange(selected) <= source.length { return active.context }
        return nil
    }
}

enum NativeNoteFontScale {
    static let key = "native.noteFontScale"
    static let values: [Double] = [0.875, 1, 1.125, 1.25, 1.5]
    static func step(_ current: Double, direction: Int) -> Double {
        let index = values.firstIndex(of: current) ?? 1
        return values[max(0, min(values.count - 1, index + (direction < 0 ? -1 : 1)))]
    }
}
