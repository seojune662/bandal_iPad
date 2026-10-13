import XCTest
import CryptoKit
@testable import Bandal

@MainActor
final class DesktopPluginCatalogTests: XCTestCase {
    private let source = "https://catalog.example.test/index.json"
    private let artifact = "https://downloads.example.test/plugin.zip"
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-\(UUID())")
        try data.write(to: url); return url
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func input(_ id: String, artifact: Bool = false, sha: String = "") -> [String: Any] {
        ["id": id, "kind": artifact ? "artifact" : "index", "sourceUrl": source, "url": artifact ? self.artifact : source, "method": "GET", "headers": [:], "entryID": "fixture.plugin", "sha256": sha]
    }
    func testPublicArtifactRevalidatesIndexHashAndNeverReceivesCredentials() async throws {
        let bytes = Data(repeating: 71, count: 1_200_000), sha = hash(Data(repeating: 71, count: 1_200_000))
        var files: [URL] = [], requests: [URLRequest] = []
        let service = DesktopPluginCatalogTransport(sources: { [self.source] }, request: { request, limit in
            requests.append(request); XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertFalse(request.httpShouldHandleCookies)
            let data: Data
            if request.url!.absoluteString == self.source {
                XCTAssertEqual(limit, 1024 * 1024)
                data = try JSONSerialization.data(withJSONObject: ["format": "bandal-plugin-catalog", "version": 1, "entries": [["id": "fixture.plugin", "url": self.artifact, "sha256": sha]]])
            } else { XCTAssertEqual(limit, 8 * 1024 * 1024); data = bytes }
            let file = try self.file(data); files.append(file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "private=never", "Content-Type": "application/zip"])!)
        }, resolve: { _ in })
        let result = try await service.handle(channel: "native:catalogRequest", request: input("artifact", artifact: true, sha: sha)) as! [String: Any]
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [source, artifact]); XCTAssertNil((result["headers"] as? [String: String])?["set-cookie"])
        var received = Data(), count = 0
        while true {
            let part = try await service.handle(channel: "native:catalogRead", request: ["bodyID": "artifact"]) as! [String: Any]
            if part["done"] as? Bool == true { break }
            let data = Data(base64Encoded: part["data"] as! String)!; XCTAssertLessThanOrEqual(data.count, 512 * 1024); received.append(data); count += 1
        }
        XCTAssertEqual(count, 3); XCTAssertEqual(received, bytes)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    func testUnconfiguredSourcePrivateHostsHeadersAndChangedIndexAreRejected() async throws {
        for url in ["http://bandal.io/plugins/index.json", "https://localhost/index.json", "https://127.0.0.1/index.json", "https://10.0.0.1/index.json", "https://192.168.1.1/index.json", "https://[::1]/index.json", "https://[fc00::1]/index.json", "https://user:password@example.test/index.json", "https://example.test/index.json#fragment", "https://host.local/index.json"] { XCTAssertThrowsError(try DesktopPluginCatalogTransport.validateURL(url)) }
        XCTAssertNoThrow(try DesktopPluginCatalogTransport.validateURL("https://[64:ff9b::808:808]/index.json"))
        XCTAssertThrowsError(try DesktopPluginCatalogTransport.validateURL("https://[64:ff9b::7f00:1]/index.json"))
        var calls = 0
        let service = DesktopPluginCatalogTransport(sources: { [self.source] }, request: { request, _ in
            calls += 1
            let data = try JSONSerialization.data(withJSONObject: ["format": "bandal-plugin-catalog", "version": 1, "entries": [["id": "fixture.plugin", "url": self.artifact, "sha256": String(repeating: "0", count: 64)]]])
            return (try self.file(data), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, resolve: { _ in })
        var unregistered = input("unregistered"); unregistered["sourceUrl"] = "https://other.example.test/index.json"
        do { _ = try await service.handle(channel: "native:catalogRequest", request: unregistered); XCTFail("Unconfigured source") } catch { }
        var headers = input("headers"); headers["headers"] = ["Cookie": "session=private"]
        do { _ = try await service.handle(channel: "native:catalogRequest", request: headers); XCTFail("Caller headers") } catch { }
        XCTAssertEqual(calls, 0)
        do { _ = try await service.handle(channel: "native:catalogRequest", request: input("changed", artifact: true, sha: String(repeating: "a", count: 64))); XCTFail("Changed selection") } catch { }
        XCTAssertEqual(calls, 1, "Changed index must fail before artifact download")
    }
    func testLateCancellationAndConfigurationChangeRemoveResponseFiles() async throws {
        for cancel in [false, true] {
            var sources = [source], pending: CheckedContinuation<(URL, HTTPURLResponse), Error>?
            let service = DesktopPluginCatalogTransport(sources: { sources }, request: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }, resolve: { _ in })
            let task = Task { try await service.handle(channel: "native:catalogRequest", request: input("race")) }
            while pending == nil { await Task.yield() }
            if cancel { _ = try await service.handle(channel: "native:catalogCancel", request: ["id": "race"]) } else { sources = [] }
            let file = try file(Data("{}".utf8)); pending?.resume(returning: (file, HTTPURLResponse(url: URL(string: source)!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            do { _ = try await task.value; XCTFail("Late response") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testRedirectAndOversizedIndexAreRejectedBeforeRead() async throws {
        for redirected in [false, true] {
            var output: URL?
            let service = DesktopPluginCatalogTransport(sources: { [self.source] }, request: { request, _ in
                let file = try self.file(Data(repeating: 1, count: redirected ? 1 : 1024 * 1024 + 1)); output = file
                return (file, HTTPURLResponse(url: request.url!, statusCode: redirected ? 302 : 200, httpVersion: nil, headerFields: nil)!)
            }, resolve: { _ in })
            do { _ = try await service.handle(channel: "native:catalogRequest", request: input("rejected")); XCTFail("Unsafe response") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output!.path))
        }
    }
}
