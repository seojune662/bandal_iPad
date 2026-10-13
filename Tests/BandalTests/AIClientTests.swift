import XCTest
@testable import Bandal

private final class AIProtocol: URLProtocol {
    static var responses: [(Int, String)] = []
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard !Self.responses.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let value = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(value.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AIClientTests: XCTestCase {
    private func session(_ replies: [(Int, String)]) -> URLSession {
        AIProtocol.responses = replies; AIProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIProtocol.self]
        return URLSession(configuration: config)
    }
    private func event(_ object: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }
    func testOpenAIToolResultRoundTripAndUsage() async throws {
        let first = try event(["type":"response.completed", "response":["output":[["type":"function_call","call_id":"call-1","name":"read_material","arguments":"{\"materialID\":\"a\"}"]],"usage":["input_tokens":20,"output_tokens":4]]])
        let second = try event(["type":"response.output_text.delta","delta":"참고 자료의 답변"])
          + event(["type":"response.completed","response":["output":[],"usage":["input_tokens":30,"output_tokens":10]]])
        var calls = 0, deltas = ""
        let result = try await AIClient(provider:.openai, model:"fixture", key:"test-only", session:session([(200,first),(200,second)])).run(messages:[ChatMessage(role:"user",text:"요약")],system:"test",tools:[AITool(name:"read_material",description:"test",properties:[:],required:[])],onDelta:{ deltas += $0 },onTool:{ _ in },execute:{ call in
            calls += 1; XCTAssertEqual(call.id,"call-1"); return "source text"
        })
        XCTAssertEqual(calls,1); XCTAssertEqual(result.text,deltas); XCTAssertEqual(result.inputTokens,50); XCTAssertEqual(result.outputTokens,14)
        XCTAssertEqual(AIProtocol.requests.count,2)
        XCTAssertEqual(AIProtocol.requests[0].value(forHTTPHeaderField:"Authorization"),"Bearer test-only")
    }
    func testClaudeAndGeminiStreamCompletion() async throws {
        let claude = try event(["type":"message_start","message":["usage":["input_tokens":7]]])
          + event(["type":"content_block_delta","delta":["type":"text_delta","text":"안녕"]])
          + event(["type":"message_delta","delta":["stop_reason":"end_turn"],"usage":["output_tokens":2]]) + event(["type":"message_stop"])
        let gemini = try event(["candidates":[["content":["parts":[["text":"안녕"]]],"finishReason":"STOP"]],"usageMetadata":["promptTokenCount":7,"candidatesTokenCount":2]])
        for (provider,body) in [(AIProvider.claude,claude),(.gemini,gemini)] {
            let result = try await AIClient(provider:provider,model:"fixture",key:"test-only",session:session([(200,body)])).run(messages:[],system:"test",tools:[],onDelta:{ _ in },onTool:{ _ in },execute:{ _ in XCTFail("Unexpected tool"); return "" })
            XCTAssertEqual(result.text,"안녕"); XCTAssertEqual(result.inputTokens,7); XCTAssertEqual(result.outputTokens,2)
        }
    }
    func testTruncatedStreamAndRateLimitAreErrors() async throws {
        for (status,body) in [(200,try event(["type":"response.output_text.delta","delta":"partial"])),(429,"{\"error\":{\"message\":\"quota\"}}") ] {
            do {
                _ = try await AIClient(provider:.openai,model:"fixture",key:"test-only",session:session([(status,body)])).run(messages:[],system:"test",tools:[],onDelta:{ _ in },onTool:{ _ in },execute:{ _ in "" })
                XCTFail("Incomplete and failed responses must not report success")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testUnlistedToolIsNeverExecuted() async throws {
        let body = try event(["type":"response.completed","response":["output":[["type":"function_call","call_id":"forbidden","name":"run_shell","arguments":"{}"]]]])
        do {
            _ = try await AIClient(provider:.openai,model:"fixture",key:"test-only",session:session([(200,body)])).run(messages:[],system:"test",tools:[],onDelta:{ _ in },onTool:{ _ in },execute:{ _ in XCTFail("Forbidden tool executed"); return "" })
            XCTFail("Unlisted tool should throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("허용되지")) }
    }
}
