import Foundation

@MainActor
struct DesktopAIEnvironment {
    var session: URLSession = URLSession(configuration: .ephemeral, delegate: DesktopAIRedirectPolicy(), delegateQueue: nil)
    /// The signed-in ai-proxy; throws when nobody is signed in.
    var endpoint: () async throws -> AIEndpoint = { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
    var hasConsent: (AIProvider, String, Int) -> Bool = { AIConsent.isGranted($0, user: $1, version: $2) }
    var setConsent: (AIProvider, String, Int) -> Void = { AIConsent.set($0, user: $1, version: $2, granted: true) }
    var askConsent: (AIProvider) async -> Bool = { await AIConsent.ask($0, english: false) }
    /// The server's AI usage after every answer and refusal (usage bar).
    var onUsage: ([String: Any]) -> Void = { _ in }
    /// A budget or task-cap refusal (paywall / credit sheet).
    var onLimit: (String, [String: Any]) -> Void = { _, _ in }
}
private final class DesktopAIRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Native AI transport through the Bandal ai-proxy (no user keys). Original desktop
/// SessionManager owns conversation, persistence, approvals and tools.
@MainActor
final class DesktopAIService {
    /// The consent wording this build shows; the proxy's config names the version it requires.
    static let consentVersion = 1
    static let kinds: Set<String> = ["question", "summary", "quiz", "translate", "routine", "explain"]
    var onEvent: ((String, [String: Any]) async throws -> Void)?
    var onTool: ((String, [String: Any]) async throws -> String)?
    private let environment: DesktopAIEnvironment
    private var tasks: [String: Task<AIResult, Error>] = [:]
    private var config: [String: Any]?
    /// The account `config` belongs to: another account's usage and consents never carry over.
    private var configUser: String?
    private var loading: Task<[String: Any], Error>?
    private var consentPrompts: [AIProvider: Task<Bool, Never>] = [:]
    init(environment: DesktopAIEnvironment? = nil) { self.environment = environment ?? DesktopAIEnvironment() }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("native:ai") }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "native:aiAvailability":
            do {
                _ = try await environment.endpoint()
                return ["installed": true, "loggedIn": true, "version": "Bandal AI", "subscriptionType": "Bandal", "transport": "api"]
            } catch {
                return ["installed": true, "loggedIn": false, "version": "Bandal AI", "transport": "api", "code": "not-logged-in", "reason": AIError.describe("SIGN_IN_REQUIRED", [:])]
            }
        case "native:aiConfig": return try await configuration(try await environment.endpoint(), refresh: request["refresh"] as? Bool == true)
        case "native:aiModels":
            let models = try await configuration(try await environment.endpoint(), refresh: request["refresh"] as? Bool == true)["models"] as? [[String: Any]] ?? []
            return ["models": models.map { ["id": $0["id"] ?? "", "displayName": $0["label"] ?? "", "provider": $0["provider"] ?? "", "badge": $0["badge"] ?? 1, "isDefault": false, "supportedEfforts": AIClient.efforts] },
                    "source": "live", "status": "ready"]
        case "native:aiRun": return try await run(request)
        case "native:aiCancel":
            if let identifier = request["requestId"] as? String { tasks[identifier]?.cancel() }
            return ["ok": true]
        default: throw DesktopRuntimeError("Unknown native AI operation")
        }
    }

    /// Models, Auto and usage from the proxy; cached until refreshed or an answer changes usage.
    private func configuration(_ endpoint: AIEndpoint, refresh: Bool = false) async throws -> [String: Any] {
        if configUser != endpoint.userID { config = nil; loading = nil; configUser = endpoint.userID }
        if !refresh, let config { return config }
        // Requests that start together share one load (and then one consent sheet).
        if let loading { return try await loading.value }
        let load = Task { try await post("config", [:], endpoint) }
        loading = load
        defer { loading = nil }
        let value = try await load.value
        guard configUser == endpoint.userID else { throw CancellationError() }
        config = value
        if let usage = value["usage"] as? [String: Any] { environment.onUsage(usage) }
        return value
    }
    private func post(_ path: String, _ body: [String: Any], _ endpoint: AIEndpoint) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.url(path)); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await endpoint.authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await environment.session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.server(code: object["code"] as? String ?? "AI_UNAVAILABLE", info: object)
        }
        return object
    }

    /// Picks the model: a model the proxy offers keeps its provider; Auto, empty, "default" or an
    /// old BYOK model name falls back to the proxy's Auto model.
    static func resolve(_ requested: String?, config: [String: Any]) -> (model: String, provider: AIProvider)? {
        let models = config["models"] as? [[String: Any]] ?? []
        if let requested, let row = models.first(where: { $0["id"] as? String == requested }),
           let provider = AIProvider(server: row["provider"] as? String ?? "") { return (requested, provider) }
        guard let auto = config["auto"] as? [String: Any], let id = auto["id"] as? String,
              let provider = AIProvider(server: auto["provider"] as? String ?? "") else { return nil }
        return (id, provider)
    }

    /// Asks once per provider (one sheet even when several requests start at once) and records
    /// the answer on the server, which refuses to relay without it.
    private func consent(_ provider: AIProvider, config: [String: Any], endpoint: AIEndpoint) async throws {
        let version = max(config["consentVersion"] as? Int ?? Self.consentVersion, 1)
        let recorded = ((config["usage"] as? [String: Any])?["consents"] as? [String: Any])?[provider.server] as? Int ?? 0
        let local = environment.hasConsent(provider, endpoint.userID, version)
        if recorded >= version, local { return }
        // This account's own answer on this iPad; a consent given by another account never counts.
        if !local {
            let granted: Bool
            if let pending = consentPrompts[provider] { granted = await pending.value } else {
                let ask = environment.askConsent
                let prompt = Task { await ask(provider) }
                consentPrompts[provider] = prompt
                granted = await prompt.value
                consentPrompts[provider] = nil
            }
            guard granted else { throw DesktopRuntimeError("AI 전송에 동의하지 않아 요청을 보내지 않았습니다.") }
            environment.setConsent(provider, endpoint.userID, version)
        }
        let status = try await post("consent", ["provider": provider.server, "version": version], endpoint)
        remember(status); environment.onUsage(status)
    }

    private func run(_ request: [String: Any]) async throws -> [String: Any] {
        guard let identifier = request["requestId"] as? String, UUID(uuidString: identifier) != nil, tasks[identifier] == nil,
              let raw = request["messages"] as? [[String: Any]], raw.count <= 300,
              let toolInputs = request["tools"] as? [[String: Any]], toolInputs.count <= 160,
              let event = onEvent, let execute = onTool else { throw DesktopRuntimeError("AI 요청 구성을 확인할 수 없습니다.") }
        do {
            let endpoint = try await environment.endpoint()
            var config = try await configuration(endpoint)
            guard let (model, provider) = Self.resolve(request["model"] as? String, config: config) else { throw AIError.server(code: "AI_UNAVAILABLE", info: [:]) }
            // Auto is the cheap default: always the lowest effort, whatever the session stored.
            let isAuto = (config["auto"] as? [String: Any])?["id"] as? String == model && request["model"] as? String != model
            try await consent(provider, config: config, endpoint: endpoint)
            config = self.config ?? config
            try Task.checkCancellation()
            var images: [String: [AIInputImage]] = [:]
            let messages: [ChatMessage] = try raw.map { value in
                guard let role = value["role"] as? String, ["user", "assistant"].contains(role), let text = value["text"] as? String, text.utf8.count <= 2_000_000 else { throw DesktopRuntimeError("AI 대화 내용이 너무 크거나 올바르지 않습니다.") }
                let message = ChatMessage(role: role, text: text)
                images[message.id] = (value["images"] as? [[String: String]] ?? []).map { AIInputImage(mediaType: $0["mediaType"] ?? "", dataBase64: $0["dataBase64"] ?? "") }
                return message
            }
            let tools: [AITool] = try toolInputs.map { value in
                guard let name = value["name"] as? String, name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil,
                      let schema = value["inputSchema"] as? [String: Any] else { throw DesktopRuntimeError("AI 도구 형식을 확인할 수 없습니다.") }
                return AITool(name: name, description: value["description"] as? String ?? name, properties: schema["properties"] as? [String: Any] ?? [:], required: schema["required"] as? [String] ?? [])
            }
            let kind = (request["kind"] as? String).flatMap { Self.kinds.contains($0) ? $0 : nil } ?? "question"
            let limit = Self.toolResultLimit(model: model, config: config)
            let onUsage = environment.onUsage
            let task = Task<AIResult, Error> {
                let client = AIClient(provider: provider, model: model, endpoint: endpoint, task: identifier.lowercased(), kind: kind, session: environment.session)
                return try await client.run(messages: messages, system: request["system"] as? String ?? "", tools: tools, onDelta: { _ in }, onTool: { _ in }, execute: { call in
                    do {
                        try Task.checkCancellation()
                        let output = try await execute(identifier, ["id": call.id, "name": call.name, "arguments": call.arguments])
                        return output.count > limit ? String(output.prefix(limit)) + "\n[이후 내용은 길이 제한으로 생략됨]" : output
                    } catch { return "도구 실행 실패: \(error.localizedDescription)" }
                }, images: images, effort: isAuto ? "low" : request["effort"] as? String, onDeltaAsync: { text in
                    try Task.checkCancellation()
                    try await event(identifier, ["type": "text-delta", "text": text])
                }, onUsage: { [weak self] usage in self?.remember(usage); onUsage(usage) })
            }
            tasks[identifier] = task
            defer { tasks[identifier] = nil }
            let result = try await task.value
            return ["text": result.text, "model": model, "usage": ["inputTokens": result.inputTokens, "outputTokens": result.outputTokens]]
        } catch is CancellationError { throw CancellationError() }
        catch AIError.server(let code, let info) {
            if code == "BUDGET_EXHAUSTED" || code == "TASK_CAP_REACHED" {
                let usage = info["usage"] as? [String: Any] ?? [:]
                remember(usage)
                environment.onUsage(usage); environment.onLimit(code, usage)
            }
            // A stale consent or model list is refreshed for the next request.
            if code == "CONSENT_REQUIRED" || code == "MODEL_UNAVAILABLE" { config = nil }
            throw DesktopRuntimeError(AIError.describe(code, info), code: code)
        }
    }

    /// The plan changed (purchase, restore, renewal): the next request reloads models and usage.
    func invalidate() { config = nil; loading = nil }

    /// Merges a newer usage status into the cached config (an event may carry only part of it).
    private func remember(_ usage: [String: Any]) {
        guard var current = config else { return }
        let old = current["usage"] as? [String: Any] ?? [:]
        var merged = old.merging(usage) { _, new in new }
        // Consents merge per provider: a reply may name only the one it changed.
        if let newer = usage["consents"] as? [String: Any] { merged["consents"] = (old["consents"] as? [String: Any] ?? [:]).merging(newer) { _, new in new } }
        current["usage"] = merged
        config = current
    }

    /// Characters one tool result may add: Auto keeps chats inside its smaller context.
    static func toolResultLimit(model: String, config: [String: Any]) -> Int {
        let auto = config["auto"] as? [String: Any]
        let tokens = auto?["id"] as? String == model ? auto?["contextCap"] as? Int ?? 30_000
            : ((config["models"] as? [[String: Any]])?.first { $0["id"] as? String == model }?["contextCap"] as? Int ?? 100_000)
        // The proxy estimates about one token per Korean character; leave room for the conversation.
        return max(8_000, tokens * 2 / 3)
    }
}
