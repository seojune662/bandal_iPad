import Foundation
import Testing
@testable import BandalCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct TransportTests {
    let user = "e7a33e3b-991d-45d0-8710-8939591a3c8a"
    func token(_ subject: String) -> String {
        "test." + Data("{\"sub\":\"\(subject)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_") + ".signature"
    }
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func RPCWireAndAuthHeaders() async throws {
        let record = StoredRecord(id: "n", kind: "note", payload: Data("{\"v\":1}".utf8), revision: 1)
        let operation = SyncOperation(id: "operation", baseRevision: 0, record: record)
        let expectedToken = token(user)
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/rest/v1/rpc/bandal_push")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "apikey") == "public-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedToken)")
            #expect(request.httpShouldHandleCookies == false)
            if let body = request.httpBody {
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect((json["p_operation"] as? [String: Any])?["id"] as? String == "operation")
            }
            return (200, try JSONEncoder().encode(PushResult(status: .accepted, record: record)))
        }
        let transport = try SupabaseSyncTransport(projectURL: URL(string: "https://unit.invalid")!,
            publishableKey: "public-key", userID: user, session: session(), accessToken: { expectedToken })
        #expect(try await transport.push(operation).record == record)
    }

    @Test func accountTokenMismatchIsRejected() async throws {
        let wrongToken = token("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        StubProtocol.handler = { _ in Issue.record("Network must not run with another account token"); return (500, Data()) }
        let transport = try SupabaseSyncTransport(projectURL: URL(string: "https://unit.invalid")!,
            publishableKey: "public", userID: user, session: session(), accessToken: { wrongToken })
        await #expect(throws: CoreError.self) { try await transport.pull(after: 0, limit: 20) }
    }

    @Test func privateServerErrorBodyIsNotExposed() async throws {
        let validToken = token(user)
        StubProtocol.handler = { _ in (401, Data("private payload and token".utf8)) }
        let transport = try SupabaseSyncTransport(projectURL: URL(string: "https://unit.invalid")!,
            publishableKey: "public", userID: user, session: session(), accessToken: { validToken })
        do { _ = try await transport.pull(after: 0, limit: 20); Issue.record("Expected failure") }
        catch let error as SyncRequestFailure { #expect(error.code == .authenticationRequired); #expect(!error.localizedDescription.contains("private payload")) }
    }
    @Test func accessPreflightAndSafeQuotaClassification() async throws {
        let validToken = token(user)
        let transport = try SupabaseSyncTransport(projectURL: URL(string: "https://unit.invalid")!, publishableKey: "public", userID: user, session: session(), accessToken: { validToken })
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/rest/v1/rpc/bandal_sync_status")
            return (200, Data("{\"writeAllowed\":false,\"storageLimitBytes\":0,\"storageUsedBytes\":100,\"usageComplete\":true}".utf8))
        }
        #expect(try await transport.syncStatus().writeAllowed == false)
        StubProtocol.handler = { _ in (403, Data("{\"code\":\"42501\",\"message\":\"sync_storage_quota_exceeded\",\"detail\":\"private-note\"}".utf8)) }
        do { _ = try await transport.pull(after: 0, limit: 20); Issue.record("Expected quota failure") }
        catch let error as SyncRequestFailure { #expect(error.code == .storageLimitExceeded); #expect(!error.localizedDescription.contains("private-note")) }
    }

}
