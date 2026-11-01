import CryptoKit
import XCTest
@testable import Bandal

/// A Google Drive held in memory that answers the REST v3 calls `DriveProvider` makes, and the
/// token endpoint (design §1.4). Every file is this app's, as under the `drive.file` scope.
final class FakeDrive: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (meta: [String: Any], bytes: Data?)] = [:]
    /// Ids in the order they changed, for `changes.list`.
    private var changed: [String] = []
    private var sessions: [String: (id: String?, metadata: [String: Any])] = [:]
    private var generated = 0, clock = 0
    /// Answers given instead of the real one, first match first: (path suffix, method, status).
    var failures: [(path: String, method: String, status: Int, body: String)] = []
    private(set) var calls: [(method: String, path: String)] = []
    private(set) var tokens = 0

    var transport: GoogleDriveAuth.Transport { { [self] request in try lock.withLock { try answer(request) } } }

    /// Items as Drive holds them, for checks and for setting up a root by hand.
    func add(_ id: String, name: String, parent: String?, folder: Bool = false, bytes: Data? = nil, root: Bool = false) {
        lock.withLock { put(id, name: name, parents: parent.map { [$0] } ?? [], folder: folder, bytes: bytes, root: root) }
    }
    func meta(_ id: String) -> [String: Any]? { lock.withLock { items[id]?.meta } }
    func remove(_ id: String) { lock.withLock { items[id] = nil; changed.append(id) } }
    /// Text of every file whose name ends with `suffix`, joined.
    func text(endingWith suffix: String) -> String {
        lock.withLock { items.values.filter { ($0.meta["name"] as? String)?.hasSuffix(suffix) == true }.compactMap { $0.bytes.map { String(decoding: $0, as: UTF8.self) } }.joined() }
    }
    func ids(named name: String) -> [String] { lock.withLock { items.filter { $0.value.meta["name"] as? String == name }.map(\.key).sorted() } }

    private func put(_ id: String, name: String, parents: [String], folder: Bool, bytes: Data?, root: Bool = false) {
        clock += 1
        var meta: [String: Any] = ["id": id, "name": name, "parents": parents, "mimeType": folder ? DriveProvider.folder : "application/octet-stream",
                                   "createdTime": items[id]?.meta["createdTime"] ?? String(format: "2026-11-01T00:00:%02d.%03dZ", clock / 1000, clock % 1000)]
        if let bytes { meta["size"] = String(bytes.count); meta["md5Checksum"] = DriveProvider.md5(bytes) }
        if root { meta["appProperties"] = ["bandalRoot": "2"] }
        items[id] = (meta, bytes)
        changed.append(id)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!, method = request.httpMethod ?? "GET", path = url.path
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        calls.append((method, path))
        func reply(_ status: Int, _ value: Any = [String: Any](), headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
            let data = try value as? Data ?? JSONSerialization.data(withJSONObject: value)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if let index = failures.firstIndex(where: { path.hasSuffix($0.path) && $0.method == method }) {
            let failure = failures.remove(at: index)
            return try reply(failure.status, Data(failure.body.utf8))
        }
        if url.host == "oauth2.googleapis.com" { tokens += 1; return try reply(200, ["access_token": "access-\(tokens)", "expires_in": 3600]) }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer access-") == true else { return try reply(401) }
        switch (method, path) {
        case ("GET", "/drive/v3/changes/startPageToken"): return try reply(200, ["startPageToken": String(changed.count)])
        case ("GET", "/drive/v3/changes"):
            let from = Int(query["pageToken"] ?? "") ?? 0
            let ids = Set(changed.dropFirst(from))
            return try reply(200, ["changes": ids.map { ["fileId": $0, "removed": items[$0] == nil, "file": items[$0]?.meta ?? [:]] }, "newStartPageToken": String(changed.count)])
        case ("GET", "/drive/v3/files"): return try reply(200, ["files": items.values.map(\.meta)])
        case ("GET", "/drive/v3/files/generateIds"):
            let ids = (0..<(Int(query["count"] ?? "") ?? 10)).map { _ -> String in generated += 1; return "g\(generated)" }
            return try reply(200, ["ids": ids])
        case ("POST", "/drive/v3/files"):
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let id = body["id"] as! String
            guard items[id] == nil else { return try reply(409) }
            put(id, name: body["name"] as! String, parents: body["parents"] as? [String] ?? ["my-drive"], folder: true, bytes: nil, root: (body["appProperties"] as? [String: String])?["bandalRoot"] == "2")
            return try reply(200, items[id]!.meta)
        case ("POST", "/upload/drive/v3/files") where query["uploadType"] == "multipart":
            let (metadata, bytes) = try Self.multipart(request)
            let id = metadata["id"] as! String
            guard items[id] == nil else { return try reply(409) }
            put(id, name: metadata["name"] as! String, parents: metadata["parents"] as? [String] ?? [], folder: false, bytes: bytes)
            return try reply(200, items[id]!.meta)
        case (_, _) where query["uploadType"] == "resumable":
            let session = "s\(sessions.count + 1)"
            sessions[session] = (path.hasPrefix("/upload/drive/v3/files/") ? String(path.dropFirst("/upload/drive/v3/files/".count)) : nil,
                                 try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any] ?? [:])
            return try reply(200, headers: ["Location": "https://upload.fake/session/\(session)"])
        case ("PUT", _) where url.host == "upload.fake":
            let (existing, metadata) = try XCTUnwrap(sessions.removeValue(forKey: url.lastPathComponent))
            let id = existing ?? metadata["id"] as! String, old = items[id]?.meta
            put(id, name: old?["name"] as? String ?? metadata["name"] as! String, parents: old?["parents"] as? [String] ?? metadata["parents"] as? [String] ?? [], folder: false, bytes: request.httpBody)
            return try reply(200, items[id]!.meta)
        case ("PATCH", _) where path.hasPrefix("/upload/drive/v3/files/"):
            let id = String(path.dropFirst("/upload/drive/v3/files/".count))
            guard let old = items[id]?.meta else { return try reply(404) }
            put(id, name: old["name"] as! String, parents: old["parents"] as! [String], folder: false, bytes: request.httpBody)
            return try reply(200, items[id]!.meta)
        case ("GET", _) where path.hasPrefix("/drive/v3/files/"):
            guard let item = items[url.lastPathComponent] else { return try reply(404) }
            return query["alt"] == "media" ? try reply(200, item.bytes ?? Data()) : try reply(200, item.meta)
        default: return try reply(400)
        }
    }

    /// The metadata and bytes of a `multipart/related` create.
    static func multipart(_ request: URLRequest) throws -> ([String: Any], Data) {
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type")), body = try XCTUnwrap(request.httpBody)
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        let gap = Data("\r\n\r\n".utf8), next = Data("\r\n--\(boundary)\r\n".utf8), end = Data("\r\n--\(boundary)--".utf8)
        let jsonStart = try XCTUnwrap(body.range(of: gap)).upperBound, jsonEnd = try XCTUnwrap(body.range(of: next, in: jsonStart..<body.endIndex))
        let bytesStart = try XCTUnwrap(body.range(of: gap, in: jsonEnd.upperBound..<body.endIndex)).upperBound
        let bytesEnd = try XCTUnwrap(body.range(of: end, options: .backwards)).lowerBound
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: body[jsonStart..<jsonEnd.lowerBound]) as? [String: Any]), Data(body[bytesStart..<bytesEnd]))
    }
}

