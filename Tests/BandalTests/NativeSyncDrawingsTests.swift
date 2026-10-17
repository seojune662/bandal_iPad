import XCTest
import PDFKit
@testable import Bandal

@MainActor
final class NativeSyncDrawingsTests: XCTestCase {
    func testStoredAndPortableJSONKeepExactMeasuredDoubleBits() throws {
        let spelling = "0.00016200891049007697", expected = try XCTUnwrap(Double(spelling))
        let raw = "{\"inkVersion\":5,\"points\":[{\"x\":\(spelling),\"y\":\(spelling),\"p\":\(spelling),\"t\":\(spelling),\"tiltX\":\(spelling),\"tiltY\":\(spelling)}]}"
        let stored = try NativePDFRepositoryValidation.parse(raw) as! [String: Any]
        let page: [String: Any] = ["materialID": "material", "documentRevision": "revision", "page": 1, "objects": [["data": stored]]]
        let record = NativeSyncFormat.record(id: "drawing", kind: "drawing", payload: try NativeSyncFormat.encodePage(page))
        let restored = try NativeSyncFormat.decodePage(record)
        for value in [stored, ((restored["objects"] as! [[String: Any]])[0]["data"] as! [String: Any])] {
            let point = (value["points"] as! [[String: Any]])[0]
            for key in ["x", "y", "p", "t", "tiltX", "tiltY"] { XCTAssertEqual((point[key] as! NSNumber).doubleValue.bitPattern, expected.bitPattern, key) }
        }
    }
    func testPortableRotationsPreserveMeasuredInkAndLegacyWidth() throws {
        let original = stroke(id: "sample")
        for rotation in [0, 90, 180, 270] {
            let geometry: [String: Any] = ["cropX": 20, "cropY": 30, "width": 300, "height": 500, "rotation": rotation]
            let portable = try NativeSyncInkGeometry.shape(original, geometry: geometry)
            let points = (portable["data"] as! [String: Any])["points"] as! [[String: Any]]
            let expected: [Int: (Double, Double)] = [0: (0.2, 0.3), 90: (0.3, 0.8), 180: (0.8, 0.7), 270: (0.7, 0.2)]
            XCTAssertEqual((points[0]["x"] as! NSNumber).doubleValue, expected[rotation]!.0, accuracy: 1e-12)
            XCTAssertEqual((points[0]["y"] as! NSNumber).doubleValue, expected[rotation]!.1, accuracy: 1e-12)
            let restored = try NativeSyncInkGeometry.shape(portable, geometry: geometry, inverse: true)
            let data = restored["data"] as! [String: Any], restoredPoints = data["points"] as! [[String: Any]]
            XCTAssertEqual(data["inkVersion"] as? Int, 5)
            XCTAssertEqual(data["futureMetadata"] as? String, "preserved")
            for (a, b) in zip(restoredPoints, (original["data"] as! [String: Any])["points"] as! [[String: Any]]) {
                for key in ["x", "y", "p", "t", "tiltX", "tiltY"] { XCTAssertEqual((a[key] as! NSNumber).doubleValue, (b[key] as! NSNumber).doubleValue, accuracy: 1e-12) }
            }
            XCTAssertEqual(((restored["style"] as! [String: Any])["width"] as! NSNumber).doubleValue, 0.003, accuracy: 1e-12)
        }
    }

