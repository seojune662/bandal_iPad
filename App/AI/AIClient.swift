import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openai, claude
    var id: String { rawValue }
    var title: String { switch self { case .openai: "OpenAI"; case .claude: "Claude" } }
    /// The provider name the ai-proxy uses in routes, config and consent.
    var server: String { switch self { case .openai: "openai"; case .claude: "anthropic" } }
    init?(server: String) { switch server { case "openai": self = .openai; case "anthropic": self = .claude; default: return nil } }
}

/// Where AI requests go: the signed-in user's ai-proxy on the Bandal Supabase project.
struct AIEndpoint {
    /// The signed-in account; caches and consent are kept per account.
    let userID: String
    let projectURL: URL
    let publishableKey: String
    let token: () async throws -> String
    func url(_ path: String) -> URL { projectURL.appendingPathComponent("functions/v1/ai-proxy").appendingPathComponent(path) }
    func authorize(_ request: inout URLRequest) async throws {
        request.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
    }
}

struct AITool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    var schema: [String: Any] { ["type": "object", "properties": properties, "required": required, "additionalProperties": false] }
}
struct AIToolCall { var id: String; var name: String; var arguments: String }
struct AIResult { var text: String; var inputTokens: Int; var outputTokens: Int }
struct AIInputImage { var mediaType: String; var dataBase64: String }
enum AIError: LocalizedError {
    case message(String)
    /// A refusal from the ai-proxy: `code` (BUDGET_EXHAUSTED, TASK_CAP_REACHED, CONSENT_REQUIRED, …) and its body.
    case server(code: String, info: [String: Any])
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .server(let code, let info): Self.describe(code, info)
        }
    }
    static func describe(_ code: String, _ info: [String: Any]) -> String {
        switch code {
        case "BUDGET_EXHAUSTED": "이번 달 AI 사용량을 다 썼어요."
        case "TASK_CAP_REACHED": "이 작업이 한 번에 쓸 수 있는 AI 사용량에 닿아 멈췄어요."
        case "CONSENT_REQUIRED": "AI 전송 동의가 필요해요."
        case "SIGN_IN_REQUIRED": "AI를 쓰려면 설정 › 반달 계정에서 로그인해 주세요."
        case "CONTEXT_TOO_LARGE": "보낼 내용이 너무 길어요. 페이지 범위를 좁히거나 대화를 새로 시작해 주세요."
        case "MODEL_UNAVAILABLE": "선택한 AI 모델을 지금 쓸 수 없어요. 다른 모델을 골라 주세요."
        case "UPSTREAM_REJECTED": "AI가 요청을 처리하지 못했어요." + ((info["message"] as? String).map { " (\($0))" } ?? "")
        default: "AI 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }
}

/// Provider request/stream adaptation over the Bandal ai-proxy, which adds the provider key,
/// meters the cost and appends a `bandal_usage` event. All app actions pass through the
/// explicitly scoped tool executor on the main actor.
@MainActor
final class AIClient {
    static let efforts = ["low", "medium", "high", "max"]
    let provider: AIProvider
    let model: String
    let endpoint: AIEndpoint
    let session: URLSession
    /// One user action; every tool step of it shares the id so the proxy can cap the action.
    let task: String
    let kind: String
    init(provider: AIProvider, model: String, endpoint: AIEndpoint, task: String = UUID().uuidString.lowercased(), kind: String = "question", session: URLSession = .shared) {
        self.provider = provider; self.model = model; self.endpoint = endpoint; self.task = task; self.kind = kind; self.session = session
    }

    func run(messages: [ChatMessage], system: String, tools: [AITool], onDelta: @escaping (String) -> Void,
             onTool: @escaping (String) -> Void, execute: @escaping (AIToolCall) async -> String,
             images: [String: [AIInputImage]] = [:], effort: String? = nil,
             onDeltaAsync: ((String) async throws -> Void)? = nil,
             onUsage: (([String: Any]) -> Void)? = nil) async throws -> AIResult {
        let effort = effort.flatMap { Self.efforts.contains($0) ? $0 : nil }
        let imageInputs = images.values.flatMap { $0 }
        guard imageInputs.count <= 6, imageInputs.allSatisfy({ ["image/png", "image/jpeg", "image/webp", "image/gif"].contains($0.mediaType) && Data(base64Encoded: $0.dataBase64) != nil }),
              imageInputs.reduce(0, { $0 + $1.dataBase64.utf8.count }) <= 28_000_000 else { throw AIError.message("첨부 이미지는 PNG·JPEG·WebP·GIF 최대 6장, 합계 20MB까지 사용할 수 있습니다.") }
        var history: [[String: Any]] = messages.filter { ["user", "assistant"].contains($0.role) }.map { message in
            let attached = message.role == "user" ? images[message.id] ?? [] : []
            if !attached.isEmpty {
                if provider == .openai { return ["role": message.role, "content": [["type": "input_text", "text": message.text]] + attached.map { ["type": "input_image", "image_url": "data:\($0.mediaType);base64,\($0.dataBase64)"] }] }
                return ["role": message.role, "content": [["type": "text", "text": message.text] as [String: Any]] + attached.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.dataBase64]] }]
            }
            return ["role": message.role, "content": message.text]
        }
        var result = AIResult(text: "", inputTokens: 0, outputTokens: 0)
        for _ in 0..<8 {
            try Task.checkCancellation()
            var body: [String: Any]
            switch provider {
            case .openai:
                body = ["model": model, "instructions": system, "input": history, "stream": true, "store": false, "include": ["reasoning.encrypted_content"],
                        "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema, "strict": false] }]
                if let effort { body["reasoning"] = ["effort": effort == "max" ? "xhigh" : effort] }
            case .claude:
                body = ["model": model, "system": system, "messages": history, "max_tokens": 8192, "stream": true,
                        "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }]
                if let effort { body["output_config"] = ["effort": effort] }
            }
            var request = URLRequest(url: endpoint.url("v1/" + provider.server)); request.httpMethod = "POST"; request.timeoutInterval = 180
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(task, forHTTPHeaderField: "X-Bandal-Task")
            request.setValue(kind, forHTTPHeaderField: "X-Bandal-Kind")
            try await endpoint.authorize(&request)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.message("AI 서버 응답을 확인할 수 없습니다.") }
            guard (200..<300).contains(http.statusCode) else {
                var errorData = Data(); for try await byte in bytes { errorData.append(byte); if errorData.count >= 32_768 { break } }
                let info = (try? JSONSerialization.jsonObject(with: errorData)) as? [String: Any] ?? [:]
                throw AIError.server(code: info["code"] as? String ?? (http.statusCode == 401 ? "SIGN_IN_REQUIRED" : "AI_UNAVAILABLE"), info: info)
            }
            var calls: [AIToolCall] = []
            var output: [[String: Any]] = []
            /// Claude content blocks in order (text, thinking, redacted_thinking, tool_use), returned unchanged on the next step.
            var blocks: [Int: [String: Any]] = [:], toolJSON: [Int: String] = [:]
            var completed = false
            func append(_ text: String) async throws { result.text += text; onDelta(text); try await onDeltaAsync?(text) }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard data != "[DONE]", let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { continue }
                if let error = object["error"] as? [String: Any] {
                    if let code = error["code"] as? String, code == code.uppercased() { throw AIError.server(code: code, info: error) }
                    throw AIError.message(error["message"] as? String ?? "AI 응답 중 오류가 발생했습니다.")
                }
                if let usage = object["bandal_usage"] as? [String: Any] { onUsage?(usage); continue }
                switch provider {
                case .openai:
                    let type = object["type"] as? String ?? ""
                    if type == "response.output_text.delta", let text = object["delta"] as? String { try await append(text) }
                    if type == "response.refusal.delta", let text = object["delta"] as? String { try await append(text) }
                    if type == "response.completed", let response = object["response"] as? [String: Any] {
                        completed = true; output = response["output"] as? [[String: Any]] ?? []
                        calls = output.filter { $0["type"] as? String == "function_call" }.map { AIToolCall(id: $0["call_id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: $0["arguments"] as? String ?? "{}") }
                        if let usage = response["usage"] as? [String: Any] { result.inputTokens += usage["input_tokens"] as? Int ?? 0; result.outputTokens += usage["output_tokens"] as? Int ?? 0 }
                    }
                    if ["response.failed", "response.incomplete"].contains(type) { throw AIError.message("AI 응답이 완료되지 않았습니다. 남은 내용을 확인하고 다시 요청해 주세요.") }
                case .claude:
                    let type = object["type"] as? String ?? ""
                    let index = object["index"] as? Int ?? 0
                    if type == "content_block_start", let block = object["content_block"] as? [String: Any] { blocks[index] = block }
                    if type == "content_block_delta", let delta = object["delta"] as? [String: Any] {
                        if let json = delta["partial_json"] as? String { toolJSON[index, default: ""] += json }
                        if var block = blocks[index] {
                            for field in ["text", "thinking", "signature"] {
                                if let piece = delta[field] as? String { block[field] = (block[field] as? String ?? "") + piece }
                            }
                            blocks[index] = block
                        }
                        if let text = delta["text"] as? String { try await append(text) }
                    }
                    if type == "message_start", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] { result.inputTokens += usage["input_tokens"] as? Int ?? 0 }
                    if type == "message_delta" {
                        if let usage = object["usage"] as? [String: Any] { result.outputTokens += usage["output_tokens"] as? Int ?? 0 }
                        if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String, !["end_turn", "tool_use", "stop_sequence"].contains(reason) { throw AIError.message("Claude 응답이 \(reason) 상태로 종료되었습니다. 부분 응답을 확인해 주세요.") }
                    }
                    if type == "message_stop" { completed = true }
                }
            }
            var claudeContent: [[String: Any]] = []
            if provider == .claude {
                for index in blocks.keys.sorted() {
                    guard var block = blocks[index] else { continue }
                    if block["type"] as? String == "tool_use" {
                        let arguments = toolJSON[index] ?? ""
                        calls.append(AIToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: arguments))
                        block["input"] = (try? JSONSerialization.jsonObject(with: Data((arguments.isEmpty ? "{}" : arguments).utf8))) ?? [:]
                    }
                    if block["type"] as? String == "text", (block["text"] as? String ?? "").isEmpty { continue }
                    claudeContent.append(block)
                }
            }
            guard completed else { throw AIError.message("AI 연결이 응답 완료 전에 끊겼습니다. 부분 응답은 보존했습니다.") }
            if calls.isEmpty { return result }
            var toolResults: [(AIToolCall, String)] = []
            for call in calls {
                try Task.checkCancellation()
                guard tools.contains(where: { $0.name == call.name }) else { throw AIError.message("허용되지 않은 AI 도구 요청입니다.") }
                onTool(call.name); toolResults.append((call, await execute(call)))
            }
            switch provider {
            case .openai:
                history.append(contentsOf: output)
                history.append(contentsOf: toolResults.map { ["type": "function_call_output", "call_id": $0.0.id, "output": $0.1] })
            case .claude:
                history.append(["role": "assistant", "content": claudeContent])
                history.append(["role": "user", "content": toolResults.map { ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1] }])
            }
        }
        throw AIError.message("한 번의 요청에서 실행할 수 있는 도구 횟수에 도달했습니다. 완료된 결과는 저장되어 있습니다.")
    }
}
