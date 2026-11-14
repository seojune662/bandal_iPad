import XCTest
@testable import Bandal

/// 찾아보기's decision step (OpenAI Decisions API through the ai-proxy): when it is asked, what it is sent, how its
/// answer is read and judged, that every failure falls back to the lookup as it was, the day's limit and the cache.
final class NativeQuickLookupDecideTests: XCTestCase {
    private static func hit(_ title: String, _ language: String = "ko", rank: Int, extract: String? = nil) -> NativeWikipediaSearch.Hit {
        .init(title: title, extract: extract ?? "\(title)은 열역학에서 쓰는 개념이다.", description: nil,
              url: URL(string: "https://\(language).wikipedia.org/wiki/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)")!, rank: rank)
    }
    private static let law = hit("열역학 제2법칙", rank: 1, extract: "열역학 제2법칙은 고립계의 엔트로피가 시간이 흘러도 줄어들지 않는다는 법칙이다.")
    private static let entropy = hit("엔트로피", rank: 2, extract: "엔트로피는 열역학적 계의 무질서한 정도를 나타내는 상태 함수이다.")
    private let passage = "고립계의 엔트로피는 감소하지 않는다.\n이것이 열역학 제2법칙이다."
    private let config: [String: Any] = ["consentVersion": 1, "usage": ["consents": ["openai": 1, "anthropic": 1]], "models": [
        ["id": "claude-haiku-5-5", "provider": "anthropic", "badge": 1], ["id": "gpt-6-luna", "provider": "openai", "badge": 1]]]

    private final class Recorder {
        var sent: [[String: Any]] = []
        var searches: [String] = []
        var recorded = 0
    }

