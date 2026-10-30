import XCTest
import CryptoKit
@testable import Bandal

@MainActor
final class DesktopAccountTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() { guard ContinuousClock.now < limit else { throw URLError(.timedOut) }; await Task.yield() }
    }
    private func start(_ service: DesktopAccountService, fixture: DesktopAccountFixture) async throws {
        let request = Task { try await service.handle(channel: "auth:signIn", request: ["provider": "google"]) }
        try await waitUntil { fixture.didStart != nil }
        fixture.didStart?()
        let result = try await request.value as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
    }
    func testNativeAppleNonceNeverLeavesNativeAuthAndRegistersRevocationCode() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        var environment = fixture.environment, hashedNonce = ""
        environment.authorizeApple = { nonce in hashedNonce = nonce; return DesktopAppleCredential(identityToken: "signed-apple-id-token", authorizationCode: "one-time-code") }
        environment.request = { request in
            fixture.requests.append(request)
            let object: Any = request.url!.path == "/auth/v1/token" ? fixture.session(user: fixture.user) : request.url!.path.contains("/rest/") ? [] : ["ok": true]
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        let result = try await service.handle(channel: "auth:signIn", request: ["provider": "apple"]) as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
        let auth = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/auth/v1/token" })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(auth.httpBody)) as? [String: Any])
        let nonce = try XCTUnwrap(body["nonce"] as? String)
        XCTAssertEqual(SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined(), hashedNonce)
        XCTAssertEqual(body["id_token"] as? String, "signed-apple-id-token")
        let revocation = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/functions/v1/account-delete" })
        let registration = try JSONSerialization.jsonObject(with: XCTUnwrap(revocation.httpBody)) as? [String: Any]
        XCTAssertEqual(registration?["action"] as? String, "registerAppleAuthorization")
        XCTAssertEqual(registration?["authorizationCode"] as? String, "one-time-code")
        let state = try await service.handle(channel: "auth:getState", request: [:])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        XCTAssertFalse(text.contains(nonce)); XCTAssertFalse(text.contains("signed-apple-id-token")); XCTAssertFalse(text.contains("one-time-code"))
    }
    func testOAuthLinkIsAuthenticatedAndRejectsUnexpectedAccountWithoutClearingOriginalSession() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user)), as: UTF8.self)
        var environment = fixture.environment
        environment.request = { request in
            fixture.requests.append(request)
            let object: Any = request.url!.path == "/auth/v1/user/identities/authorize" ? ["url": "https://accounts.google.com/o/oauth2/auth"] : request.url!.path == "/auth/v1/token" ? fixture.session(user: "22222222-2222-4222-8222-222222222222") : []
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try await service.handle(channel: "auth:getState", request: [:])
        let original = fixture.credential
        let linking = Task { try await service.handle(channel: "auth:linkProvider", request: ["provider": "google"]) }
        try await waitUntil { fixture.didStart != nil }
        fixture.didStart?(); _ = try await linking.value
        let authorize = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/auth/v1/user/identities/authorize" })
        XCTAssertTrue(authorize.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertEqual(URLComponents(url: authorize.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "skip_http_redirect" }?.value, "true")
        fixture.completeOAuth()
        try await waitUntil { fixture.requests.contains { $0.url?.path == "/auth/v1/token" } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.credential, original)
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(original).utf8)) as? [String: Any])
        let token = try await service.accessToken()
        XCTAssertEqual(token, stored["access_token"] as? String, "The in-memory session must stay the original account")
    }
    func testUnconfiguredStateDoesNotOpenNetworkOrWriteCredentials() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.configuration = ("", "")
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "unconfigured")
        let result = try await service.handle(channel: "auth:signIn", request: ["provider": "google"]) as? [String: Any]
        XCTAssertEqual(result?["reason"] as? String, "not-configured")
        XCTAssertTrue(fixture.requests.isEmpty); XCTAssertTrue(fixture.writes.isEmpty); XCTAssertNil(fixture.oauthURL)
    }
    func testKakaoIsNoLongerASignInOrLinkProvider() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        for channel in ["auth:signIn", "auth:linkProvider"] {
            let result = try await service.handle(channel: channel, request: ["provider": "kakao"]) as? [String: Any]
            XCTAssertEqual(result?["ok"] as? Bool, false); XCTAssertEqual(result?["reason"] as? String, "provider")
        }
        XCTAssertNil(fixture.oauthURL); XCTAssertTrue(fixture.requests.isEmpty); XCTAssertTrue(fixture.writes.isEmpty)
    }
    func testSignInWaitsForActualBrowserStartAndIgnoresCallbackAfterSignOut() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        var returned = false
        let login = Task { let response = try await service.handle(channel: "auth:signIn", request: ["provider": "google"]); returned = true; return response }
        try await waitUntil { fixture.didStart != nil }
        XCTAssertFalse(returned)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(fixture.oauthURL), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value, "s256")
        XCTAssertNotNil(components.queryItems?.first(where: { $0.name == "code_challenge" })?.value)
        fixture.didStart?(); _ = try await login.value
        _ = try await service.handle(channel: "auth:signOut", request: [:])
        fixture.completeOAuth()
        for _ in 0..<20 { await Task.yield() }
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-out")
        XCTAssertNil(fixture.credential); XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-binding.json").path))
    }
    func testProfileProjectionAndNicknameUseDesktopContractWithoutBindingTheDataFolder() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        var events: [[String: Any]] = []
        service.emit = { channel, value in if channel == "auth:changed", let state = value as? [String: Any] { events.append(state) } }
        try await start(service, fixture: fixture)
        fixture.completeOAuth(); try await waitUntil { fixture.requests.count == 1 }
        fixture.reply(0, object: fixture.session(user: fixture.user, metadata: ["picture": "http://lh3.googleusercontent.com/photo.png"]))
        try await waitUntil { fixture.requests.count == 2 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [], "Signing in must not write into the data folder")
        XCTAssertNotNil(fixture.credential)
        fixture.reply(1, object: [["id": fixture.user, "nickname": "user_1234abcd", "avatar_color": "moon", "avatar_emoji": "🌙"]])
        try await waitUntil { events.last?["phase"] as? String == "signed-in" }
        let state = try XCTUnwrap(events.last)
        XCTAssertNil(state["localAccess"])
        XCTAssertTrue((state["profile"] as? [String: Any])?["nickname"] is NSNull)
        XCTAssertEqual(state["avatarUrl"] as? String, "https://lh3.googleusercontent.com/photo.png")
        let eventData = try JSONSerialization.data(withJSONObject: events)
        XCTAssertFalse(String(decoding: eventData, as: UTF8.self).contains("access_token"))
        XCTAssertFalse(String(decoding: eventData, as: UTF8.self).contains("refresh_token"))
        do { _ = try await service.handle(channel: "auth:setNickname", request: ["nickname": "bad name"]); XCTFail("Invalid nickname must be rejected locally") } catch { XCTAssertTrue(error.localizedDescription.contains("2~16")) }
        XCTAssertEqual(fixture.requests.count, 2)
        let nickname = Task { try await service.handle(channel: "auth:setNickname", request: ["nickname": " 반달학생 "]) }
        try await waitUntil { fixture.requests.count == 3 }
        XCTAssertEqual(fixture.requests[2].httpMethod, "PATCH")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(fixture.requests[2].httpBody)) as? [String: String]
        XCTAssertEqual(body?["nickname"], "반달학생")
        fixture.reply(2, status: 409, object: ["code": "23505"])
        do { _ = try await nickname.value; XCTFail("Duplicate nickname must fail") } catch { XCTAssertEqual(error.localizedDescription, "이미 쓰고 있는 이름이에요. 다른 이름으로 해볼까요?") }
    }
    func testConcurrentRestoreRefreshesOnceAndRejectsAnotherIssuer() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user, expires: Date().timeIntervalSince1970 - 60)), as: UTF8.self)
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        let first = Task { try await service.accessToken() }
        let second = Task { try await service.accessToken() }
        try await waitUntil { fixture.requests.count == 1 }
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(fixture.requests[0].url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "refresh_token")
        let next = fixture.session(user: fixture.user)
        fixture.reply(0, object: next)
        try await waitUntil { fixture.requests.count == 2 }
        fixture.reply(1, object: [])
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b); XCTAssertEqual(fixture.requests.count, 2); XCTAssertEqual(fixture.writes.count, 1)

        let other = try DesktopAccountFixture(); defer { other.close() }
        other.credential = String(decoding: try JSONSerialization.data(withJSONObject: other.session(user: other.user, issuer: "https://wrong.invalid/auth/v1")), as: UTF8.self)
        let wrong = DesktopAccountService(root: other.root, environment: other.environment)
        _ = try? await wrong.accessToken()
        let state = try await wrong.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-out")
        XCTAssertTrue(other.requests.isEmpty); XCTAssertTrue(other.writes.isEmpty)
    }
    /// auth.bandal.io is a custom domain: requests go there, but tokens keep the
    /// project's supabase.co issuer (measured from its OIDC discovery on 2026-10-30).
    func testCustomAuthDomainChecksTheConfiguredIssuerNotTheRequestHost() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.configuration = ("https://auth.custom.invalid", "fixture-public-key")
        fixture.issuer = "https://project.custom.invalid/auth/v1"
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user)), as: UTF8.self)
        var environment = fixture.environment
        environment.request = { request in
            fixture.requests.append(request)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try await service.accessToken()
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-in")
        XCTAssertEqual(fixture.requests.compactMap { $0.url?.host }, ["auth.custom.invalid"])

        let derived = try DesktopAccountFixture(); defer { derived.close() }
        derived.configuration = fixture.configuration; derived.issuer = fixture.issuer
        derived.credential = String(decoding: try JSONSerialization.data(withJSONObject: derived.session(user: derived.user, issuer: "https://auth.custom.invalid/auth/v1")), as: UTF8.self)
        let rejecting = DesktopAccountService(root: derived.root, environment: derived.environment)
        _ = try? await rejecting.accessToken()
        let rejected = try await rejecting.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(rejected?["phase"] as? String, "signed-out")
        XCTAssertTrue(derived.requests.isEmpty)
    }
    /// Builds before 2026-10-30 bound the data folder to the first account. Those
    /// files stay on disk untouched; they no longer block sign-in or restore.
    func testLegacyBindingFilesAndReceiptsNoLongerLockSignInOrRestore() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let otherUser = "22222222-2222-4222-8222-222222222222"
        let binding = try JSONSerialization.data(withJSONObject: ["version": 1, "userID": otherUser, "projectURL": fixture.configuration.url])
        let receipt = try JSONSerialization.data(withJSONObject: ["userID": otherUser, "projectURL": fixture.configuration.url, "allowed": false])
        try binding.write(to: fixture.root.appendingPathComponent("account-binding.json"))
        try receipt.write(to: fixture.root.appendingPathComponent("account-access.json"))
        let legacy = try DesktopSQLite(url: fixture.directory.appendingPathComponent("Bandal/bandal.sqlite"))
        try legacy.exec("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        _ = try legacy.run("INSERT INTO metadata(key,value) VALUES('sync_account',?)", params: [otherUser])

        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        var signedIn = false
        service.emit = { _, value in signedIn = (value as? [String: Any])?["phase"] as? String == "signed-in" }
        try await start(service, fixture: fixture)
        fixture.completeOAuth(); try await waitUntil { fixture.requests.count == 1 }
        fixture.reply(0, object: fixture.session(user: fixture.user))
        try await waitUntil { fixture.requests.count == 2 }
        fixture.reply(1, object: [])
        try await waitUntil { signedIn }
        XCTAssertNotNil(fixture.credential)

        var environment = fixture.environment
        environment.request = { request in (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let reopened = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try await reopened.accessToken()
        let state = try await reopened.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-in")
        XCTAssertNil(state?["localAccess"]); XCTAssertFalse(reopened.canHandle("auth:confirmProfile"))

        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("account-binding.json")), binding)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("account-access.json")), receipt)
        XCTAssertEqual(try legacy.query("SELECT value FROM metadata WHERE key='sync_account'", params: nil).first?["value"] as? String, otherUser)
    }
    func testExpiredOfflineSessionAsksForLoginAndSignsOutCleanly() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user, expires: Date().timeIntervalSince1970 - 60)), as: UTF8.self)
        var environment = fixture.environment
        environment.request = { _ in throw URLError(.notConnectedToInternet) }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try? await service.accessToken()
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-in")
        XCTAssertEqual(state?["errorCode"] as? String, "reauthentication-required")
        XCTAssertEqual(state?["online"] as? Bool, false)
        _ = try await service.handle(channel: "auth:signOut", request: [:])
        let after = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(after?["phase"] as? String, "signed-out"); XCTAssertNil(fixture.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-access.json").path))
    }
    /// A refusal (any HTTP error status) leaves the account intact, so the session stays.
    /// A dropped connection or an unreadable success reply may have deleted the account,
    /// so the session is signed out instead of being restored on the next launch.
    func testDeletionKeepsTheSessionWhenRefusedAndSignsOutWhenTheOutcomeIsUncertain() async throws {
        let pending: [String: Any] = ["error": "account_deletion_pending_transactions", "pendingTransactions": ["orders": [["count": 2]], "payouts": [["count": 1]], "cases": [["count": 3]], "unsettledBalance": -4500]]
        let cases: [(name: String, status: Int, body: Data?, keepsSession: Bool)] = [
            ("pending transactions", 409, try JSONSerialization.data(withJSONObject: pending), true),
            ("reauthentication", 401, try JSONSerialization.data(withJSONObject: ["error": "reauthentication_required"]), true),
            ("server error", 500, Data("{}".utf8), true),
            ("dropped connection", 0, nil, false),
            ("empty success body", 200, Data(), false),
            ("success without ok", 200, try JSONSerialization.data(withJSONObject: ["ok": false]), false),
        ]
        for scenario in cases {
            let fixture = try DesktopAccountFixture(); defer { fixture.close() }
            var environment = fixture.environment
            environment.authorizeApple = { _ in DesktopAppleCredential(identityToken: "fixture-identity", authorizationCode: nil) }
            environment.request = { request in
                guard request.url!.path == "/functions/v1/account-delete" else {
                    let body: Any = request.url!.path == "/auth/v1/token" ? fixture.session(user: fixture.user) : []
                    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                guard let body = scenario.body else { throw URLError(.networkConnectionLost) }
                return (body, HTTPURLResponse(url: request.url!, statusCode: scenario.status, httpVersion: nil, headerFields: nil)!)
            }
            let service = DesktopAccountService(root: fixture.root, environment: environment)
            _ = try await service.handle(channel: "auth:signIn", request: ["provider": "apple"])
            do { _ = try await service.deleteAccount(); XCTFail("\(scenario.name) must throw") }
            catch where scenario.name == "pending transactions" {
                XCTAssertTrue(error.localizedDescription.contains("거래 2건")); XCTAssertTrue(error.localizedDescription.contains("정산 1건"))
                XCTAssertTrue(error.localizedDescription.contains("처리 3건")); XCTAssertTrue(error.localizedDescription.contains("-4500원"))
            } catch { }
            let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
            XCTAssertEqual(state?["phase"] as? String, scenario.keepsSession ? "signed-in" : "signed-out", scenario.name)
            XCTAssertEqual(fixture.credential != nil, scenario.keepsSession, scenario.name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [], scenario.name)
        }
    }
}

