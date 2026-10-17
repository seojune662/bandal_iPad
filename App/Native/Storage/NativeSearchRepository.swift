import Foundation
import PDFKit

struct NativeSearchPDFJob: Sendable {
    let courseID: String
    let relativePath: String
    let url: URL
    let folder: URL
    let identity: String
}
struct NativeSearchPDFText: Sendable {
    let job: NativeSearchPDFJob
    let pages: [String]
}

/// Derived content only. The canonical course files remain authoritative and
/// every cached page is bound to its file identity and course folder.
final class NativeSearchRepository {
    private let context: NativeRepositoryContext
    private static let noteExtensions: Set<String> = ["md", "markdown"]
    private static let textExtensions: Set<String> = ["txt", "csv", "tsv", "json", "yml", "yaml", "xml", "html", "css", "js", "ts", "tex", "log", "srt", "vtt"]
    private static let maximumTextBytes = 2 * 1024 * 1024
    private static let maximumScannedFiles = 5000
    init(context: NativeRepositoryContext) throws {
        self.context = context
        try context.db.exec("""
        CREATE TABLE IF NOT EXISTS native_search_roots(course_id TEXT PRIMARY KEY,folder TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS native_search_files(course_id TEXT NOT NULL,rel_path TEXT NOT NULL,kind TEXT NOT NULL,identity TEXT NOT NULL,pdf_complete INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(course_id,rel_path));
        CREATE TABLE IF NOT EXISTS native_search_documents(course_id TEXT NOT NULL,rel_path TEXT NOT NULL,kind TEXT NOT NULL,page INTEGER NOT NULL DEFAULT 0,body TEXT NOT NULL,search_key TEXT NOT NULL,PRIMARY KEY(course_id,rel_path,page));
        CREATE INDEX IF NOT EXISTS native_search_documents_course ON native_search_documents(course_id);
        """)
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        switch channel {
        case "search:query":
            let course = try NativeValue.string(request["courseId"], "과목"), query = try NativeValue.string(request["query"], "검색어")
            let limit = try request["limit"].map { try NativeValue.int($0, "검색 결과 수", min: 1) } ?? 30
            return ["hits": try self.query(courseID: course, text: query, limit: min(100, limit))]
        case "search:indexPdfPages":
            try indexPDFPages(request); context.emit?("search:changed", ["courseId": request["courseId"]!]); return NativeValue.ok
        default: return nil
        }
    }
    func query(courseID: String, text: String, limit: Int = 30) throws -> [[String: Any]] {
        let needle = Self.key(try NativeValue.string(text, "검색어").trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty, limit >= 1 else { throw NativeRepositoryContext.validation("Invalid search query or limit") }
        try refresh(courseID: courseID)
        var hits: [[String: Any]] = [], offset: Int64 = 0
        // A substring predicate also covers single Korean syllables, quotes and
        // punctuation. Read in small batches instead of materializing a corpus.
        while true {
            let rows = try context.query("SELECT rowid,rel_path,kind,page,body,search_key FROM native_search_documents WHERE course_id=? AND rowid>? AND instr(search_key,?)>0 ORDER BY rowid LIMIT 16", [courseID, offset, needle])
            if rows.isEmpty { break }
            for row in rows {
                offset = (row["rowid"] as? NSNumber)?.int64Value ?? offset
                guard let body = row["body"] as? String, let key = row["search_key"] as? String, let found = key.range(of: needle, options: .literal) else { continue }
                let position = key.utf16.distance(from: key.utf16.startIndex, to: found.lowerBound.samePosition(in: key.utf16)!)
                var occurrences = 0, cursor = key.startIndex
                while occurrences < 50, let range = key.range(of: needle, options: .literal, range: cursor..<key.endIndex) { occurrences += 1; cursor = range.upperBound }
                let page = (row["page"] as? NSNumber)?.intValue ?? 0
                hits.append(["kind": row["kind"]!, "relPath": row["rel_path"]!, "page": page == 0 ? NSNull() : page as Any, "snippet": Self.snippet(body, at: position, length: needle.utf16.count), "score": occurrences * 100 + max(0, 50 - position / 20) + (position == 0 ? 25 : 0)])
            }
            hits.sort(by: Self.ranked)
            if hits.count > min(limit, 100) { hits.removeLast(hits.count - min(limit, 100)) }
        }
        return hits
    }

    /// Called on the serial storage queue. The returned immutable jobs can be
    /// extracted outside that queue, leaving document saves responsive.
    func preparePDFJobs(courseID: String) throws -> [NativeSearchPDFJob] {
        try refresh(courseID: courseID)
        let folder = try boundRoot(courseID)
        return try context.query("SELECT rel_path,identity FROM native_search_files WHERE course_id=? AND kind='pdf' AND pdf_complete=0 ORDER BY rel_path", [courseID]).map { row in
            let relative = row["rel_path"] as! String
            return NativeSearchPDFJob(courseID: courseID, relativePath: relative, url: try context.materialURL(courseID: courseID, relativePath: relative), folder: folder, identity: row["identity"] as! String)
        }
    }
    /// PDFKit owns its document on the calling worker; no view or SQLite state
    /// crosses the worker boundary. Encrypted or damaged originals are retained.
    static func extract(_ job: NativeSearchPDFJob) throws -> NativeSearchPDFText {
        let before = try NativeRepositoryContext.identity(job.url)
        guard try NativeRepositoryContext.json(before) == job.identity, let document = PDFDocument(url: job.url), !document.isLocked else { throw NativeRepositoryContext.validation("PDF text could not be read") }
        var pages: [String] = []; pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            if Task.isCancelled { throw CancellationError() }
            pages.append(autoreleasepool { document.page(at: index)?.string ?? "" })
        }
        guard try NativeRepositoryContext.sameIdentity(before, NativeRepositoryContext.identity(job.url)) else { throw NativeRepositoryContext.conflict("PDF changed during text extraction") }
        return NativeSearchPDFText(job: job, pages: pages)
    }
    /// Called back on the storage queue. A rename, replacement or relink makes
    /// a late extraction obsolete; none of its pages enter the new file's cache.
    func commit(_ extracted: NativeSearchPDFText) throws {
        let job = extracted.job
        guard try boundRoot(job.courseID) == job.folder,
              try context.materialURL(courseID: job.courseID, relativePath: job.relativePath) == job.url,
              try fingerprint(job.url) == job.identity else { throw NativeRepositoryContext.conflict("PDF search source changed before publication") }
        try context.transaction {
            try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [job.courseID, job.relativePath])
            for (index, text) in extracted.pages.enumerated() where !text.isEmpty { try insert(course: job.courseID, relative: job.relativePath, kind: "pdf", page: index + 1, text: text) }
            try saveMetadata(course: job.courseID, relative: job.relativePath, kind: "pdf", identity: job.identity, complete: true)
        }
        context.emit?("search:changed", ["courseId": job.courseID])
    }

    private func indexPDFPages(_ request: [String: Any]) throws {
        let course = try NativeValue.string(request["courseId"], "과목"), relative = try NativeValue.string(request["relPath"], "PDF 경로").precomposedStringWithCanonicalMapping
        _ = try boundRoot(course)
        let url = try context.materialURL(courseID: course, relativePath: relative)
        guard url.pathExtension.lowercased() == "pdf", let pages = request["pages"] as? [[String: Any]] else { throw NativeRepositoryContext.validation("PDF pages are required") }
        let identity = try fingerprint(url)
        var values: [Int: String] = [:]
        for page in pages {
            let number = try NativeValue.int(page["page"], "페이지", min: 1)
            guard let text = page["text"] as? String else { throw NativeRepositoryContext.validation("PDF page text must be a string") }
            values[number] = text
        }
        if values.isEmpty { return }
        try context.transaction {
            let previous = try context.query("SELECT identity FROM native_search_files WHERE course_id=? AND rel_path=?", [course, relative]).first?["identity"] as? String
            if previous != identity { try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [course, relative]) }
            for (page, text) in values {
                try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=? AND page=?", [course, relative, page])
                if !text.isEmpty { try insert(course: course, relative: relative, kind: "pdf", page: page, text: text) }
            }
            try saveMetadata(course: course, relative: relative, kind: "pdf", identity: identity, complete: true)
        }
    }
    private func refresh(courseID: String) throws {
        let root = try boundRoot(courseID)
        let old = try context.query("SELECT * FROM native_search_files WHERE course_id=?", [courseID])
        var byPath: [String: [String: Any]] = [:]
        for row in old { byPath[row["rel_path"] as! String] = row }
        var scanned = 0
        func walk(_ directory: URL, relative: String, depth: Int) throws {
            let children: [URL]
            do { children = try context.files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent } }
            catch { return } // An unreadable folder must not erase live entries.
            for entry in children {
                if scanned >= Self.maximumScannedFiles { return }
                guard let resource = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]), resource.isSymbolicLink != true else { continue }
                let path = (relative.isEmpty ? entry.lastPathComponent : relative + "/" + entry.lastPathComponent).precomposedStringWithCanonicalMapping
                if resource.isDirectory == true { if depth < 10 { try walk(entry, relative: path, depth: depth + 1) }; continue }
                guard resource.isRegularFile == true else { continue }; scanned += 1
                let ext = entry.pathExtension.lowercased()
                let kind = Self.noteExtensions.contains(ext) ? "note" : Self.textExtensions.contains(ext) ? "text" : ext == "pdf" ? "pdf" : nil
                guard let kind else { continue }
                let actual = try context.resolve(in: root, relativePath: path), info: [String: Any]
                do { info = try NativeRepositoryContext.identity(actual) } catch { continue }
                let identity = try NativeRepositoryContext.json(info)
                if byPath[path]?["identity"] as? String == identity { continue }
                if kind == "pdf" {
                    try context.transaction {
                        try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [courseID, path])
                        try saveMetadata(course: courseID, relative: path, kind: kind, identity: identity)
                    }
                    continue
                }
                let size = Int(info["size"] as? String ?? "") ?? Int.max
                var text: String?
                if size <= Self.maximumTextBytes {
                    guard let bytes = try? Data(contentsOf: actual), let after = try? NativeRepositoryContext.identity(actual), NativeRepositoryContext.sameIdentity(info, after) else { continue }
                    text = String(decoding: bytes, as: UTF8.self)
                }
                try context.transaction {
                    try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [courseID, path])
                    if let text { try insert(course: courseID, relative: path, kind: kind, page: 0, text: text) }
                    try saveMetadata(course: courseID, relative: path, kind: kind, identity: identity)
                }
            }
        }
        try walk(root, relative: "", depth: 0)
        // Scan caps and temporarily unreadable folders are not deletions. Check
        // each cached original before pruning or invalidating its prior pages.
        for row in old {
            let relative = row["rel_path"] as! String
            let url = try? context.resolve(in: root, relativePath: relative)
            let identity = url.flatMap { try? fingerprint($0) }
            if identity == nil {
                try context.transaction {
                    try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [courseID, relative])
                    try context.run("DELETE FROM native_search_files WHERE course_id=? AND rel_path=?", [courseID, relative])
                }
            } else if row["kind"] as? String == "pdf", identity != row["identity"] as? String {
                // A changed PDF beyond a scan cap still cannot expose old text.
                try context.transaction {
                    let current = try context.query("SELECT identity FROM native_search_files WHERE course_id=? AND rel_path=?", [courseID, relative]).first?["identity"] as? String
                    if current != identity {
                        try context.run("DELETE FROM native_search_documents WHERE course_id=? AND rel_path=?", [courseID, relative])
                        try saveMetadata(course: courseID, relative: relative, kind: "pdf", identity: identity!)
                    }
                }
            }
        }
    }
    private func boundRoot(_ course: String) throws -> URL {
        let root = try context.courseFolder(course)
        let cached = try context.query("SELECT folder FROM native_search_roots WHERE course_id=?", [course]).first?["folder"] as? String
        if cached != root.path {
            try context.transaction {
                try context.run("DELETE FROM native_search_documents WHERE course_id=?", [course]); try context.run("DELETE FROM native_search_files WHERE course_id=?", [course])
                try context.run("INSERT INTO native_search_roots(course_id,folder) VALUES(?,?) ON CONFLICT(course_id) DO UPDATE SET folder=excluded.folder", [course, root.path])
            }
        }
        return root
    }
    private func fingerprint(_ url: URL) throws -> String {
        let identity = try NativeRepositoryContext.identity(url)
        guard identity["directory"] as? Bool == false else { throw NativeRepositoryContext.validation("Search source must be a regular file") }
        return try NativeRepositoryContext.json(identity)
    }
    private func saveMetadata(course: String, relative: String, kind: String, identity: String, complete: Bool = false) throws {
        try context.run("INSERT INTO native_search_files(course_id,rel_path,kind,identity,pdf_complete) VALUES(?,?,?,?,?) ON CONFLICT(course_id,rel_path) DO UPDATE SET kind=excluded.kind,identity=excluded.identity,pdf_complete=excluded.pdf_complete", [course, relative, kind, identity, complete ? 1 : 0])
    }
    private func insert(course: String, relative: String, kind: String, page: Int, text: String) throws {
        let normalized = text.precomposedStringWithCanonicalMapping
        try context.run("INSERT INTO native_search_documents(course_id,rel_path,kind,page,body,search_key) VALUES(?,?,?,?,?,?)", [course, relative, kind, page, normalized, Self.key(normalized)])
    }
    private static func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func ranked(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        let a = left["score"] as! Int, b = right["score"] as! Int
        if a != b { return a > b }
        let x = left["relPath"] as! String, y = right["relPath"] as! String
        let comparison = x.compare(y, locale: Locale(identifier: "ko_KR"))
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return (left["page"] as? Int ?? 0) < (right["page"] as? Int ?? 0)
    }
    private static func snippet(_ body: String, at position: Int, length: Int) -> String {
        let text = body as NSString, budget = 158
        var start = min(text.length, max(0, position - max(0, budget - length) / 2)), end = min(text.length, start + budget)
        if end == text.length { start = max(0, end - budget) }; end = max(start, end)
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let context = text.substring(with: range).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(((start > 0 ? "…" : "") + context + (end < text.length ? "…" : "")).prefix(160))
    }
}
