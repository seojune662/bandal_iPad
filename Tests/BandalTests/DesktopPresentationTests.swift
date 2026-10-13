import XCTest
@testable import Bandal

@MainActor
final class DesktopPresentationTests: XCTestCase {
    private let legacy = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 1])
    private let normalized = Data([0x50, 0x4b, 0x03, 0x04, 2, 3, 4])
    func testSourceVersionCacheWorksOfflineAndRejectsChangedSourceWithoutServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppt-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("강의.ppt"); try legacy.write(to: source)
        var configured = "https://converter.example.test", requests = 0, tokens = 0
        var environment = DesktopPresentationEnvironment(); environment.configuration = { configured }
        environment.request = { request, limit in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, "https://converter.example.test/normalize")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.ms-powerpoint")
            XCTAssertEqual(request.httpBody, self.legacy); XCTAssertEqual(limit, 160 * 1024 * 1024)
            let file = root.appendingPathComponent("response.pptx"); try self.normalized.write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.openxmlformats-officedocument.presentationml.presentation"])!)
        }
        let service = DesktopPresentationService(root: root, token: { tokens += 1; return "fixture-access" }, environment: environment)
        let first = try await service.handle(channel: "native:presentationNormalize", request: ["path": source.path, "requestId": "first"]) as? [String: Any]
        XCTAssertEqual(first?["data"] as? String, normalized.base64EncodedString())
        configured = ""
        _ = try await service.handle(channel: "native:presentationNormalize", request: ["path": source.path, "requestId": "offline"])
        XCTAssertEqual(requests, 1); XCTAssertEqual(tokens, 1)
        try (legacy + Data([2])).write(to: source)
        do { _ = try await service.handle(channel: "native:presentationNormalize", request: ["path": source.path, "requestId": "changed"]); XCTFail("A changed source must not reuse another version's cached slides") } catch { XCTAssertTrue(error.localizedDescription.contains("연결되지")) }
    }

    func testCancellationAndInvalidServerReplyNeverPublishCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppt-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("강의.ppt"); try legacy.write(to: source)
        var pending: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        var environment = DesktopPresentationEnvironment(); environment.configuration = { "https://converter.example.test" }
        environment.request = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let service = DesktopPresentationService(root: root, token: { "fixture" }, environment: environment)
        let operation = Task { try await service.handle(channel: "native:presentationNormalize", request: ["path": source.path, "requestId": "cancel"]) }
        while pending == nil { await Task.yield() }
        _ = try await service.handle(channel: "native:presentationCancel", request: ["requestId": "cancel"])
        let output = root.appendingPathComponent("late.pptx"); try normalized.write(to: output)
        pending?.resume(returning: (output, HTTPURLResponse(url: URL(string: "https://converter.example.test/normalize")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.openxmlformats-officedocument.presentationml.presentation"])!))
        do { _ = try await operation.value; XCTFail("Cancelled normalization must reject its late response") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ConvertedPresentations").path))
        environment.request = { request, _ in
            let file = root.appendingPathComponent("wrong.pdf"); try Data("%PDF-1.7 wrong format".utf8).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!)
        }
        let invalid = DesktopPresentationService(root: root, token: { "fixture" }, environment: environment)
        do { _ = try await invalid.handle(channel: "native:presentationNormalize", request: ["path": source.path, "requestId": "invalid"]); XCTFail("PDF bytes cannot satisfy the original slide renderer's PPTX contract") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ConvertedPresentations").path))
    }
}
