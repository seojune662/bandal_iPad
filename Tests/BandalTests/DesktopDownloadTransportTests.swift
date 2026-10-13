import XCTest
import Network
@testable import Bandal

final class DesktopDownloadTransportTests: XCTestCase {
    func testRealDownloadRejectsRedirectsAndBothDeclaredAndStreamedOversize() async throws {
        let server = try DownloadFixtureServer(), port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let (file, response) = try await DesktopDownloadTransport.request(URLRequest(url: base.appendingPathComponent("ok")), maximumBytes: 4096)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 0x61, count: 1024))
        for route in ["redirect", "declared", "streamed"] {
            do {
                let (unexpected, _) = try await DesktopDownloadTransport.request(URLRequest(url: base.appendingPathComponent(route)), maximumBytes: 4096)
                try? FileManager.default.removeItem(at: unexpected)
                XCTFail("Unsafe response accepted: \(route)")
            } catch { }
        }
        XCTAssertFalse(server.requestedPaths.contains("/redirect-target"), "A redirect must never receive the original request")
    }
    func testRealDownloadsDoNotReadOrPersistSharedCookiesAndCancelPendingTransfer() async throws {
        let server = try DownloadFixtureServer(), port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "bandal-download-test", .value: "private-fixture"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let (file, _) = try await DesktopDownloadTransport.request(URLRequest(url: base.appendingPathComponent("cookies")), maximumBytes: 4096)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).lowercased().contains("cookie:"))
        XCTAssertFalse(HTTPCookieStorage.shared.cookies?.contains { $0.name == "bandal-response-cookie" } == true)
        let task = Task { try await DesktopDownloadTransport.request(URLRequest(url: base.appendingPathComponent("pending")), maximumBytes: 4096) }
        let deadline = Date().addingTimeInterval(3)
        while !server.requestedPaths.contains("/pending"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(server.requestedPaths.contains("/pending"))
        task.cancel()
        do { let (file, _) = try await task.value; try? FileManager.default.removeItem(at: file); XCTFail("Cancelled download completed") } catch { }
    }
}

private final class DownloadFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bandal.download-fixture")
    private let lock = NSLock()
    private var paths: [String] = []
    private var connections: [NWConnection] = []
    var requestedPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = listener.port { listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue) }
                if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.async { self.connections.forEach { $0.cancel() }; self.connections.removeAll() } }
    private func receive(_ connection: NWConnection) {
        connections.append(connection); connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let request = String(decoding: data, as: UTF8.self), path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock(); paths.append(path); lock.unlock()
            if path == "/pending" { return }
            let body: Data, headers: String
            switch path {
            case "/redirect": body = Data(); headers = "HTTP/1.1 302 Found\r\nLocation: /redirect-target\r\nContent-Length: 0\r\n"
            case "/declared": body = Data(repeating: 0x62, count: 65536); headers = "HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n"
            case "/streamed": body = Data(repeating: 0x63, count: 65536); headers = "HTTP/1.1 200 OK\r\n"
            case "/cookies": body = data; headers = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nSet-Cookie: bandal-response-cookie=never-persist; Path=/\r\n"
            default: body = Data(repeating: 0x61, count: 1024); headers = "HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n"
            }
            connection.send(content: Data((headers + "Connection: close\r\n\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
