#if DEBUG
import Foundation

/// UI tests of the decision step (`--native-ui-testing --native-auto-lookup-fixture --lookup-decisions-fixture`): a
/// signed-in Plus reader who agreed to OpenAI on this iPad and at the server, Wikipedia's search answered from
/// `NativeQuickLookupAutoFixture.articles`, and the decision a fixed reply after 0.3 s, read from the passage:
///   "제출" or "쪽": not worth a card · "경제": none of the articles · "법칙": 열역학 제2법칙 ·
///   "엔트로피" or "Entropy": that article · anything else: unsure (the lookup goes on without the decision).
@MainActor
enum NativeQuickLookupDecideFixture {
    static func install(on auto: NativeQuickLookupAuto) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing"), arguments.contains(NativeQuickLookupDecide.fixtureArgument) else { return }
        let decider = auto.decider
        decider.tier = { .plus }
        decider.endpoint = { AIEndpoint(userID: "ui-test-decide", projectURL: URL(string: "https://example.invalid")!, publishableKey: "", token: { "" }) }
        decider.config = { ["models": [["id": "gpt-6-luna", "provider": "openai", "badge": 1]], "consentVersion": 1,
                            "usage": ["plan": "plus", "consents": ["openai": 1]]] }
        decider.granted = { provider, _, _ in provider == .openai }
        decider.search = { language, query in
            try await Task.sleep(for: .milliseconds(150))
            // As a search would: the articles that mention a word of the query.
            let words = NativeWikipediaSearch.fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
            return NativeQuickLookupAutoFixture.articles.filter { $0.url.host?.hasPrefix(language + ".") == true }
                .filter { hit in words.contains { NativeWikipediaSearch.fold(hit.title + " " + hit.extract).contains($0) } }
        }
        decider.send = { call in
            try await Task.sleep(for: .milliseconds(300))
            return reply(to: call.body)
        }
    }

    static func reply(to body: [String: Any]) -> [NativeQuickLookupDecide.Answer] {
        let passage = ((body["input"] as? [[String: Any]])?.last?["content"] as? String ?? "").components(separatedBy: "고른 글:\n").last ?? ""
        let questions = body["questions"] as? [[String: Any]] ?? []
        let values = (questions.first { $0["name"] as? String == "article" }?["choices"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        let worth: Double = passage.contains("제출") || passage.contains("쪽") ? 0.04 : 0.9
        var answers = [NativeQuickLookupDecide.Answer(name: "worth", type: "predicate", probability: worth)]
        guard !values.isEmpty else { return answers }
        let pick: (String, Double)
        if passage.contains("경제") { pick = (NativeQuickLookupDecide.noArticle, 0.88) }
        else if passage.contains("법칙"), values.contains("열역학 제2법칙") { pick = ("열역학 제2법칙", 0.9) }
        else if let title = ["엔트로피", "Entropy"].first(where: { passage.contains($0) && values.contains($0) }) { pick = (title, 0.86) }
        else { pick = (values[0], 0.3) }
        answers.append(.init(name: "article", type: "choice", choice: pick.0, confidence: pick.1))
        return answers
    }
}
#endif
