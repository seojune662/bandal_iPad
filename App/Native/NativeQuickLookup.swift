import Foundation
import Network

/// 찾아보기: what a selected piece of text is looked up in. Decided by rules alone, never by a model,
/// so a lookup spends no AI allowance and the text leaves the device only when the reader taps the button.
enum NativeQuickLookupQuery: Equatable {
    /// One English word: the bundled English–Korean dictionary first.
    case word(String)
    /// A short term (up to four words and forty characters, letters and digits only): a Wikipedia summary.
    case term(String)
    /// Anything else, a sentence or a formula: a web search.
    case phrase(String)

    static let maximumTermWords = 4
    static let maximumTermCharacters = 40
    /// A search query this long still fits every engine's address; a longer selection is cut at a word.
    static let maximumQueryCharacters = 200

    var text: String {
        switch self { case .word(let value), .term(let value), .phrase(let value): value }
    }

    static func classify(_ selection: String) -> NativeQuickLookupQuery? {
        let text = normalized(selection)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if text.count <= maximumTermCharacters,
           text.range(of: #"^\p{Latin}+(?:['’-]\p{Latin}+)*$"#, options: .regularExpression) != nil { return .word(text) }
        if text.count <= maximumTermCharacters, text.split(separator: " ").count <= maximumTermWords,
           text.range(of: #"^[\p{L}\p{M}\p{N}]+(?:[ '’·–-][\p{L}\p{M}\p{N}]+)*$"#, options: .regularExpression) != nil { return .term(text) }
        return .phrase(clipped(text))
    }

    /// PDF text arrives with line breaks, words hyphenated across lines, ligatures and the quotes or full stop
    /// the finger caught at either end.
    static func normalized(_ selection: String) -> String {
        selection.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: #"(\p{L})[-‐‑]\s*\n\s*(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^["“”‘’'(\[{<«「『]+|["“”‘’')\]}>»」』.,!?;:…]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String) -> String {
        guard text.count > maximumQueryCharacters else { return text }
        let head = text.prefix(maximumQueryCharacters)
        guard let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > maximumQueryCharacters / 2 else { return String(head) }
        return String(head[..<space])
    }

    /// The search the in-app browser would run (`NativeBrowserAddress.resolve`), always as a search:
    /// a term that reads like an address ("Node.js") is quoted, so it is searched for rather than opened.
    static func searchURL(_ query: String, engine: String) -> URL? {
        try? NativeBrowserAddress.resolve(NativeBrowserAddress.isWebAddress(query) ? "\"" + query + "\"" : query, engine: engine)
    }

    /// How long a card stays when nobody touches it: about five seconds, longer for a longer text.
    static func dwell(characters: Int) -> Double { min(10, max(5, Double(characters) / 12)) }
}

/// One dictionary headword as the card shows it.
struct NativeQuickLookupDefinition: Equatable {
    let headword: String
    let pronunciation: String?
    /// "명사 · 행렬, 모체" per part of speech.
    let lines: [String]
    let url: URL?

    /// `DesktopDictionaryService.lookup`'s entries, which come base form first; the senses of that headword only.
    init?(entries: [[String: Any]]) {
        guard let first = entries.first, let headword = first["headword"] as? String else { return nil }
        let same = entries.filter { $0["headword"] as? String == headword }
        var lines: [String] = []
        for entry in same {
            var meanings: [String] = []
            for sense in entry["senses"] as? [[String: Any]] ?? [] {
                for meaning in (sense["meaning"] as? String).map({ [$0] }) ?? sense["meanings"] as? [String] ?? [] {
                    let value = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, !meanings.contains(value) { meanings.append(value) }
                }
            }
            guard !meanings.isEmpty else { continue }
            let part = (entry["partOfSpeech"] as? String).map { $0 + " · " } ?? ""
            lines.append(part + meanings.prefix(5).joined(separator: ", "))
        }
        guard !lines.isEmpty else { return nil }
        self.headword = headword
        pronunciation = (first["pronunciation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.lines = Array(lines.prefix(3))
        url = ((first["source"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
    }
}

struct NativeWikipediaSummary: Equatable {
    /// "ko" or "en".
    let language: String
    let title: String
    let description: String?
    let extract: String
    let url: URL
}

/// Wikipedia's page summary (REST `page/summary`): the lead of one article by its exact title, redirects followed.
/// Nothing is searched for, so a miss is a miss rather than a loosely related article.
enum NativeWikipediaClient {
    static func summaryURL(language: String, title: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard ["ko", "en"].contains(language),
              let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/" + path)
    }

    /// nil for an article that has no lead to show: a disambiguation page, the main page, an empty extract.
    static func parse(_ data: Data, language: String) -> NativeWikipediaSummary? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["type"] as? String == "standard", let title = value["title"] as? String,
              let page = ((value["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String,
              let url = URL(string: page), url.scheme == "https" else { return nil }
        // Formulas are dropped from the extract and leave empty lines behind.
        let extract = (value["extract"] as? String ?? "").replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extract.isEmpty else { return nil }
        let description = (value["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .init(language: language, title: title, description: description, extract: extract, url: url)
    }

    static func fetch(language: String, title: String, session: URLSession) async throws -> NativeWikipediaSummary? {
        guard let url = summaryURL(language: language, title: title) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return parse(data, language: language)
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }
}

enum NativeQuickLookupResult: Equatable {
    case dictionary(NativeQuickLookupDefinition)
    case wikipedia(NativeWikipediaSummary)
    case search(String)
    /// The network could not be reached and nothing on the device answered.
    case unreachable(String)
}

/// The order a query is tried in. Dictionary and network are passed in so the branches can be tested without either.
struct NativeQuickLookupResolver {
    var dictionary: (String) async -> [[String: Any]]
    var summary: (_ language: String, _ title: String) async throws -> NativeWikipediaSummary?

    func resolve(_ query: NativeQuickLookupQuery) async -> NativeQuickLookupResult {
        switch query {
        case .word(let word):
            if let definition = NativeQuickLookupDefinition(entries: await dictionary(word)) { return .dictionary(definition) }
            return await wikipedia(word)
        case .term(let term): return await wikipedia(term)
        case .phrase(let phrase): return .search(phrase)
        }
    }

    /// Korean first, then English; a term written in Hangul has no English article to find.
    private func wikipedia(_ title: String) async -> NativeQuickLookupResult {
        let languages = title.range(of: #"\p{Hangul}"#, options: .regularExpression) == nil ? ["ko", "en"] : ["ko"]
        for language in languages {
            do {
                if let found = try await summary(language, title) { return .wikipedia(found) }
            } catch {
                if Task.isCancelled { return .search(title) }
                if Self.isUnreachable(error) { return .unreachable(title) }
            }
        }
        return .search(title)
    }

    /// No route to the server at all, as opposed to a server that answered badly (then the search still may work).
    static func isUnreachable(_ error: Error) -> Bool {
        let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : 0)
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .timedOut, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed].contains(code)
    }
}

enum NativeQuickLookupNetwork {
    /// Ephemeral: no cookies or cache are kept from a lookup.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        if let proxy = offlineProxy { configuration.proxyConfigurations = [proxy] }
        return URLSession(configuration: configuration)
    }

    /// UI tests stand in for a device without a network: requests go to a proxy that refuses every connection,
    /// so URLSession and WebKit fail the way they do offline.
    static var offlineProxy: ProxyConfiguration? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing"), arguments.contains("--native-quick-lookup-offline") else { return nil }
        return ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))
        #else
        return nil
        #endif
    }
}
