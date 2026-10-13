import Foundation
import AuthenticationServices
import CryptoKit
import Security
import Darwin

/// Authentication effects are injected in tests; no fixture touches Keychain,
/// a real provider account, or the user's existing database.
@MainActor
struct DesktopAccountEnvironment {
    var configuration: () -> (url: String, key: String) = {
        (UserDefaults.standard.string(forKey: "sync.url") ?? "", UserDefaults.standard.string(forKey: "sync.publishableKey") ?? "")
    }
    var readCredential: () -> String? = { KeychainStore.read("sync.session") }
    var writeCredential: (String) throws -> Void = { try KeychainStore.write($0, account: "sync.session") }
    var request: (URLRequest) async throws -> (Data, URLResponse) = { request in
        let session = URLSession(configuration: .ephemeral, delegate: DesktopAccountRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
    var openOAuth: ((URL, @escaping @MainActor () -> Void) async throws -> URL)?
}

private final class DesktopAccountRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Implements the desktop auth contract. Tokens never enter renderer responses
/// or auth:changed events; sync.session remains the existing Keychain format.
@MainActor
final class DesktopAccountService {
    var emit: ((String, Any) -> Void)?
    private let root: URL
    private let environment: DesktopAccountEnvironment
    private var session: CloudSession?
    private var metadata: [String: Any] = [:]
    private var phase = "signed-out"
    private var profile: [String: Any]?
    private var avatarURL: String?
    private var online = false
    private var errorCode: String?
    private var generation = 0
    private var restored = false
    private var restoring: Task<Void, Never>?
    private var login: Task<Void, Never>?
    private var browser: OAuthSession?
    private var refreshing: (id: UUID, generation: Int, task: Task<String, Error>)?
    private var nicknameOperation: UUID?
    private struct Context { let generation: Int; let url: String; let key: String }
    private struct Binding: Codable { let version: Int; let userID: String; let projectURL: String }

    init(root: URL, environment: DesktopAccountEnvironment? = nil) {
        self.root = root; self.environment = environment ?? DesktopAccountEnvironment()
        if configuredURL() == nil { phase = "unconfigured" }
    }
    func canHandle(_ channel: String) -> Bool { ["auth:getState", "auth:signIn", "auth:signOut", "auth:setNickname"].contains(channel) }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "auth:getState": await restore(); return state
        case "auth:signIn": return await signIn(provider: request["provider"] as? String ?? "")
        case "auth:signOut": try await signOut(); return ["ok": true]
        case "auth:setNickname": return try await setNickname(request["nickname"] as? String ?? "")
        default: throw DesktopRuntimeError("Unknown account operation")
        }
    }
    private var state: [String: Any] {
        ["phase": phase, "profile": profile ?? NSNull() as Any, "email": session?.user.email ?? NSNull() as Any,
         "avatarUrl": avatarURL ?? NSNull() as Any, "online": online, "errorCode": errorCode ?? NSNull() as Any]
    }
    private func publish() { emit?("auth:changed", state) }
    private func context() -> Context {
        let value = environment.configuration()
        return Context(generation: generation, url: value.url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")), key: value.key)
    }
    private func validate(_ expected: Context) throws {
        try Task.checkCancellation()
        guard matches(expected) else { throw CancellationError() }
    }
    private func matches(_ expected: Context) -> Bool {
        let current = context()
        return expected.generation == current.generation && expected.url == current.url && expected.key == current.key
    }
    private func configuredURL() -> URL? {
        let value = context()
        guard let url = URL(string: value.url), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !value.key.isEmpty else { return nil }
        return url
    }
    private func reset(error: String? = nil) {
        session = nil; profile = nil; metadata = [:]; avatarURL = nil; online = false
        phase = configuredURL() == nil ? "unconfigured" : "signed-out"; errorCode = error
    }
    private func restore() async {
        if let restoring { await restoring.value; return }
        guard !restored else { return }
        restored = true
        let expected = context()
        let task = Task { [weak self] in
            guard let self, self.configuredURL() != nil, let raw = self.environment.readCredential(), !raw.isEmpty else { return }
            do {
                let restored = try self.decodeSession(Data(raw.utf8), context: expected)
                try self.checkBinding(restored.value.user.id, context: expected)
                self.session = restored.value; self.metadata = restored.metadata
                _ = try await self.currentToken(context: expected)
                try self.validate(expected)
                if let session = self.session { try self.bind(session.user.id, context: expected) }
                await self.loadProfile(context: expected)
            } catch {
                guard self.generation == expected.generation else { return }
                self.reset(); self.publish()
            }
        }
        restoring = task; await task.value
        if generation == expected.generation { restoring = nil }
    }
    private func signIn(provider: String) async -> [String: Any] {
        guard configuredURL() != nil else { reset(); publish(); return ["ok": false, "reason": "not-configured"] }
        guard ["google", "kakao"].contains(provider) else { return ["ok": false, "reason": "provider"] }
        await restore()
        guard session == nil else { return ["ok": false, "reason": "already-signed-in"] }
        guard login == nil else { return ["ok": false, "reason": "provider"] }
        generation += 1
        let expected = context()
        let verifier: String
        do { verifier = try Self.verifier() } catch { return ["ok": false, "reason": "provider"] }
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var authorize = URLComponents(string: expected.url) else { return ["ok": false, "reason": "not-configured"] }
        authorize.path = "/auth/v1/authorize"
        authorize.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "redirect_to", value: "bandal://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
        guard let url = authorize.url else { return ["ok": false, "reason": "provider"] }
        phase = "signing-in"; errorCode = nil; publish()
        return await withCheckedContinuation { started in
            var answered = false
            let didStart: @MainActor () -> Void = { [weak self] in
                guard !answered else { return }; answered = true
                started.resume(returning: self?.matches(expected) == true ? ["ok": true] : ["ok": false, "reason": "provider"])
            }
            login = Task { [weak self] in
                guard let self else { if !answered { answered = true; started.resume(returning: ["ok": false, "reason": "network"]) }; return }
                defer { if self.generation == expected.generation { self.login = nil; self.browser = nil } }
                do {
                    let callback: URL
                    if let open = self.environment.openOAuth { callback = try await open(url, didStart) }
                    else { let browser = OAuthSession(); self.browser = browser; callback = try await browser.open(url, onStarted: didStart) }
                    try self.validate(expected)
                    let code = try Self.callbackCode(callback)
                    let data = try await self.request(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "pkce")], method: "POST", body: ["auth_code": code, "code_verifier": verifier], context: expected)
                    let result = try self.decodeSession(data, context: expected)
                    try self.bind(result.value.user.id, context: expected)
                    try self.save(result.value, metadata: result.metadata, context: expected)
                    await self.loadProfile(context: expected)
                } catch {
                    if !answered { answered = true; started.resume(returning: ["ok": false, "reason": "network"]) }
                    guard self.matches(expected) else { return }
                    let cancelled = error is CancellationError || (error as NSError).domain == ASWebAuthenticationSessionError.errorDomain && (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    self.reset(error: cancelled ? "oauth-cancelled" : "provider")
                    if !cancelled { self.phase = "error" }
                    self.publish()
                }
            }
        }
    }
    private func signOut() async throws {
        let old = session, expected = context()
        generation += 1; restored = true
        login?.cancel(); login = nil; browser?.cancel(); browser = nil
        restoring?.cancel(); restoring = nil; refreshing?.task.cancel(); refreshing = nil; nicknameOperation = nil
        reset(); publish()
        // Do not claim success if the local credential could not be removed.
        try environment.writeCredential("")
        guard let token = old?.access_token else { return }
        // Remote invalidation is best effort and never mutates local state after
        // suspension; a new login may already be active when it finishes.
        guard let url = URL(string: expected.url + "/auth/v1/logout?scope=local") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue(expected.key, forHTTPHeaderField: "apikey"); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        _ = try? await environment.request(request)
    }
    func accessToken() async throws -> String { await restore(); return try await currentToken(context: context()) }
    /// Native sync identity; never included in the renderer's account state.
    func syncIdentity() async throws -> DesktopSyncIdentity {
        _ = try await accessToken()
        let expected = context()
        guard let session, let url = configuredURL() else { throw DesktopRuntimeError("계정 로그인이 필요합니다.") }
        try validate(expected)
        return DesktopSyncIdentity(userID: session.user.id.lowercased(), projectURL: url, publishableKey: expected.key)
    }
    private func currentToken(context expected: Context) async throws -> String {
        try validate(expected)
        guard let value = session else { throw DesktopRuntimeError("계정 로그인이 필요합니다.") }
        try checkBinding(value.user.id, context: expected)
        if (value.expires_at ?? 0) > Date().timeIntervalSince1970 + 90 { return value.access_token }
        if let refreshing, refreshing.generation == expected.generation {
            let token = try await refreshing.task.value; try validate(expected); return token
        }
        let identifier = UUID()
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let data = try await self.request(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], method: "POST", body: ["refresh_token": value.refresh_token], context: expected)
            let result = try self.decodeSession(data, context: expected)
            guard result.value.user.id.lowercased() == value.user.id.lowercased() else { throw DesktopRuntimeError("로그인 계정이 변경되어 다시 연결해야 합니다.") }
            try self.checkBinding(result.value.user.id, context: expected)
            try self.save(result.value, metadata: result.metadata, context: expected)
            return result.value.access_token
        }
        refreshing = (identifier, expected.generation, task)
        defer { if refreshing?.id == identifier { refreshing = nil } }
        let token = try await task.value; try validate(expected); return token
    }
    private func loadProfile(context expected: Context) async {
        guard let value = session else { return }
        do {
            let token = try await currentToken(context: expected)
            let data = try await request(path: "/rest/v1/profiles", query: [URLQueryItem(name: "select", value: "id,nickname,avatar_color,avatar_emoji"), URLQueryItem(name: "id", value: "eq." + value.user.id)], method: "GET", token: token, context: expected)
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            try validate(expected)
            profile = Self.profile(rows.first, userID: value.user.id); online = true
        } catch {
            guard matches(expected), !Task.isCancelled else { return }
            profile = Self.profile(nil, userID: value.user.id); online = false
        }
        guard matches(expected), !Task.isCancelled else { return }
        avatarURL = Self.avatar(metadata); phase = "signed-in"; errorCode = nil; publish()
    }
    private func setNickname(_ nickname: String) async throws -> [String: Any] {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[가-힣a-zA-Z0-9_]{2,16}$", options: .regularExpression) != nil else { throw DesktopRuntimeError("닉네임은 한글·영문·숫자·밑줄 2~16자여야 해요.") }
        await restore()
        guard nicknameOperation == nil, let user = session?.user.id else { throw DesktopRuntimeError("로그인 상태와 진행 중인 작업을 확인해 주세요.") }
        let operation = UUID(); nicknameOperation = operation
        defer { if nicknameOperation == operation { nicknameOperation = nil } }
        let expected = context(), token = try await currentToken(context: context())
        let data = try await request(path: "/rest/v1/profiles", query: [URLQueryItem(name: "id", value: "eq." + user), URLQueryItem(name: "select", value: "id,nickname,avatar_color,avatar_emoji")], method: "PATCH", body: ["nickname": trimmed], token: token, context: expected)
        guard let row = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first, (row["id"] as? String)?.lowercased() == user.lowercased() else { throw DesktopRuntimeError("프로필 변경 결과를 확인하지 못했습니다.") }
        try validate(expected)
        let result = Self.profile(row, userID: user); profile = result; online = true; publish(); return result
    }
    private func request(path: String, query: [URLQueryItem] = [], method: String, body: [String: Any]? = nil, token: String? = nil, context expected: Context) async throws -> Data {
        try validate(expected)
        guard configuredURL() != nil, var components = URLComponents(string: expected.url) else { throw DesktopRuntimeError("계정 서버가 설정되지 않았습니다.") }
        components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw DesktopRuntimeError("계정 서버 주소를 확인해 주세요.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30; request.httpShouldHandleCookies = false
        request.setValue(expected.key, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if method == "PATCH" { request.setValue("return=representation", forHTTPHeaderField: "Prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await environment.request(request)
        try validate(expected)
        guard data.count <= 2 * 1024 * 1024, let http = response as? HTTPURLResponse else { throw DesktopRuntimeError("계정 서버 응답을 확인할 수 없습니다.") }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            if code == "23505" { throw DesktopRuntimeError("이미 쓰고 있는 이름이에요. 다른 이름으로 해볼까요?") }
            if code == "23514" { throw DesktopRuntimeError("닉네임은 한글·영문·숫자·밑줄 2~16자여야 해요.") }
            throw DesktopRuntimeError("계정 요청을 완료하지 못했습니다 (\(http.statusCode)).")
        }
        return data
    }
    private func decodeSession(_ data: Data, context: Context) throws -> (value: CloudSession, metadata: [String: Any]) {
        var value = try JSONDecoder().decode(CloudSession.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard UUID(uuidString: value.user.id) != nil, !value.refresh_token.isEmpty,
              let claims = Self.jwtClaims(value.access_token), (claims["sub"] as? String)?.lowercased() == value.user.id.lowercased(),
              claims["iss"] as? String == context.url + "/auth/v1" else { throw DesktopRuntimeError("계정 토큰의 서버와 사용자를 확인하지 못했습니다.") }
        if value.expires_at == nil { value.expires_at = claims["exp"] as? Double ?? (object?["expires_in"] as? Double).map { Date().timeIntervalSince1970 + $0 } }
        return (value, (object?["user"] as? [String: Any])?["user_metadata"] as? [String: Any] ?? [:])
    }
    private func save(_ value: CloudSession, metadata: [String: Any], context expected: Context) throws {
        try validate(expected)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        var user = object["user"] as! [String: Any]; user["user_metadata"] = metadata; object["user"] = user
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try environment.writeCredential(String(decoding: data, as: UTF8.self)); session = value; self.metadata = metadata
    }
    private func checkBinding(_ user: String, context expected: Context) throws {
        let file = root.appendingPathComponent("account-binding.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: file))
            guard binding.version == 1, binding.userID.lowercased() == user.lowercased(), binding.projectURL == expected.url else { throw DesktopRuntimeError("이 기기의 자료는 다른 계정에 연결되어 있습니다. 기존 계정으로 로그인해 주세요.") }
        }
        let legacyName = root.lastPathComponent == "BandalDesktop-UI-Tests" ? "Bandal-UI-Tests" : "Bandal"
        let legacy = root.deletingLastPathComponent().appendingPathComponent(legacyName).appendingPathComponent("bandal.sqlite")
        if FileManager.default.fileExists(atPath: legacy.path) {
            let database = try DesktopSQLite(url: legacy, readOnly: true)
            let bound = try database.query("SELECT value FROM metadata WHERE key='sync_account'", params: nil).first?["value"] as? String
            guard bound == nil || bound?.lowercased() == user.lowercased() else { throw DesktopRuntimeError("이전 반달 자료가 다른 계정에 연결되어 있습니다. 기존 계정으로 로그인해 주세요.") }
        }
    }
    private func bind(_ user: String, context expected: Context) throws {
        try validate(expected); try checkBinding(user, context: expected)
        let target = root.appendingPathComponent("account-binding.json")
        if FileManager.default.fileExists(atPath: target.path) { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(".account-binding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(Binding(version: 1, userID: user, projectURL: expected.url))
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: temporary, to: target)
        let directory = Darwin.open(root.path, O_RDONLY)
        guard directory >= 0 else { throw DesktopRuntimeError("계정 연결을 안전하게 저장하지 못했습니다.") }
        defer { Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else { throw DesktopRuntimeError("계정 연결 저장을 확인하지 못했습니다.") }
    }
    private static func profile(_ row: [String: Any]?, userID: String) -> [String: Any] {
        let name = row?["nickname"] as? String
        let nickname = name.flatMap { $0.range(of: "^user_[0-9a-f]{8}$", options: .regularExpression) == nil ? $0 : nil }
        return ["id": userID, "nickname": nickname ?? NSNull() as Any, "avatarColor": row?["avatar_color"] as? String ?? "moon", "avatarEmoji": row?["avatar_emoji"] as? String ?? "🌙"]
    }
    private static func avatar(_ metadata: [String: Any]) -> String? {
        for key in ["avatar_url", "picture", "profile_image"] {
            guard let raw = metadata[key] as? String, var url = URLComponents(string: raw), let host = url.host?.lowercased(),
                  ["googleusercontent.com", "kakaocdn.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443, ["http", "https"].contains(url.scheme ?? "") else { continue }
            url.scheme = "https"; return url.url?.absoluteString
        }
        return nil
    }
    private static func callbackCode(_ url: URL) throws -> String {
        guard url.scheme?.lowercased() == "bandal", url.host?.lowercased() == "auth", url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "callback", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DesktopRuntimeError("로그인 반환 주소를 확인할 수 없습니다.") }
        if components.queryItems?.contains(where: { $0.name == "error" && $0.value == "access_denied" }) == true { throw CancellationError() }
        guard components.queryItems?.contains(where: { $0.name == "error" }) != true else { throw DesktopRuntimeError("로그인 서비스가 요청을 완료하지 못했습니다.") }
        let codes = Set(components.queryItems?.filter { $0.name == "code" }.compactMap(\.value) ?? [])
        guard codes.count == 1, let code = codes.first, code.range(of: "^[A-Za-z0-9._~+/=-]{1,2048}$", options: .regularExpression) != nil else { throw DesktopRuntimeError("로그인 코드를 확인할 수 없습니다.") }
        return code
    }
    private static func verifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DesktopRuntimeError("안전한 로그인 요청을 만들지 못했습니다.") }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
