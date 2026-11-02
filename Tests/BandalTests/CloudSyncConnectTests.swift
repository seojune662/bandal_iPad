import XCTest
@testable import Bandal

/// Settings › 동기화 through `CloudSyncService` with a folder for iCloud Drive (design §4.2–4.4):
/// a new root, joining one that holds data (merge, overwrite, a new profile), another Apple ID,
/// a removed root and the device name.
@MainActor
final class CloudSyncConnectTests: XCTestCase {
    fileprivate final class Box { var items: [String: String] = [:] }

    /// A folder whose writes fail while `fails` is set, and whose `pending` files are still downloading.
    fileprivate final class Failing: FolderProvider, @unchecked Sendable {
        var fails = false, pending = Set<String>()
        override func write(_ content: SyncOutbox.Content, to path: String) async throws {
            if fails { throw DesktopRuntimeError("write failed", code: "IO") }
            try await super.write(content, to: path)
        }
        override func list() async throws -> [String: SyncRemoteFile] {
            var files = try await super.list()
            for path in pending { files[path] = files[path].map { SyncRemoteFile(version: $0.version, local: false) } }
            return files
        }
    }

    @MainActor fileprivate final class Device {
        let documents: URL, store: NativeWorkspaceStore, service: CloudSyncService
        var failing: Failing?
        var account = "account-a"

        /// Signing in to Google gives this account; sign-ins are counted, with the account each one offered first.
        var google: GoogleDriveAuth.Account? = .init(refresh: "refresh-a", id: "google-a", email: "a@example.com")
        var signIns = 0, hints: [String?] = []
        let keychain: Box

        init(cloud: URL, documents: URL? = nil, root name: String = "BandalDesktop", keychain box: Box = Box()) async throws {
            self.documents = documents ?? FileManager.default.temporaryDirectory.appendingPathComponent("sync-connect-" + UUID().uuidString)
            keychain = box
            let root = self.documents.appendingPathComponent(name)
            store = NativeWorkspaceStore(storageRoot: root)
            await store.start()
            XCTAssertTrue(store.isReady, store.errorMessage ?? "store")
            service = CloudSyncService(store: store, profile: DesktopProfileService(documents: self.documents, root: root))
            service.environment = .init(locate: { (cloud, "account") }, provider: { FolderProvider(root: $0) },
                                        keychain: .init(read: { box.items[$0] }, write: { box.items[$0] = $1 }))
            service.environment.provider = { [unowned self] root in
                guard let failing, failing.root == root else { return FolderProvider(root: root) }
                return failing
            }
            setAccount(account, cloud: cloud)
        }
        /// Google Drive in memory, one per Google account id.
        func useDrive(_ drives: [String: FakeDrive]) {
            let cache = documents.appendingPathComponent("drive-cache", isDirectory: true)
            service.environment.signIn = { [unowned self] hint in signIns += 1; hints.append(hint); return google }
            service.environment.drive = { DriveProvider(account: $0, cache: cache, transport: drives[$0.id]!.transport, poll: .seconds(3600), backoff: 0.01, window: 0) }
        }
        func setAccount(_ name: String, cloud: URL) {
            account = name
            service.environment.locate = { (cloud, name) }
        }
        func sync(_ channel: String, _ request: [String: Any] = [:]) async throws -> [String: Any] {
            let value = try await service.handle(channel, request)
            return try XCTUnwrap(value as? [String: Any])
        }
        func invoke(_ channel: String, _ request: [String: Any] = [:]) async throws -> Any { try await store.runtime.invokePrivate(channel, request: request) }
        /// This device's sync store, read or changed on the storage queue.
        func syncStore<T>(_ work: @escaping (SyncStore) throws -> T) async throws -> T {
            let box = keychain
            return try await store.runtime.withSyncStorage { context, _ in try work(SyncStore(context: context, keychain: .init(read: { box.items[$0] }, write: { box.items[$0] = $1 }))) }
        }
        /// The device log, as `<event> channel=<c> code=<c>` lines.
        func logLines() async -> [String] {
            await store.runtime.log.flush()
            let text = try? String(contentsOf: store.runtime.root.appendingPathComponent("Logs/bandal.log"), encoding: .utf8)
            return (text ?? "").split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        }
        func course(_ name: String) async throws -> [String: Any]? {
            (try await invoke("courses:list") as! [[String: Any]]).first { $0["name"] as? String == name }
        }
        func files(_ course: String) async throws -> [String] {
            _ = try await invoke("materials:tree", ["courseId": course])
            return try await store.runtime.withSyncStorage { context, _ in
                try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL ORDER BY rel_path", [course]).compactMap { $0["rel_path"] as? String }
            }
        }
        func stroke(_ course: String, _ path: String, x: Double = 0.2) async throws -> String {
            let binding = try await invoke("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any]
            let created = try await invoke("drawings:create", ["courseId": course, "relPath": path, "page": 1, "kind": "ink", "documentRevision": binding["documentRevision"]!,
                                                               "clientMutationId": UUID().uuidString, "data": ["inkVersion": 5, "points": [["x": x, "y": 0.3, "p": 0.4, "t": 0.0], ["x": 0.6, "y": 0.5, "p": 0.8, "t": 20.0]]],
                                                               "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]) as! [String: Any]
            return created["id"] as! String
        }
        func image(_ course: String, _ path: String) async throws -> String {
            _ = try? await invoke("materials:createFolder", ["courseId": course, "dirRelPath": "", "name": "assets"])
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            _ = try await invoke("materials:writeFile", ["courseId": course, "dirRelPath": "assets", "fileName": "p.png", "encoding": "base64", "data": png.base64EncodedString()])
            let binding = try await invoke("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any]
            let created = try await invoke("drawings:create", ["courseId": course, "relPath": path, "page": 1, "kind": "image", "documentRevision": binding["documentRevision"]!,
                                                               "clientMutationId": UUID().uuidString, "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.2], "image": ["relPath": "assets/p.png", "label": "사진", "widthPx": 1, "heightPx": 1]],
                                                               "style": ["color": "ink", "width": 0.002, "opacity": 1.0]]) as! [String: Any]
            return created["id"] as! String
        }
        func logEvents(_ cloud: URL) throws -> Int {
            let logs = try FileManager.default.subpathsOfDirectory(atPath: cloud.path).filter { $0.hasPrefix("log/") && $0.hasSuffix(".json") }
            return try logs.map { try (JSONSerialization.jsonObject(with: Data(contentsOf: cloud.appendingPathComponent($0))) as? [Any])?.count ?? 0 }.reduce(0, +)
        }
        func ink(_ course: String, _ path: String) async throws -> Set<String> {
            Set((try await invoke("drawings:listForFile", ["courseId": course, "relPath": path]) as! [[String: Any]]).compactMap { $0["id"] as? String })
        }
        func pdf(_ course: String, named title: String, bytes: Data? = nil, folder: String = "") async throws -> String {
            guard let bytes else { return (try await invoke("pdfNotes:create", ["courseId": course, "title": title, "paper": "blank"]) as! [String: Any])["relPath"] as! String }
            if !folder.isEmpty { _ = try? await invoke("materials:createFolder", ["courseId": course, "dirRelPath": "", "name": folder]) }
            let written = try await invoke("materials:writeFile", ["courseId": course, "dirRelPath": folder, "fileName": title + ".pdf", "encoding": "base64", "data": bytes.base64EncodedString()]) as! [String: Any]
            return written["relPath"] as! String
        }
        deinit { try? FileManager.default.removeItem(at: documents) }
    }

    private var cloud: URL!
    override func setUp() { cloud = FileManager.default.temporaryDirectory.appendingPathComponent("sync-connect-cloud-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: cloud) }

    private func newCourse(_ device: Device, _ name: String, color: String = "blue") async throws -> String {
        (try await device.invoke("courses:create", ["name": name, "color": color]) as! [String: Any])["id"] as! String
    }

    func testAnEmptyRootIsFilledAndAnotherIPadJoinsIt() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리")
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        let first = try await a.sync("cloudSync:preview")
        XCTAssertEqual(first["empty"] as? Bool, true)
        XCTAssertEqual((first["local"] as? [String: Any])?["courses"] as? Int, 1)
        let on = try await a.sync("cloudSync:connect", ["mode": "start"])
        XCTAssertEqual(on["provider"] as? String, "icloud")
        _ = try await a.sync("cloudSync:syncNow")
        let seen = try await b.sync("cloudSync:preview")
        XCTAssertEqual(seen["empty"] as? Bool, false)
        XCTAssertEqual((seen["cloud"] as? [String: Any])?["courses"] as? Int, 1)
        XCTAssertEqual((seen["cloud"] as? [String: Any])?["documents"] as? Int, 1)
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []])
        _ = try await b.sync("cloudSync:syncNow")
        let joined = try await b.course("물리"), other = try XCTUnwrap(joined)["id"] as! String
        let note = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(note["markdown"] as? String, "# 힘\n")
    }

    /// Spec v2.6: while another device fills the root, the sheet only says so and nothing connects. It is
    /// told from the mark and that device's file before the rest of the root is down: written within the
    /// hour, or, with no file yet, a mark from the last five minutes (2026-11-02). Once stopped, the root
    /// can be merged or taken, not overwritten. Each wait and refusal goes into the device log.
    func testAnotherDevicesFirstUploadIsWaitedForThenOnlyMerged() async throws {
        let other = "cccccccc-0000-4000-8000-000000000003", now = Date().timeIntervalSince1970, device = "devices/\(other).json"
        func ms(minutesAgo: Double) -> Int64 { Int64((now - minutesAgo * 60) * 1000) }
        func mark(minutesAgo: Double) throws {
            try Data(#"{"format":2,"initial_upload":"\#(other)","started":\#(ms(minutesAgo: minutesAgo))}"#.utf8).write(to: cloud.appendingPathComponent("bandal.json"))
        }
        func seen(minutesAgo: Double) throws { try SyncOutbox.deviceFile(name: "Mac", lastSeen: ms(minutesAgo: minutesAgo)).write(to: cloud.appendingPathComponent(device)) }
        func uploading(_ b: Device) async throws -> [String: AnyHashable]? { try await b.sync("cloudSync:preview")["initialUpload"] as? [String: AnyHashable] }
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("log/\(other)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("devices"), withIntermediateDirectories: true)
        try mark(minutesAgo: 1)
        let b = try await Device(cloud: cloud)
        _ = try await newCourse(b, "화학")
        let begun = try await uploading(b)
        XCTAssertEqual(begun, ["device": "cccccccc", "going": true], "no device file yet, a mark just made")
        try seen(minutesAgo: 1)
        try Data("[]".utf8).write(to: cloud.appendingPathComponent("log/\(other)/00000001.json"))
        b.failing = Failing(root: cloud); b.failing?.pending = ["log/\(other)/00000001.json"]
        let going = try await b.sync("cloudSync:preview")
        XCTAssertEqual(going["initialUpload"] as? [String: AnyHashable], ["device": "Mac", "going": true], "a file still coming down does not hide it")
        XCTAssertNil(going["sameName"], "no connection sheet")
        do { _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); XCTFail("connected") } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_INITIAL_UPLOAD") }
        b.failing?.pending.insert(device)
        let unknown = try await b.sync("cloudSync:preview")
        XCTAssertNil(unknown["initialUpload"], "its device file still coming down: not decided")
        XCTAssertNotNil(unknown["downloading"])
        b.failing?.pending = []
        try seen(minutesAgo: -61)
        let ahead = try await uploading(b)
        XCTAssertEqual(ahead, ["device": "Mac", "going": false], "a clock more than an hour ahead")
        try FileManager.default.removeItem(at: cloud.appendingPathComponent(device))
        try mark(minutesAgo: 6)
        let old = try await uploading(b)
        XCTAssertEqual(old, ["device": "cccccccc", "going": false], "no device file, a mark older than five minutes")
        try seen(minutesAgo: 120)
        let stopped = try await b.sync("cloudSync:preview")
        XCTAssertEqual(stopped["initialUpload"] as? [String: AnyHashable], ["device": "Mac", "going": false])
        do {
            _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": [], "fingerprint": stopped["fingerprint"]!]); XCTFail("overwrote")
        } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_INITIAL_UPLOAD") }
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []])
        let synced = try await b.sync("cloudSync:syncNow")
        XCTAssertEqual(synced["phase"] as? String, "idle")
        let log = await b.logLines()
        XCTAssertTrue(log.contains("sync.preview channel=icloud code=uploading"), "\(log)")
        XCTAssertTrue(log.contains("sync.preview.root channel=icloud code=entries:3:bandal_json:1:initial_upload:\(other)"), "\(log)")
        XCTAssertTrue(log.contains("sync.preview channel=icloud code=downloading"), "\(log)")
        XCTAssertEqual(log.filter { $0 == "sync.connect channel=icloud code=SYNC_INITIAL_UPLOAD" }.count, 2, "\(log)")
    }

    /// A merge joins the checked same-name course and the PDF both hold: one course and one document
    /// everywhere, the cloud's course values, and the ink of both sides on that PDF.
    func testMergeJoinsSameNameCoursesAndTheSamePDF() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리", color: "blue")
        let paper = try await a.pdf(course, named: "1주차")
        let theirs = try await a.stroke(course, paper)
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let mine = try await newCourse(b, "물리", color: "pink")
        let bytes = try await a.store.runtime.readMaterial(courseID: course, relativePath: paper)
        let copy = try await b.pdf(mine, named: "강의 1주차", bytes: bytes)
        let ours = try await b.stroke(mine, copy, x: 0.7)
        let preview = try await b.sync("cloudSync:preview")
        let pairs = try XCTUnwrap(preview["sameName"] as? [[String: Any]])
        XCTAssertEqual(pairs.count, 1); XCTAssertEqual(pairs.first?["matched"] as? Int, 1)
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": pairs.map { ["local": $0["local"]!, "remote": $0["remote"]!] }])
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow"); _ = try await b.sync("cloudSync:syncNow")
        let courses = (try await a.invoke("courses:list") as! [[String: Any]]).filter { $0["name"] as? String == "물리" }
        XCTAssertEqual(courses.count, 1, "one course")
        let adopted = try await b.course("물리"), documents = try await a.files(course)
        XCTAssertEqual(adopted?["color"] as? String, "blue", "the cloud's values")
        XCTAssertEqual(documents, [paper], "one document")
        let onA = try await a.ink(course, paper), onB = try await b.ink(mine, copy)
        XCTAssertEqual(onA, [theirs, ours]); XCTAssertEqual(onB, [theirs, ours])
    }

    /// A PDF added here while the sheet was open is joined too: connecting scans the courses again.
    func testAPDFAddedWhileTheSheetIsOpenIsStillJoined() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리"), paper = try await a.pdf(course, named: "1주차")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let mine = try await newCourse(b, "물리")
        let preview = try await b.sync("cloudSync:preview"), pairs = try XCTUnwrap(preview["sameName"] as? [[String: Any]])
        _ = try await b.pdf(mine, named: "강의", bytes: try await a.store.runtime.readMaterial(courseID: course, relativePath: paper))
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": pairs.map { ["local": $0["local"]!, "remote": $0["remote"]!] }])
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let documents = try await a.files(course)
        XCTAssertEqual(documents, [paper], "one document")
    }

