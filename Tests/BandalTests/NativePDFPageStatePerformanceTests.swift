import XCTest
@testable import Bandal

final class NativePDFPageStatePerformanceTests: XCTestCase {
    func testAppendingPageDoesNotRewriteExistingInkOrItsTimestamps() throws {
        try fixture { context, repository, course in
            let before = try repository.state(course: course, path: "paper.pdf")
            let after = try repository.remap(before, map: [[1], [2], [3]], count: 4)
            XCTAssertEqual(try NativeSyncFormat.canonical(before), try NativeSyncFormat.canonical(after))
            let changes = try context.query("SELECT total_changes() AS count").first?["count"] as? Int
            try repository.applyState(after, course: course, path: "paper.pdf")
            XCTAssertEqual(try context.query("SELECT total_changes() AS count").first?["count"] as? Int, changes,
                "Appending a blank page must write zero existing drawing, annotation, or viewport rows")
        }
    }

    func testMovingPagesUpdatesExistingRowsWithoutDeletingAndReinsertingPointData() throws {
        try fixture { context, repository, course in
            try context.db.exec("""
                CREATE TABLE drawing_writes(kind TEXT);
                CREATE TRIGGER drawing_update AFTER UPDATE ON pdf_drawings BEGIN INSERT INTO drawing_writes VALUES('update'); END;
                CREATE TRIGGER drawing_insert AFTER INSERT ON pdf_drawings BEGIN INSERT INTO drawing_writes VALUES('insert'); END;
                CREATE TRIGGER drawing_delete AFTER DELETE ON pdf_drawings BEGIN INSERT INTO drawing_writes VALUES('delete'); END;
                """)
            let before = try repository.state(course: course, path: "paper.pdf")
            let after = try repository.remap(before, map: [[1], [3], [4]], count: 4)
            try repository.applyState(after, course: course, path: "paper.pdf")
            let writes = try context.query("SELECT kind FROM drawing_writes")
            XCTAssertEqual(writes.compactMap { $0["kind"] as? String }, ["update", "update"])
            let rows = try context.query("SELECT id,page,data_json,updated_at FROM pdf_drawings ORDER BY id")
            XCTAssertEqual(rows.compactMap { $0["page"] as? Int }, [1, 3, 4])
            XCTAssertEqual(rows.first?["updated_at"] as? String, "2026-01-01")
            XCTAssertTrue(rows.allSatisfy { $0["data_json"] as? String == "{\"points\":[]}" })
            try repository.applyState(before, course: course, path: "paper.pdf")
            XCTAssertEqual(try NativeSyncFormat.canonical(repository.state(course: course, path: "paper.pdf")), try NativeSyncFormat.canonical(before))
        }
    }

    private func fixture(_ body: (NativeRepositoryContext, NativePDFPageRepository, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-state-performance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context)
        let pdf = try NativePDFRepository(context: context)
        let repository = try NativePDFPageRepository(context: context, pdf: pdf)
        let course = try XCTUnwrap((library.handle("courses:create", ["name": "State fixture", "color": "green"]) as? [String: Any])?["id"] as? String)
        for page in 1...3 {
            try context.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",
                ["ink-\(page)", course, "paper.pdf", page, "ink", "{\"points\":[]}", "{}", "2026-01-01", "2026-01-01"])
        }
        try context.run("INSERT INTO pdf_view_state(course_id,rel_path,page,zoom,updated_at) VALUES(?,?,?,?,?)", [course, "paper.pdf", 3, 1.5, "2026-01-01"])
        try body(context, repository, course)
    }
}
