import Foundation
import XCTest
import CoreGraphics
import CoreText
@testable import Bandal

final class NativeSearchRepositoryTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var search: NativeSearchRepository!
    private var courseID: String!
    private var folder: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-search-\(UUID().uuidString)")
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        courseID = UUID().uuidString; folder = root.appendingPathComponent("Course")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = NativeRepositoryContext.nowISO
        try context.run("INSERT INTO courses(id,name,slug,color,folder_path,source,created_at,updated_at) VALUES(?,?,?,?,?,'managed',?,?)", [courseID!, "검색 자료", courseID!, "blue", folder.path, now, now])
        search = try NativeSearchRepository(context: context)
    }
    override func tearDownWithError() throws { search = nil; context = nil; try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url)
    }
    func testKoreanNFCShortQueriesPunctuationAndFreshExternalEdits() throws {
        try write("노트/기초.md", "힘과 모멘트. 아이패드에서 필기합니다. a+b [x]".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(try search.query(courseID: courseID, text: "아이패드").first?["relPath"] as? String, "노트/기초.md")
        XCTAssertEqual(try search.query(courseID: courseID, text: "힘").count, 1)
        XCTAssertEqual(try search.query(courseID: courseID, text: "a+b [x]").count, 1)
        try write("노트/기초.md", "새로 저장한 내용")
        XCTAssertTrue(try search.query(courseID: courseID, text: "아이패드").isEmpty)
        XCTAssertEqual(try search.query(courseID: courseID, text: "새로").count, 1)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("노트/기초.md"))
        XCTAssertTrue(try search.query(courseID: courseID, text: "새로").isEmpty)
    }
    func testPDFPagesSurviveRestartAndRejectStaleReplacement() throws {
        try pdf("original force").write(to: folder.appendingPathComponent("학습.pdf"))
        _ = try search.handle("search:indexPdfPages", ["courseId": courseID!, "relPath": "학습.pdf", "pages": [["page": 1, "text": "힘과 모멘트"], ["page": 2, "text": "다음 페이지"]]])
        search = try NativeSearchRepository(context: context)
        let hits = try search.query(courseID: courseID, text: "힘")
        XCTAssertEqual(hits.first?["kind"] as? String, "pdf"); XCTAssertEqual(hits.first?["page"] as? Int, 1)
        XCTAssertTrue(try search.preparePDFJobs(courseID: courseID).isEmpty)
        try pdf("new replacement").write(to: folder.appendingPathComponent("학습.pdf"), options: .atomic)
        XCTAssertTrue(try search.query(courseID: courseID, text: "힘").isEmpty)
        XCTAssertEqual(try search.preparePDFJobs(courseID: courseID).count, 1)
    }
    func testPDFKitWorkerExtractionAndLateCommitChecksCourseRelink() throws {
        try pdf("Force and moment").write(to: folder.appendingPathComponent("source.pdf"))
        let job = try XCTUnwrap(search.preparePDFJobs(courseID: courseID).first)
        let text = try NativeSearchRepository.extract(job)
        XCTAssertTrue(text.pages.joined().contains("Force and moment"))
        try search.commit(text)
        XCTAssertEqual(try search.query(courseID: courseID, text: "force").first?["page"] as? Int, 1)
        let newFolder = root.appendingPathComponent("Relinked"); try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try pdf("new identity").write(to: newFolder.appendingPathComponent("source.pdf"))
        try context.run("UPDATE courses SET folder_path=? WHERE id=?", [newFolder.path, courseID!])
        XCTAssertThrowsError(try search.commit(text))
        XCTAssertTrue(try search.query(courseID: courseID, text: "force").isEmpty)
    }
    func testInvalidPDFBatchIsAtomicAndEmptyPageRemovesOnlyThatPage() throws {
        try pdf("sample").write(to: folder.appendingPathComponent("source.pdf"))
        _ = try search.handle("search:indexPdfPages", ["courseId": courseID!, "relPath": "source.pdf", "pages": [["page": 1, "text": "retained"], ["page": 2, "text": "retained"]]])
        XCTAssertThrowsError(try search.handle("search:indexPdfPages", ["courseId": courseID!, "relPath": "source.pdf", "pages": [["page": 1, "text": "changed"], ["page": 0, "text": "invalid"]]]))
        XCTAssertEqual(try search.query(courseID: courseID, text: "retained").count, 2)
        _ = try search.handle("search:indexPdfPages", ["courseId": courseID!, "relPath": "source.pdf", "pages": [["page": 1, "text": ""]]])
        let hits = try search.query(courseID: courseID, text: "retained")
        XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits[0]["page"] as? Int, 2)
    }
    func testSymlinkEscapesAndOversizedTextNeverAppearInCourseSearch() throws {
        let external = root.appendingPathComponent("private.txt"); try Data("outside secret".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.txt"), withDestinationURL: external)
        try write(".hidden.md", "outside secret")
        try write("huge.txt", String(repeating: "outside secret", count: 200_000))
        XCTAssertTrue(try search.query(courseID: courseID, text: "secret").isEmpty)
        XCTAssertThrowsError(try search.handle("search:indexPdfPages", ["courseId": courseID!, "relPath": "../outside.pdf", "pages": []]))
    }
    func testRankingAndLimitAreStableAndSnippetsHandleUnicode() throws {
        try write("second.md", "prefix needle")
        try write("first.md", "needle needle needle")
        try write("unicode.md", String(repeating: "İ👨‍👩‍👧‍👦", count: 100) + "needle")
        let hits = try search.query(courseID: courseID, text: "needle", limit: 2)
        XCTAssertEqual(hits.count, 2); XCTAssertEqual(hits.first?["relPath"] as? String, "first.md")
        XCTAssertTrue(try search.query(courseID: courseID, text: "needle").allSatisfy { ($0["snippet"] as? String ?? "").count <= 160 })
    }
    private func pdf(_ text: String) throws -> Data {
        let bytes = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData)), graphics = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        graphics.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        graphics.textPosition = CGPoint(x: 30, y: 200); CTLineDraw(line, graphics)
        graphics.endPDFPage(); graphics.closePDF(); return bytes as Data
    }
}
