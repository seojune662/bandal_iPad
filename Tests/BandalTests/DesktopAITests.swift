import XCTest
@testable import Bandal

private final class DesktopAIProtocol: URLProtocol {
    static var body = ""
    static var requests: [URLRequest] = []
    static var hold = false
    static var requestBodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let body = request.httpBody { Self.requestBodies.append(body) }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            Self.requestBodies.append(body)
        }
        if Self.hold { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DesktopAITests: XCTestCase {
    private func environment(_ body: String, hold: Bool = false) -> DesktopAIEnvironment {
        DesktopAIProtocol.body = body; DesktopAIProtocol.requests = []; DesktopAIProtocol.requestBodies = []; DesktopAIProtocol.hold = hold
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DesktopAIProtocol.self]
        var value = DesktopAIEnvironment(); value.session = URLSession(configuration: configuration)
        value.readKey = { _ in "fixture-secret-1234" }; value.writeKey = { _, _ in }
        value.hasConsent = { _ in true }; value.askConsent = { _ in XCTFail("Unexpected consent prompt"); return false }
        return value
    }
    private func event(_ value: [String: Any]) throws -> String { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n" }
    private func request(provider: String = "codex") -> [String: Any] { ["requestId": UUID().uuidString, "provider": provider, "model": "fixture", "messages": [["role": "user", "text": "fixture only"]], "tools": []] }
    func testAPIKeysOnlyReturnHintAndNeverPretendCLIInstalled() async throws {
        var writes: [(AIProvider, String)] = []
        var configured: String? = nil
        var fixture = environment("")
        fixture.readKey = { _ in configured }; fixture.writeKey = { provider, value in writes.append((provider, value)); configured = value }
        let service = DesktopAIService(environment: fixture)
        let initial = try await service.handle(channel: "native:aiAvailability", request: ["provider": "codex"]) as? [String: Any]
        XCTAssertEqual(initial?["transport"] as? String, "api"); XCTAssertEqual(initial?["version"] as? String, "iPad API")
        XCTAssertEqual(initial?["loggedIn"] as? Bool, false)
        let status = try await service.handle(channel: "native:aiSetKey", request: ["provider": "codex", "key": "fixture-secret-1234"]) as? [String: Any]
        XCTAssertEqual(status?["hint"] as? String, "1234"); XCTAssertEqual(writes.first?.0, .openai)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: status!), as: UTF8.self).contains("fixture-secret"))
        XCTAssertTrue(DesktopAIProtocol.requests.isEmpty)
    }
    func testNativeStreamAwaitsDeltaDeliveryBeforeCompletion() async throws {
        let body = try event(["type": "response.output_text.delta", "delta": "안녕"])
            + event(["type": "response.completed", "response": ["output": [], "usage": ["input_tokens": 2, "output_tokens": 1]]])
        let service = DesktopAIService(environment: environment(body))
        var received = ""
        service.onEvent = { _, event in await Task.yield(); received += event["text"] as? String ?? "" }
        service.onTool = { _, _ in XCTFail("Unexpected tool"); return "" }
        let result = try await service.handle(channel: "native:aiRun", request: request()) as? [String: Any]
        XCTAssertEqual(received, "안녕"); XCTAssertEqual(result?["text"] as? String, received)
        XCTAssertEqual(DesktopAIProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret-1234")
    }
    func testDeclinedConsentSendsNothing() async throws {
        var fixture = environment("")
        var asked: [AIProvider] = []
        fixture.hasConsent = { _ in false }; fixture.askConsent = { provider in asked.append(provider); await Task.yield(); return false }
        let service = DesktopAIService(environment: fixture)
        service.onEvent = { _, _ in XCTFail("Declined request emitted output") }; service.onTool = { _, _ in XCTFail("Declined request called tool"); return "" }
        let first = Task { _ = try await service.handle(channel: "native:aiRun", request: self.request(provider: "claude-code")) }
        let second = Task { _ = try await service.handle(channel: "native:aiRun", request: self.request(provider: "claude-code")) }
        for task in [first, second] {
            if case .success = await task.result { XCTFail("Declined request returned success") }
        }
        XCTAssertEqual(asked, [.claude])
        XCTAssertTrue(DesktopAIProtocol.requests.isEmpty)
    }
    func testGrantedConsentStillNeedsAKeyBeforeSending() async throws {
        var fixture = environment("")
        fixture.readKey = { _ in nil }; fixture.hasConsent = { _ in false }; fixture.askConsent = { _ in true }
        let service = DesktopAIService(environment: fixture)
        service.onEvent = { _, _ in }; service.onTool = { _, _ in "" }
        do { _ = try await service.handle(channel: "native:aiRun", request: request(provider: "gemini")); XCTFail("Sent without a key") } catch {}
        XCTAssertTrue(DesktopAIProtocol.requests.isEmpty)
    }
    func testKeyChangeCancelsAnInFlightRequest() async throws {
        let service = DesktopAIService(environment: environment("", hold: true))
        service.onEvent = { _, _ in XCTFail("Cancelled request emitted output") }; service.onTool = { _, _ in XCTFail("Cancelled request called tool"); return "" }
        let active = Task { try await service.handle(channel: "native:aiRun", request: request()) }
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while DesktopAIProtocol.requests.isEmpty { guard ContinuousClock.now < limit else { throw URLError(.timedOut) }; await Task.yield() }
        _ = try await service.handle(channel: "native:aiSetKey", request: ["provider": "codex", "key": NSNull()])
        do { _ = try await active.value; XCTFail("Cancelled request returned success") } catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
    }
    func testAllProvidersReceiveActualImageInputs() async throws {
        let openai = try event(["type": "response.completed", "response": ["output": []]])
        let claude = try event(["type": "message_stop"])
        let gemini = try event(["candidates": [["content": ["parts": []], "finishReason": "STOP"]]])
        for (provider, body, imageField) in [(AIProvider.openai, openai, "input_image"), (.claude, claude, "media_type"), (.gemini, gemini, "inlineData")] {
            let fixture = environment(body), message = ChatMessage(role: "user", text: "attached fixture")
            _ = try await AIClient(provider: provider, model: "fixture", key: "test-only", session: fixture.session).run(messages: [message], system: "test", tools: [], onDelta: { _ in }, onTool: { _ in }, execute: { _ in "" }, images: [message.id: [AIInputImage(mediaType: "image/png", dataBase64: "AQID")]], effort: "low")
            let content = String(decoding: try XCTUnwrap(DesktopAIProtocol.requestBodies.first), as: UTF8.self)
            XCTAssertTrue(content.contains(imageField)); XCTAssertTrue(content.contains("AQID"))
        }
    }
}
