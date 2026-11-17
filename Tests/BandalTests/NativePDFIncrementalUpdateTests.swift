import XCTest
import PDFKit
import CoreGraphics
@testable import Bandal

/// Page add, delete and move keep the original bytes and are proven structurally,
/// so no PDFKit rendering or text difference can turn them into a conflict.
final class NativePDFIncrementalUpdateTests: XCTestCase {
    typealias D = NativePDFPageDocument
    typealias I = NativePDFIncrementalUpdate

    private func operations(_ count: Int) -> [(String, [Int])] {
        var result: [(String, [Int])] = [("append", Array(1...count) + [0]), ("insert", [1, 0] + Array(1...count).dropFirst())]
        if count > 1 { result.append(("delete", (1...count).filter { $0 != 2 })) }
        if count > 2 { result.append(("move", [2, 3, 1] + Array(1...count).dropFirst(3))) }
        return result
    }

    func testCorpusAddInsertDeleteMoveKeepOriginalBytesAndPages() throws {
        var report: [String] = []
        for item in try NativePDFTestCorpus.all() {
            let source = item.data, before = try XCTUnwrap(CGDataProvider(data: source as CFData).flatMap(CGPDFDocument.init), item.name)
            let count = try D.open(source).pageCount, paper = item.name == "app-paper"
            for (label, recipe) in operations(count) {
                let output: Data
                do { output = try D.rewrite(source, pages: recipe) }
                catch { XCTFail("\(item.name) \(label): \(error)"); continue }
                // The original is the first part of the result, byte for byte.
                XCTAssertEqual(output.prefix(source.count), source, "\(item.name) \(label)")
                let summary = try D.validate(source: source, target: output, pages: recipe)
                XCTAssertEqual(summary.rasterPages, 0, "\(item.name) \(label): proven without rendering")
                let after = try XCTUnwrap(CGDataProvider(data: output as CFData).flatMap(CGPDFDocument.init)), kit = try XCTUnwrap(PDFDocument(data: output))
                XCTAssertEqual(after.numberOfPages, recipe.count, "\(item.name) \(label)"); XCTAssertEqual(kit.pageCount, recipe.count, "\(item.name) \(label)")
                let original = try XCTUnwrap(PDFDocument(data: source))
                for (index, entry) in recipe.enumerated() {
                    let page = try XCTUnwrap(after.page(at: index + 1))
                    if entry == 0 {
                        let template = try XCTUnwrap(before.page(at: D.template(recipe, at: index)))
                        XCTAssertEqual(page.getBoxRect(.cropBox), template.getBoxRect(.cropBox), "\(item.name) \(label) new page size")
                        XCTAssertEqual(page.rotationAngle, template.rotationAngle, "\(item.name) \(label) new page rotation")
                        if paper { XCTAssertEqual(NativePDFTestCorpus.pixels(page), NativePDFTestCorpus.pixels(template), "app paper continues its paper") }
                        else { XCTAssertTrue(NativePDFTestCorpus.pixels(page).allSatisfy { $0 == 255 }, "\(item.name) \(label): an imported PDF gets an empty page") }
                        XCTAssertTrue(kit.page(at: index)?.annotations.isEmpty == true)
                        continue
                    }
                    let source = try XCTUnwrap(before.page(at: entry))
                    XCTAssertEqual(NativePDFTestCorpus.pixels(page), NativePDFTestCorpus.pixels(source), "\(item.name) \(label) page \(index + 1) draws exactly as before")
                    XCTAssertEqual(kit.page(at: index)?.string, original.page(at: entry - 1)?.string, "\(item.name) \(label) page \(index + 1) text")
                    XCTAssertEqual(kit.page(at: index)?.annotations.filter { $0.type != "Link" }.count, original.page(at: entry - 1)?.annotations.filter { $0.type != "Link" }.count)
                }
                report.append("\(item.name) \(label) +\(output.count - source.count)B")
            }
        }
        print("PDF_INCREMENTAL_CORPUS " + report.joined(separator: ", "))
    }

