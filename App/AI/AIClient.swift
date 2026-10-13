import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openai, claude, gemini
    var id: String { rawValue }
    var title: String { switch self { case .openai: "OpenAI"; case .claude: "Claude"; case .gemini: "Gemini" } }
    var defaultModel: String { switch self { case .openai: "gpt-5-mini"; case .claude: "claude-sonnet-4-5"; case .gemini: "gemini-2.5-flash" } }
    var model: String { let value = UserDefaults.standard.string(forKey: "ai.model.\(rawValue)") ?? ""; return value.isEmpty ? defaultModel : value }
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
enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

/// Provider transports contain only HTTP/API adaptation. All app actions pass
/// through the explicitly scoped tool executor on the main actor.
@MainActor
final class AIClient {
    let provider: AIProvider
    let model: String
    let key: String
    let session: URLSession
    init(provider: AIProvider, model: String, key: String, session: URLSession = .shared) { self.provider = provider; self.model = model; self.key = key; self.session = session }

    func run(messages: [ChatMessage], system: String, tools: [AITool], onDelta: @escaping (String) -> Void,
             onTool: @escaping (String) -> Void, execute: @escaping (AIToolCall) async -> String) async throws -> AIResult {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.message("설정에서 \(provider.title) API 키를 등록해 주세요.") }
        var history: [[String: Any]] = messages.filter { ["user", "assistant"].contains($0.role) }.map { message in
            if provider == .gemini { return ["role": message.role == "assistant" ? "model" : "user", "parts": [["text": message.text]]] }
            return ["role": message.role, "content": message.text]
        }
        var result = AIResult(text: "", inputTokens: 0, outputTokens: 0)
        for _ in 0..<8 {
            try Task.checkCancellation()
            var body: [String: Any]
            let url: URL
            switch provider {
            case .openai:
                url = URL(string: "https://api.openai.com/v1/responses")!
                body = ["model": model, "instructions": system, "input": history, "stream": true, "store": false, "include": ["reasoning.encrypted_content"],
                        "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema, "strict": false] }]
            case .claude:
                url = URL(string: "https://api.anthropic.com/v1/messages")!
                body = ["model": model, "system": system, "messages": history, "max_tokens": 8192, "stream": true,
                        "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }]
            case .gemini:
                guard model.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else { throw AIError.message("Gemini 모델 ID 형식이 올바르지 않습니다.") }
                url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
                body = ["systemInstruction": ["parts": [["text": system]]], "contents": history,
                        "tools": [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.schema] }]]]
            }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switch provider {
            case .openai: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .claude: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.message("AI 서버 응답을 확인할 수 없습니다.") }
            guard (200..<300).contains(http.statusCode) else {
                var errorData = Data(); for try await byte in bytes { errorData.append(byte); if errorData.count >= 32_768 { break } }
                let obj = (try? JSONSerialization.jsonObject(with: errorData)) as? [String: Any]
                let detail = (obj?["error"] as? [String: Any])?["message"] as? String
                let fallback = http.statusCode == 401 ? "API 키를 확인해 주세요." : http.statusCode == 429 ? "사용량 한도 또는 요청 제한에 도달했습니다." : "잠시 후 다시 시도해 주세요."
                throw AIError.message("\(provider.title) (\(http.statusCode)): \(detail ?? fallback)")
            }
            var calls: [AIToolCall] = []
            var output: [[String: Any]] = []
            var blockCalls: [Int: AIToolCall] = [:]
            var stepText = ""
            var completed = false
            var geminiInput = 0, geminiOutput = 0
            func append(_ text: String) { stepText += text; result.text += text; onDelta(text) }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard data != "[DONE]", let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { continue }
                if let error = object["error"] as? [String: Any] { throw AIError.message(error["message"] as? String ?? "AI 응답 중 오류가 발생했습니다.") }
                switch provider {
                case .openai:
                    let type = object["type"] as? String ?? ""
                    if type == "response.output_text.delta", let text = object["delta"] as? String { append(text) }
                    if type == "response.refusal.delta", let text = object["delta"] as? String { append(text) }
                    if type == "response.completed", let response = object["response"] as? [String: Any] {
                        completed = true; output = response["output"] as? [[String: Any]] ?? []
                        calls = output.filter { $0["type"] as? String == "function_call" }.map { AIToolCall(id: $0["call_id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: $0["arguments"] as? String ?? "{}") }
                        if let usage = response["usage"] as? [String: Any] { result.inputTokens += usage["input_tokens"] as? Int ?? 0; result.outputTokens += usage["output_tokens"] as? Int ?? 0 }
                    }
                    if ["response.failed", "response.incomplete"].contains(type) { throw AIError.message("AI 응답이 완료되지 않았습니다. 남은 내용을 확인하고 다시 요청해 주세요.") }
                case .claude:
                    let type = object["type"] as? String ?? ""
                    let index = object["index"] as? Int ?? 0
                    if type == "content_block_start", let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                        blockCalls[index] = AIToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: "")
                    }
                    if type == "content_block_delta", let delta = object["delta"] as? [String: Any] {
                        if let text = delta["text"] as? String { append(text) }
                        if let json = delta["partial_json"] as? String { blockCalls[index]?.arguments += json }
                    }
                    if type == "message_start", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] { result.inputTokens += usage["input_tokens"] as? Int ?? 0 }
                    if type == "message_delta" {
                        if let usage = object["usage"] as? [String: Any] { result.outputTokens += usage["output_tokens"] as? Int ?? 0 }
                        if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String, !["end_turn", "tool_use", "stop_sequence"].contains(reason) { throw AIError.message("Claude 응답이 \(reason) 상태로 종료되었습니다. 부분 응답을 확인해 주세요.") }
                    }
                    if type == "message_stop" { completed = true }
                case .gemini:
                    if let usage = object["usageMetadata"] as? [String: Any] { geminiInput = usage["promptTokenCount"] as? Int ?? geminiInput; geminiOutput = usage["candidatesTokenCount"] as? Int ?? geminiOutput }
                    for candidate in object["candidates"] as? [[String: Any]] ?? [] {
                        if let reason = candidate["finishReason"] as? String { completed = true; if reason != "STOP" { throw AIError.message("Gemini 응답이 \(reason) 상태로 종료되었습니다.") } }
                        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                        for part in parts {
                            if let text = part["text"] as? String, part["thought"] as? Bool != true { append(text) }
                            output.append(part)
                            if let call = part["functionCall"] as? [String: Any] {
                                let arguments = try JSONSerialization.data(withJSONObject: call["args"] as? [String: Any] ?? [:])
                                calls.append(AIToolCall(id: call["id"] as? String ?? UUID().uuidString, name: call["name"] as? String ?? "", arguments: String(decoding: arguments, as: UTF8.self)))
                            }
                        }
                    }
                }
            }
            if provider == .gemini { result.inputTokens += geminiInput; result.outputTokens += geminiOutput }
            if provider == .claude { calls = blockCalls.keys.sorted().compactMap { blockCalls[$0] } }
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
                var content: [[String: Any]] = stepText.isEmpty ? [] : [["type": "text", "text": stepText]]
                content += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": (try? JSONSerialization.jsonObject(with: Data($0.arguments.utf8))) ?? [:]] }
                history.append(["role": "assistant", "content": content])
                history.append(["role": "user", "content": toolResults.map { ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1] }])
            case .gemini:
                history.append(["role": "model", "parts": output])
                history.append(["role": "user", "parts": toolResults.map { ["functionResponse": ["name": $0.0.name, "response": ["result": $0.1]]] }])
            }
        }
        throw AIError.message("한 번의 요청에서 실행할 수 있는 도구 횟수에 도달했습니다. 완료된 결과는 저장되어 있습니다.")
    }
}
