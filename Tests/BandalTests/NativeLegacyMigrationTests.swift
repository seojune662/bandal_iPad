import Foundation
import CoreGraphics
import PDFKit
import XCTest
@testable import Bandal

final class NativeLegacyMigrationTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var legacy: URL { root.appendingPathComponent("Legacy") }
    private let course = "11111111-1111-4111-a111-111111111111"
    private let material = "22222222-2222-4222-a222-222222222222"
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("native-legacy-\(UUID())"); context = try NativeRepositoryContext(root: root.appendingPathComponent("Current"), legacyRoot: legacy) }
    override func tearDownWithError() throws { context = nil; try FileManager.default.removeItem(at: root) }
    private func store(_ records: [[String: Any]], receipts: [String] = []) throws {
        let db = try DesktopSQLite(url: legacy.appendingPathComponent("bandal.sqlite"))
        try db.exec("CREATE TABLE records(id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload BLOB NOT NULL,revision INTEGER,deleted INTEGER,format_version INTEGER); CREATE TABLE local_mutation_receipts(mutation_id TEXT PRIMARY KEY)")
        for r in records { let data = Data(try NativeSyncFormat.canonical(r["payload"]!).utf8); _ = try db.run("INSERT INTO records VALUES(?,?,?,?,?,?)", params: [r["id"]!, r["kind"]!, ["__buffer": data.base64EncodedString()], 3, r["deleted"] as? Bool == true ? 1 : 0, 1]) }
        for receipt in receipts { _ = try db.run("INSERT INTO local_mutation_receipts VALUES(?)", params: [receipt]) }
    }
    private func record(_ id: String, _ kind: String, _ payload: [String: Any]) -> [String: Any] { NativeSyncFormat.record(id: id, kind: kind, payload: payload) }
    private func courseRecord() -> [String: Any] { record("course:" + course, "course", ["id": course, "name": "이전 과목", "color": "blue"]) }
    private func noteRecords(_ markdown: String = "stored note") -> [[String: Any]] { [courseRecord(), record("material:" + material, "material", ["id": material, "courseID": course, "kind": "note", "title": "보존할 제목", "fileName": "note.md", "revision": "note"]), record("note:" + material, "note", ["materialID": material, "markdown": markdown])] }
    private func apply() throws { let pdf = try NativePDFRepository(context: context); try NativeLegacyMigration.apply(context: context, library: NativeLibraryRepository(context: context), pdf: pdf) }
    private func pending(_ sequence: Int, mutation: String, markdown: String) throws -> URL {
        let folder = legacy.appendingPathComponent("PendingEdits"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(String(format: "%020d", sequence) + ".json"), payload = Data(try NativeSyncFormat.canonical(["materialID": material, "markdown": markdown]).utf8)
        try Data(NativeSyncFormat.canonical(["mutationID": mutation, "id": "note:" + material, "kind": "note", "payload": payload.base64EncodedString()]).utf8).write(to: url); return url
    }
    func testPendingEditsOverrideStoredRecordButReceiptedEntryCannotResurrectIt() throws {
        try store(noteRecords(), receipts: ["already-accepted"])
        let first = try pending(1, mutation: "new-one", markdown: "unsaved newest"), ignored = try pending(2, mutation: "already-accepted", markdown: "stale accepted value")
        let db = try Data(contentsOf: legacy.appendingPathComponent("bandal.sqlite")), originalPending = try Data(contentsOf: first)
        try apply()
        let row = try XCTUnwrap(context.query("SELECT rel_path FROM materials_index WHERE id=?", [material]).first), path = try XCTUnwrap(row["rel_path"] as? String)
        XCTAssertEqual(path, "보존할 제목.md"); XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: course, relativePath: path), encoding: .utf8), "unsaved newest")
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("bandal.sqlite")), db); XCTAssertEqual(try Data(contentsOf: first), originalPending); XCTAssertTrue(FileManager.default.fileExists(atPath: ignored.path))
        let receipt = try XCTUnwrap(context.query("SELECT report_json FROM ipad_legacy_migrations").first?["report_json"] as? String)
        try apply(); XCTAssertEqual(try context.query("SELECT report_json FROM ipad_legacy_migrations").first?["report_json"] as? String, receipt)
        XCTAssertEqual((try context.query("SELECT COUNT(*) n FROM courses").first?["n"] as? NSNumber)?.intValue, 1)
    }
    func testCorruptAssetRejectsAllRowsAndSuccessfulRetryKeepsOriginal() throws {
        let expected = Data("correct bytes".utf8), hash = NativeSyncFormat.hash(expected), source = legacy.appendingPathComponent("Materials/\(material)/source.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("corrupted".utf8).write(to: source)
        try store([courseRecord(), record("material:" + material, "material", ["id": material, "courseID": course, "kind": "file", "title": "Source", "fileName": "source.bin", "revision": hash, "byteCount": expected.count])])
        XCTAssertThrowsError(try apply()); XCTAssertTrue(try context.query("SELECT * FROM courses").isEmpty); XCTAssertTrue(try context.query("SELECT * FROM ipad_legacy_archive").isEmpty); XCTAssertTrue(try context.query("SELECT * FROM ipad_legacy_migrations").isEmpty)
        try expected.write(to: source); try apply()
        XCTAssertEqual(try Data(contentsOf: source), expected); XCTAssertEqual(try Data(contentsOf: context.materialURL(courseID: course, relativePath: "source.bin")), expected)
    }
    func testOpaqueArchiveKeepsUnknownEnvelopeAndOriginalPendingFile() throws {
        let opaque: [String: Any] = ["recordType": "future-material-v12", "blob": ["newField": [1, 2, 3]], "unrecognized": true]
        try store(noteRecords() + [record("artifact:opaque", "artifact", opaque)])
        try apply(); let saved = try XCTUnwrap(context.query("SELECT payload_json FROM ipad_legacy_archive WHERE record_id='artifact:opaque'").first?["payload_json"] as? String)
        XCTAssertEqual(try NativeSyncFormat.canonical(NativeSyncFormat.object(saved)), try NativeSyncFormat.canonical(opaque))
        let report = try NativeSyncFormat.object(context.query("SELECT report_json FROM ipad_legacy_migrations").first?["report_json"])
        XCTAssertEqual(report["archivedKinds"] as? [String], ["artifact"])
    }
    func testRotatedPDFKeepsMeasuredSamplesAndHistoricalPagesArchived() throws {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 300, height: 500)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data)), writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil)); writer.beginPDFPage(nil); writer.endPDFPage(); writer.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data)), page = try XCTUnwrap(document.page(at: 0)); page.rotation = 90
        let bytes = try XCTUnwrap(document.dataRepresentation()), hash = NativeSyncFormat.hash(bytes), source = legacy.appendingPathComponent("Materials/\(material)/\(NativeSyncFormat.hash(Data(hash.utf8)))/source.pdf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: source)
        let exact = Double("0.00016200891049007697")!, point: [String: Any] = ["x": 0.2, "y": 0.3, "p": exact, "t": exact, "tiltX": exact, "tiltY": exact]
        let object: [String: Any] = ["id": "measured-stroke", "kind": "ink", "data": ["inkVersion": 5, "points": [point, point]], "style": ["width": 0.003, "color": "ink", "opacity": 1], "createdAt": "created", "updatedAt": "updated"]
        var portable: [String: Any] = ["schemaVersion": 1, "materialID": material, "documentRevision": hash, "page": 1, "coordinateSpace": NativeSyncFormat.coordinateSpace, "geometry": try NativeSyncInkGeometry.pages(source)[0], "objects": [object], "highlights": [], "deletedObjectIDs": [], "deletedHighlightIDs": []]
        let drawing = record("drawing:\(material):\(hash):1", "drawing", try NativeSyncFormat.encodePage(portable)); portable["documentRevision"] = String(repeating: "0", count: 64)
        let old = record("drawing:historical", "drawing", try NativeSyncFormat.encodePage(portable))
        try store([courseRecord(), record("material:" + material, "material", ["id": material, "courseID": course, "kind": "pdf", "title": "Source", "fileName": "source.pdf", "revision": hash, "byteCount": bytes.count]), drawing, old]); try apply()
        let stored = try NativeSyncFormat.object(context.query("SELECT data_json FROM pdf_drawings").first?["data_json"]), restored = try XCTUnwrap((stored["points"] as? [[String: Any]])?.first)
        XCTAssertEqual((restored["x"] as! NSNumber).doubleValue, 0.7, accuracy: 1e-12); XCTAssertEqual((restored["y"] as! NSNumber).doubleValue, 0.2, accuracy: 1e-12)
        for key in ["p", "t", "tiltX", "tiltY"] { XCTAssertEqual((restored[key] as! NSNumber).doubleValue.bitPattern, exact.bitPattern) }
        let report = try NativeSyncFormat.object(context.query("SELECT report_json FROM ipad_legacy_migrations").first?["report_json"]); XCTAssertEqual(report["historicalPages"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testInterruptedFloatAudioRepairsDerivedHeaderWithoutTouchingOriginal() throws {
        let source = root.appendingPathComponent("interrupted.wav"), target = root.appendingPathComponent("converted.wav")
        var bytes = PCMRecordingWriter.header(samples: 0, encoding: .float32)
        for value: Float in [-1, -0.5, 0, 0.5, 1] { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
        try bytes.write(to: source); let samples = try NativeLegacyAudio.copy(source: source, target: target, context: context)
        XCTAssertEqual(samples, 5); XCTAssertEqual(try Data(contentsOf: source), bytes)
        let converted = try Data(contentsOf: target); XCTAssertEqual(converted.count, 54); XCTAssertEqual(Array(converted[40..<44]), [10, 0, 0, 0])
        XCTAssertEqual(Array(converted[44...]), [0, 128, 0, 192, 0, 0, 0, 64, 255, 127])
        XCTAssertEqual(try NativeLegacyAudio.copy(source: source, target: target, context: context), 5)
    }
    func testDifferingExistingTargetAndInvalidAudioPreserveBothSources() throws {
        try store(noteRecords()); let target = context.root.appendingPathComponent("Courses/iPad/\(course)/보존할 제목.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("newer destination".utf8).write(to: target)
        XCTAssertThrowsError(try apply()); XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "newer destination"); XCTAssertTrue(try context.query("SELECT * FROM courses").isEmpty)
        let source = root.appendingPathComponent("invalid.wav"), output = root.appendingPathComponent("invalid-output.wav")
        try Data("not wave".utf8).write(to: source); XCTAssertThrowsError(try NativeLegacyAudio.copy(source: source, target: output, context: context)); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testNavigationRestoreRetryUsesMigrationReceiptAndNeverRewritesNewerNote() throws {
        let tab = "33333333-3333-4333-a333-333333333333"
        let workspace = record("workspace:ipad", "workspace", ["selectedCourseID": course, "tabs": [["id": tab, "materialID": material, "courseID": course]], "primaryID": tab, "splitEnabled": false])
        try store(noteRecords() + [workspace]); try apply()
        let navigation = context.root.appendingPathComponent("native-workspace.json"), selection = context.root.appendingPathComponent("native-workspace-selection.json")
        let first = try NativeSyncFormat.object(String(contentsOf: navigation, encoding: .utf8))
        XCTAssertEqual(first["activeID"] as? String, course + ":보존할 제목.md")
        XCTAssertEqual(try NativeSyncFormat.object(String(contentsOf: selection, encoding: .utf8))["courseID"] as? String, course)
        let url = try context.materialURL(courseID: course, relativePath: "보존할 제목.md"); try Data("newer Swift edit".utf8).write(to: url)
        try FileManager.default.removeItem(at: navigation); try apply()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newer Swift edit")
        XCTAssertEqual(try NativeSyncFormat.object(String(contentsOf: navigation, encoding: .utf8))["activeID"] as? String, course + ":보존할 제목.md")
        XCTAssertEqual((try context.query("SELECT COUNT(*) n FROM ipad_legacy_migrations").first?["n"] as? NSNumber)?.intValue, 1)
    }

}
