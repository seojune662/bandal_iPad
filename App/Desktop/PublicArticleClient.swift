import Foundation
import Network
import Security
import Darwin

/// Anonymous article GETs connect to an already-validated numeric address.
/// DNS rebinding cannot turn a public hostname into access to the local network;
/// TLS still verifies the original hostname. No browser cookies are copied.
struct PublicArticleClient {
    struct Result: Sendable { let url: URL; let html: String }
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    typealias Resolver = @Sendable (String) async throws -> [String]
    typealias Fetch = @Sendable (URL, String) async throws -> Data
    var resolve: Resolver = { host in try await Task.detached(priority: .utility) { try addresses(host) }.value }
    var fetch: Fetch = { try await ArticleConnection.get(url: $0, address: $1) }

    func load(_ input: String) async throws -> Result {
        var current = input
        for _ in 0..<6 {
            try Task.checkCancellation()
            let url = try Self.validateURL(current)
            let host = url.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let addresses = try await resolve(host)
            guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublicAddress) else {
                throw DesktopRuntimeError("로컬 또는 비공개 네트워크의 기사는 자동으로 읽지 않아요.")
            }
            let response = try Self.parse(try await fetch(url, addresses.first(where: { !$0.contains(":") }) ?? addresses[0]))
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard let location = response.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw URLError(.badServerResponse) }
                current = next.absoluteString; continue
            }
            guard (200..<300).contains(response.status) else { throw DesktopRuntimeError("기사 페이지를 읽지 못했어요 (\(response.status)).") }
            let contentType = response.headers["content-type"]?.lowercased() ?? ""
            guard contentType.contains("text/html") || contentType.contains("application/xhtml+xml") else { throw DesktopRuntimeError("읽을 수 있는 HTML 기사 주소가 아니에요.") }
            let encoding = response.headers["content-encoding"]?.lowercased() ?? "identity"
            guard encoding == "identity" else { throw DesktopRuntimeError("기사 서버의 압축 형식을 읽지 못했어요. 원문 탭에서 다시 시도해 주세요.") }
            guard let html = String(data: response.body, encoding: .utf8) ?? String(data: response.body, encoding: .isoLatin1) else { throw URLError(.cannotDecodeContentData) }
            return Result(url: url, html: html)
        }
        throw DesktopRuntimeError("기사 주소의 이동이 너무 많아요.")
    }

    static func validateURL(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(), !host.isEmpty,
              host != "localhost", ![".localhost", ".local", ".internal", ".lan"].contains(where: host.hasSuffix),
              host.contains(".") || host.contains(":"), parts.port == nil || [80, 443].contains(parts.port!),
              !host.contains("%"), !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw DesktopRuntimeError("공개된 HTTP 또는 HTTPS 기사 주소만 사용할 수 있어요.")
        }
        parts.fragment = nil
        guard let url = parts.url else { throw URLError(.badURL) }
        return url
    }

    static func isPublicAddress(_ input: String) -> Bool {
        let address = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { bytes in publicV4(Array(bytes)) }
        }
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return publicV4(Array(bytes.suffix(4))) }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, (bytes[2] == 0x0d && bytes[3] == 0xb8 || bytes[2] == 0 && bytes[3] == 0) { return false }
        return true
    }
    private static func publicV4(_ b: [UInt8]) -> Bool {
        let a = b[0], c = b[1], d = b[2]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || a == 100 && (64...127).contains(c) || a == 169 && c == 254 || a == 172 && (16...31).contains(c) || a == 192 && c == 168 || a == 192 && c == 0 && (d == 0 || d == 2) || a == 198 && (c == 18 || c == 19 || c == 51 && d == 100) || a == 203 && c == 0 && d == 113)
    }

    private static func addresses(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { throw URLError(.dnsLookupFailed) }
        defer { freeaddrinfo(list) }
        var next: UnsafeMutablePointer<addrinfo>? = list, result: [String] = []
        while let entry = next {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: buffer)) }
            next = entry.pointee.ai_next
        }
        return result
    }

    static func parse(_ bytes: Data) throws -> Response {
        guard bytes.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let separator = Data([13, 10, 13, 10])
        var input = bytes
        var status = 0, headers: [String: String] = [:]
        for _ in 0..<8 {
            guard let range = input.range(of: separator), range.lowerBound - input.startIndex <= 64 * 1024,
                  let header = String(data: input[..<range.lowerBound], encoding: .isoLatin1) else { throw URLError(.badServerResponse) }
            let lines = header.components(separatedBy: "\r\n")
            guard let first = lines.first, first.hasPrefix("HTTP/1."), let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw URLError(.badServerResponse) }
            status = code; headers = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw URLError(.badServerResponse) }
                let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let old = headers[key], ["content-length", "transfer-encoding", "location"].contains(key), old != value { throw URLError(.badServerResponse) }
                headers[key] = value
            }
            input = Data(input[range.upperBound...])
            if !(100..<200).contains(code) { break }
            if code == 101 { throw URLError(.badServerResponse) }
        }
        guard status >= 200 else { throw URLError(.badServerResponse) }
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw URLError(.badServerResponse) }
            var output = Data(), offset = input.startIndex
            while offset < input.endIndex {
                guard let lineEnd = input.range(of: Data([13, 10]), in: offset..<input.endIndex), lineEnd.lowerBound - offset <= 1024,
                      let line = String(data: input[offset..<lineEnd.lowerBound], encoding: .ascii),
                      let raw = line.split(separator: ";", maxSplits: 1).first, let size = Int(raw.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { throw URLError(.badServerResponse) }
                offset = lineEnd.upperBound
                if size == 0 { return Response(status: status, headers: headers, body: output) }
                guard size <= input.endIndex - offset - 2, output.count + size <= 8 * 1024 * 1024,
                      input[offset + size] == 13, input[offset + size + 1] == 10 else { throw URLError(.badServerResponse) }
                output.append(input[offset..<(offset + size)]); offset += size + 2
            }
            throw URLError(.badServerResponse)
        }
        if let length = headers["content-length"] {
            guard let count = Int(length), count >= 0, input.count == count else { throw URLError(.badServerResponse) }
        }
        return Response(status: status, headers: headers, body: input)
    }
}

private final class ArticleConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.bandal.public-article")
    private let connection: NWConnection
    private let request: Data
    private var continuation: CheckedContinuation<Data, Error>?
    private var bytes = Data()
    private var finished = false
    private init(url: URL, address: String) throws {
        let tls: NWProtocolTLS.Options?
        if url.scheme == "https" {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, url.host!)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            tls = options
        } else { tls = nil }
        connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? (tls == nil ? 80 : 443)))!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        let host = url.host! + (url.port.map { ":\($0)" } ?? "")
        request = Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Bandal/\(DesktopVersion.current)\r\nAccept: text/html, application/xhtml+xml\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
    }
    static func get(url: URL, address: String) async throws -> Data {
        let client = try ArticleConnection(url: url, address: address)
        return try await withTaskCancellationHandler(operation: { try await client.run() }, onCancel: { client.queue.async { client.finish(.failure(CancellationError())) } })
    }
    private func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            if let error { self.finish(.failure(error)) } else { self.read() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            }
        }
    }
    private func read() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.bytes.append(data) }
            if self.bytes.count > 8 * 1024 * 1024 { self.finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
            if let error { self.finish(.failure(error)) }
            else if complete { self.finish(.success(self.bytes)) }
            else { self.read() }
        }
    }
    private func finish(_ result: Swift.Result<Data, Error>) {
        guard !finished else { return }; finished = true
        let pending = continuation; continuation = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        pending?.resume(with: result)
    }
}
