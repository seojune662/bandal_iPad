import XCTest
@testable import Bandal

/// The steps of Google sign-in that run without the web sheet (design §1.4): the redirect, the
/// code exchange for an iOS client (PKCE, no secret) and the refresh.
final class GoogleDriveAuthTests: XCTestCase {
    private final class Token: @unchecked Sendable { var bodies: [String] = []; var answer: [String: Any] = [:]; var status = 200 }

    private func transport(_ token: Token) -> GoogleDriveAuth.Transport {
        { request in
            token.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let data = try JSONSerialization.data(withJSONObject: token.answer)
            return (data, HTTPURLResponse(url: request.url!, statusCode: token.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// A JWT whose payload is `claims` (unsigned: claims straight from the token endpoint are read, not verified).
    private func idToken(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    private func redirect(_ query: String) -> URL { URL(string: GoogleDriveAuth.redirect + "?" + query)! }

    func testTheRedirectIsExchangedForTheAccount() async throws {
        let token = Token()
        token.answer = ["access_token": "a", "refresh_token": "r", "expires_in": 3600, "scope": "openid https://www.googleapis.com/auth/drive.file email",
                        "id_token": try idToken(["sub": "1234", "email": "a@example.com"])]
        let account = try await GoogleDriveAuth.finish(redirect("state=s1&code=c1"), state: "s1", verifier: "v1", transport: transport(token))
        XCTAssertEqual(account, .init(refresh: "r", id: "1234", email: "a@example.com"))
        let body = try XCTUnwrap(token.bodies.first)
        XCTAssertTrue(body.contains("code=c1") && body.contains("code_verifier=v1") && body.contains("grant_type=authorization_code"))
        XCTAssertFalse(body.contains("client_secret"))
        let url = GoogleDriveAuth.authorization(challenge: GoogleDriveAuth.challenge("v1"), state: "s1").absoluteString
        XCTAssertTrue(url.contains("code_challenge_method=S256") && url.contains("state=s1"))
    }

    func testARedirectThatIsNotThisRequestOrSaysNoGivesNothing() async throws {
        let token = Token()
        do { _ = try await GoogleDriveAuth.finish(redirect("state=other&code=c1"), state: "s1", verifier: "v1", transport: transport(token)); XCTFail("state") } catch {}
        let denied = try await GoogleDriveAuth.finish(redirect("state=s1&error=access_denied"), state: "s1", verifier: "v1", transport: transport(token))
        XCTAssertNil(denied)
        XCTAssertTrue(token.bodies.isEmpty, "nothing was exchanged")
    }

    func testDriveLeftUntickedIsAskedFor() async throws {
        let token = Token()
        token.answer = ["refresh_token": "r", "scope": "openid email", "id_token": try idToken(["sub": "1"])]
        do { _ = try await GoogleDriveAuth.finish(redirect("state=s1&code=c1"), state: "s1", verifier: "v1", transport: transport(token)); XCTFail("scope") }
        catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_DRIVE_SCOPE") }
    }

    func testARefreshGoogleNoLongerHonoursSignsOut() async throws {
        let token = Token()
        token.status = 400; token.answer = ["error": "invalid_grant"]
        do { _ = try await GoogleDriveAuth.accessToken(.init(refresh: "r", id: "1", email: ""), transport: transport(token)); XCTFail("signed out") }
        catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_DRIVE_SIGNED_OUT") }
        XCTAssertTrue(try XCTUnwrap(token.bodies.first).contains("grant_type=refresh_token"))
    }
}
