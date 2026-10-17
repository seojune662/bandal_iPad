import XCTest
import PDFKit
@testable import Bandal

@MainActor final class NativePDFPageNoteTests: XCTestCase {
    func testPortableUnicodeManifestAndSectionsRoundTripWithAppendix() throws {
        var note = NativePDFPageNoteDocument(source: "강의/문서 --> 1.pdf", fingerprint: "fingerprint", sizes: [.init(width: 600, height: 800), .init(width: 800, height: 600)], title: "페이지 필기")
        note.pages = ["# 첫째\n\n한글 **내용**", "둘째 쪽"]
        note.appendix = "이전 페이지의 필기"
        let raw = try note.markdown()
        let parsed = try XCTUnwrap(NativePDFPageNoteDocument(raw))
        XCTAssertEqual(parsed, note)
        XCTAssertEqual(parsed.source, "강의/문서 --> 1.pdf")
        XCTAssertFalse(raw.components(separatedBy: "\n")[0].contains("문서 -->"))
        XCTAssertNil(NativePDFPageNoteDocument(raw.replacingOccurrences(of: "bandal:page 2", with: "bandal:page 8")))
    }

    func testIndentedCodeAndPastedBoundaryCannotDestroyOtherPages() throws {
        var note = NativePDFPageNoteDocument(source: "source.pdf", fingerprint: "f", sizes: [.init(width: 600, height: 800), .init(width: 600, height: 800)], title: "필기")
        note.pages = ["    indented code\n\n<!-- bandal:page 2 -->\n앞 <!-- bandal:appendix --> 뒤", "보존할 다른 페이지"]
        let restored = try XCTUnwrap(NativePDFPageNoteDocument(note.markdown()))
        XCTAssertTrue(restored.pages[0].hasPrefix("    indented code"))
        XCTAssertTrue(restored.pages[0].contains("&lt;!-- bandal:page 2 -->"))
        XCTAssertEqual(restored.pages[1], "보존할 다른 페이지")
        XCTAssertEqual(restored.pages.count, 2)
    }

    func testPageAndAppendixFramingPreservesWhitespaceIncludingEmptyParagraphs() throws {
        let values = ["", " ", "  ", "\t", "\n", "\n\n", "\n    first line  \n\n\t", "last line \n\n"]
        for value in values {
            var note = NativePDFPageNoteDocument(source: "source.pdf", fingerprint: "f", sizes: [.init(width: 600, height: 800), .init(width: 600, height: 800)], title: "필기")
            note.pages = [value, value]
            let withoutAppendix = try XCTUnwrap(NativePDFPageNoteDocument(note.markdown()))
            XCTAssertEqual(withoutAppendix.pages, note.pages)
            note.appendix = value
            let withAppendix = try XCTUnwrap(NativePDFPageNoteDocument(note.markdown()))
            XCTAssertEqual(withAppendix.pages, note.pages)
            XCTAssertEqual(withAppendix.appendix, value)
        }
    }

