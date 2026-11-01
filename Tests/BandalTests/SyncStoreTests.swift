import PDFKit
import XCTest
@testable import Bandal

/// Two iPads sharing one cloud root held in memory (design §3.5). Each has its own data
/// root, database and keychain; a sync is outbox → write → commit → merge → apply.
final class SyncStoreTests: XCTestCase {
    private final class Cloud { var files: [String: Data] = [:] }
    private final class Box { var items: [String: String] = [:] }
    /// One clock for both devices, so the order of calls is the order of t.
    private static var time: Int64 = 1_793_318_400_000

    private final class Device {
        let root: URL, context: NativeRepositoryContext, library: NativeLibraryRepository, pdf: NativePDFRepository, store: SyncStore, outbox: SyncOutbox
        let keychain = Box()

        init(_ name: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-store-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            library = NativeLibraryRepository(context: context)
            pdf = try NativePDFRepository(context: context)
            let box = keychain
            store = try SyncStore(context: context, keychain: SyncStore.Keychain(read: { box.items[$0] }, write: { box.items[$0] = $1 }))
            outbox = SyncOutbox(store: store, library: library)
            outbox.deviceName = name
            outbox.now = { SyncStoreTests.time += 1; return SyncStoreTests.time }
            try store.setCapturing(true)
        }

        /// Paths written this round.
        @discardableResult func sync(_ cloud: Cloud) throws -> [String] {
            let batch = try outbox.prepare(remote: Set(cloud.files.keys))
            for write in batch.writes {
                switch write.content {
                case .data(let data): cloud.files[write.path] = data
                case .file(let url): cloud.files[write.path] = try Data(contentsOf: url)
                }
            }
            try outbox.commit(batch)
            let state = SyncMerge.merge(SyncFormat.readRoot(cloud.files.map { ($0.key, $0.value) }).files)
            let report = try SyncApply(store: store, library: library, read: { try XCTUnwrap(cloud.files[$0], $0) }).apply(state)
            XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
            return batch.writes.map(\.path).sorted()
        }

