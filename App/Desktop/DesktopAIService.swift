import Foundation

@MainActor
struct DesktopAIEnvironment {
    var readKey: (AIProvider) -> String? = { KeychainStore.read("ai.\($0.rawValue)") }
    var writeKey: (AIProvider, String) throws -> Void = { try KeychainStore.write($1, account: "ai.\($0.rawValue)") }
    var session: URLSession = URLSession(configuration: .ephemeral, delegate: DesktopAIRedirectPolicy(), delegateQueue: nil)
    var hasConsent: (AIProvider) -> Bool = { AIConsent.isGranted($0) }
    var askConsent: (AIProvider) async -> Bool = { await AIConsent.ask($0, english: false) }
}
private final class DesktopAIRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Native BYOK transport. Original desktop SessionManager owns conversation,
/// persistence, approvals and tools. Keys never cross into either JS runtime.
@MainActor
final class DesktopAIService {
    var onEvent: ((String, [String: Any]) async throws -> Void)?
    var onTool: ((String, [String: Any]) async throws -> String)?
    private let environment: DesktopAIEnvironment
    private var tasks: [String: (provider: AIProvider, task: Task<AIResult, Error>)] = [:]
    private var generations: [AIProvider: Int] = [:]
    private var catalogs: [AIProvider: [String: Any]] = [:]
    private var consentPrompts: [AIProvider: Task<Bool, Never>] = [:]
    init(environment: DesktopAIEnvironment? = nil) { self.environment = environment ?? DesktopAIEnvironment() }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("native:ai") }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        let provider = try resolve(request["provider"] as? String)
        switch channel {
        case "native:aiAvailability":
            let configured = !(environment.readKey(provider) ?? "").isEmpty
            var result: [String: Any] = ["installed": true, "loggedIn": configured, "version": "iPad API", "subscriptionType": "API · BYOK", "transport": "api"]
            if !configured { result["code"] = "not-logged-in"; result["reason"] = "iPad API 연결에 사용할 \(provider.title) API 키를 등록해 주세요. CLI 실행은 iPad에서 지원하지 않습니다." }
            return result
        case "native:aiKeyStatus": return keyStatus(provider)
        case "native:aiSetKey":
            let value = (request["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 8192, !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw DesktopRuntimeError("API 키 형식을 확인해 주세요.") }
            try environment.writeKey(provider, value)
            generations[provider, default: 0] += 1; catalogs[provider] = nil
            for active in tasks.values where active.provider == provider { active.task.cancel() }
            return keyStatus(provider)
        case "native:aiModels": return try await models(provider, refresh: request["refresh"] as? Bool == true)
        case "native:aiRun": return try await run(provider, request: request)
        case "native:aiCancel":
            if let identifier = request["requestId"] as? String, tasks[identifier]?.provider == provider { tasks[identifier]?.task.cancel() }
            return ["ok": true]
        default: throw DesktopRuntimeError("Unknown native AI operation")
        }
    }
    private func resolve(_ value: String?) throws -> AIProvider {
        switch value { case "codex": return .openai; case "claude-code": return .claude; case "gemini": return .gemini; default: throw DesktopRuntimeError("AI 제공자를 확인해 주세요.") }
    }
    private func keyStatus(_ provider: AIProvider) -> [String: Any] {
        let key = environment.readKey(provider) ?? ""
        return ["configured": !key.isEmpty, "hint": key.isEmpty ? NSNull() as Any : String(key.suffix(4)), "storageAvailable": true]
    }
    private func models(_ provider: AIProvider, refresh: Bool) async throws -> [String: Any] {
        if !refresh, let cached = catalogs[provider] { return cached }
        let fallback: [String: Any] = ["models": [["id": provider.model, "displayName": provider.model, "isDefault": false, "supportedEfforts": []]], "source": "fallback", "status": "unverified"]
        guard let key = environment.readKey(provider), !key.isEmpty else { return fallback }
        let generation = generations[provider, default: 0]
        let url: URL
        switch provider { case .openai: url = URL(string: "https://api.openai.com/v1/models")!; case .claude: url = URL(string: "https://api.anthropic.com/v1/models")!; case .gemini: url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")! }
        var request = URLRequest(url: url); request.timeoutInterval = 20; request.httpShouldHandleCookies = false
        switch provider {
        case .openai: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .claude: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        do {
            let (data, response) = try await environment.session.data(for: request)
            guard generation == generations[provider, default: 0] else { throw CancellationError() }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 4 * 1024 * 1024 else { throw DesktopRuntimeError("모델 목록을 가져오지 못했습니다.") }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rows = object[provider == .gemini ? "models" : "data"] as? [[String: Any]] ?? []
            let models: [[String: Any]] = rows.compactMap { row in
                let id = (row[provider == .gemini ? "name" : "id"] as? String ?? "").replacingOccurrences(of: "models/", with: "")
                guard !id.isEmpty else { return nil }
                if provider == .openai, !["gpt-", "o1", "o3", "o4"].contains(where: { id.hasPrefix($0) }) { return nil }
                if provider == .gemini, !(row["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { return nil }
                return ["id": id, "displayName": row["display_name"] as? String ?? row["displayName"] as? String ?? id, "isDefault": false, "supportedEfforts": []]
            }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            guard !models.isEmpty else { throw DesktopRuntimeError("사용 가능한 API 모델 목록이 비어 있습니다.") }
            let result: [String: Any] = ["models": models, "source": "live", "status": "ready", "fetchedAt": ISO8601DateFormatter().string(from: Date())]
            catalogs[provider] = result; return result
        } catch is CancellationError { throw CancellationError() }
        catch { var result = catalogs[provider] ?? fallback; result["status"] = "unverified"; result["error"] = "API 모델 목록 확인에 실패했습니다. 선택한 모델의 실제 접근 권한은 요청 때 확인됩니다."; if catalogs[provider] != nil { result["source"] = "cache" }; return result }
    }
    /// One sheet per provider even when several requests start at once.
    private func consent(_ provider: AIProvider) async -> Bool {
        if environment.hasConsent(provider) { return true }
        if let pending = consentPrompts[provider] { return await pending.value }
        let ask = environment.askConsent
        let prompt = Task { await ask(provider) }
        consentPrompts[provider] = prompt
        defer { consentPrompts[provider] = nil }
        return await prompt.value
    }
    private func run(_ provider: AIProvider, request: [String: Any]) async throws -> [String: Any] {
        guard let identifier = request["requestId"] as? String, UUID(uuidString: identifier) != nil, tasks[identifier] == nil,
              let raw = request["messages"] as? [[String: Any]], raw.count <= 300,
              let toolInputs = request["tools"] as? [[String: Any]], toolInputs.count <= 160,
              let event = onEvent, let execute = onTool else { throw DesktopRuntimeError("AI 요청 구성을 확인할 수 없습니다.") }
        guard await consent(provider) else { throw DesktopRuntimeError("AI 제공자 전송에 동의하지 않아 요청을 보내지 않았습니다.") }
        try Task.checkCancellation()
        let key = environment.readKey(provider) ?? ""
        guard !key.isEmpty else { throw DesktopRuntimeError("\(provider.title) API 키를 설정 › AI 엔진에서 등록해 주세요.") }
        let generation = generations[provider, default: 0]
        let requestedModel = request["model"] as? String ?? ""
        let model = requestedModel.isEmpty || requestedModel == "default" ? provider.model : requestedModel
        guard model.utf8.count <= 200, model.range(of: "^[a-zA-Z0-9._:/-]+$", options: .regularExpression) != nil else { throw DesktopRuntimeError("AI 모델 ID 형식을 확인해 주세요.") }
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
        let task = Task<AIResult, Error> {
            let client = AIClient(provider: provider, model: model, key: key, session: environment.session)
            return try await client.run(messages: messages, system: request["system"] as? String ?? "", tools: tools, onDelta: { _ in }, onTool: { _ in }, execute: { call in
                do {
                    try Task.checkCancellation()
                    guard generation == self.generations[provider, default: 0] else { throw CancellationError() }
                    return try await execute(identifier, ["id": call.id, "name": call.name, "arguments": call.arguments])
                } catch { return "도구 실행 실패: \(error.localizedDescription)" }
            }, images: images, effort: request["effort"] as? String, onDeltaAsync: { text in
                try Task.checkCancellation()
                guard generation == self.generations[provider, default: 0] else { throw CancellationError() }
                try await event(identifier, ["type": "text-delta", "text": text])
            })
        }
        tasks[identifier] = (provider, task)
        defer { tasks[identifier] = nil }
        do {
            let result = try await task.value
            guard generation == generations[provider, default: 0] else { throw CancellationError() }
            return ["text": result.text, "model": model, "usage": ["inputTokens": result.inputTokens, "outputTokens": result.outputTokens]]
        } catch is CancellationError { throw CancellationError() }
        catch { throw DesktopRuntimeError(error.localizedDescription.replacingOccurrences(of: key.isEmpty ? "\0" : key, with: "[redacted]")) }
    }
}
