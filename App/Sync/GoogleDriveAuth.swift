import AuthenticationServices
import CryptoKit
import Foundation

/// Google sign-in for Drive sync (design §1.4): OAuth 2.0 for installed apps with PKCE in
/// `ASWebAuthenticationSession`, no SDK. Only the refresh token is kept, in the keychain; access
/// tokens stay in memory. It is not the 반달 login: neither signs the other in or out. Turning
/// sync off forgets the token here without revoking it: a revoke ends the app's grant on the
/// account, which would sign out the user's other devices too.
enum GoogleDriveAuth {
    static let clientID = "565020221852-oc2noms2efphagpdldse4b8p7u9lls5e.apps.googleusercontent.com"
    static let scheme = "com.googleusercontent.apps.565020221852-oc2noms2efphagpdldse4b8p7u9lls5e"
    static let redirect = scheme + ":/oauth2redirect"
    static let scopes = "openid email https://www.googleapis.com/auth/drive.file"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// A connected Google account: `id` is the account's stable subject, `email` is shown in settings.
    struct Account: Codable, Equatable {
        let refresh: String, id: String, email: String
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let live: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DesktopRuntimeError("Google 응답을 확인하지 못했습니다.") }
        return (data, http)
    }

    static let signedOut = DesktopRuntimeError("Google에 다시 연결해 주세요.", code: "SYNC_DRIVE_SIGNED_OUT")

    /// Asks the user to sign in and allow Drive files; nil when they close the sheet. `hint`: the account to offer
    /// first (another device moved sync to that Drive, spec v2.7).
    @MainActor static func signIn(hint: String? = nil, transport: @escaping Transport = live) async throws -> Account? {
        let verifier = random(), state = random()
        let callback: URL
        do { callback = try await OAuthSession().open(authorization(challenge: challenge(verifier), state: state, hint: hint), callbackScheme: scheme) }
        catch {
            let closed = (error as NSError).domain == ASWebAuthenticationSessionError.errorDomain && (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
            if error is CancellationError || closed { return nil }
            throw error
        }
        return try await finish(callback, state: state, verifier: verifier, transport: transport)
    }

    static func authorization(challenge: String, state: String, hint: String? = nil) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                          .init(name: "scope", value: scopes), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                          .init(name: "state", value: state)] + (hint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        return url.url!
    }

    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    /// The redirect back from Google: the code it carries for the account, nil when the user said no.
    static func finish(_ callback: URL, state: String, verifier: String, transport: Transport) async throws -> Account? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { throw DesktopRuntimeError("Google 연결 응답이 이 요청과 맞지 않습니다.") }
        if item("error") == "access_denied" { return nil }
        guard let code = item("code") else { throw DesktopRuntimeError("Google 연결을 마치지 못했습니다.") }
        let token = try await post(["code": code, "client_id": clientID, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier], transport: transport)
        // The consent screen lets Drive be left unticked; without it nothing can sync.
        guard (token["scope"] as? String ?? "").split(separator: " ").contains("https://www.googleapis.com/auth/drive.file") else {
            throw DesktopRuntimeError("Google Drive 파일 접근을 허용해야 동기화할 수 있어요.", code: "SYNC_DRIVE_SCOPE")
        }
        guard let refresh = token["refresh_token"] as? String, let claims = (token["id_token"] as? String).flatMap(claims),
              let id = claims["sub"] as? String else { throw DesktopRuntimeError("Google 연결을 마치지 못했습니다. 다시 시도해 주세요.") }
        return Account(refresh: refresh, id: id, email: claims["email"] as? String ?? "")
    }

    /// A fresh access token for the account; `signedOut` once Google no longer honours it.
    static func accessToken(_ account: Account, transport: Transport) async throws -> (token: String, expires: Date) {
        let token = try await post(["client_id": clientID, "refresh_token": account.refresh, "grant_type": "refresh_token"], transport: transport)
        guard let access = token["access_token"] as? String else { throw signedOut }
        return (access, Date().addingTimeInterval(((token["expires_in"] as? NSNumber)?.doubleValue ?? 3600) - 60))
    }

    private static func post(_ fields: [String: String], transport: Transport) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await transport(request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if body["error"] as? String == "invalid_grant" { throw signedOut }
        guard response.statusCode == 200 else { throw DesktopRuntimeError("Google 인증 서버가 응답하지 않습니다 (\(response.statusCode)).") }
        return body
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    /// The id token comes straight from Google's token endpoint over TLS, so its claims are read, not verified.
    private static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func random() -> String { base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
