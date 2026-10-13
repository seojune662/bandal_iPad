import XCTest
@testable import Bandal

@MainActor
final class DesktopCloudTests: XCTestCase {
    private let project = "https://fixture.supabase.co"
    private func identity(_ user: String = "user-a") -> DesktopSyncIdentity {
        .init(userID: user, projectURL: URL(string: project)!, publishableKey: "public-fixture")
    }
    private func environment() -> DesktopCloudEnvironment {
        DesktopCloudEnvironment(configuration: { (self.project, "public-fixture", "https://market.example.test") }, signedIn: { true }, credential: { (self.identity(), "private-fixture-token") })
    }
    private func input(_ id: String, url: String? = nil) -> [String: Any] {
        ["id": id, "url": url ?? project + "/functions/v1/study-market", "method": "POST", "accountID": "user-a", "headers": ["Authorization": "Bearer native-keychain", "apikey": "ignored", "Content-Type": "application/json"], "bodyBase64": Data("{}".utf8).base64EncodedString()]
    }
    private func file(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        try data.write(to: file); return file
    }
    func testTokenStaysNativeAndBodiesAreChunkedAndRemovedAtEOF() async throws {
        var environment = environment(), responseFile: URL?
        let bytes = Data(repeating: 71, count: 1_200_000)
        environment.request = { request, maximum in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-fixture")
            XCTAssertEqual(request.httpBody, Data("{}".utf8)); XCTAssertEqual(maximum, 8 * 1024 * 1024)
            let file = try self.file(bytes); responseFile = file
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Set-Cookie": "secret=private", "Authorization": "private-fixture-token"])!)
        }
        let service = DesktopCloudService(environment: environment)
        let result = try await service.handle(channel: "native:cloudRequest", request: input("chunks")) as! [String: Any]
        XCTAssertFalse(String(describing: result).contains("private-fixture-token"))
        XCTAssertNil((result["headers"] as? [String: String])?["set-cookie"])
        var received = Data(), chunks = 0
        while true {
            let part = try await service.handle(channel: "native:cloudRead", request: ["bodyID": "chunks"]) as! [String: Any]
            if part["done"] as? Bool == true { break }
            let data = Data(base64Encoded: part["data"] as! String)!
            XCTAssertLessThanOrEqual(data.count, 512 * 1024); received += data; chunks += 1
        }
        XCTAssertEqual(chunks, 3); XCTAssertEqual(received, bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseFile!.path))
    }
    func testCredentialsNeverReachOtherOriginsStorageOrUnapprovedHeaders() async throws {
        var environment = environment(), calls = 0
        environment.request = { _, _ in calls += 1; throw URLError(.unsupportedURL) }
        let service = DesktopCloudService(environment: environment)
        let rejected = ["https://fixture.supabase.co.evil.test/functions/v1/study-market", "https://fixture.supabase.co@evil.test/functions/v1/study-market", project + "/rest/v1/other", project + "/storage/v1/object/sign/file"]
        for (index, url) in rejected.enumerated() {
            do { _ = try await service.handle(channel: "native:cloudRequest", request: input("reject-\(index)", url: url)); XCTFail("Unexpected origin/token acceptance") } catch { }
        }
        var cookie = input("cookie"); cookie["headers"] = ["Cookie": "session=secret"]
        do { _ = try await service.handle(channel: "native:cloudRequest", request: cookie); XCTFail("Cookies must remain outside this transport") } catch { }
        XCTAssertEqual(calls, 0)
        for suffix in ["\r\nInjected: value", "\r", "\n", "\0", "\u{7f}"] {
            var invalid = input("control-" + UUID().uuidString); invalid["headers"] = ["Content-Type": "application/json" + suffix]
            do { _ = try await service.handle(channel: "native:cloudRequest", request: invalid); XCTFail("Header control characters must be rejected before network") } catch { }
        }
        XCTAssertEqual(calls, 0)
    }
    func testAccountChangeAndLateCancellationRemoveDownloadedFiles() async throws {
        for cancel in [false, true] {
            var environment = environment(), user = "user-a"
            var pending: CheckedContinuation<(URL, HTTPURLResponse), Error>?
            environment.credential = { (self.identity(user), "fixture") }
            environment.request = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
            let service = DesktopCloudService(environment: environment)
            let task = Task { try await service.handle(channel: "native:cloudRequest", request: input("race")) }
            while pending == nil { await Task.yield() }
            if cancel { _ = try await service.handle(channel: "native:cloudCancel", request: ["id": "race"]) } else { user = "user-b" }
            let file = try file(Data("sensitive".utf8))
            pending?.resume(returning: (file, HTTPURLResponse(url: URL(string: project + "/functions/v1/study-market")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            do { _ = try await task.value; XCTFail("A late response must not cross account/cancellation boundaries") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testBoundAccountRejectsTheNextUploadBeforeNetworkAndRedirectRepliesAreRejected() async throws {
        var environment = environment(), user = "user-b", calls = 0, output: URL?
        environment.credential = { (self.identity(user), "fixture") }
        environment.request = { request, _ in
            calls += 1; let file = try self.file(Data()); output = file
            return (file, HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.test"])!)
        }
        let service = DesktopCloudService(environment: environment)
        do { _ = try await service.handle(channel: "native:cloudRequest", request: input("different-user")); XCTFail("An action must stay bound to its initial account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0); user = "user-a"
        do { _ = try await service.handle(channel: "native:cloudRequest", request: input("redirect")); XCTFail("Redirect responses must be rejected") } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output!.path))
    }
}
