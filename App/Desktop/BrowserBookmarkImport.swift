import Foundation

/// Netscape bookmark HTML, the export format of Chrome, Safari, Edge and
/// Firefox. Only http(s) links are kept; folders are flattened.
enum BrowserBookmarkImport {
    static let maxBytes = 10 * 1024 * 1024
    static let maxLinks = 2_000
    struct Link: Equatable { let title: String; let url: String }

    static func links(_ html: String) throws -> [Link] {
        guard html.utf8.count <= maxBytes else { throw DesktopRuntimeError("10MB 이하 북마크 파일을 선택해 주세요.") }
        let pattern = try NSRegularExpression(pattern: #"<a\s[^>]*?href\s*=\s*"([^"]*)"[^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        var seen = Set<String>(), result: [Link] = []
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard result.count < maxLinks, let hrefRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html) else { break }
            let url = decode(String(html[hrefRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.utf8.count <= 20_000, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false, seen.insert(url).inserted else { continue }
            let stripped = decode(String(html[titleRange]).replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Link(title: String((stripped.isEmpty ? parsed.host! : stripped).prefix(200)), url: url))
        }
        return result
    }
    private static func decode(_ text: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
