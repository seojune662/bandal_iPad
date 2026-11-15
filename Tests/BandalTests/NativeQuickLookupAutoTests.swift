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
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .free, usedToday: 4), "Free has five a day")
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .free, usedToday: 5))
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .plus, usedToday: 29))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .plus, usedToday: 30))
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .pro, usedToday: 99))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: passage, tier: .pro, usedToday: 100))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: false, text: passage, tier: .pro, usedToday: 0))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "엔트로피", tier: .pro, usedToday: 0), "one term is looked up, not explained")
        XCTAssertTrue(NativeQuickLookupPreferences.explainsByDefault, "AI 설명 starts on: a passage is only worth a card when a model read it")
        // An area that has to be seen is read whatever its text is; the plan and the day's limit still hold.
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "q w ~ 1 R", picture: true, tier: .plus, usedToday: 0))
        XCTAssertTrue(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "", picture: true, tier: .pro, usedToday: 0))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "", picture: true, tier: .free, usedToday: 5))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: true, text: "", picture: true, tier: .plus, usedToday: 30))
        XCTAssertFalse(NativeQuickLookupExplain.allowedLocally(enabled: false, text: "", picture: true, tier: .pro, usedToday: 0))
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
        // The proxy estimates a token per three UTF-8 bytes; the text of the whole request stays under 900.
        XCTAssertLessThanOrEqual((system + user).utf8.count / 3, 900)
        XCTAssertTrue(system.contains("검색어:") && system.contains("건너뛰기"), system)

        let openai = NativeQuickLookupExplain.body(provider: .openai, model: "gpt-6-luna", system: system, user: user)
        XCTAssertEqual(openai["max_output_tokens"] as? Int, 400)
        XCTAssertEqual((openai["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(openai["store"] as? Bool, false)
        XCTAssertTrue(Set(openai.keys).isSubset(of: ["model", "instructions", "input", "stream", "store", "include", "tools", "reasoning", "max_output_tokens"]))
        let claude = NativeQuickLookupExplain.body(provider: .claude, model: "claude-haiku-5-5", system: system, user: user)
        XCTAssertEqual(claude["max_tokens"] as? Int, 400)
        XCTAssertEqual((claude["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertTrue(Set(claude.keys).isSubset(of: ["model", "system", "messages", "max_tokens", "stream", "tools", "output_config"]))
        let gemini = NativeQuickLookupExplain.body(provider: .gemini, model: "gemini-test", system: system, user: user)
        XCTAssertEqual((gemini["generationConfig"] as? [String: Int])?["maxOutputTokens"], 400)
        XCTAssertTrue(Set(gemini.keys).isSubset(of: ["model", "systemInstruction", "contents", "tools", "generationConfig"]))
        for body in [openai, claude, gemini] { XCTAssertNil(body["tools"], "no tools: one answer, no steps") }
        XCTAssertEqual((openai["input"] as? [[String: Any]])?.first?["content"] as? String, user, "no picture: the text alone")
    }

    func testAnAreaThatHasToBeSeenGoesAsAPictureWithItsText() throws {
        let system = NativeQuickLookupExplain.system(english: false)
        let user = NativeQuickLookupExplain.user(text: "q w ~ 1 R", heading: "Aerodynamic Heating", title: "re-entry.pdf", language: "ko")
        let jpeg = "AAAA"
        // Each provider's own shape, the one the chat sends an attached image in and the proxy counts as an image.
        let openai = NativeQuickLookupExplain.body(provider: .openai, model: "gpt-6-luna", system: system, user: user, picture: jpeg)
        let parts = try XCTUnwrap((openai["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["input_text", "input_image"])
        XCTAssertEqual(parts[0]["text"] as? String, user)
        XCTAssertEqual(parts[1]["image_url"] as? String, "data:image/jpeg;base64,AAAA")
        let claude = NativeQuickLookupExplain.body(provider: .claude, model: "claude-haiku-5-5", system: system, user: user, picture: jpeg)
        let blocks = try XCTUnwrap((claude["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual(blocks[0]["source"] as? [String: String], ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"])
        XCTAssertEqual(blocks[1]["text"] as? String, user)
        let gemini = NativeQuickLookupExplain.body(provider: .gemini, model: "gemini-test", system: system, user: user, picture: jpeg)
        let pieces = try XCTUnwrap((gemini["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(pieces[0]["inlineData"] as? [String: String], ["mimeType": "image/jpeg", "data": "AAAA"])
        XCTAssertEqual(pieces[1]["text"] as? String, user)
        // Still only what the proxy accepts, with the same limits.
        XCTAssertTrue(Set(openai.keys).isSubset(of: ["model", "instructions", "input", "stream", "store", "include", "tools", "reasoning", "max_output_tokens"]))
        XCTAssertTrue(Set(claude.keys).isSubset(of: ["model", "system", "messages", "max_tokens", "stream", "tools", "output_config"]))
        XCTAssertTrue(Set(gemini.keys).isSubset(of: ["model", "systemInstruction", "contents", "tools", "generationConfig"]))
    }

    func testThePictureIsSmall() throws {
        // A lassoed area rendered large comes down to `pictureSide` on its longer side, as a JPEG.
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 900)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 900))
            ("q = 1 / √R" as NSString).draw(at: CGPoint(x: 80, y: 300), withAttributes: [.font: UIFont.systemFont(ofSize: 160)])
        }
        let encoded = try XCTUnwrap(NativeQuickLookupPDFText.jpeg(big))
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(image.size.width * image.scale, image.size.height * image.scale), NativeQuickLookupPDFText.pictureSide)
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "a JPEG")
        XCTAssertLessThan(data.count, 150_000)
        // A small area is not blown up.
        let small = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 60)) }
        let kept = try XCTUnwrap(UIImage(data: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(NativeQuickLookupPDFText.jpeg(small))))))
        XCTAssertLessThanOrEqual(max(kept.size.width * kept.scale, kept.size.height * kept.scale), 120 * small.scale)
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

    func testTheSearchWordsAreReadAndAPictureLetsTheFormulaBeReadOffIt() {
        // What the text layer gives for q̇_w ∼ 1/√R: pieces. The formula the model reads is not in them.
        let selection = "A concept of a blunt re-entry capsule\nq w ~ 1 R"
        let output = "주제: 정체점 가열\n설명: 뭉툭한 앞부분일수록 정체점의 열유속이 줄어요. 열유속은 곡률 반지름의 제곱근에 반비례해요.\n수식: $\\dot{q}_w \\sim \\frac{1}{\\sqrt{R}}$\n검색어: stagnation point heating blunt body"
        XCTAssertEqual(NativeQuickLookupExplain.parse(output, selection: selection, picture: true),
                       .explanation(.init(topic: "정체점 가열", summary: "뭉툭한 앞부분일수록 정체점의 열유속이 줄어요. 열유속은 곡률 반지름의 제곱근에 반비례해요.",
                                          formula: "\\dot{q}_w \\sim \\frac{1}{\\sqrt{R}}", search: "stagnation point heating blunt body")))
        // Without the picture the model only had the pieces: a formula with letters that are not there is dropped.
        guard case .explanation(let blind)? = NativeQuickLookupExplain.parse(output.replacingOccurrences(of: "\\sim", with: "= k"), selection: selection) else { return XCTFail("no answer") }
        XCTAssertNil(blind.formula)
        XCTAssertEqual(blind.search, "stagnation point heating blunt body")
        guard case .explanation(let seen)? = NativeQuickLookupExplain.parse(output.replacingOccurrences(of: "\\sim", with: "= k"), selection: selection, picture: true) else { return XCTFail("no answer") }
        XCTAssertEqual(seen.formula, "\\dot{q}_w = k \\frac{1}{\\sqrt{R}}", "read off the picture")
        // No search words, or too many: none, and the topic is what is searched for.
        guard case .explanation(let bare)? = NativeQuickLookupExplain.parse("주제: 엔트로피\n설명: 상태 함수예요.\n수식:\n검색어:", selection: selection) else { return XCTFail("no answer") }
        XCTAssertNil(bare.search)
        let long = String(repeating: "entropy ", count: 12)
        guard case .explanation(let wordy)? = NativeQuickLookupExplain.parse("주제: 엔트로피\n설명: 상태 함수예요.\n검색어: \(long)", selection: selection) else { return XCTFail("no answer") }
        XCTAssertNil(wordy.search)
        // A link is never the model's, in the search words either.
        guard case .explanation(let linked)? = NativeQuickLookupExplain.parse("주제: 엔트로피\n설명: 상태 함수예요.\n검색어: entropy https://evil.example", selection: selection) else { return XCTFail("no answer") }
        XCTAssertEqual(linked.search, "entropy")
        XCTAssertEqual(NativeQuickLookupExplain.parse("건너뛰기", selection: "", picture: true), .skip)
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

    // MARK: the answer as it arrives

    func testAnAnswerStillArrivingIsShownOnceItsTopicIsWrittenAndItsExplanationHasBegun() {
        let selection = "고립계의 엔트로피는 감소하지 않는다."
        let reply = "주제: 엔트로피\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식: $\\Delta S \\geq 0$\n검색어: second law entropy"
        var seen: [NativeQuickLookupExplanation] = []
        for end in reply.indices.dropFirst() + [reply.endIndex] {
            guard let part = NativeQuickLookupExplain.partial(String(reply[..<end]), selection: selection, picture: true), part != seen.last else { continue }
            seen.append(part)
        }
        // Nothing until "설명: " has a character after it; then the explanation grows.
        XCTAssertEqual(seen.first, .init(topic: "엔트로피", summary: "고", formula: nil))
        XCTAssertEqual(seen.map(\.summary).last, "고립계의 엔트로피는 줄지 않아요.")
        XCTAssertTrue(seen.allSatisfy { $0.topic == "엔트로피" }, "the topic is shown once its line is finished, never half of it")
        // The formula and the search words come only with their lines finished.
        XCTAssertEqual(seen.filter { $0.formula != nil }.first?.formula, "\\Delta S \\geq 0")
        XCTAssertNil(seen.first { $0.search != nil }, "the last line is never finished before the reply ends")
        XCTAssertEqual(NativeQuickLookupExplain.partial(reply + "\n", selection: selection, picture: true)?.search, "second law entropy")
        XCTAssertEqual(NativeQuickLookupExplain.parse(reply, selection: selection, picture: true),
                       .explanation(.init(topic: "엔트로피", summary: "고립계의 엔트로피는 줄지 않아요.", formula: "\\Delta S \\geq 0", search: "second law entropy")))

        for early in ["", "주제: 엔트", "주제: 엔트로피", "주제: 엔트로피\n", "주제: 엔트로피\n설명:", "주제: 엔트로피\n설명: ", "건너뛰기", "건너뛰기\n", "주제: 건너뛰기\n설명: 쪽 번호"] {
            XCTAssertNil(NativeQuickLookupExplain.partial(early, selection: selection), early)
        }
        // A link in what has come is dropped, as in the whole answer.
        XCTAssertEqual(NativeQuickLookupExplain.partial("주제: 엔트로피\n설명: https://evil.example 상태", selection: selection)?.summary, "상태")
    }

    @MainActor
    func testTheTransportPassesOnTheTextAsItGrows() throws {
        var reply = NativeQuickLookupExplainer.Reply()
        var parts: [String] = []
        let progress: (String) -> Void = { parts.append($0) }
        for event: [String: Any] in [["type": "response.created"], ["type": "response.output_text.delta", "delta": "주제: "],
                                     ["type": "response.output_text.delta", "delta": "엔트로피\n설명: 줄지"],
                                     ["type": "response.completed", "response": ["usage": ["input_tokens": 470, "output_tokens": 41]]]] {
            let before = reply.text.count
            try NativeQuickLookupExplainTransport.read(event, provider: .openai, into: &reply)
            if reply.text.count != before { progress(reply.text) }
        }
        XCTAssertEqual(parts, ["주제: ", "주제: 엔트로피\n설명: 줄지"], "only events with text, each with all the text so far")
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
    func testSignedOutWordsAndTheDailyLimitNeverCall() async {
        let fail: (NativeQuickLookupExplainer.Call) async throws -> NativeQuickLookupExplainer.Reply = { _ in XCTFail("no call"); return .init() }
        let (free, freeCalls) = explainer(tier: .free, used: 4) { _ in .init(text: "건너뛰기") }
        let fifth = await free.explain(text: passage, heading: nil, title: "")
        XCTAssertEqual(fifth, .skip, "Free has five a day")
        let sixth = await free.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(sixth); XCTAssertEqual(freeCalls.calls.count, 1)
        let (off, offCalls) = explainer(send: fail)
        off.enabled = { false }
        let none = await off.explain(text: passage, heading: nil, title: "")
        XCTAssertNil(none); XCTAssertEqual(offCalls.endpoint, 0, "switched off: not even signed in for it")
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
        XCTAssertEqual(NativeQuickLookupExplain.deadline, .seconds(6), "a picture takes a few seconds to read; the card says 읽는 중… meanwhile")
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
        auto.decider.enabled = { false }
        auto.engine = { _ in "google" }
        auto.settle = .milliseconds(80)
        auto.readingDelay = .milliseconds(20)
        return auto
    }
    /// Waits for a card with an answer on it; 읽는 중… is not one.
    @MainActor
    private func waitForCard(_ center: NativeQuickLookupCenter, seconds: Double = 3) async throws {
        for _ in 0..<Int(seconds * 20) where center.card == nil || center.card?.phase == .loading { try await Task.sleep(for: .milliseconds(50)) }
    }
    @MainActor
    private func waitForNoCard(_ center: NativeQuickLookupCenter, seconds: Double = 3) async throws {
        for _ in 0..<Int(seconds * 20) where center.card != nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    /// Waits for 읽는 중….
    @MainActor
    private func waitForReading(_ center: NativeQuickLookupCenter, seconds: Double = 2) async throws {
        for _ in 0..<Int(seconds * 100) where center.card?.phase != .loading { try await Task.sleep(for: .milliseconds(10)) }
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
    func testAPassageTheModelCouldNotReadGetsNoCardRatherThanAGuess() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let (failing, recorder) = explainer { _ in
            try await Task.sleep(for: .milliseconds(400))
            throw AIError.server(code: "TASK_CAP_REACHED", info: [:])
        }
        auto.explainer = failing
        auto.look(.init(owner: "pdf", text: passage, heading: "열역학 제2법칙", title: ""), store: nil, target: nil)
        XCTAssertNil(center.card, "not at once")
        try await waitForReading(center)
        XCTAssertEqual(center.card?.phase, .loading, "읽는 중… while the model reads")
        XCTAssertEqual(center.card?.automatic, true)
        try await waitForNoCard(center)
        XCTAssertNil(center.card, "nobody read the passage: no card made from one of its words")
        XCTAssertEqual(recorder.calls, ["gpt-6-luna"])
        XCTAssertEqual(calls.search, [], "the passage's words were not searched for")
        XCTAssertEqual(auto.cache.count, 0, "a failure is tried again next time")

        // An answer: AI 설명, opening a search for its topic (no search words in this reply).
        let (working, _) = explainer { _ in .init(text: "주제: 엔트로피\n설명: 줄지 않아요.\n수식:") }
        auto.explainer = working
        auto.look(.init(owner: "pdf", text: passage + " ", heading: "열역학 제2법칙", title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.explanation?.topic, "엔트로피")
        XCTAssertEqual(center.card?.phase, .result(.search("엔트로피")))
        XCTAssertEqual(NativeQuickLookupCenter.pageURL(center.card!)?.host, "www.google.com", "the link is the search engine's, never the model's")
        XCTAssertEqual(calls.search, [], "nothing is asked of Wikipedia before the card shows")
    }

    @MainActor
    func testAnExplanationOpensTheSearchEngineForTheModelsWords() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let (searching, _) = explainer { _ in .init(text: "주제: 정체점 가열\n설명: 앞이 뭉툭할수록 정체점이 덜 뜨거워져요.\n수식:\n검색어: stagnation point heating blunt body") }
        auto.explainer = searching
        auto.look(.init(owner: "pdf", text: passage, heading: "Aerodynamic Heating", title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.phase, .result(.search("stagnation point heating blunt body")))
        XCTAssertEqual(center.card?.explanation?.topic, "정체점 가열", "the card is the explanation")
        XCTAssertEqual(calls.search, [], "Wikipedia is not asked, even where it has an article")
        XCTAssertEqual(NativeQuickLookupCenter.pageURL(center.card!)?.host, "www.google.com")
        XCTAssertTrue(NativeQuickLookupCenter.pageURL(center.card!)?.query?.contains("stagnation") == true)
        // The reader's own search engine.
        center.dismiss()
        auto.engine = { _ in "naver" }
        auto.look(.init(owner: "pdf", text: passage + "\n다른 줄", heading: "Aerodynamic Heating", title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(NativeQuickLookupCenter.pageURL(center.card!)?.host, "search.naver.com")
        auto.engine = { _ in "google" }

        // No search words either: the topic is searched for.
        center.dismiss()
        let (bare, _) = explainer { _ in .init(text: "주제: 정체점 가열\n설명: 앞이 뭉툭할수록 덜 뜨거워져요.") }
        auto.explainer = bare
        auto.look(.init(owner: "pdf", text: passage + " ", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.phase, .result(.search("정체점 가열")))

        // 건너뛰기: no card, and the same selection is not asked about again.
        center.dismiss()
        let (skipping, skipped) = explainer { _ in .init(text: "건너뛰기") }
        auto.explainer = skipping
        let page = "3쪽\n목차는 다음과 같다."
        auto.look(.init(owner: "pdf", text: page, heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(center.card)
        auto.look(.init(owner: "pdf", text: page, heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(center.card)
        XCTAssertEqual(skipped.calls.count, 1, "knowing there is nothing is kept too")
    }

    @MainActor
    func testAnAreaThatHasToBeSeenIsSentAsItsPictureAndNeverGuessedFromItsText() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let url = try lecturePDF()
        let area = NativeQuickLookupAuto.Picture(url: url, page: 1, region: CGRect(x: 0.08, y: 0.18, width: 0.7, height: 0.12))
        var sent: [[String: Any]] = []
        let (reader, recorder) = explainer { call in
            sent.append(call.body)
            return .init(text: "주제: 엔트로피\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식: $\\Delta S \\geq 0$\n검색어: second law entropy", inputTokens: 900, outputTokens: 60)
        }
        auto.explainer = reader
        // Pieces of a formula: one "term", which without the picture would be looked up as a word.
        auto.look(.init(owner: "pdf", text: "S 0", heading: "열역학 제2법칙", title: "열역학.pdf", picture: area), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(recorder.calls, ["gpt-6-luna"])
        let parts = try XCTUnwrap((sent.first?["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(parts.last?["image_url"] as? String)
        XCTAssertTrue(image.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(Data(base64Encoded: String(image.dropFirst("data:image/jpeg;base64,".count))))), "the area, rendered")
        XCTAssertEqual(center.card?.explanation?.formula, "\\Delta S \\geq 0", "read off the picture: its letters need not be in the text")
        XCTAssertEqual(center.card?.phase, .result(.search("second law entropy")))

        // AI 설명 switched off: no card, and nothing looked up from the pieces.
        center.dismiss(); calls.search = []
        let (off, offCalls) = explainer { _ in XCTFail("no call"); return .init() }
        off.enabled = { false }
        auto.explainer = off
        auto.look(.init(owner: "pdf", text: "S 0", heading: "열역학 제2법칙", title: "열역학.pdf", picture: area), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(center.card)
        XCTAssertEqual(offCalls.calls, [])
        XCTAssertEqual(calls.search, [], "what has to be seen is not guessed from the pieces of text in it")
    }

    /// A model's reply that streams: `parts` are the text so far at each step, `gap` apart; then `end` (the whole
    /// reply), or a failure.
    @MainActor
    private func streaming(_ parts: [String], gap: Duration = .milliseconds(150), end: String?) -> (NativeQuickLookupExplainer, Recorder) {
        explainer { call in
            for part in parts { try await Task.sleep(for: gap); call.progress(part) }
            try await Task.sleep(for: gap)
            guard let end else { throw URLError(.networkConnectionLost) }
            return .init(text: end)
        }
    }
    private static let streamed = ["주제: 엔트로피\n설명: 고립계의", "주제: 엔트로피\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식:"]
    private static let whole = "주제: 엔트로피\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식:\n검색어: second law entropy"

    @MainActor
    func testTheCardShowsTheAnswerAsItArrivesInOneCard() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { _, _ in nil }
        auto.explainer = streaming(Self.streamed, end: Self.whole).0
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForReading(center)
        let id = try XCTUnwrap(center.card?.id)
        try await waitForCard(center)
        // The first part, on the same card as 읽는 중…, still arriving.
        XCTAssertEqual(center.card?.id, id, "updated in place, not a new card")
        XCTAssertEqual(center.card?.explanation?.summary, "고립계의")
        XCTAssertEqual(center.card?.streaming, true)
        XCTAssertEqual(center.card?.phase, .result(.search("엔트로피")), "until the search words come, the topic is searched for")
        XCTAssertTrue(center.isPending(owner: "pdf"))
        for _ in 0..<40 where center.card?.streaming == true { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(center.card?.id, id)
        XCTAssertEqual(center.card?.explanation?.summary, "고립계의 엔트로피는 줄지 않아요.")
        XCTAssertEqual(center.card?.streaming, false, "all of it is there: the card counts down to leave")
        XCTAssertEqual(center.card?.phase, .result(.search("second law entropy")))
        XCTAssertEqual(auto.cache.count, 1)
    }

    @MainActor
    func testAnAnswerCutOffHalfwayKeepsWhatCameAndIsAskedAgain() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { language, query in self.article(language, query) }
        let (cut, cutCalls) = streaming(Array(Self.streamed.prefix(1)), end: nil)
        auto.explainer = cut
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        for _ in 0..<40 where center.card?.streaming == true { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(center.card?.explanation?.summary, "고립계의", "what came stays")
        XCTAssertEqual(center.card?.streaming, false, "and leaves by itself like any card")
        XCTAssertEqual(calls.search, [], "not replaced by a guess from the passage")
        XCTAssertEqual(auto.cache.count, 0, "asked for again next time")
        XCTAssertEqual(cutCalls.calls.count, 1)
    }

    @MainActor
    func testACardClosedWhileTheAnswerArrivesStaysClosed() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { _, _ in nil }
        auto.explainer = streaming(Self.streamed, gap: .milliseconds(200), end: Self.whole).0
        let source = NativeQuickLookupAuto.Source(owner: "pdf", text: passage, heading: nil, title: "")
        auto.look(source, store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.streaming, true)
        center.dismiss()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(center.card, "neither the rest of the answer nor its end brings it back")
        XCTAssertEqual(auto.cache.count, 1, "the answer is kept for the next time")
        auto.look(source, store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.explanation?.summary, "고립계의 엔트로피는 줄지 않아요.")

        // A newer selection while an answer arrives: that card goes, and the newer selection's comes.
        center.dismiss()
        auto.explainer = streaming(Self.streamed, gap: .milliseconds(200), end: Self.whole).0
        auto.look(.init(owner: "pdf", text: passage + "\n셋째 줄", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.streaming, true)
        auto.cancel(owner: "pdf")
        XCTAssertNil(center.card, "the pane went away: its unfinished card with it")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(center.card)
    }

    @MainActor
    func testANewerSelectionTakesTheReadingCardAway() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter(), calls = Calls()
        let auto = controller(center, resolverCalls: calls) { _, _ in nil }
        let (slow, _) = explainer { _ in try await Task.sleep(for: .seconds(3)); return .init(text: "주제: x\n설명: y") }
        auto.explainer = slow
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForReading(center)
        XCTAssertEqual(center.card?.phase, .loading)
        // The pane goes away, or the lasso closes on ink: the lookup stops and so does its card.
        auto.cancel(owner: "pdf")
        XCTAssertNil(center.card)
        // Stopped before 읽는 중… came: it does not come afterwards.
        auto.readingDelay = .milliseconds(200)
        auto.look(.init(owner: "pdf", text: passage + " ", heading: nil, title: ""), store: nil, target: nil)
        auto.cancel(owner: "pdf")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(center.card)
        // 읽는 중… closed with ✕: the answer does not come up afterwards, and is there the next time.
        auto.readingDelay = .milliseconds(20)
        let (answering, answered) = explainer { _ in try await Task.sleep(for: .milliseconds(300)); return .init(text: "주제: 엔트로피\n설명: 줄지 않아요.") }
        auto.explainer = answering
        let closed = NativeQuickLookupAuto.Source(owner: "pdf", text: passage + "\n닫은 글", heading: nil, title: "")
        auto.look(closed, store: nil, target: nil)
        try await waitForReading(center)
        center.dismiss()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(center.card, "closed is closed")
        auto.look(closed, store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.explanation?.topic, "엔트로피")
        XCTAssertEqual(answered.calls.count, 1, "from the cache")
        center.dismiss()
        auto.readingDelay = .milliseconds(200)
        // A reader the model cannot be asked for (signed out) is refused at once: nothing comes and goes.
        let (signedOut, _) = explainer(signedIn: false) { _ in XCTFail("no call"); return .init() }
        auto.explainer = signedOut
        auto.look(.init(owner: "pdf", text: passage + "  ", heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(center.card)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(center.card, "the lookup was over before 읽는 중… was due")
        // A card with an answer on it is not the lookup's to take away.
        center.showAutomatic(.init(query: "엔트로피", result: .search("엔트로피")), owner: "pdf", engine: "google", store: nil, target: nil)
        center.dismissPending(owner: "pdf")
        XCTAssertNotNil(center.card)
        auto.cancel(owner: "pdf")
        XCTAssertNotNil(center.card)
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
