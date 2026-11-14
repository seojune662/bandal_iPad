import XCTest
import Combine
import PDFKit
import UIKit
@testable import Bandal

/// 자동 찾아보기: what is searched for, when a card comes by itself, when the model is called and how its
/// answer is read, and that every failure falls back without a card or a paywall.
final class NativeQuickLookupAutoTests: XCTestCase {
    // MARK: what is searched for (no model)

    func testAShortSelectionIsItsOwnQuery() {
        XCTAssertEqual(NativeQuickLookupTerm.query(for: "열역학 제2법칙", heading: nil), "열역학 제2법칙")
        XCTAssertEqual(NativeQuickLookupTerm.query(for: "고립계의 엔트로피는 감소하지 않는다", heading: nil), "고립계의 엔트로피는 감소하지 않는다")
        XCTAssertEqual(NativeQuickLookupTerm.query(for: "isolated system", heading: nil), "isolated system")
        XCTAssertNil(NativeQuickLookupTerm.query(for: "…", heading: nil))
    }

    func testALongSelectionIsSearchedByItsKeyTerm() {
        let korean = "엔트로피는 무질서도의 척도다. 고립계에서 엔트로피는 시간이 지나도 줄어들지 않으며 이것이 열역학 제2법칙이다."
        XCTAssertEqual(NativeQuickLookupTerm.query(for: korean, heading: nil), "엔트로피")
        let english = "Entropy of an isolated system never decreases over time in any spontaneous process."
        XCTAssertEqual(NativeQuickLookupTerm.query(for: english, heading: nil), "Entropy")
    }

    func testTheHeadingAboveSaysWhichTermMatters() {
        let text = "고립계의 엔트로피는 감소하지 않는다. 고립계는 외부와 에너지도 물질도 주고받지 않는 계를 말한다."
        XCTAssertEqual(NativeQuickLookupTerm.keyTerms(text, heading: "고립계").first, "고립계")
    }

    func testPredicatesParticlesAndFormulasAreNotTerms() {
        let terms = NativeQuickLookupTerm.keyTerms("감소하는 경향을 보인다. 효율은 1 - Tc/Th 이다.", heading: nil, limit: 8)
        XCTAssertTrue(terms.contains("경향"), "\(terms)")
        XCTAssertTrue(terms.contains("효율"), "\(terms)")
        for word in ["감소하", "감소하는", "보인다", "이다", "Tc", "Th", "1"] { XCTAssertFalse(terms.contains(word), "\(word) in \(terms)") }
        XCTAssertEqual(NativeQuickLookupTerm.stem("열역학의").stem, "열역학")
        XCTAssertEqual(NativeQuickLookupTerm.stem("과정으로").stem, "과정")
        XCTAssertEqual(NativeQuickLookupTerm.stem("차이").stem, "차이", "a stem of one letter keeps the word")
        XCTAssertTrue(NativeQuickLookupTerm.isPredicate("않는다"))
        XCTAssertTrue(NativeQuickLookupTerm.isPredicate("일정한"))
        XCTAssertFalse(NativeQuickLookupTerm.isPredicate("제한"))
        XCTAssertFalse(NativeQuickLookupTerm.isPredicate("엔트로피는"))
    }

    func testTheTextsLanguageIsTriedFirstThenTheOther() {
        XCTAssertEqual(NativeQuickLookupTerm.searches(text: "isolated system", query: "isolated system", heading: nil).map(\.language), ["en", "ko"])
        XCTAssertEqual(NativeQuickLookupTerm.searches(text: "고립계", query: "고립계", heading: nil).map(\.language), ["ko"], "a Hangul query has no English article to match")
        let mixed = NativeQuickLookupTerm.searches(text: "엔트로피(entropy)는 무질서도의 척도다", query: "엔트로피", heading: nil)
        XCTAssertEqual(mixed.map(\.language), ["ko", "en"])
        XCTAssertEqual(mixed.last?.query, "entropy")
    }

    // MARK: Wikipedia's search

