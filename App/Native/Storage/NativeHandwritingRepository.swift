import Foundation
import CoreGraphics
import CryptoKit

/// One page whose ink differs from what was last recognised. `page` is 1-based, as `pdf_drawings` stores it.
struct NativeHandwritingJob: Sendable {
    let documentID: String, courseID: String, relativePath: String
    let page: Int
    let digest: String
    var key: String { documentID + ":" + String(page) }
}
/// One recognised line. `box` is normalised to the displayed page with a top-left origin, like annotation rects.
struct NativeHandwritingLine: Sendable, Equatable {
    let text: String
    let box: CGRect
    let confidence: Double
}
/// The ink of one page, read on the storage queue and recognised off it.
struct NativeHandwritingSource: @unchecked Sendable {
    let url: URL
    let rows: [[String: Any]]
    /// Identity and edit time of every ink stroke: unchanged ink is not recognised again.
    let inkKey: String
    let unchanged: Bool
}

/// Text recognised from handwritten pages. Derived and device-local: it is rebuilt from `pdf_drawings`
/// on each device and never enters the sync outbox.
final class NativeHandwritingRepository {
    private let context: NativeRepositoryContext
    private let pdf: NativePDFRepository
    /// Pages edited in place since their rows were last read. A recognition that started earlier must not publish.
    private var invalidated = Set<String>()

