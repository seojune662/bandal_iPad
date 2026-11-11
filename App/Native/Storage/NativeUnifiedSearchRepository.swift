import Foundation

/// One statement over PDF and note text, recognised handwriting and conversations.
/// It only reads what is already indexed; refreshing the indexes is background work.
final class NativeUnifiedSearchRepository {
    private let context: NativeRepositoryContext
    /// Past this many hits a query is too broad to browse: each section keeps its best few.
    static let hitLimit = 1000, cappedSectionSize = 20, minimumLength = 2
    private static let snippetWindow = 160, snippetLength = 72

    /// Requires `native_search_documents` (NativeSearchRepository) and `handwriting_text` (NativeHandwritingRepository).
    init(context: NativeRepositoryContext) throws {
        self.context = context
        let fresh = try !context.tableExists("native_search_fts")
        try context.db.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS native_search_fts USING fts5(body,content='native_search_documents',content_rowid='rowid',tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS native_search_fts_insert AFTER INSERT ON native_search_documents BEGIN INSERT INTO native_search_fts(rowid,body) VALUES(new.rowid,new.body); END;
        CREATE TRIGGER IF NOT EXISTS native_search_fts_delete AFTER DELETE ON native_search_documents BEGIN INSERT INTO native_search_fts(native_search_fts,rowid,body) VALUES('delete',old.rowid,old.body); END;
        CREATE TRIGGER IF NOT EXISTS native_search_fts_update AFTER UPDATE ON native_search_documents BEGIN INSERT INTO native_search_fts(native_search_fts,rowid,body) VALUES('delete',old.rowid,old.body); INSERT INTO native_search_fts(rowid,body) VALUES(new.rowid,new.body); END;
        CREATE VIRTUAL TABLE IF NOT EXISTS chat_search USING fts5(text,tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS chat_search_insert AFTER INSERT ON message_blocks WHEN new.kind='text' AND json_valid(new.payload_json) BEGIN INSERT INTO chat_search(rowid,text) VALUES(new.rowid,COALESCE(json_extract(new.payload_json,'$.text'),'')); END;
        CREATE TRIGGER IF NOT EXISTS chat_search_delete AFTER DELETE ON message_blocks WHEN old.kind='text' BEGIN DELETE FROM chat_search WHERE rowid=old.rowid; END;
        """)
        // Text indexed and conversations held before this build.
        if fresh {
            try context.transaction {
                try context.run("INSERT INTO native_search_fts(native_search_fts) VALUES('rebuild')")
                try context.run("INSERT INTO chat_search(rowid,text) SELECT rowid,COALESCE(json_extract(payload_json,'$.text'),'') FROM message_blocks WHERE kind='text' AND json_valid(payload_json)")
            }
        }
    }

    /// `courseID == nil` searches every course. Sections come back in display order: 자료, 손글씨, 대화.
    func query(text: String, courseID: String?) throws -> [String: Any] {
        let needle = NativeRepositoryContext.key(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.unicodeScalars.count >= Self.minimumLength else { throw NativeRepositoryContext.validation("Search needs at least two characters") }
        // The trigram index answers three characters or more. Two characters scan the same tables.
        let indexed = needle.unicodeScalars.count >= 3
        let phrase = "\"" + needle.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let like = Self.like(needle)
        let limit = Self.hitLimit + 1, window = Self.snippetWindow
        let material = indexed ? (from: "native_search_fts JOIN native_search_documents d ON d.rowid=native_search_fts.rowid", match: "native_search_fts MATCH ?1", order: " ORDER BY native_search_fts.rank")
                               : (from: "native_search_documents d", match: "instr(d.search_key,?2)>0", order: "")
        let ink = indexed ? (match: "handwriting_text MATCH ?1", order: " ORDER BY handwriting_text.rank") : (match: "handwriting_text.text LIKE ?4 ESCAPE '\\'", order: "")
        let chat = indexed ? (match: "chat_search MATCH ?1", order: " ORDER BY chat_search.rank") : (match: "chat_search.text LIKE ?4 ESCAPE '\\'", order: " ORDER BY chat_search.rowid DESC")
        let rows = try context.query("""
        SELECT * FROM (SELECT 0 AS section,d.course_id AS course,c.name AS course_name,d.rel_path AS path,d.kind AS kind,d.page AS page,
            substr(d.body,max(1,instr(d.search_key,?2)-40),\(window)) AS text,NULL AS box,NULL AS title,NULL AS owner,NULL AS item,NULL AS policy
          FROM \(material.from) JOIN courses c ON c.id=d.course_id AND c.deleted_at IS NULL
          WHERE \(material.match) AND (?3 IS NULL OR d.course_id=?3)\(material.order) LIMIT \(limit))
        UNION ALL SELECT * FROM (SELECT 1,a.course_id,c.name,a.rel_path,'pdf',handwriting_text.page_index+1,handwriting_text.text,handwriting_text.bbox,NULL,NULL,NULL,NULL
          FROM handwriting_text JOIN pdf_document_aliases a ON a.material_id=handwriting_text.document_id JOIN courses c ON c.id=a.course_id AND c.deleted_at IS NULL
          WHERE \(ink.match) AND (?3 IS NULL OR a.course_id=?3)\(ink.order) LIMIT \(limit))
        UNION ALL SELECT * FROM (SELECT 2,m.course_id,c.name,NULL,m.role,NULL,
            substr(chat_search.text,max(1,instr(lower(chat_search.text),?2)-40),\(window)),NULL,s.title,s.id,m.id,s.access_policy
          FROM chat_search JOIN message_blocks b ON b.rowid=chat_search.rowid AND b.deleted_at IS NULL JOIN messages m ON m.id=b.message_id AND m.deleted_at IS NULL
            JOIN agent_sessions s ON s.id=m.session_id AND s.deleted_at IS NULL JOIN courses c ON c.id=m.course_id AND c.deleted_at IS NULL
          WHERE \(chat.match) AND (?3 IS NULL OR m.course_id=?3)\(chat.order) LIMIT \(limit))
        UNION ALL SELECT * FROM (SELECT 3,f.course_id,c.name,f.rel_path,f.kind,NULL,NULL,NULL,NULL,NULL,NULL,NULL
          FROM native_search_files f JOIN courses c ON c.id=f.course_id AND c.deleted_at IS NULL
          WHERE instr(lower(f.rel_path),?2)>0 AND (?3 IS NULL OR f.course_id=?3) LIMIT \(limit))
        """, indexed ? [phrase, needle, courseID ?? NSNull() as Any] : [NSNull(), needle, courseID ?? NSNull() as Any, like])
        var bySection: [Int: [[String: Any]]] = [:]
        for row in rows { bySection[row["section"] as? Int ?? 0, default: []].append(row) }
        // A file whose name matches leads the 자료 section even when its text does not.
        let named = (bySection[3] ?? []).filter { NativeRepositoryContext.key((($0["path"] as? String ?? "") as NSString).lastPathComponent).contains(needle) }
        let total = (bySection[0]?.count ?? 0) + (bySection[1]?.count ?? 0) + (bySection[2]?.count ?? 0) + named.count
        let capped = total > Self.hitLimit
        func kept(_ rows: [[String: Any]]) -> [[String: Any]] { capped ? Array(rows.prefix(Self.cappedSectionSize)) : rows }

        func files(_ hits: [[String: Any]], names: [[String: Any]] = [], handwriting: Bool) -> [[String: Any]] {
            var order: [String] = [], groups: [String: [String: Any]] = [:], pages: [String: [[String: Any]]] = [:]
            for row in names + hits {
                guard let course = row["course"] as? String, let path = row["path"] as? String, !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                let key = course + "\n" + path
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = ["courseId": course, "courseName": row["course_name"] ?? "", "relPath": path, "kind": row["kind"] ?? "pdf"]
                }
                guard let text = row["text"] as? String else { continue }
                var hit: [String: Any] = ["snippet": Self.snippet(text, needle: needle)]
                if let page = row["page"] as? Int, page > 0 { hit["page"] = page }
                if handwriting, let box = (row["box"] as? String).flatMap({ try? NativeRepositoryContext.jsonObject($0) }) { hit["box"] = box }
                pages[key, default: []].append(hit)
            }
            return order.map { key in var group = groups[key]!; group["hits"] = pages[key] ?? []; return group }
        }
        var conversations: [String] = [], sessions: [String: [String: Any]] = [:], messages: [String: [[String: Any]]] = [:]
        for row in kept(bySection[2] ?? []) {
            guard let session = row["owner"] as? String, let message = row["item"] as? String, let course = row["course"] as? String else { continue }
            let policy = (row["policy"] as? String).flatMap { try? NativeRepositoryContext.jsonObject($0) } as? [String: Any] ?? [:]
            // 대화 기록 저장 off: such a conversation is gone at the next launch and is never a result.
            if policy["ephemeral"] as? Bool == true { continue }
            if sessions[session] == nil {
                conversations.append(session)
                var value: [String: Any] = ["courseId": course, "courseName": row["course_name"] ?? "", "sessionId": session, "title": row["title"] as? String ?? ""]
                if let workspace = policy["workspace"] as? [String: Any] { value["workspace"] = workspace }
                sessions[session] = value
            }
            messages[session, default: []].append(["messageId": message, "role": row["kind"] ?? "user", "snippet": Self.snippet(row["text"] as? String ?? "", needle: needle)])
        }
        return ["query": needle, "capped": capped, "indexed": indexed, "sections": [
            ["id": "material", "groups": files(kept(bySection[0] ?? []), names: kept(named), handwriting: false)],
            ["id": "handwriting", "groups": files(kept(bySection[1] ?? []), handwriting: true)],
            ["id": "chat", "groups": conversations.map { id in var value = sessions[id]!; value["hits"] = messages[id] ?? []; return value }]
        ]]
    }

    /// Matches inside one document, for its viewer: how often each page's text has the query, and the
    /// handwritten lines that have it, top to bottom. Pages are 1-based.
    func document(courseID: String, relativePath: String, text: String) throws -> [String: Any] {
        let needle = NativeRepositoryContext.key(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return ["text": [[String: Any]](), "handwriting": [[String: Any]]()] }
        let pages = try context.query("SELECT page,search_key FROM native_search_documents WHERE course_id=? AND rel_path=? AND page>0 AND instr(search_key,?)>0 ORDER BY page", [courseID, relativePath, needle]).map { row -> [String: Any] in
            let key = row["search_key"] as? String ?? ""
            var count = 0, cursor = key.startIndex
            while let found = key.range(of: needle, options: .literal, range: cursor..<key.endIndex) { count += 1; cursor = found.upperBound }
            return ["page": row["page"] ?? 0, "count": count]
        }
        // Three characters or more go through the trigram index; shorter ones scan the recognised lines.
        let indexed = needle.unicodeScalars.count >= 3
        let lines = try context.query("SELECT handwriting_text.page_index,handwriting_text.text,handwriting_text.bbox FROM handwriting_text JOIN pdf_document_aliases a ON a.material_id=handwriting_text.document_id WHERE a.course_id=? AND a.rel_path=? AND \(indexed ? "handwriting_text MATCH ?" : "handwriting_text.text LIKE ? ESCAPE '\\'") ORDER BY handwriting_text.page_index,handwriting_text.line_index",
                                      [courseID, relativePath, indexed ? "\"" + needle.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : Self.like(needle)]).compactMap { row -> [String: Any]? in
            guard let index = row["page_index"] as? Int, let box = (row["bbox"] as? String).flatMap({ try? NativeRepositoryContext.jsonObject($0) }) else { return nil }
            return ["page": index + 1, "box": box, "text": row["text"] ?? ""]
        }
        return ["text": pages, "handwriting": lines]
    }
    private static func like(_ needle: String) -> String {
        "%" + needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// One line around the first match, with an ellipsis where text was cut.
    static func snippet(_ text: String, needle: String) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) as NSString
        guard flat.length > snippetLength else { return flat as String }
        let found = flat.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        let center = found.location == NSNotFound ? 0 : found.location
        var start = max(0, center - snippetLength / 3), end = min(flat.length, start + snippetLength)
        if end == flat.length { start = max(0, end - snippetLength) }; end = max(start, end)
        let range = flat.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return (range.location > 0 ? "…" : "") + flat.substring(with: range).trimmingCharacters(in: .whitespaces) + (NSMaxRange(range) < flat.length ? "…" : "")
    }
}
