import XCTest
@testable import Bandal

@MainActor
final class DesktopMCPTests: XCTestCase {
    let config: [String: Any] = ["id": "fixture", "transport": "http", "url": "https://mcp.example.test/rpc", "headers": ["Authorization": "Bearer fixture-secret"]]
    let schema: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"]]]
    func response(_ request: URLRequest, _ result: [String: Any], sse: Bool = false, session: String? = "fixture-session") throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        var headers = ["Content-Type": sse ? "text/event-stream" : "application/json"]
        if let session { headers["Mcp-Session-Id"] = session }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"] ?? NSNull(), "result": result]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return (sse ? Data(("event: message\ndata: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8) : data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
    func testActualHTTPProtocolSessionPaginationAndApprovedToolCall() async throws {
        var methods: [String] = [], calls = 0
        let service = DesktopMCPService { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let method = body["method"] as! String; methods.append(method)
            if method == "initialize" { return try self.response(request, ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]]]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
            if method == "notifications/initialized" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!) }
            if method == "tools/list" {
                let params = body["params"] as! [String: Any]
                if params["cursor"] == nil { return try self.response(request, ["tools": [["name": "echo", "inputSchema": self.schema]], "nextCursor": "page2"], sse: true) }
                return try self.response(request, ["tools": [["name": "second", "inputSchema": self.schema]]])
            }
            XCTAssertEqual(method, "tools/call"); calls += 1
            XCTAssertEqual((body["params"] as? [String: Any])?["name"] as? String, "echo")
            return try self.response(request, ["content": [["type": "text", "text": "actual fixture result"]]], sse: true)
        }
        let result = try await service.handle(channel: "native:mcpCall", request: ["config": config, "conversationId": "conversation", "tool": "echo", "expectedSchema": schema, "arguments": ["text": "input"]])
        XCTAssertTrue(String(describing: result).contains("actual fixture result")); XCTAssertEqual(calls, 1)
        XCTAssertEqual(methods, ["initialize", "notifications/initialized", "tools/list", "tools/list", "tools/call"])
    }
    func testRedirectAndUnsafeHeadersRejectedWithoutCredentialLeak() async throws {
        var requests = 0
        let service = DesktopMCPService { request in requests += 1; return (Data("secret-server-body".utf8), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.test"])!) }
        let unsafeHeaders = [["Host": "other.test"], ["Authorization": "abc\r\nInjected: yes"], ["Authorization": "abc\rInjected: yes"], ["Authorization": "abc\nInjected: yes"], ["X-Test\n": "value"], ["X-Test": "abc\u{0000}value"], ["X-Test": "abc\u{007f}value"]]
        let invalidConfigs = [config.merging(["url": "http://localhost/rpc"], uniquingKeysWith: { _, new in new })] + unsafeHeaders.map { config.merging(["headers": $0], uniquingKeysWith: { _, new in new }) }
        for invalid in invalidConfigs {
            XCTAssertThrowsError(try DesktopMCPService.Config(invalid))
            do { _ = try await service.handle(channel: "native:mcpProbe", request: ["config": invalid]); XCTFail("Expected invalid configuration") } catch {}
        }
        XCTAssertEqual(requests, 0)
        do { _ = try await service.handle(channel: "native:mcpProbe", request: ["config": config]); XCTFail("Expected redirect rejection") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret")); XCTAssertTrue(error.localizedDescription.contains("302")) }
    }
    func testChangedToolSchemaCannotExecuteAndDuplicateResponseIsBounded() async throws {
        var calls = 0
        let service = DesktopMCPService { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            switch body["method"] as? String {
            case "initialize": return try self.response(request, ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]]])
            case "notifications/initialized": return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
            case "tools/list": return try self.response(request, ["tools": [["name": "echo", "inputSchema": ["type": "object", "properties": ["changed": ["type": "boolean"]]]]]])
            default: calls += 1; return try self.response(request, [:])
            }
        }
        do { _ = try await service.handle(channel: "native:mcpCall", request: ["config": config, "tool": "echo", "expectedSchema": schema, "arguments": [:]]); XCTFail("Expected stale schema rejection") } catch {}
        XCTAssertEqual(calls, 0)
        let mismatch = DesktopMCPService { request in (Data("{\"jsonrpc\":\"2.0\",\"id\":\"wrong\",\"result\":{}}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!) }
        do { _ = try await mismatch.handle(channel: "native:mcpProbe", request: ["config": config]); XCTFail("Expected response mismatch") } catch { XCTAssertTrue(error.localizedDescription.contains("식별자")) }
    }
    func testConversationCancellationStopsPendingNetworkWork() async throws {
        var started = false
        let service = DesktopMCPService { _ in started = true; try await Task.sleep(for: .seconds(60)); throw DesktopRuntimeError("Should cancel first") }
        let operation = Task { try await service.handle(channel: "native:mcpCall", request: ["config": config, "conversationId": "fixture", "tool": "echo", "expectedSchema": schema, "arguments": [:]]) }
        while !started { await Task.yield() }
        _ = try await service.handle(channel: "native:mcpCancel", request: ["conversationId": "fixture"])
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testVaultAuthenticatesCiphertextAndNamespaceWithoutPlaintextFallback() throws {
        var keys: [String: Data] = [:]
        let storage = DesktopMCPVault.Storage(read: { keys[$0] }, write: { keys[$0] = $1 })
        let vault = DesktopMCPVault(namespace: "fixture", storage: storage)
        XCTAssertTrue(vault.available())
        let cipher = try vault.encrypt("Bearer fixture-secret")
        XCTAssertFalse(cipher.contains("fixture-secret")); XCTAssertEqual(try vault.decrypt(cipher), "Bearer fixture-secret")
        var bytes = Data(base64Encoded: cipher)!; bytes[15] ^= 0x01
        XCTAssertThrowsError(try vault.decrypt(bytes.base64EncodedString()))
        XCTAssertThrowsError(try DesktopMCPVault(namespace: "other", storage: storage).decrypt(cipher))
        keys["fixture"] = Data([1, 2]); XCTAssertFalse(vault.available()); XCTAssertThrowsError(try vault.encrypt("must not overwrite")); XCTAssertEqual(keys["fixture"], Data([1, 2]))
    }
}
