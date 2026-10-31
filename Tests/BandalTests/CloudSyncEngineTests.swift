import XCTest
@testable import Bandal

/// Two iPads running the real loop against one folder (design §1). The folder stands in for
/// iCloud Drive: `ICloudProvider` is this provider with file coordination and a metadata query.
@MainActor
final class CloudSyncEngineTests: XCTestCase {
    private final class Box { var items: [String: String] = [:] }

    /// A provider whose files can be still downloading (listed, not readable) or not listed yet,
    /// as iCloud reports them.
    private final class Downloading: FolderProvider, @unchecked Sendable {
        var pending = Set<String>(), unlisted: (String) -> Bool = { _ in false }
        override func list() async throws -> [String: SyncRemoteFile] {
            try await super.list().reduce(into: [:]) { files, file in
                guard !unlisted(file.key) else { return }
                files[file.key] = pending.contains(file.key) ? SyncRemoteFile(version: file.value.version, local: false) : file.value
            }
        }
        override func read(_ path: String) throws -> Data {
            guard !pending.contains(path) else { throw DesktopRuntimeError("\(path) is not downloaded yet", code: "SYNC_DOWNLOADING") }
            return try super.read(path)
        }
    }

    @MainActor private final class Device {
        let root: URL, runtime: DesktopRuntime, engine: CloudSyncEngine, provider: Downloading
        /// What each apply told the workspace to reload.
        var reloads: [[String: Any]] = []
        /// The barrier's flush of open editors, run before apply as `withExternalMutation` does.
        var flush: (() async throws -> Void)?
        /// Documents open in an editor, as `course\0path`; nil when an editor does not say.
        var open: Set<String>? = []
        private let keychain = Box()

        init(cloud: URL) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-engine-" + UUID().uuidString)
            runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            try await runtime.start()
            let box = keychain, keys = SyncStore.Keychain(read: { box.items[$0] }, write: { box.items[$0] = $1 })
            provider = Downloading(root: cloud)
            engine = CloudSyncEngine(runtime: runtime, provider: provider, keychain: keys)
            engine.mutateOpenDocuments = { [unowned self] action in
                try await flush?()
                let result = try await action()
                reloads.append(result as? [String: Any] ?? [:])
                return result
            }
            engine.openDocuments = { [unowned self] in open }
            try await runtime.withSyncStorage { context, _ in try SyncStore(context: context, keychain: keys).setProvider("icloud") }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func invoke(_ channel: String, _ request: [String: Any] = [:]) async throws -> Any { try await runtime.invokePrivate(channel, request: request) }
        func course(_ name: String) async throws -> String {
            let courses = try await invoke("courses:list") as! [[String: Any]]
            return try XCTUnwrap(courses.first { $0["name"] as? String == name }?["id"] as? String)
        }
        func stroke(_ course: String, _ path: String) async throws {
            let binding = try await invoke("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any]
            _ = try await invoke("drawings:create", ["courseId": course, "relPath": path, "page": 1, "kind": "ink", "documentRevision": binding["documentRevision"]!,
                                                     "clientMutationId": UUID().uuidString, "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.4, "t": 0.0], ["x": 0.6, "y": 0.5, "p": 0.8, "t": 20.0]]],
                                                     "style": ["color": "blue", "width": 0.003, "opacity": 1.0]])
        }
    }

    private var cloud: URL!

    override func setUp() {
        cloud = FileManager.default.temporaryDirectory.appendingPathComponent("sync-cloud-" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cloud) }

    func testTwoIPadsSyncThroughOneFolder() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        let paper = (try await a.invoke("pdfNotes:create", ["courseId": course, "title": "1주차", "paper": "blank"]) as! [String: Any])["relPath"] as! String
        try await a.stroke(course, paper)
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(a.engine.status["phase"] as? String, "idle")
        XCTAssertEqual(b.engine.status["phase"] as? String, "idle")
        let other = try await b.course("물리"), note = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as? [String: Any]
        XCTAssertEqual(note?["markdown"] as? String, "# 힘\n")
        let received = try await b.runtime.readMaterial(courseID: other, relativePath: paper), sent = try await a.runtime.readMaterial(courseID: course, relativePath: paper)
        XCTAssertEqual(received, sent)
        let ink = try await b.invoke("drawings:listForFile", ["courseId": other, "relPath": paper]) as? [[String: Any]]
        XCTAssertEqual(ink?.count, 1)
        XCTAssertTrue(b.reloads.isEmpty, "nothing was open")
        // Ink for a PDF open on b goes in through the barrier, which reopens that editor.
        b.open = [other + "\u{0}" + paper]
        try await a.stroke(course, paper)
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual((b.reloads.last?["changedDocuments"] as? [[String: Any]])?.compactMap { $0["relPath"] as? String }, [paper])
        let both = try await b.invoke("drawings:listForFile", ["courseId": other, "relPath": paper]) as? [[String: Any]]
        XCTAssertEqual(both?.count, 2)
    }

