import Foundation
import CryptoKit
import Darwin

/// Public catalog downloads never share browser cookies or account credentials.
/// Native rechecks a selected artifact against its currently configured index.
@MainActor
final class DesktopPluginCatalogTransport {
    typealias Request = (URLRequest, Int64) async throws -> (URL, HTTPURLResponse)
    private struct Body { let file: URL; let handle: FileHandle; let expires: Date }
    private let sources: () async throws -> [String]
    private let request: Request
    private let resolve: (String) async throws -> Void
    private var tasks: [String: Task<[String: Any], Error>] = [:]
    private var bodies: [String: Body] = [:]
    private var cancelled: [String: Date] = [:]
    private static let official = "https://bandal.io/plugins/index.json"
    init(sources: @escaping () async throws -> [String], request: @escaping Request = DesktopDownloadTransport.request,
         resolve: @escaping (String) async throws -> Void = { host in try await Task.detached { try DesktopPluginCatalogTransport.resolvePublicHost(host) }.value }) {
        self.sources = sources; self.request = request; self.resolve = resolve
    }
    func canHandle(_ channel: String) -> Bool { ["native:catalogRequest", "native:catalogRead", "native:catalogCancel"].contains(channel) }
    func handle(channel: String, request input: [String: Any]) async throws -> Any {
        prune()
        guard let id = (input["id"] ?? input["bodyID"]) as? String, id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw DesktopRuntimeError("카탈로그 요청 ID를 확인해 주세요.") }
        if channel == "native:catalogCancel" { cancelled[id] = Date(); tasks[id]?.cancel(); close(id); return ["ok": true] }
        guard cancelled[id] == nil else { throw CancellationError() }
        if channel == "native:catalogRead" {
            guard let body = bodies[id] else { throw DesktopRuntimeError("카탈로그 읽기가 만료되었습니다.") }
            let bytes = try body.handle.read(upToCount: 512 * 1024) ?? Data()
            if bytes.isEmpty { close(id) }
            return ["data": bytes.base64EncodedString(), "done": bytes.isEmpty]
        }
        guard channel == "native:catalogRequest", tasks[id] == nil, bodies[id] == nil, tasks.count + bodies.count < 24 else { throw DesktopRuntimeError("진행 중인 카탈로그 요청이 끝난 뒤 다시 시도해 주세요.") }
        let task = Task { try await self.fetch(id: id, input: input) }; tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func allowed(_ source: URL) async throws -> Bool {
        let configured = [Self.official] + (try await sources())
        return configured.contains { (try? Self.validateURL($0)) == source }
    }
    private func fetch(id: String, input: [String: Any]) async throws -> [String: Any] {
        guard (input["method"] as? String ?? "GET") == "GET", (input["headers"] as? [String: String] ?? [:]).isEmpty,
              input["bodyBase64"] == nil, !(input["accountID"] is String), let raw = input["url"] as? String,
              let rawSource = input["sourceUrl"] as? String, let kind = input["kind"] as? String, ["index", "artifact"].contains(kind) else { throw DesktopRuntimeError("카탈로그는 인증 없는 읽기 요청만 지원합니다.") }
        let url = try Self.validateURL(raw), source = try Self.validateURL(rawSource)
        guard try await allowed(source) else { throw DesktopRuntimeError("설정에 등록되지 않은 카탈로그입니다.") }
        var expected: String?
        if kind == "index" { guard url == source else { throw DesktopRuntimeError("카탈로그 주소가 일치하지 않습니다.") } }
        else {
            guard let entryID = input["entryID"] as? String, entryID.count <= 128, let sha = input["sha256"] as? String,
                  sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw DesktopRuntimeError("카탈로그 항목을 확인해 주세요.") }
            let (index, response) = try await download(source, maximum: 1024 * 1024, timeout: 10)
            defer { try? FileManager.default.removeItem(at: index) }
            guard (200..<300).contains(response.statusCode), let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any],
                  envelope["format"] as? String == "bandal-plugin-catalog", (envelope["version"] as? NSNumber)?.intValue == 1,
                  let entries = envelope["entries"] as? [[String: Any]],
                  let entry = entries.first(where: { $0["id"] as? String == entryID }), let rawArtifact = entry["url"] as? String,
                  let artifact = URL(string: rawArtifact, relativeTo: source)?.absoluteURL,
                  try Self.validateURL(artifact.absoluteString) == url, entry["sha256"] as? String == sha else { throw DesktopRuntimeError("카탈로그 항목이 변경되었습니다. 새로고침하고 다시 설치해 주세요.") }
            expected = sha
        }
        try Task.checkCancellation()
        guard cancelled[id] == nil, try await allowed(source) else { throw CancellationError() }
        let (file, response) = try await download(url, maximum: kind == "index" ? 1024 * 1024 : 8 * 1024 * 1024, timeout: kind == "index" ? 10 : 30)
        do {
            try Task.checkCancellation()
            guard cancelled[id] == nil, try await allowed(source) else { throw CancellationError() }
            if let expected, (200..<300).contains(response.statusCode) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var hash = SHA256()
                while let part = try handle.read(upToCount: 256 * 1024), !part.isEmpty { try Task.checkCancellation(); hash.update(data: part) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw DesktopRuntimeError("파일이 카탈로그와 달라요.") }
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            bodies[id] = Body(file: file, handle: try FileHandle(forReadingFrom: file), expires: Date().addingTimeInterval(120))
            var headers: [String: String] = ["content-length": String(size)]
            if let mime = response.value(forHTTPHeaderField: "Content-Type") { headers["content-type"] = mime }
            return ["status": response.statusCode, "headers": headers, "bodyID": id, "byteCount": size]
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private func download(_ url: URL, maximum: Int64, timeout: TimeInterval) async throws -> (URL, HTTPURLResponse) {
        try await resolve(url.host!); try Task.checkCancellation()
        var input = URLRequest(url: url); input.httpMethod = "GET"; input.timeoutInterval = timeout; input.httpShouldHandleCookies = false
        let (file, response) = try await request(input, maximum)
        do {
            try Task.checkCancellation()
            guard response.url == url, !(300..<400).contains(response.statusCode),
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximum else { throw URLError(.badServerResponse) }
            return (file, response)
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    nonisolated static func validateURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8192, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.fragment == nil,
              let rawHost = url.host, !rawHost.isEmpty else { throw DesktopRuntimeError("HTTPS 카탈로그 주소를 확인해 주세요.") }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        guard host.contains(".") || host.contains(":"), !["localhost", "local", "internal"].contains(host),
              ![".localhost", ".local", ".internal", ".lan", ".home.arpa"].contains(where: host.hasSuffix),
              !Self.isPrivateLiteral(host) else { throw DesktopRuntimeError("로컬 네트워크 주소는 카탈로그에 사용할 수 없습니다.") }
        return url
    }
    nonisolated private static func isPrivateLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return !publicIPv4(withUnsafeBytes(of: v4) { Array($0) }) }
        if inet_pton(AF_INET6, host, &v6) == 1 { return !publicIPv6(withUnsafeBytes(of: v6) { Array($0) }) }
        return false
    }
    nonisolated private static func publicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] != 0 && b[0] != 10 && b[0] != 127 && b[0] < 224 && !(b[0] == 100 && (64...127).contains(b[1])) && !(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && (16...31).contains(b[1])) && !(b[0] == 192 && (b[1] == 168 || b[1] == 0)) && !(b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) && !(b[0] == 203 && b[1] == 0 && b[2] == 113)
    }
    nonisolated private static func publicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // DNS64 on IPv6-only mobile networks uses this public translation
        // prefix. Apply the IPv4 policy to its embedded address as well.
        if Array(b.prefix(12)) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] || Array(b.prefix(12)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] { return publicIPv4(Array(b.suffix(4))) }
        if b[0] == 0x20 && b[1] == 2 { return publicIPv4(Array(b[2..<6])) }
        return b[0] & 0xe0 == 0x20 && !(b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8)
    }
    nonisolated private static func resolvePublicHost(_ raw: String) throws {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo(), result: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { throw URLError(.cannotFindHost) }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first, count = 0
        while let item = cursor {
            if let address = item.pointee.ai_addr {
                let safe: Bool
                if item.pointee.ai_family == AF_INET { let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr; safe = publicIPv4(withUnsafeBytes(of: value) { Array($0) }) }
                else if item.pointee.ai_family == AF_INET6 { let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr; safe = publicIPv6(withUnsafeBytes(of: value) { Array($0) }) }
                else { safe = false }
                guard safe else { throw DesktopRuntimeError("카탈로그 주소가 로컬 네트워크를 가리킵니다.") }; count += 1
            }
            cursor = item.pointee.ai_next
        }
        guard count > 0 else { throw URLError(.cannotFindHost) }
    }
    private func close(_ id: String) { if let body = bodies.removeValue(forKey: id) { try? body.handle.close(); try? FileManager.default.removeItem(at: body.file) } }
    private func prune() { let now = Date(); for (id, body) in bodies where body.expires < now { close(id) }; cancelled = cancelled.filter { now.timeIntervalSince($0.value) < 120 } }
    deinit { tasks.values.forEach { $0.cancel() }; for body in bodies.values { try? body.handle.close(); try? FileManager.default.removeItem(at: body.file) } }
}
