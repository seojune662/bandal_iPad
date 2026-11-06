import XCTest
@testable import Bandal

private final class AIProtocol: URLProtocol {
    static var responses: [(Int, String)] = []
    static var requests: [URLRequest] = []
    static var bodies: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.body(of: request))
        guard !Self.responses.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let value = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(value.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class AIClientTests: XCTestCase {
    private let endpoint = AIEndpoint(userID: "user-a", projectURL: URL(string: "https://project.test")!, publishableKey: "publishable-fixture", token: { "user-jwt" })
    private func session(_ replies: [(Int, String)]) -> URLSession {
        AIProtocol.responses = replies; AIProtocol.requests = []; AIProtocol.bodies = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIProtocol.self]
        return URLSession(configuration: config)
    }
    private func event(_ object: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }

    func testOpenAIGoesThroughTheProxyWithOneTaskIdAndReportsUsage() async throws {
        let first = try event(["type":"response.completed", "response":["output":[["type":"function_call","call_id":"call-1","name":"read_material","arguments":"{\"materialID\":\"a\"}"]],"usage":["input_tokens":20,"output_tokens":4]]])
          + event(["bandal_usage": ["costUcents": 7, "percent": 3]])
        let second = try event(["type":"response.output_text.delta","delta":"참고 자료의 답변"])
          + event(["type":"response.completed","response":["output":[],"usage":["input_tokens":30,"output_tokens":10]]])
        var calls = 0, deltas = "", usages: [[String: Any]] = []
        let client = AIClient(provider: .openai, model: "gpt-6-luna", endpoint: endpoint, task: "11111111-1111-4111-8111-111111111111", kind: "summary", session: session([(200, first), (200, second)]))
        let result = try await client.run(messages: [ChatMessage(role: "user", text: "요약")], system: "test", tools: [AITool(name: "read_material", description: "test", properties: [:], required: [])], onDelta: { deltas += $0 }, onTool: { _ in }, execute: { call in
            calls += 1; XCTAssertEqual(call.id, "call-1"); return "source text"
        }, effort: "max", onUsage: { usages.append($0) })
        XCTAssertEqual(calls, 1); XCTAssertEqual(result.text, deltas); XCTAssertEqual(result.inputTokens, 50); XCTAssertEqual(result.outputTokens, 14)
        XCTAssertEqual(usages.first?["costUcents"] as? Int, 7)
        XCTAssertEqual(AIProtocol.requests.count, 2)
        for request in AIProtocol.requests {
            XCTAssertEqual(request.url?.absoluteString, "https://project.test/functions/v1/ai-proxy/v1/openai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "publishable-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bandal-Task"), "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bandal-Kind"), "summary")
        }
        XCTAssertEqual((AIProtocol.bodies[0]["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
    }

    func testClaudeReturnsThinkingBlocksUnchangedOnTheNextStep() async throws {
        let first = try event(["type":"message_start","message":["usage":["input_tokens":7]]])
          + event(["type":"content_block_start","index":0,"content_block":["type":"thinking","thinking":""]])
          + event(["type":"content_block_delta","index":0,"delta":["type":"thinking_delta","thinking":"생각"]])
          + event(["type":"content_block_delta","index":0,"delta":["type":"signature_delta","signature":"sig-1"]])
          + event(["type":"content_block_start","index":1,"content_block":["type":"tool_use","id":"tu-1","name":"list_materials","input":[:]]])
          + event(["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"{}"]])
          + event(["type":"message_delta","delta":["stop_reason":"tool_use"],"usage":["output_tokens":2]]) + event(["type":"message_stop"])
        let second = try event(["type":"message_start","message":["usage":["input_tokens":9]]])
          + event(["type":"content_block_start","index":0,"content_block":["type":"text","text":""]])
          + event(["type":"content_block_delta","index":0,"delta":["type":"text_delta","text":"안녕"]])
          + event(["type":"message_delta","delta":["stop_reason":"end_turn"],"usage":["output_tokens":2]]) + event(["type":"message_stop"])
        let client = AIClient(provider: .claude, model: "claude-haiku-5-5", endpoint: endpoint, session: session([(200, first), (200, second)]))
        let result = try await client.run(messages: [ChatMessage(role: "user", text: "q")], system: "test", tools: [AITool(name: "list_materials", description: "", properties: [:], required: [])], onDelta: { _ in }, onTool: { _ in }, execute: { _ in "[]" }, effort: "low")
        XCTAssertEqual(result.text, "안녕")
        XCTAssertEqual(AIProtocol.requests.first?.url?.path, "/functions/v1/ai-proxy/v1/anthropic")
        XCTAssertEqual((AIProtocol.bodies[0]["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let assistant = (AIProtocol.bodies[1]["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "assistant" }
        let content = assistant?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(content.first?["signature"] as? String, "sig-1")
        XCTAssertEqual(content.first?["thinking"] as? String, "생각")
        XCTAssertEqual(content.last?["id"] as? String, "tu-1")
    }

    func testProxyRefusalsBecomeServerErrorsAndTruncatedStreamsFail() async throws {
        do {
            _ = try await AIClient(provider: .openai, model: "gpt-6-luna", endpoint: endpoint, session: session([(402, "{\"code\":\"BUDGET_EXHAUSTED\",\"usage\":{\"plan\":\"plus\"}}")])).run(messages: [], system: "test", tools: [], onDelta: { _ in }, onTool: { _ in }, execute: { _ in "" })
            XCTFail("Refused request reported success")
        } catch AIError.server(let code, let info) {
            XCTAssertEqual(code, "BUDGET_EXHAUSTED"); XCTAssertEqual((info["usage"] as? [String: Any])?["plan"] as? String, "plus")
        }
        do {
            _ = try await AIClient(provider: .openai, model: "gpt-6-luna", endpoint: endpoint, session: session([(200, try event(["type":"response.output_text.delta","delta":"partial"]))])).run(messages: [], system: "test", tools: [], onDelta: { _ in }, onTool: { _ in }, execute: { _ in "" })
            XCTFail("Incomplete response reported success")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testUnlistedToolIsNeverExecuted() async throws {
        let body = try event(["type":"response.completed","response":["output":[["type":"function_call","call_id":"forbidden","name":"run_shell","arguments":"{}"]]]])
        do {
            _ = try await AIClient(provider: .openai, model: "gpt-6-luna", endpoint: endpoint, session: session([(200, body)])).run(messages: [], system: "test", tools: [], onDelta: { _ in }, onTool: { _ in }, execute: { _ in XCTFail("Forbidden tool executed"); return "" })
            XCTFail("Unlisted tool should throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("허용되지")) }
    }

    func testBothProvidersReceiveImages() async throws {
        for (provider, body, field) in [(AIProvider.openai, try event(["type": "response.completed", "response": ["output": []]]), "input_image"), (.claude, try event(["type": "message_stop"]), "media_type")] {
            let message = ChatMessage(role: "user", text: "attached fixture")
            _ = try await AIClient(provider: provider, model: "fixture", endpoint: endpoint, session: session([(200, body)])).run(messages: [message], system: "test", tools: [], onDelta: { _ in }, onTool: { _ in }, execute: { _ in "" }, images: [message.id: [AIInputImage(mediaType: "image/png", dataBase64: "AQID")]])
            let content = String(decoding: try JSONSerialization.data(withJSONObject: AIProtocol.bodies[0]), as: UTF8.self)
            XCTAssertTrue(content.contains(field)); XCTAssertTrue(content.contains("AQID"))
        }
    }
}
