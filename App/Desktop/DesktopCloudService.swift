import Foundation

@MainActor
struct DesktopCloudEnvironment {
    var configuration: () -> (supabase: String, key: String, marketplace: String) = {
        (UserDefaults.standard.string(forKey: "sync.url") ?? "", UserDefaults.standard.string(forKey: "sync.publishableKey") ?? "", UserDefaults.standard.string(forKey: "marketplace.url") ?? "")
    }
    var signedIn: () async -> Bool
    var credential: () async throws -> (identity: DesktopSyncIdentity, token: String)
    var request: (URLRequest, Int64) async throws -> (URL, HTTPURLResponse) = DesktopDownloadTransport.request
}

/// The original marketplace clients use this private, restricted fetch seam.
/// Keychain tokens never cross into JavaScript. Download bodies stay on disk
/// and are read in bounded chunks by the original verification/import code.
@MainActor
final class DesktopCloudService {
    private struct Body { let url: URL; let handle: FileHandle; let expires: Date }
    private let environment: DesktopCloudEnvironment
    private var running: [String: Task<[String: Any], Error>] = [:]
    private var bodies: [String: Body] = [:]
    private var cancellations: [String: Date] = [:]
    init(environment: DesktopCloudEnvironment) { self.environment = environment }
    func canHandle(_ channel: String) -> Bool { ["native:cloudState", "native:cloudRequest", "native:cloudRead", "native:cloudCancel"].contains(channel) }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        prune()
        if channel == "native:cloudState" {
            let config = environment.configuration()
            let supabase: Any = Self.base(config.supabase) != nil && !config.key.isEmpty ? ["url": config.supabase.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "publishableKey": config.key] : NSNull()
            let signedIn = await environment.signedIn()
            let identity = signedIn ? try await environment.credential().identity : nil
            return ["supabase": supabase, "marketplaceURL": Self.base(config.marketplace)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as Any? ?? NSNull(), "signedIn": signedIn, "accountID": identity?.userID as Any? ?? NSNull()]
        }
        guard let id = (request["id"] ?? request["bodyID"]) as? String,
              id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw DesktopRuntimeError("클라우드 요청 ID를 확인해 주세요.") }
        if channel == "native:cloudCancel" {
            cancellations[id] = Date(); running[id]?.cancel(); close(id)
            return ["ok": true]
        }
        if channel == "native:cloudRead" {
            if cancellations[id] != nil { throw CancellationError() }
            guard let body = bodies[id] else { throw DesktopRuntimeError("클라우드 응답 읽기가 만료되었습니다.") }
            let data = try body.handle.read(upToCount: 512 * 1024) ?? Data()
            if data.isEmpty { close(id) }
            return ["data": data.base64EncodedString(), "done": data.isEmpty]
        }
        guard channel == "native:cloudRequest", cancellations[id] == nil else { throw CancellationError() }
        guard running[id] == nil, bodies[id] == nil, running.count + bodies.count < 12 else { throw DesktopRuntimeError("진행 중인 클라우드 요청이 끝난 뒤 다시 시도해 주세요.") }
        let task = Task { try await self.fetch(id: id, input: request) }
        running[id] = task
        defer { running.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func fetch(id: String, input: [String: Any]) async throws -> [String: Any] {
        let config = environment.configuration()
        guard let raw = input["url"] as? String, let url = URL(string: raw) else { throw DesktopRuntimeError("클라우드 주소를 확인해 주세요.") }
        let method = (input["method"] as? String ?? "GET").uppercased()
        let scope = try Self.scope(url: url, method: method, supabase: config.supabase, marketplace: config.marketplace)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(120, max(1, (input["timeoutMs"] as? Double ?? 120_000) / 1000))
        let headers = input["headers"] as? [String: String] ?? [:]
        let allowed = Set(["accept", "content-type", "tus-resumable", "x-signature", "upload-length", "upload-metadata", "upload-offset"])
        var authenticate = false
        for (name, value) in headers {
            let key = name.lowercased()
            guard name.count <= 128, value.count <= 16_384, name.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }), value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { throw DesktopRuntimeError("클라우드 요청 헤더를 확인해 주세요.") }
            if key == "authorization" {
                guard value == "Bearer native-keychain", scope != .storage else { throw DesktopRuntimeError("이 주소에 계정 인증 정보를 전달할 수 없습니다.") }
                authenticate = true
            } else if key == "apikey" {
                guard scope != .marketplace else { throw DesktopRuntimeError("클라우드 인증 구성을 확인해 주세요.") }
                request.setValue(config.key, forHTTPHeaderField: name)
            } else if allowed.contains(key) { request.setValue(value, forHTTPHeaderField: name) }
            else { throw DesktopRuntimeError("지원하지 않는 클라우드 요청 헤더입니다.") }
        }
        if let encoded = input["bodyBase64"] as? String {
            guard encoded.count <= 16 * 1024 * 1024, let data = Data(base64Encoded: encoded), data.count <= 12 * 1024 * 1024, ["POST", "PATCH"].contains(method) else { throw DesktopRuntimeError("클라우드 요청 크기를 확인해 주세요.") }
            request.httpBody = data
        }
        let identity: DesktopSyncIdentity?
        if authenticate || input["accountID"] is String {
            let current = try await environment.credential()
            if let expected = input["accountID"] as? String, current.identity.userID != expected { throw CancellationError() }
            identity = current.identity
            if authenticate { request.setValue("Bearer " + current.token, forHTTPHeaderField: "Authorization") }
        } else { identity = nil }
        try Task.checkCancellation()
        let maximum: Int64 = scope == .storage ? 50 * 1024 * 1024 : scope == .marketplace && url.path.hasSuffix("/review-bundle") ? 8 * 1024 * 1024 : 8 * 1024 * 1024
        let (file, response) = try await environment.request(request, maximum)
        do {
            try Task.checkCancellation()
            guard cancellations[id] == nil, response.url == url, environment.configuration().supabase == config.supabase,
                  environment.configuration().marketplace == config.marketplace else { throw CancellationError() }
            if let identity, try await environment.credential().identity != identity { throw CancellationError() }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= maximum, !(300..<400).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            var responseHeaders: [String: String] = [:]
            // Cookie and authentication headers never return through this seam.
            let permitted = Set(["content-type", "content-length", "location", "upload-offset", "tus-resumable", "retry-after", "etag"])
            for (name, value) in response.allHeaderFields {
                let key = String(describing: name).lowercased()
                if permitted.contains(key) { responseHeaders[key] = String(describing: value) }
            }
            bodies[id] = Body(url: file, handle: try FileHandle(forReadingFrom: file), expires: Date().addingTimeInterval(300))
            return ["status": response.statusCode, "headers": responseHeaders, "bodyID": id, "byteCount": size]
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    enum Scope { case supabase, storage, marketplace }
    static func base(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }
    static func scope(url: URL, method: String, supabase: String, marketplace: String) throws -> Scope {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil else { throw DesktopRuntimeError("허용되지 않은 클라우드 주소입니다.") }
        let sameOrigin: (URL) -> Bool = { url.scheme == $0.scheme && url.host?.lowercased() == $0.host?.lowercased() && (url.port ?? 443) == ($0.port ?? 443) }
        if let base = base(supabase) {
            if sameOrigin(base), ["/functions/v1/study-market", "/rest/v1/rpc/submit_feedback"].contains(url.path), method == "POST", url.query == nil { return .supabase }
            let host = base.host!.lowercased()
            let storageHost = host.hasSuffix(".supabase.co") ? String(host.dropLast(".supabase.co".count)) + ".storage.supabase.co" : host
            if (sameOrigin(base) || url.host?.lowercased() == storageHost && (url.port ?? 443) == (base.port ?? 443)), url.path.hasPrefix("/storage/v1/"), ["GET", "HEAD", "POST", "PATCH"].contains(method) { return .storage }
        }
        if let base = base(marketplace), sameOrigin(base), url.query == nil, ["GET", "POST"].contains(method),
           url.path.range(of: "^/(dashboard|publishers|releases(?:/[a-zA-Z0-9-]+(?:/(?:review|review-bundle))?)?|reports(?:/[a-zA-Z0-9-]+/resolve)?)$", options: .regularExpression) != nil { return .marketplace }
        throw DesktopRuntimeError("허용되지 않은 클라우드 요청입니다.")
    }
    private func close(_ id: String) {
        guard let body = bodies.removeValue(forKey: id) else { return }
        try? body.handle.close(); try? FileManager.default.removeItem(at: body.url)
    }
    private func prune() {
        let now = Date()
        for (id, body) in bodies where body.expires < now { close(id) }
        cancellations = cancellations.filter { now.timeIntervalSince($0.value) < 300 }
    }
    deinit {
        running.values.forEach { $0.cancel() }
        for body in bodies.values { try? body.handle.close(); try? FileManager.default.removeItem(at: body.url) }
    }
}
