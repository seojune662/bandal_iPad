import XCTest
import Combine
@testable import Bandal

final class NativeQuickLookupTests: XCTestCase {
    // MARK: what a selection is looked up in

    func testOneEnglishWordGoesToTheDictionary() {
        XCTAssertEqual(NativeQuickLookupQuery.classify("eigenvalue"), .word("eigenvalue"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("  “Matrix,” "), .word("Matrix"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("well-known"), .word("well-known"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("runner’s"), .word("runner’s"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("naïve"), .word("naïve"))
    }

    func testPDFTextIsCleanedBeforeItIsClassified() {
        // A word hyphenated across two lines, a ligature, a soft hyphen and full-width letters.
        XCTAssertEqual(NativeQuickLookupQuery.classify("eigen-\nvalue"), .word("eigenvalue"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("\u{FB01}nite"), .word("finite"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("deter\u{00AD}minant"), .word("determinant"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("Ｒｕｎｎｉｎｇ"), .word("Running"))
        // A line break inside a term is a space.
        XCTAssertEqual(NativeQuickLookupQuery.classify("linear\nalgebra"), .term("linear algebra"))
    }

    func testShortTermsGoToWikipedia() {
        XCTAssertEqual(NativeQuickLookupQuery.classify("linear algebra"), .term("linear algebra"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("선형대수학"), .term("선형대수학"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("고유값 분해"), .term("고유값 분해"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("COVID-19"), .term("COVID-19"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("Kullback–Leibler divergence."), .term("Kullback–Leibler divergence"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("principal component analysis method"), .term("principal component analysis method"))
    }

    func testSentencesFormulasAndLongTextGoToSearch() {
        XCTAssertEqual(NativeQuickLookupQuery.classify("The determinant of a singular matrix is zero."),
                       .phrase("The determinant of a singular matrix is zero"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("one two three four five"), .phrase("one two three four five"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("x^2 + y^2 = 1"), .phrase("x^2 + y^2 = 1"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("행렬식이 0이면, 역행렬이 없다"), .phrase("행렬식이 0이면, 역행렬이 없다"))
        XCTAssertEqual(NativeQuickLookupQuery.classify("Node.js"), .phrase("Node.js"))
        // A single word longer than any headword is not a dictionary lookup.
        XCTAssertEqual(NativeQuickLookupQuery.classify(String(repeating: "a", count: 41)), .phrase(String(repeating: "a", count: 41)))
        let paragraph = Array(repeating: "linear", count: 60).joined(separator: " ")
        guard case .phrase(let query) = NativeQuickLookupQuery.classify(paragraph) else { return XCTFail("a paragraph is a search") }
        XCTAssertLessThanOrEqual(query.count, NativeQuickLookupQuery.maximumQueryCharacters)
        XCTAssertTrue(query.hasSuffix("linear"), "cut at a word")
    }

    func testNothingToLookUp() {
        XCTAssertNil(NativeQuickLookupQuery.classify(""))
        XCTAssertNil(NativeQuickLookupQuery.classify(" \n\t "))
        XCTAssertNil(NativeQuickLookupQuery.classify("…!?"))
    }

    // MARK: the order a query is tried in

    private final class Calls { var dictionary: [String] = []; var summary: [String] = [] }
    private func resolver(_ calls: Calls, dictionary: [[String: Any]] = [],
                          summary: @escaping (String, String) throws -> NativeWikipediaSummary? = { _, _ in nil }) -> NativeQuickLookupResolver {
        NativeQuickLookupResolver(dictionary: { calls.dictionary.append($0); return dictionary },
                                  summary: { calls.summary.append($0 + ":" + $1); return try summary($0, $1) })
    }
    private func article(_ language: String, _ title: String) -> NativeWikipediaSummary {
        .init(language: language, title: title, description: nil, extract: title + " is a subject.", url: URL(string: "https://\(language).wikipedia.org/wiki/\(title)")!)
    }
    private let matrix: [[String: Any]] = [["headword": "matrix", "partOfSpeech": "명사", "pronunciation": "/ˈmeɪ.tɹɪks/",
        "senses": [["meaning": "행렬"], ["meaning": "모체"], ["meaning": "행렬"]], "source": ["url": "https://en.wiktionary.org/wiki/matrix#English"]]]

    func testAWordInTheDictionaryNeverReachesTheNetwork() async {
        let calls = Calls()
        let result = await resolver(calls, dictionary: matrix).resolve(.word("matrix"))
        guard case .dictionary(let definition) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(definition.headword, "matrix")
        XCTAssertEqual(definition.pronunciation, "/ˈmeɪ.tɹɪks/")
        XCTAssertEqual(definition.lines, ["명사 · 행렬, 모체"])
        XCTAssertEqual(definition.url?.absoluteString, "https://en.wiktionary.org/wiki/matrix#English")
        XCTAssertEqual(calls.summary, [])
    }

    func testAWordMissingFromTheDictionaryTriesKoreanThenEnglishWikipedia() async {
        let calls = Calls()
        let result = await resolver(calls) { language, title in language == "en" ? self.article("en", "Eigendecomposition") : nil }
            .resolve(.word("eigendecomposition"))
        XCTAssertEqual(result, .wikipedia(article("en", "Eigendecomposition")))
        XCTAssertEqual(calls.dictionary, ["eigendecomposition"])
        XCTAssertEqual(calls.summary, ["ko:eigendecomposition", "en:eigendecomposition"])
    }

    func testKoreanWikipediaWinsWhenBothHaveTheArticle() async {
        let calls = Calls()
        let result = await resolver(calls) { language, _ in self.article(language, "Mercury") }.resolve(.term("Mercury"))
        XCTAssertEqual(result, .wikipedia(article("ko", "Mercury")))
        XCTAssertEqual(calls.summary, ["ko:Mercury"])
    }

    func testAHangulTermIsNotSentToEnglishWikipedia() async {
        let calls = Calls()
        let result = await resolver(calls).resolve(.term("없는 용어"))
        XCTAssertEqual(result, .search("없는 용어"))
        XCTAssertEqual(calls.summary, ["ko:없는 용어"])
        XCTAssertEqual(calls.dictionary, [])
    }

    func testOfflineStopsAtTheFirstRequestAndSaysSo() async {
        let calls = Calls()
        let result = await resolver(calls) { _, _ in throw URLError(.notConnectedToInternet) }.resolve(.term("linear algebra"))
        XCTAssertEqual(result, .unreachable("linear algebra"))
        XCTAssertEqual(calls.summary, ["ko:linear algebra"])
    }

    func testOfflineStillAnswersAWordFromTheDictionary() async {
        let calls = Calls()
        let result = await resolver(calls, dictionary: matrix) { _, _ in throw URLError(.notConnectedToInternet) }.resolve(.word("matrix"))
        guard case .dictionary = result else { return XCTFail("\(result)") }
    }

    func testAServerErrorFallsThroughToTheNextLanguageAndThenSearch() async {
        let calls = Calls()
        let result = await resolver(calls) { _, _ in throw URLError(.badServerResponse) }.resolve(.term("linear algebra"))
        XCTAssertEqual(result, .search("linear algebra"))
        XCTAssertEqual(calls.summary, ["ko:linear algebra", "en:linear algebra"])
    }

    func testASentenceGoesStraightToSearch() async {
        let calls = Calls()
        let result = await resolver(calls).resolve(.phrase("The determinant of a singular matrix is zero"))
        XCTAssertEqual(result, .search("The determinant of a singular matrix is zero"))
        XCTAssertEqual(calls.dictionary, []); XCTAssertEqual(calls.summary, [])
    }

    func testUnreachableMeansNoRouteNotABadAnswer() {
        XCTAssertTrue(NativeQuickLookupResolver.isUnreachable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NativeQuickLookupResolver.isUnreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(NativeQuickLookupResolver.isUnreachable(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(NativeQuickLookupResolver.isUnreachable(URLError(.badServerResponse)))
        XCTAssertFalse(NativeQuickLookupResolver.isUnreachable(NSError(domain: "other", code: NSURLErrorNotConnectedToInternet)))
    }

    // MARK: the dictionary entry as the card shows it

    func testTheBundledDictionaryAnswersAWordAndItsInflection() async throws {
        let service = DesktopDictionaryService()
        func entries(_ word: String) async -> [[String: Any]] { await service.lookup(word)["entries"] as? [[String: Any]] ?? [] }
        let matrixEntries = await entries("matrix"), runningEntries = await entries("Running")
        let matrix = try XCTUnwrap(NativeQuickLookupDefinition(entries: matrixEntries))
        XCTAssertEqual(matrix.headword, "matrix")
        XCTAssertTrue(matrix.lines.contains { $0.contains("행렬") }, "\(matrix.lines)")
        XCTAssertEqual(matrix.url?.host, "en.wiktionary.org")
        XCTAssertLessThanOrEqual(matrix.lines.count, 3)
        let running = try XCTUnwrap(NativeQuickLookupDefinition(entries: runningEntries))
        XCTAssertTrue(["running", "run"].contains(running.headword), running.headword)
        let missing = await entries("qwertyzxcv")
        XCTAssertNil(NativeQuickLookupDefinition(entries: missing))
    }

    // MARK: Wikipedia and search addresses

    func testWikipediaSummaryAddressesEncodeTheWholeTitle() {
        XCTAssertEqual(NativeWikipediaClient.summaryURL(language: "en", title: "linear algebra")?.absoluteString,
                       "https://en.wikipedia.org/api/rest_v1/page/summary/linear_algebra")
        XCTAssertEqual(NativeWikipediaClient.summaryURL(language: "ko", title: "선형대수학")?.absoluteString,
                       "https://ko.wikipedia.org/api/rest_v1/page/summary/%EC%84%A0%ED%98%95%EB%8C%80%EC%88%98%ED%95%99")
        XCTAssertEqual(NativeWikipediaClient.summaryURL(language: "en", title: "AC/DC?#")?.absoluteString,
                       "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC%3F%23")
        XCTAssertNil(NativeWikipediaClient.summaryURL(language: "evil.example", title: "x"))
    }

    func testWikipediaSummaryKeepsOnlyArticlesWithALead() throws {
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let page = ["desktop": ["page": "https://en.wikipedia.org/wiki/Linear_algebra"]]
        let standard = try XCTUnwrap(NativeWikipediaClient.parse(try json(["type": "standard", "title": "Linear algebra", "description": "Branch of mathematics",
            "extract": "Linear algebra is the branch of mathematics concerning linear equations such as\n\nlinear maps such as the following:\n\nand their representations",
            "content_urls": page]), language: "en"))
        XCTAssertEqual(standard.title, "Linear algebra")
        XCTAssertEqual(standard.description, "Branch of mathematics")
        XCTAssertEqual(standard.extract, "Linear algebra is the branch of mathematics concerning linear equations such as linear maps such as the following: and their representations")
        XCTAssertEqual(standard.url.absoluteString, "https://en.wikipedia.org/wiki/Linear_algebra")
        XCTAssertNil(NativeWikipediaClient.parse(try json(["type": "disambiguation", "title": "머큐리", "extract": "머큐리는", "content_urls": page]), language: "ko"))
        XCTAssertNil(NativeWikipediaClient.parse(try json(["type": "standard", "title": "Empty", "extract": " ", "content_urls": page]), language: "en"))
        XCTAssertNil(NativeWikipediaClient.parse(try json(["type": "standard", "title": "Plain", "extract": "text",
            "content_urls": ["desktop": ["page": "http://en.wikipedia.org/wiki/Plain"]]]), language: "en"))
        XCTAssertNil(NativeWikipediaClient.parse(Data("not json".utf8), language: "en"))
    }

    func testSearchUsesTheBrowsersEngineAndNeverOpensAnAddress() {
        XCTAssertEqual(NativeQuickLookupQuery.searchURL("linear algebra", engine: "google")?.absoluteString, "https://www.google.com/search?q=linear%20algebra")
        XCTAssertEqual(NativeQuickLookupQuery.searchURL("행렬", engine: "naver")?.host, "search.naver.com")
        XCTAssertEqual(NativeQuickLookupQuery.searchURL("matrix", engine: "duckduckgo")?.host, "duckduckgo.com")
        let address = NativeQuickLookupQuery.searchURL("Node.js", engine: "google")
        XCTAssertEqual(address?.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: address!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "\"Node.js\"")
    }

    // MARK: how long a card stays

    func testACardStaysAboutFiveSecondsAndLongerForLongerText() {
        XCTAssertEqual(NativeQuickLookupQuery.dwell(characters: 0), 5)
        XCTAssertEqual(NativeQuickLookupQuery.dwell(characters: 60), 5)
        XCTAssertEqual(NativeQuickLookupQuery.dwell(characters: 96), 8)
        XCTAssertEqual(NativeQuickLookupQuery.dwell(characters: 2_000), 10)
    }

    @MainActor
    func testAWordCardOpensItsSourceInABrowserTabOfThePaneThatAsked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quick-lookup-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(storageRoot: directory)
        let center = NativeQuickLookupCenter()
        var opened: [[String: Any]] = []
        let subscription = store.events.sink { event in
            if event.channel == "nativeWorkspace:openBrowserURL", let payload = event.payload as? [String: Any] { opened.append(payload) }
        }
        defer { subscription.cancel() }

        center.lookUp("…", owner: "pane", store: store)
        XCTAssertNil(center.card, "punctuation is nothing to look up")
        center.lookUp(" matrix. ", owner: "pane", store: store)
        XCTAssertEqual(center.card?.query, .word("matrix"))
        XCTAssertEqual(center.card?.phase, .loading)
        for _ in 0..<100 where center.card?.phase == .loading { try await Task.sleep(for: .milliseconds(50)) }
        guard case .result(.dictionary(let definition)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertEqual(definition.headword, "matrix")
        XCTAssertNil(center.preview, "a dictionary card has no web view")

        center.dismiss(owner: "another pane")
        XCTAssertNotNil(center.card, "only the pane that asked closes the card")
        center.hold(); XCTAssertTrue(center.held)
        center.openInBrowser()
        XCTAssertNil(center.card); XCTAssertFalse(center.held)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?["url"] as? String, "https://en.wiktionary.org/wiki/matrix#English")
        XCTAssertEqual(opened.first?["sourcePanelID"] as? String, "pane")
    }
}