        func course(_ name: String, color: String = "blue") throws -> String {
            (try library.handle("courses:create", ["name": name, "color": color]) as! [String: Any])["id"] as! String
        }
        func courseID(_ name: String) throws -> String { try XCTUnwrap(context.query("SELECT id FROM courses WHERE name=? AND deleted_at IS NULL", [name]).first?["id"] as? String) }
        func paper(_ course: String, _ title: String) throws -> String {
            (try pdf.handle("pdfNotes:create", ["courseId": course, "title": title, "paper": "blank"]) as! [String: Any])["relPath"] as! String
        }
        func stroke(_ course: String, _ path: String, x: Double = 0.2) throws -> String {
            let revision = (try pdf.handle("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any])["documentRevision"]!
            let created = try pdf.handle("drawings:create", ["courseId": course, "relPath": path, "page": 1, "kind": "ink", "documentRevision": revision, "clientMutationId": UUID().uuidString,
                                                             "data": ["inkVersion": 5, "points": [["x": x, "y": 0.3, "p": 0.37, "t": 0.0], ["x": 0.6, "y": 0.5, "p": 0.83, "t": 24.3]]],
                                                             "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]) as! [String: Any]
            return created["id"] as! String
        }
        func note(_ course: String, _ path: String, _ text: String) throws {
            _ = try library.handle("notes:write", ["courseId": course, "relPath": path, "markdown": text])
        }
        func text(_ course: String, _ path: String) throws -> String? {
            let url = try context.materialURL(courseID: course, relativePath: path, allowMissing: true)
            return FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
        }
        func bytes(_ course: String, _ path: String) throws -> Data { try Data(contentsOf: context.materialURL(courseID: course, relativePath: path)) }
        /// Live drawings of one PDF as `id → (data, style)` JSON values.
        func drawings(_ course: String, _ path: String) throws -> [String: [Any]] {
            var result: [String: [Any]] = [:]
            for row in try context.query("SELECT id,data_json,style_json FROM pdf_drawings WHERE course_id=? AND rel_path=? AND deleted_at IS NULL", [course, path]) {
                result[row["id"] as! String] = [try NativeRepositoryContext.jsonObject(row["data_json"] as! String), try NativeRepositoryContext.jsonObject(row["style_json"] as! String)]
            }
            return result
        }
        func files(_ course: String) throws -> [String] {
            _ = try library.handle("materials:tree", ["courseId": course])
            return try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL ORDER BY rel_path", [course]).map { $0["rel_path"] as! String }
        }
        func image(_ course: String, _ path: String, file: String) throws -> String {
            let revision = (try pdf.handle("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any])["documentRevision"]!
            let created = try pdf.handle("drawings:create", ["courseId": course, "relPath": path, "page": 1, "kind": "image", "documentRevision": revision, "clientMutationId": UUID().uuidString,
                                                             "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.2], "image": ["relPath": file, "label": "사진", "widthPx": 1, "heightPx": 1]],
                                                             "style": ["color": "ink", "width": 0.002, "opacity": 1.0]]) as! [String: Any]
            return created["id"] as! String
        }
        /// Merge and apply only, as when the root is read before anything is sent.
        func apply(_ cloud: Cloud) throws {
            let state = SyncMerge.merge(SyncFormat.readRoot(cloud.files.map { ($0.key, $0.value) }).files)
            XCTAssertTrue(try SyncApply(store: store, library: library, read: { try XCTUnwrap(cloud.files[$0], $0) }).apply(state).skipped.isEmpty)
        }
        func overwrite(_ course: String, _ path: String, _ bytes: Data) throws {
            try context.atomicWrite(bytes, to: context.materialURL(courseID: course, relativePath: path))
        }
        /// A blank page added at the end in the app, which moves the PDF binding along.
        func appendPage(_ course: String, _ path: String) throws {
            try restructure(course, path, Array(1...(try XCTUnwrap(PDFDocument(data: try bytes(course, path))).pageCount)) + [0])
        }
        /// A page change in the app (`pdf:restructure` recipe, 0 = a new page).
        func restructure(_ course: String, _ path: String, _ pages: [Int]) throws {
            let revision = (try pdf.handle("nativePDF:binding", ["courseId": course, "relPath": path]) as! [String: Any])["documentRevision"]!
            _ = try NativePDFPageRepository(context: context, pdf: pdf).handle("pdf:restructure", ["courseId": course, "relPath": path, "documentRevision": revision,
                                                                                                    "clientMutationId": UUID().uuidString, "pages": pages])
        }
        /// The same bytes with one more page, written outside the app.
        func replaceOutside(_ course: String, _ path: String) throws -> Data {
            let document = try XCTUnwrap(PDFDocument(data: try bytes(course, path)))
            document.insert(try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage), at: document.pageCount)
            let longer = try XCTUnwrap(document.dataRepresentation())
            try overwrite(course, path, longer)
            return longer
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Writes events from a device that is not one of the test iPads.
    private static func remote(_ cloud: Cloud, seq: Int, _ events: [[String: Any]], notes: [String: Data] = [:]) throws {
        let device = "eeeeeeee-0000-4000-8000-000000000005"
        cloud.files["log/\(device)/" + String(format: "%08d", seq) + ".json"] = try JSONSerialization.data(withJSONObject: events)
        for (doc, bytes) in notes { cloud.files["notes/\(doc)/\(device)-" + String(format: "%08d", seq) + ".md"] = bytes }
    }

    /// The fields of the doc.upsert that sent this PDF.
    private static func upsert(_ cloud: Cloud, pdf sha: String) throws -> [String: Any]? {
        for (path, data) in cloud.files where path.hasPrefix("log/") {
            for event in try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [] {
                if let fields = event["fields"] as? [String: Any], fields["pdf_sha256"] as? String == sha { return fields }
            }
        }
        return nil
    }

    /// 1×1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testDeviceIdentityFollowsTheKeychain() throws {
        let device = try Device("iPad")
        let id = try device.store.deviceID()
        XCTAssertEqual(try device.store.deviceID(), id)
        XCTAssertEqual(id, id.lowercased())
        // I15: a seq always passes this device's files already in the root.
        XCTAssertEqual(try device.store.nextSeq(pastRemote: 0), 1)
        XCTAssertEqual(try device.store.nextSeq(pastRemote: 7), 8)
        XCTAssertEqual(try device.store.nextSeq(pastRemote: 0), 9)
        // I16: the same database on another iPad (another keychain) writes under a new id from seq 1.
        let copy = try SyncStore(context: device.context, keychain: SyncStore.Keychain(read: { _ in nil }, write: { _, _ in }))
        XCTAssertNotEqual(try copy.deviceID(), id)
        XCTAssertEqual(try copy.nextSeq(pastRemote: 0), 1)
        // M8: a remote t an hour ahead of this clock still loses to the next local change.
        try device.store.observe(Self.time + 3_600_000)
        XCTAssertGreaterThan(try device.store.stamp(now: Self.time), Self.time + 3_600_000)
    }

    func testRegistersKeepValuesAndStamps() throws {
        var entity = SyncMerge.Entity()
        entity.fields["name"] = SyncMerge.Register(value: "물리", stamp: SyncMerge.Stamp(t: 5, device: "a", seq: 2, index: 1))
        entity.fields["archived"] = SyncMerge.Register(value: true, stamp: SyncMerge.Stamp(t: 6, device: "b", seq: 3, index: 0))
        entity.deleted = (false, SyncMerge.Stamp(t: 6, device: "b", seq: 3, index: 0))
        let back = try SyncStore.decode(try SyncStore.encode(entity))
        XCTAssertEqual(back.text("name"), "물리")
        XCTAssertEqual(back.fields["archived"]?.stamp, SyncMerge.Stamp(t: 6, device: "b", seq: 3, index: 0))
        XCTAssertEqual(back.deleted?.value, false)
        // A sort read from JSON (2.0) equals the local integer; a boolean never equals a number.
        XCTAssertTrue(SyncStore.same(2, NSNumber(value: 2.0)))
        XCTAssertFalse(SyncStore.same(back.fields["archived"]?.value, 1))
        XCTAssertTrue(SyncStore.same(back.fields["archived"]?.value, true))
    }

    func testOneDeviceWritesAndTheOtherApplies() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리", color: "purple"), paper = try a.paper(course, "1주차")
        let stroke = try a.stroke(course, paper)
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        try a.note(course, "노트/강의.md", "# 강의\n본문\n")
        try a.sync(cloud)
        XCTAssertTrue(cloud.files.keys.contains("bandal.json"))
        try b.sync(cloud)

        let other = try b.courseID("물리")
        XCTAssertEqual(try b.context.query("SELECT color FROM courses WHERE id=?", [other]).first?["color"] as? String, "purple")
        XCTAssertEqual(try b.bytes(other, paper), try a.bytes(course, paper))
        XCTAssertEqual(try b.text(other, "노트/강의.md"), "# 강의\n본문\n")
        XCTAssertEqual(Array(try b.drawings(other, paper).keys), [stroke])
        XCTAssertTrue(SyncConformanceTests.jsonEqual(try b.drawings(other, paper), try a.drawings(course, paper)))
        // B's PDF repository takes the placed file as the same document.
        XCTAssertEqual((try b.pdf.handle("nativePDF:binding", ["courseId": other, "relPath": paper]) as! [String: Any])["materialID"] as? String,
                       (try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]) as! [String: Any])["materialID"] as? String)
        // I6: once both hold the same state nothing travels, applied writes included.
        XCTAssertEqual(try b.sync(cloud), [])
        XCTAssertEqual(try a.sync(cloud), [])
    }

    func testEditsTravelBothWays() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차"), stroke = try a.stroke(course, paper)
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        _ = try b.library.handle("courses:rename", ["courseId": other, "name": "물리학"])
        _ = try b.pdf.handle("drawings:update", ["id": stroke, "style": ["color": "red", "width": 0.003, "opacity": 1.0]])
        let added = try b.stroke(other, paper, x: 0.4)
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertNoThrow(try a.courseID("물리학"))
        XCTAssertEqual(Set(try a.drawings(course, paper).keys), [stroke, added])
        XCTAssertEqual((try a.drawings(course, paper)[stroke]?[1] as? [String: Any])?["color"] as? String, "red")
        // I4, I7: a deleted stroke and an in-app rename. The rename moves the other stroke with
        // its PDF without changing it, so that stroke is not sent again.
        let sent = try a.context.query("SELECT t,dev FROM cloud_sync_objects WHERE id=?", [stroke])
        _ = try a.pdf.handle("drawings:delete", ["ids": [added]])
        _ = try a.library.handle("materials:rename", ["courseId": course, "relPath": paper, "newName": "1주차 정리.pdf"])
        let renamed = (paper as NSString).deletingLastPathComponent + "/1주차 정리.pdf"
        try a.sync(cloud)
        XCTAssertTrue(SyncConformanceTests.jsonEqual(try a.context.query("SELECT t,dev FROM cloud_sync_objects WHERE id=?", [stroke]), sent))
        try b.sync(cloud)
        XCTAssertEqual(try b.files(other), [renamed])
        XCTAssertEqual(Array(try b.drawings(other, renamed).keys), [stroke])
    }

    func testConcurrentNoteEditsLeaveOneConflictCopy() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리")
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        // N2: both edit the same version offline; B's later write is the body.
        try a.note(course, "노트/강의.md", "A의 수정\n")
        try b.note(other, "노트/강의.md", "B의 수정\n")
        for device in [a, b, a, b] { try device.sync(cloud) }
        for (device, id) in [(a, course), (b, other)] {
            XCTAssertEqual(try device.text(id, "노트/강의.md"), "B의 수정\n")
            XCTAssertEqual(try device.text(id, "노트/강의 (충돌 사본 iPad A).md"), "A의 수정\n")
            XCTAssertEqual(try device.files(id), ["노트/강의 (충돌 사본 iPad A).md", "노트/강의.md"])
        }
        XCTAssertEqual(try a.sync(cloud), [])
    }

