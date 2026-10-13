import XCTest
@testable import Bandal

@MainActor
final class DesktopMailTests: XCTestCase {
    private let client = "fixture.apps.googleusercontent.com"
    private let scheme = "com.googleusercontent.apps.fixture"
    private func response(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func testPKCECallbackAndSafeStateKeepCredentialsOutOfRenderer() async throws {
        var saved = "", requests: [URLRequest] = []
        var environment = DesktopMailEnvironment()
        environment.configuration = { (self.client, self.scheme, false) }
        environment.read = { _ in nil }
        environment.write = { _, value in saved = value }
        environment.open = { url, scheme in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
            XCTAssertNotNil(query.first { $0.name == "code_challenge" }?.value)
            let state = query.first { $0.name == "state" }!.value!
            return URL(string: scheme + ":/oauth2redirect?code=fixture-code&state=" + state)!
        }
        environment.request = { request in
            requests.append(request)
            if request.url!.path == "/token" {
                XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("code_verifier="))
                return try self.response(request, ["access_token": "private-access", "refresh_token": "private-refresh", "expires_in": 3600, "scope": "https://www.googleapis.com/auth/gmail.modify"])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-access")
            return try self.response(request, ["emailAddress": "fixture@example.invalid"])
        }
        let service = DesktopMailService(environment: environment)
        let connected = try await service.handle(channel: "native:mailConnect", request: [:]) as! [String: Any]
        XCTAssertEqual(connected["status"] as? String, "connected")
        XCTAssertTrue(saved.contains("private-refresh"))
        let state = try await service.handle(channel: "native:mailState", request: [:])
        XCTAssertFalse(String(describing: state).contains("private-"))
        XCTAssertEqual(requests.count, 2)
        do { _ = try await service.handle(channel: "native:mailAPI", request: ["path": "https://attacker.invalid/messages", "method": "GET"]); XCTFail("Unexpected external request") } catch {}
        XCTAssertEqual(requests.count, 2)
    }
    func testMismatchedOAuthStateCannotSaveSession() async throws {
        var wrote = false, fetched = false
        var environment = DesktopMailEnvironment()
        environment.configuration = { (self.client, self.scheme, true) }
        environment.read = { _ in nil }; environment.write = { _, _ in wrote = true }
        environment.open = { _, scheme in URL(string: scheme + ":/oauth2redirect?code=malicious&state=wrong")! }
        environment.request = { _ in fetched = true; throw URLError(.badServerResponse) }
        let service = DesktopMailService(environment: environment)
        do { _ = try await service.handle(channel: "native:mailConnect", request: [:]); XCTFail("Invalid callback was accepted") } catch {}
        XCTAssertFalse(wrote); XCTAssertFalse(fetched)
    }
    func testExpiredSessionRefreshAndDisconnectDoNotReturnTokens() async throws {
        var saved = "", refreshed = 0
        var environment = DesktopMailEnvironment()
        environment.configuration = { (self.client, self.scheme, false) }
        environment.read = { _ in #"{"accessToken":"old","refreshToken":"refresh","expiresAt":0,"email":"fixture@example.invalid"}"# }
        environment.write = { _, value in saved = value }
        environment.request = { request in
            if request.url!.path == "/token" { refreshed += 1; return try self.response(request, ["access_token": "new-private", "expires_in": 3600]) }
            if request.url!.path == "/revoke" { return try self.response(request, [:]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-private")
            return try self.response(request, ["messages": []])
        }
        let service = DesktopMailService(environment: environment)
        _ = try await service.handle(channel: "native:mailAPI", request: ["path": "/messages?maxResults=20", "method": "GET"])
        XCTAssertEqual(refreshed, 1); XCTAssertTrue(saved.contains("new-private"))
        _ = try await service.handle(channel: "native:mailDisconnect", request: [:])
        XCTAssertEqual(saved, "")
        let state = try await service.handle(channel: "native:mailState", request: [:]) as! [String: Any]
        XCTAssertEqual(state["status"] as? String, "disconnected")
    }
}
