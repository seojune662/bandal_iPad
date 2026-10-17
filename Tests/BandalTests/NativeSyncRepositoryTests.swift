import Foundation
import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import Bandal

final class NativeSyncRepositoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("native-sync-\(UUID())"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func engine(_ name: String) throws -> (NativeRepositoryContext, NativeLibraryRepository, NativeSyncRepository) {
        let context = try NativeRepositoryContext(root: root.appendingPathComponent(name), legacyRoot: root.appendingPathComponent("Legacy")), library = NativeLibraryRepository(context: context)
        let sync = try NativeSyncRepository(context: context, library: library, checkPDFBinding: { _ in throw NativeRepositoryContext.validation("Unexpected PDF") })
        let artifacts = NativeSyncArtifacts(context: context); sync.registerProjection(snapshot: artifacts.snapshot, plan: { try artifacts.plan($0, assets: $1) })
        return (context, library, sync)
    }
    private func call(_ sync: NativeSyncRepository, _ channel: String, _ request: [String: Any] = [:]) throws -> [String: Any] {
        let value = try sync.handle(channel, request); return try XCTUnwrap(value as? [String: Any])
    }
    private func create(_ library: NativeLibraryRepository) throws -> (String, String) {
        let courseValue = try library.handle("courses:create", ["name": "과목", "color": "green"]), course = try XCTUnwrap(courseValue as? [String: Any]), id = try XCTUnwrap(course["id"] as? String)
        let noteValue = try library.handle("notes:create", ["courseId": id, "dirRelPath": "", "title": "동기화 노트"]), note = try XCTUnwrap(noteValue as? [String: Any]); return (id, try XCTUnwrap(note["relPath"] as? String))
    }
    func testCanonicalRoundTripPreservesUUIDAndUnicodeMarkdown() throws {
        let (a, la, sa) = try engine("A"), (b, lb, sb) = try engine("B"), (course, path) = try create(la)
        let original = "# 원본\n[[한글 링크]] ✍️"
        _ = try la.handle("notes:write", ["courseId": course, "relPath": path, "markdown": original])
        let exported = try call(sa, "nativeSync:export"), imported = try call(sb, "nativeSync:import", exported)
        XCTAssertEqual(imported["applied"] as? Int, 3); XCTAssertTrue((imported["conflicts"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), original)
        XCTAssertEqual(try a.query("SELECT id FROM materials_index").first?["id"] as? String, try b.query("SELECT id FROM materials_index").first?["id"] as? String)
        let next = try call(sb, "nativeSync:export"); XCTAssertEqual((next["records"] as? [[String: Any]])?.count, 3)
        _ = lb
    }
    func testConflictingNotePreservesLocalUntilExplicitSelectionAndReplayKeepsResolution() throws {
        let (_, la, sa) = try engine("A"), (b, lb, sb) = try engine("B"), (course, path) = try create(la)
        _ = try call(sb, "nativeSync:import", call(sa, "nativeSync:export")); _ = try call(sb, "nativeSync:export")
        _ = try lb.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "local latest"])
        _ = try la.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "remote latest"])
        let remote = try call(sa, "nativeSync:export"), result = try call(sb, "nativeSync:import", remote)
        XCTAssertFalse((result["conflicts"] as? [[String: Any]])?.isEmpty ?? true)
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), "local latest")
        let conflicts = try XCTUnwrap(sb.handle("nativeSync:conflicts", [:]) as? [[String: Any]]), selected = try XCTUnwrap(conflicts.first { ($0["recordID"] as? String)?.hasPrefix("note:") == true })
        let restored = try call(sb, "nativeSync:restoreConflict", ["conflictID": selected["id"]!, "variant": "remote"])
        XCTAssertEqual(restored["applied"] as? Int, 1)
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), "remote latest")
        XCTAssertFalse(try b.query("SELECT resolved_at FROM ipad_sync_conflicts WHERE id=?", [selected["id"]!]).first?["resolved_at"] is NSNull)
    }
    func testUnknownEnvelopeAndAssetSurviveReopen() throws {
        let (context, _, sync) = try engine("A"), bytes = Data("future asset".utf8), hash = NativeSyncFormat.hash(bytes), source = root.appendingPathComponent("future.bin")
        try bytes.write(to: source)
        let record = NativeSyncFormat.record(id: "artifact:new-version", kind: "artifact", payload: ["recordType": "future-v9", "opaque": ["keep": true], "assetRevision": hash])
        let result = try call(sync, "nativeSync:import", ["records": [record], "assets": [["sha256": hash, "path": source.path]]])
        XCTAssertEqual(result["applied"] as? Int, 1); try FileManager.default.removeItem(at: source)
        let reopened = try NativeRepositoryContext(root: context.root, legacyRoot: context.legacyRoot), library = NativeLibraryRepository(context: reopened), next = try NativeSyncRepository(context: reopened, library: library, checkPDFBinding: { _ in [:] })
        let exported = try call(next, "nativeSync:export"), saved = try XCTUnwrap((exported["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(try NativeSyncFormat.comparable(saved), try NativeSyncFormat.comparable(record))
        let asset = try XCTUnwrap((exported["assets"] as? [[String: Any]])?.first), path = try XCTUnwrap(asset["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }
    func testInvalidAssetAndDuplicateEnvelopeCannotMutateDatabase() throws {
        let (context, _, sync) = try engine("A"), record = NativeSyncFormat.record(id: "artifact:future", kind: "artifact", payload: ["recordType": "future"])
        XCTAssertThrowsError(try call(sync, "nativeSync:import", ["records": [record, record]]))
        let file = root.appendingPathComponent("bad.bin"); try Data("wrong".utf8).write(to: file)
        XCTAssertThrowsError(try call(sync, "nativeSync:import", ["records": [record], "assets": [["sha256": String(repeating: "0", count: 64), "path": file.path]]]))
        XCTAssertTrue(try context.query("SELECT * FROM ipad_sync_projection").isEmpty)
    }
    func testJournalSQLFailureRestoresOriginalBytesAndPreservesBackup() throws {
        let (context, library, _) = try engine("A"), (course, path) = try create(library), url = try context.materialURL(courseID: course, relativePath: path), original = try Data(contentsOf: url), journal = try NativeSyncJournal(context: context)
        let plan = NativeSyncPlan(files: [.init(target: url, data: Data("replacement".utf8))], apply: { throw NativeRepositoryContext.validation("fixture SQL failure") })
        XCTAssertThrowsError(try journal.apply(plan, commit: {})); XCTAssertEqual(try Data(contentsOf: url), original)
        let files = FileManager.default.enumerator(at: context.root.appendingPathComponent("SyncRecovery"), includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        XCTAssertEqual(files.filter { $0.pathExtension == "original" }.count, 1); XCTAssertTrue(files.filter { $0.lastPathComponent == "intent.json" }.isEmpty)
    }
    func testCrashJournalRestoresBeforeSQLReceiptAndKeepsCommittedBytes() throws {
        let (context, library, _) = try engine("A"), (course, path) = try create(library), target = try context.materialURL(courseID: course, relativePath: path), original = try Data(contentsOf: target), after = Data("published".utf8)
        let id = UUID().uuidString.lowercased(), directory = context.root.appendingPathComponent("SyncRecovery/\(id)"), backup = directory.appendingPathComponent("0.original")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try original.write(to: backup); try after.write(to: target)
        let intent: [String: Any] = ["id": id, "entries": [["target": target.path, "backup": backup.path, "existed": true, "beforeHash": NativeSyncFormat.hash(original), "afterHash": NativeSyncFormat.hash(after)]]]
        try Data(NativeSyncFormat.canonical(intent).utf8).write(to: directory.appendingPathComponent("intent.json"))
        let journal = try NativeSyncJournal(context: context); try journal.recover(); XCTAssertEqual(try Data(contentsOf: target), original)
        try after.write(to: target); try Data(NativeSyncFormat.canonical(intent).utf8).write(to: directory.appendingPathComponent("intent.json")); try context.run("INSERT INTO ipad_sync_commits(id) VALUES(?)", [id]); try journal.recover(); XCTAssertEqual(try Data(contentsOf: target), after)
    }
    func testSnapshotHashPreventsExternalEditDuringPlanningFromBeingOverwritten() throws {
        let (context, library, _) = try engine("A"), (course, path) = try create(library), url = try context.materialURL(courseID: course, relativePath: path)
        let original = try Data(contentsOf: url), journal = try NativeSyncJournal(context: context)
        let plan = NativeSyncPlan(files: [.init(target: url, data: Data("remote".utf8), expectedHash: NativeSyncFormat.hash(original))])
        try Data("external newer".utf8).write(to: url)
        XCTAssertThrowsError(try journal.apply(plan, commit: {})); XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external newer")
    }

    func testMaterialAndNoteDeletionEnvelopeAppliesWithoutOrphanConflict() throws {
        let (_, la, sa) = try engine("A"), (b, _, sb) = try engine("B"), (course, path) = try create(la)
        _ = try call(sb, "nativeSync:import", call(sa, "nativeSync:export"))
        _ = try call(sb, "nativeSync:export")
        _ = try la.handle("materials:delete", ["courseId": course, "relPath": path])
        let imported = try call(sb, "nativeSync:import", call(sa, "nativeSync:export"))
        XCTAssertTrue((imported["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(imported)")
        XCTAssertEqual(imported["applied"] as? Int, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try b.materialURL(courseID: course, relativePath: path, allowMissing: true).path))
        XCTAssertTrue(try b.query("SELECT id FROM materials_index WHERE deleted_at IS NULL").isEmpty)
    }

    func testRepeatedUnchangedExchangeDoesNotInvalidateOpenCourseEditors() throws {
        let (_, la, sa) = try engine("A"), (_, _, sb) = try engine("B")
        _ = try create(la)
        let first = try call(sa, "nativeSync:export")
        _ = try call(sb, "nativeSync:import", first)
        _ = try call(sb, "nativeSync:export")
        let replay = try call(sb, "nativeSync:import", first)
        XCTAssertEqual(replay["applied"] as? Int, 3)
        XCTAssertEqual(replay["changedCourseIDs"] as? [String], [])
        XCTAssertTrue((replay["conflicts"] as? [[String: Any]])?.isEmpty == true)
    }

    func testPartialImportFailureIdentifiesCommittedAndUncertainCourses() throws {
        let (context, library, sync) = try engine("A")
        let (firstCourse, firstPath) = try create(library), (secondCourse, secondPath) = try create(library), (untouchedCourse, _) = try create(library)
        let firstURL = try context.materialURL(courseID: firstCourse, relativePath: firstPath)
        let secondURL = try context.materialURL(courseID: secondCourse, relativePath: secondPath)
        let originalSecond = try Data(contentsOf: secondURL)
        let exported = try call(sync, "nativeSync:export")
        let materialID = try XCTUnwrap(context.query("SELECT id FROM materials_index WHERE course_id=?", [firstCourse]).first?["id"] as? String)
        var note = try XCTUnwrap((exported["records"] as? [[String: Any]])?.first { $0["id"] as? String == "note:" + materialID })
        var payload = try XCTUnwrap(note["payload"] as? [String: Any]); payload["markdown"] = "remote committed"; note["payload"] = payload
        sync.registerProjection(snapshot: { NativeSyncSnapshot() }, plan: { record, _ in
            guard record["id"] as? String == "artifact:recovery-failure" else { return nil }
            return NativeSyncPlan(files: [.init(target: secondURL, data: Data("remote second".utf8))], courseID: secondCourse, apply: {
                // An external writer wins after publication. SQL then fails;
                // recovery must preserve that writer and retain our originals.
                try Data("external newer".utf8).write(to: secondURL)
                throw NativeRepositoryContext.validation("Injected SQL failure")
            })
        })
        let failure = NativeSyncFormat.record(id: "artifact:recovery-failure", kind: "artifact", payload: ["recordType": "fixture"])
        do {
            _ = try call(sync, "nativeSync:import", ["records": [note, failure], "assets": []])
            XCTFail("Expected an incomplete recovery")
        } catch let error as NativeSyncImportFailure {
            XCTAssertEqual(error.changedCourseIDs, Set([firstCourse, secondCourse]))
            XCTAssertFalse(error.changedCourseIDs.contains(untouchedCourse))
            XCTAssertEqual((error.underlyingError as? DesktopRuntimeError)?.code, "RECOVERY_REQUIRED")
        }
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "remote committed")
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "external newer")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: context.root.appendingPathComponent("SyncRecovery"), includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
        XCTAssertTrue(try files.filter { $0.pathExtension == "original" }.contains { try Data(contentsOf: $0) == originalSecond })
        XCTAssertEqual(files.filter { $0.lastPathComponent == "intent.json" }.count, 1)
    }

    func testRolledBackCourseDoesNotInvalidateItsOpenEditors() throws {
        let (context, library, sync) = try engine("A")
        let (firstCourse, firstPath) = try create(library), (secondCourse, secondPath) = try create(library)
        let firstURL = try context.materialURL(courseID: firstCourse, relativePath: firstPath), secondURL = try context.materialURL(courseID: secondCourse, relativePath: secondPath)
        let secondOriginal = try Data(contentsOf: secondURL), exported = try call(sync, "nativeSync:export")
        let materialID = try XCTUnwrap(context.query("SELECT id FROM materials_index WHERE course_id=?", [firstCourse]).first?["id"] as? String)
        var note = try XCTUnwrap((exported["records"] as? [[String: Any]])?.first { $0["id"] as? String == "note:" + materialID })
        var payload = try XCTUnwrap(note["payload"] as? [String: Any]); payload["markdown"] = "remote committed"; note["payload"] = payload
        sync.registerProjection(snapshot: { NativeSyncSnapshot() }, plan: { record, _ in
            guard record["id"] as? String == "artifact:sql-failure" else { return nil }
            return NativeSyncPlan(files: [.init(target: secondURL, data: Data("replacement".utf8))], courseID: secondCourse, apply: { throw NativeRepositoryContext.validation("Injected SQL failure") })
        })
        let failure = NativeSyncFormat.record(id: "artifact:sql-failure", kind: "artifact", payload: ["recordType": "fixture"])
        let result = try call(sync, "nativeSync:import", ["records": [note, failure], "assets": []])
        XCTAssertEqual(result["changedCourseIDs"] as? [String], [firstCourse])
        XCTAssertEqual((result["conflicts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "remote committed")
        XCTAssertEqual(try Data(contentsOf: secondURL), secondOriginal)
    }

    func testCommittedJournalCleanupFailureKeepsSuccessfulPublication() throws {
        let (context, library, _) = try engine("A"), (course, path) = try create(library)
        let target = try context.materialURL(courseID: course, relativePath: path), journal = try NativeSyncJournal(context: context)
        let recoveryRoot = context.root.appendingPathComponent("SyncRecovery")
        var protectedDirectory: URL?
        defer { if let protectedDirectory { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path) } }
        let plan = NativeSyncPlan(files: [.init(target: target, data: Data("committed".utf8))], apply: {
            let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil).first)
            protectedDirectory = directory
            // The file/SQL commit can succeed while private journal cleanup is
            // denied. This must still report the successful document change.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        })
        try journal.apply(plan, commit: {})
        let directory = try XCTUnwrap(protectedDirectory), intent = directory.appendingPathComponent("intent.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
        XCTAssertEqual(try context.query("SELECT id FROM ipad_sync_commits").count, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "committed")
        XCTAssertNoThrow(try journal.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try journal.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: intent.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "committed")
    }

    func testConflictReceiptFailureStillIdentifiesReplacedDocument() throws {
        let (_, sourceLibrary, sourceSync) = try engine("Source"), (context, library, sync) = try engine("Target")
        let (course, path) = try create(sourceLibrary)
        _ = try call(sync, "nativeSync:import", call(sourceSync, "nativeSync:export"))
        _ = try call(sync, "nativeSync:export")
        _ = try library.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "local latest"])
        _ = try sourceLibrary.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "selected remote"])
        _ = try call(sync, "nativeSync:import", call(sourceSync, "nativeSync:export"))
        let conflicts = try XCTUnwrap(sync.handle("nativeSync:conflicts", [:]) as? [[String: Any]])
        let conflict = try XCTUnwrap(conflicts.first { ($0["recordID"] as? String)?.hasPrefix("note:") == true })
        try context.db.exec("CREATE TRIGGER fail_resolution BEFORE UPDATE OF resolved_at ON ipad_sync_conflicts BEGIN SELECT RAISE(FAIL,'injected resolution receipt failure'); END")
        do {
            _ = try call(sync, "nativeSync:restoreConflict", ["conflictID": conflict["id"]!, "variant": "remote"])
            XCTFail("Expected a conflict receipt failure after materialization")
        } catch let failure as NativeSyncImportFailure {
            XCTAssertEqual(failure.changedCourseIDs, [course])
            XCTAssertTrue(failure.underlyingError.localizedDescription.contains("injected resolution receipt failure"))
        }
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: course, relativePath: path), encoding: .utf8), "selected remote")
        XCTAssertTrue(try context.query("SELECT resolved_at FROM ipad_sync_conflicts WHERE id=?", [conflict["id"]!]).first?["resolved_at"] is NSNull)
    }

    func testRunningExportCannotReplayUncommittedFileRecoveryBehindEditors() throws {
        let (context, library, sync) = try engine("A"), (course, path) = try create(library)
        let target = try context.materialURL(courseID: course, relativePath: path), before = try Data(contentsOf: target), after = Data("published before a crash".utf8)
        let id = UUID().uuidString.lowercased(), directory = context.root.appendingPathComponent("SyncRecovery/" + id), backup = directory.appendingPathComponent("0.original")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try before.write(to: backup); try after.write(to: target)
        let intent: [String: Any] = ["id": id, "entries": [["target": target.path, "backup": backup.path, "existed": true, "beforeHash": NativeSyncFormat.hash(before), "afterHash": NativeSyncFormat.hash(after)]]]
        try Data(NativeSyncFormat.canonical(intent).utf8).write(to: directory.appendingPathComponent("intent.json"))
        do { _ = try sync.handle("nativeSync:export", [:]); XCTFail("Running export must not replay file recovery") }
        catch { XCTAssertEqual((error as? DesktopRuntimeError)?.code, "RECOVERY_REQUIRED") }
        XCTAssertEqual(try Data(contentsOf: target), after)
        try NativeSyncRepository.recoverFiles(context: context)
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertNoThrow(try sync.handle("nativeSync:export", [:]))
    }

    func testConflictRestoreKeepsNewerDraftAsNewConflictBeforeApplyingExplicitChoice() throws {
        let (_, la, sa) = try engine("A"), (b, lb, sb) = try engine("B"), (course, path) = try create(la)
        _ = try call(sb, "nativeSync:import", call(sa, "nativeSync:export"))
        _ = try lb.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "local reviewed version"])
        _ = try la.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "remote reviewed version"])
        _ = try call(sb, "nativeSync:import", call(sa, "nativeSync:export"))
        let values = try sb.handle("nativeSync:conflicts", [:])
        let conflicts = try XCTUnwrap(values as? [[String: Any]]), selected = try XCTUnwrap(conflicts.first { ($0["recordID"] as? String)?.hasPrefix("note:") == true })
        _ = try lb.handle("notes:write", ["courseId": course, "relPath": path, "markdown": "new local draft after review"])
        try b.db.exec("CREATE TRIGGER fail_draft_preservation BEFORE INSERT ON ipad_sync_conflicts BEGIN SELECT RAISE(ABORT,'fixture conflict disk failure'); END")
        XCTAssertThrowsError(try call(sb, "nativeSync:restoreConflict", ["conflictID": selected["id"]!, "variant": "remote"]))
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), "new local draft after review")
        XCTAssertTrue(try b.query("SELECT resolved_at FROM ipad_sync_conflicts WHERE id=?", [selected["id"]!]).first?["resolved_at"] is NSNull)
        try b.db.exec("DROP TRIGGER fail_draft_preservation")
        // Matching the desktop projector: a draft edited after review is kept as
        // a new conflict and the earlier choice is not applied over it.
        let result = try call(sb, "nativeSync:restoreConflict", ["conflictID": selected["id"]!, "variant": "remote"])
        XCTAssertEqual(result["applied"] as? Int, 0)
        XCTAssertEqual(result["resolved"] as? Bool, false)
        XCTAssertFalse((result["conflicts"] as? [[String: Any]])?.isEmpty ?? true)
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), "new local draft after review")
        XCTAssertTrue(try b.query("SELECT resolved_at FROM ipad_sync_conflicts WHERE id=?", [selected["id"]!]).first?["resolved_at"] is NSNull)
        let (_, _, reopened) = try engine("B")
        let reopenedValue = try reopened.handle("nativeSync:conflicts", [:])
        let retained = try XCTUnwrap(reopenedValue as? [[String: Any]])
        let newer = try XCTUnwrap(retained.first { (($0["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String == "new local draft after review" })
        XCTAssertTrue(retained.contains { $0["id"] as? String == selected["id"] as? String })
        let applied = try call(reopened, "nativeSync:restoreConflict", ["conflictID": newer["id"]!, "variant": "remote"])
        XCTAssertEqual(applied["applied"] as? Int, 1)
        XCTAssertEqual(try String(contentsOf: b.materialURL(courseID: course, relativePath: path), encoding: .utf8), "remote reviewed version")
        XCTAssertFalse(try b.query("SELECT resolved_at FROM ipad_sync_conflicts WHERE id=?", [newer["id"]!]).first?["resolved_at"] is NSNull)
    }


    // MARK: PDF page lineage (desktop `pdfLineage` wire format)
    private struct PageDevice {
        let context: NativeRepositoryContext, library: NativeLibraryRepository, pdf: NativePDFRepository, sync: NativeSyncRepository
        init(root: URL) throws {
            context = try NativeRepositoryContext(root: root.appendingPathComponent("root"), legacyRoot: root.appendingPathComponent("legacy"))
            library = NativeLibraryRepository(context: context); pdf = try NativePDFRepository(context: context)
            sync = try NativeSyncRepository(context: context, library: library, checkPDFBinding: pdf.checkBinding)
            let drawings = NativeSyncDrawings(context: context, pdf: pdf)
            sync.registerProjection(snapshot: { try drawings.snapshot() }, plan: { try drawings.plan($0, assets: $1) })
        }
        func exchange(_ channel: String, _ request: [String: Any] = [:]) throws -> [String: Any] { try XCTUnwrap(try sync.handle(channel, request) as? [String: Any]) }
    }
    private static func pagesDocument() throws -> Data {
        let document = PDFDocument()
        for index in 1...3 {
            let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 300, height: 420)
            let canvas = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
            canvas.beginPDFPage(nil); canvas.setFillColor(CGColor(gray: 0, alpha: 1)); canvas.textPosition = CGPoint(x: 40, y: 240)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(index)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)])), canvas)
            canvas.endPDFPage(); canvas.closePDF()
            document.insert(try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0)), at: document.pageCount)
        }
        return try XCTUnwrap(document.dataRepresentation())
    }
    /// A page restructure travels as the desktop `pdfLineage` recipe and applies on
    /// another device without changing the material identity or losing its ink.
    func testRestructureRoundTripsAsDesktopLineageAndKeepsOldEnvelopesAsHistory() throws {
        let a = try PageDevice(root: root.appendingPathComponent("A")), b = try PageDevice(root: root.appendingPathComponent("B")), path = "원본.pdf"
        let course = try XCTUnwrap((try a.library.handle("courses:create", ["name": "페이지", "color": "green"]) as? [String: Any])?["id"] as? String)
        let original = try Self.pagesDocument(); try a.context.atomicWrite(original, to: a.context.materialURL(courseID: course, relativePath: path, allowMissing: true))
        _ = try a.library.handle("materials:tree", ["courseId": course])
        let binding = try a.pdf.checkBinding(["courseId": course, "relPath": path]), material = binding["materialID"] as! String, from = binding["documentRevision"] as! String
        try a.context.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", ["ink-3", course, path, 3, "rect", "{\"box\":{\"x\":0.1,\"y\":0.2,\"width\":0.3,\"height\":0.1}}", "{\"color\":\"red\",\"width\":0.01,\"opacity\":1}", "2026-01-01", "2026-01-01"])
        let first = try a.exchange("nativeSync:export"), initial = try b.exchange("nativeSync:import", first)
        XCTAssertTrue((initial["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(initial)")
        let oldEnvelope = try XCTUnwrap((first["records"] as? [[String: Any]])?.first { $0["id"] as? String == "drawing:\(material):\(from):3" })

        let changed = try XCTUnwrap(try NativePDFPageRepository(context: a.context, pdf: a.pdf).handle("pdf:restructure", ["courseId": course, "relPath": path, "documentRevision": from, "clientMutationId": UUID().uuidString, "pages": [3, 1]]) as? [String: Any])
        let to = changed["documentRevision"] as! String
        let exported = try a.exchange("nativeSync:export")
        let record = try XCTUnwrap((exported["records"] as? [[String: Any]])?.first { $0["id"] as? String == "material:\(material)" }), payload = record["payload"] as! [String: Any]
        XCTAssertEqual(try NativeSyncFormat.canonical(payload["pdfLineage"]!), try NativeSyncFormat.canonical([["from": from, "to": to, "pages": [["source": 3], ["source": 1]]]]))
        XCTAssertNil((payload["desktop"] as? [String: Any])?["pageLineage"])
        let sizes = Dictionary(uniqueKeysWithValues: (payload["pdfLineageAssets"] as! [[String: Any]]).map { ($0["sha256"] as! String, ($0["byteCount"] as! NSNumber).intValue) })
        XCTAssertEqual(sizes[from], original.count); XCTAssertEqual(sizes[to], (payload["byteCount"] as! NSNumber).intValue)
        XCTAssertTrue((exported["assets"] as! [[String: Any]]).contains { $0["sha256"] as? String == from && $0["materialID"] as? String == material })

        let imported = try b.exchange("nativeSync:import", exported)
        XCTAssertTrue((imported["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(imported)")
        XCTAssertEqual(try Data(contentsOf: b.context.materialURL(courseID: course, relativePath: path)), try Data(contentsOf: a.context.materialURL(courseID: course, relativePath: path)))
        XCTAssertEqual(try b.pdf.checkBinding(["courseId": course, "relPath": path])["documentRevision"] as? String, to)
        XCTAssertEqual(try b.context.query("SELECT page FROM pdf_drawings WHERE id='ink-3' AND deleted_at IS NULL").first?["page"] as? Int, 1)
        let rows = try b.context.query("SELECT from_sha,to_sha,pages_json FROM native_pdf_revision_lineage WHERE material_id=?", [material])
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["from_sha"] as? String, from); XCTAssertEqual(rows.first?["to_sha"] as? String, to)
        XCTAssertEqual(rows.first?["pages_json"] as? String, try NativeSyncFormat.canonical([["source": 3], ["source": 1]]))

        // The desktop keeps emitting live old-revision envelopes after a rewrite.
        let history = try b.exchange("nativeSync:import", ["records": [oldEnvelope]])
        XCTAssertTrue((history["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(history)"); XCTAssertEqual(history["applied"] as? Int, 1)
        XCTAssertEqual(try b.context.query("SELECT page FROM pdf_drawings WHERE id='ink-3' AND deleted_at IS NULL").first?["page"] as? Int, 1)
        XCTAssertEqual(try b.context.query("SELECT * FROM pdf_drawings").count, 1)
    }
}