@MainActor
private final class DesktopAccountFixture {
    let directory: URL
    let root: URL
    let user = "11111111-1111-4111-8111-111111111111"
    var configuration = (url: "https://account-fixture.invalid", key: "fixture-public-key")
    /// Nil keeps the default `<url>/auth/v1`; set explicitly so a simulator's stored defaults never leak in.
    var issuer: String?
    var credential: String?
    var writes: [String] = []
    var requests: [URLRequest] = []
    var oauthURL: URL?
    var didStart: (@MainActor () -> Void)?
    var oauth: CheckedContinuation<URL, Error>?
    var waiting: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopAccountTests-\(UUID().uuidString)")
        root = directory.appendingPathComponent("BandalDesktop")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var environment: DesktopAccountEnvironment {
        var environment = DesktopAccountEnvironment()
        environment.configuration = { self.configuration }
        environment.issuer = { self.issuer }
        environment.readCredential = { self.credential }
        environment.writeCredential = { value in self.writes.append(value); self.credential = value.isEmpty ? nil : value }
        environment.request = { request in
            let index = self.requests.count; self.requests.append(request)
            return try await withCheckedThrowingContinuation { self.waiting[index] = $0 }
        }
        environment.openOAuth = { url, started in
            self.oauthURL = url; self.didStart = started
            return try await withCheckedThrowingContinuation { self.oauth = $0 }
        }
        return environment
    }
    func completeOAuth() { let callback = oauth; oauth = nil; callback?.resume(returning: URL(string: "bandal://auth/callback?code=fixture-code")!) }
    func reply(_ index: Int, status: Int = 200, object: Any) {
        waiting.removeValue(forKey: index)?.resume(returning: (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!))
    }
    func session(user: String, expires: Double = Date().timeIntervalSince1970 + 3600, issuer: String? = nil, metadata: [String: String] = [:]) -> [String: Any] {
        func encode(_ value: Any) -> String { try! JSONSerialization.data(withJSONObject: value).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let token = encode(["alg": "fixture"]) + "." + encode(["sub": user, "iss": issuer ?? self.issuer ?? configuration.url + "/auth/v1", "exp": expires]) + ".fixture"
        return ["access_token": token, "refresh_token": "fixture-refresh", "expires_at": expires, "user": ["id": user, "email": "student@example.invalid", "user_metadata": metadata]]
    }
    func close() {
        oauth?.resume(throwing: CancellationError()); oauth = nil
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }; waiting = [:]
        try? FileManager.default.removeItem(at: directory)
    }
}
