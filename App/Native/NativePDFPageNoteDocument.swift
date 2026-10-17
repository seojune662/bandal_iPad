import Foundation

/// The desktop page-note format remains ordinary portable Markdown on disk.
struct NativePDFPageNoteDocument: Equatable {
    struct Size: Codable, Equatable { var width: Double; var height: Double }
    struct Manifest: Codable, Equatable { var version = 1; var source: String; var fingerprint: String; var pages: [Size] }
    var manifest: Manifest
    var title: String
    var pages: [String]
    var appendix: String
    var source: String { manifest.source.removingPercentEncoding ?? manifest.source }
    init(source: String, fingerprint: String, sizes: [Size], title: String) {
        manifest = Manifest(source: source.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? source, fingerprint: fingerprint, pages: sizes)
        self.title = title; pages = sizes.map { _ in "" }; appendix = ""
    }
    init?(_ text: String) {
        let prefix = "<!-- bandal:pdf-page-note ", suffix = " -->"
        guard let first = text.components(separatedBy: "\n").first, first.hasPrefix(prefix), first.hasSuffix(suffix),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(first.dropFirst(prefix.count).dropLast(suffix.count).utf8)),
              manifest.version == 1, !manifest.pages.isEmpty, manifest.pages.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }),
              let expression = try? NSRegularExpression(pattern: #"^<!-- bandal:page (\d+) -->[ \t]*$"#, options: .anchorsMatchLines) else { return nil }
        let string = text as NSString, matches = expression.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard matches.count == manifest.pages.count else { return nil }
        let appendixRange = string.range(of: "<!-- bandal:appendix -->")
        let end = appendixRange.location == NSNotFound ? string.length : appendixRange.location
        var pages: [String] = []
        for (index, match) in matches.enumerated() {
            guard Int(string.substring(with: match.range(at: 1))) == index + 1 else { return nil }
            let start = NSMaxRange(match.range), next = index + 1 < matches.count ? matches[index + 1].range.location : end
            guard next >= start else { return nil }
            pages.append(Self.content(fromSection: string.substring(with: NSRange(location: start, length: next - start)), followedBySection: next < string.length))
        }
        self.manifest = manifest; self.pages = pages
        title = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? "PDF 페이지 필기"
        appendix = appendixRange.location == NSNotFound ? "" : Self.content(fromSection: string.substring(from: NSMaxRange(appendixRange)), followedBySection: false)
    }
    /// Decode only the format's framing: two line breaks after a marker, two
    /// before the next section, or one at EOF. The body can itself begin/end in
    /// whitespace (including an in-progress space key or an empty paragraph).
    static func content(fromSection value: String, followedBySection: Bool) -> String {
        var result = value
        for _ in 0..<2 {
            guard result.first == "\n" || result.first == "\r" || result.first == "\r\n" else { break }
            result.removeFirst()
        }
        for _ in 0..<(followedBySection ? 2 : 1) {
            guard result.last == "\n" || result.last == "\r" || result.last == "\r\n" else { break }
            result.removeLast()
        }
        return result
    }
    /// Reserved structural comments pasted into page content are literal text.
    /// They must never become a second boundary or hide subsequent pages.
    static func safeContent(_ value: String) -> String {
        value.replacingOccurrences(of: "<!-- bandal:", with: "&lt;!-- bandal:")
    }
    func markdown() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        let safeTitle = title.components(separatedBy: .newlines).joined(separator: " ")
        let body = pages.enumerated().map { index, text in
            let clean = Self.safeContent(text)
            return "<!-- bandal:page \(index + 1) -->" + (clean.isEmpty ? "" : "\n\n" + clean)
        }.joined(separator: "\n\n")
        return "<!-- bandal:pdf-page-note \(header) -->\n# \(safeTitle)\n\n" + body + (appendix.isEmpty ? "" : "\n\n<!-- bandal:appendix -->\n\n" + Self.safeContent(appendix)) + "\n"
    }
}
