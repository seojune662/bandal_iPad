import XCTest
import PDFKit
@testable import Bandal

final class NativePDFThumbnailRepositoryTests: XCTestCase {
    func testUnopenedThumbnailsNeverCreateBindingsHashRowsOrOriginalCopies() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let empty = try fixture.pdf.thumbnailSnapshot(fixture.request)
        XCTAssertTrue((empty["drawings"] as? [[String: Any]] ?? []).isEmpty)
        // Legacy unbound rows also must not cause library browsing to establish
        // recovery evidence for hundreds of unopened documents.
        try fixture.drawing(id: "legacy")
        let unbound = try fixture.pdf.thumbnailSnapshot(fixture.request)
        XCTAssertTrue((unbound["drawings"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue(try fixture.context.query("SELECT * FROM pdf_document_bindings").isEmpty)
        XCTAssertTrue(try fixture.context.query("SELECT * FROM native_file_hashes").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("PDFOriginals").path))
    }

    func testBoundThumbnailUsesExistingIdentityWithoutRecreatingOriginalAndRejectsReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.pdf.checkBinding(fixture.request)
        let digest = try XCTUnwrap(binding["documentRevision"] as? String)
        try fixture.drawing(id: "page-one", page: 1)
        try fixture.drawing(id: "page-two", page: 2)
        try fixture.annotation(id: "highlight", page: 1)
        let original = fixture.root.appendingPathComponent("PDFOriginals/" + digest + ".pdf")
        try FileManager.default.removeItem(at: original)
        let reloaded = try NativePDFRepository(context: fixture.context)
        let preview = try reloaded.thumbnailSnapshot(fixture.request)
        XCTAssertEqual((preview["drawings"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["page-one"])
        XCTAssertEqual((preview["annotations"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "A thumbnail read cannot perform original-file recovery or fsync")
        let replacement = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 300)).pdfData { $0.beginPage() }
        try replacement.write(to: fixture.url, options: .atomic)
        XCTAssertThrowsError(try reloaded.thumbnailSnapshot(fixture.request), "Known old ink must never be drawn on a replacement PDF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try fixture.context.query("SELECT bound_sha FROM pdf_document_bindings").first?["bound_sha"] as? String, digest)
    }

    func testTargetedRowsChunkIDsPreserveScopeTombstonesOrderAndDoNotDecodeUnrelatedPayloads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.pdf.checkBinding(fixture.request)
        var expected: [String] = []
        try fixture.context.transaction {
            for index in 0..<825 {
                let id = "row-\(index)"
                try fixture.drawing(id: id, page: index % 2 + 1)
                expected.append(id)
            }
            try fixture.drawing(id: "foreign-path", path: "elsewhere.pdf")
            try fixture.drawing(id: "deleted", deleted: true)
            try fixture.drawing(id: "unrelated-corrupt", json: "not JSON")
            try fixture.annotation(id: "selected-annotation", page: 1)
            try fixture.annotation(id: "foreign-annotation", page: 1, path: "elsewhere.pdf")
        }
        var request = fixture.request
        request.removeValue(forKey: "page")
        request["ids"] = Array(expected.reversed()) + ["foreign-path", "deleted", "missing", expected[0]]
        let rows = try fixture.pdf.listDrawings(request)
        let ordered = expected.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + expected.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ordered)
        request["page"] = 2
        XCTAssertEqual(try fixture.pdf.listDrawings(request).count, 412)
        request["ids"] = ["selected-annotation", "foreign-annotation"]
        request["page"] = 1
        XCTAssertEqual(try fixture.pdf.listAnnotations(request).compactMap { $0["id"] as? String }, ["selected-annotation"])
        request["ids"] = [String]()
        XCTAssertTrue(try fixture.pdf.listDrawings(request).isEmpty)
        XCTAssertTrue(try fixture.pdf.listAnnotations(request).isEmpty)
        request["ids"] = ["\u{0}"]
        XCTAssertThrowsError(try fixture.pdf.listDrawings(request))
        request["ids"] = "not an array"
        XCTAssertThrowsError(try fixture.pdf.listAnnotations(request))
    }

    private final class Fixture {
        let root: URL
        let context: NativeRepositoryContext
        let pdf: NativePDFRepository
        let course: String
        let path: String
        let url: URL
        var request: [String: Any] { ["courseId": course, "relPath": path, "page": 1] }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailRepositoryTests-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            let library = NativeLibraryRepository(context: context)
            pdf = try NativePDFRepository(context: context)
            course = try XCTUnwrap((try library.handle("courses:create", ["name": "Thumbnail", "color": "blue"]) as? [String: Any])?["id"] as? String)
            let created = try pdf.handle("pdfNotes:create", ["courseId": course, "title": "Fixture", "paper": "blank", "orientation": "portrait"])
            path = try XCTUnwrap((created as? [String: Any])?["relPath"] as? String)
            url = try context.materialURL(courseID: course, relativePath: path)
        }
        func drawing(id: String, page: Int = 1, path alternate: String? = nil, deleted: Bool = false, json: String = "{}") throws {
            _ = try context.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at,deleted_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                                [id, course, alternate ?? path, page, "rect", json, "{}", "same-time", "same-time", deleted ? "deleted" : NSNull()])
        }
        func annotation(id: String, page: Int, path alternate: String? = nil) throws {
            _ = try context.run("INSERT INTO annotations(id,course_id,rel_path,page,color,rects_json,anchor_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",
                                [id, course, alternate ?? path, page, "blue", "[]", "{}", "same-time", "same-time"])
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
