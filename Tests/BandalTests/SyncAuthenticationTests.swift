import XCTest
@testable import Bandal

@MainActor
private final class AuthenticationFixture {
    var credential: String?
    var configuration = (url: "https://fixture.invalid", key: "public-test-key")
    var requests: [URLRequest] = []
    var pending: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    var oauthURL: URL?
    var oauthContinuation: CheckedContinuation<URL, Error>?
    var environment: SyncAuthenticationEnvironment {
        SyncAuthenticationEnvironment(configuration: { self.configuration }, readCredential: { self.credential }, writeCredential: { self.credential = $0.isEmpty ? nil : $0 }, request: { request in
            try await withCheckedThrowingContinuation { continuation in
                let index = self.requests.count
                self.requests.append(request); self.pending[index] = continuation
            }
        }, openOAuth: { url in
            try await withCheckedThrowingContinuation { continuation in self.oauthURL = url; self.oauthContinuation = continuation }
        })
    }
    func reply(_ index: Int, data: Data = Data("{}".utf8), status: Int = 200) {
        pending.removeValue(forKey: index)?.resume(returning: (data, HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
    func sessionData(user: String, email: String) throws -> Data {
        try JSONEncoder().encode(CloudSession(access_token: "fixture-access", refresh_token: "fixture-refresh", expires_at: Date().timeIntervalSince1970 + 3_600, user: CloudUser(id: user, email: email)))
    }
    func cancelRemaining() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending = [:]
        oauthContinuation?.resume(throwing: CancellationError()); oauthContinuation = nil
    }
}

@MainActor
final class SyncAuthenticationTests: XCTestCase {
    private func makeModel() async -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: directory, seedWelcome: false)
        while model.loading { await Task.yield() }
        return (model, directory)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Authentication fixture was not reached"); throw URLError(.timedOut) }
            await Task.yield()
        }
    }
    func testCodeRequestSerializesEveryAuthenticationEntryPoint() async throws {
        let (model, directory) = await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = AuthenticationFixture(); defer { fixture.cancelRemaining() }
        let controller = SyncController(model: model, authentication: fixture.environment)
        let pending = Task { try await controller.sendCode(email: "one@example.org") }
        try await waitUntil { fixture.requests.count == 1 }
        XCTAssertTrue(controller.busy)
        for attempt in 0..<4 {
            do {
                switch attempt {
                case 0: try await controller.sendCode(email: "two@example.org")
                case 1: try await controller.verifyCode(email: "one@example.org", code: "123456")
                case 2: try await controller.signIn(email: "one@example.org", password: "fixture")
                default: try await controller.signIn(provider: "google")
                }
                XCTFail("Concurrent authentication must be rejected")
            } catch { XCTAssertTrue(error.localizedDescription.contains("진행 중")) }
        }
        XCTAssertEqual(fixture.requests.count, 1); XCTAssertNil(fixture.oauthURL)
        fixture.reply(0); try await pending.value
        XCTAssertFalse(controller.busy)
        XCTAssertTrue(controller.status.contains("인증 코드"))
    }
    func testLateVerificationCannotRestoreSessionOrReleaseNewLoginLock() async throws {
        let (model, directory) = await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = AuthenticationFixture(); defer { fixture.cancelRemaining() }
        let controller = SyncController(model: model, authentication: fixture.environment)
        let obsolete = Task { try await controller.verifyCode(email: "old@example.org", code: "123456") }
        try await waitUntil { fixture.requests.count == 1 }
        await controller.signOut()
        XCTAssertFalse(controller.busy)
        let current = Task { try await controller.signIn(email: "new@example.org", password: "fixture") }
        try await waitUntil { fixture.requests.count == 2 }
        fixture.reply(0, data: try fixture.sessionData(user: "11111111-1111-4111-8111-111111111111", email: "old@example.org"))
        do { try await obsolete.value; XCTFail("A stale verification must be cancelled") } catch is CancellationError { }
        XCTAssertTrue(controller.busy, "Old completion must not unlock a newer request")
        XCTAssertNil(controller.email); XCTAssertNil(fixture.credential)
        fixture.reply(1, data: try fixture.sessionData(user: "22222222-2222-4222-8222-222222222222", email: "new@example.org"))
        try await current.value
        XCTAssertEqual(controller.email, "new@example.org"); XCTAssertFalse(controller.busy)
        let binding = try await model.store?.syncAccount()
        XCTAssertNil(binding, "Authentication alone must not irreversibly bind the local database")
        let saved = try JSONDecoder().decode(CloudSession.self, from: Data(try XCTUnwrap(fixture.credential).utf8))
        XCTAssertEqual(saved.user.email, "new@example.org")
    }
    func testLateOAuthCallbackDoesNotExchangeCodeAfterSignOut() async throws {
        let (model, directory) = await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = AuthenticationFixture(); defer { fixture.cancelRemaining() }
        let controller = SyncController(model: model, authentication: fixture.environment)
        let pending = Task { try await controller.signIn(provider: "google") }
        try await waitUntil { fixture.oauthContinuation != nil }
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(fixture.oauthURL), resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.queryItems?.contains { $0.name == "code_challenge" && $0.value?.isEmpty == false } == true)
        await controller.signOut()
        let continuation = fixture.oauthContinuation; fixture.oauthContinuation = nil
        continuation?.resume(returning: URL(string: "bandal://auth/callback?code=old-code")!)
        do { try await pending.value; XCTFail("A stale OAuth callback must be cancelled") } catch is CancellationError { }
        XCTAssertTrue(fixture.requests.isEmpty); XCTAssertNil(fixture.credential)
        XCTAssertFalse(controller.busy); XCTAssertEqual(controller.status, "연결되지 않음")
    }
    func testLateCodeStatusAndChangedServerCannotReviveAuthentication() async throws {
        let (model, directory) = await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = AuthenticationFixture(); defer { fixture.cancelRemaining() }
        let controller = SyncController(model: model, authentication: fixture.environment)
        let code = Task { try await controller.sendCode(email: "one@example.org") }
        try await waitUntil { fixture.requests.count == 1 }
        await controller.signOut(); fixture.reply(0)
        do { try await code.value; XCTFail("Old status must not replace sign-out state") } catch is CancellationError { }
        XCTAssertEqual(controller.status, "연결되지 않음")
        let password = Task { try await controller.signIn(email: "one@example.org", password: "fixture") }
        try await waitUntil { fixture.requests.count == 2 }
        fixture.configuration.url = "https://changed-fixture.invalid"
        fixture.reply(1, data: try fixture.sessionData(user: "33333333-3333-4333-8333-333333333333", email: "one@example.org"))
        do { try await password.value; XCTFail("A response from the previous server must be cancelled") } catch is CancellationError { }
        XCTAssertNil(fixture.credential); XCTAssertNil(controller.email); XCTAssertFalse(controller.busy)
    }
    func testExistingAccountBindingRejectsAnotherAccountBeforeCredentialWrite() async throws {
        let (model, directory) = await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await model.store?.bindSyncAccount(userID: "11111111-1111-4111-8111-111111111111")
        let fixture = AuthenticationFixture(); defer { fixture.cancelRemaining() }
        let controller = SyncController(model: model, authentication: fixture.environment)
        let pending = Task { try await controller.verifyCode(email: "other@example.org", code: "123456") }
        try await waitUntil { fixture.requests.count == 1 }
        fixture.reply(0, data: try fixture.sessionData(user: "22222222-2222-4222-8222-222222222222", email: "other@example.org"))
        do { try await pending.value; XCTFail("An account switch must preserve the existing store binding") }
        catch { XCTAssertTrue(error.localizedDescription.contains("다른 계정")) }
        XCTAssertNil(fixture.credential); XCTAssertNil(controller.email); XCTAssertFalse(controller.busy)
        let binding = try await model.store?.syncAccount()
        XCTAssertEqual(binding, "11111111-1111-4111-8111-111111111111")
    }
}
