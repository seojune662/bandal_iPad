import Foundation

/// 짚어주기's second place to look when a page's own text lacks the quoted passage: the page's recognised
/// handwritten lines (`NativeHandwritingRepository`), top to bottom. Read only; empty while 손글씨 검색 is off.
enum NativePDFGuideHandwriting {
    static func lines(context: NativeRepositoryContext, request: [String: Any]) throws -> [[String: Any]] {
        let course = try NativeValue.string(request["courseId"], "과목"), path = try NativeValue.string(request["relPath"], "자료")
        let page = try NativeValue.int(request["page"], "페이지", min: 1)
        let rows = try context.query("""
        SELECT h.text,h.bbox FROM handwriting_text h JOIN pdf_document_aliases a ON a.material_id=h.document_id
        WHERE a.course_id=? AND a.rel_path=? AND h.page_index=? ORDER BY CAST(h.line_index AS INTEGER)
        """, [course, path, page - 1])
        return rows.compactMap { row in
            guard let text = row["text"] as? String, let raw = row["bbox"] as? String,
                  let box = (try? NativeRepositoryContext.jsonObject(raw)) as? [Double], box.count == 4, box.allSatisfy(\.isFinite) else { return nil }
            return ["text": text, "box": box]
        }
    }
}
