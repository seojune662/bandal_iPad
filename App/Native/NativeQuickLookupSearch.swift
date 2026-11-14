import Foundation
import NaturalLanguage

/// 자동 찾아보기 without a model: what a selection is searched for. A short selection is its own query; from a
/// longer one the key term is picked on the device, with the heading line above it as context. Rules only.
enum NativeQuickLookupTerm {
    /// Up to four words and forty characters, as a term the button looks up.
    static func isShort(_ text: String) -> Bool {
        text.count <= NativeQuickLookupQuery.maximumTermCharacters && text.split(separator: " ").count <= NativeQuickLookupQuery.maximumTermWords
    }

    /// The query for a selection already cleaned by `NativeQuickLookupQuery.normalized`; nil when it holds no term.
    static func query(for text: String, heading: String?) -> String? {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if isShort(text) { return text }
        return keyTerms(text, heading: heading).first
    }

    /// "ko" when the text is written in Hangul, else "en".
    static func language(of text: String) -> String {
        text.range(of: #"\p{Hangul}"#, options: .regularExpression) == nil ? "en" : "ko"
    }

    /// The Wikipedias a query is tried in: the text's language first, then the other one when the query can be
    /// read there (a Hangul query has no English article to match, so Korean text tries English with its Latin term).
    static func searches(text: String, query: String, heading: String?) -> [(language: String, query: String)] {
        if language(of: text) == "en" { return [("en", query), ("ko", query)] }
        var result = [("ko", query)]
        if language(of: query) == "en" { result.append(("en", query)) }
        else if let latin = keyTerms(text, heading: heading, limit: 8).first(where: { language(of: $0) == "en" }) { result.append(("en", latin)) }
        return result
    }

    // MARK: key terms

    /// Particles a Korean noun carries, longest first, with how much they say the noun is what the sentence is about.
    private static let particles: [(String, Double)] = [
        ("에서는", 0.6), ("으로는", 0.6), ("에게서", 0.3), ("이라는", 0.8), ("이라고", 0.5), ("이란", 1.2), ("에서", 0.3), ("으로", 0.3),
        ("에게", 0.3), ("한테", 0.3), ("까지", 0.3), ("부터", 0.3), ("보다", 0.3), ("처럼", 0.3), ("만큼", 0.3), ("이나", 0.3),
        ("라는", 0.8), ("이고", 0.5), ("이며", 0.5), ("이다", 0.8), ("에는", 0.5), ("와는", 0.4), ("과는", 0.4), ("란", 1.2),
        ("은", 1.5), ("는", 1.5), ("이", 1.3), ("가", 1.3), ("을", 1.0), ("를", 1.0), ("의", 0.5), ("와", 0.6), ("과", 0.6),
        ("에", 0.3), ("로", 0.3), ("도", 0.5), ("만", 0.4)]
    /// Endings only verbs and adjectives have ("감소하는", "않는다"): checked before a particle is looked for,
    /// since "하는" also ends in the particle "는".
    private static let verbEndings = ["습니다", "합니다", "됩니다", "니다", "한다", "된다", "는다", "었다", "였다", "했다", "있다", "없다", "같다",
        "하는", "되는", "있는", "없는", "않는", "이는", "하던", "하고", "되고", "하며", "되며", "하여", "되어", "해서", "돼서", "하면", "되면", "하지", "되지",
        "하게", "되게", "하기", "되기", "지만", "어서", "아서", "도록", "면서", "므로", "으며", "으나", "으면", "는데"]
    /// Endings a noun can also end in ("제한", "공인"): a predicate only on a word of three letters or more without a particle.
    private static let weakEndings = ["적인", "한", "된", "인", "다", "요", "까"]
    private static let koreanStopwords: Set<String> = ["이다", "있다", "없다", "그것", "이것", "저것", "또는", "그리고", "하지만", "그러나", "따라서", "때문",
        "경우", "통해", "위해", "대한", "대해", "모든", "어떤", "각각", "다음", "이번", "여기", "거기", "우리", "자신", "정도", "부분", "이상", "이하"]
    private static let stopwords: Set<String> = ["the", "and", "for", "are", "was", "were", "with", "that", "this", "these", "those", "from", "into",
        "its", "his", "her", "their", "our", "your", "not", "but", "can", "may", "will", "has", "have", "had", "been", "being", "also", "such",
        "than", "then", "when", "where", "which", "while", "what", "who", "how", "why", "all", "any", "each", "both", "more", "most", "some",
        "only", "very", "never", "always", "often", "there", "here", "one", "two", "use", "used", "using", "via", "per", "let", "see", "e.g", "i.e"]

    /// A Korean word without its particle, and the particle's weight (0 when it had none).
    static func stem(_ word: String) -> (stem: String, weight: Double) {
        for (particle, weight) in particles where word.hasSuffix(particle) {
            let stem = String(word.dropLast(particle.count))
            if stem.count >= 2 { return (stem, weight) }
        }
        return (word, 0)
    }

    /// A Korean verb or adjective form, which is never the term looked up.
    static func isPredicate(_ word: String) -> Bool {
        if verbEndings.contains(where: { word.hasSuffix($0) }) { return true }
        return stem(word).weight == 0 && word.count >= 3 && weakEndings.contains { word.hasSuffix($0) }
    }

    /// The selection's terms, the likeliest first: nouns the sentences are about (a topic or subject particle),
    /// repeated ones, ones the heading also names, longer ones. Formulas, numbers and predicates are left out.
    static func keyTerms(_ text: String, heading: String?, limit: Int = 3) -> [String] {
        let headingStems = Set(words(heading ?? "").map { stem($0).stem.lowercased() })
        let nouns = englishNouns(text)
        var scores: [String: (score: Double, first: Int, shown: String)] = [:]
        for (index, word) in words(text).enumerated() {
            guard word.count >= 2, word.contains(where: \.isLetter), word.range(of: #"^[\p{L}\p{M}\p{N}'’·-]+$"#, options: .regularExpression) != nil else { continue }
            var term = word, score = 1.0
            if word.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil {
                if isPredicate(word) { continue }
                let (stem, weight) = stem(word)
                guard !koreanStopwords.contains(stem) else { continue }
                term = stem; score += weight > 0 ? weight : 0.8
                if term.count >= 3 { score += 0.5 }
            } else if word.range(of: #"^[\p{Latin}'’-]+$"#, options: .regularExpression) != nil {
                let lower = word.lowercased()
                guard word.count >= 3, !stopwords.contains(lower) else { continue }
                if let nouns { guard nouns.contains(lower) else { continue }; score += 0.8 }
                if word.count >= 6 { score += 0.5 }
                if index > 0, word.first?.isUppercase == true { score += 0.3 }
            } else { continue }
            let key = term.lowercased()
            if headingStems.contains(key) { score += 1.5 }
            if let seen = scores[key] { scores[key] = (seen.score + score * 0.6, seen.first, seen.shown) }
            else { scores[key] = (score, index, term) }
        }
        return scores.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.first < $1.first }.prefix(limit).map(\.shown)
    }

    static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?()[]{}<>\"“”‘«»「」『』/=+*^…")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’-·")) }.filter { !$0.isEmpty }
    }

    /// The English nouns of `text` (lower-cased), or nil when the text has no English to tag.
    private static func englishNouns(_ text: String) -> Set<String>? {
        guard text.range(of: #"\p{Latin}{3,}"#, options: .regularExpression) != nil else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var nouns = Set<String>(), tagged = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard text[range].range(of: #"^\p{Latin}"#, options: .regularExpression) != nil else { return true }
            if tag != nil, tag != .otherWord { tagged = true }
            if tag == .noun { nouns.insert(text[range].lowercased()) }
            return true
        }
        return tagged ? nouns : nil
    }
}

