import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import Bandal

final class NativePDFPageRepositoryTests: XCTestCase {
    private final class Fixture {
        let directory: URL, context: NativeRepositoryContext, library: NativeLibraryRepository, pdf: NativePDFRepository, pages: NativePDFPageRepository
        let course: String, path = "원본.pdf", material: String, revision: String, original: Data
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("BandalPageTests-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: directory.appendingPathComponent("root"), legacyRoot: directory.appendingPathComponent("legacy"))
            library = NativeLibraryRepository(context: context); pdf = try NativePDFRepository(context: context); pages = try NativePDFPageRepository(context: context, pdf: pdf)
            let value = try library.handle("courses:create", ["name": "페이지", "color": "green"])
            course = try XCTUnwrap((value as? [String: Any])?["id"] as? String)
            original = try NativePDFPageRepositoryTests.document()
            try context.atomicWrite(original, to: context.materialURL(courseID: course, relativePath: path, allowMissing: true))
            _ = try library.handle("materials:tree", ["courseId": course])
            let binding = try pdf.checkBinding(["courseId": course, "relPath": path]); material = binding["materialID"] as! String; revision = binding["documentRevision"] as! String
            for page in 1...3 {
                try context.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", ["ink-\(page)", course, path, page, "rect", "{\"box\":{\"x\":0.1,\"y\":0.2,\"width\":0.3,\"height\":0.1}}", "{\"color\":\"red\",\"width\":0.01,\"opacity\":1}", "2026-01-01", "2026-01-01"])
                try context.run("INSERT INTO annotations(id,course_id,rel_path,page,color,rects_json,anchor_json,comment,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)", ["annotation-\(page)", course, path, page, "yellow", "[{\"x\":0.1,\"y\":0.2,\"width\":0.2,\"height\":0.03}]", "{\"quote\":\"Source\",\"prefix\":\"\",\"suffix\":\"\"}", "메모 \(page)", "2026-01-01", "2026-01-01"])
            }
            try context.run("INSERT INTO drawing_create_receipts VALUES(?,?,?)", [UUID().uuidString, "{\"original\":true}", "ink-3"])
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var url: URL { get throws { try context.materialURL(courseID: course, relativePath: path) } }
        func request(_ extra: [String: Any] = [:]) -> [String: Any] { var result: [String: Any] = ["courseId": course, "relPath": path, "documentRevision": revision, "clientMutationId": UUID().uuidString]; result.merge(extra) { _, next in next }; return result }
        func call(_ channel: String, _ request: [String: Any]) throws -> [String: Any] { let value = try pages.handle(channel, request); return try XCTUnwrap(value as? [String: Any]) }
        func current() throws -> String { try pdf.checkBinding(["courseId": course, "relPath": path])["documentRevision"] as! String }
    }
    private static func document() throws -> Data {
        let document = PDFDocument()
        for index in 1...3 {
            let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 300, height: 420)
            let canvas = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, [kCGPDFContextTitle: "원문 PDF", kCGPDFContextAuthor: "Original Author"] as CFDictionary))
            canvas.beginPDFPage(nil); canvas.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.4, blue: 0.7, alpha: 1)); canvas.fill(CGRect(x: 30, y: 50, width: 120, height: 80))
            canvas.setFillColor(CGColor(gray: 0, alpha: 1)); canvas.textPosition = CGPoint(x: 40, y: 240)
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Original Page \(index)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), canvas)
            canvas.endPDFPage(); canvas.closePDF()
            let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
            if index == 3 { page.rotation = 90; page.setBounds(CGRect(x: 10, y: 20, width: 270, height: 370), for: .cropBox) }
            let field = PDFAnnotation(bounds: CGRect(x: 35, y: 160, width: 140, height: 35), forType: .widget, withProperties: nil); field.widgetFieldType = .text; field.fieldName = "field\(index)"; field.widgetStringValue = "Value \(index)"; page.addAnnotation(field)
            document.insert(page, at: document.pageCount)
        }
        let root = PDFOutline()
        for index in 0..<3 { let child = PDFOutline(); child.label = "Chapter \(index + 1)"; child.destination = PDFDestination(page: document.page(at: index)!, at: .zero); root.insertChild(child, at: index) }
        document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 300, width: 120, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: 1)!, at: .zero)); document.page(at: 0)!.addAnnotation(link)
        return try XCTUnwrap(document.dataRepresentation())
    }
    func testReorderDeletePreservesPDFFormsTextGeometryInkAndImmutableReceipts() throws {
        let f = try Fixture(), receipt = try f.context.query("SELECT * FROM drawing_create_receipts")
        _ = try f.pdf.handle("pdf:setViewState", ["courseId": f.course, "relPath": f.path, "page": 3, "zoom": 1.7])
        let result = try f.call("pdf:restructure", f.request(["pages": [["source": 3, "rotate": 0], ["source": 1]]]))
        XCTAssertEqual(result["pageMap"] as? [[Int]], [[2], [], [1]])
        let document = try XCTUnwrap(PDFDocument(url: f.url)); XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Original Page 3") == true)
        XCTAssertEqual(document.page(at: 0)?.rotation, 90); XCTAssertEqual(document.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 10, y: 20, width: 270, height: 370))
        XCTAssertEqual(document.page(at: 0)?.annotations.first(where: { $0.fieldName == "field3" })?.widgetStringValue, "Value 3")
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 2)
        let outline = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(document.index(for: try XCTUnwrap(outline.child(at: 0)?.destination?.page)), 1)
        XCTAssertNil(document.page(at: 1)?.annotations.first(where: { $0.type == "Link" })?.action)
        let rows = try f.context.query("SELECT id,page,deleted_at FROM pdf_drawings ORDER BY id")
        XCTAssertEqual(rows[0]["page"] as? Int, 2); XCTAssertFalse(rows[1]["deleted_at"] is NSNull); XCTAssertEqual(rows[2]["page"] as? Int, 1)
        XCTAssertEqual(try NativeSyncFormat.canonical(receipt), try NativeSyncFormat.canonical(f.context.query("SELECT * FROM drawing_create_receipts")))
        XCTAssertEqual(try f.current(), result["documentRevision"] as? String)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("root/PDFOriginals/\(f.revision).pdf")), f.original)
        let view = try f.context.query("SELECT * FROM pdf_view_state").first; XCTAssertEqual(view?["page"] as? Int, 1); XCTAssertEqual(view?["zoom"] as? Double, 1.7)
    }
    func testInsertedPageCopiesTemplateWithoutInkAndUndoRestoresOriginal() throws {
        let f = try Fixture()
        let result = try f.call("pdf:restructure", f.request(["pages": [1, 0, 2, 3]]))
        XCTAssertEqual(result["pageMap"] as? [[Int]], [[1], [3], [4]]); XCTAssertEqual(result["pageCount"] as? Int, 4)
        XCTAssertEqual((result["changedDocuments"] as? [[String: Any]])?.map { $0["relPath"] as? String }, [f.path], "only this PDF's editors are invalidated")
        let document = try XCTUnwrap(PDFDocument(url: f.url)); XCTAssertEqual(document.pageCount, 4)
        let template = try XCTUnwrap(document.page(at: 0)), inserted = try XCTUnwrap(document.page(at: 1))
        XCTAssertTrue(try NativePDFPageDocument.matches(NativePDFPageDocument.fingerprint(template, annotations: false), NativePDFPageDocument.fingerprint(inserted)))
        XCTAssertTrue(inserted.annotations.isEmpty)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("Original Page 2") == true)
        let rows = try f.context.query("SELECT id,page FROM pdf_drawings WHERE deleted_at IS NULL ORDER BY id")
        XCTAssertEqual(rows.map { $0["page"] as? Int }, [1, 3, 4])
        let lineage = try f.context.query("SELECT pages_json FROM native_pdf_revision_lineage").first?["pages_json"] as? String
        XCTAssertTrue(lineage?.contains("null") == true, "the desktop recipe marks a new page as source: null")
        let token = result["historyToken"]!
        _ = try f.call("pdf:restorePages", f.request(["documentRevision": result["documentRevision"]!, "historyToken": token, "direction": "undo"]))
        XCTAssertEqual(try Data(contentsOf: f.url), f.original)
        XCTAssertEqual(try f.context.query("SELECT page FROM pdf_drawings WHERE deleted_at IS NULL ORDER BY id").map { $0["page"] as? Int }, [1, 2, 3])
    }
    func testValidationIdempotencyAndStaleRevisionNeverRewrite() throws {
        let f = try Fixture()
        for pages in [[], [1, 1], [0], [4]] as [[Int]] { XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": pages]))) }
        XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": [["source": 1, "rotate": 90]]])))
        XCTAssertEqual(try Data(contentsOf: f.url), f.original)
        let input = f.request(["pages": [3, 2, 1]]), result = try f.call("pdf:restructure", input), bytes = try Data(contentsOf: f.url)
        XCTAssertEqual(try NativeSyncFormat.canonical(result), try NativeSyncFormat.canonical(f.call("pdf:restructure", input)))
        var reused = input; reused["pages"] = [1, 2]
        XCTAssertThrowsError(try f.call("pdf:restructure", reused)); XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": [1, 2]])))
        XCTAssertEqual(try Data(contentsOf: f.url), bytes); XCTAssertEqual(try f.context.query("SELECT * FROM native_pdf_page_history").count, 1)
    }
    func testExactUndoRedoAndRecoveryCopyProtectLaterInk() throws {
        let f = try Fixture(), changed = try f.call("pdf:restructure", f.request(["pages": [3, 1]])), token = changed["historyToken"]!
        let changedBytes = try Data(contentsOf: f.url)
        let undo = try f.call("pdf:restorePages", f.request(["documentRevision": changed["documentRevision"]!, "historyToken": token, "direction": "undo"]))
        XCTAssertEqual(try Data(contentsOf: f.url), f.original); XCTAssertEqual(try f.context.query("SELECT * FROM pdf_drawings WHERE deleted_at IS NULL").count, 3)
        _ = try f.call("pdf:restorePages", f.request(["documentRevision": undo["documentRevision"]!, "historyToken": token, "direction": "redo"]))
        XCTAssertEqual(try Data(contentsOf: f.url), changedBytes)
        try f.context.run("UPDATE pdf_drawings SET data_json='{}',updated_at='later edit' WHERE id='ink-3'")
        let history = try f.call("pdf:pageHistory", f.request()); XCTAssertEqual(history["canUndo"] as? Bool, false); XCTAssertEqual(history["recoverToken"] as? String, token as? String)
        XCTAssertThrowsError(try f.call("pdf:restorePages", f.request(["documentRevision": changed["documentRevision"]!, "historyToken": token, "direction": "undo"])))
        let copy = try f.call("pdf:recoverPagesCopy", f.request(["historyToken": token, "variant": "before"])), copyPath = copy["relPath"] as! String
        XCTAssertEqual((copy["changedDocuments"] as? [[String: Any]])?.count, 0, "a recovery copy invalidates no open editor")
        XCTAssertEqual(try Data(contentsOf: f.context.materialURL(courseID: f.course, relativePath: copyPath)), f.original)
        XCTAssertEqual(try f.context.query("SELECT * FROM pdf_drawings WHERE rel_path=? AND deleted_at IS NULL", [copyPath]).count, 3)
        XCTAssertEqual(try f.context.query("SELECT data_json FROM pdf_drawings WHERE id='ink-3'").first?["data_json"] as? String, "{}")
        XCTAssertEqual(try Data(contentsOf: f.url), changedBytes)
    }
    func testSQLFailureAfterFilePublicationRestoresExactPDFAndAllRows() throws {
        let f = try Fixture(), before = try f.context.query("SELECT * FROM pdf_drawings ORDER BY id")
        try f.context.db.exec("CREATE TRIGGER reject_page_history BEFORE INSERT ON native_pdf_page_history BEGIN SELECT RAISE(ABORT,'forced history failure'); END;")
        XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": [3, 1]])))
        XCTAssertEqual(try Data(contentsOf: f.url), f.original); XCTAssertEqual(try f.current(), f.revision)
        XCTAssertEqual(try NativeSyncFormat.canonical(before), try NativeSyncFormat.canonical(f.context.query("SELECT * FROM pdf_drawings ORDER BY id")))
        XCTAssertTrue(try f.context.query("SELECT * FROM native_pdf_page_receipts").isEmpty)
        try NativeSyncJournal(context: f.context).recover(); XCTAssertEqual(try Data(contentsOf: f.url), f.original)
    }
    func testLinkedMarkdownReordersArchivesDeletedTextAndRollsBackWithPDF() throws {
        let f = try Fixture(), notePath = "연결.md", note = "<!-- bandal:pdf-page-note {\"version\":1,\"source\":\"원본.pdf\",\"fingerprint\":\"old\",\"pages\":[{\"width\":300,\"height\":420},{\"width\":300,\"height\":420},{\"width\":370,\"height\":270}]} -->\n# 연결\n\n<!-- bandal:page 1 -->\n\n첫쪽\n\n<!-- bandal:page 2 -->\n\n삭제되어도 보존\n\n<!-- bandal:page 3 -->\n\n마지막쪽\n"
        let noteURL = try f.context.materialURL(courseID: f.course, relativePath: notePath, allowMissing: true); try f.context.atomicWrite(Data(note.utf8), to: noteURL)
        let source: [String: Any] = ["kind": "pdf", "payload": ["courseId": f.course, "relPath": f.path]], target: [String: Any] = ["kind": "note", "payload": ["courseId": f.course, "relPath": notePath]]
        try f.context.run("INSERT INTO material_links(id,course_id,source_json,target_json,kind,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, f.course, try NativeSyncFormat.canonical(source), try NativeSyncFormat.canonical(target), "pdf-page-note", "{\"version\":1,\"syncScroll\":true}", "today"])
        try f.context.db.exec("CREATE TRIGGER reject_page_history BEFORE INSERT ON native_pdf_page_history BEGIN SELECT RAISE(ABORT,'forced failure'); END;")
        XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": [3, 1]]))); XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), note)
        try f.context.db.exec("DROP TRIGGER reject_page_history")
        let changed = try f.call("pdf:restructure", f.request(["pages": [3, 1]])), rewritten = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("<!-- bandal:page 1 -->\n\n마지막쪽")); XCTAssertTrue(rewritten.contains("<!-- bandal:page 2 -->\n\n첫쪽")); XCTAssertTrue(rewritten.contains("<!-- bandal:appendix -->\n\n## 연결 제외된 페이지\n\n### 기존 PDF 2쪽\n\n삭제되어도 보존"))
        _ = try f.call("pdf:restorePages", f.request(["documentRevision": changed["documentRevision"]!, "historyToken": changed["historyToken"]!, "direction": "undo"]))
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), note)
    }
    func testStaleLinkToDeletedPageNoteDoesNotBlockPageEdits() throws {
        let f = try Fixture()
        let source: [String: Any] = ["kind": "pdf", "payload": ["courseId": f.course, "relPath": f.path]], target: [String: Any] = ["kind": "note", "payload": ["courseId": f.course, "relPath": "지워진 페이지 필기.md"]]
        try f.context.run("INSERT INTO material_links(id,course_id,source_json,target_json,kind,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, f.course, try NativeSyncFormat.canonical(source), try NativeSyncFormat.canonical(target), "pdf-page-note", "{\"version\":1}", "today"])
        let result = try f.call("pdf:restructure", f.request(["pages": [1, 2, 3, 0]]))
        XCTAssertEqual(result["pageCount"] as? Int, 4)
        XCTAssertEqual(try PDFDocument(url: f.url)?.pageCount, 4)
        XCTAssertEqual(try f.context.query("SELECT * FROM material_links").count, 1, "the stale link survives with its remapped pages")
    }
    func testPageReorderDeleteAndHistoryPreserveExactUserWhitespaceInLinkedNote() throws {
        let f = try Fixture(), notePath = "공백 보존.md"
        var document = NativePDFPageNoteDocument(source: f.path, fingerprint: "old", sizes: Array(repeating: .init(width: 300, height: 420), count: 3), title: "Whitespace")
        document.pages = ["\n    indented code  \n\n", " deleted words \t\n\n", "\n\nlast page \n"]
        document.appendix = " \tprevious appendix \n\n"
        let original = try document.markdown().replacingOccurrences(of: "\"version\":1", with: "\"future\":{\"keep\":true},\"version\":1")
        let noteURL = try f.context.materialURL(courseID: f.course, relativePath: notePath, allowMissing: true)
        try f.context.atomicWrite(Data(original.utf8), to: noteURL)
        let source: [String: Any] = ["kind": "pdf", "payload": ["courseId": f.course, "relPath": f.path]]
        let target: [String: Any] = ["kind": "note", "payload": ["courseId": f.course, "relPath": notePath]]
        try f.context.run("INSERT INTO material_links(id,course_id,source_json,target_json,kind,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, f.course, NativeSyncFormat.canonical(source), NativeSyncFormat.canonical(target), "pdf-page-note", "{}", "today"])
        let changed = try f.call("pdf:restructure", f.request(["pages": [3, 1]]))
        let rewritten = try String(contentsOf: noteURL, encoding: .utf8)
        let parsed = try XCTUnwrap(NativePDFPageNoteDocument(rewritten))
        XCTAssertEqual(parsed.pages, [document.pages[2], document.pages[0]])
        XCTAssertEqual(parsed.appendix, document.appendix + "\n\n## 연결 제외된 페이지\n\n### 기존 PDF 2쪽\n\n" + document.pages[1])
        XCTAssertTrue(rewritten.contains("\"future\":{\"keep\":true}"), "Unknown manifest fields survive the intentional page/fingerprint update")
        let undo = try f.call("pdf:restorePages", f.request(["documentRevision": changed["documentRevision"]!, "historyToken": changed["historyToken"]!, "direction": "undo"]))
        XCTAssertEqual(try Data(contentsOf: noteURL), Data(original.utf8), "Undo restores the exact original manifest and Markdown bytes")
        _ = try f.call("pdf:restorePages", f.request(["documentRevision": undo["documentRevision"]!, "historyToken": changed["historyToken"]!, "direction": "redo"]))
        XCTAssertEqual(try Data(contentsOf: noteURL), Data(rewritten.utf8))
    }
    func testCrashRecoveryRestoresUncommittedFileBeforeBindingsReopen() throws {
        let f = try Fixture(), changed = try NativePDFPageDocument.rewrite(f.original, pages: [3, 1]), id = UUID().uuidString, directory = f.context.root.appendingPathComponent("SyncRecovery/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("0.original"); try f.context.atomicWrite(f.original, to: backup)
        let entries: [[String: Any]] = [["target": try f.url.path, "backup": backup.path, "existed": true, "remove": false, "beforeHash": f.revision, "afterHash": NativeSyncFormat.hash(changed)]]
        try f.context.atomicWrite(Data(try NativeSyncFormat.canonical(["id": id, "entries": entries]).utf8), to: directory.appendingPathComponent("intent.json"))
        try f.context.atomicWrite(changed, to: f.url)
        XCTAssertThrowsError(try f.call("pdf:pageHistory", f.request()))
        let restarted = try NativeRepositoryContext(root: f.context.root, legacyRoot: f.context.legacyRoot)
        try NativeSyncRepository.recoverFiles(context: restarted)
        let repository = try NativePDFRepository(context: restarted)
        XCTAssertEqual(try repository.checkBinding(["courseId": f.course, "relPath": f.path])["documentRevision"] as? String, f.revision)
        XCTAssertEqual(try Data(contentsOf: f.url), f.original)
    }
    private func sync(_ context: NativeRepositoryContext, _ library: NativeLibraryRepository, _ pdf: NativePDFRepository) throws -> NativeSyncRepository {
        let sync = try NativeSyncRepository(context: context, library: library, checkPDFBinding: pdf.checkBinding), drawings = NativeSyncDrawings(context: context, pdf: pdf)
        sync.registerProjection(snapshot: { try drawings.snapshot() }, plan: { try drawings.plan($0, assets: $1) }); return sync
    }
    private func exchange(_ sync: NativeSyncRepository, _ channel: String, _ request: [String: Any] = [:]) throws -> [String: Any] {
        let value = try sync.handle(channel, request); return try XCTUnwrap(value as? [String: Any])
    }
    func testSyncApprovedPageChangeAndUndoRoundTripWithStableIdentity() throws {
        let a = try Fixture(), context = try NativeRepositoryContext(root: a.directory.appendingPathComponent("B"), legacyRoot: a.directory.appendingPathComponent("BLegacy")), library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context)
        let source = try sync(a.context, a.library, a.pdf), destination = try sync(context, library, pdf)
        let initial = try exchange(destination, "nativeSync:import", exchange(source, "nativeSync:export"))
        XCTAssertTrue((initial["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(initial)")
        let changed = try a.call("pdf:restructure", a.request(["pages": [3, 1]]))
        let exported = try exchange(source, "nativeSync:export"), imported = try exchange(destination, "nativeSync:import", exported)
        XCTAssertTrue((imported["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(imported)")
        let target = try context.materialURL(courseID: a.course, relativePath: a.path)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: a.url))
        XCTAssertEqual(try pdf.checkBinding(["courseId": a.course, "relPath": a.path])["materialID"] as? String, a.material)
        XCTAssertEqual(try context.query("SELECT page FROM pdf_drawings WHERE id='ink-3'").first?["page"] as? Int, 1)
        _ = try a.call("pdf:restorePages", a.request(["documentRevision": changed["documentRevision"]!, "historyToken": changed["historyToken"]!, "direction": "undo"]))
        let undo = try exchange(destination, "nativeSync:import", exchange(source, "nativeSync:export"))
        XCTAssertTrue((undo["conflicts"] as? [[String: Any]])?.isEmpty == true, "\(undo)")
        XCTAssertEqual(try Data(contentsOf: target), a.original)
        XCTAssertEqual(try context.query("SELECT * FROM pdf_drawings WHERE deleted_at IS NULL").count, 3)
    }
    func testSyncConcurrentInkAndForgedRecipePreserveBothOriginals() throws {
        let a = try Fixture(), context = try NativeRepositoryContext(root: a.directory.appendingPathComponent("B"), legacyRoot: a.directory.appendingPathComponent("BLegacy")), library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context)
        let source = try sync(a.context, a.library, a.pdf), destination = try sync(context, library, pdf)
        _ = try exchange(destination, "nativeSync:import", exchange(source, "nativeSync:export"))
        try context.run("UPDATE pdf_drawings SET style_json='{\"color\":\"blue\",\"width\":0.02,\"opacity\":1}',updated_at='local edit' WHERE id='ink-1'")
        _ = try a.call("pdf:restructure", a.request(["pages": [3, 1]])); let exported = try exchange(source, "nativeSync:export")
        let result = try exchange(destination, "nativeSync:import", exported)
        XCTAssertFalse((result["conflicts"] as? [[String: Any]])?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: context.materialURL(courseID: a.course, relativePath: a.path)), a.original)
        XCTAssertEqual(try context.query("SELECT updated_at FROM pdf_drawings WHERE id='ink-1'").first?["updated_at"] as? String, "local edit")
        XCTAssertEqual(try context.query("SELECT * FROM pdf_drawings WHERE deleted_at IS NULL").count, 3)
        XCTAssertEqual(try context.query("SELECT * FROM annotations WHERE deleted_at IS NULL").count, 3)
        let material = try XCTUnwrap((exported["records"] as? [[String: Any]])?.first { $0["kind"] as? String == "material" }), payload = material["payload"] as! [String: Any]
        var steps = payload["pdfLineage"] as! [[String: Any]]; steps[0]["pages"] = [["source": 1], ["source": 3]]
        var assets: [String: URL] = [:]; for asset in exported["assets"] as! [[String: Any]] { assets[asset["sha256"] as! String] = URL(fileURLWithPath: asset["path"] as! String) }
        XCTAssertThrowsError(try NativePDFPageSync.plan(context: context, material: a.material, course: a.course, path: a.path, from: a.revision, to: payload["revision"] as! String, lineage: steps, assets: assets))
        XCTAssertEqual(try Data(contentsOf: context.materialURL(courseID: a.course, relativePath: a.path)), a.original)
    }
    func testNewReferenceBlocksUndoAndRenamedMaterialRecoversBesideCurrentFile() throws {
        let f = try Fixture(), changed = try f.call("pdf:restructure", f.request(["pages": [3, 1]]))
        let source: [String: Any] = ["kind": "pdf", "payload": ["courseId": f.course, "relPath": f.path, "page": 1]]
        try f.context.run("INSERT INTO material_links(id,course_id,source_json,target_json,created_at) VALUES(?,?,?,?,?)", [UUID().uuidString, f.course, NativeSyncFormat.canonical(source), "{}", "later"])
        XCTAssertEqual(try f.call("pdf:pageHistory", f.request())["canUndo"] as? Bool, false)
        try f.context.files.createDirectory(at: f.context.courseFolder(f.course).appendingPathComponent("Moved"), withIntermediateDirectories: true)
        let renamed = "Moved/이름.pdf"; try f.context.files.moveItem(at: f.url, to: f.context.materialURL(courseID: f.course, relativePath: renamed, allowMissing: true))
        for table in ["materials_index", "pdf_document_aliases", "pdf_drawings", "annotations"] { try f.context.run("UPDATE \(table) SET rel_path=? WHERE course_id=? AND rel_path=?", [renamed, f.course, f.path]) }
        let copy = try f.call("pdf:recoverPagesCopy", f.request(["relPath": renamed, "historyToken": changed["historyToken"]!, "variant": "before"]))
        XCTAssertTrue((copy["relPath"] as? String)?.hasPrefix("Moved/이름") == true)
    }
    func testPageNoteRewritePreservesIndentedCodeAndExistingAppendix() throws {
        let text = "<!-- bandal:pdf-page-note {\"version\":1,\"source\":\"x.pdf\",\"fingerprint\":\"f\",\"pages\":[{\"width\":1,\"height\":1},{\"width\":1,\"height\":1}]} -->\n# Notes\n\n<!-- bandal:page 1 -->\n\n    indented code\n\n<!-- bandal:page 2 -->\n\nsecond\n\n<!-- bandal:appendix -->\n\n    archived code\n"
        let rewritten = try NativePDFPageLinks.rewrite(text, source: "x.pdf", pageMap: [[2], [1]], fingerprint: "next", sizes: [["width": 1, "height": 1], ["width": 1, "height": 1]])
        XCTAssertTrue(rewritten.contains("<!-- bandal:page 2 -->\n\n    indented code")); XCTAssertTrue(rewritten.contains("<!-- bandal:appendix -->\n\n    archived code"))
    }

    func testUnlockedEncryptedPDFRemainsReadableWhilePageEditingIsDisabled() throws {
        let f = try Fixture(), document = try XCTUnwrap(PDFDocument(data: f.original))
        let bytes = try XCTUnwrap(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner-password", PDFDocumentWriteOption.userPasswordOption: ""]))
        let loaded = try XCTUnwrap(PDFDocument(data: bytes)); XCTAssertTrue(loaded.isEncrypted); XCTAssertFalse(loaded.isLocked)
        let path = "읽기 가능.pdf", url = try f.context.materialURL(courseID: f.course, relativePath: path, allowMissing: true)
        try f.context.atomicWrite(bytes, to: url); _ = try f.library.handle("materials:tree", ["courseId": f.course])
        let history = try f.call("pdf:pageHistory", f.request(["relPath": path]))
        XCTAssertEqual(history["pageCount"] as? Int, 3); XCTAssertEqual(history["canRestructure"] as? Bool, false)
        XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["relPath": path, "documentRevision": history["documentRevision"]!, "pages": [3, 1]])))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testFinalCommitReceiptFailureRollsBackFileHistoryAndBindings() throws {
        let f = try Fixture()
        try f.context.db.exec("CREATE TRIGGER reject_final_page_commit BEFORE INSERT ON ipad_sync_commits BEGIN SELECT RAISE(ABORT,'forced commit receipt failure'); END;")
        XCTAssertThrowsError(try f.call("pdf:restructure", f.request(["pages": [3, 1]])))
        XCTAssertEqual(try Data(contentsOf: f.url), f.original); XCTAssertEqual(try f.current(), f.revision)
        XCTAssertTrue(try f.context.query("SELECT * FROM native_pdf_page_history").isEmpty)
        XCTAssertTrue(try f.context.query("SELECT * FROM native_pdf_revision_lineage").isEmpty)
        XCTAssertTrue(try f.context.query("SELECT * FROM native_pdf_page_receipts").isEmpty)
        XCTAssertEqual(try f.context.query("SELECT * FROM pdf_drawings WHERE deleted_at IS NULL").count, 3)
        try NativeSyncJournal(context: f.context).recover(); XCTAssertEqual(try Data(contentsOf: f.url), f.original)
    }

}
