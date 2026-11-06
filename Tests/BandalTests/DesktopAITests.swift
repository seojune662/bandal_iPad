import XCTest
@testable import Bandal

/// A fake ai-proxy: /config and /consent answer JSON, /v1/<provider> streams `stream`.
/// URLProtocol runs on a background thread, so its shared state is behind a lock.
private final class ProxyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = (stream: "", relayStatus: 200, hold: false, consents: [String: Int](), paths: [String](), bodies: [[String: Any]]())
    static func reset(stream: String, relayStatus: Int, hold: Bool, consents: [String: Int]) {
        lock.withLock { state = (stream, relayStatus, hold, consents, [], []) }
    }
    static var paths: [String] { lock.withLock { state.paths } }
    static var bodies: [[String: Any]] { lock.withLock { state.bodies } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let snapshot = Self.lock.withLock { () -> (stream: String, relayStatus: Int, hold: Bool, consents: [String: Int]) in
            Self.state.paths.append(path); Self.state.bodies.append(body)
            if path.hasSuffix("/consent"), let provider = body["provider"] as? String { Self.state.consents[provider] = body["version"] as? Int ?? 0 }
            return (Self.state.stream, Self.state.relayStatus, Self.state.hold, Self.state.consents)
        }
        let status: Int, reply: Data
        if path.hasSuffix("/config") {
            status = 200
            reply = try! JSONSerialization.data(withJSONObject: [
                "models": [["id": "claude-haiku-5-5", "provider": "anthropic", "label": "Claude Haiku 5.5", "contextCap": 100000, "badge": 1],
                           ["id": "gpt-6-sol", "provider": "openai", "label": "GPT-6 Sol", "contextCap": 100000, "badge": 20]],
                "auto": ["id": "claude-haiku-5-5", "provider": "anthropic", "contextCap": 30000],
                "consentVersion": 1, "usage": ["plan": "none", "percent": 10, "consents": snapshot.consents]])
        } else if path.hasSuffix("/consent") {
            status = 200; reply = try! JSONSerialization.data(withJSONObject: ["plan": "none", "consents": snapshot.consents])
        } else {
            if snapshot.hold { return }
            status = snapshot.relayStatus; reply = Data(snapshot.stream.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DesktopAITests: XCTestCase {
    private var usages: [[String: Any]] = []
    private var limits: [String] = []
    private func environment(_ stream: String, status: Int = 200, consents: [String: Int] = ["anthropic": 1, "openai": 1], hold: Bool = false) -> DesktopAIEnvironment {
        ProxyProtocol.reset(stream: stream, relayStatus: status, hold: hold, consents: consents)
        usages = []; limits = []
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ProxyProtocol.self]
        var value = DesktopAIEnvironment(); value.session = URLSession(configuration: configuration)
        value.endpoint = { AIEndpoint(userID: "user-a", projectURL: URL(string: "https://project.test")!, publishableKey: "pk", token: { "jwt" }) }
        value.hasConsent = { _, _, _ in true }; value.askConsent = { _ in XCTFail("Unexpected consent prompt"); return false }
        value.onUsage = { [weak self] in self?.usages.append($0) }
        value.onLimit = { [weak self] code, _ in self?.limits.append(code) }
        return value
    }
    private func event(_ value: [String: Any]) throws -> String { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n" }
    private func request(model: String = "default") -> [String: Any] { ["requestId": UUID().uuidString, "provider": "claude-code", "model": model, "messages": [["role": "user", "text": "fixture only"]], "tools": []] }
    private var claudeAnswer: String {
        get throws {
            try event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "안녕"]])
                + event(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]]) + event(["type": "message_stop"])
                + event(["bandal_usage": ["percent": 11, "plan": "none"]])
        }
    }
    private func ready(_ service: DesktopAIService) {
        service.onEvent = { _, _ in }; service.onTool = { _, _ in "" }
    }

    func testSignedOutIsReportedWithoutSendingAnything() async throws {
        var fixture = environment("")
        fixture.endpoint = { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
        let service = DesktopAIService(environment: fixture)
        let availability = try await service.handle(channel: "native:aiAvailability", request: [:]) as? [String: Any]
        XCTAssertEqual(availability?["loggedIn"] as? Bool, false)
        ready(service)
        do { _ = try await service.handle(channel: "native:aiRun", request: request()); XCTFail("Ran signed out") }
        catch let error as DesktopRuntimeError { XCTAssertEqual(error.code, "SIGN_IN_REQUIRED") }
        XCTAssertTrue(ProxyProtocol.paths.isEmpty)
    }

    func testUnknownOrDefaultModelRunsOnAutoAndStreamsDeltasAndUsage() async throws {
        let service = DesktopAIService(environment: environment(try claudeAnswer))
        var received = ""
        service.onEvent = { _, event in await Task.yield(); received += event["text"] as? String ?? "" }
        service.onTool = { _, _ in XCTFail("Unexpected tool"); return "" }
        for model in ["default", "gpt-5-mini", ""] {
            received = ""
            let result = try await service.handle(channel: "native:aiRun", request: request(model: model)) as? [String: Any]
            XCTAssertEqual(received, "안녕"); XCTAssertEqual(result?["text"] as? String, received)
            XCTAssertEqual(result?["model"] as? String, "claude-haiku-5-5")
        }
        XCTAssertEqual(ProxyProtocol.paths.filter { $0.hasSuffix("/config") }.count, 1, "config is cached")
        XCTAssertEqual(ProxyProtocol.paths.last, "/functions/v1/ai-proxy/v1/anthropic")
        XCTAssertEqual(usages.last?["percent"] as? Int, 11)
    }

    func testAModelTheProxyOffersKeepsItsProvider() async throws {
        let body = try event(["type": "response.output_text.delta", "delta": "hi"]) + event(["type": "response.completed", "response": ["output": []]])
        let service = DesktopAIService(environment: environment(body)); ready(service)
        _ = try await service.handle(channel: "native:aiRun", request: request(model: "gpt-6-sol"))
        XCTAssertEqual(ProxyProtocol.paths.last, "/functions/v1/ai-proxy/v1/openai")
        XCTAssertEqual(ProxyProtocol.bodies.last?["model"] as? String, "gpt-6-sol")
    }

    func testDeclinedConsentSendsNothingAndAsksOnce() async throws {
        var fixture = environment("", consents: [:])
        var asked: [AIProvider] = []
        fixture.hasConsent = { _, _, _ in false }; fixture.askConsent = { provider in asked.append(provider); await Task.yield(); return false }
        let service = DesktopAIService(environment: fixture)
        service.onEvent = { _, _ in XCTFail("Declined request emitted output") }; service.onTool = { _, _ in XCTFail("Declined request called tool"); return "" }
        let first = Task { _ = try await service.handle(channel: "native:aiRun", request: self.request()) }
        let second = Task { _ = try await service.handle(channel: "native:aiRun", request: self.request()) }
        for task in [first, second] { if case .success = await task.result { XCTFail("Declined request returned success") } }
        XCTAssertEqual(asked, [.claude])
        XCTAssertEqual(ProxyProtocol.paths.map { $0.components(separatedBy: "/").last ?? "" }, ["config"], "only the config was read")
    }

    func testGrantedConsentIsRecordedOnTheServerBeforeSending() async throws {
        var fixture = environment(try claudeAnswer, consents: [:])
        var granted = false
        fixture.hasConsent = { _, _, _ in granted }; fixture.setConsent = { _, _, _ in granted = true }; fixture.askConsent = { _ in true }
        let service = DesktopAIService(environment: fixture); ready(service)
        _ = try await service.handle(channel: "native:aiRun", request: request())
        XCTAssertEqual(ProxyProtocol.paths.map { $0.components(separatedBy: "/").last ?? "" }, ["config", "consent", "anthropic"])
        XCTAssertEqual(ProxyProtocol.bodies[1]["provider"] as? String, "anthropic")
        XCTAssertEqual(ProxyProtocol.bodies[1]["version"] as? Int, DesktopAIService.consentVersion)
        // The next request needs neither the sheet nor another record.
        _ = try await service.handle(channel: "native:aiRun", request: request())
        XCTAssertEqual(ProxyProtocol.paths.filter { $0.hasSuffix("/consent") }.count, 1)
    }

    func testAnotherAccountNeverInheritsConfigOrConsent() async throws {
        var fixture = environment(try claudeAnswer, consents: [:])
        var user = "user-a"
        var granted: Set<String> = []
        fixture.endpoint = { AIEndpoint(userID: user, projectURL: URL(string: "https://project.test")!, publishableKey: "pk", token: { "jwt" }) }
        fixture.hasConsent = { _, account, _ in granted.contains(account) }
        fixture.setConsent = { _, account, _ in granted.insert(account) }
        var asked = 0
        fixture.askConsent = { _ in asked += 1; return true }
        let service = DesktopAIService(environment: fixture); ready(service)
        _ = try await service.handle(channel: "native:aiRun", request: request())
        user = "user-b"
        ProxyProtocol.reset(stream: try claudeAnswer, relayStatus: 200, hold: false, consents: [:])
        _ = try await service.handle(channel: "native:aiRun", request: request())
        XCTAssertEqual(asked, 2, "user B is asked for their own consent")
        XCTAssertEqual(ProxyProtocol.paths.map { $0.components(separatedBy: "/").last ?? "" }, ["config", "consent", "anthropic"], "B's config is loaded fresh")
        XCTAssertEqual(granted, ["user-a", "user-b"])
    }

    func testBudgetRefusalReportsTheLimitAndItsCode() async throws {
        let service = DesktopAIService(environment: environment("{\"code\":\"BUDGET_EXHAUSTED\",\"usage\":{\"plan\":\"plus\",\"percent\":100}}", status: 402)); ready(service)
        do { _ = try await service.handle(channel: "native:aiRun", request: request()); XCTFail("Refused request ran") }
        catch let error as DesktopRuntimeError { XCTAssertEqual(error.code, "BUDGET_EXHAUSTED"); XCTAssertTrue(error.localizedDescription.contains("다 썼어요")) }
        XCTAssertEqual(limits, ["BUDGET_EXHAUSTED"])
        XCTAssertEqual(usages.last?["percent"] as? Int, 100)
    }

    func testCancelStopsAnInFlightRequest() async throws {
        let service = DesktopAIService(environment: environment("", hold: true))
        service.onEvent = { _, _ in XCTFail("Cancelled request emitted output") }; service.onTool = { _, _ in XCTFail("Cancelled request called tool"); return "" }
        let input = request()
        let active = Task { try await service.handle(channel: "native:aiRun", request: input) }
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !ProxyProtocol.paths.contains(where: { $0.hasSuffix("/anthropic") }) { guard ContinuousClock.now < limit else { throw URLError(.timedOut) }; await Task.yield() }
        _ = try await service.handle(channel: "native:aiCancel", request: ["requestId": input["requestId"]!])
        do { _ = try await active.value; XCTFail("Cancelled request returned success") } catch {}
    }

    func testToolResultsAreCutToTheModelsContext() {
        let config: [String: Any] = ["auto": ["id": "claude-haiku-5-5", "contextCap": 30000], "models": [["id": "gpt-6-sol", "contextCap": 100000]]]
        XCTAssertEqual(DesktopAIService.toolResultLimit(model: "claude-haiku-5-5", config: config), 20000)
        XCTAssertEqual(DesktopAIService.toolResultLimit(model: "gpt-6-sol", config: config), 66666)
    }
}