    func testRepeatedEditsStayIncrementalAndUndoIsProvenAgainstTheEditItReverses() throws {
        for item in try NativePDFTestCorpus.all() {
            var current = item.data, count = try D.open(current).pageCount
            for step in 0..<5 {
                let recipe: [Int]
                switch step {
                case 0: recipe = Array(1...count) + [0]
                case 1: recipe = [count] + Array(1..<count)
                case 2: recipe = Array(2...count)
                case 3: recipe = Array(1...count).reversed()
                default: recipe = [1, 0] + Array(1...count).dropFirst()
                }
                let next = try D.rewrite(current, pages: recipe)
                XCTAssertEqual(next.prefix(current.count), current, "\(item.name) step \(step)")
                if !recipe.contains(0), recipe.count == count {
                    // Sync checks an undo as the reverse edit: older bytes against newer.
                    let inverse = (1...count).map { page in recipe.firstIndex(of: page)! + 1 }
                    XCTAssertEqual(try D.validate(source: next, target: current, pages: inverse).rasterPages, 0, "\(item.name) undo of step \(step)")
                }
                current = next; count = recipe.count
            }
            XCTAssertEqual(PDFDocument(data: current)?.pageCount, count, item.name)
        }
    }

    func testDeletingAPageDropsItsBookmarksLinksAndOpenAction() throws {
        let source = NativePDFTestCorpus.hand(version: "1.7")
        // Page 2 is the target of the "Field theory" bookmark (a named destination), a GoTo link,
        // a named-destination link and the open action.
        let output = try D.rewrite(source, pages: [1, 3, 4, 5, 6, 7])
        let document = try XCTUnwrap(PDFDocument(data: output)), root = try XCTUnwrap(document.outlineRoot)
        let labels = (0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label }
        XCTAssertEqual(labels, ["Introduction", "Field theory", "Summary"], "an item with children stays")
        XCTAssertNil(root.child(at: 1)?.destination, "its destination went with the page")
        XCTAssertEqual(root.child(at: 1)?.child(at: 0)?.label, "Gauss")
        XCTAssertEqual(document.index(for: try XCTUnwrap(root.child(at: 2)?.destination?.page)), 5)
        let links = try XCTUnwrap(document.page(at: 0)).annotations.filter { $0.type == "Link" }
        XCTAssertEqual(links.count, 2, "Named NextPage and the URI stay; both links to page 2 go")
        let file = try NativePDFObjectFile(output), catalog = try XCTUnwrap(file.object(XCTUnwrap(file.trailer["Root"]?.reference)).dictionary)
        XCTAssertNil(catalog["OpenAction"])
        // A leaf bookmark to a deleted page goes, and its siblings are relinked.
        let last = try D.rewrite(source, pages: [1, 2, 3, 4, 5, 6])
        let outline = try XCTUnwrap(PDFDocument(data: last)?.outlineRoot)
        XCTAssertEqual((0..<outline.numberOfChildren).compactMap { outline.child(at: $0)?.label }, ["Introduction", "Field theory"])
    }

    func testRebuiltCrossReferenceIsWrittenWhole() throws {
        let broken = NativePDFTestCorpus.brokenStartXRef(NativePDFTestCorpus.hand(version: "1.4"))
        XCTAssertTrue(try NativePDFObjectFile(broken).repaired)
        let output = try D.rewrite(broken, pages: [1, 2, 3, 4, 5, 6, 7, 0])
        let fixed = try NativePDFObjectFile(output)
        XCTAssertFalse(fixed.repaired, "the update's cross-reference stands on its own")
        XCTAssertNil(fixed.trailer["Prev"])
        XCTAssertEqual(PDFDocument(data: output)?.pageCount, 8)
    }