/// Wikipedia's search (the action API with the search generator), with each hit's lead in the same request,
/// so a lookup is one request per language. Disambiguation pages are left out; a hit counts only when its
/// title is what the query names (or shares a word with it or with the heading).
enum NativeWikipediaSearch {
    /// The only identifying header a request carries: the app's name and site, nothing of the reader or the iPad.
    static let userAgent = "Bandal (https://bandal.io)"

    struct Hit: Equatable {
        let title: String
        let extract: String
        let description: String?
        let url: URL
        /// The search's own rank, 1 first.
        let rank: Int
    }

    static func url(language: String, query: String) -> URL? {
        guard ["ko", "en"].contains(language), !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: String(query.prefix(120))), .init(name: "gsrlimit", value: "5"),
            .init(name: "gsrnamespace", value: "0"), .init(name: "prop", value: "extracts|info|pageprops|description"),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"), .init(name: "exsentences", value: "3"), .init(name: "exlimit", value: "5"),
            .init(name: "inprop", value: "url"), .init(name: "ppprop", value: "disambiguation"), .init(name: "redirects", value: "1")]
        return components?.url
    }

    static func parse(_ data: Data, language: String) -> [Hit] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (value["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return [] }
        return pages.compactMap { page in
            guard let title = page["title"] as? String, (page["pageprops"] as? [String: Any])?["disambiguation"] == nil,
                  let address = page["fullurl"] as? String ?? page["canonicalurl"] as? String, let url = URL(string: address), url.scheme == "https",
                  url.host?.hasSuffix(".wikipedia.org") == true else { return nil }
            let extract = (page["extract"] as? String ?? "").replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extract.isEmpty else { return nil }
            let description = (page["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Hit(title: title, extract: extract, description: description, url: url, rank: page["index"] as? Int ?? 99)
        }.sorted { $0.rank < $1.rank }
    }

    /// Folded for comparison: case, width, spaces and the particles on Korean words.
    static func fold(_ text: String) -> String {
        NativeQuickLookupTerm.words(NativeQuickLookupQuery.normalized(text)).map { NativeQuickLookupTerm.stem($0).stem.lowercased() }.joined(separator: " ")
    }

    /// The hit that is the query's article, or nil when none is: a search for a sentence always returns something.
    static func best(_ hits: [Hit], query: String, context: String?) -> Hit? {
        let folded = fold(query), queryWords = Set(folded.split(separator: " ").map(String.init))
        let contextWords = Set(fold(context ?? "").split(separator: " ").map(String.init)).filter { $0.count >= 2 }
        var best: (hit: Hit, score: Double)?
        for hit in hits {
            let title = fold(hit.title.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression))
            guard !title.isEmpty else { continue }
            let titleWords = Set(title.split(separator: " ").map(String.init))
            var score = 0.0
            if title == folded { score += 4 }
            else if title.count >= 2, folded.contains(title) || title.contains(folded) { score += 2 }
            score += Double(titleWords.intersection(queryWords).filter { $0.count >= 2 }.count)
            let relation = score
            if !contextWords.isEmpty {
                let body = fold(hit.title + " " + (hit.description ?? "") + " " + hit.extract.prefix(300))
                score += min(2, Double(contextWords.filter { body.contains($0) }.count))
                if title == fold(context ?? "") { score += 1 }
                // Of the articles on the query, the one the heading names ("순환" under "카르노 순환").
                if relation >= 1 { score += 1.5 * Double(titleWords.intersection(contextWords).subtracting(queryWords).count) }
            }
            score -= Double(max(0, hit.rank - 1)) * 0.3
            guard relation >= 1 || score >= 2.5 else { continue }
            if best == nil || score > best!.score { best = (hit, score) }
        }
        guard let best, best.score >= 1.5 else { return nil }
        return best.hit
    }

    static func fetch(language: String, query: String, context: String?, session: URLSession) async throws -> NativeWikipediaSummary? {
        guard let url = url(language: language, query: query) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let hit = best(parse(data, language: language), query: query, context: context) else { return nil }
        return NativeWikipediaSummary(language: language, title: hit.title, description: hit.description, extract: hit.extract, url: hit.url)
    }
}

/// The order an automatic lookup is tried in, network passed in so every branch can be tested without it.
/// Unlike the button, it never opens a search page by itself and it says nothing when it fails:
/// nil means no card at all.
struct NativeQuickLookupAutoResolver {
    var dictionary: (String) async -> [[String: Any]]
    var search: (_ language: String, _ query: String, _ context: String?) async throws -> NativeWikipediaSummary?

    struct Outcome: Equatable {
        let query: String
        /// `.dictionary`, `.wikipedia` or `.search` (a link to search the web, nothing loaded).
        let result: NativeQuickLookupResult
    }

    func resolve(_ selection: String, heading: String?) async -> Outcome? {
        let text = NativeQuickLookupQuery.normalized(selection)
        guard let query = NativeQuickLookupTerm.query(for: text, heading: heading) else { return nil }
        // The dictionary answers a selection that is one English word, not a word taken out of a sentence.
        if query == text, case .word(let word) = NativeQuickLookupQuery.classify(query),
           let definition = NativeQuickLookupDefinition(entries: await dictionary(word)) { return Outcome(query: word, result: .dictionary(definition)) }
        if Task.isCancelled { return nil }
        let summary: NativeWikipediaSummary?
        do { summary = try await wikipedia(text: text, query: query, heading: heading) }
        catch { return nil }
        if Task.isCancelled { return nil }
        return Outcome(query: summary?.title ?? query, result: summary.map { .wikipedia($0) } ?? .search(query))
    }

    /// The article for `query`, nil when Wikipedia has none; throws when a language could not be asked at all
    /// (offline, or a server that answered badly), since then a miss is not known to be one.
    func wikipedia(text: String, query: String, heading: String?) async throws -> NativeWikipediaSummary? {
        var failure: Error?
        for attempt in NativeQuickLookupTerm.searches(text: text, query: query, heading: heading) {
            do {
                if let found = try await search(attempt.language, attempt.query, heading) { return found }
            } catch {
                if Task.isCancelled || NativeQuickLookupResolver.isUnreachable(error) { throw error }
                failure = error
            }
        }
        if let failure { throw failure }
        return nil
    }
}