    /// The workspace barrier runs only when another device changed a document open here, and
    /// names it to reopen; this device's own writes and changes elsewhere go in without it.
    func testOnlyRemoteChangesToOpenDocumentsUseTheBarrier() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        a.open = [course + "\u{0}요약.md"]
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.reloads.count, 0)
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘과 운동\n"])
        await a.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.reloads.count, 0, "own writes")
        let count = a.reloads.count
        await b.engine.syncNow()
        let other = try await b.course("물리"), read = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(read["markdown"] as? String, "# 힘과 운동\n")
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘과 운동\n\n뉴턴\n", "expectedMtime": read["mtime"]!])
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.reloads.count, count + 1)
        let changed = a.reloads.last?["changedDocuments"] as? [[String: Any]]
        XCTAssertEqual(changed?.compactMap { $0["relPath"] as? String }, ["요약.md"])
        let note = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as? [String: Any]
        XCTAssertEqual(note?["markdown"] as? String, "# 힘과 운동\n\n뉴턴\n")
    }

    /// An open note's unsaved text is saved before remote text lands, so it is never overwritten:
    /// it goes out from the version it started from and the merge keeps the other as a copy.
    func testAnUnsavedNoteIsSavedBeforeRemoteTextLands() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        let other = try await b.course("물리"), read = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘\n\nb\n", "expectedMtime": read["mtime"]!])
        await b.engine.syncNow()
        a.open = [course + "\u{0}요약.md"]
        a.flush = { [unowned a] in
            a.flush = nil
            let open = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as! [String: Any]
            _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n\na\n", "expectedMtime": open["mtime"]!])
        }
        await a.engine.syncNow(); await a.engine.syncNow()
        let mine = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(mine["markdown"] as? String, "# 힘\n\na\n")
        _ = try await a.invoke("materials:tree", ["courseId": course])
        let files = try await a.runtime.withSyncStorage { context, _ in
            try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL", [course]).compactMap { $0["rel_path"] as? String }
        }
        let copy = try XCTUnwrap(files.first { $0.hasPrefix("요약 (충돌 사본") }, "\(files)")
        let kept = try await a.invoke("notes:read", ["courseId": course, "relPath": copy]) as! [String: Any]
        XCTAssertEqual(kept["markdown"] as? String, "# 힘\n\nb\n")
    }

    /// An open editor that cannot save (a note in conflict) holds back the remote change to its
    /// document only: this device's own changes still go out.
    func testAnEditorThatCannotSaveHoldsBackOnlyItsDocument() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        await a.engine.syncNow(); await b.engine.syncNow()
        let other = try await b.course("물리"), read = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘\n\nb\n", "expectedMtime": read["mtime"]!])
        await b.engine.syncNow()
        a.open = [course + "\u{0}요약.md"]
        a.flush = { throw DesktopRuntimeError("파일이 다른 곳에서 변경되었습니다.", code: "CONFLICT") }
        _ = try await a.invoke("courses:create", ["name": "생물", "color": "pink"])
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status["phase"] as? String, "waiting")
        let held = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(held["markdown"] as? String, "# 힘\n")
        await b.engine.syncNow()
        _ = try await b.course("생물")
        a.flush = nil
        await a.engine.syncNow()
        let landed = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(landed["markdown"] as? String, "# 힘\n\nb\n")
        XCTAssertEqual(a.engine.status["phase"] as? String, "idle")
    }

    /// A PDF or attachment that is listed but not downloaded, or that arrives after the log naming
    /// it, holds its document until it is here, and then the document goes in without another
    /// write from anyone (review HIGH).
    func testFilesArrivingAfterTheirLogAreAppliedWhenTheyLand() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        let paper = (try await a.invoke("pdfNotes:create", ["courseId": course, "title": "1주차", "paper": "blank"]) as! [String: Any])["relPath"] as! String
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        _ = try await a.invoke("materials:createFolder", ["courseId": course, "dirRelPath": "", "name": "assets"])
        _ = try await a.invoke("materials:writeFile", ["courseId": course, "dirRelPath": "assets", "fileName": "p.png", "encoding": "base64", "data": png.base64EncodedString()])
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "![](assets/p.png)\n"])
        await a.engine.syncNow()
        b.provider.unlisted = { $0.hasPrefix("pdf/") }
        b.provider.pending = Set(try await b.provider.list().keys.filter { $0.hasPrefix("assets/") })
        await b.engine.syncNow()
        await b.engine.syncNow()  // b's own first files are in; only the blobs can change now
        let other = try await b.course("물리")
        let before = try await b.runtime.withSyncStorage { context, _ in try context.query("SELECT rel_path FROM cloud_sync_docs WHERE course_id=? AND rel_path<>''", [other]).count }
        XCTAssertEqual(before, 0, "the PDF is not listed and the note's attachment is still downloading")
        b.provider.unlisted = { _ in false }; b.provider.pending = []
        await b.engine.syncNow()
        let pdf = try await b.runtime.readMaterial(courseID: other, relativePath: paper), original = try await a.runtime.readMaterial(courseID: course, relativePath: paper)
        XCTAssertEqual(pdf, original)
        let note = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        XCTAssertEqual(note["markdown"] as? String, "![](assets/\(SyncFormat.sha256(png)).png)\n")
    }

    /// This device's own note version can reach the listing a cycle late (iCloud metadata lags);
    /// the conflict copy it makes still appears then (review MEDIUM).
    func testOwnFilesListedLateStillMakeTheirCopies() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        let other = try await b.course("물리"), read = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘\n\nb\n", "expectedMtime": read["mtime"]!])
        await b.engine.syncNow()
        let mine = try await a.invoke("notes:read", ["courseId": course, "relPath": "요약.md"]) as! [String: Any]
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n\na\n", "expectedMtime": mine["mtime"]!])
        let listed = Set(try await a.provider.list().keys)
        await a.engine.syncNow()
        a.provider.unlisted = { !listed.contains($0) }
        await a.engine.syncNow()
        a.provider.unlisted = { _ in false }
        await a.engine.syncNow()
        _ = try await a.invoke("materials:tree", ["courseId": course])
        let files = try await a.runtime.withSyncStorage { context, _ in
            try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL", [course]).compactMap { $0["rel_path"] as? String }
        }
        XCTAssertTrue(files.contains { $0.hasPrefix("요약 (충돌 사본") }, "\(files)")
    }

    /// When an editor does not name its document, every change that could touch an open one waits for the barrier.
    func testUnknownOpenDocumentsUseTheBarrier() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        _ = try await a.invoke("notes:write", ["courseId": course, "relPath": "요약.md", "markdown": "# 힘\n"])
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        let other = try await b.course("물리"), read = try await b.invoke("notes:read", ["courseId": other, "relPath": "요약.md"]) as! [String: Any]
        _ = try await b.invoke("notes:write", ["courseId": other, "relPath": "요약.md", "markdown": "# 힘\n\nb\n", "expectedMtime": read["mtime"]!])
        await b.engine.syncNow()
        a.open = nil
        await a.engine.syncNow()
        XCTAssertEqual((a.reloads.last?["changedDocuments"] as? [[String: Any]])?.compactMap { $0["relPath"] as? String }, ["요약.md"])
    }

    func testARootOfAnotherFormatIsNeverWritten() async throws {
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data(#"{"format":3}"#.utf8).write(to: cloud.appendingPathComponent("bandal.json"))
        let a = try await Device(cloud: cloud)
        _ = try await a.invoke("courses:create", ["name": "물리", "color": "blue"])
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status["phase"] as? String, "paused")
        XCTAssertEqual(a.engine.status["reason"] as? String, "update-required")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), ["bandal.json"])
    }

    /// Until every spec file is here nothing is applied or written; then everything is.
    func testNothingHappensUntilEveryFileIsHere() async throws {
        let a = try await Device(cloud: cloud), b = try await Device(cloud: cloud)
        _ = try await a.invoke("courses:create", ["name": "물리", "color": "blue"])
        await a.engine.syncNow()
        let before = try await b.provider.list()
        b.provider.pending = Set(before.keys.filter { $0.hasPrefix("log/") })
        _ = try await b.invoke("courses:create", ["name": "화학", "color": "green"])
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.status["phase"] as? String, "downloading")
        let waiting = try await b.provider.list()
        XCTAssertEqual(Set(waiting.keys), Set(before.keys), "nothing written")
        b.provider.pending = []
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.status["phase"] as? String, "idle")
        _ = try await b.course("물리")
        let after = try await b.provider.list()
        XCTAssertGreaterThan(after.count, before.count)
    }

    /// A synced PDF keeps its pages: only new pages at the end (design §4.6, spec proposal §12.2-2).
    func testSyncedPDFsOnlyGrowAtTheEnd() async throws {
        let a = try await Device(cloud: cloud)
        let course = (try await a.invoke("courses:create", ["name": "물리", "color": "blue"]) as! [String: Any])["id"] as! String
        let paper = (try await a.invoke("pdfNotes:create", ["courseId": course, "title": "1주차", "paper": "blank"]) as! [String: Any])["relPath"] as! String
        func change(_ pages: [Any]) async throws -> Any {
            let binding = try await a.invoke("nativePDF:binding", ["courseId": course, "relPath": paper]) as! [String: Any]
            return try await a.invoke("pdf:restructure", ["courseId": course, "relPath": paper, "documentRevision": binding["documentRevision"]!, "clientMutationId": UUID().uuidString, "pages": pages])
        }
        _ = try await change([1, 0])
        do { _ = try await change([2, 1]); XCTFail("reordered") } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_RESTRUCTURE_BLOCKED") }
        do { _ = try await change([1]); XCTFail("deleted") } catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SYNC_RESTRUCTURE_BLOCKED") }
        let history = try await a.invoke("pdf:pageHistory", ["courseId": course, "relPath": paper]) as! [String: Any]
        XCTAssertEqual(history["canRestructure"] as? Bool, false)
        XCTAssertEqual(history["canAppend"] as? Bool, true)
        XCTAssertEqual(history["canUndo"] as? Bool, false)
        try await a.runtime.withSyncStorage { context, _ in try SyncStore(context: context).setProvider(nil) }
        _ = try await change([2, 1])
    }
}