    func testProofRejectsAnUpdateThatChangesWhatAKeptPageDraws() throws {
        let source = NativePDFTestCorpus.hand(version: "1.7"), recipe = [1, 2, 3, 4, 5, 6, 7, 0]
        let good = try I.write(source, pages: recipe, newPage: .blank).data
        XCTAssertNoThrow(try I.verify(source: source, target: good, pages: recipe))
        func appending(_ objects: String) -> Data {
            // Another update after ours that also redefines an object a kept page uses.
            let file = try! NativePDFObjectFile(good)
            var out = good, offsets: [(Int, Int)] = []
            for chunk in objects.components(separatedBy: "|||") {
                let number = Int(chunk.prefix { $0.isNumber })!
                offsets.append((number, out.count)); out.append(Data((chunk + "\nendobj\n").utf8))
            }
            let xref = out.count
            var table = "xref\n"
            for (number, offset) in offsets { table += "\(number) 1\n" + String(format: "%010d 00000 n \n", offset) }
            out.append(Data((table + "trailer\n<< /Size \(file.size) /Root 1 0 R /Info 80 0 R /Prev \(file.startxref) >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
            return out
        }
        let content = "BT /F1 28 Tf 48 330 Td (Changed) Tj ET"
        let changedContent = appending("61 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n" + content + "\nendstream")
        XCTAssertThrowsError(try I.verify(source: source, target: changedContent, pages: recipe), "a kept page's content stream")
        XCTAssertThrowsError(try I.verify(source: source, target: appending("20 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"), pages: recipe), "a font")
        XCTAssertThrowsError(try I.verify(source: source, target: appending("5 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 62 0 R >>"), pages: recipe), "a page pointing at other content")
        XCTAssertThrowsError(try I.verify(source: source, target: appending("2 0 obj\n<< /Type /Pages /Kids [6 0 R 5 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R 12 0 R] /Count 8 /MediaBox [0 0 720 405] /Resources << /Font << /F1 20 0 R >> >> >>"), pages: recipe), "pages in another order")
        var tampered = good; tampered[100] ^= 1
        XCTAssertThrowsError(try I.verify(source: source, target: tampered, pages: recipe), "the original bytes changed")
        XCTAssertThrowsError(try I.verify(source: source, target: good, pages: [1, 2, 3, 4, 5, 7, 6, 0]), "a recipe that does not match")
    }

    func testUnsupportedPageEditIsNotAConflict() throws {
        let error = DesktopRuntimeError("이 PDF는 페이지를 바꿀 수 없어 원래대로 두었어요.", code: D.unsupportedCode)
        XCTAssertEqual(NativePDFWorkspaceModel.pageFailureNotice(error), "이 PDF는 페이지를 바꿀 수 없어 원래대로 두었어요.")
        XCTAssertEqual(NativePDFWorkspaceModel.pageFailureNotice(NativeRepositoryContext.conflict("PDF가 다른 작업에서 변경되었습니다.")), "PDF가 방금 바뀌어서 페이지를 그대로 두었어요.")
        XCTAssertEqual(NativePDFWorkspaceModel.pageFailureNotice(NativeRepositoryContext.validation("암호화되었거나 손상된 PDF의 페이지는 변경할 수 없습니다.")), "암호화되었거나 손상된 PDF의 페이지는 변경할 수 없습니다.")
        XCTAssertFalse(NativePDFWorkspaceModel.pageFailureNotice(CancellationError()).contains("["))
    }

    /// Under sync pages may only be added at the end. The toast's 되돌리기 still works until the
    /// new page leaves this device; once it has been exchanged, undo stays off (design §4.6).
    func testAppendUnderSyncCanBeUndoneUntilItLeavesTheDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BandalSyncAppend-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NativeRepositoryContext(root: directory.appendingPathComponent("root"), legacyRoot: directory.appendingPathComponent("legacy"))
        let library = NativeLibraryRepository(context: context), pdf = try NativePDFRepository(context: context), pages = try NativePDFPageRepository(context: context, pdf: pdf)
        let course = try XCTUnwrap((try library.handle("courses:create", ["name": "동기화", "color": "blue"]) as? [String: Any])?["id"] as? String), path = "강의.pdf"
        let original = try NativePDFTestCorpus.quartz(pages: 3, size: CGSize(width: 960, height: 540), links: false)
        try context.atomicWrite(original, to: context.materialURL(courseID: course, relativePath: path, allowMissing: true))
        _ = try library.handle("materials:tree", ["courseId": course])
        _ = try SyncStore(context: context, keychain: .init(read: { _ in nil }, write: { _, _ in }))
        try context.run("INSERT OR REPLACE INTO cloud_sync_state(key,value) VALUES('provider','icloud')")
        try context.run("UPDATE courses SET source='managed' WHERE id=?", [course])
        func revision() throws -> String { try pdf.checkBinding(["courseId": course, "relPath": path])["documentRevision"] as! String }
        func call(_ channel: String, _ extra: [String: Any]) throws -> [String: Any] {
            var request: [String: Any] = ["courseId": course, "relPath": path, "documentRevision": try revision(), "clientMutationId": UUID().uuidString]
            request.merge(extra) { _, next in next }
            guard let value = try pages.handle(channel, request) as? [String: Any] else { throw NSError(domain: "no result", code: 1) }
            return value
        }
        let before = try revision()
        XCTAssertThrowsError(try call("pdf:restructure", ["pages": [2, 1, 3]]), "no reordering under sync")
        let added = try call("pdf:restructure", ["pages": [1, 2, 3, 0]]), token = try XCTUnwrap(added["historyToken"] as? String)
        XCTAssertEqual(try call("pdf:pageHistory", [:])["canUndo"] as? Bool, true, "not exchanged yet")
        func exchanged(_ sha: String) throws {
            var entity = SyncMerge.Entity()
            entity.fields["pdf_sha256"] = SyncMerge.Register(value: sha, stamp: SyncMerge.Stamp(t: 1, device: "a", seq: 1, index: 0))
            try context.run("INSERT OR REPLACE INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES('doc',?,?,'local',?)", [course, path, try SyncStore.encode(entity)])
        }
        try exchanged(try revision())
        XCTAssertEqual(try call("pdf:pageHistory", [:])["canUndo"] as? Bool, false, "other devices may have the new page")
        XCTAssertThrowsError(try call("pdf:restorePages", ["historyToken": token, "direction": "undo"])) { XCTAssertEqual(($0 as? DesktopRuntimeError)?.code, "SYNC_RESTRUCTURE_BLOCKED") }
        try exchanged(before)
        XCTAssertEqual(try call("pdf:pageHistory", [:])["canUndo"] as? Bool, true, "the exchanged PDF is still the one before the page was added")
        _ = try call("pdf:restorePages", ["historyToken": token, "direction": "undo"])
        XCTAssertEqual(try Data(contentsOf: context.materialURL(courseID: course, relativePath: path)), original)
        XCTAssertEqual(try call("pdf:pageHistory", [:])["canRedo"] as? Bool, false, "redo stays off under sync")
    }

    /// Opt-in: `TEST_RUNNER_BANDAL_PDF_CORPUS=<folder>` runs every PDF there (generated corpora, files
    /// an owner hands over outside the repository) through the same operations.
    func testExternalCorpusWhenProvided() throws {
        guard let folder = ProcessInfo.processInfo.environment["BANDAL_PDF_CORPUS"] else { throw XCTSkip("BANDAL_PDF_CORPUS not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
        var lines: [String] = [], conflicts = 0
        for name in files {
            let source = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name))
            guard let count = try? D.open(source).pageCount else { lines.append("\(name): not editable (encrypted or signed)"); continue }
            var line = name
            for (label, recipe) in operations(count) {
                do {
                    let output = try D.rewrite(source, pages: recipe)
                    let incremental = output.prefix(source.count) == source
                    line += " \(label)=\(incremental ? "incremental" : "fallback")"
                    XCTAssertEqual(PDFDocument(data: output)?.pageCount, recipe.count, "\(name) \(label)")
                } catch {
                    if (error as? DesktopRuntimeError)?.code == "CONFLICT" { conflicts += 1 }
                    line += " \(label)=refused(\((error as? DesktopRuntimeError)?.code ?? "?"))"
                }
            }
            lines.append(line)
        }
        print("PDF_EXTERNAL_CORPUS\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(conflicts, 0)
    }
}