    func testAttachmentsAndImagesTravelAsAssets() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        let file = (try a.library.handle("materials:writeFile", ["courseId": course, "dirRelPath": "assets", "createDirIfMissing": true, "fileName": "이미지-1.PNG",
                                                                 "encoding": "base64", "data": Self.png.base64EncodedString()]) as! [String: Any])["relPath"] as! String
        let drawing = try a.image(course, paper, file: file)
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        // N6: links as the editor writes them, percent-encoded.
        try a.note(course, "노트/강의.md", "# 강의\n![사진](assets/%EC%9D%B4%EB%AF%B8%EC%A7%80-1.PNG)\n")
        try a.sync(cloud); try b.sync(cloud)
        let sha = SyncFormat.sha256(Self.png), other = try b.courseID("물리")
        XCTAssertEqual(cloud.files["assets/\(sha).png"], Self.png)
        XCTAssertTrue(String(decoding: cloud.files.first { $0.key.hasPrefix("notes/") }!.value, as: UTF8.self).contains("](../../assets/\(sha).png)"))
        XCTAssertEqual(try b.text(other, "노트/강의.md"), "# 강의\n![사진](assets/\(sha).png)\n")
        XCTAssertEqual(try b.bytes(other, "assets/\(sha).png"), Self.png)
        // I11: the image drawing points at the asset file B keeps under its hash.
        let data = try XCTUnwrap(try b.drawings(other, paper)[drawing]?[0] as? [String: Any])
        XCTAssertEqual((data["image"] as? [String: Any])?["relPath"] as? String, "assets/\(sha).png")
        XCTAssertEqual(try b.sync(cloud), [])
        XCTAssertEqual(try a.sync(cloud), [])
    }