    init(context: NativeRepositoryContext, pdf: NativePDFRepository) throws {
        self.context = context; self.pdf = pdf
        try context.db.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS handwriting_text USING fts5(document_id UNINDEXED,page_index UNINDEXED,line_index UNINDEXED,text,bbox UNINDEXED,confidence UNINDEXED,updated_at UNINDEXED,tokenize='trigram');
        CREATE TABLE IF NOT EXISTS handwriting_pages(document_id TEXT NOT NULL,page_index INTEGER NOT NULL,digest TEXT NOT NULL,ink_key TEXT NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(document_id,page_index));
        """)
    }

    /// Every page with live drawings, the ones still to read, and nothing left behind for pages or files that are gone.
    /// The digest (count and row ids) comes from the page index alone, so this never touches stroke data.
    func plan() throws -> (jobs: [NativeHandwritingJob], total: Int) {
        let rows = try context.query("""
        SELECT a.material_id AS doc,g.course_id,g.rel_path,g.page,g.digest FROM
          (SELECT course_id,rel_path,page,COUNT(*)||':'||TOTAL(rowid) AS digest FROM pdf_drawings WHERE deleted_at IS NULL GROUP BY course_id,rel_path,page) g
          JOIN pdf_document_aliases a ON a.course_id=g.course_id AND a.rel_path=g.rel_path
          JOIN courses c ON c.id=g.course_id AND c.deleted_at IS NULL
        ORDER BY g.course_id,g.rel_path,g.page
        """)
        var known: [String: (document: String, pageIndex: Int, digest: String)] = [:]
        for row in try context.query("SELECT document_id,page_index,digest FROM handwriting_pages") {
            guard let document = row["document_id"] as? String, let index = row["page_index"] as? Int else { continue }
            known[document + ":" + String(index + 1)] = (document, index, row["digest"] as? String ?? "")
        }
        var jobs: [NativeHandwritingJob] = [], total = 0, present: [String: Bool] = [:]
        for row in rows {
            guard let document = row["doc"] as? String, let course = row["course_id"] as? String, let path = row["rel_path"] as? String,
                  let page = row["page"] as? Int, let digest = row["digest"] as? String else { continue }
            // A trashed file keeps its ink rows for a restore; it is not searchable meanwhile.
            let exists = present[document] ?? ((try? context.materialURL(courseID: course, relativePath: path)) != nil)
            present[document] = exists
            guard exists else { continue }
            let job = NativeHandwritingJob(documentID: document, courseID: course, relativePath: path, page: page, digest: digest)
            total += 1
            if known.removeValue(forKey: job.key)?.digest != digest { jobs.append(job) }
        }
        if !known.isEmpty {
            try context.transaction { for stale in known.values { try remove(document: stale.document, pageIndex: stale.pageIndex) } }
        }
        return (jobs, total)
    }

    func source(_ job: NativeHandwritingJob) throws -> NativeHandwritingSource {
        invalidated.remove(job.key)
        let snapshot = try pdf.thumbnailSnapshot(["courseId": job.courseID, "relPath": job.relativePath, "page": job.page])
        let rows = (snapshot["drawings"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "ink" }
        let identity = rows.map { ($0["id"] as? String ?? "") + "@" + ($0["updatedAt"] as? String ?? "") }.joined(separator: "\n")
        let inkKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let stored = try context.query("SELECT ink_key FROM handwriting_pages WHERE document_id=? AND page_index=?", [job.documentID, job.page - 1]).first?["ink_key"] as? String
        return NativeHandwritingSource(url: try context.materialURL(courseID: job.courseID, relativePath: job.relativePath), rows: rows, inkKey: inkKey, unchanged: stored == inkKey)
    }

    /// Replaces one page's lines; `lines == nil` keeps them (the ink itself did not change).
    /// Returns false when the page changed while it was being read: it stays pending.
    @discardableResult func commit(_ job: NativeHandwritingJob, inkKey: String, lines: [NativeHandwritingLine]?) throws -> Bool {
        try context.transaction {
            let current = try context.query("SELECT COUNT(*)||':'||TOTAL(rowid) AS digest FROM pdf_drawings WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL",
                                            [job.courseID, job.relativePath, job.page]).first?["digest"] as? String
            guard current == job.digest, !invalidated.contains(job.key) else { return false }
            let now = NativeRepositoryContext.nowISO
            if let lines {
                // ponytail: an fts5 delete by document scans every indexed line; keep a rowid range per page if a library passes ~100k lines.
                try context.run("DELETE FROM handwriting_text WHERE document_id=? AND page_index=?", [job.documentID, job.page - 1])
                for (index, line) in lines.enumerated() {
                    let box = [line.box.minX, line.box.minY, line.box.width, line.box.height].map { ($0 * 10_000).rounded() / 10_000 }
                    try context.run("INSERT INTO handwriting_text(document_id,page_index,line_index,text,bbox,confidence,updated_at) VALUES(?,?,?,?,?,?,?)",
                                    [job.documentID, job.page - 1, index, line.text.precomposedStringWithCanonicalMapping, try NativeRepositoryContext.json(box), line.confidence, now])
                }
            }
            try context.run("INSERT INTO handwriting_pages(document_id,page_index,digest,ink_key,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(document_id,page_index) DO UPDATE SET digest=excluded.digest,ink_key=excluded.ink_key,updated_at=excluded.updated_at",
                            [job.documentID, job.page - 1, job.digest, inkKey, now])
            return true
        }
    }

    /// A stroke moved or reshaped in place keeps its row, so the page digest cannot see it.
    func invalidate(courseID: String, relativePath: String, page: Int) throws {
        guard let document = try context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [courseID, relativePath]).first?["material_id"] as? String else { return }
        invalidated.insert(document + ":" + String(page))
        try context.run("UPDATE handwriting_pages SET digest='' WHERE document_id=? AND page_index=?", [document, page - 1])
    }

    /// A file or folder moved to the trash takes its recognised text with it.
    func forget(courseID: String, relativePath: String) throws {
        let documents = try context.query("SELECT material_id,rel_path FROM pdf_document_aliases WHERE course_id=?", [courseID]).compactMap { row -> String? in
            guard let path = row["rel_path"] as? String, NativeRepositoryContext.contains(NativeRepositoryContext.key(relativePath), NativeRepositoryContext.key(path)) else { return nil }
            return row["material_id"] as? String
        }
        guard !documents.isEmpty else { return }
        try context.transaction { for document in documents { try remove(document: document, pageIndex: nil) } }
    }

    /// 설정 › 일반 › 손글씨 검색 off.
    func clear() throws {
        invalidated.removeAll()
        try context.transaction { try context.run("DELETE FROM handwriting_text"); try context.run("DELETE FROM handwriting_pages") }
    }

    private func remove(document: String, pageIndex: Int?) throws {
        let page = pageIndex.map { " AND page_index=\($0)" } ?? ""
        try context.run("DELETE FROM handwriting_text WHERE document_id=?" + page, [document])
        try context.run("DELETE FROM handwriting_pages WHERE document_id=?" + page, [document])
    }
}
