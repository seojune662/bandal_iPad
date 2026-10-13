import Foundation
import CryptoKit
import Security

@MainActor
struct DesktopMailEnvironment {
    var configuration: () -> (clientID: String, callbackScheme: String, verified: Bool) = {
        let client = UserDefaults.standard.string(forKey: "gmail.clientID") ?? ""
        let scheme = client.components(separatedBy: ".").reversed().joined(separator: ".")
        let declared = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return (declared.contains(scheme) ? client : "", scheme, UserDefaults.standard.string(forKey: "gmail.verified") == "true")
    }
    var read: (String) -> String? = { KeychainStore.read("gmail.session." + $0) }
    var write: (String, String) throws -> Void = { try KeychainStore.write($1, account: "gmail.session." + $0) }
    var request: (URLRequest) async throws -> (Data, URLResponse) = { request in
        let session = URLSession(configuration: .ephemeral, delegate: DesktopMailRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
    var open: ((URL, String) async throws -> URL)?
}
private final class DesktopMailRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Native OAuth and Keychain storage, behind the original desktop mail model.
/// Gmail credentials are separate from the Bandal account and never sync.
@MainActor
final class DesktopMailService {
    private struct Session: Codable {
        let accessToken: String; let refreshToken: String; let expiresAt: Double; let email: String
    }
    private let environment: DesktopMailEnvironment
    private var credential: Session?
    private var loadedClient: String?
    private var generation = 0
    private var needsAuth = false
    private var connecting: Task<[String: Any], Error>?
    private var refresh: (id: UUID, task: Task<String, Error>)?
    private var browser: OAuthSession?
    private let scope = "https://www.googleapis.com/auth/gmail.modify"
    init(environment: DesktopMailEnvironment? = nil) { self.environment = environment ?? DesktopMailEnvironment() }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("native:mail") }

    func handle(channel: String, request: [String: Any]) async throws -> Any {
        load()
        switch channel {
        case "native:mailState": return state()
        case "native:mailConnect": return try await connect()
        case "native:mailCancel": cancel(); return ["ok": true]
        case "native:mailDisconnect": try await disconnect(); return ["ok": true]
        case "native:mailAPI":
            guard let path = request["path"] as? String,
                  let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
                  parts.path.range(of: "^/messages(?:/[a-zA-Z0-9_-]{1,200}(?:/modify)?)?$", options: .regularExpression) != nil,
                  ["GET", "POST"].contains(request["method"] as? String ?? "GET") else { throw DesktopRuntimeError("메일 요청 경로를 확인해 주세요.") }
            let method = request["method"] as? String ?? "GET"
            guard method == "GET" && !parts.path.hasSuffix("/modify") && parts.path != "/messages/send" || method == "POST" && (parts.path.hasSuffix("/modify") || parts.path == "/messages/send") else { throw DesktopRuntimeError("메일 요청을 확인해 주세요.") }
            return try await api(path: path, method: method, body: request["body"] as? [String: Any])
        default: throw DesktopRuntimeError("Unknown mail service", code: "ENOSYS")
        }
    }
    private func load() {
        let client = environment.configuration().clientID
        guard loadedClient != client else { return }
        cancel(); credential = nil; needsAuth = false; loadedClient = client
        guard !client.isEmpty else { return }
        if let raw = environment.read(client), let value = try? JSONDecoder().decode(Session.self, from: Data(raw.utf8)), !value.accessToken.isEmpty, !value.refreshToken.isEmpty, !value.email.isEmpty { credential = value }
    }
    private func state() -> [String: Any] {
        let config = environment.configuration()
        return ["status": config.clientID.isEmpty ? "unconfigured" : connecting != nil ? "connecting" : needsAuth ? "reauth-required" : credential == nil ? "disconnected" : "connected", "email": credential?.email as Any? ?? NSNull(), "experimental": !config.verified]
    }
    private func check(_ expected: Int, client: String) throws {
        try Task.checkCancellation()
        guard generation == expected, environment.configuration().clientID == client else { throw CancellationError() }
    }
    private func cancel() {
        generation += 1; connecting?.cancel(); connecting = nil; refresh?.task.cancel(); refresh = nil; browser?.cancel(); browser = nil
    }
    private func save(_ value: Session, expected: Int, client: String) throws {
        try check(expected, client: client)
        try environment.write(client, String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        credential = value
    }
    private func connect() async throws -> [String: Any] {
        if let connecting { return try await connecting.value }
        let config = environment.configuration()
        guard config.clientID.hasSuffix(".apps.googleusercontent.com"), config.callbackScheme.hasPrefix("com.googleusercontent.apps.") else {
            throw DesktopRuntimeError("이 빌드에는 iPad용 Google 메일 연결 설정이 아직 없어요.")
        }
        generation += 1
        let expected = generation
        let task = Task<[String: Any], Error> {
            let verifier = try Self.random(), nonce = try Self.random()
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let redirect = config.callbackScheme + ":/oauth2redirect"
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = ["client_id": config.clientID, "redirect_uri": redirect, "response_type": "code", "scope": self.scope, "state": nonce,
                                     "code_challenge": challenge, "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
            let callback: URL
            if let open = self.environment.open { callback = try await open(components.url!, config.callbackScheme) }
            else { let browser = OAuthSession(); self.browser = browser; callback = try await browser.open(components.url!, callbackScheme: config.callbackScheme) }
            try self.check(expected, client: config.clientID)
            guard callback.scheme == config.callbackScheme, callback.host == nil, callback.path == "/oauth2redirect",
                  let result = URLComponents(url: callback, resolvingAgainstBaseURL: false), result.queryItems?.filter({ $0.name == "state" }).count == 1,
                  result.queryItems?.first(where: { $0.name == "state" })?.value == nonce,
                  !((result.queryItems ?? []).contains { $0.name == "error" }),
                  let code = result.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw DesktopRuntimeError("Google 메일 연결이 취소되었어요.") }
            let tokens = try await self.exchange(["client_id": config.clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"], expected: expected, client: config.clientID)
            guard let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
                  (tokens["scope"] as? String).map({ $0.split(separator: " ").contains(Substring(self.scope)) }) ?? true else { throw DesktopRuntimeError("메일 읽기·관리 권한을 허용해 주세요.") }
            let profile = try await self.http(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!, method: "GET", token: access)
            try self.check(expected, client: config.clientID)
            guard let email = profile["emailAddress"] as? String, !email.isEmpty else { throw DesktopRuntimeError("메일 계정을 확인하지 못했어요.") }
            try self.save(Session(accessToken: access, refreshToken: refresh, expiresAt: Date().timeIntervalSince1970 + (tokens["expires_in"] as? Double ?? 3600), email: email), expected: expected, client: config.clientID)
            self.needsAuth = false
            return ["status": "connected", "email": email, "experimental": !config.verified]
        }
        connecting = task
        defer { if expected == generation { connecting = nil; browser = nil } }
        return try await task.value
    }
    private func disconnect() async throws {
        let client = environment.configuration().clientID, old = credential
        cancel()
        // Retain visible state if secure deletion fails, allowing a retry.
        try environment.write(client, "")
        credential = nil; needsAuth = false
        if let old { _ = try? await http(url: URL(string: "https://oauth2.googleapis.com/revoke")!, method: "POST", form: ["token": old.refreshToken]) }
    }
    private func token(expected: Int, client: String) async throws -> String {
        try check(expected, client: client)
        guard let credential, !needsAuth else { throw DesktopRuntimeError("Google 메일을 연결해 주세요.") }
        if credential.expiresAt > Date().timeIntervalSince1970 + 60 { return credential.accessToken }
        if let refresh { let result = try await refresh.task.value; try check(expected, client: client); return result }
        let id = UUID()
        let task = Task<String, Error> {
            let tokens = try await self.exchange(["client_id": client, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"], expected: expected, client: client)
            let access = tokens["access_token"] as! String
            try self.save(Session(accessToken: access, refreshToken: credential.refreshToken, expiresAt: Date().timeIntervalSince1970 + (tokens["expires_in"] as? Double ?? 3600), email: credential.email), expected: expected, client: client)
            return access
        }
        refresh = (id, task); defer { if refresh?.id == id { refresh = nil } }
        return try await task.value
    }
    private func exchange(_ form: [String: String], expected: Int, client: String) async throws -> [String: Any] {
        do {
            let value = try await http(url: URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: form)
            try check(expected, client: client)
            guard let token = value["access_token"] as? String, !token.isEmpty else { throw DesktopRuntimeError("Google 메일 인증을 완료하지 못했어요.") }
            return value
        } catch {
            try check(expected, client: client)
            if (error as? DesktopRuntimeError)?.code == "invalid_grant" { needsAuth = true }
            throw error
        }
    }
    private func api(path: String, method: String, body: [String: Any]?, retry: Bool = true) async throws -> [String: Any] {
        let expected = generation, client = environment.configuration().clientID
        let token = try await token(expected: expected, client: client)
        try check(expected, client: client)
        do {
            let value = try await http(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me" + path)!, method: method, token: token, json: body)
            try check(expected, client: client); return value
        } catch {
            try check(expected, client: client)
            if (error as? DesktopRuntimeError)?.code == "HTTP_401" {
                if retry, let old = credential {
                    credential = Session(accessToken: old.accessToken, refreshToken: old.refreshToken, expiresAt: 0, email: old.email)
                    return try await api(path: path, method: method, body: body, retry: false)
                }
                needsAuth = true
            }
            throw error
        }
    }
    private func http(url: URL, method: String, token: String? = nil, json: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30; request.httpShouldHandleCookies = false
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let form {
            var components = URLComponents(); components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await environment.request(request)
        guard let http = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else { throw DesktopRuntimeError("메일 서버 응답을 확인하지 못했어요.") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if object["error"] as? String == "invalid_grant" { throw DesktopRuntimeError("메일 연결이 만료되었어요. 다시 연결해 주세요.", code: "invalid_grant") }
            let message = http.statusCode == 401 ? "메일을 다시 연결해 주세요." : http.statusCode == 403 ? "메일 접근 권한이나 학교 계정 정책을 확인해 주세요." : http.statusCode == 429 ? "요청이 많아요. 잠시 후 다시 시도해 주세요." : "메일 요청을 완료하지 못했어요. 다시 시도해 주세요."
            throw DesktopRuntimeError(message, code: "HTTP_\(http.statusCode)")
        }
        return object
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DesktopRuntimeError("안전한 로그인 요청을 만들지 못했어요.") }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ value: Data) -> String { value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