@MainActor
final class DriveProviderTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() { folders.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func provider(_ drive: FakeDrive, id: String = "sub-a", window: TimeInterval = 15) -> DriveProvider {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("drive-cache-" + UUID().uuidString)
        folders.append(cache)
        return DriveProvider(account: .init(refresh: "refresh", id: id, email: "a@example.com"), cache: cache, transport: drive.transport,
                             poll: .seconds(3600), backoff: 0.01, window: window)
    }

    /// Writes make the root (`appProperties.bandalRoot = "2"`) and folders, and read back as written.
    func testWritesMakeTheRootAndReadBack() async throws {
        let drive = FakeDrive(), a = provider(drive, window: 0), log = "log/aaaaaaaa-0000-4000-8000-000000000001/00000001.json"
        let empty = try await a.list()
        XCTAssertEqual(empty, [:])
        try await a.write(.data(Data(#"{"format":2}"#.utf8)), to: "bandal.json")
        try await a.write(.data(Data("[]".utf8)), to: log)
        let root = try XCTUnwrap(drive.ids(named: "Bandal").first)
        XCTAssertEqual(drive.meta(root)?["appProperties"] as? [String: String], ["bandalRoot": "2"])
        let other = provider(drive), listed = try await other.list()
        XCTAssertEqual(Set(listed.keys), ["bandal.json", log])
        XCTAssertTrue(listed.values.allSatisfy(\.local), "text files are downloaded while listing")
        XCTAssertEqual(try other.read(log), Data("[]".utf8))
        // Rewriting a file of this device replaces it in place.
        try await a.write(.data(Data("[1]".utf8)), to: "bandal.json")
        XCTAssertEqual(drive.ids(named: "bandal.json").count, 1)
        _ = try await other.list()
        XCTAssertEqual(try other.read("bandal.json"), Data("[1]".utf8))
    }

    /// What Drive no longer has (removed or trashed elsewhere) leaves the listing with the next change.
    func testRemovedFilesLeaveTheListing() async throws {
        let drive = FakeDrive(), a = provider(drive, window: 0)
        try await a.write(.data(Data("1".utf8)), to: "log/a.json")
        try await a.write(.data(Data("2".utf8)), to: "log/b.json")
        let other = provider(drive)
        _ = try await other.list()
        drive.remove(try XCTUnwrap(drive.ids(named: "a.json").first))
        let listed = try await other.list()
        XCTAssertEqual(Set(listed.keys), ["log/b.json"])
    }

    /// Folders of one name (two devices made one at once) read as one; writes go to the oldest.
    func testSameNameFoldersReadAsOneAndWritesGoToTheOldest() async throws {
        let drive = FakeDrive()
        drive.add("root", name: "Bandal", parent: "my-drive", folder: true, root: true)
        drive.add("log1", name: "log", parent: "root", folder: true)
        drive.add("log2", name: "log", parent: "root", folder: true)
        drive.add("f1", name: "a.json", parent: "log1", bytes: Data("1".utf8))
        drive.add("f2", name: "b.json", parent: "log2", bytes: Data("2".utf8))
        let a = provider(drive)
        let listed = try await a.list()
        XCTAssertEqual(Set(listed.keys), ["log/a.json", "log/b.json"])
        try await a.write(.data(Data("3".utf8)), to: "log/c.json")
        let made = try XCTUnwrap(drive.ids(named: "c.json").first)
        XCTAssertEqual(drive.meta(made)?["parents"] as? [String], ["log1"])
    }

    /// The root is the oldest folder made as one that holds bandal.json (design appendix C).
    func testTheRootIsTheOldestThatHoldsBandalJSON() async throws {
        let drive = FakeDrive()
        drive.add("empty", name: "Bandal", parent: "my-drive", folder: true, root: true)
        drive.add("used", name: "Bandal", parent: "my-drive", folder: true, root: true)
        drive.add("later", name: "Bandal", parent: "my-drive", folder: true, root: true)
        drive.add("plain", name: "Bandal", parent: "my-drive", folder: true)
        drive.add("b1", name: "bandal.json", parent: "used", bytes: Data("{}".utf8))
        drive.add("b2", name: "bandal.json", parent: "later", bytes: Data("{}".utf8))
        drive.add("x", name: "x.json", parent: "later", bytes: Data("{}".utf8))
        let listed = try await provider(drive).list()
        XCTAssertEqual(Set(listed.keys), ["bandal.json"])
        try await provider(drive).write(.data(Data("[]".utf8)), to: "log/x.json")
        XCTAssertEqual(drive.meta(try XCTUnwrap(drive.ids(named: "log").first))?["parents"] as? [String], ["used"])
    }

    /// A root made by another app of the project carries `appProperties` this app cannot see; a
    /// top-level "Bandal" folder holding bandal.json is still the root.
    func testARootMadeByAnotherAppIsFound() async throws {
        let drive = FakeDrive()
        drive.add("desktop", name: "Bandal", parent: "my-drive", folder: true)
        drive.add("b1", name: "bandal.json", parent: "desktop", bytes: Data("{}".utf8))
        let a = provider(drive)
        let listed = try await a.list()
        XCTAssertEqual(Set(listed.keys), ["bandal.json"])
        try await a.write(.data(Data("[]".utf8)), to: "log/x.json")
        XCTAssertEqual(drive.ids(named: "Bandal"), ["desktop"], "no second root")
    }

    /// A create sent again after it went through (the id was made ahead) is the same file;
    /// a file under that id with other bytes is a conflict.
    func testACreateSentTwiceMakesOneFile() async throws {
        let drive = FakeDrive(), a = provider(drive)
        // Ids so far: g1 the root, g2 the folder, g3 the file; the next create takes g4.
        try await a.write(.data(Data("{}".utf8)), to: "log/0.json")
        let bytes = Data("[]".utf8)
        drive.add("g4", name: "00000001.json", parent: nil, bytes: bytes)
        try await a.write(.data(bytes), to: "log/00000001.json")
        XCTAssertEqual(drive.ids(named: "00000001.json"), ["g4"])
        drive.add("g5", name: "00000002.json", parent: nil, bytes: Data("other".utf8))
        do { try await a.write(.data(bytes), to: "log/00000002.json"); XCTFail("other bytes under the id") } catch {}
    }

    /// A 401 renews the access token once; rate limits and server errors back off and retry.
    func testAnExpiredTokenIsRenewedAndBusyAnswersAreRetried() async throws {
        let drive = FakeDrive(), a = provider(drive)
        drive.failures = [("/drive/v3/changes/startPageToken", "GET", 401, ""), ("/drive/v3/files", "GET", 429, ""),
                          ("/drive/v3/files", "GET", 500, ""), ("/drive/v3/files", "GET", 403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#)]
        let listed = try await a.list()
        XCTAssertEqual(listed, [:])
        XCTAssertEqual(drive.tokens, 2)
        drive.failures = [("/drive/v3/changes", "GET", 403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#)]
        do { _ = try await a.list(); XCTFail("a refusal is not retried") } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "DRIVE_403") }
        drive.failures = [("/token", "POST", 400, #"{"error":"invalid_grant"}"#), ("/drive/v3/changes", "GET", 401, "")]
        do { _ = try await a.list(); XCTFail("signed out") } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_DRIVE_SIGNED_OUT") }
    }

    /// Rewrites of one file wait out the window unless hurried (design §1.4).
    func testRewritesWaitForTheWindowUnlessHurried() async throws {
        let drive = FakeDrive(), a = provider(drive, window: 0.5)
        try await a.write(.data(Data("1".utf8)), to: "log/x.json")
        var start = Date()
        try await a.write(.data(Data("2".utf8)), to: "log/x.json")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.4)
        await a.hurry()
        start = Date()
        try await a.write(.data(Data("3".utf8)), to: "log/x.json")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
    }

    /// PDFs and assets come down after the listing and are listed as here once they land; big
    /// ones go up in a resumable upload.
    func testBlobsDownloadAfterTheListingAndLargeOnesUploadResumably() async throws {
        let drive = FakeDrive(), a = provider(drive)
        let large = Data(repeating: 7, count: 5 << 20), sha = SyncFormat.sha256(large)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drive-large-" + UUID().uuidString)
        folders.append(file)
        try large.write(to: file)
        try await a.write(.file(file), to: "pdf/\(sha).pdf")
        XCTAssertTrue(drive.calls.contains { $0.method == "PUT" })
        let b = provider(drive)
        var changes = b.changes.makeAsyncIterator()
        let before = try await b.list()
        XCTAssertEqual(before["pdf/\(sha).pdf"]?.local, false)
        _ = await changes.next()
        let after = try await b.list()
        XCTAssertEqual(after["pdf/\(sha).pdf"]?.local, true)
        XCTAssertEqual(try b.read("pdf/\(sha).pdf"), large)
    }

    /// Two iPads through one Drive with the real loop: courses, notes, PDFs and ink.
    func testTwoIPadsSyncThroughOneDrive() async throws {
        let drive = FakeDrive()
        func device() async throws -> (DesktopRuntime, CloudSyncEngine) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-device-" + UUID().uuidString)
            folders.append(root)
            let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            try await runtime.start()
            let box = Box(), keys = SyncStore.Keychain(read: { box.items[$0] }, write: { box.items[$0] = $1 })
            try await runtime.withSyncStorage { context, _ in try SyncStore(context: context, keychain: keys).setProvider("drive") }
            return (runtime, CloudSyncEngine(runtime: runtime, provider: provider(drive), keychain: keys))
        }
        let (a, sender) = try await device(), (b, receiver) = try await device()
        let course = (try await a.invokePrivate("courses:create", request: ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invokePrivate("notes:write", request: ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        let paper = (try await a.invokePrivate("pdfNotes:create", request: ["courseId": course, "title": "1주차", "paper": "blank"]) as! [String: Any])["relPath"] as! String
        let binding = try await a.invokePrivate("nativePDF:binding", request: ["courseId": course, "relPath": paper]) as! [String: Any]
        _ = try await a.invokePrivate("drawings:create", request: ["courseId": course, "relPath": paper, "page": 1, "kind": "ink", "documentRevision": binding["documentRevision"]!,
                                                                   "clientMutationId": UUID().uuidString, "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.4, "t": 0.0], ["x": 0.6, "y": 0.5, "p": 0.8, "t": 20.0]]],
                                                                   "style": ["color": "blue", "width": 0.003, "opacity": 1.0]])
        await sender.syncNow()
        XCTAssertEqual(sender.status["phase"] as? String, "idle")
        // The PDF lands after the first listing; the engine takes it on a later cycle.
        var placed = false
        for _ in 0..<40 where !placed {
            await receiver.syncNow()
            let courses = try await b.invokePrivate("courses:list", request: [:]) as! [[String: Any]]
            if let other = courses.first(where: { $0["name"] as? String == "물리" })?["id"] as? String {
                placed = (try? await b.readMaterial(courseID: other, relativePath: paper)) != nil
                if placed {
                    let note = try await b.invokePrivate("notes:read", request: ["courseId": other, "relPath": "요약.md"]) as? [String: Any]
                    XCTAssertEqual(note?["markdown"] as? String, "# 힘\n")
                    // Ink waits for its PDF and comes in on the same or the next cycle.
                    var ink = try await b.invokePrivate("drawings:listForFile", request: ["courseId": other, "relPath": paper]) as? [[String: Any]]
                    if ink?.isEmpty != false { await receiver.syncNow(); ink = try await b.invokePrivate("drawings:listForFile", request: ["courseId": other, "relPath": paper]) as? [[String: Any]] }
                    XCTAssertEqual(ink?.count, 1)
                }
            }
            if !placed { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(placed)
    }

    private final class Box { var items: [String: String] = [:] }
}