    func testRemovalsTravel() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차"), stroke = try a.stroke(course, paper)
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        // A drawing removed outright (page restructure undo does this) still goes out as a tombstone.
        try a.context.run("DELETE FROM pdf_drawings WHERE id=?", [stroke])
        _ = try a.library.handle("materials:delete", ["courseId": course, "relPath": "노트/강의.md"])
        try a.sync(cloud); try b.sync(cloud)
        XCTAssertTrue(try b.drawings(other, paper).isEmpty)
        XCTAssertEqual(try b.files(other), [paper])
        _ = try a.library.handle("courses:delete", ["courseId": course])
        try a.sync(cloud); try b.sync(cloud)
        XCTAssertTrue(try b.context.query("SELECT 1 FROM courses WHERE name='물리' AND deleted_at IS NULL").isEmpty)
        XCTAssertEqual(try b.sync(cloud), [])
    }

    /// A write that failed before `commit` is prepared again under the same document id.
    func testRetryAfterAFailedWriteKeepsIds() throws {
        let cloud = Cloud(), a = try Device("iPad A")
        let course = try a.course("물리")
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        for write in try a.outbox.prepare(remote: []).writes { if case .data(let data) = write.content { cloud.files[write.path] = data } }
        try a.sync(cloud)
        let state = SyncMerge.merge(SyncFormat.readRoot(cloud.files.map { ($0.key, $0.value) }).files)
        XCTAssertEqual(state.docs.count, 1)
        XCTAssertEqual(state.courses.count, 1)
    }

    /// The simulator looks paths up case-sensitively, as an iPad does, but keeps them on the
    /// Mac's case-insensitive volume: a name that differs from an existing one only by case
    /// (or by case folding, as ς and Σ) cannot be created there. Not so on a device.
    private static let caseVariantsRefused: Bool = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("case-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("a"), withIntermediateDirectories: true)
        return (try? FileManager.default.createDirectory(at: folder.appendingPathComponent("A"), withIntermediateDirectories: false)) == nil
    }()

    /// Every fixture root applied to an empty iPad: each document and drawing that is not
    /// waiting lands, and a second pass changes nothing.
    func testFixtureRootsApplyToAnEmptyDevice() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: SyncConformanceTests.fixtures.path).filter { $0.range(of: "^[0-9]{2}-", options: .regularExpression) != nil }.sorted()
        for name in names {
            let device = try Device("iPad"), folder = SyncConformanceTests.fixtures.appendingPathComponent("\(name)/root")
            let state = SyncMerge.merge(try SyncConformanceTests.readRoot(name).files)
            let apply = SyncApply(store: device.store, library: device.library, read: { try Data(contentsOf: folder.appendingPathComponent($0)) })
            // 06 holds names that differ only by case from another in the same folder (QnA/qna, Lecture/lecture);
            // since v2.3 the Σ/ς pair collides in the merge and is renamed instead.
            let refused: Set<String> = name == "06-path-collision" && Self.caseVariantsRefused
                ? ["d1b00000-0000-4000-8000-000000000012", "db000000-0000-4000-8000-000000000007", "2f323a7c-51a2-542e-a2bf-b054768c84d0"] : []
            let report = try apply.apply(state)
            XCTAssertEqual(Set(report.skipped.map(\.id)), refused, "\(name) \(report.skipped)")
            let renames = Dictionary(state.renames.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for (id, doc) in state.docs where doc.isAlive && !state.waitingDocs.contains(id) && !refused.contains(id) {
                guard let course = state.courses[doc.text("course_id") ?? ""], course.isAlive, let folder = doc.text("rel_path"), let docName = renames[id] ?? doc.text("name") else { continue }
                let local = try device.courseID(course.text("name") ?? "")
                let placed = try device.context.materialURL(courseID: local, relativePath: folder.isEmpty ? docName : folder + "/" + docName, allowMissing: true)
                XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path), "\(name) \(id)")
            }
            for (id, entry) in state.ink where entry.object.value["del"] == nil && !state.waitingInk.contains(id) {
                XCTAssertFalse(try device.context.query("SELECT 1 FROM pdf_drawings WHERE id=? AND deleted_at IS NULL", [id]).isEmpty, "\(name) \(id)")
            }
            let before = try device.context.query("SELECT id,updated_at FROM pdf_drawings ORDER BY id").map { "\($0["id"]!)\($0["updated_at"]!)" }
            XCTAssertEqual(Set(try apply.apply(state).skipped.map(\.id)), refused, name)
            XCTAssertEqual(try device.context.query("SELECT id,updated_at FROM pdf_drawings ORDER BY id").map { "\($0["id"]!)\($0["updated_at"]!)" }, before, name)
        }
    }

    /// One file per (document, page) for the session, rewritten in place; over the size limit
    /// the next changes start a new file (I12), and the result is the same.
    func testSessionFilesAreRewrittenUntilTheyGrowTooLarge() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        var strokes = [try a.stroke(course, paper)]
        try a.sync(cloud)
        func inkFiles() -> [String] { cloud.files.keys.filter { $0.hasPrefix("ink/") }.sorted() }
        let first = inkFiles()
        strokes.append(try a.stroke(course, paper, x: 0.4))
        try a.sync(cloud)
        XCTAssertEqual(inkFiles(), first)
        a.outbox.maxFile = 64
        strokes.append(try a.stroke(course, paper, x: 0.5))
        try a.sync(cloud)
        XCTAssertEqual(inkFiles().count, 2)
        // A new session starts new files as well.
        try a.outbox.endSession()
        a.outbox.maxFile = 1 << 20
        strokes.append(try a.stroke(course, paper, x: 0.6))
        try a.sync(cloud)
        XCTAssertEqual(inkFiles().count, 3)
        try b.sync(cloud)
        XCTAssertEqual(Set(try b.drawings(try b.courseID("물리"), paper).keys), Set(strokes))
    }

    /// A PDF made here is first bound when opened, under an id other than its sync id; a page
    /// added on another device must still leave it open for ink (review HIGH).
    /// A page added at the end on another iPad keeps the ink here on the longer PDF, also for a
    /// PDF made here and bound under its local id (spec v2.3 rebinding; review HIGH).
    func testRemotePageAdditionKeepsALocalPDFUsable() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        try a.sync(cloud)
        XCTAssertTrue(try a.context.query("SELECT 1 FROM pdf_document_aliases").isEmpty)
        let first = try a.stroke(course, paper)
        try b.sync(cloud)
        let other = try b.courseID("물리"), before = SyncFormat.sha256(try b.bytes(other, paper))
        try b.appendPage(other, paper)
        let longer = try b.bytes(other, paper)
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertEqual(try Self.upsert(cloud, pdf: SyncFormat.sha256(longer))?["pdf_prev_sha256"] as? String, before)
        XCTAssertEqual(try a.bytes(course, paper), longer)
        let binding = try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]) as! [String: Any]
        XCTAssertEqual(binding["documentRevision"] as? String, SyncFormat.sha256(longer))
        XCTAssertNotNil(try a.drawings(course, paper)[first])
        XCTAssertNoThrow(try a.stroke(course, paper, x: 0.7))
    }

    /// Pages moved or removed in the app (here while sync was off) are not an append: the PDF goes
    /// out with pdf_prev_sha256 null and other devices keep their ink protected (spec v2.3).
    func testReorderedPagesCarryNoPreviousPDF() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        try a.sync(cloud)
        let first = try a.stroke(course, paper)
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        try b.appendPage(other, paper)
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertNoThrow(try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]))
        try b.restructure(other, paper, [2, 1])
        let moved = try b.bytes(other, paper)
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertTrue(try XCTUnwrap(Self.upsert(cloud, pdf: SyncFormat.sha256(moved)))["pdf_prev_sha256"] is NSNull)
        XCTAssertEqual(try a.bytes(course, paper), moved)
        XCTAssertThrowsError(try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]))
        XCTAssertNotNil(try a.drawings(course, paper)[first])
    }

    /// Bytes replaced outside the app carry no ink over (pdf_prev_sha256 null): ink here stays
    /// bound to the PDF it was drawn on, also where that PDF was never opened, and its bytes stay
    /// in PDFOriginals. A PDF with no ink here simply follows (spec v2.3).
    func testPDFReplacedOutsideTheAppKeepsInkProtected() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차"), plain = try a.paper(course, "2주차")
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리"), first = try b.stroke(other, paper)
        _ = try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": plain])
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertNotNil(try a.drawings(course, paper)[first])
        let original = SyncFormat.sha256(try a.bytes(course, paper))
        let longer = try b.replaceOutside(other, paper), longerPlain = try b.replaceOutside(other, plain)
        try b.sync(cloud); try a.sync(cloud)
        XCTAssertTrue(try XCTUnwrap(Self.upsert(cloud, pdf: SyncFormat.sha256(longer)))["pdf_prev_sha256"] is NSNull)
        XCTAssertEqual(try a.bytes(course, paper), longer)
        XCTAssertThrowsError(try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]))
        XCTAssertNotNil(try a.drawings(course, paper)[first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("PDFOriginals/\(original).pdf").path))
        XCTAssertEqual(try a.bytes(course, plain), longerPlain)
        XCTAssertNoThrow(try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": plain]))
    }

    /// A PDF replaced outside the app before it was ever opened here is bound to the new bytes on
    /// first open, yet nothing vouches that ink on the old bytes fits them: no pdf_prev_sha256.
    func testFirstOpenAfterAnOutsideReplacementCarriesNothing() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        try a.sync(cloud); try b.sync(cloud)
        let longer = try a.replaceOutside(course, paper)
        _ = try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper])
        let other = try b.courseID("물리"), first = try b.stroke(other, paper)
        try b.sync(cloud); try a.sync(cloud); try b.sync(cloud)
        XCTAssertTrue(try XCTUnwrap(Self.upsert(cloud, pdf: SyncFormat.sha256(longer)))["pdf_prev_sha256"] is NSNull)
        XCTAssertEqual(try b.bytes(other, paper), longer)
        XCTAssertThrowsError(try b.pdf.handle("nativePDF:binding", ["courseId": other, "relPath": paper]))
        XCTAssertNotNil(try b.drawings(other, paper)[first])
    }

    /// pdf_prev_sha256 counts only with the pdf_sha256 of the same write: a later writer that
    /// does not send it (spec v2.2) does not inherit an earlier writer's claim.
    func testAnEarlierWritersPreviousPDFDoesNotCarryInkOver() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        try a.sync(cloud)
        _ = try a.stroke(course, paper)
        try b.sync(cloud)
        let other = try b.courseID("물리")
        try b.appendPage(other, paper)
        try b.sync(cloud)
        let id = try XCTUnwrap(a.context.query("SELECT sync_id FROM cloud_sync_docs").first?["sync_id"] as? String)
        let document = try XCTUnwrap(PDFDocument(data: try b.bytes(other, paper)))
        document.insert(try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage), at: document.pageCount)
        let third = try XCTUnwrap(document.dataRepresentation()), sha = SyncFormat.sha256(third)
        cloud.files["pdf/\(sha).pdf"] = third
        try Self.remote(cloud, seq: 1, [["t": SyncStoreTests.time + 1_000, "op": "doc.upsert", "id": id, "fields": ["pdf_sha256": sha]]])
        try a.sync(cloud)
        XCTAssertEqual(try a.bytes(course, paper), third)
        XCTAssertThrowsError(try a.pdf.handle("nativePDF:binding", ["courseId": course, "relPath": paper]))
    }

    /// A new PDF where a removed one was does not show the removed one's ink (review MEDIUM).
    func testInkOfARemovedPDFStaysOffTheNextFileThere() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차")
        _ = try a.stroke(course, paper)
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        XCTAssertEqual(try b.drawings(other, paper).count, 1)
        _ = try a.library.handle("materials:delete", ["courseId": course, "relPath": paper])
        try a.sync(cloud); try b.sync(cloud)
        try a.context.run("DELETE FROM pdf_document_aliases")
        try a.context.run("UPDATE pdf_drawings SET rel_path='old'")
        XCTAssertEqual(try a.paper(course, "1주차"), paper)
        try a.sync(cloud); try b.sync(cloud)
        XCTAssertEqual(try b.files(other), [paper])
        XCTAssertTrue(try b.drawings(other, paper).isEmpty)
        XCTAssertEqual(try b.context.query("SELECT 1 FROM pdf_drawings WHERE rel_path LIKE '.bandal-sync/removed/%' AND deleted_at IS NULL").count, 1)
        XCTAssertNoThrow(try b.stroke(other, paper))
    }

    func testNoteTextOutsideSpecLinksStaysAsWritten() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리")
        _ = try a.library.handle("notes:create", ["courseId": course, "dirRelPath": "노트", "title": "강의"])
        let text = "# 강의\n![도식](../../assets/diagram.png)\n"
        try a.note(course, "노트/강의.md", text)
        try a.sync(cloud); try b.sync(cloud)
        XCTAssertEqual(try b.text(try b.courseID("물리"), "노트/강의.md"), text)
        XCTAssertEqual(try b.sync(cloud), [])
    }

    /// The flush reached the root but `commit` never ran; a rename made afterwards survives an
    /// apply that runs before the next flush (review MEDIUM).
    func testUncommittedCourseKeepsALaterRename() throws {
        let cloud = Cloud(), a = try Device("iPad A")
        let course = try a.course("물리")
        for write in try a.outbox.prepare(remote: []).writes { if case .data(let data) = write.content { cloud.files[write.path] = data } }
        _ = try a.library.handle("courses:rename", ["courseId": course, "name": "물리학"])
        try a.apply(cloud)
        XCTAssertNoThrow(try a.courseID("물리학"))
        try a.sync(cloud)
        let state = SyncMerge.merge(SyncFormat.readRoot(cloud.files.map { ($0.key, $0.value) }).files)
        XCTAssertEqual(state.courses.values.first?.text("name"), "물리학")
    }

    /// A stroke removed outright here and edited later elsewhere ends removed: the removal is
    /// sent after the edit was read, so it is the later write (review LOW).
    func testOutrightRemovalIsNotUndoneBeforeItIsSent() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리"), paper = try a.paper(course, "1주차"), stroke = try a.stroke(course, paper)
        try a.sync(cloud); try b.sync(cloud)
        try a.context.run("DELETE FROM pdf_drawings WHERE id=?", [stroke])
        _ = try b.pdf.handle("drawings:update", ["id": stroke, "style": ["color": "red", "width": 0.003, "opacity": 1.0]])
        try b.sync(cloud)
        try a.apply(cloud)
        XCTAssertTrue(try a.context.query("SELECT 1 FROM pdf_drawings WHERE id=?", [stroke]).isEmpty)
        try a.sync(cloud); try b.sync(cloud)
        XCTAssertTrue(try b.drawings(try b.courseID("물리"), paper).isEmpty)
    }

    /// A document the folder scan never lists (a dot name) is placed, and not sent back as removed (review LOW).
    func testUnlistedDocumentIsNotSentAsRemoved() throws {
        let cloud = Cloud(), a = try Device("iPad A")
        let course = try a.course("물리")
        try a.sync(cloud)
        let synced = try XCTUnwrap(a.context.query("SELECT sync_id FROM cloud_sync_courses").first?["sync_id"] as? String)
        let doc = "d0000000-0000-4000-8000-0000000000aa", text = Data("숨김\n".utf8)
        try Self.remote(cloud, seq: 1, [["t": Self.time + 10, "op": "doc.upsert", "id": doc,
                                         "fields": ["course_id": synced, "type": "md", "name": ".숨김.md", "rel_path": "", "md_hash": SyncFormat.sha256(text), "md_base": NSNull()]]],
                        notes: [doc: text])
        try a.sync(cloud)
        XCTAssertEqual(try a.text(course, ".숨김.md"), "숨김\n")
        XCTAssertEqual(try a.sync(cloud), [])
    }

    func testSameNameFromTwoDevicesEndsUnderTwoNames() throws {
        let cloud = Cloud(), a = try Device("iPad A"), b = try Device("iPad B")
        let course = try a.course("물리")
        try a.sync(cloud); try b.sync(cloud)
        let other = try b.courseID("물리")
        // M9: the same name made offline on both; the larger id moves aside, alike on both.
        let paper = try a.paper(course, "1주차"), folder = (paper as NSString).deletingLastPathComponent
        XCTAssertEqual(try b.paper(other, "1주차"), paper)
        for device in [a, b, a, b, a] { try device.sync(cloud) }
        let names = try a.files(course)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.last, paper)
        XCTAssertNotNil(names.first?.range(of: "^" + folder + #"/1주차 \([0-9a-f]{4}\)\.pdf$"#, options: .regularExpression))
        XCTAssertEqual(try b.files(other), names)
        XCTAssertEqual(try b.sync(cloud), [])
    }
}
