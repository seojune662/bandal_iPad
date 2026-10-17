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
        XCTAssertEqual(fixture.credential, original); XCTAssertTrue(service.localAccessAllowed)
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
    func testProfileProjectionBindingAndNicknameUseDesktopContract() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        var events: [[String: Any]] = []
        service.emit = { channel, value in if channel == "auth:changed", let state = value as? [String: Any] { events.append(state) } }
        try await start(service, fixture: fixture)
        fixture.completeOAuth(); try await waitUntil { fixture.requests.count == 1 }
        fixture.reply(0, object: fixture.session(user: fixture.user, metadata: ["picture": "http://example.kakaocdn.net/photo.png"]))
        try await waitUntil { fixture.requests.count == 2 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-binding.json").path))
        XCTAssertNotNil(fixture.credential)
        fixture.reply(1, object: [["id": fixture.user, "nickname": "user_1234abcd", "avatar_color": "moon", "avatar_emoji": "🌙"]])
        try await waitUntil { events.last?["phase"] as? String == "signed-in" }
        let state = try XCTUnwrap(events.last)
        XCTAssertTrue((state["profile"] as? [String: Any])?["nickname"] is NSNull)
        XCTAssertEqual(state["avatarUrl"] as? String, "https://example.kakaocdn.net/photo.png")
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
        let state = try await wrong.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertEqual(state?["phase"] as? String, "signed-out")
        XCTAssertTrue(other.requests.isEmpty); XCTAssertTrue(other.writes.isEmpty)
    }
    func testLegacyAccountBindingBlocksNewAccountWithoutChangingLegacyDatabase() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let legacyURL = fixture.directory.appendingPathComponent("Bandal/bandal.sqlite")
        let legacy = try DesktopSQLite(url: legacyURL)
        try legacy.exec("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        _ = try legacy.run("INSERT INTO metadata(key,value) VALUES('sync_account',?)", params: ["22222222-2222-4222-8222-222222222222"])
        let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
        var failed = false
        service.emit = { _, value in failed = (value as? [String: Any])?["phase"] as? String == "error" }
        try await start(service, fixture: fixture)
        fixture.completeOAuth(); try await waitUntil { fixture.requests.count == 1 }
        fixture.reply(0, object: fixture.session(user: fixture.user))
        try await waitUntil { failed }
        XCTAssertNil(fixture.credential); XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-binding.json").path))
        XCTAssertEqual(try legacy.query("SELECT value FROM metadata WHERE key='sync_account'", params: nil).first?["value"] as? String, "22222222-2222-4222-8222-222222222222")
    }
    func testExpiredOfflineSessionKeepsPreviouslyAuthorizedLocalAccess() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user, expires: Date().timeIntervalSince1970 - 60)), as: UTF8.self)
        var environment = fixture.environment
        environment.request = { _ in throw URLError(.notConnectedToInternet) }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertTrue((state?["localAccess"] as? [String: Any])?["allowed"] as? Bool == true)
        XCTAssertEqual(state?["online"] as? Bool, false)
        let reopened = DesktopAccountService(root: fixture.root, environment: environment)
        XCTAssertTrue(reopened.localAccessAllowed)
        _ = try await reopened.handle(channel: "auth:signOut", request: [:])
        XCTAssertFalse(reopened.localAccessAllowed)
        XCTAssertFalse(DesktopAccountService(root: fixture.root, environment: environment).localAccessAllowed)
    }
    func testExistingContentRequiresExplicitOwnershipConfirmation() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let db = try DesktopSQLite(url: fixture.root.appendingPathComponent("bandal.db"))
        try db.exec("CREATE TABLE courses(id TEXT PRIMARY KEY); INSERT INTO courses VALUES('existing-course')")
        fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user)), as: UTF8.self)
        var environment = fixture.environment
        environment.request = { request in (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        let state = try await service.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        XCTAssertFalse(service.localAccessAllowed)
        XCTAssertTrue((state?["localAccess"] as? [String: Any])?["requiresBindingConfirmation"] as? Bool == true)
        do { _ = try await service.handle(channel: "auth:confirmProfile", request: ["userID": "other-account"]); XCTFail("Wrong identity") } catch { }
        _ = try await service.handle(channel: "auth:confirmProfile", request: ["userID": fixture.user])
        XCTAssertTrue(service.localAccessAllowed)
        XCTAssertEqual(try db.query("SELECT id FROM courses", params: nil).count, 1)
    }

    func testCorruptReceiptCannotRestoreOfflineAccessFromExistingCredential() async throws {
        let receipts: [[String: Any]] = [
            ["userID": "11111111-1111-4111-8111-111111111111", "projectURL": "https://account-fixture.invalid"],
            ["userID": "", "projectURL": "https://account-fixture.invalid", "allowed": true],
            ["userID": "11111111-1111-4111-8111-111111111111", "projectURL": "https://account-fixture.invalid", "allowed": true]
        ]
        for receipt in receipts {
            let fixture = try DesktopAccountFixture(); defer { fixture.close() }
            fixture.credential = String(decoding: try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user)), as: UTF8.self)
            let original = try JSONSerialization.data(withJSONObject: receipt)
            let file = fixture.root.appendingPathComponent("account-access.json")
            try original.write(to: file)
            let service = DesktopAccountService(root: fixture.root, environment: fixture.environment)
            _ = try await service.handle(channel: "auth:getState", request: [:])
            XCTAssertFalse(service.localAccessAllowed)
            XCTAssertTrue(fixture.requests.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testReceiptWriteFailureDoesNotUnlockCurrentOrReopenedProfile() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        let receipt = fixture.root.appendingPathComponent("account-access.json")
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
        var environment = fixture.environment
        environment.authorizeApple = { _ in DesktopAppleCredential(identityToken: "fixture-identity", authorizationCode: nil) }
        environment.request = { request in
            (try JSONSerialization.data(withJSONObject: fixture.session(user: fixture.user)), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        let response = try await service.handle(channel: "auth:signIn", request: ["provider": "apple"]) as? [String: Any]
        XCTAssertEqual(response?["ok"] as? Bool, false)
        XCTAssertFalse(service.localAccessAllowed)
        let reopened = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try await reopened.handle(channel: "auth:getState", request: [:])
        XCTAssertFalse(reopened.localAccessAllowed)
    }

    func testDeletionLocksBeforeRemoteRequestAndExplainsPendingSettlement() async throws {
        let fixture = try DesktopAccountFixture(); defer { fixture.close() }
        var environment = fixture.environment, uncertain = false
        environment.authorizeApple = { _ in DesktopAppleCredential(identityToken: "fixture-identity", authorizationCode: nil) }
        environment.request = { request in
            let deleting = request.url!.path == "/functions/v1/account-delete"
            if deleting {
                let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("account-access.json"))) as? [String: Any]
                XCTAssertEqual(receipt?["allowed"] as? Bool, false)
                if uncertain { throw URLError(.networkConnectionLost) }
            }
            let body: Any = deleting ? ["error": "account_deletion_pending_transactions", "pendingTransactions": ["orders": [["count": 2]], "payouts": [["count": 1]], "cases": [["count": 3]], "unsettledBalance": -4500]] : request.url!.path == "/auth/v1/token" ? fixture.session(user: fixture.user) : []
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: deleting ? 409 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopAccountService(root: fixture.root, environment: environment)
        _ = try await service.handle(channel: "auth:signIn", request: ["provider": "apple"])
        do { _ = try await service.deleteAccount(); XCTFail("Pending transactions") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("거래 2건")); XCTAssertTrue(error.localizedDescription.contains("정산 1건"))
            XCTAssertTrue(error.localizedDescription.contains("처리 3건")); XCTAssertTrue(error.localizedDescription.contains("-4500원"))
        }
        XCTAssertTrue(service.localAccessAllowed)
        uncertain = true
        do { _ = try await service.deleteAccount(); XCTFail("Uncertain remote outcome") } catch { }
        XCTAssertFalse(service.localAccessAllowed)
        XCTAssertFalse(DesktopAccountService(root: fixture.root, environment: environment).localAccessAllowed)
    }

}

@MainActor
private final class DesktopAccountFixture {
    let directory: URL
    let root: URL
    let user = "11111111-1111-4111-8111-111111111111"
    var configuration = (url: "https://account-fixture.invalid", key: "fixture-public-key")
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
        let token = encode(["alg": "fixture"]) + "." + encode(["sub": user, "iss": issuer ?? configuration.url + "/auth/v1", "exp": expires]) + ".fixture"
        return ["access_token": token, "refresh_token": "fixture-refresh", "expires_at": expires, "user": ["id": user, "email": "student@example.invalid", "user_metadata": metadata]]
    }
    func close() {
        oauth?.resume(throwing: CancellationError()); oauth = nil
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }; waiting = [:]
        try? FileManager.default.removeItem(at: directory)
    }
}