    @MainActor
    private func decider(tier: Membership.Tier = .free, used: Int = 0, signedIn: Bool = true, config: [String: Any]? = nil,
                         granted: @escaping (AIProvider) -> Bool = { _ in true },
                         search: @escaping (String, String) async throws -> [NativeWikipediaSearch.Hit] = { _, _ in [NativeQuickLookupDecideTests.law, NativeQuickLookupDecideTests.entropy] },
                         send: @escaping ([String: Any]) async throws -> [NativeQuickLookupDecide.Answer]) -> (NativeQuickLookupDecider, Recorder) {
        let recorder = Recorder()
        let decider = NativeQuickLookupDecider()
        decider.enabled = { true }
        decider.tier = { tier }
        decider.endpoint = {
            guard signedIn else { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return AIEndpoint(userID: "u", projectURL: URL(string: "https://example.invalid")!, publishableKey: "", token: { "" })
        }
        let config = config ?? self.config
        decider.config = { config }
        decider.granted = { provider, _, _ in granted(provider) }
        decider.search = { language, query in recorder.searches.append(language + ":" + query); return try await search(language, query) }
        decider.used = { _ in used + recorder.recorded }
        decider.record = { _ in recorder.recorded += 1 }
        decider.send = { call in recorder.sent.append(call.body); return try await send(call.body) }
        return (decider, recorder)
    }
    private static func answers(worth: Double, choice: String? = nil, confidence: Double = 0.9) -> [NativeQuickLookupDecide.Answer] {
        [.init(name: "worth", type: "predicate", probability: worth)] + (choice.map { [.init(name: "article", type: "choice", choice: $0, confidence: confidence)] } ?? [])
    }

    // MARK: when it is asked

    @MainActor
    func testOnlyPassagesOfSignedInReadersWhoAgreedToOpenAIOnBothSidesAreDecided() async {
        let fail: ([String: Any]) async throws -> [NativeQuickLookupDecide.Answer] = { _ in XCTFail("no call"); return [] }
        let (word, wordCalls) = decider(send: fail)
        let term = await word.decide(text: "엔트로피", heading: nil, title: "")
        XCTAssertNil(term); XCTAssertEqual(wordCalls.searches, [], "one word or term is looked up without a model")
        XCTAssertFalse(word.wouldTry("열역학 제2법칙"))
        XCTAssertTrue(word.wouldTry(passage))

        let (off, _) = decider(send: fail); off.enabled = { false }
        let none = await off.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(none)
        let (signedOut, signedOutCalls) = decider(signedIn: false, send: fail)
        let out = await signedOut.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(out); XCTAssertEqual(signedOutCalls.searches, [], "nothing is searched for a decision that cannot be asked")
        // Agreed to on this iPad but not on record at the server, and the other way round.
        var unrecorded = config; unrecorded["usage"] = ["consents": ["anthropic": 1]]
        let (serverMissing, _) = decider(config: unrecorded, send: fail)
        let noServer = await serverMissing.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(noServer)
        let (deviceMissing, _) = decider(granted: { $0 != .openai }, send: fail)
        let noDevice = await deviceMissing.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(noDevice)
        // The server does not offer the decision model.
        var withoutLuna = config; withoutLuna["models"] = [["id": "claude-haiku-5-5", "provider": "anthropic", "badge": 1]]
        let (unoffered, _) = decider(config: withoutLuna, send: fail)
        let noModel = await unoffered.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(noModel)

        // A free reader who agreed: one call.
        let (free, freeCalls) = decider(tier: .free) { _ in Self.answers(worth: 0.9, choice: "열역학 제2법칙") }
        let verdict = await free.decide(text: passage, heading: "열역학 제2법칙", title: "열역학 강의자료.pdf")
        XCTAssertEqual(verdict, .article(NativeQuickLookupDecide.candidates([("ko", [Self.law, Self.entropy])])[0]))
        XCTAssertEqual(freeCalls.sent.count, 1)
        XCTAssertEqual(freeCalls.recorded, 1)
    }

    @MainActor
    func testTheDailyLimitPerPlan() async {
        XCTAssertEqual(NativeQuickLookupDecide.dailyLimit(.free), 5)
        XCTAssertEqual(NativeQuickLookupDecide.dailyLimit(.plus), 50)
        XCTAssertEqual(NativeQuickLookupDecide.dailyLimit(.pro), 150)
        for (tier, limit) in [(Membership.Tier.free, 5), (.plus, 50), (.pro, 150)] {
            let (under, underCalls) = decider(tier: tier, used: limit - 1) { _ in Self.answers(worth: 0.9, choice: "엔트로피") }
            let last = await under.decide(text: passage, heading: nil, title: "")
            XCTAssertNotNil(last, "\(tier): the \(limit)th call of the day")
            XCTAssertEqual(underCalls.sent.count, 1)
            let (over, overCalls) = decider(tier: tier, used: limit) { _ in XCTFail("no call over the limit"); return [] }
            let past = await over.decide(text: passage, heading: nil, title: "")
            XCTAssertNil(past, "\(tier): past the limit the lookup goes on without a decision")
            XCTAssertEqual(overCalls.searches, [])
        }
    }

    func testTheDailyCountIsPerAccountAndPerDay() {
        let user = "decide-" + UUID().uuidString
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(NativeQuickLookupPreferences.decisionsToday(user: user, now: day), 0)
        NativeQuickLookupPreferences.recordDecision(user: user, now: day)
        NativeQuickLookupPreferences.recordDecision(user: user, now: day)
        XCTAssertEqual(NativeQuickLookupPreferences.decisionsToday(user: user, now: day), 2)
        XCTAssertEqual(NativeQuickLookupPreferences.decisionsToday(user: "someone-else", now: day), 0)
        XCTAssertEqual(NativeQuickLookupPreferences.decisionsToday(user: user, now: day.addingTimeInterval(86_400)), 0, "a new day starts at zero")
        XCTAssertEqual(NativeQuickLookupPreferences.explanationsToday(user: user, now: day), 0, "AI 설명 is counted apart")
        XCTAssertTrue(NativeQuickLookupPreferences.decidesByDefault, "the decision step starts on")
    }

    // MARK: what it is sent

    func testTheSearchesAreThePassagesKeyTerms() {
        let korean = NativeQuickLookupDecide.searches(text: "엔트로피는 무질서도의 척도다. 고립계에서 엔트로피는 줄어들지 않으며 이것이 Carnot 순환과도 이어진다.", heading: nil)
        XCTAssertEqual(korean.first?.language, "ko")
        XCTAssertEqual(korean.first?.query, "엔트로피")
        XCTAssertLessThanOrEqual(korean.filter { $0.language == "ko" }.count, NativeQuickLookupDecide.maximumTerms)
        XCTAssertEqual(korean.filter { $0.language == "en" }.map(\.query), ["Carnot"], "a Korean text's Latin term is searched in English too")
        let english = NativeQuickLookupDecide.searches(text: "Entropy of an isolated system never decreases over time.", heading: nil)
        XCTAssertEqual(english.first?.query, "Entropy")
        XCTAssertTrue(english.allSatisfy { $0.language == "en" })
    }

    func testTheCandidatesKeepTheSearchOrder() {
        let first = [Self.hit("열역학 제2법칙", rank: 1), Self.hit("열역학", rank: 2), Self.hit("열기관", rank: 3)]
        let second = [Self.hit("엔트로피", rank: 1), Self.hit("열역학 제2법칙", rank: 2)]
        let english = [Self.hit("Entropy", "en", rank: 1), Self.hit("엔트로피", "en", rank: 2)]
        let candidates = NativeQuickLookupDecide.candidates([("ko", first), ("ko", second), ("en", english)])
        // Every search's first hit, then every second one; the same article once; at most four.
        XCTAssertEqual(candidates.map(\.value), ["열역학 제2법칙", "엔트로피", "Entropy", "열역학"])
        XCTAssertEqual(candidates.map(\.hit.url.host), ["ko.wikipedia.org", "ko.wikipedia.org", "en.wikipedia.org", "ko.wikipedia.org"])
        XCTAssertEqual(NativeQuickLookupDecide.candidates([("ko", first), ("ko", second), ("en", english)]), candidates, "the same searches, the same order")
        // Search order is the hits' rank, however they arrive.
        XCTAssertEqual(NativeQuickLookupDecide.candidates([("ko", first.reversed())]).map(\.value), ["열역학 제2법칙", "열역학"])
        // Two articles of one title (Korean and English Wikipedia) are told apart by their language.
        XCTAssertEqual(NativeQuickLookupDecide.candidates([("ko", [Self.hit("DNA", rank: 1)]), ("en", [Self.hit("DNA", "en", rank: 1)])]).map(\.value), ["DNA (ko)", "DNA (en)"])
        XCTAssertEqual(NativeQuickLookupDecide.candidates([("ko", [Self.hit(NativeQuickLookupDecide.noArticle, rank: 1)])]), [])
        XCTAssertEqual(NativeQuickLookupDecide.candidates([]), [])
    }

    func testTheRequestIsTextOnlySmallAndWhatTheProxyAccepts() throws {
        let long = String(repeating: "엔트로피는 감소하지 않는다. ", count: 40)
        let candidates = NativeQuickLookupDecide.candidates([("ko", [Self.law, Self.entropy, Self.hit("열역학", rank: 3)]),
                                                             ("ko", [Self.hit("열기관", rank: 1, extract: String(repeating: "열기관은 열을 일로 바꾼다. ", count: 20))])])
        let body = NativeQuickLookupDecide.body(text: long, heading: "열역학 제2법칙", title: "열역학 강의자료.pdf", candidates: candidates)
        XCTAssertEqual(Set(body.keys), ["model", "input", "questions"])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["developer", "user"])
        XCTAssertTrue(input.allSatisfy { Set($0.keys) == ["role", "content"] && $0["content"] is String }, "text only: no images, no parts")
        let user = try XCTUnwrap(input[1]["content"] as? String)
        XCTAssertTrue(user.contains("문서: 열역학 강의자료.pdf") && user.contains("제목 줄: 열역학 제2법칙"), user)
        XCTAssertEqual(try XCTUnwrap(user.components(separatedBy: "고른 글:\n").last).count, NativeQuickLookupDecide.maximumPassageCharacters)

        let questions = try XCTUnwrap(body["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.map { $0["name"] as? String }, ["worth", "article"])
        XCTAssertEqual(questions.map { $0["type"] as? String }, ["predicate", "choice"])
        XCTAssertEqual(Set(questions[0].keys), ["type", "name", "instructions"])
        XCTAssertEqual(Set(questions[1].keys), ["type", "name", "instructions", "choices"])
        let choices = try XCTUnwrap(questions[1]["choices"] as? [[String: String]])
        XCTAssertEqual(choices.map { $0["value"] }, ["열역학 제2법칙", "열기관", "엔트로피", NativeQuickLookupDecide.noArticle], "search order (two hits a search), 없음 last")
        XCTAssertTrue(choices.allSatisfy { Set($0.keys).isSubset(of: ["value", "description"]) && ($0["description"]?.count ?? 0) <= NativeQuickLookupDecide.maximumExtractCharacters })
        let json = try JSONSerialization.data(withJSONObject: body)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("wikipedia.org"), "no links go to the model")
        // Within the proxy's caps (8 questions, 12 choices, ~4,000 tokens at UTF-8 bytes / 3), and small: this is the longest request.
        XCTAssertLessThanOrEqual(json.count / 3, 1_300)

        // No article to choose from: 가 alone.
        let alone = NativeQuickLookupDecide.body(text: passage, heading: nil, title: "노트", candidates: [])
        XCTAssertEqual((alone["questions"] as? [[String: Any]])?.map { $0["name"] as? String }, ["worth"])
    }

    // MARK: how the answer is read

    func testTheAnswerIsReadAndJudged() throws {
        let candidates = NativeQuickLookupDecide.candidates([("ko", [Self.law, Self.entropy])])
        let data = Data(#"{"answers":[{"type":"predicate","name":"worth","probability":0.82},{"type":"choice","name":"article","choice":"엔트로피","confidence":0.74,"probabilities":[{"value":"엔트로피","probability":0.8}]}]}"#.utf8)
        let answers = try XCTUnwrap(NativeQuickLookupDecide.answers(data))
        XCTAssertEqual(answers, [.init(name: "worth", type: "predicate", probability: 0.82), .init(name: "article", type: "choice", choice: "엔트로피", confidence: 0.74)])
        XCTAssertEqual(NativeQuickLookupDecide.verdict(answers, candidates: candidates), .article(candidates[1]))
        XCTAssertNil(NativeQuickLookupDecide.answers(Data("<html>".utf8)))
        XCTAssertNil(NativeQuickLookupDecide.answers(Data(#"{"code":"AI_UNAVAILABLE"}"#.utf8)))

        let verdict = { (answers: [NativeQuickLookupDecide.Answer]) in NativeQuickLookupDecide.verdict(answers, candidates: candidates) }
        XCTAssertEqual(NativeQuickLookupDecide.minimumWorth, 0.3)
        XCTAssertEqual(NativeQuickLookupDecide.minimumConfidence, 0.5)
        XCTAssertEqual(verdict(Self.answers(worth: 0.29, choice: "엔트로피")), .skip, "not worth a card, whatever was chosen")
        XCTAssertEqual(verdict(Self.answers(worth: 0.3, choice: "엔트로피", confidence: 0.5)), .article(candidates[1]))
        XCTAssertEqual(verdict(Self.answers(worth: 0.9, choice: "엔트로피", confidence: 0.49)), .unsure)
        XCTAssertEqual(verdict(Self.answers(worth: 0.9, choice: NativeQuickLookupDecide.noArticle, confidence: 0.8)), .noArticle)
        XCTAssertEqual(verdict(Self.answers(worth: 0.9, choice: NativeQuickLookupDecide.noArticle, confidence: 0.2)), .unsure)
        // Not what was asked: no verdict, and the lookup goes on as without one.
        XCTAssertNil(verdict(Self.answers(worth: 0.9, choice: "열기관")), "a choice that was not offered")
        XCTAssertNil(verdict(Self.answers(worth: 0.9)), "no answer to 나")
        XCTAssertNil(verdict([.init(name: "worth", type: "refusal"), .init(name: "article", type: "choice", choice: "엔트로피", confidence: 0.9)]))
        XCTAssertNil(verdict([.init(name: "worth", type: "predicate", probability: 0.9), .init(name: "article", type: "refusal")]))
        XCTAssertNil(verdict([.init(name: "worth", type: "predicate", probability: 1.4)]))
        XCTAssertNil(verdict([]))
        // Nothing to choose from: 가 alone decides between no card and a search link.
        XCTAssertEqual(NativeQuickLookupDecide.verdict(Self.answers(worth: 0.8), candidates: []), .noArticle)
        XCTAssertEqual(NativeQuickLookupDecide.verdict(Self.answers(worth: 0.1), candidates: []), .skip)
    }

    @MainActor
    func testTheTransportReadsTheRouteAndTheServersRefusals() throws {
        XCTAssertThrowsError(try NativeQuickLookupDecideTransport.read(Data(#"{"code":"NOT_FOUND"}"#.utf8), status: 404)) { error in
            guard case NativeQuickLookupDecideTransport.Failure.routeMissing = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try NativeQuickLookupDecideTransport.read(Data("Function not found".utf8), status: 404)) { error in
            guard case NativeQuickLookupDecideTransport.Failure.routeMissing = error else { return XCTFail("\(error)") }
        }
        for (status, code) in [(402, "BUDGET_EXHAUSTED"), (409, "CONSENT_REQUIRED"), (401, "SIGN_IN_REQUIRED"), (503, "AI_UNAVAILABLE")] {
            XCTAssertThrowsError(try NativeQuickLookupDecideTransport.read(Data(#"{"code":"\#(code)"}"#.utf8), status: status)) { error in
                guard case AIError.server(let read, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(read, code)
            }
        }
        XCTAssertThrowsError(try NativeQuickLookupDecideTransport.read(Data("{}".utf8), status: 200))
        XCTAssertEqual(try NativeQuickLookupDecideTransport.read(Data(#"{"answers":[{"type":"refusal","name":"worth"}]}"#.utf8), status: 200),
                       [.init(name: "worth", type: "refusal")])
    }

    // MARK: every failure falls back

    @MainActor
    func testEveryFailureComesBackAsNoDecision() async {
        let failures: [(String, Error)] = [("budget", AIError.server(code: "BUDGET_EXHAUSTED", info: ["usage": ["plan": "none"]])),
                                           ("consent", AIError.server(code: "CONSENT_REQUIRED", info: ["provider": "openai"])),
                                           ("server", AIError.server(code: "AI_UNAVAILABLE", info: [:])),
                                           ("network", URLError(.notConnectedToInternet)),
                                           ("unreadable", NativeQuickLookupDecideTransport.Failure.unreadable)]
        for (name, failure) in failures {
            let (failing, calls) = decider { _ in throw failure }
            let verdict = await failing.decide(text: passage, heading: nil, title: "")
            XCTAssertNil(verdict, name)
            XCTAssertEqual(calls.sent.count, 1, name)
            XCTAssertTrue(failing.wouldTry(passage), "\(name): asked again next time")
        }
        let (refused, _) = decider { _ in [.init(name: "worth", type: "refusal"), .init(name: "article", type: "refusal")] }
        let refusal = await refused.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(refusal)

        let (slow, _) = decider { _ in try await Task.sleep(for: .seconds(5)); return Self.answers(worth: 0.9, choice: "엔트로피") }
        slow.deadline = .milliseconds(200)
        let started = Date()
        let late = await slow.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(late)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline does not wait for the call")
        XCTAssertEqual(NativeQuickLookupDecide.deadline, .milliseconds(1500))

        // Wikipedia cannot be asked at all: nothing is known, so no decision either (and no call).
        let (offline, offlineCalls) = decider(search: { _, _ in throw URLError(.notConnectedToInternet) }) { _ in XCTFail("no call"); return [] }
        let none = await offline.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(none); XCTAssertEqual(offlineCalls.sent.count, 0)
    }

    @MainActor
    func testARouteTheServerDoesNotHaveIsNotAskedAgainThisRun() async {
        let (missing, calls) = decider { _ in throw NativeQuickLookupDecideTransport.Failure.routeMissing }
        let first = await missing.decide(text: passage, heading: nil, title: "")
        XCTAssertNil(first)
        XCTAssertTrue(missing.routeMissing)
        XCTAssertFalse(missing.wouldTry(passage))
        let second = await missing.decide(text: passage + " ", heading: nil, title: "")
        XCTAssertNil(second)
        XCTAssertEqual(calls.sent.count, 1, "one 404, then no more calls")
        XCTAssertEqual(calls.recorded, 1)
    }

    // MARK: the card

    @MainActor
    private func controller(_ center: NativeQuickLookupCenter, decider: NativeQuickLookupDecider, searches: Recorder) -> NativeQuickLookupAuto {
        let auto = NativeQuickLookupAuto()
        auto.center = center
        auto.resolver = NativeQuickLookupAutoResolver(dictionary: { _ in [] }, search: { language, query, _ in
            searches.searches.append("resolver:" + language + ":" + query)
            return NativeWikipediaSummary(language: language, title: "검색 " + query, description: nil, extract: query + " 문서", url: URL(string: "https://\(language).wikipedia.org/wiki/x")!)
        })
        auto.explainer.enabled = { false }
        auto.decider = decider
        auto.engine = { _ in "google" }
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
    func testTheChosenArticleIsTheCardAndTheSameSelectionComesFromTheCache() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter()
        let (decider, calls) = decider { _ in Self.answers(worth: 0.9, choice: "열역학 제2법칙") }
        let auto = controller(center, decider: decider, searches: calls)
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(center.card?.phase, .result(.wikipedia(.init(language: "ko", title: "열역학 제2법칙", description: nil, extract: Self.law.extract, url: Self.law.url))))
        XCTAssertEqual(center.card?.automatic, true)
        XCTAssertFalse(calls.searches.contains { $0.hasPrefix("resolver:") }, "the search's own pick was not needed")
        center.dismiss()
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertNotNil(center.card)
        XCTAssertEqual(calls.sent.count, 1, "the same selection is not decided twice")
    }

    @MainActor
    func testNoArticleIsASearchLinkAndNotWorthItIsNoCard() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter()
        let (none, noneCalls) = decider { _ in Self.answers(worth: 0.9, choice: NativeQuickLookupDecide.noArticle) }
        let auto = controller(center, decider: none, searches: noneCalls)
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        guard case .result(.search(let query)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertFalse(query.isEmpty)
        XCTAssertFalse(noneCalls.searches.contains { $0.hasPrefix("resolver:") })

        center.dismiss()
        let (worthless, worthlessCalls) = decider { _ in Self.answers(worth: 0.05, choice: "엔트로피") }
        auto.decider = worthless
        let page = "과제는 다음 주 금요일까지 제출하세요.\n3쪽"
        auto.look(.init(owner: "pdf", text: page, heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(center.card, "not worth a card: none")
        XCTAssertFalse(worthlessCalls.searches.contains { $0.hasPrefix("resolver:") })
        auto.look(.init(owner: "pdf", text: page, heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(center.card)
        XCTAssertEqual(worthlessCalls.sent.count, 1, "knowing there is nothing is kept too")
    }

    @MainActor
    func testAnUnsureOrFailedDecisionLeavesTheLookupAsItWas() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter()
        let (unsure, unsureCalls) = decider { _ in Self.answers(worth: 0.9, choice: "엔트로피", confidence: 0.2) }
        let auto = controller(center, decider: unsure, searches: unsureCalls)
        auto.look(.init(owner: "pdf", text: passage, heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        guard case .result(.wikipedia(let summary)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertTrue(summary.title.hasPrefix("검색 "), "the search's own pick: \(summary.title)")
        XCTAssertTrue(unsureCalls.searches.contains { $0.hasPrefix("resolver:") })

        // No route on the server: the same, and no decision is asked again this run.
        center.dismiss()
        let (missing, missingCalls) = decider { _ in throw NativeQuickLookupDecideTransport.Failure.routeMissing }
        auto.decider = missing
        auto.look(.init(owner: "pdf", text: passage + "\n둘째 글", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        guard case .result(.wikipedia(let fallback)) = center.card?.phase else { return XCTFail("\(String(describing: center.card))") }
        XCTAssertTrue(fallback.title.hasPrefix("검색 "))
        center.dismiss()
        auto.look(.init(owner: "pdf", text: passage + "\n셋째 글", heading: nil, title: ""), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(missingCalls.sent.count, 1)
    }

    @MainActor
    func testWithAIExplanationTheDecisionComesFirstAndPassesTheChosenTitle() async throws {
        NativeQuickLookupPreferences.auto = .on
        let center = NativeQuickLookupCenter()
        let (decider, calls) = decider { _ in Self.answers(worth: 0.9, choice: "열역학 제2법칙") }
        let auto = controller(center, decider: decider, searches: calls)
        let explainer = NativeQuickLookupExplainer()
        var explained: [String] = []
        explainer.enabled = { true }
        explainer.tier = { .pro }
        explainer.endpoint = { AIEndpoint(userID: "u", projectURL: URL(string: "https://example.invalid")!, publishableKey: "", token: { "" }) }
        let config = config
        explainer.config = { config }
        explainer.granted = { _, _, _ in true }
        explainer.used = { _ in 0 }
        explainer.record = { _ in }
        explainer.send = { call in
            XCTAssertEqual(calls.sent.count, 1, "the decision was asked first")
            explained.append((call.body["input"] as? [[String: Any]])?.first?["content"] as? String ?? "")
            return .init(text: "주제: 열역학 제2법칙\n설명: 고립계의 엔트로피는 줄지 않아요.\n수식:")
        }
        auto.explainer = explainer
        auto.look(.init(owner: "pdf", text: passage, heading: "열역학", title: "강의.pdf"), store: nil, target: nil)
        try await waitForCard(center)
        XCTAssertEqual(explained.count, 1)
        XCTAssertTrue(explained[0].contains("찾은 위키백과 문서: 열역학 제2법칙"), explained[0])
        XCTAssertEqual(center.card?.explanation?.summary, "고립계의 엔트로피는 줄지 않아요.")
        XCTAssertEqual(NativeQuickLookupCenter.pageURL(center.card!), Self.law.url, "the link is the chosen article")

        // Not worth a card: AI 설명 is not asked.
        center.dismiss()
        auto.decider = self.decider { _ in Self.answers(worth: 0.1, choice: "엔트로피") }.0
        auto.look(.init(owner: "pdf", text: "과제는 금요일까지 제출하세요.\n3쪽", heading: nil, title: ""), store: nil, target: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(center.card)
        XCTAssertEqual(explained.count, 1)
    }
}