    func testTheSearchRequestCarriesOnlyTheQuery() throws {
        let url = try XCTUnwrap(NativeWikipediaSearch.url(language: "ko", query: "엔트로피"))
        XCTAssertEqual(url.host, "ko.wikipedia.org")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["gsrsearch"], "엔트로피")
        XCTAssertEqual(items["generator"], "search")
        XCTAssertEqual(Set(items.keys), ["action", "format", "formatversion", "generator", "gsrsearch", "gsrlimit", "gsrnamespace", "prop", "exintro",
                                         "explaintext", "exsentences", "exlimit", "inprop", "ppprop", "redirects"])
        XCTAssertNil(NativeWikipediaSearch.url(language: "evil.example", query: "x"))
        // Nothing of the reader or the iPad: the app's name and site.
        XCTAssertEqual(NativeWikipediaSearch.userAgent, "Bandal (https://bandal.io)")
    }

    private func page(_ title: String, _ index: Int, extract: String? = nil, disambiguation: Bool = false, url: String? = nil) -> [String: Any] {
        var page: [String: Any] = ["title": title, "index": index, "extract": extract ?? title + "은(는) 설명이다.",
                                   "fullurl": url ?? "https://ko.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_")]
        if disambiguation { page["pageprops"] = ["disambiguation": ""] }
        return page
    }

    func testSearchHitsDropDisambiguationAndInsecurePages() throws {
        let data = try JSONSerialization.data(withJSONObject: ["query": ["pages": [
            page("엔트로피", 2), page("엔트로피 (동음이의)", 1, disambiguation: true), page("엔트로피 법칙", 3, url: "http://ko.wikipedia.org/wiki/x"),
            page("정보 엔트로피", 4, url: "https://example.com/wiki/x"), page("빈 문서", 5, extract: " ")]]])
        let hits = NativeWikipediaSearch.parse(data, language: "ko")
        XCTAssertEqual(hits.map(\.title), ["엔트로피"])
        XCTAssertEqual(NativeWikipediaSearch.parse(Data("{}".utf8), language: "ko"), [])
    }

    private func hit(_ title: String, _ rank: Int, extract: String = "", language: String = "ko") -> NativeWikipediaSearch.Hit {
        .init(title: title, extract: extract.isEmpty ? title + "에 관한 문서." : extract, description: nil,
              url: URL(string: "https://\(language).wikipedia.org/wiki/\(rank)")!, rank: rank)
    }

    func testTheBestHitIsTheQuerysOwnArticle() {
        let hits = [hit("열역학", 1), hit("엔트로피", 2), hit("열역학 제2법칙", 3)]
        XCTAssertEqual(NativeWikipediaSearch.best(hits, query: "엔트로피", context: nil)?.title, "엔트로피")
        XCTAssertEqual(NativeWikipediaSearch.best(hits, query: "열역학 제2법칙", context: nil)?.title, "열역학 제2법칙")
        XCTAssertEqual(NativeWikipediaSearch.best([hit("Isolated system", 1, language: "en")], query: "isolated system", context: nil)?.title, "Isolated system")
        // A sentence: the article on the word it is about.
        XCTAssertEqual(NativeWikipediaSearch.best(hits, query: "고립계의 엔트로피는 감소하지 않는다", context: "열역학 제2법칙")?.title, "엔트로피")
        // A search always answers something; nothing related is no article.
        XCTAssertNil(NativeWikipediaSearch.best([hit("대한민국의 역사", 1), hit("서울특별시", 2)], query: "카르노 기관 효율", context: nil))
    }

    func testTheHeadingPicksBetweenRelatedArticles() {
        let hits = [hit("순환 (그래프 이론)", 1, extract: "그래프에서 시작점과 끝점이 같은 경로."), hit("카르노 순환", 2, extract: "열역학에서 두 등온 과정과 두 단열 과정으로 이루어진 이상적인 순환.")]
        XCTAssertEqual(NativeWikipediaSearch.best(hits, query: "순환", context: "카르노 순환")?.title, "카르노 순환")
    }

    // MARK: the order an automatic lookup is tried in

    private final class Calls { var dictionary: [String] = []; var search: [String] = [] }
    private func resolver(_ calls: Calls, dictionary: [[String: Any]] = [],
                          search: @escaping (String, String) throws -> NativeWikipediaSummary? = { _, _ in nil }) -> NativeQuickLookupAutoResolver {
        NativeQuickLookupAutoResolver(dictionary: { calls.dictionary.append($0); return dictionary },
                                      search: { language, query, _ in calls.search.append(language + ":" + query); return try search(language, query) })
    }
    private func article(_ language: String, _ title: String) -> NativeWikipediaSummary {
        .init(language: language, title: title, description: nil, extract: title + " is a subject.", url: URL(string: "https://\(language).wikipedia.org/wiki/\(title)")!)
    }
    private let matrix: [[String: Any]] = [["headword": "matrix", "partOfSpeech": "명사", "senses": [["meaning": "행렬"]],
                                            "source": ["url": "https://en.wiktionary.org/wiki/matrix#English"]]]

    func testAnEnglishWordIsAnsweredByTheBundledDictionaryWithoutTheNetwork() async {
        let calls = Calls()
        let outcome = await resolver(calls, dictionary: matrix).resolve("matrix.", heading: nil)
        guard case .dictionary(let definition)? = outcome?.result else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(definition.headword, "matrix")
        XCTAssertEqual(calls.search, [])
    }

    func testAWordTakenFromASentenceIsSearchedNotLookedUpInTheDictionary() async {
        let calls = Calls()
        let outcome = await resolver(calls, dictionary: matrix) { language, query in self.article(language, query) }
            .resolve("Entropy of an isolated system never decreases over time in any spontaneous process.", heading: nil)
        XCTAssertEqual(calls.dictionary, [])
        XCTAssertEqual(outcome?.result, .wikipedia(article("en", "Entropy")))
    }

    func testATermIsTheBestSearchHitInTheTextsLanguageFirst() async {
        let calls = Calls()
        let outcome = await resolver(calls) { language, _ in language == "ko" ? nil : self.article("en", "Isolated system") }.resolve("isolated system", heading: nil)
        XCTAssertEqual(outcome?.result, .wikipedia(article("en", "Isolated system")))
        XCTAssertEqual(calls.search, ["en:isolated system"])
        let korean = Calls()
        _ = await resolver(korean) { _, _ in self.article("ko", "엔트로피") }.resolve("엔트로피", heading: nil)
        XCTAssertEqual(korean.search, ["ko:엔트로피"])
    }

    func testNothingFoundIsOnlyALinkToSearchTheWeb() async {
        let calls = Calls()
        let outcome = await resolver(calls).resolve("qwertyzxcv", heading: nil)
        XCTAssertEqual(outcome, .init(query: "qwertyzxcv", result: .search("qwertyzxcv")))
        XCTAssertEqual(calls.search, ["en:qwertyzxcv", "ko:qwertyzxcv"])
        XCTAssertEqual(calls.dictionary, ["qwertyzxcv"])
    }

    func testOfflineOrAFailingServerShowsNoCardAtAll() async {
        let offline = Calls()
        let none = await resolver(offline) { _, _ in throw URLError(.notConnectedToInternet) }.resolve("isolated system", heading: nil)
        XCTAssertNil(none)
        XCTAssertEqual(offline.search, ["en:isolated system"], "offline stops at the first request")
        let failing = Calls()
        let failed = await resolver(failing) { _, _ in throw URLError(.badServerResponse) }.resolve("isolated system", heading: nil)
        XCTAssertNil(failed, "a miss after a server error is not known to be a miss")
        XCTAssertEqual(failing.search, ["en:isolated system", "ko:isolated system"])
    }

    func testALongPassageIsSearchedByItsKeyTermWithTheHeadingAsContext() async {
        var context: String?
        let calls = Calls()
        let resolver = NativeQuickLookupAutoResolver(dictionary: { _ in [] }, search: { language, query, heading in
            calls.search.append(language + ":" + query); context = heading; return self.article("ko", query)
        })
        let outcome = await resolver.resolve("엔트로피는 무질서도의 척도다. 고립계에서 엔트로피는 시간이 지나도 줄어들지 않으며 이것이 열역학 제2법칙이다.", heading: "열역학 제2법칙")
        XCTAssertEqual(calls.search, ["ko:엔트로피"])
        XCTAssertEqual(context, "열역학 제2법칙")
        XCTAssertEqual(outcome?.query, "엔트로피")
        _ = calls
    }

    // MARK: when a card comes by itself

    func testAMarkdownSelectionIsLookedUpBetweenTwoAndTwoHundredCharacters() {
        XCTAssertNil(NativeQuickLookupTrigger.markdown("a"))
        XCTAssertNil(NativeQuickLookupTrigger.markdown(" \n "))
        XCTAssertNil(NativeQuickLookupTrigger.markdown("**"))
        XCTAssertEqual(NativeQuickLookupTrigger.markdown("ab"), "ab")
        XCTAssertNil(NativeQuickLookupTrigger.markdown(String(repeating: "가", count: 201)))
        XCTAssertNotNil(NativeQuickLookupTrigger.markdown(String(repeating: "가", count: 200)))
        XCTAssertEqual(NativeQuickLookupTrigger.markdown("**엔트로피**"), "엔트로피")
        XCTAssertEqual(NativeQuickLookupTrigger.markdown("## 2주차 정리"), "2주차 정리")
        XCTAssertEqual(NativeQuickLookupTrigger.markdown("[볼츠만](https://example.com) 식 $S = k \\ln W$"), "볼츠만 식 S = k \\ln W")
        XCTAssertEqual(NativeQuickLookupTrigger.markdown("- [ ] *엔트로피* 복습"), "엔트로피 복습")
    }

    func testASelectionMadeWhileTypingIsSkipped() {
        let now = Date()
        XCTAssertFalse(NativeQuickLookupTrigger.typing(lastEdit: nil, now: now))
        XCTAssertTrue(NativeQuickLookupTrigger.typing(lastEdit: now.addingTimeInterval(-0.2), now: now))
        XCTAssertFalse(NativeQuickLookupTrigger.typing(lastEdit: now.addingTimeInterval(-1), now: now))
    }

    func testOnlyALassoThatCaughtNothingLooksItselfUp() {
        let area = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)
        XCTAssertTrue(NativeQuickLookupTrigger.lasso(caughtObjects: false, region: area))
        XCTAssertFalse(NativeQuickLookupTrigger.lasso(caughtObjects: true, region: area), "a lasso around ink is only a selection")
        XCTAssertFalse(NativeQuickLookupTrigger.lasso(caughtObjects: false, region: nil))
        XCTAssertFalse(NativeQuickLookupTrigger.lasso(caughtObjects: false, region: CGRect(x: 0.1, y: 0.1, width: 0.004, height: 0.004)), "a tap-sized lasso")
    }

    func testTheMarkdownHeadingAboveTheSelection() {
        let note = "# 2주차 정리\n\n엔트로피는 무질서도의 척도다.\n\n## 카르노 순환\n\n효율은 1 - Tc/Th 이다.\n"
        XCTAssertEqual(NativeQuickLookupTrigger.markdownHeading(before: "효율은", in: note), "카르노 순환")
        XCTAssertEqual(NativeQuickLookupTrigger.markdownHeading(before: "무질서도", in: note), "2주차 정리")
        XCTAssertNil(NativeQuickLookupTrigger.markdownHeading(before: "없는 글", in: note))
    }

    func testTheRateLimitAndTheCache() {
        var limit = NativeQuickLookupRateLimit(limit: 2, window: 60)
        let start = Date()
        XCTAssertTrue(limit.allow(at: start)); XCTAssertTrue(limit.allow(at: start.addingTimeInterval(1)))
        XCTAssertFalse(limit.allow(at: start.addingTimeInterval(2)))
        XCTAssertTrue(limit.allow(at: start.addingTimeInterval(61)))
        var cache = NativeQuickLookupCache(capacity: 2)
        let content = NativeQuickLookupAutoContent(query: "a", result: .search("a"))
        cache.store(content, for: "a"); cache.store(nil, for: "b")
        XCTAssertEqual(cache.lookup("a"), .some(content))
        XCTAssertEqual(cache.lookup("b"), .some(nil), "knowing there is nothing is kept too")
        XCTAssertNil(cache.lookup("c") as NativeQuickLookupAutoContent??)
        cache.store(content, for: "c")
        XCTAssertNil(cache.lookup("a") as NativeQuickLookupAutoContent??, "the oldest goes first")
    }

    // MARK: the printed text inside a lasso

    private func lecturePDF() throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { renderer in
            renderer.beginPage()
            for (row, line) in ["열역학 제2법칙", "고립계의 엔트로피는 감소하지 않는다.", "Entropy of an isolated system never decreases."].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 90 + CGFloat(row) * (row == 0 ? 0 : 44) + (row > 0 ? 30 : 0)),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: row == 0 ? 30 : 18, weight: row == 0 ? .semibold : .regular)])
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-lookup-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testALassoReadsThePrintedTextInsideItAndTheHeadingAbove() async throws {
        let url = try lecturePDF()
        // The first body line sits at y 164…186 of 842 points.
        let line = CGRect(x: 50 / 595.28, y: 158 / 841.89, width: 400 / 595.28, height: 34 / 841.89)
        let reading = await NativeQuickLookupPDFText.read(url: url, page: 1, region: line)
        XCTAssertEqual(reading?.text, "고립계의 엔트로피는 감소하지 않는다.")
        XCTAssertEqual(reading?.heading, "열역학 제2법칙")
        let heading = await NativeQuickLookupPDFText.read(url: url, page: 1, region: CGRect(x: 0.08, y: 0.09, width: 0.6, height: 0.07))
        XCTAssertEqual(heading?.text, "열역학 제2법칙")
        XCTAssertNil(heading?.heading)
        let blank = await NativeQuickLookupPDFText.read(url: url, page: 1, region: CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.2))
        XCTAssertNil(blank, "an empty area of a page with text is nothing to look up")
    }

    // MARK: when the model is called

    func testOnlyPassagesAreExplained() {
        for text in ["entropy", "열역학 제2법칙", "linear algebra", "dS = dQ/T", "Node.js"] { XCTAssertFalse(NativeQuickLookupExplain.isPassage(text), text) }
        for text in ["고립계의 엔트로피는 감소하지 않는다.", "Entropy of an isolated system never decreases.", "카르노 순환\n두 등온 과정과 두 단열 과정",
                     "one two three four five"] { XCTAssertTrue(NativeQuickLookupExplain.isPassage(text), text) }
    }

    func testThePlanTheSwitchAndTheDailyLimitGateTheModel() {
        let passage = "고립계의 엔트로피는 감소하지 않는다."
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .free, usedToday: 0))
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .plus, usedToday: 29))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .plus, usedToday: 30))
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .pro, usedToday: 99))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .pro, usedToday: 100))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: false, text: passage, tier: .pro, usedToday: 0))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "엔트로피", tier: .pro, usedToday: 0), "one term is looked up, not explained")
        XCTAssertFalse(NativeQuickLookupPreferences.explainsByDefault, "AI 설명 starts off")
    }

    func testTheDailyCountIsPerAccountAndPerDay() {
        let user = "test-" + UUID().uuidString
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(NativeQuickLookupPreferences.explanationsToday(user: user, now: day), 0)
        NativeQuickLookupPreferences.recordExplanation(user: user, now: day)
        NativeQuickLookupPreferences.recordExplanation(user: user, now: day)
        XCTAssertEqual(NativeQuickLookupPreferences.explanationsToday(user: user, now: day), 2)
        XCTAssertEqual(NativeQuickLookupPreferences.explanationsToday(user: "someone-else", now: day), 0)
        XCTAssertEqual(NativeQuickLookupPreferences.explanationsToday(user: user, now: day.addingTimeInterval(86_400)), 0, "a new day starts at zero")
    }

    private let config: [String: Any] = ["consentVersion": 1, "usage": ["consents": ["openai": 1, "anthropic": 1]], "models": [
        ["id": "claude-haiku-5-5", "provider": "anthropic", "badge": 1], ["id": "claude-sonnet-5-5", "provider": "anthropic", "badge": 20],
        ["id": "gpt-6-luna", "provider": "openai", "badge": 1], ["id": "gpt-6-sol", "provider": "openai", "badge": 20]]]

    @MainActor
    func testTheCheapestModelOfAProviderAlreadyAgreedTo() {
        let both = NativeQuickLookupExplain.consented(config, user: "u", granted: { _, _, _ in true })
        XCTAssertEqual(both, [.openai, .claude])
        XCTAssertEqual(NativeQuickLookupExplain.cheapest(config, consented: both)?.model, "gpt-6-luna", "both agreed to: gpt-6-luna")
        let claude = NativeQuickLookupExplain.consented(config, user: "u", granted: { provider, _, _ in provider == .claude })
        XCTAssertEqual(NativeQuickLookupExplain.cheapest(config, consented: claude)?.model, "claude-haiku-5-5")
        // Agreed to on this iPad but not on record at the server (or the other way): not agreed to.
        var unrecorded = config; unrecorded["usage"] = ["consents": ["openai": 1]]
        XCTAssertEqual(NativeQuickLookupExplain.consented(unrecorded, user: "u", granted: { _, _, _ in true }), [.openai])
        XCTAssertEqual(NativeQuickLookupExplain.consented(config, user: "u", granted: { _, _, _ in false }), [])
        XCTAssertNil(NativeQuickLookupExplain.cheapest(config, consented: []))
        // A cheaper model wins over the provider order.
        let pricier: [String: Any] = ["models": [["id": "gpt-6-sol", "provider": "openai", "badge": 20], ["id": "claude-haiku-5-5", "provider": "anthropic", "badge": 1]]]
        XCTAssertEqual(NativeQuickLookupExplain.cheapest(pricier, consented: [.openai, .claude])?.model, "claude-haiku-5-5")
    }

    func testTheRequestIsSmallCappedAndOnlyWhatTheProxyAccepts() throws {
        let long = String(repeating: "엔트로피는 감소하지 않는다. ", count: 40)
        let user = NativeQuickLookupExplain.user(text: long, heading: "열역학 제2법칙", title: "열역학 강의자료.pdf", language: "ko")
        XCTAssertTrue(user.contains("문서: 열역학 강의자료.pdf") && user.contains("제목 줄: 열역학 제2법칙") && user.contains("앱 언어: ko"), user)
        let passage = try XCTUnwrap(user.components(separatedBy: "고른 글:\n").last)
        XCTAssertEqual(passage.count, NativeQuickLookupExplain.maximumInputCharacters)
        let system = NativeQuickLookupExplain.system(english: false)
        // The proxy estimates a token per three UTF-8 bytes; the whole request stays near 500.
        XCTAssertLessThanOrEqual((system + user).utf8.count / 3, 650)

        let openai = NativeQuickLookupExplain.body(provider: .openai, model: "gpt-6-luna", system: system, user: user)
        XCTAssertEqual(openai["max_output_tokens"] as? Int, 120)
        XCTAssertEqual((openai["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(openai["store"] as? Bool, false)
        XCTAssertTrue(Set(openai.keys).isSubset(of: ["model", "instructions", "input", "stream", "store", "include", "tools", "reasoning", "max_output_tokens"]))
        let claude = NativeQuickLookupExplain.body(provider: .claude, model: "claude-haiku-5-5", system: system, user: user)
        XCTAssertEqual(claude["max_tokens"] as? Int, 120)
        XCTAssertEqual((claude["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertTrue(Set(claude.keys).isSubset(of: ["model", "system", "messages", "max_tokens", "stream", "tools", "output_config"]))
        let gemini = NativeQuickLookupExplain.body(provider: .gemini, model: "gemini-test", system: system, user: user)
        XCTAssertEqual((gemini["generationConfig"] as? [String: Int])?["maxOutputTokens"], 120)
        XCTAssertTrue(Set(gemini.keys).isSubset(of: ["model", "systemInstruction", "contents", "tools", "generationConfig"]))
        for body in [openai, claude, gemini] { XCTAssertNil(body["tools"], "no tools: one answer, no steps") }
    }

    // MARK: the model's answer

    func testTheAnswerIsReadFromItsThreeLines() {
        let selection = "가역 과정에서 dS = dQ/T.\n엔트로피는 상태 함수이므로 경로와 무관하다."
        let answer = NativeQuickLookupExplain.parse("주제: 엔트로피\n설명: 가역 과정에서 엔트로피 변화는 받은 열을 온도로 나눈 값이에요.\n수식: $dS = \\frac{dQ}{T}$", selection: selection)
        XCTAssertEqual(answer, .explanation(.init(topic: "엔트로피", summary: "가역 과정에서 엔트로피 변화는 받은 열을 온도로 나눈 값이에요.", formula: "dS = \\frac{dQ}{T}")))
        XCTAssertEqual(NativeQuickLookupExplain.parse("**주제**: 엔트로피\n**설명**: 상태 함수예요.\n수식:", selection: selection),
                       .explanation(.init(topic: "엔트로피", summary: "상태 함수예요.", formula: nil)))
        XCTAssertEqual(NativeQuickLookupExplain.parse("건너뛰기", selection: selection), .skip)
        XCTAssertEqual(NativeQuickLookupExplain.parse("주제: 건너뛰기", selection: selection), .skip)
        XCTAssertNil(NativeQuickLookupExplain.parse("엔트로피에 대한 설명입니다.", selection: selection), "no format, no answer")
        XCTAssertNil(NativeQuickLookupExplain.parse("주제: 엔트로피\n수식: S", selection: selection), "no explanation")
    }

    func testTheModelGivesNoLinksAndNoFormulaThatIsNotInTheText() {
        let selection = "고립계의 엔트로피는 감소하지 않는다."
        let answer = NativeQuickLookupExplain.parse("주제: 엔트로피\n설명: [위키백과](https://ko.wikipedia.org/wiki/x) 참고 https://evil.example 상태 함수예요.\n수식: E = mc^2", selection: selection)
        guard case .explanation(let explanation)? = answer else { return XCTFail("\(String(describing: answer))") }
        XCTAssertFalse(explanation.summary.contains("http"), explanation.summary)
        XCTAssertNil(explanation.formula, "E, m, c and 2 are not in the selection")
        XCTAssertTrue(NativeQuickLookupExplain.formulaAppears("\\eta = 1 - \\frac{T_c}{T_h}", in: "효율은 1 - Tc/Th 이다."))
        XCTAssertFalse(NativeQuickLookupExplain.formulaAppears("\\Delta S \\geq 0", in: selection))
        XCTAssertFalse(NativeQuickLookupExplain.formulaAppears("\\alpha", in: selection), "only commands: nothing to check it against")
    }

    @MainActor
    func testStreamEventsGiveTheTextAndTheTokens() throws {
        var openai = NativeQuickLookupExplainer.Reply()
        for event: [String: Any] in [["type": "response.output_text.delta", "delta": "주제: "], ["type": "response.output_text.delta", "delta": "엔트로피"],
                                     ["type": "response.completed", "response": ["usage": ["input_tokens": 470, "output_tokens": 41]]]] {
            try NativeQuickLookupExplainTransport.read(event, provider: .openai, into: &openai)
        }
        XCTAssertEqual(openai, .init(text: "주제: 엔트로피", inputTokens: 470, outputTokens: 41))
        var claude = NativeQuickLookupExplainer.Reply()
        for event: [String: Any] in [["type": "message_start", "message": ["usage": ["input_tokens": 512]]],
                                     ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "건너뛰기"]],
                                     ["type": "message_delta", "usage": ["output_tokens": 6], "delta": ["stop_reason": "end_turn"]]] {
            try NativeQuickLookupExplainTransport.read(event, provider: .claude, into: &claude)
        }
        XCTAssertEqual(claude, .init(text: "건너뛰기", inputTokens: 512, outputTokens: 6))
        var gemini = NativeQuickLookupExplainer.Reply()
        try NativeQuickLookupExplainTransport.read(["candidates": [["content": ["parts": [["text": "생각", "thought": true], ["text": "주제: 엔트로피"]]]]],
                                                    "usageMetadata": ["promptTokenCount": 430, "candidatesTokenCount": 30, "thoughtsTokenCount": 12]], provider: .gemini, into: &gemini)
        XCTAssertEqual(gemini, .init(text: "주제: 엔트로피", inputTokens: 430, outputTokens: 42))
        XCTAssertThrowsError(try NativeQuickLookupExplainTransport.read(["error": ["message": "Overloaded"]], provider: .claude, into: &claude))
    }

    // MARK: the call and its fallbacks

    @MainActor
    private func explainer(tier: Membership.Tier = .pro, used: Int = 0, signedIn: Bool = true,
                           send: @escaping (NativeQuickLookupExplainer.Call) async throws -> NativeQuickLookupExplainer.Reply) -> (NativeQuickLookupExplainer, Recorder) {
        let recorder = Recorder()
        let explainer = NativeQuickLookupExplainer()
        explainer.enabled = { true }
        explainer.tier = { tier }
        explainer.endpoint = {
            recorder.endpoint += 1
            guard signedIn else { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return AIEndpoint(userID: "u", projectURL: URL(string: "https://example.invalid")!, publishableKey: "", token: { "" })
        }
        let config = self.config
        explainer.config = { config }
        explainer.granted = { _, _, _ in true }
        explainer.used = { _ in used + recorder.recorded }
        explainer.record = { _ in recorder.recorded += 1 }
        explainer.send = { call in recorder.calls.append(call.model); return try await send(call) }
        return (explainer, recorder)
    }
    private final class Recorder { var endpoint = 0; var recorded = 0; var calls: [String] = [] }
    private let passage = "고립계의 엔트로피는 감소하지 않는다.\nEntropy of an isolated system never decreases."

    @MainActor
    func testAPassageIsExplainedByOneCallToTheCheapestModel() async {
        let (explainer, recorder) = explainer { call in
            XCTAssertEqual(call.provider, .openai)
            return .init(text: "주제: 엔트로피\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식:", inputTokens: 480, outputTokens: 40)
        }
        let answer = await explainer.explain(text: passage, heading: "열역학 제2법칙", title: "열역학 강의자료.pdf")
        XCTAssertEqual(answer, .explanation(.init(topic: "엔트로피", summary: "고립계의 엔트로피는 줄지 않아요.", formula: nil)))
        XCTAssertEqual(recorder.calls, ["gpt-6-luna"])
        XCTAssertEqual(recorder.recorded, 1)
    }

    @MainActor
    func testFreeSignedOutWordsAndTheDailyLimitNeverCall() async {
        let fail: (NativeQuickLookupExplainer.Call) async throws -> NativeQuickLookupExplainer.Reply = { _ in XCTFail("no call"); return .init() }
        let (free, freeCalls) = explainer(tier: .free, send: fail)
        let none = await free.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(none); XCTAssertEqual(freeCalls.endpoint, 0, "a free reader is not even signed in for it")
        let (word, _) = explainer(send: fail)
        let term = await word.explain(text: "엔트로피", heading: nil, title: "")
        XCTAssertNil(term)
        let (signedOut, _) = explainer(signedIn: false, send: fail)
        let out = await signedOut.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(out)
        let (spent, spentCalls) = explainer(tier: .plus, used: 30, send: fail)
        let limit = await spent.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(limit); XCTAssertEqual(spentCalls.recorded, 0)
        let (pro, _) = explainer(tier: .pro, used: 30) { _ in .init(text: "건너뛰기") }
        let skip = await pro.explain(text: passage, heading: nil, title: "")
        XCTAssertEqual(skip, .skip, "Pro has 100 a day")
    }

    @MainActor
    func testALateFailingOrUnreadableAnswerIsNoAnswer() async {
        let (slow, _) = explainer { _ in try await Task.sleep(for: .seconds(5)); return .init(text: "주제: x\n설명: y") }
        slow.deadline = .milliseconds(200)
        let started = Date()
        let late = await slow.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(late)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline does not wait for the call")
        XCTAssertEqual(NativeQuickLookupExplain.deadline, .seconds(2))
        let (refused, _) = explainer { _ in throw AIError.server(code: "BUDGET_EXHAUSTED", info: ["usage": ["plan": "plus"]]) }
        let budget = await refused.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(budget)
        let (rambling, _) = explainer { _ in .init(text: "엔트로피는 무질서도입니다.") }
        let unreadable = await rambling.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(unreadable)
    }

    // MARK: the controller

    @MainActor
    private func controller(_ center: NativeQuickLookupCenter, resolverCalls: Calls,
                            search: @escaping (String, String) async throws -> NativeWikipediaSummary?) -> NativeQuickLookupAuto {
        let auto = NativeQuickLookupAuto()
        auto.center = center
        auto.resolver = NativeQuickLookupAutoResolver(dictionary: { _ in [] }, search: { language, query, _ in
            resolverCalls.search.append(language + ":" + query); return try await search(language, query)
        })
        auto.explainer.enabled = { false }
        auto.engine = { _ in "google" }
        auto.settle = .milliseconds(80)
        return auto
    }
    @MainActor
    private func waitForCard(_ center: NativeQuickLookupCenter, seconds: Double = 3) async throws {
        for _ in 0..<Int(seconds * 20) where center.card == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    private var savedAuto: Any?
    override func setUp() { savedAuto = UserDefaults.standard.object(forKey: NativeQuickLookupPreferences.autoKey) }
    override func tearDown() { UserDefaults.standard.set(savedAuto, forKey: NativeQuickLookupPreferences.autoKey) }

    @MainActor
    func testASettledMarkdownSelectionShowsTheSmallCard() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("auto-lookup-" + UUID().uuidString))
        auto.selectionChanged("엔트", owner: "note", title: "노트", store: store, target: nil) { "" }
        auto.selectionChanged("엔트로피", owner: "note", title: "노트", store: store, target: nil) { "# 열역학\n엔트로피" }
        try await waitForCard(center)
        XCTAssertEqual(center.card?.automatic, true)
        XCTAssertEqual(center.card?.phase, .result(.wikipedia(article("ko", "엔트로피"))))
        XCTAssertEqual(calls.search, ["ko:엔트로피"], "the selection that was still moving was not looked up")
        // The same selection again comes from the cache.
        center.dismiss(); auto.selectionChanged("", owner: "note", title: "노트", store: store, target: nil) { "" }
        auto.selectionChanged("엔트로피", owner: "note", title: "노트", store: store, target: nil) { "# 열역학\n엔트로피" }
        try await waitForCard(center)
        XCTAssertNotNil(center.card)
        XCTAssertEqual(calls.search, ["ko:엔트로피"])
    }

    @MainActor
    func testTypingAndTheSwitchKeepTheCardAway() async throws {
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("auto-lookup-" + UUID().uuidString))
        NativeQuickLookupPreferences.auto = .on
        // A selection that came with an edit (a format, undo) is not looked up, nor one edited while it settles.
        auto.edited(owner: "note")
        auto.selectionChanged("엔트로피", owner: "note", title: "", store: store, target: nil) { "" }
        auto.selectionChanged("", owner: "note", title: "", store: store, target: nil) { "" }
        try await Task.sleep(for: .milliseconds(700))
        auto.selectionChanged("카르노", owner: "note", title: "", store: store, target: nil) { "" }
        auto.edited(owner: "note")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(center.card); XCTAssertEqual(calls.search, [])
        // Turned off: nothing by itself.
        NativeQuickLookupPreferences.auto = .off
        auto.selectionChanged("", owner: "note", title: "", store: store, target: nil) { "" }
        auto.selectionChanged("엔트로피", owner: "note", title: "", store: store, target: nil) { "" }
        auto.look(.init(owner: "pdf", text: "엔트로피", heading: nil, title: ""), store: store, target: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(center.card); XCTAssertEqual(calls.search, [])
        // An ink lasso only selects.
        NativeQuickLookupPreferences.auto = .on
        auto.lasso(region: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1), caughtObjects: true, page: 1, original: URL(fileURLWithPath: "/nonexistent.pdf"),
                   title: "", owner: "pdf", store: store)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(center.card); XCTAssertEqual(calls.search, [])
    }

    @MainActor
    func testTheFirstLookupAsksOnceAndTheAnswerStays() async throws {
        NativeQuickLookupPreferences.auto = .undecided
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        auto.look(.init(owner: "pdf", text: "엔트로피", heading: nil, title: ""), store: nil, target: nil)
        XCTAssertEqual(center.consentOwner, "pdf")
        XCTAssertNil(center.card); XCTAssertEqual(calls.search, [], "nothing is sent before the reader agrees")
        center.answerAutomatic(true)
        XCTAssertEqual(NativeQuickLookupPreferences.auto, .on)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.automatic, true)
        XCTAssertNil(center.consentOwner)

        NativeQuickLookupPreferences.auto = .undecided
        center.dismiss()
        auto.look(.init(owner: "pdf", text: "카르노", heading: nil, title: ""), store: nil, target: nil)
        center.answerAutomatic(false)
        XCTAssertEqual(NativeQuickLookupPreferences.auto, .off, "나중에 leaves it off; Settings turns it on")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(center.card)
        XCTAssertEqual(calls.search, ["ko:엔트로피"])
    }

    @MainActor
    func testANewSelectionCancelsTheLookupInFlight() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in
            if query == "엔트로피" { try await Task.sleep(for: .seconds(2)) }
            return self.article(language, query)
        }
        auto.look(.init(owner: "pdf", text: "엔트로피", heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(100))
        auto.look(.init(owner: "pdf", text: "카르노", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        guard case .result(.wikipedia(let summary)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertEqual(summary.title, "카르노")
        try await Task.sleep(for: .milliseconds(2200))
        guard case .result(.wikipedia(let still)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertEqual(still.title, "카르노", "the cancelled lookup never replaced the newer card")
        XCTAssertEqual(auto.cache.count, 1, "a cancelled lookup is not cached")
    }

    @MainActor
    func testOfflineAutomaticLookupsShowNothingAndAreTriedAgainLater() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        var offline = true
        let auto = controller(center, resolverCalls: calls) { language, query in
            if offline { throw URLError(.notConnectedToInternet) }
            return self.article(language, query)
        }
        auto.look(.init(owner: "pdf", text: "엔트로피", heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(center.card, "offline, no card and no error")
        offline = false
        auto.look(.init(owner: "pdf", text: "엔트로피", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertNotNil(center.card)
        XCTAssertEqual(calls.search, ["ko:엔트로피", "ko:엔트로피"])
    }

    @MainActor
    func testAFailedExplanationFallsBackToTheLookupWithoutAModel() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let (failing, recorder) = explainer { _ in throw AIError.server(code: "TASK_CAP_REACHED", info: [:]) }
        auto.explainer = failing
        auto.look(.init(owner: "pdf", text: passage, heading: "열역학 제2법칙", title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(recorder.calls, ["gpt-6-luna"])
        XCTAssertNil(center.card?.explanation)
        guard case .result(.wikipedia) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }

        // An answer: AI 설명 with the topic's article as the link.
        center.dismiss()
        let (working, _) = explainer { _ in .init(text: "주제: 엔트로피\n설명: 줄지 않아요.\n수식:") }
        auto.explainer = working
        auto.look(.init(owner: "pdf", text: passage + " ", heading: "열역학 제2법칙", title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.explanation?.topic, "엔트로피")
        XCTAssertEqual(center.card?.phase, .result(.wikipedia(article("ko", "엔트로피"))))
        XCTAssertEqual(NativeQuickLookupCenter.pageURL(center.card!)?.host, "ko.wikipedia.org", "the link is Wikipedia's, never the model's")
    }

    @MainActor
    func testAnAutomaticCardOpensItsPageInABrowserTab() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auto-lookup-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(storageRoot: directory)
        let center = NativeQuickLookupCenter()
        var opened: [String] = []
        let subscription = store.events.sink { event in
            if event.channel == "nativeWorkspace:openBrowserURL", let url = (event.payload as? [String: Any])?["url"] as? String { opened.append(url) }
        }
        defer { subscription.cancel() }
        center.showAutomatic(.init(query: "qwertyzxcv", result: .search("qwertyzxcv")), owner: "pdf", engine: "google", store: store, target: nil)
        XCTAssertEqual(center.card?.automatic, true)
        XCTAssertNil(center.preview, "an automatic card never loads a search page")
        center.openInBrowser()
        XCTAssertEqual(opened, ["https://www.google.com/search?q=qwertyzxcv"])
        XCTAssertNil(center.card)
    }
}
