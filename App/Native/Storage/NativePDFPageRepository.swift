import Foundation
import PDFKit

/// Durable PDF page history. PDF bytes, linked Markdown, the binding and ink
/// rows share one recovery journal and one SQLite commit receipt.
final class NativePDFPageRepository {
    static let channels = ["pdf:restructure", "pdf:pageHistory", "pdf:restorePages", "pdf:recoverPagesCopy"]
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    private typealias D = NativePDFPageDocument
    private let context: C
    private let pdf: NativePDFRepository
    private let journal: NativeSyncJournal
    init(context: NativeRepositoryContext, pdf: NativePDFRepository) throws {
        self.context = context; self.pdf = pdf; journal = try NativeSyncJournal(context: context)
        try context.db.exec("""
        CREATE TABLE IF NOT EXISTS native_pdf_page_history(id TEXT PRIMARY KEY,material_id TEXT NOT NULL,course_id TEXT NOT NULL,rel_path TEXT NOT NULL,before_sha TEXT NOT NULL,after_sha TEXT NOT NULL,before_json TEXT NOT NULL,after_json TEXT NOT NULL,files_json TEXT NOT NULL,recipe_json TEXT NOT NULL,parent_id TEXT,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS native_pdf_page_cursor(material_id TEXT PRIMARY KEY,undo_token TEXT,redo_json TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE IF NOT EXISTS native_pdf_page_receipts(operation_id TEXT PRIMARY KEY,request_json TEXT NOT NULL,result_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS native_pdf_revision_lineage(material_id TEXT NOT NULL,from_sha TEXT NOT NULL,to_sha TEXT NOT NULL,pages_json TEXT NOT NULL,PRIMARY KEY(material_id,from_sha,to_sha));
        """)
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard Self.channels.contains(channel) else { return nil }
        return try context.withMaterialLock {
            try journal.requireSettled()
            if channel == "pdf:pageHistory" { return try history(request) }
            let operation = try operationID(request)
            var canonical = request; canonical["channel"] = channel; canonical.removeValue(forKey: "clientMutationId"); canonical.removeValue(forKey: "operationId")
            if let receipt = try context.query("SELECT * FROM native_pdf_page_receipts WHERE operation_id=?", [operation]).first {
                guard try F.canonical(F.object(receipt["request_json"])) == F.canonical(canonical) else { throw C.conflict("같은 페이지 변경 요청을 다른 내용으로 다시 사용할 수 없습니다.") }
                return try F.object(receipt["result_json"])
            }
            switch channel {
            case "pdf:restructure": return try restructure(request, operation: operation, canonical: canonical)
            case "pdf:restorePages": return try restore(request, operation: operation, canonical: canonical)
            case "pdf:recoverPagesCopy": return try recoverCopy(request, operation: operation, canonical: canonical)
            default: return NSNull()
            }
        }
    }
    private func operationID(_ request: [String: Any]) throws -> String {
        let a = request["clientMutationId"] as? String, b = request["operationId"] as? String
        guard a == nil || b == nil || a == b, let id = a ?? b, UUID(uuidString: id) != nil else { throw C.validation("페이지 변경 요청 식별자가 올바르지 않습니다.") }; return id.lowercased()
    }
    private func identity(_ request: [String: Any], requireRevision: Bool = true) throws -> (String, String, [String: Any]) {
        guard let course = request["courseId"] as? String, let path = request["relPath"] as? String, path.lowercased().hasSuffix(".pdf") else { throw C.validation("PDF 자료가 필요합니다.") }
        var bindingRequest: [String: Any] = ["courseId": course, "relPath": path]
        let a = request["documentRevision"] as? String, b = request["expectedRevision"] as? String
        if requireRevision { guard a == nil || b == nil || a == b, let expected = a ?? b else { throw C.validation("PDF 원본 버전을 확인한 뒤 다시 시도해 주세요.") }; bindingRequest["documentRevision"] = expected }
        return (course, path, try pdf.checkBinding(bindingRequest))
    }
    private func cursor(_ material: String) throws -> (String?, [String]) {
        let row = try context.query("SELECT * FROM native_pdf_page_cursor WHERE material_id=?", [material]).first
        let redo = try (row?["redo_json"] as? String).map { try DesktopJSON.decode(Data($0.utf8)) as? [String] ?? [] } ?? []
        return (row?["undo_token"] as? String, redo)
    }
    func setCursor(_ material: String, undo: String?, redo: [String]) throws {
        try context.run("INSERT INTO native_pdf_page_cursor(material_id,undo_token,redo_json) VALUES(?,?,?) ON CONFLICT(material_id) DO UPDATE SET undo_token=excluded.undo_token,redo_json=excluded.redo_json", [material, undo ?? NSNull() as Any, F.canonical(redo)])
    }
    private func row(_ token: String, material: String) throws -> [String: Any] {
        guard let row = try context.query("SELECT * FROM native_pdf_page_history WHERE id=? AND material_id=?", [token, material]).first else { throw C.validation("페이지 변경 복구 기록이 없습니다.") }; return row
    }
    /// Eligibility reads just one side. Fetching SELECT * copied both large ink
    /// snapshots even though undo only needs after_json and redo only before_json.
    private func eligibilityRow(_ token: String, material: String, variant: String) throws -> [String: Any] {
        guard ["before", "after"].contains(variant) else { throw C.validation("Invalid PDF history variant") }
        let columns = "course_id,rel_path,\(variant)_sha,\(variant)_json,files_json"
        guard let row = try context.query("SELECT \(columns) FROM native_pdf_page_history WHERE id=? AND material_id=?", [token, material]).first else { throw C.validation("페이지 변경 복구 기록이 없습니다.") }
        return row
    }
    func state(course: String, path: String) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for table in ["pdf_drawings", "annotations", "pdf_view_state"] { result[table] = try context.query("SELECT * FROM \(table) WHERE course_id=? AND rel_path=? ORDER BY \(table == "pdf_view_state" ? "page" : "id")", [course, path]) }
        return result
    }
    func remap(_ before: [String: Any], map: [[Int]], count: Int) throws -> [String: Any] {
        var after = before
        for table in ["pdf_drawings", "annotations"] {
            after[table] = (before[table] as? [[String: Any]] ?? []).map { row -> [String: Any] in
                guard row["deleted_at"] is NSNull else { return row }
                var row = row; let page = (row["page"] as? NSNumber)?.intValue ?? 0
                if page > 0, map.indices.contains(page - 1), let next = map[page - 1].first {
                    guard next != page else { return row }
                    row["page"] = next
                }
                else if row["deleted_at"] is NSNull { row["deleted_at"] = C.nowISO }
                row["updated_at"] = C.nowISO; return row
            }
        }
        after["pdf_view_state"] = (before["pdf_view_state"] as? [[String: Any]] ?? []).map { row -> [String: Any] in
            var row = row; let page = (row["page"] as? NSNumber)?.intValue ?? 1
            let next = page > 0 && map.indices.contains(page - 1) ? map[page - 1].first ?? min(page, count) : 1
            guard next != page else { return row }
            row["page"] = next; row["updated_at"] = C.nowISO; return row
        }
        return after
    }
    func applyState(_ state: [String: Any], course: String, path: String) throws {
        for table in ["pdf_drawings", "annotations", "pdf_view_state"] {
            let current = try context.query("SELECT * FROM \(table) WHERE course_id=? AND rel_path=?", [course, path])
            let incoming = state[table] as? [[String: Any]] ?? []
            let keyedByID = table != "pdf_view_state"
            func key(_ row: [String: Any]) throws -> String {
                guard row["course_id"] as? String == course, row["rel_path"] as? String == path,
                      !keyedByID || row["id"] is String else { throw C.validation("PDF 페이지 기록의 자료 연결이 올바르지 않습니다.") }
                return keyedByID ? row["id"] as! String : "view"
            }
            var oldRows: [String: [String: Any]] = [:], seen = Set<String>()
            for row in current { oldRows[try key(row)] = row }
            for row in incoming {
                let id = try key(row)
                guard seen.insert(id).inserted else { throw C.validation("PDF 페이지 기록에 중복된 개체가 있습니다.") }
                guard let old = oldRows.removeValue(forKey: id) else { try insert(table, row); continue }
                // Appending a page leaves all existing ink byte-identical. Do
                // not delete/reinsert megabytes of point JSON for a no-op map.
                if try NativePDFPageStateEquality.row(old, row) { continue }
                let clause = "course_id=? AND rel_path=?" + (keyedByID ? " AND id=?" : "")
                let parameters: [Any] = [course, path] + (keyedByID ? [id] : [])
                if Set(old.keys) != Set(row.keys) {
                    try context.run("DELETE FROM \(table) WHERE \(clause)", parameters)
                    try insert(table, row)
                } else {
                    let changed = try row.keys.filter { try !NativePDFPageStateEquality.scalar(old[$0]!, row[$0]!) }.sorted()
                    guard !changed.isEmpty else { continue }
                    try context.run("UPDATE \(table) SET \(changed.map { $0 + "=?" }.joined(separator: ",")) WHERE \(clause)", changed.map { row[$0]! } + parameters)
                }
            }
            for id in oldRows.keys {
                try context.run("DELETE FROM \(table) WHERE course_id=? AND rel_path=?" + (keyedByID ? " AND id=?" : ""), [course, path] + (keyedByID ? [id] : []))
            }
        }
        for table in ["material_links", "recording_anchors"] { for row in state[table] as? [[String: Any]] ?? [] { try F.upsert(context, table: table, values: row) } }
    }
    private func insert(_ table: String, _ row: [String: Any]) throws {
        let keys = row.keys.sorted(); try context.run("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES(\(keys.map { _ in "?" }.joined(separator: ",")))", keys.map { row[$0]! })
    }
    func retain(_ data: Data) throws -> String {
        let hash = F.hash(data), target = context.root.appendingPathComponent("PDFOriginals/\(hash).pdf")
        try context.files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if context.files.fileExists(atPath: target.path) { guard try F.hash(target) == hash else { throw C.conflict("PDF 원본 백업을 확인하지 못했습니다.") } }
        else { try context.atomicWrite(data, to: target) }
        return hash
    }
    func original(_ hash: String) throws -> Data {
        guard hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw C.validation("Invalid PDF history digest") }
        let data = try Data(contentsOf: context.root.appendingPathComponent("PDFOriginals/\(hash).pdf")); guard F.hash(data) == hash else { throw C.conflict("PDF 복구 원본의 체크섬이 다릅니다.") }; return data
    }
    func invalidate(course: String, path: String, revision: String, material: String, size: Int) throws {
        try context.run("UPDATE pdf_document_bindings SET bound_sha=?,evidence='page-history',legacy_unverified=0 WHERE material_id=?", [revision, material])
        try context.run("UPDATE materials_index SET size=?,mtime=?,updated_at=? WHERE id=?", [size, Date().timeIntervalSince1970 * 1000, C.nowISO, material])
        for table in ["native_search_documents", "native_search_files"] where try context.tableExists(table) { try context.run("DELETE FROM \(table) WHERE course_id=? AND rel_path=?", [course, path]) }
    }
    private func saveReceipt(_ operation: String, _ request: [String: Any], _ result: [String: Any]) throws { try context.run("INSERT INTO native_pdf_page_receipts(operation_id,request_json,result_json) VALUES(?,?,?)", [operation, F.canonical(request), F.canonical(result)]) }
    private func publish(_ plan: NativeSyncPlan, courses: Set<String>, commit: () throws -> Void) throws {
        do { try journal.apply(plan, commit: commit) }
        catch { if (error as? DesktopRuntimeError)?.code == "RECOVERY_REQUIRED" { throw NativeSyncImportFailure(underlyingError: error, changedCourseIDs: courses) }; throw error }
        for course in courses { context.emit?("materials:changed", ["courseId": course]) }
    }
    private func restructure(_ request: [String: Any], operation: String, canonical: [String: Any]) throws -> [String: Any] {
        let (course, path, binding) = try identity(request), material = binding["materialID"] as! String, from = binding["documentRevision"] as! String
        let url = try context.materialURL(courseID: course, relativePath: path), bytes = try Data(contentsOf: url)
        guard F.hash(bytes) == from else { throw C.conflict("PDF가 다른 작업에서 변경되었습니다.") }
        let document = try D.open(bytes), pages = try D.recipe(request["pages"], count: document.pageCount), map = D.map(pages, count: document.pageCount)
        if pages == Array(1...document.pageCount) {
            let result: [String: Any] = ["documentRevision": from, "fingerprint": D.fingerprint(bytes), "pageCount": pages.count, "pageMap": map, "changedCourseIDs": [String](), "changedDocuments": [[String: Any]]()]
            try context.transaction { try saveReceipt(operation, canonical, result) }; return result
        }
        let output = try D.rewrite(bytes, pages: pages), to = try retain(output), _ = try retain(bytes)
        let fingerprint = D.fingerprint(output), sizes = D.sizes(try D.open(output)), token = UUID().uuidString.lowercased(), head = try cursor(material)
        var before = try state(course: course, path: path), after = try remap(before, map: map, count: pages.count)
        let links = try NativePDFPageLinks.plan(context: context, course: course, path: path, revision: from, pageMap: map, fingerprint: fingerprint, sizes: sizes)
        before.merge(links.before) { _, new in new }; after.merge(links.after) { _, new in new }
        var files = [NativeSyncFileChange(target: url, data: output, expectedHash: from)]
        files += try noteChanges(links.files, variant: "after")
        let courses = Set([course] + links.files.compactMap { $0["courseId"] as? String })
        let changedDocuments: [[String: Any]] = [["courseId": course, "relPath": path]] + links.files.compactMap { file in
            guard let owner = file["courseId"] as? String, let notePath = file["relPath"] as? String else { return nil }
            return ["courseId": owner, "relPath": notePath]
        }
        let result: [String: Any] = ["documentRevision": to, "fingerprint": fingerprint, "pageCount": pages.count, "pageMap": map, "historyToken": token, "changedCourseIDs": courses.sorted(), "changedDocuments": changedDocuments]
        let actual = NativeSyncPlan(files: files, courseID: course, apply: {
            try self.applyState(after, course: course, path: path); try self.invalidate(course: course, path: path, revision: to, material: material, size: output.count)
            try self.context.run("INSERT INTO native_pdf_page_history(id,material_id,course_id,rel_path,before_sha,after_sha,before_json,after_json,files_json,recipe_json,parent_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [token, material, course, path, from, to, F.canonical(before), F.canonical(after), F.canonical(links.files), F.canonical(pages), head.0 ?? NSNull() as Any, C.nowISO])
            try self.lineage(material: material, from: from, to: to, pages: pages.map { ["source": $0 == 0 ? NSNull() as Any : $0] }); try self.setCursor(material, undo: token, redo: [])
        })
        try publish(actual, courses: courses) { try self.saveReceipt(operation, canonical, result) }; return result
    }
    private func noteChanges(_ files: [[String: Any]], variant: String) throws -> [NativeSyncFileChange] {
        try files.map { row in
            guard let course = row["courseId"] as? String, let path = row["relPath"] as? String, let text = row[variant] as? String, let opposite = row[variant == "before" ? "after" : "before"] as? String else { throw C.validation("Invalid PDF page note history") }
            return .init(target: try context.materialURL(courseID: course, relativePath: path), data: Data(text.utf8), expectedHash: F.hash(Data(opposite.utf8)))
        }
    }
    private func eligible(_ row: [String: Any], course: String, path: String, revision: String, variant: String) throws -> Bool {
        guard row["course_id"] as? String == course, row["rel_path"] as? String == path, row[variant + "_sha"] as? String == revision else { return false }
        let expected = try F.object(row[variant + "_json"]), actual = try state(course: course, path: path)
        for table in ["pdf_drawings", "annotations"] { if try !NativePDFPageStateEquality.rows(expected[table] ?? [], actual[table] ?? []) { return false } }
        var related: [String: Set<String>] = [:]
        for row in try context.query("SELECT a.* FROM recording_anchors a JOIN recording_sessions s ON s.id=a.session_id WHERE s.course_id=?", [course]) {
            let value = try F.object(row["payload"])
            if value["relPath"] as? String == path, value["page"] is NSNumber || value["removedPage"] is NSNumber { related["recording_anchors", default: []].insert(row["id"] as! String) }
        }
        for row in try context.query("SELECT * FROM material_links") {
            for key in ["source_json", "target_json"] {
                let value = try F.object(row[key]), payload = value["payload"] as? [String: Any] ?? [:]
                if payload["courseId"] as? String == course, payload["relPath"] as? String == path { related["material_links", default: []].insert(row["id"] as! String) }
            }
        }
        for table in ["recording_anchors", "material_links"] {
            let expectedRows = expected[table] as? [[String: Any]] ?? []
            guard related[table, default: []] == Set(expectedRows.compactMap { $0["id"] as? String }) else { return false }
            for old in expectedRows {
                guard let current = try context.query("SELECT * FROM \(table) WHERE id=?", [old["id"]!]).first, try F.canonical(old) == F.canonical(current) else { return false }
            }
        }
        for file in try historyFiles(row) {
            guard let course = file["courseId"] as? String, let path = file["relPath"] as? String, let expected = file[variant] as? String, let url = try? context.materialURL(courseID: course, relativePath: path), (try? context.contentHash(url)) == F.hash(Data(expected.utf8)) else { return false }
        }
        return true
    }
    private func historyFiles(_ row: [String: Any]) throws -> [[String: Any]] { guard let raw = row["files_json"] as? String, let files = try DesktopJSON.decode(Data(raw.utf8)) as? [[String: Any]] else { throw C.validation("Invalid PDF history files") }; return files }
    /// Page count and restructure eligibility are fixed per revision; parse the file once.
    private var restructureInfo: [String: (pageCount: Int, reason: String?)] = [:]
    private func history(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path, binding) = try identity(request, requireRevision: false), material = binding["materialID"] as! String, revision = binding["documentRevision"] as! String, head = try cursor(material)
        let info: (pageCount: Int, reason: String?)
        if let cached = restructureInfo[revision] { info = cached } else {
            let url = try context.materialURL(courseID: course, relativePath: path), data = try Data(contentsOf: url)
            do { info = (try D.open(data).pageCount, nil) }
            catch {
                guard let document = PDFDocument(data: data) else { throw C.validation("PDF를 읽지 못했습니다.") }
                info = (document.pageCount, error.localizedDescription)
            }
            if restructureInfo.count >= 64 { restructureInfo.removeAll() }
            restructureInfo[revision] = info
        }
        var result: [String: Any] = ["documentRevision": revision, "pageCount": info.pageCount, "canUndo": false, "canRedo": false, "canRestructure": info.reason == nil]
        if let reason = info.reason { result["restructureReason"] = reason }
        if let token = head.0 { let row = try eligibilityRow(token, material: material, variant: "after"); result["undoToken"] = token; result["canUndo"] = try eligible(row, course: course, path: path, revision: revision, variant: "after"); result["recoverToken"] = token }
        if let token = head.1.last { let row = try eligibilityRow(token, material: material, variant: "before"); result["redoToken"] = token; result["canRedo"] = try eligible(row, course: course, path: path, revision: revision, variant: "before"); if result["recoverToken"] == nil { result["recoverToken"] = token } }
        if result["recoverToken"] == nil { result["recoverToken"] = try context.query("SELECT id FROM native_pdf_page_history WHERE material_id=? ORDER BY created_at DESC,rowid DESC LIMIT 1", [material]).first?["id"] }
        if result["recoverToken"] != nil { result["recoverVariant"] = "before"; result["reason"] = "변경 뒤 필기나 연결 노트를 수정했다면 원본에 덮어쓰지 않고 변경 전 사본으로 복구할 수 있습니다." }
        return result
    }
    private func restore(_ request: [String: Any], operation: String, canonical: [String: Any]) throws -> [String: Any] {
        let (course, path, binding) = try identity(request), material = binding["materialID"] as! String, current = binding["documentRevision"] as! String, head = try cursor(material)
        guard let token = request["historyToken"] as? String, let direction = request["direction"] as? String, ["undo", "redo"].contains(direction), token == (direction == "undo" ? head.0 : head.1.last) else { throw C.conflict("현재 페이지 변경 기록과 복원 요청이 다릅니다.") }
        let record = try row(token, material: material), fromVariant = direction == "undo" ? "after" : "before", toVariant = direction == "undo" ? "before" : "after"
        guard try eligible(record, course: course, path: path, revision: current, variant: fromVariant) else { throw C.conflict("페이지 변경 이후 수정된 필기·노트가 있습니다. 변경 전 사본으로 복구해 주세요.") }
        let target = record[toVariant + "_sha"] as! String, output = try original(target), state = try F.object(record[toVariant + "_json"]), fileHistory = try historyFiles(record)
        let pages = try DesktopJSON.decode(Data((record["recipe_json"] as! String).utf8)) as! [Int], beforeCount = try D.open(original(record["before_sha"] as! String)).pageCount
        let map: [[Int]] = direction == "undo" ? pages.map { $0 == 0 ? [] : [$0] } : D.map(pages, count: beforeCount)
        let url = try context.materialURL(courseID: course, relativePath: path), files = [NativeSyncFileChange(target: url, data: output, expectedHash: current)] + (try noteChanges(fileHistory, variant: toVariant)), courses = Set([course] + fileHistory.compactMap { $0["courseId"] as? String })
        let changedDocuments: [[String: Any]] = [["courseId": course, "relPath": path]] + fileHistory.compactMap { file in
            guard let owner = file["courseId"] as? String, let notePath = file["relPath"] as? String else { return nil }
            return ["courseId": owner, "relPath": notePath]
        }
        let result: [String: Any] = ["documentRevision": target, "fingerprint": D.fingerprint(output), "pageCount": try D.open(output).pageCount, "pageMap": map, "historyToken": token, "changedCourseIDs": courses.sorted(), "changedDocuments": changedDocuments]
        // Undo is a desktop recipe whose restored pages have no source in the
        // rewritten revision (null, like the desktop's blank-page insertion).
        let recipe: [[String: Any]] = direction == "undo" ? (1...beforeCount).map { ["source": pages.firstIndex(of: $0).map { $0 + 1 } ?? NSNull() as Any] } : pages.map { ["source": $0 == 0 ? NSNull() as Any : $0] }
        let plan = NativeSyncPlan(files: files, courseID: course, apply: {
            try self.applyState(state, course: course, path: path); try self.invalidate(course: course, path: path, revision: target, material: material, size: output.count)
            try self.lineage(material: material, from: current, to: target, pages: recipe)
            if direction == "undo" { try self.setCursor(material, undo: record["parent_id"] as? String, redo: head.1 + [token]) }
            else { try self.setCursor(material, undo: token, redo: Array(head.1.dropLast())) }
        })
        try publish(plan, courses: courses) { try self.saveReceipt(operation, canonical, result) }; return result
    }
    private func recoverCopy(_ request: [String: Any], operation: String, canonical: [String: Any]) throws -> [String: Any] {
        let (course, currentPath, binding) = try identity(request, requireRevision: false), material = binding["materialID"] as! String
        guard let token = request["historyToken"] as? String, let variant = request["variant"] as? String, ["before", "after"].contains(variant) else { throw C.validation("복구할 PDF 버전을 선택해 주세요.") }
        let record = try row(token, material: material), digest = record[variant + "_sha"] as! String, output = try original(digest), snapshot = try F.object(record[variant + "_json"])
        let folder = (currentPath as NSString).deletingLastPathComponent, title = ((currentPath as NSString).lastPathComponent as NSString).deletingPathExtension + " (페이지 복구)"
        var path = folder.isEmpty ? title + ".pdf" : folder + "/" + title + ".pdf", suffix = 2
        while context.files.fileExists(atPath: try context.materialURL(courseID: course, relativePath: path, allowMissing: true).path) { path = (folder.isEmpty ? "" : folder + "/") + title + " \(suffix).pdf"; suffix += 1 }
        let url = try context.materialURL(courseID: course, relativePath: path, allowMissing: true), id = UUID().uuidString.lowercased(), now = C.nowISO
        // A recovery copy only adds a file: lists reload, no open editor is invalidated.
        let result: [String: Any] = ["courseId": course, "relPath": path, "title": title, "kind": "pdf", "documentRevision": digest, "changedCourseIDs": [course], "changedDocuments": [[String: Any]]()]
        let plan = NativeSyncPlan(files: [.init(target: url, data: output, expectedMissing: true)], courseID: course, apply: {
            try self.context.run("INSERT INTO materials_index(id,course_id,rel_path,kind,size,mtime,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)", [id, course, path, "pdf", output.count, Date().timeIntervalSince1970 * 1000, now, now])
            try self.context.run("INSERT INTO pdf_document_bindings VALUES(?,?,?,0,?)", [id, digest, "page-recovery-copy", now]); try self.context.run("INSERT INTO pdf_document_aliases VALUES(?,?,?)", [course, path, id])
            for table in ["pdf_drawings", "annotations"] {
                for old in snapshot[table] as? [[String: Any]] ?? [] where old["deleted_at"] is NSNull {
                    var row = old; row["id"] = UUID().uuidString.lowercased(); row["course_id"] = course; row["rel_path"] = path; row["created_at"] = now; row["updated_at"] = now; try self.insert(table, row)
                }
            }
        })
        try publish(plan, courses: [course]) { try self.saveReceipt(operation, canonical, result) }; return result
    }
    /// `pages` is the desktop recipe `[{source: 1-based page of from | null, rotate?}]`.
    func lineage(material: String, from: String, to: String, pages: [[String: Any]]) throws {
        try context.run("INSERT INTO native_pdf_revision_lineage(material_id,from_sha,to_sha,pages_json) VALUES(?,?,?,?) ON CONFLICT(material_id,from_sha,to_sha) DO NOTHING", [material, from, to, F.canonical(pages)])
        if try context.tableExists("ipad_sync_projection") {
            for row in try context.query("SELECT id,payload_json FROM ipad_sync_projection WHERE kind='drawing'") {
                let payload = try F.object(row["payload_json"])
                if payload["materialID"] as? String == material, payload["documentRevision"] as? String != to { try context.run("UPDATE ipad_sync_projection SET deleted=1 WHERE id=?", [row["id"]!]) }
            }
        }
    }
}