    func testRotatedPDFSnapshotImportsWithoutChangingReceiptOrMeasuredMetadata() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let binding = try f.pdf.checkBinding(["courseId": f.course, "relPath": f.path]), revision = binding["documentRevision"] as! String
        var input = stroke(id: "unused"); input.removeValue(forKey: "id")
        input["courseId"] = f.course; input["relPath"] = f.path; input["page"] = 1; input["documentRevision"] = revision; input["clientMutationId"] = UUID().uuidString
        let row = try f.pdf.handle("drawings:create", input) as! [String: Any], rowID = row["id"] as! String
        let receipts = try f.context.query("SELECT * FROM drawing_create_receipts")
        let snapshot = try f.sync.snapshot(), record = try XCTUnwrap(snapshot.records.first { $0["kind"] as? String == "drawing" })
        let portable = try NativeSyncFormat.decodePage(record), geometry = portable["geometry"] as! [String: Any]
        XCTAssertEqual(geometry["rotation"] as? Int, 90)
        XCTAssertEqual((geometry["cropX"] as! NSNumber).doubleValue, 20)
        try f.context.run("UPDATE pdf_drawings SET deleted_at='removed'")
        let planned = try f.sync.plan(record, assets: [:]); try XCTUnwrap(planned).apply()
        let after = try XCTUnwrap(try f.pdf.listDrawings(["courseId": f.course, "relPath": f.path]).first)
        XCTAssertEqual(after["id"] as? String, rowID)
        let points = (after["data"] as! [String: Any])["points"] as! [[String: Any]], before = (row["data"] as! [String: Any])["points"] as! [[String: Any]]
        for (a, b) in zip(points, before) { for key in ["x", "y", "p", "t", "tiltX", "tiltY"] { XCTAssertEqual((a[key] as! NSNumber).doubleValue, (b[key] as! NSNumber).doubleValue, accuracy: 1e-12) } }
        XCTAssertEqual(try f.context.query("SELECT * FROM drawing_create_receipts") as NSArray, receipts as NSArray)
    }

    func testPageDeletionDeletesBothInkAndHighlightsAndProjectsTombstones() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var request: [String: Any] = ["courseId": f.course, "relPath": f.path, "page": 1, "color": "yellow", "rects": [["x": 0.1, "y": 0.2, "width": 0.2, "height": 0.05]], "anchor": ["quote": "Source", "prefix": "", "suffix": ""]]
        let annotation = try f.pdf.handle("annotations:create", request) as! [String: Any]
        request = stroke(id: "unused"); request.removeValue(forKey: "id"); request.merge(["courseId": f.course, "relPath": f.path, "page": 1]) { _, n in n }
        let drawing = try f.pdf.handle("drawings:create", request) as! [String: Any]
        var record = try XCTUnwrap(try f.sync.snapshot().records.first { $0["kind"] as? String == "drawing" })
        var page = try NativeSyncFormat.decodePage(record); page["objects"] = []; page["highlights"] = []; record["payload"] = try NativeSyncFormat.encodePage(page); record["deleted"] = true
        let planned = try f.sync.plan(record, assets: [:]); try XCTUnwrap(planned).apply()
        XCTAssertTrue(try f.context.query("SELECT id FROM pdf_drawings WHERE deleted_at IS NULL").isEmpty)
        XCTAssertTrue(try f.context.query("SELECT id FROM annotations WHERE deleted_at IS NULL").isEmpty)
        let envelope = try NativeSyncFormat.decodePage(XCTUnwrap(try f.sync.snapshot().records.first { $0["kind"] as? String == "drawing" }))
        XCTAssertEqual(envelope["deletedObjectIDs"] as? [String], [drawing["id"] as! String])
        XCTAssertEqual(envelope["deletedHighlightIDs"] as? [String], [annotation["id"] as! String])
    }

    func testImportRejectsGeometryRevisionIdentityAndDuplicateObjectsBeforeWrites() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let binding = try f.pdf.checkBinding(["courseId": f.course, "relPath": f.path]), revision = binding["documentRevision"] as! String
        var page = try f.page(objects: [stroke(id: "new-ink")]), geometry = page["geometry"] as! [String: Any]
        geometry["cropX"] = 50; page["geometry"] = geometry
        XCTAssertThrowsError(try f.sync.plan(f.envelope(page), assets: [:]))
        page = try f.page(objects: [stroke(id: "new-ink"), stroke(id: "new-ink")])
        XCTAssertThrowsError(try f.sync.plan(f.envelope(page), assets: [:]))
        page = try f.page(objects: [stroke(id: "new-ink")]); page["documentRevision"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try f.sync.plan(f.envelope(page), assets: [:]))
        page["documentRevision"] = revision
        var wrongIdentity = try f.envelope(page); wrongIdentity["id"] = "drawing:another:revision:1"
        XCTAssertThrowsError(try f.sync.plan(wrongIdentity, assets: [:]))
        XCTAssertTrue(try f.context.query("SELECT * FROM pdf_drawings").isEmpty)
    }

    func testInkTombstoneAfterMaterialRemovalUsesPreservedOriginalBinding() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let page = try f.page(objects: [stroke(id: "to-remove")]), live = try f.envelope(page)
        let created = try f.sync.plan(live, assets: [:]); try XCTUnwrap(created).apply()
        try f.context.files.removeItem(at: f.url)
        try f.context.run("UPDATE materials_index SET deleted_at='deleted' WHERE id=?", [f.materialID])
        var tombstone = live; tombstone["deleted"] = true
        let removal = try f.sync.plan(tombstone, assets: [:]); try XCTUnwrap(removal).apply()
        XCTAssertEqual(try f.context.query("SELECT id FROM pdf_drawings WHERE deleted_at IS NOT NULL").first?["id"] as? String, "to-remove")
        XCTAssertThrowsError(try f.sync.plan(live, assets: [:]), "A live page must not revive a removed material")
    }

    func testAncestorTombstoneAfterPageReorderCannotDeleteRemappedInk() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let document = try XCTUnwrap(PDFDocument(url: f.url))
        let second = try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage); second.rotation = 270
        document.insert(second, at: 1)
        try XCTUnwrap(document.dataRepresentation()).write(to: f.url)
        let original = try f.page(objects: [stroke(id: "kept-through-reorder")]), live = try f.envelope(original)
        try XCTUnwrap(try f.sync.plan(live, assets: [:])).apply()
        let pages = try NativePDFPageRepository(context: f.context, pdf: f.pdf)
        _ = try pages.handle("pdf:restructure", ["courseId": f.course, "relPath": f.path, "documentRevision": original["documentRevision"]!, "clientMutationId": UUID().uuidString, "pages": [2, 1]])
        let before = try f.context.query("SELECT * FROM pdf_drawings")
        XCTAssertEqual(before.first?["page"] as? Int, 2)
        var tombstone = live; tombstone["deleted"] = true
        try XCTUnwrap(try f.sync.plan(tombstone, assets: [:])).apply()
        XCTAssertEqual(try f.context.query("SELECT * FROM pdf_drawings") as NSArray, before as NSArray)
        XCTAssertThrowsError(try f.sync.plan(live, assets: [:]), "Historical live pages must not overwrite current ink")
        try f.context.run("DELETE FROM native_pdf_revision_lineage")
        XCTAssertThrowsError(try f.sync.plan(tombstone, assets: [:]), "Only an explicitly approved page lineage can accept historical tombstones")
    }

    func testDeletedRowCanReturnToItsProvenRevisionPageWithoutReassigningLiveRows() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let document = try XCTUnwrap(PDFDocument(url: f.url))
        let second = try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage); second.rotation = 270
        document.insert(second, at: 1); try XCTUnwrap(document.dataRepresentation()).write(to: f.url)
        var page = try f.page(objects: [stroke(id: "restored-page-ink")]); page["page"] = 2; page["geometry"] = try NativeSyncInkGeometry.pages(f.url)[1]
        let live = try f.envelope(page)
        try XCTUnwrap(try f.sync.plan(live, assets: [:])).apply()
        let pages = try NativePDFPageRepository(context: f.context, pdf: f.pdf)
        let changed = try XCTUnwrap(try pages.handle("pdf:restructure", ["courseId": f.course, "relPath": f.path, "documentRevision": page["documentRevision"]!, "clientMutationId": UUID().uuidString, "pages": [2, 1]]) as? [String: Any])
        _ = try pages.handle("pdf:restorePages", ["courseId": f.course, "relPath": f.path, "documentRevision": changed["documentRevision"]!, "clientMutationId": UUID().uuidString, "historyToken": changed["historyToken"]!, "direction": "undo"])
        try f.context.run("UPDATE pdf_drawings SET page=1,deleted_at='old-page' WHERE id='restored-page-ink'")
        try XCTUnwrap(try f.sync.plan(live, assets: [:])).apply()
        XCTAssertEqual(try f.context.query("SELECT page FROM pdf_drawings WHERE id='restored-page-ink' AND deleted_at IS NULL").first?["page"] as? Int, 2)
        try f.context.run("UPDATE pdf_drawings SET page=1 WHERE id='restored-page-ink'")
        XCTAssertThrowsError(try f.sync.plan(live, assets: [:]), "An active row cannot be moved by an incoming page record")
        try f.context.run("UPDATE pdf_drawings SET deleted_at='removed' WHERE id='restored-page-ink'")
        try f.context.run("DELETE FROM native_pdf_page_history")
        XCTAssertThrowsError(try f.sync.plan(live, assets: [:]), "A deleted row needs exact revision history proof")
    }

    func testDeletedLastPageRowsDoNotBreakCurrentRevisionSnapshot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let document = try XCTUnwrap(PDFDocument(url: f.url))
        let second = try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage); second.rotation = 270
        document.insert(second, at: 1)
        try XCTUnwrap(document.dataRepresentation()).write(to: f.url)
        var page = try f.page(objects: [stroke(id: "removed-page-ink")]); page["page"] = 2; page["geometry"] = try NativeSyncInkGeometry.pages(f.url)[1]
        try XCTUnwrap(try f.sync.plan(f.envelope(page), assets: [:])).apply()
        let pages = try NativePDFPageRepository(context: f.context, pdf: f.pdf)
        _ = try pages.handle("pdf:restructure", ["courseId": f.course, "relPath": f.path, "documentRevision": page["documentRevision"]!, "clientMutationId": UUID().uuidString, "pages": [1]])
        XCTAssertEqual(try f.context.query("SELECT id FROM pdf_drawings WHERE deleted_at IS NOT NULL").first?["id"] as? String, "removed-page-ink")
        XCTAssertFalse(try f.sync.snapshot().records.contains { $0["kind"] as? String == "drawing" })
    }

    func testWhiteboardRoundTripPreservesClipsAndRepointsReferencedMaterial() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let board = UUID().uuidString, record = NativeSyncFormat.record(id: "material:" + board, kind: "material", payload: ["id": board, "courseID": f.course, "title": "Board", "kind": "whiteboard", "revision": "whiteboard-" + board, "desktop": ["background": "grid", "surface": "dark", "pageCount": 2]])
        let plan = try f.sync.plan(record, assets: [:]); try XCTUnwrap(plan).apply()
        let data: [String: Any] = ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4], "clip": ["relPath": f.path, "page": 1, "label": "원문", "crop": ["x": 0.2, "y": 0.3, "width": 0.1, "height": 0.2]]]
        try NativeSyncFormat.upsert(f.context, table: "whiteboard_local_shapes", values: ["id": "clip-object", "board_id": board, "page": 2, "kind": "clip", "data_json": NativeSyncFormat.canonical(data), "style_json": NativeSyncFormat.canonical(["color": "ink", "width": 0.003, "opacity": 1]), "created_at": "created", "updated_at": "updated", "deleted_at": NSNull()])
        let snapshot = try f.sync.snapshot(), drawing = try XCTUnwrap(snapshot.records.first { ($0["id"] as? String)?.hasPrefix("drawing:" + board) == true })
        let page = try NativeSyncFormat.decodePage(drawing), objects = page["objects"] as! [[String: Any]], clip = ((objects[0]["data"] as! [String: Any])["clip"] as! [String: Any])
        XCTAssertEqual(clip["assetId"] as? String, f.materialID)
        // A transferred asset keeps its stable ID despite a local filename collision.
        let renamed = "Different.pdf", target = try f.context.materialURL(courseID: f.course, relativePath: renamed, allowMissing: true)
        try f.context.files.copyItem(at: f.url, to: target)
        try f.context.run("UPDATE materials_index SET rel_path=? WHERE id=?", [renamed, f.materialID])
        let imported = try f.sync.plan(drawing, assets: [:]); try XCTUnwrap(imported).apply()
        let saved = try NativeSyncFormat.object(XCTUnwrap(try f.context.query("SELECT data_json FROM whiteboard_local_shapes WHERE id='clip-object'").first)["data_json"])
        let savedClip = saved["clip"] as! [String: Any]
        XCTAssertEqual(savedClip["relPath"] as? String, renamed)
        XCTAssertNil(savedClip["assetId"])
        XCTAssertEqual(savedClip["crop"] as? NSDictionary, (data["clip"] as! [String: Any])["crop"] as? NSDictionary)
    }

    private func stroke(id: String) -> [String: Any] {
        ["id": id, "kind": "ink", "data": ["inkVersion": 5, "futureMetadata": "preserved", "points": [["x": 0.2, "y": 0.3, "p": 0.7, "t": 0, "tiltX": -25, "tiltY": 18], ["x": 0.6, "y": 0.5, "p": 0.4, "t": 24.3, "tiltX": -20, "tiltY": 10]]], "style": ["color": "blue", "width": 0.003, "opacity": 1]]
    }
    private final class Fixture {
        let root: URL, context: NativeRepositoryContext, pdf: NativePDFRepository, sync: NativeSyncDrawings, course: String
        let materialID = UUID().uuidString, path = "Original.pdf"
        var url: URL { get throws { try context.materialURL(courseID: course, relativePath: path) } }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-sync-ink-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            let created = try NativeLibraryRepository(context: context).handle("courses:create", ["name": "Sync", "color": "blue"]) as! [String: Any]
            course = created["id"] as! String; pdf = try NativePDFRepository(context: context); sync = NativeSyncDrawings(context: context, pdf: pdf)
            let document = try XCTUnwrap(PDFDocument(data: NativePDFRepository.paperData(title: "Original", paper: "blank", orientation: "portrait"))), page = try XCTUnwrap(document.page(at: 0))
            page.setBounds(CGRect(x: 20, y: 30, width: 300, height: 500), for: .cropBox); page.rotation = 90
            let target = try context.materialURL(courseID: course, relativePath: path, allowMissing: true)
            try XCTUnwrap(document.dataRepresentation()).write(to: target)
            try NativeSyncFormat.upsert(context, table: "materials_index", values: ["id": materialID, "course_id": course, "rel_path": path, "kind": "pdf", "size": 0, "mtime": 0, "created_at": "created", "updated_at": "updated", "deleted_at": NSNull()])
        }
        func page(objects: [[String: Any]]) throws -> [String: Any] {
            let binding = try pdf.checkBinding(["courseId": course, "relPath": path])
            return ["schemaVersion": 1, "materialID": materialID, "documentRevision": binding["documentRevision"]!, "page": 1, "coordinateSpace": NativeSyncFormat.coordinateSpace, "geometry": try NativeSyncInkGeometry.pages(url)[0], "objects": objects, "highlights": [], "deletedObjectIDs": [], "deletedHighlightIDs": []]
        }
        func envelope(_ page: [String: Any]) throws -> [String: Any] { NativeSyncFormat.record(id: "drawing:\(page["materialID"]!):\(page["documentRevision"]!):\(page["page"]!)", kind: "drawing", payload: try NativeSyncFormat.encodePage(page)) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
