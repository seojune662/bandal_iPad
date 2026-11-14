#if DEBUG
import Foundation

/// UI tests of 자동 찾아보기 (`--native-ui-testing --native-auto-lookup-fixture`): Wikipedia's search answers from
/// three articles about the seeded lecture, with no network. `--native-auto-lookup-ai-fixture` also makes the
/// reader a signed-in Pro member who agreed to OpenAI and Anthropic, and the model a fixed reply after 0.4 s.
/// `--native-auto-lookup-on` (NativeQuickLookupPreferences) skips the one-time question.
@MainActor
enum NativeQuickLookupAutoFixture {
    static var requested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--native-ui-testing") && arguments.contains("--native-auto-lookup-fixture")
    }

    static let articles: [NativeWikipediaSearch.Hit] = [
        .init(title: "열역학 제2법칙", extract: "열역학 제2법칙은 고립계의 엔트로피가 시간이 흘러도 줄어들지 않는다는 법칙이다. 열은 저절로 차가운 곳에서 뜨거운 곳으로 흐르지 않는다.",
              description: "열역학의 기본 법칙", url: URL(string: "https://ko.wikipedia.org/wiki/%EC%97%B4%EC%97%AD%ED%95%99_%EC%A0%9C2%EB%B2%95%EC%B9%99")!, rank: 1),
        .init(title: "엔트로피", extract: "엔트로피는 열역학적 계의 무질서한 정도를 나타내는 상태 함수이다. 고립계에서 엔트로피는 감소하지 않는다.",
              description: nil, url: URL(string: "https://ko.wikipedia.org/wiki/%EC%97%94%ED%8A%B8%EB%A1%9C%ED%94%BC")!, rank: 2),
        .init(title: "Entropy", extract: "Entropy is a scientific concept that is most commonly associated with a state of disorder, randomness, or uncertainty.",
              description: "Property of a thermodynamic system", url: URL(string: "https://en.wikipedia.org/wiki/Entropy")!, rank: 1)]

    static func install(on auto: NativeQuickLookupAuto) {
        guard requested else { return }
        let dictionary = auto.resolver.dictionary
        auto.resolver = NativeQuickLookupAutoResolver(dictionary: dictionary) { language, query, context in
            try await Task.sleep(for: .milliseconds(150))
            // As a search would: the articles that mention a word of the query.
            let words = NativeWikipediaSearch.fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
            let hits = articles.filter { $0.url.host?.hasPrefix(language + ".") == true }
                .filter { hit in words.contains { NativeWikipediaSearch.fold(hit.title + " " + hit.extract).contains($0) } }
            guard let hit = NativeWikipediaSearch.best(hits, query: query, context: context) else { return nil }
            return NativeWikipediaSummary(language: language, title: hit.title, description: hit.description, extract: hit.extract, url: hit.url)
        }
        guard ProcessInfo.processInfo.arguments.contains("--native-auto-lookup-ai-fixture") else { return }
        let explainer = auto.explainer
        explainer.tier = { .pro }
        explainer.endpoint = { AIEndpoint(userID: "ui-test", projectURL: URL(string: "https://example.invalid")!, publishableKey: "", token: { "" }) }
        explainer.config = { ["models": [["id": "claude-haiku-5-5", "provider": "anthropic", "badge": 1], ["id": "gpt-6-luna", "provider": "openai", "badge": 1],
                                         ["id": "gpt-6-sol", "provider": "openai", "badge": 20]],
                              "consentVersion": 1, "usage": ["plan": "pro", "consents": ["openai": 1, "anthropic": 1]]] }
        explainer.granted = { _, _, _ in true }
        explainer.send = { call in
            try await Task.sleep(for: .milliseconds(400))
            let text = ((call.body["input"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            calls.append((call.model, text))
            let reply: String
            if text.contains("S = k ln W") { reply = "주제: 엔트로피\n설명: 볼츠만 식은 엔트로피를 한 상태가 가질 수 있는 미시 상태의 수로 나타내요.\n수식: S = k \\ln W" }
            else if text.contains("엔트로피") || text.contains("Entropy") { reply = "주제: 엔트로피\n설명: 고립된 계의 엔트로피는 시간이 지나도 줄지 않는다는 열역학 제2법칙을 말해요.\n수식:" }
            else { reply = "건너뛰기" }
            return .init(text: reply, inputTokens: 480, outputTokens: 58)
        }
    }
    /// Model and passage of every fixture call, for a test that wants to see what would have been sent.
    static var calls: [(model: String, text: String)] = []
}
#endif
