import Foundation

private final class MCPRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Private HTTPS MCP boundary. Registry secrets arrive only from JSCore, never
/// from an external page, and redirects cannot carry credentials to another host.
@MainActor
final class DesktopMCPService {
    struct Config {
        let id: String; let url: URL; let headers: [String: String]
        init(_ value: [String: Any]) throws {
            guard value["transport"] as? String == "http", let id = value["id"] as? String, !id.isEmpty,
                  let raw = value["url"] as? String, raw.utf8.count <= 8192, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
                throw DesktopRuntimeError("iPad MCP는 사용자 정보가 없는 HTTPS 서버 주소만 지원합니다. 로컬 stdio 서버는 실행할 수 없습니다.")
            }
            let headers = value["headers"] as? [String: String] ?? [:]
            let reserved = Set(["host", "content-length", "content-type", "accept", "connection", "transfer-encoding", "mcp-session-id", "mcp-protocol-version", "origin"])
            guard headers.count <= 30, headers.allSatisfy({ key, value in
                !key.isEmpty && key.utf8.count <= 100 && key.utf8.allSatisfy({ (33...126).contains($0) && "!#$%&'*+.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-".utf8.contains($0) }) && !reserved.contains(key.lowercased()) && value.utf8.count <= 16_384 && value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
            }) else { throw DesktopRuntimeError("MCP HTTP 헤더 이름과 값의 형식을 확인해 주세요.") }
            self.id = id; self.url = url; self.headers = headers
        }
    }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private var tasks: [String: (conversation: String, task: Task<Any, Error>)] = [:]
    init(transport: Transport? = nil) {
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: MCPRedirectBlocker(), delegateQueue: nil)
            self.transport = { request in
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 8 * 1024 * 1024 else { throw DesktopRuntimeError("MCP 응답 크기 한도를 초과했습니다.") }
                var data = Data(), line = Data(), eventLines: [String] = []
                let sse = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                let requestID = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["id"] as? String
                defer { bytes.task.cancel() }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 8 * 1024 * 1024 else { throw DesktopRuntimeError("MCP 응답 크기 한도를 초과했습니다.") }; data.append(byte)
                    if sse, let requestID {
                        if byte == 10 {
                            let value = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""; line.removeAll(keepingCapacity: true)
                            if value.isEmpty {
                                let json = eventLines.joined(separator: "\n"); eventLines.removeAll(keepingCapacity: true)
                                if let eventData = json.data(using: .utf8), let envelope = (try? JSONSerialization.jsonObject(with: eventData)) as? [String: Any], envelope["id"] as? String == requestID { return (data, http) }
                            } else if value.hasPrefix("data:") { eventLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                        } else { line.append(byte) }
                    }
                }
                return (data, http)
            }
        }
    }
    func canHandle(_ channel: String) -> Bool { ["native:mcpProbe", "native:mcpCall", "native:mcpCancel"].contains(channel) }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        if channel == "native:mcpCancel" {
            guard let conversation = request["conversationId"] as? String else { throw DesktopRuntimeError("MCP 대화를 확인해 주세요.") }
            for (id, entry) in tasks where entry.conversation == conversation { entry.task.cancel(); tasks.removeValue(forKey: id) }; return ["ok": true]
        }
        guard canHandle(channel), let raw = request["config"] as? [String: Any] else { throw DesktopRuntimeError("MCP 연결 설정을 확인해 주세요.") }
        let config = try Config(raw), requestID = UUID().uuidString, conversation = request["conversationId"] as? String ?? ""
        guard tasks.count < 8 else { throw DesktopRuntimeError("MCP 요청이 많습니다. 진행 중인 작업이 끝난 뒤 다시 시도해 주세요.") }
        let task = Task<Any, Error> {
            let started = Date()
            do {
                var connection = try await Connection.open(config: config, transport: self.transport)
                let tools = try await connection.listTools()
                if channel == "native:mcpProbe" { return ["tools": tools, "durationMs": Int(Date().timeIntervalSince(started) * 1000)] }
                guard let tool = request["tool"] as? String, let actual = tools.first(where: { $0["name"] as? String == tool }),
                      let schema = request["expectedSchema"] as? [String: Any],
                      try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: actual["inputSchema"] ?? [:], options: [.sortedKeys]),
                      let arguments = request["arguments"] as? [String: Any], try JSONSerialization.data(withJSONObject: arguments).count <= 256 * 1024 else {
                    throw DesktopRuntimeError("MCP 도구 설정이 바뀌었거나 입력이 올바르지 않습니다. 연결을 다시 확인해 주세요.")
                }
                return try await connection.rpc("tools/call", params: ["name": tool, "arguments": arguments])
            } catch is CancellationError { throw CancellationError() }
            catch { throw DesktopRuntimeError(Self.redact(error.localizedDescription, config: config)) }
        }
        tasks[requestID] = (conversation, task)
        let deadline = Task { try await Task.sleep(for: .seconds(30)); task.cancel() }
        defer { tasks.removeValue(forKey: requestID); deadline.cancel() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    static func redact(_ message: String, config: Config) -> String {
        var text = message
        for secret in config.headers.values.flatMap({ value in [value, value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)) : ""] }).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: secret, with: "[redacted]") }
        text = text.replacingOccurrences(of: config.url.absoluteString, with: config.url.host ?? "MCP 서버")
        return String(text.prefix(1000))
    }
    private struct Connection {
        let config: Config; let transport: Transport
        var sessionID: String?; var protocolVersion = "2025-03-26"
        static func open(config: Config, transport: @escaping Transport) async throws -> Connection {
            var connection = Connection(config: config, transport: transport)
            let result = try await connection.rpc("initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "bandal-ipad", "version": DesktopVersion.current]])
            guard let version = result["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version), let capabilities = result["capabilities"] as? [String: Any], capabilities["tools"] != nil else { throw DesktopRuntimeError("이 MCP 서버의 도구 프로토콜을 지원하지 않습니다.") }
            connection.protocolVersion = version
            _ = try await connection.send(["jsonrpc": "2.0", "method": "notifications/initialized"], responseID: nil)
            return connection
        }
        mutating func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
            let id = UUID().uuidString
            let envelope = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], responseID: id)
            guard let result = envelope?["result"] as? [String: Any] else { throw DesktopRuntimeError("MCP 서버가 요청 결과를 반환하지 않았습니다.") }; return result
        }
        mutating func send(_ body: [String: Any], responseID: String?) async throws -> [String: Any]? {
            try Task.checkCancellation()
            var request = URLRequest(url: config.url); request.httpMethod = "POST"; request.timeoutInterval = 20
            for (key, value) in config.headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if body["method"] as? String != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard data.count <= 8 * 1024 * 1024 else { throw DesktopRuntimeError("MCP 응답 크기 한도를 초과했습니다.") }
            guard (200...299).contains(response.statusCode) else { throw DesktopRuntimeError("MCP 서버 요청 실패 (HTTP \(response.statusCode)). 연결 설정을 확인해 주세요.") }
            if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                guard session.utf8.count <= 1024, !session.isEmpty, session.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw DesktopRuntimeError("MCP 세션 응답이 올바르지 않습니다.") }
                if sessionID != nil && sessionID != session { throw DesktopRuntimeError("MCP 서버 세션이 요청 중 변경되었습니다.") }; sessionID = session
            }
            guard let responseID else { return nil }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let values: [[String: Any]]
            if contentType.contains("text/event-stream") {
                guard let text = String(data: data, encoding: .utf8) else { throw DesktopRuntimeError("MCP 스트림 문자 형식이 올바르지 않습니다.") }
                values = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { event in
                    let json = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    guard let bytes = json.data(using: .utf8) else { return nil }; return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                }
            } else if contentType.contains("application/json") { values = [(try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]] }
            else { throw DesktopRuntimeError("MCP 응답 형식을 지원하지 않습니다.") }
            guard let envelope = values.last(where: { $0["id"] as? String == responseID }), envelope["jsonrpc"] as? String == "2.0" else { throw DesktopRuntimeError("MCP 응답 식별자가 요청과 일치하지 않습니다.") }
            if let error = envelope["error"] as? [String: Any] { throw DesktopRuntimeError("MCP 도구 실행 실패 (코드 \((error["code"] as? NSNumber)?.stringValue ?? "unknown")).") }
            return envelope
        }
        mutating func listTools() async throws -> [[String: Any]] {
            var tools: [[String: Any]] = [], cursor: String?, cursors = Set<String>()
            repeat {
                let result = try await rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
                guard let entries = result["tools"] as? [[String: Any]], entries.allSatisfy({ ($0["name"] as? String)?.isEmpty == false && ($0["name"] as? String)?.utf8.count ?? 999 < 128 && $0["inputSchema"] is [String: Any] }), tools.count + entries.count <= 100 else { throw DesktopRuntimeError("MCP 도구 목록 형식 또는 100개 한도를 확인해 주세요.") }
                tools += entries; cursor = result["nextCursor"] as? String
                if let cursor { guard cursors.insert(cursor).inserted, cursors.count < 20 else { throw DesktopRuntimeError("MCP 도구 목록 페이지가 반복되거나 너무 많습니다.") } }
            } while cursor != nil
            guard Set(tools.compactMap { $0["name"] as? String }).count == tools.count else { throw DesktopRuntimeError("MCP 서버가 중복된 도구 이름을 반환했습니다.") }; return tools
        }
    }
}
