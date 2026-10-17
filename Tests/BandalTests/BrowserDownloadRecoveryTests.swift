import XCTest
import Combine
import Network
import WebKit
@testable import Bandal

@MainActor
final class BrowserDownloadRecoveryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("browser-download-recovery-\(UUID())") }
    func testNativeOpenResolvesMaterialImportedAfterDownloadSnapshotWithoutPresenter() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NativeWorkspaceStore(storageRoot: root)
        let services = NativePlatformServices(store: workspace, credentialEnvironment: .init(read: { _ in nil }, write: { _, _ in }))
        defer { withExtendedLifetime(services) {} }
        let host = services.browser, id = UUID().uuidString
        let downloadStore = try XCTUnwrap(host.downloadStore)
        try FileManager.default.createDirectory(at: downloadStore.folder(id), withIntermediateDirectories: true)
        let file = downloadStore.folder(id).appendingPathComponent("lecture.md")
        try Data("# Downloaded note".utf8).write(to: file)
        let record = BrowserDownloadStore.Record(id: id, profileID: "default", courseID: "course", fileName: "lecture.md", url: "https://school.test/lecture.md", destinationLeaf: "lecture.md", relPath: nil, state: "completed", receivedBytes: 17, totalBytes: 17, failureReason: nil)
        let item = DesktopBrowserDownload(restoring: record, host: host)
        host.downloads[id] = item
        let clickedSnapshot = item.payload
        XCTAssertTrue(clickedSnapshot["relPath"] is NSNull)
        item.relPath = "Imported/lecture.md" // Automatic import completes after the row snapshot.
        var opened: [[String: Any]] = [], legacyEvents = 0
        let nativeOpen = expectation(description: "Native workspace receives the imported material")
        let subscription = workspace.events.sink { event in
            if event.channel == "nativeWorkspace:openDocument", let payload = event.payload as? [String: Any] { opened.append(payload); nativeOpen.fulfill() }
            if event.channel == "ui:openMaterial" { legacyEvents += 1 }
        }
        defer { subscription.cancel() }
        _ = try await host.handle(channel: "browser:downloadFile", request: ["id": id, "action": "open"])
        await fulfillment(of: [nativeOpen], timeout: 3)
        XCTAssertNil(host.presentingController)
        XCTAssertEqual(opened.count, 1); XCTAssertEqual(legacyEvents, 0)
        XCTAssertEqual(opened.first?["courseId"] as? String, "course")
        XCTAssertEqual(opened.first?["relPath"] as? String, "Imported/lecture.md")
        XCTAssertEqual(opened.first?["kind"] as? String, "note")
    }
    func testCompletedRecordsSurviveContainerRelocationAndDismissPreservesFiles() throws {
        let original = root(), relocated = root()
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: relocated) }
        let host = DesktopBrowserHost(root: original), id = UUID().uuidString
        let store = try XCTUnwrap(host.downloadStore)
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        let bytes = Data("completed PDF fixture".utf8)
        try bytes.write(to: store.folder(id).appendingPathComponent("lecture.pdf"))
        try store.save(.init(id: id, profileID: "default", courseID: "course", fileName: "lecture.pdf", url: "https://school.test/lecture.pdf", destinationLeaf: "lecture.pdf", relPath: "lecture.pdf", state: "completed", receivedBytes: 21, totalBytes: 21, failureReason: nil), resumeData: nil)
        try FileManager.default.moveItem(at: original, to: relocated)
        let restored = DesktopBrowserHost(root: relocated), item = try XCTUnwrap(restored.downloads[id])
        XCTAssertEqual(item.state, "completed"); XCTAssertEqual(item.relPath, "lecture.pdf")
        let file = try XCTUnwrap(item.destination)
        XCTAssertTrue(file.path.hasPrefix(relocated.path)); XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(item.payload["webContentsId"] is NSNull)
        _ = try restored.dismissDownload(["id": id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(DesktopBrowserHost(root: relocated).downloads[id])
    }
    func testInterruptedAndPausedRestorationNeverStartsNetworkAutomatically() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root), store = try XCTUnwrap(host.downloadStore)
        let interruptedID = UUID().uuidString, pausedID = UUID().uuidString
        for (id, data) in [(interruptedID, nil as Data?), (pausedID, Data("opaque WebKit fixture".utf8))] {
            try store.save(.init(id: id, profileID: "default", courseID: nil, fileName: "file.pdf", url: "https://school.test/file.pdf", destinationLeaf: nil, relPath: nil, state: "progressing", receivedBytes: 40, totalBytes: 100, failureReason: nil), resumeData: data)
        }
        let restored = DesktopBrowserHost(root: root)
        XCTAssertEqual(restored.downloads[interruptedID]?.state, "interrupted")
        XCTAssertEqual(restored.downloads[pausedID]?.state, "progressing")
        XCTAssertEqual(restored.downloads[pausedID]?.paused, true)
        XCTAssertNil(restored.downloads[pausedID]?.download)
        XCTAssertTrue(restored.pages.isEmpty)
        XCTAssertFalse(BrowserDownloadStore.valid(.init(id: interruptedID, profileID: "default", courseID: nil, fileName: "file.pdf", url: nil, destinationLeaf: "../outside", relPath: nil, state: "completed", receivedBytes: 0, totalBytes: 0, failureReason: nil)))
    }
    func testRealWebKitDownloadPersistsThenRetriesAfterRestartWithoutOriginalTab() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserRecoveryFixtureServer(), port = try await server.start(); defer { server.stop() }
        server.interruptResponses = true
        let url = URL(string: "http://127.0.0.1:\(port)/lecture.pdf")!
        let host = DesktopBrowserHost(root: root)
        try await host.prepareBrowserNetwork()
        let page = try host.createPage(tabID: "download", profileID: "default", isPrivate: false, courseID: nil)
        let transfer = await page.webView.startDownload(using: host.navigationRequest(url))
        host.track(transfer, page: page)
        let id = try XCTUnwrap(host.downloads.keys.first)
        // A real truncated response produces WebKit's failure/resume data. The
        // test does not fabricate a second record or retry a completed file.
        try await wait { host.downloads[id]?.state == "interrupted" }
        let original = try XCTUnwrap(host.downloads[id])
        XCTAssertNotNil(original.failureReason)
        XCTAssertEqual(host.downloadStore?.records.first(where: { $0.id == id })?.state,"interrupted")
        host.destroy("download")
        let restarted = DesktopBrowserHost(root: root), restored = try XCTUnwrap(restarted.downloads[id])
        XCTAssertTrue(restarted.pages.isEmpty); XCTAssertNil(restored.page)
        XCTAssertTrue(restored.state == "interrupted" || restored.paused)
        let requestsBeforeRetry = server.requestCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requestCount,requestsBeforeRetry,"Restoration must not silently restart a transfer")
        server.interruptResponses = false
        _ = try await restarted.handle(channel: "browser:downloadFile", request: ["id": id, "action": "retry"])
        try await wait { restored.state == "completed" || restored.state == "interrupted" }
        let diagnostic = "state=\(restored.payload), requests=\(server.requestCount), beforeRetry=\(requestsBeforeRetry), resume=\(restored.resumeData != nil), userAgent=\(server.lastUserAgent)"
        if restored.state != "completed" {
            let attachment = XCTAttachment(string: diagnostic); attachment.name = "Restored-download-diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(restored.state,"completed",diagnostic)
        XCTAssertGreaterThan(server.requestCount,requestsBeforeRetry)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.destination)), server.body)
        XCTAssertTrue(server.lastUserAgent.contains("Safari/")); XCTAssertTrue(server.lastUserAgent.contains("Bandal"), "Restored transfer must use the same engine identity as browser pages")
        let snapshots = try await restarted.handle(channel: "browser:downloadsSnapshot", request: [:]) as? [[String: Any]]
        XCTAssertEqual(snapshots?.count, 1)
    }
    func testAutomaticCourseImportRejectsConcurrentRetryAndCompletedRetryDoesNotDuplicateMaterial() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserRecoveryFixtureServer(), port = try await server.start(); defer { server.stop() }
        let host = DesktopBrowserHost(root: root)
        var imports = 0, release: CheckedContinuation<Void,Never>?
        defer { release?.resume() }
        host.onDownload = { source, course in
            imports += 1; XCTAssertEqual(course,"course")
            await withCheckedContinuation { release = $0 }
            let destination = root.appendingPathComponent("imported-lecture.pdf")
            try FileManager.default.copyItem(at: source,to: destination)
            return "imported-lecture.pdf"
        }
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "download-import", "courseId": "course"])
        defer { host.destroy("download-import") }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": "download-import", "action": "downloadURL", "args": ["http://127.0.0.1:\(port)/lecture.pdf"]])
        let id = try XCTUnwrap(host.downloads.keys.first)
        let item = try XCTUnwrap(host.downloads[id])
        try await wait { release != nil || item.state == "interrupted" }
        guard item.state == "completed" else {
            XCTFail("Download did not reach automatic import: \(item.payload), requests=\(server.requestCount)")
            throw NSError(domain: "BrowserDownloadFixture", code: 1)
        }
        XCTAssertEqual(item.state,"completed"); XCTAssertTrue(item.isChangingTransfer)
        XCTAssertEqual(item.payload["recoverable"] as? Bool,false)
        do {
            _ = try await host.handle(channel: "browser:downloadFile",request: ["id": id,"action": "retry"])
            XCTFail("Retry must not import the same completed file concurrently")
        } catch { }
        XCTAssertThrowsError(try host.dismissDownload(["id": id]),"A pending import cannot later resurrect a dismissed record")
        XCTAssertEqual(imports,1)
        release?.resume(); release = nil
        try await wait { item.relPath != nil && !item.isChangingTransfer }
        _ = try await host.handle(channel: "browser:downloadFile",request: ["id": id,"action": "retry"])
        XCTAssertEqual(imports,1,"Repeated completed actions are idempotent")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("imported-lecture.pdf")),server.body)
        XCTAssertEqual(host.downloadStore?.records.first(where: { $0.id == id })?.relPath,"imported-lecture.pdf")
    }
    func testPrivateDownloadStaysOutOfNormalHistoryAndCourseUntilExplicitSave() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserRecoveryFixtureServer(), port = try await server.start(); defer { server.stop() }
        let host = DesktopBrowserHost(root: root)
        var imports = 0
        host.onDownload = { source, course in
            imports += 1; XCTAssertEqual(course, "private-course")
            XCTAssertEqual(try Data(contentsOf: source), server.body)
            return "explicitly-saved.pdf"
        }
        _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "native-scope.private.download", "isPrivate": true, "courseId": "private-course"])
        let page = try XCTUnwrap(host.pages["native-scope.private.download"])
        defer { host.destroy(page.tabID) }
        _ = try await host.handle(channel: "browser:pageAction", request: ["tabId": page.tabID, "action": "downloadURL", "args": ["http://127.0.0.1:\(port)/lecture.pdf"]])
        let item = try XCTUnwrap(host.downloads.values.first)
        try await wait { item.state == "completed" || item.state == "interrupted" }
        XCTAssertEqual(item.state, "completed", "\(item.payload), requests=\(server.requestCount)"); XCTAssertEqual(imports, 0)
        XCTAssertNil(item.relPath); XCTAssertEqual(item.payload["recoverable"] as? Bool, true)
        XCTAssertEqual(item.payload["profileId"] as? String, "default")
        XCTAssertEqual(item.payload["isPrivate"] as? Bool, true)
        XCTAssertEqual(item.payload["tabId"] as? String, page.tabID)
        let file = try XCTUnwrap(item.destination)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertFalse(file.path.hasPrefix(host.root.path), "A private filename must not enter the normal Documents download directory")
        XCTAssertEqual(try Data(contentsOf: file), server.body)
        XCTAssertTrue(host.downloadStore?.records.isEmpty == true)
        XCTAssertTrue(DesktopBrowserHost(root: root).downloads.isEmpty, "Private metadata must not reappear after restart")
        _ = try await host.handle(channel: "browser:downloadFile", request: ["id": item.id, "action": "retry"])
        XCTAssertEqual(imports, 1); XCTAssertEqual(item.relPath, "explicitly-saved.pdf")
        XCTAssertTrue(host.downloadStore?.records.isEmpty == true)
    }

    private func wait(_ ready: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !ready() && Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        guard ready() else {
            XCTFail("WebKit download timed out")
            throw NSError(domain: "BrowserDownloadFixture", code: 2)
        }
    }
}