    /// An overwrite keeps this iPad's data and deletes elsewhere what only the cloud had: a course,
    /// a document, and ink on the PDF both hold. Files stay in the root.
    func testOverwriteDeletesWhatOnlyTheCloudHad() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리"), chemistry = try await newCourse(a, "화학")
        let paper = try await a.pdf(course, named: "1주차"), extra = try await a.pdf(course, named: "2주차")
        let theirs = try await a.stroke(course, paper)
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let mine = try await newCourse(b, "물리"), _ = try await newCourse(b, "생물")
        let copy = try await b.pdf(mine, named: "1주차", bytes: try await a.store.runtime.readMaterial(courseID: course, relativePath: paper), folder: "노트")
        XCTAssertEqual(copy, paper)
        let ours = try await b.stroke(mine, copy, x: 0.7)
        let preview = try await b.sync("cloudSync:preview")
        let pairs = try XCTUnwrap(preview["sameName"] as? [[String: Any]])
        let before = try FileManager.default.subpathsOfDirectory(atPath: cloud.path).filter { $0.hasPrefix("pdf/") }.count
        _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": pairs.map { ["local": $0["local"]!, "remote": $0["remote"]!] }, "fingerprint": preview["fingerprint"]!])
        let local = try await b.course("물리")
        XCTAssertEqual(local?["id"] as? String, mine)
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let removed = try await a.course("화학"), arrived = try await a.course("생물"), kept = try await a.course("물리")
        XCTAssertNil(removed, "deleted"); XCTAssertNotNil(arrived, "this iPad's course arrived"); XCTAssertNotNil(kept)
        let documents = try await a.files(course), ink = try await a.ink(course, paper), applied = try await b.course("화학")
        XCTAssertFalse(documents.contains(extra), "the document only the cloud had is deleted")
        XCTAssertEqual(ink, [ours], "the cloud's ink on the shared PDF is deleted")
        XCTAssertNil(applied, "nothing of the cloud's was applied on the overwriting iPad")
        XCTAssertGreaterThanOrEqual(try FileManager.default.subpathsOfDirectory(atPath: cloud.path).filter { $0.hasPrefix("pdf/") }.count, before, "files stay")
        _ = chemistry; _ = theirs
    }

    /// A root this iPad filled and that is empty now is not taken as everything deleted: sync pauses
    /// until the user fills it again, and then everything goes out once more.
    func testARemovedRootPausesUntilItIsMadeAgain() async throws {
        let a = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리")
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        try FileManager.default.removeItem(at: cloud)
        let paused = try await a.sync("cloudSync:syncNow")
        XCTAssertEqual(paused["phase"] as? String, "paused"); XCTAssertEqual(paused["reason"] as? String, "root-missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.path), "nothing written")
        let still = try await a.course("물리")
        XCTAssertNotNil(still, "nothing deleted here")
        _ = try await a.sync("cloudSync:recreateRoot")
        let b = try await Device(cloud: cloud)
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        let joined = try await b.course("물리"), other = try XCTUnwrap(joined)["id"] as! String
        let note = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(note["markdown"] as? String, "# 힘\n")
    }

    /// An overwrite that never went out is dropped with its connection: a later merge sends no deletes (review HIGH).
    func testAnUnsentOverwriteDiesWithItsConnection() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리"); _ = try await newCourse(a, "화학")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await newCourse(b, "생물")
        b.failing = Failing(root: cloud); b.failing?.fails = true
        let preview = try await b.sync("cloudSync:preview")
        _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": [], "fingerprint": preview["fingerprint"]!])
        let failed = try await b.sync("cloudSync:syncNow")
        XCTAssertEqual(failed["phase"] as? String, "error")
        _ = try await b.sync("cloudSync:disconnect")
        b.failing?.fails = false
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []])
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let physics = try await a.course("물리"), chemistry = try await a.course("화학"), biology = try await a.course("생물")
        XCTAssertNotNil(physics); XCTAssertNotNil(chemistry); XCTAssertNotNil(biology)
    }

    /// Cloud images on a PDF both hold are understood here, so an overwrite deletes them like strokes
    /// instead of failing the connection (review MEDIUM).
    func testOverwriteDeletesCloudImagesOnASharedPDF() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리"), paper = try await a.pdf(course, named: "1주차")
        let picture = try await a.image(course, paper)
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let mine = try await newCourse(b, "물리")
        _ = try await b.pdf(mine, named: "1주차", bytes: try await a.store.runtime.readMaterial(courseID: course, relativePath: paper), folder: "노트")
        let preview = try await b.sync("cloudSync:preview"), pairs = try XCTUnwrap(preview["sameName"] as? [[String: Any]])
        XCTAssertEqual(pairs.first?["ink"] as? Int, 1)
        _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": pairs.map { ["local": $0["local"]!, "remote": $0["remote"]!] }, "fingerprint": preview["fingerprint"]!])
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let ink = try await a.ink(course, paper)
        XCTAssertFalse(ink.contains(picture))
    }

    /// An overwrite sends this iPad's values again whole: a course the cloud deleted while this iPad
    /// was away comes back everywhere instead of being deleted here (review MEDIUM).
    func testOverwriteBringsBackWhatTheCloudDeletedMeanwhile() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:disconnect")
        _ = try await a.invoke("courses:delete", ["courseId": course]); _ = try await a.sync("cloudSync:syncNow")
        let preview = try await b.sync("cloudSync:preview")
        _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": [], "fingerprint": preview["fingerprint"]!])
        _ = try await b.sync("cloudSync:syncNow"); _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let here = try await b.course("물리"), there = try await a.course("물리")
        XCTAssertNotNil(here, "kept on the overwriting iPad"); XCTAssertNotNil(there, "back on the other iPad")
    }

    /// Back on an Apple ID whose root holds this iPad's courses from before: they are joined by id,
    /// neither copied here nor deleted there (review MEDIUM).
    func testReturningToAnEarlierRootJoinsThisIPadsOwnCourses() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("sync-connect-other-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: other) }
        a.setAccount("account-b", cloud: other)
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        a.setAccount("account-a", cloud: cloud)
        let preview = try await a.sync("cloudSync:preview"), pairs = try XCTUnwrap(preview["sameName"] as? [[String: Any]])
        XCTAssertEqual(pairs.map { $0["fixed"] as? Bool }, [true])
        _ = try await a.sync("cloudSync:connect", ["mode": "overwrite", "pairs": [], "fingerprint": preview["fingerprint"]!])
        _ = try await a.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let courses = (try await a.invoke("courses:list") as! [[String: Any]]).filter { $0["name"] as? String == "물리" }
        XCTAssertEqual(courses.count, 1, "not copied here")
        let status = try await a.sync("cloudSync:status")
        XCTAssertEqual(status["phase"] as? String, "idle", "\(status)")
        let b = try await Device(cloud: cloud)
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        let there = try await b.course("물리")
        XCTAssertNotNil(there, "not deleted there")
    }

    /// A root restored with this iPad's files (Recently Deleted) just resumes when the user asks to
    /// make it again: nothing is sent twice (review MEDIUM).
    func testMakingAgainARestoredRootJustResumes() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let aside = cloud.deletingLastPathComponent().appendingPathComponent("aside-" + UUID().uuidString)
        try FileManager.default.moveItem(at: cloud, to: aside)
        let paused = try await a.sync("cloudSync:syncNow")
        XCTAssertEqual(paused["reason"] as? String, "root-missing")
        try FileManager.default.moveItem(at: aside, to: cloud)
        let before = try a.logEvents(cloud)
        let resumed = try await a.sync("cloudSync:recreateRoot")
        XCTAssertEqual(resumed["phase"] as? String, "idle")
        XCTAssertEqual(try a.logEvents(cloud), before, "nothing sent again")
    }

    /// An overwrite deletes only what its sheet showed: a root that changed since is refused (review MEDIUM).
    func testAnOverwriteOfARootThatChangedIsRefused() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let preview = try await b.sync("cloudSync:preview")
        _ = try await newCourse(a, "화학"); _ = try await a.sync("cloudSync:syncNow")
        do {
            _ = try await b.sync("cloudSync:connect", ["mode": "overwrite", "pairs": [], "fingerprint": preview["fingerprint"]!])
            XCTFail("connected to a changed root")
        } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_ROOT_CHANGED") }
        let status = try await b.sync("cloudSync:status")
        XCTAssertNil(status["provider"])
    }

    func testTheDeviceNameGoesToItsDevicesFile() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"])
        let named = try await a.sync("cloudSync:setDeviceName", ["name": "공부 iPad"])
        XCTAssertEqual(named["deviceName"] as? String, "공부 iPad")
        _ = try await a.sync("cloudSync:syncNow")
        let devices = try FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("devices"), includingPropertiesForKeys: nil)
        let names = try devices.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }.compactMap { $0?["name"] as? String }
        XCTAssertEqual(names, ["공부 iPad"])
        do { _ = try await a.sync("cloudSync:setDeviceName", ["name": "  "]); XCTFail("empty name") } catch {}
    }

    /// Another Apple ID holds another root: sync pauses at start, and joining it goes through the sheet
    /// and forgets what was matched with the old root.
    func testAnotherAppleIDPausesUntilItsRootIsJoined() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await a.sync("cloudSync:disconnect")
        _ = try await a.store.runtime.withSyncStorage { context, _ in try SyncStore(context: context).setProvider("icloud") }
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("sync-connect-other-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: other) }
        a.setAccount("account-b", cloud: other)
        await a.service.start()
        let paused = try await a.sync("cloudSync:status")
        XCTAssertEqual(paused["reason"] as? String, "account-changed")
        let preview = try await a.sync("cloudSync:preview")
        XCTAssertEqual(preview["empty"] as? Bool, true)
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let logs = try FileManager.default.subpathsOfDirectory(atPath: other.path).filter { $0.hasPrefix("log/") && $0.hasSuffix(".json") }
        XCTAssertFalse(logs.isEmpty, "everything went out again into the new root")
        let text = try logs.map { try String(contentsOf: other.appendingPathComponent($0), encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("물리"))
    }

    /// 가져오기: a new profile connects on its first start and can go back to the profile it came from.
    func testImportStartsANewProfileThatConnectsOnItsFirstStart() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await a.sync("cloudSync:connect", ["mode": "import"])
        let pointer = try JSONDecoder().decode(DesktopProfileService.Selection.self, from: Data(contentsOf: a.documents.appendingPathComponent("active-profile.json")))
        let off = try await a.sync("cloudSync:status")
        XCTAssertNil(off["provider"], "this profile is off")
        let next = try await Device(cloud: cloud, documents: a.documents, root: pointer.rootName)
        await next.service.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.documents.appendingPathComponent(pointer.rootName + "/" + DesktopProfileService.syncConnect).path))
        let fresh = try await next.sync("cloudSync:status")
        XCTAssertEqual(fresh["previousProfile"] as? Bool, true)
        _ = try await next.sync("cloudSync:syncNow")
        let arrived = try await next.course("물리")
        XCTAssertNotNil(arrived, "the cloud's data arrived")
        _ = try await next.sync("cloudSync:returnToPrevious")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.documents.appendingPathComponent("active-profile.json").path), "back to BandalDesktop")
    }

    // MARK: Google Drive (design §1.4)

    /// Choosing Google Drive asks for the account first; a second iPad on that account joins the
    /// same root; turning it off forgets the account here (no revoke, which would sign out the
    /// other iPad too). No 반달 login anywhere.
    func testDriveAsksForTheAccountAndTurningOffForgetsIt() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        a.useDrive(drives); b.useDrive(drives)
        let course = try await newCourse(a, "물리")
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        let first = try await a.sync("cloudSync:preview", ["provider": "drive"])
        XCTAssertEqual(first["empty"] as? Bool, true)
        XCTAssertEqual(first["provider"] as? String, "drive")
        let on = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"])
        XCTAssertEqual(on["provider"] as? String, "drive")
        XCTAssertEqual(on["driveEmail"] as? String, "a@example.com")
        let made = await a.logLines()
        XCTAssertTrue(made.contains("sync.connect channel=drive code=new-root-folder"), "\(made)")
        _ = try await a.sync("cloudSync:syncNow")
        XCTAssertFalse(drives["google-a"]!.ids(named: "bandal.json").isEmpty)
        let seen = try await b.sync("cloudSync:preview", ["provider": "drive"])
        XCTAssertEqual((seen["cloud"] as? [String: Any])?["courses"] as? Int, 1)
        _ = try await b.sync("cloudSync:connect", ["provider": "drive", "mode": "merge", "pairs": []])
        let joinedLog = await b.logLines()
        XCTAssertFalse(joinedLog.contains { $0.hasPrefix("sync.connect") }, "b joins a's folder: \(joinedLog)")
        _ = try await b.sync("cloudSync:syncNow")
        let found = try await b.course("물리"), joined = try XCTUnwrap(found)["id"] as! String
        let note = try await b.invoke("notes:read", ["courseId": joined, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(note["markdown"] as? String, "# 힘\n")
        let off = try await a.sync("cloudSync:disconnect")
        XCTAssertNil(off["provider"])
        XCTAssertNil(off["driveEmail"])
        // b still syncs: nothing was revoked.
        _ = try await b.sync("cloudSync:syncNow")
        let still = try await b.sync("cloudSync:status")
        XCTAssertEqual(still["phase"] as? String, "idle")
        // Closing the Google sheet leaves sync off, and an account signed in but never joined is not kept.
        a.google = nil
        let cancelled = try await a.sync("cloudSync:preview", ["provider": "drive"])
        XCTAssertEqual(cancelled["available"] as? Bool, false)
        a.google = .init(refresh: "refresh-a2", id: "google-a", email: "a@example.com")
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        let unjoined = try await a.sync("cloudSync:status")
        XCTAssertNil(unjoined["driveEmail"], "kept only once the connection is made")
    }

    /// A Google account whose token stopped working is asked for again when Drive is chosen, and a
    /// profile with sync on but no account pauses until it is connected again.
    func testADeadGoogleTokenAsksAgain() async throws {
        let drive = FakeDrive(), a = try await Device(cloud: cloud)
        a.useDrive(["google-a": drive])
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        XCTAssertEqual(a.signIns, 1)
        drive.failures = [("/token", "POST", 400, #"{"error":"invalid_grant"}"#)]
        let again = try await a.sync("cloudSync:preview", ["provider": "drive"])
        XCTAssertEqual(a.signIns, 2)
        XCTAssertEqual(again["available"] as? Bool, true)
        a.google = nil
        drive.failures = [("/token", "POST", 400, #"{"error":"invalid_grant"}"#)]
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        await a.service.start()
        let paused = try await a.sync("cloudSync:status")
        XCTAssertEqual(paused["reason"] as? String, "drive-signed-out")
    }

    /// Joining iCloud lets the Google account of Drive sync go.
    func testMovingFromDriveToICloudForgetsTheGoogleAccount() async throws {
        let a = try await Device(cloud: cloud)
        a.useDrive(["google-a": FakeDrive()])
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await a.sync("cloudSync:preview")
        let icloud = try await a.sync("cloudSync:connect", ["mode": "start"])
        XCTAssertEqual(icloud["provider"] as? String, "icloud")
        XCTAssertNil(icloud["driveEmail"])
    }

    /// Another Google account is another root: sync pauses until that root is joined, and then
    /// everything goes out again into it (design §4.4).
    func testAnotherGoogleAccountPausesUntilItsRootIsJoined() async throws {
        let drives = ["google-a": FakeDrive(), "google-b": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        a.google = .init(refresh: "refresh-b", id: "google-b", email: "b@example.com")
        let paused = try await a.sync("cloudSync:signInDrive")
        XCTAssertEqual(paused["reason"] as? String, "account-changed")
        let preview = try await a.sync("cloudSync:preview", ["provider": "drive"])
        XCTAssertEqual(preview["empty"] as? Bool, true)
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        XCTAssertTrue(drives["google-b"]!.text(endingWith: ".json").contains("물리"), "everything went out again into the new root")
    }

    // MARK: Moving (spec v2.7)

    /// Looks at the other storage as the settings screen does, then moves there with the plan it showed.
    @discardableResult private func move(_ device: Device, to kind: String, expect: String, hint: String? = nil) async throws -> [String: Any] {
        var request: [String: Any] = ["provider": kind]
        if let hint { request["accountHint"] = hint }
        let prepared = try await device.sync("cloudSync:prepareMove", request)
        XCTAssertEqual(prepared["plan"] as? String, expect, "\(prepared)")
        return try await device.sync("cloudSync:move", ["provider": kind, "expect": expect])
    }

    private func iCloudFile(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cloud.appendingPathComponent(path))) as? [String: Any])
    }

    private func count(_ text: String, _ word: String) -> Int { text.components(separatedBy: word).count - 1 }

    /// A move fills the empty storage, stamped from the old root's clock, then tells the old root where it went.
    /// A device still there is offered to follow; following joins by id and sends only what the new root lacks.
    func testAMoveFillsTheEmptyStorageThenTellsTheOldOneAndAFollowerSendsOnlyWhatChanged() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        a.useDrive(drives); b.useDrive(drives)
        let physics = try await newCourse(a, "물리")
        let paper = try await a.pdf(physics, named: "역학")
        _ = try await a.stroke(physics, paper)
        _ = try await a.sync("cloudSync:setDeviceName", ["name": "iPad A"])
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        let quiet = try await b.sync("cloudSync:syncNow")
        XCTAssertNil(quiet["moved"])
        let clock = try await a.syncStore { try $0.clock() }

        let moving = try await move(a, to: "drive", expect: "upload")
        XCTAssertEqual(moving["provider"] as? String, "drive")
        let moved = try await a.sync("cloudSync:syncNow")
        XCTAssertNil(moved["moving"], "the old root was told and let go")
        let drive = drives["google-a"]!.text(endingWith: ".json")
        let stamps = try NSRegularExpression(pattern: #""t":([0-9]+)"#).matches(in: drive, range: NSRange(drive.startIndex..., in: drive)).map { Int64((drive as NSString).substring(with: $0.range(at: 1)))! }
        XCTAssertEqual(stamps.sorted(), [clock + 2, clock + 3], "the first upload goes on from the old root's clock (the stroke took clock + 1), not from now")
        XCTAssertFalse(drives["google-a"]!.text(endingWith: ".json.gz").isEmpty, "the ink went up too")
        let me = try await a.syncStore { try $0.deviceID() }
        let note = try XCTUnwrap(try iCloudFile("devices/\(me).json")["moved_to"] as? [String: Any])
        XCTAssertEqual(note["provider"] as? String, "drive")
        XCTAssertEqual(note["account_hint"] as? String, "a@example.com")
        XCTAssertGreaterThan((note["t"] as? NSNumber)?.int64Value ?? 0, clock)

        // b, still in iCloud, makes a course after a left, is offered to follow, and follows in one step.
        _ = try await newCourse(b, "생물")
        let offered = try await b.sync("cloudSync:syncNow")
        let offer = try XCTUnwrap(offered["moved"] as? [String: Any])
        XCTAssertEqual(offer["device"] as? String, "iPad A")
        XCTAssertEqual(offer["provider"] as? String, "drive")
        XCTAssertEqual(offer["account"] as? String, "a@example.com")
        let before = drives["google-a"]!.text(endingWith: ".json")
        try await move(b, to: "drive", expect: "join", hint: "a@example.com")
        XCTAssertEqual(b.hints, ["a@example.com"], "Google is asked for the account a moved to")
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let after = drives["google-a"]!.text(endingWith: ".json")
        XCTAssertEqual(count(after, "doc.upsert"), count(before, "doc.upsert"), "nothing both held goes up again")
        XCTAssertEqual(count(after, "course.upsert"), count(before, "course.upsert") + 1, "only 생물")
        let courses = try await a.invoke("courses:list") as! [[String: Any]]
        XCTAssertEqual(Set(courses.compactMap { $0["name"] as? String }), ["물리", "생물"])
        let followed = try await b.sync("cloudSync:status")
        XCTAssertEqual(followed["provider"] as? String, "drive")
        XCTAssertNil(followed["moved"], "the new root has no move in it")
        XCTAssertNil(followed["moving"])
    }

    /// The note's t is an event's (spec v2.7): past every t this iPad has seen, also from a device whose clock runs a
    /// day ahead, and so past the first upload's own stamps, which went on from that clock.
    func testAMoveIsToldAfterEveryTSeenEvenFromAClockADayAhead() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let ahead = Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000, other = "dddddddd-0000-4000-8000-000000000004"
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("log/\(other)"), withIntermediateDirectories: true)
        try Data(#"[{"t":\#(ahead),"op":"course.upsert","id":"c0000000-0000-4000-8000-000000000009","fields":{"name":"미래","sort":1,"color":"blue","archived":false}}]"#.utf8)
            .write(to: cloud.appendingPathComponent("log/\(other)/00000001.json"))
        _ = try await a.sync("cloudSync:syncNow")
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")
        let me = try await a.syncStore { try $0.deviceID() }
        let note = try XCTUnwrap(try iCloudFile("devices/\(me).json")["moved_to"] as? [String: Any])
        XCTAssertGreaterThan((note["t"] as? NSNumber)?.int64Value ?? 0, ahead + 1)
    }

    /// Following to a Drive that looks empty: the screen names the account signed in, and choosing the Google account
    /// again signs in once more, offering first the account the other device moved to.
    func testFollowingToADriveThatLooksEmptyCanChooseTheGoogleAccountAgain() async throws {
        let drives = ["google-a": FakeDrive(), "google-b": FakeDrive()], a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        a.useDrive(drives); b.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")

        b.google = .init(refresh: "refresh-b", id: "google-b", email: "b@example.com")
        let empty = try await b.sync("cloudSync:prepareMove", ["provider": "drive", "accountHint": "a@example.com"])
        XCTAssertEqual(empty["plan"] as? String, "upload", "another Google account's Drive")
        XCTAssertEqual(empty["account"] as? String, "b@example.com")
        b.google = .init(refresh: "refresh-a2", id: "google-a", email: "a@example.com")
        let found = try await b.sync("cloudSync:prepareMove", ["provider": "drive", "accountHint": "a@example.com", "signInAgain": true])
        XCTAssertEqual(found["plan"] as? String, "join")
        XCTAssertEqual(found["account"] as? String, "a@example.com")
        XCTAssertEqual(b.hints, ["a@example.com", "a@example.com"])
    }

    /// What another device changed in the old storage after the move (a rename, a deletion) wins once it follows:
    /// the first upload was stamped before it. "나중에" hides the offer until then.
    func testWhatTheOldStorageChangedAfterTheMoveWinsWhenItFollows() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        a.useDrive(drives); b.useDrive(drives)
        _ = try await newCourse(a, "물리"); _ = try await newCourse(a, "화학")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")

        let rows = (try await b.course("물리"), try await b.course("화학"))
        let physics = try XCTUnwrap(rows.0?["id"] as? String), chemistry = try XCTUnwrap(rows.1?["id"] as? String)
        _ = try await b.invoke("courses:rename", ["courseId": physics, "name": "물리학"])
        _ = try await b.invoke("courses:delete", ["courseId": chemistry])
        let offered = try await b.sync("cloudSync:syncNow")
        let t = try XCTUnwrap((offered["moved"] as? [String: Any])?["t"] as? NSNumber)
        let later = try await b.sync("cloudSync:dismissMove", ["t": t])
        XCTAssertNil(later["moved"])
        let still = try await b.sync("cloudSync:syncNow")
        XCTAssertNil(still["moved"], "not offered again")

        try await move(b, to: "drive", expect: "join")
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow")
        let courses = try await a.invoke("courses:list") as! [[String: Any]]
        XCTAssertEqual(courses.compactMap { $0["name"] as? String }, ["물리학"], "the rename and the deletion made in iCloud after the move")
    }

    /// The old storage is let go only after a last pass with it went through: a file still coming down stops the move.
    func testAMoveGoesOnlyAfterALastPassWithTheOldStorage() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        a.failing = Failing(root: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let other = "dddddddd-0000-4000-8000-000000000004"
        try Data(#"{"name":"Mac","last_seen":1}"#.utf8).write(to: cloud.appendingPathComponent("devices/\(other).json"))
        a.failing?.pending = ["devices/\(other).json"]
        _ = try await a.sync("cloudSync:prepareMove", ["provider": "drive"])
        do { _ = try await a.sync("cloudSync:move", ["provider": "drive", "expect": "upload"]); XCTFail("moved") }
        catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_MOVE_BEHIND") }
        let status = try await a.sync("cloudSync:status")
        XCTAssertEqual(status["provider"] as? String, "icloud")
        XCTAssertEqual(drives["google-a"]!.text(endingWith: ".json"), "", "nothing went into Drive")
        a.failing?.pending = []
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")
        XCTAssertTrue(drives["google-a"]!.text(endingWith: ".json").contains("물리"))
    }

    /// A note changed in both storages around a move keeps both texts: one stays the note, the other a conflict copy.
    func testANoteChangedInBothStoragesAroundAMoveKeepsBothTexts() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        a.useDrive(drives); b.useDrive(drives)
        let course = try await newCourse(a, "물리")
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await b.sync("cloudSync:connect", ["mode": "merge", "pairs": []]); _ = try await b.sync("cloudSync:syncNow")
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘 (Drive)\n"])
        _ = try await a.sync("cloudSync:syncNow")
        let row = try await b.course("물리"), other = try XCTUnwrap(row?["id"] as? String)
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘 (iCloud)\n"])
        _ = try await b.sync("cloudSync:syncNow")

        try await move(b, to: "drive", expect: "join")
        _ = try await b.sync("cloudSync:syncNow"); _ = try await a.sync("cloudSync:syncNow"); _ = try await b.sync("cloudSync:syncNow")
        for (device, id) in [(a, course), (b, other)] {
            let files = try await device.files(id)
            let copy = try XCTUnwrap(files.first { $0.hasPrefix("요약 (충돌 사본") }, "\(files)")
            var texts = Set<String>()
            for path in ["요약.md", copy] {
                let note = try await device.invoke("notes:read", ["courseId": id, "relPath": path]) as? [String: Any]
                texts.insert(try XCTUnwrap(note?["markdown"] as? String))
            }
            XCTAssertEqual(texts, ["# 힘 (Drive)\n", "# 힘 (iCloud)\n"])
        }
    }

    /// Moving back to the storage it left: its own note there offers nothing and goes with its next devices file;
    /// the Drive left behind is told, and its Google account is let go once iCloud holds everything.
    func testMovingBackOffersNothingAndLetsTheGoogleAccountGo() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        try await move(a, to: "drive", expect: "upload")
        _ = try await a.sync("cloudSync:syncNow")
        let me = try await a.syncStore { try $0.deviceID() }
        XCTAssertNotNil(try iCloudFile("devices/\(me).json")["moved_to"])
        let events = try a.logEvents(cloud)

        try await move(a, to: "icloud", expect: "join")
        let back = try await a.sync("cloudSync:syncNow")
        XCTAssertNil(back["moved"], "its own move is no offer")
        XCTAssertNil(back["moving"])
        XCTAssertNil(try iCloudFile("devices/\(me).json")["moved_to"], "written again without it")
        XCTAssertEqual(try a.logEvents(cloud), events, "nothing both held goes up again")
        let told = drives["google-a"]!.text(endingWith: "\(me).json")
        XCTAssertTrue(told.contains(#""provider":"icloud""#), told)
        XCTAssertEqual(a.keychain.items["drive.account"], "", "the Google account went once Drive was told")
    }

    /// A disconnect before the new storage's first pass ends the move untold. The base still describes the old
    /// root then, so that is the root this profile belongs to again.
    func testADisconnectBeforeTheNewStoragesFirstPassGivesTheBaseBackToTheOldRoot() async throws {
        let a = try await Device(cloud: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        let old = try await a.syncStore { try $0.value("sync_account") }
        try await a.syncStore { store in
            try store.setMoving(.init(provider: "icloud", account: old ?? "", at: 0, clock: 0, rebase: true))
            try store.set("sync_account", "drive:google-a")
        }
        _ = try await a.sync("cloudSync:disconnect")
        let after = try await a.syncStore { (account: try $0.value("sync_account"), moving: try $0.moving()) }
        XCTAssertEqual(after.account, old)
        XCTAssertNil(after.moving)
    }

    /// Telling the old storage is tried again after each pass and given up after a week; the move ends either way.
    func testTellingTheOldStorageIsTriedAgainThenGivenUpAfterAWeek() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        a.failing = Failing(root: cloud)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        a.failing?.fails = true
        try await move(a, to: "drive", expect: "upload")
        let trying = try await a.sync("cloudSync:syncNow")
        XCTAssertEqual(trying["moving"] as? String, "icloud", "tried again after the next pass")
        try await a.syncStore { store in
            var moving = try XCTUnwrap(try store.moving())
            moving.at -= CloudSyncService.tellingFor
            try store.setMoving(moving)
        }
        let done = try await a.sync("cloudSync:syncNow")
        XCTAssertNil(done["moving"])
        let lines = await a.logLines()
        XCTAssertTrue(lines.contains("sync.move channel=icloud code=gave-up"), "\(lines)")
        let me = try await a.syncStore { try $0.deviceID() }
        XCTAssertNil(try iCloudFile("devices/\(me).json")["moved_to"])
    }

    /// A profile joined to iCloud before Drive existed kept the account under the old key; moving it
    /// to Drive is still another root, so everything goes out again.
    func testAnICloudRootJoinedBeforeDriveIsStillAnotherRoot() async throws {
        let drives = ["google-a": FakeDrive()], a = try await Device(cloud: cloud)
        a.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:connect", ["mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        try await a.store.runtime.withSyncStorage { context, _ in
            try context.run("DELETE FROM cloud_sync_state WHERE key='sync_account'")
            try SyncStore(context: context).set("icloud_account", "account-a")
        }
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        XCTAssertTrue(drives["google-a"]!.text(endingWith: ".json").contains("물리"))
    }

    /// 가져오기 on Drive: the new profile takes the Google account with it; this one lets it go
    /// without giving the grant back.
    func testImportOnDriveTakesTheGoogleAccountToTheNewProfile() async throws {
        let drives = ["google-a": FakeDrive()], keychain = Box(), a = try await Device(cloud: cloud, keychain: keychain)
        a.useDrive(drives)
        _ = try await newCourse(a, "물리")
        _ = try await a.sync("cloudSync:preview", ["provider": "drive"])
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "start"]); _ = try await a.sync("cloudSync:syncNow")
        _ = try await a.sync("cloudSync:connect", ["provider": "drive", "mode": "import"])
        let pointer = try JSONDecoder().decode(DesktopProfileService.Selection.self, from: Data(contentsOf: a.documents.appendingPathComponent("active-profile.json")))
        let next = try await Device(cloud: cloud, documents: a.documents, root: pointer.rootName, keychain: keychain)
        next.useDrive(drives); next.google = nil
        await next.service.start()
        _ = try await next.sync("cloudSync:syncNow")
        let status = try await next.sync("cloudSync:status")
        XCTAssertEqual(status["provider"] as? String, "drive")
        XCTAssertEqual(status["driveEmail"] as? String, "a@example.com")
        let arrived = try await next.course("물리")
        XCTAssertNotNil(arrived, "the cloud's data arrived")
        let left = try await a.sync("cloudSync:status")
        XCTAssertNil(left["driveEmail"], "the old profile let the account go")
    }
}