    func testOpeningPageNoteIsIdempotentAndPreservesExistingTextAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-note-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context)
        let course = try XCTUnwrap(try library.handle("courses:create", ["name": "페이지 필기", "color": "blue"]) as? [String: Any])
        let courseID = try XCTUnwrap(course["id"] as? String)
        let paper = try XCTUnwrap(try pdf.handle("pdfNotes:create", ["courseId": courseID, "title": "수학", "paper": "blank"]) as? [String: Any])
        let path = try XCTUnwrap(paper["relPath"] as? String)
        let repository = NativePDFPageNoteRepository(context: context, pdf: pdf)
        let request: [String: Any] = ["courseId": courseID, "relPath": path]
        let first = try repository.open(request), notePath = try XCTUnwrap(first["relPath"] as? String)
        let url = try context.materialURL(courseID: courseID, relativePath: notePath)
        var note = try XCTUnwrap(NativePDFPageNoteDocument(String(contentsOf: url, encoding: .utf8)))
        note.pages[0] = "잃어버리면 안 되는 필기"
        let raw = try note.markdown(); try Data(raw.utf8).write(to: url, options: .atomic)
        let reopened = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try NativeSyncRepository.recoverFiles(context: reopened)
        let again = try NativePDFPageNoteRepository(context: reopened, pdf: NativePDFRepository(context: reopened)).open(request)
        XCTAssertEqual(again["relPath"] as? String, notePath)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw)
        XCTAssertEqual(try reopened.query("SELECT id FROM material_links WHERE kind='pdf-page-note'").count, 1)
        let decoded = try NativeToolJSON.decode(first, as: NativeDocumentReference.self)
        XCTAssertEqual(decoded.relativePath, notePath)
        let source = try XCTUnwrap(repository.source(["courseId": courseID, "relPath": notePath]) as? [String: Any])
        XCTAssertEqual(source["courseId"] as? String, courseID)
        XCTAssertEqual(source["relPath"] as? String, path)
    }

    func testWorkspacePageNoteActionFlushesOpenEditorsAndReturnsNativeDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-note-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start(); try await store.createCourse(name: "Page note action")
        let course = try XCTUnwrap(store.selectedCourseID)
        let createdValue = try await store.invoke("pdfNotes:create", ["courseId": course, "title": "Source", "paper": "blank"])
        let created = try XCTUnwrap(createdValue as? [String: Any])
        let path = try XCTUnwrap(created["relPath"] as? String)
        var flushed = 0
        let registration = store.registerDocumentFlush(id: "open-editor") { flushed += 1 }
        defer { store.unregisterDocumentFlush(registration) }
        let note = try await store.openPDFPageNote(courseID: course, relativePath: path)
        XCTAssertEqual(flushed, 1)
        XCTAssertEqual(note.kind, "note")
        XCTAssertEqual(note.courseID, course)
        let sourceValue = try await store.invokePrivate("nativePDF:pageNoteSource", ["courseId": course, "relPath": note.relativePath])
        let source = try XCTUnwrap(sourceValue as? [String: Any])
        XCTAssertEqual(source["relPath"] as? String, path)
    }
    func testCrossCoursePageNoteRenameJournalsManifestAndSupportsLaterPageChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-note-cross-course-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context)
        context.beforeMaterialRename = { course, from, to, directory in try pdf.prepareRename(courseID: course, from: from, to: to, isDirectory: directory) }
        let sourceValue = try library.handle("courses:create", ["name": "PDF 과목", "color": "blue"])
        let targetValue = try library.handle("courses:create", ["name": "연결 노트 과목", "color": "green"])
        let sourceCourse = try XCTUnwrap((sourceValue as? [String: Any])?["id"] as? String), targetCourse = try XCTUnwrap((targetValue as? [String: Any])?["id"] as? String)
        let paperValue = try pdf.handle("pdfNotes:create", ["courseId": sourceCourse, "title": "이름 변경 전", "paper": "blank", "dirRelPath": ""])
        let originalPath = try XCTUnwrap((paperValue as? [String: Any])?["relPath"] as? String)
        let pdfURL = try context.materialURL(courseID: sourceCourse, relativePath: originalPath)
        let pdfDocument = try XCTUnwrap(PDFDocument(url: pdfURL))
        let secondPage = try XCTUnwrap(PDFDocument(url: pdfURL)?.page(at: 0))
        pdfDocument.insert(secondPage, at: 1)
        try context.atomicWrite(try XCTUnwrap(pdfDocument.dataRepresentation()), to: pdfURL)
        let repository = NativePDFPageNoteRepository(context: context, pdf: pdf), reference = try repository.open(["courseId": sourceCourse, "relPath": originalPath])
        let originalNotePath = try XCTUnwrap(reference["relPath"] as? String), notePath = "다른 과목의 필기.md"
        let originalNoteURL = try context.materialURL(courseID: sourceCourse, relativePath: originalNotePath), noteURL = try context.materialURL(courseID: targetCourse, relativePath: notePath, allowMissing: true)
        var note = try XCTUnwrap(NativePDFPageNoteDocument(String(contentsOf: originalNoteURL, encoding: .utf8)))
        note.pages[0] = "다른 과목에 보관한 원문 필기"
        note.pages[1] = "두 번째 쪽 필기"
        let preserved = try note.markdown(); try context.atomicWrite(Data(preserved.utf8), to: originalNoteURL)
        try context.files.moveItem(at: originalNoteURL, to: noteURL)
        let target: [String: Any] = ["kind": "note", "payload": ["courseId": targetCourse, "relPath": notePath]]
        try context.run("UPDATE material_links SET target_json=? WHERE course_id=? AND kind='pdf-page-note'", [NativeSyncFormat.canonical(target), sourceCourse])
        try context.db.exec("CREATE TRIGGER fail_page_note_rename BEFORE UPDATE OF source_json ON material_links BEGIN SELECT RAISE(ABORT,'fixture rename rollback'); END")
        XCTAssertThrowsError(try library.handle("materials:rename", ["courseId": sourceCourse, "relPath": originalPath, "newName": "이름 변경 후.pdf"]))
        XCTAssertTrue(context.files.fileExists(atPath: pdfURL.path))
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), preserved)
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
        try context.db.exec("DROP TRIGGER fail_page_note_rename")
        let renamedValue = try library.handle("materials:rename", ["courseId": sourceCourse, "relPath": originalPath, "newName": "이름 변경 후.pdf"])
        let renamed = try XCTUnwrap((renamedValue as? [String: Any])?["relPath"] as? String)
        let beforeChanges = try context.query("SELECT total_changes() AS value").first?["value"] as? Int
        let source = try XCTUnwrap(repository.source(["courseId": targetCourse, "relPath": notePath]) as? [String: Any])
        XCTAssertEqual(source["courseId"] as? String, sourceCourse)
        XCTAssertNotEqual(source["courseId"] as? String, targetCourse)
        XCTAssertEqual(source["relPath"] as? String, renamed)
        let renamedText = try String(contentsOf: noteURL, encoding: .utf8)
        let renamedNote = try XCTUnwrap(NativePDFPageNoteDocument(renamedText))
        XCTAssertEqual(renamedNote.source, renamed)
        XCTAssertEqual(renamedNote.manifest.fingerprint, note.manifest.fingerprint)
        XCTAssertEqual(renamedNote.manifest.pages, note.manifest.pages)
        XCTAssertEqual(renamedText.drop(while: { $0 != "\n" }), preserved.drop(while: { $0 != "\n" }), "Rename only changes the manifest source; note body remains exact")
        XCTAssertEqual(try context.query("SELECT total_changes() AS value").first?["value"] as? Int, beforeChanges, "Resolving the source is read-only")
        let pages = try NativePDFPageRepository(context: context, pdf: pdf)
        let revision = try pdf.checkBinding(["courseId": sourceCourse, "relPath": renamed])["documentRevision"]
        _ = try pages.handle("pdf:restructure", ["courseId": sourceCourse, "relPath": renamed, "documentRevision": try XCTUnwrap(revision), "clientMutationId": UUID().uuidString, "pages": [2, 1]])
        let reorderedNote = try XCTUnwrap(NativePDFPageNoteDocument(String(contentsOf: noteURL, encoding: .utf8)))
        XCTAssertEqual(reorderedNote.pages, ["두 번째 쪽 필기", "다른 과목에 보관한 원문 필기"])
        XCTAssertEqual(reorderedNote.source, renamed)
        let afterRestart = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let reopened = NativePDFPageNoteRepository(context: afterRestart, pdf: try NativePDFRepository(context: afterRestart))
        let reopenedSource = try XCTUnwrap(reopened.source(["courseId": targetCourse, "relPath": notePath]) as? [String: Any])
        XCTAssertEqual(reopenedSource["relPath"] as? String, renamed)
    }

}