private final class BrowserRecoveryFixtureServer: @unchecked Sendable {
    let body = Data(repeating: 0x61, count: 16_384)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bandal.download-recovery-fixture")
    private let lock = NSLock()
    private var storedUserAgent = ""
    private var requests = 0
    private var interrupt = false
    private var connections: [NWConnection] = [] // Retain until the fixture stops.
    var lastUserAgent: String { lock.withLock { storedUserAgent } }
    var requestCount: Int { lock.withLock { requests } }
    var interruptResponses: Bool { get { lock.withLock { interrupt } } set { lock.withLock { interrupt = newValue } } }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port { self.listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue) }
                if case .failed(let error) = state { self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let userAgent = String(data: data ?? Data(), encoding: .utf8)?.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") } ?? ""
                    let interrupted = self.lock.withLock { self.storedUserAgent = userAgent; self.requests += 1; return self.interrupt }
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=lecture.pdf\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n"
                    let body = interrupted ? Data(self.body.prefix(512)) : self.body
                    // Send a proper FIN after the response. cancel() immediately
                    // after contentProcessed may reset TCP before queued bytes
                    // arrive, making an otherwise successful fixture flaky.
                    connection.send(content: Data(header.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in if error != nil { connection.cancel() } })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.async { self.connections.forEach { $0.cancel() }; self.connections.removeAll() } }
}
