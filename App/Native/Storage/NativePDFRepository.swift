import Foundation
import CryptoKit
import PDFKit
import CoreGraphics
import CoreText
import Darwin

/// Serial-queue repository for the existing PDF schema. All drawing data stays
/// in its original normalized, displayed-CropBox coordinates and ink version.
final class NativePDFRepository {
    static let channels = ["drawings:listForFile", "drawings:create", "drawings:mutationStatus", "drawings:update", "drawings:replace", "drawings:delete", "annotations:listForFile", "annotations:create", "annotations:update", "annotations:delete", "nativePDF:binding", "nativePDF:thumbnailSnapshot", "nativePDF:mutationStatus", "nativePDF:renderDrawings", "nativePDF:exportBytes", "pdf:getViewState", "pdf:setViewState", "pdfNotes:create"]
    private typealias V = NativePDFRepositoryValidation
    let context: NativeRepositoryContext
    private var verifiedOriginals = Set<String>()
    private let decodedDrawings = NativePDFDrawingDecodeCache()
    func releaseDecodedDrawings() { decodedDrawings.removeAll() }

    init(context: NativeRepositoryContext) throws {
        self.context = context
        try context.db.exec("""
        CREATE TABLE IF NOT EXISTS drawing_create_receipts (
          operation_id TEXT PRIMARY KEY, request_json TEXT NOT NULL, drawing_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS drawing_replace_receipts (
          operation_id TEXT PRIMARY KEY, request_json TEXT NOT NULL, before_json TEXT NOT NULL, after_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS annotation_create_receipts (
          operation_id TEXT PRIMARY KEY, request_json TEXT NOT NULL, annotation_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pdf_document_bindings (
          material_id TEXT PRIMARY KEY, bound_sha TEXT NOT NULL, evidence TEXT NOT NULL,
          legacy_unverified INTEGER NOT NULL, created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pdf_document_aliases (
          course_id TEXT NOT NULL, rel_path TEXT NOT NULL, material_id TEXT NOT NULL UNIQUE,
          PRIMARY KEY(course_id,rel_path), FOREIGN KEY(material_id) REFERENCES pdf_document_bindings(material_id)
        );
        """)
    }

    func handle(channel: String, _ request: [String: Any]) throws -> Any? {
        switch channel {
        case "nativePDF:binding": return try checkBinding(request)
        case "nativePDF:thumbnailSnapshot": return try thumbnailSnapshot(request)
        case "nativePDF:mutationStatus": return try mutationStatus(request)
        case "nativePDF:renderDrawings":
            guard let raw = request["pageAspects"] as? [Any] else { throw V.error("Invalid PDF page geometry") }
            let aspects = try raw.map { try V.number($0, "page aspect", positive: true) }
            return try listDrawings(request).map { row -> [String: Any] in
                guard ["ink", "highlighter"].contains(row["kind"] as? String ?? ""),
                      let data = row["data"] as? [String: Any], data["inkVersion"] == nil else { return row }
                let page = try V.integer(row["page"], "page")
                guard aspects.indices.contains(page - 1) else { throw V.error("기존 필기의 표시 경로를 준비하지 못했습니다.") }
                var row = row; row["nativePath"] = try NativePDFLegacyInk.path(row, aspect: aspects[page - 1]); return row
            }
        case "drawings:listForFile": return try listDrawings(request)
        case "drawings:create": return try createDrawing(request)
        case "drawings:mutationStatus": return try mutationStatus(request, measuredOnly: false)
        case "drawings:update": return try updateDrawing(request)
        case "drawings:replace": return try replaceDrawing(request)
        case "drawings:delete": try deleteDrawings(request); return ["ok": true]
        case "annotations:listForFile": return try listAnnotations(request)
        case "annotations:create": return try createAnnotation(request)
        case "annotations:update": return try updateAnnotation(request)
        case "annotations:delete": try deleteAnnotation(request); return ["ok": true]
        case "pdf:getViewState": return try getViewState(request)
        case "pdf:setViewState": return try setViewState(request)
        case "pdfNotes:create": return try createPaper(request)
        case "nativePDF:exportBytes": return try exportBytes(request)
        default: return nil
        }
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? { try handle(channel: channel, request) }

    private var db: DesktopSQLite { context.db }
    private func one(_ sql: String, _ params: [Any] = []) throws -> [String: Any]? { try db.query(sql, params: params).first }
    private func now() -> String { ISO8601DateFormatter.nativePDF.string(from: Date()) }
    private func identity(_ request: [String: Any]) throws -> (String, String) { (try V.id(request["courseId"], "courseId"), try V.path(request["relPath"])) }
    private func table(_ name: String) throws -> Bool { try one("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]) != nil }
    private func assertCourse(_ id: String) throws {
        guard try one("SELECT id FROM courses WHERE id=? AND deleted_at IS NULL", [id]) != nil else { throw V.error("PDF course is unavailable") }
    }
    private func checkPDF(_ course: String, _ path: String) throws {
        if path.lowercased().hasSuffix(".pdf") { _ = try checkBinding(["courseId": course, "relPath": path]) }
    }
    private func mismatch() -> DesktopRuntimeError {
        V.error("PDF 원본이 기존 필기와 다릅니다. 원래 PDF·필기·복구 기록을 보존했으며 새 원본에는 적용하지 않았습니다.")
    }

    /// Establish historical identity before a library rename changes any path.
    func prepareRename(courseID: String, from: String, to: String, isDirectory: Bool) throws {
        let from = try V.path(from), _ = try V.path(to)
        let folded = from.precomposedStringWithCanonicalMapping.lowercased()
        let rows = try db.query("SELECT rel_path FROM pdf_drawings WHERE course_id=? UNION SELECT rel_path FROM annotations WHERE course_id=? UNION SELECT rel_path FROM pdf_document_aliases WHERE course_id=?", params: [courseID, courseID, courseID])
        for row in rows {
            guard let path = row["rel_path"] as? String, path.lowercased().hasSuffix(".pdf") else { continue }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            if key == folded || isDirectory && key.hasPrefix(folded + "/") { _ = try checkBinding(["courseId": courseID, "relPath": path]) }
        }
    }

    func checkBinding(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request)
        try assertCourse(course)
        try assertPathAvailable(course: course, path: path)
        let expected = try request["documentRevision"].map { try V.digest($0) }
        let source = try context.materialURL(courseID: course, relativePath: path)
        let current = try revision(at: source)
        if let expected, expected != current { throw mismatch() }
        let bound: [String: Any] = try context.transaction {
            var bound = try binding(course: course, path: path)
            if bound == nil {
                let indexed = try one("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [course, path])
                var evidence: [String: String] = [:]
                for receipt in try db.query("SELECT r.request_json FROM drawing_create_receipts r JOIN pdf_drawings d ON d.id=r.drawing_id WHERE d.course_id=? AND d.rel_path=?", params: [course, path]) {
                    guard let input = try V.parse(receipt["request_json"]) as? [String: Any] else { throw V.error("Invalid PDF drawing receipt; recovery data was preserved") }
                    if let value = input["documentRevision"] { evidence[try V.digest(value)] = "receipt" }
                }
                if try table("ipad_sync_projection") {
                    for row in try db.query("SELECT payload_json,source_json FROM ipad_sync_projection WHERE kind='drawing'", params: []) {
                        guard let payload = try V.parse(row["payload_json"]) as? [String: Any], let source = try V.parse(row["source_json"]) as? [String: Any] else { throw V.error("Invalid PDF sync history") }
                        guard indexed?["id"] as? String == payload["materialID"] as? String && indexed != nil || source["courseID"] as? String == course && source["relPath"] as? String == path else { continue }
                        let digest = try V.digest(payload["documentRevision"])
                        if evidence[digest] == nil { evidence[digest] = "sync" }
                    }
                }
                guard evidence.count <= 1 else { throw V.error("서로 다른 PDF 원본의 필기 기록이 있습니다. 자료와 필기를 보존했으며 자동으로 합치지 않았습니다.") }
                let material = indexed?["id"] as? String ?? UUID().uuidString.lowercased()
                guard try one("SELECT material_id FROM pdf_document_bindings WHERE material_id=?", [material]) == nil else { throw V.error("PDF identity has no matching path alias") }
                let hasRows = try one("SELECT 1 FROM pdf_drawings WHERE course_id=? AND rel_path=? LIMIT 1", [course, path]) != nil || one("SELECT 1 FROM annotations WHERE course_id=? AND rel_path=? LIMIT 1", [course, path]) != nil
                let prior = evidence.first
                _ = try db.run("INSERT INTO pdf_document_bindings(material_id,bound_sha,evidence,legacy_unverified,created_at) VALUES(?,?,?,?,?)", params: [material, prior?.key ?? current, prior?.value ?? "first-observed", prior == nil && hasRows ? 1 : 0, now()])
                _ = try db.run("INSERT INTO pdf_document_aliases(course_id,rel_path,material_id) VALUES(?,?,?)", params: [course, path, material])
                bound = try binding(course: course, path: path)
            }
            guard let bound, let material = bound["material_id"] as? String else { throw V.error("Missing PDF binding") }
            if let indexed = try one("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [course, path]), indexed["id"] as? String != material {
                guard try one("SELECT course_id,rel_path FROM materials_index WHERE id=?", [material]) == nil else { throw V.error("PDF material identity is already assigned to another path") }
                _ = try db.run("UPDATE materials_index SET id=? WHERE id=?", params: [material, indexed["id"]!])
            }
            return bound
        }
        // The transaction commits historical evidence before rejecting a new
        // file. Relaunch must not turn a known mismatch into first-observed.
        guard bound["bound_sha"] as? String == current else { throw mismatch() }
        try preserveOriginal(source: source, digest: current)
        return ["materialID": bound["material_id"]!, "documentRevision": current,
                "evidence": bound["evidence"]!, "legacyUnverified": (bound["legacy_unverified"] as? NSNumber)?.boolValue ?? false]
    }
    private func binding(course: String, path: String) throws -> [String: Any]? {
        try one("SELECT b.* FROM pdf_document_aliases a JOIN pdf_document_bindings b ON b.material_id=a.material_id WHERE a.course_id=? AND a.rel_path=?", [course, path])
    }
    private func assertPathAvailable(course: String, path: String) throws {
        guard try table("material_path_intents") else { return }
        let rows = try db.query("SELECT * FROM material_path_intents WHERE course_id=?", params: [course])
        func overlaps(_ other: String) -> Bool {
            let a = path.precomposedStringWithCanonicalMapping.lowercased(), b = other.precomposedStringWithCanonicalMapping.lowercased()
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        for row in rows {
            var paths = [row["from_rel_path"], row["to_rel_path"]].compactMap { $0 as? String }
            if let raw = row["note_writes"] as? String, let writes = try V.parse(raw) as? [[String: Any]] { paths += writes.compactMap { $0["relPath"] as? String } }
            if paths.contains(where: overlaps) { throw DesktopRuntimeError("자료 경로 복구가 필요합니다. 파일과 기록을 보존했습니다. 반달을 다시 연 뒤 확인해 주세요.", code: "CONFLICT") }
        }
    }

    /// One hash per file version, shared with sync and page history (identity-keyed, persisted).
    func revision(at url: URL) throws -> String { try context.contentHash(url) }
    private func preserveOriginal(source: URL, digest: String) throws {
        guard !verifiedOriginals.contains(digest) else { return }
        let directory = context.root.appendingPathComponent("PDFOriginals", isDirectory: true), target = directory.appendingPathComponent(digest + ".pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try revision(at: target) == digest else { throw V.error("Preserved PDF original failed its integrity check") }
        } else {
            let temporary = directory.appendingPathComponent(digest + "." + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard try revision(at: temporary) == digest else { throw V.error("PDF changed while preserving its original; no ink was applied") }
            let file = try FileHandle(forWritingTo: temporary); defer { try? file.close() }; try file.synchronize()
            try FileManager.default.moveItem(at: temporary, to: target)
            try Self.syncDirectory(directory)
        }
        verifiedOriginals.insert(digest)
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY); guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func listDrawings(_ request: [String: Any]) throws -> [[String: Any]] {
        #if DEBUG
        let decodedBefore = decodedDrawings.decodeCount
        #endif
        let rows = try listRows(table: "pdf_drawings", request: request).map(drawing)
        #if DEBUG
        if ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"] != nil {
            print("[PDF_DECODE_CACHE] rows=\(rows.count) newDecodes=\(decodedDrawings.decodeCount - decodedBefore) retainedCost=\(decodedDrawings.retainedCost)")
        }
        #endif
        return rows
    }
    private func listRows(table: String, request: [String: Any]) throws -> [[String: Any]] {
        let (course, path) = try identity(request)
        let page = try request["page"].map { try V.integer($0, "page") }
        let identifiers: [String]?
        if let input = request["ids"] {
            guard let values = input as? [Any] else { throw V.error("ids must be an array") }
            identifiers = Array(try Set(values.map { try V.id($0) }))
        } else { identifiers = nil }
        if identifiers?.isEmpty == true { return [] }
        try checkPDF(course, path)
        let pageClause = page == nil ? "" : " AND page=?"
        var parameters: [Any] = [course, path]
        if let page { parameters.append(page) }
        let query = "SELECT rowid AS _native_order,* FROM \(table) WHERE course_id=? AND rel_path=? AND deleted_at IS NULL" + pageClause
        let order = " ORDER BY page ASC,created_at ASC,rowid ASC"
        guard let identifiers else { return try db.query(query + order, params: parameters) }
        var result: [[String: Any]] = []
        // Keep well below SQLite's conservative 999-variable limit, including
        // the course/path/page parameters. Decode only the requested objects.
        for start in stride(from: 0, to: identifiers.count, by: 400) {
            let chunk = Array(identifiers[start..<min(start + 400, identifiers.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            result += try db.query(query + " AND id IN (" + placeholders + ")" + order, params: parameters + chunk)
        }
        return result.sorted { left, right in
            let lp = (left["page"] as? NSNumber)?.intValue ?? 0, rp = (right["page"] as? NSNumber)?.intValue ?? 0
            if lp != rp { return lp < rp }
            let ld = left["created_at"] as? String ?? "", rd = right["created_at"] as? String ?? ""
            if ld != rd { return ld < rd }
            return ((left["_native_order"] as? NSNumber)?.int64Value ?? 0) < ((right["_native_order"] as? NSNumber)?.int64Value ?? 0)
        }
    }
    /// Previewing a library must not bind every unopened PDF, copy its original,
    /// or fsync it. Only already-bound ink is eligible for a preview. The normal
    /// editor open still establishes legacy bindings and recovery evidence.
    func thumbnailSnapshot(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request)
        let page = try V.integer(request["page"] ?? 1, "page")
        try assertCourse(course)
        try assertPathAvailable(course: course, path: path)
        let source = try context.materialURL(courseID: course, relativePath: path)
        let empty: [String: Any] = ["drawings": [[String: Any]](), "annotations": [[String: Any]]()]
        let arguments: [Any] = [course, path, page]
        let hasDrawings = try one("SELECT 1 FROM pdf_drawings WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL LIMIT 1", arguments) != nil
        let hasAnnotations = try one("SELECT 1 FROM annotations WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL LIMIT 1", arguments) != nil
        guard hasDrawings || hasAnnotations, let bound = try binding(course: course, path: path) else { return empty }
        // contentHash stat-checks a cached version before reading bytes. This
        // preserves replacement protection without preserveOriginal's writes.
        guard bound["bound_sha"] as? String == (try context.contentHash(source)) else { throw mismatch() }
        let drawings = hasDrawings ? try db.query("SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL ORDER BY created_at ASC", params: arguments).map(drawing) : []
        let annotations = hasAnnotations ? try db.query("SELECT * FROM annotations WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL ORDER BY created_at ASC", params: arguments).map(annotation) : []
        return ["drawings": drawings, "annotations": annotations]
    }
    private func drawing(_ row: [String: Any]) throws -> [String: Any] {
        let payload = try decodedDrawings.decode(row)
        return ["id": row["id"]!, "courseId": row["course_id"]!, "relPath": row["rel_path"]!, "page": row["page"]!, "kind": row["kind"]!,
         "data": payload.data, "style": payload.style, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!]
    }
    private func row(_ table: String, id: String, check: Bool = true) throws -> [String: Any] {
        guard let row = try one("SELECT * FROM \(table) WHERE id=? AND deleted_at IS NULL", [id]) else { throw DesktopRuntimeError("\(table) item was not found", code: "NOT_FOUND") }
        if check { try checkPDF(row["course_id"] as! String, row["rel_path"] as! String) }; return row
    }
    private func drawingInput(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request), kind = try V.kind(request["kind"])
        var result: [String: Any] = ["courseId": course, "relPath": path, "page": try V.integer(request["page"], "page"), "kind": kind,
                                   "data": try V.data(request["data"], kind: kind), "style": try V.style(request["style"])]
        if let revision = request["documentRevision"] { result["documentRevision"] = try V.digest(revision) }
        return result
    }
    private func createDrawing(_ request: [String: Any]) throws -> [String: Any] {
        let input = try drawingInput(request), course = input["courseId"] as! String, path = input["relPath"] as! String
        try assertCourse(course)
        let operation = try request["clientMutationId"].map { try V.uuid($0, "clientMutationId") }
        // Exact receipt replay precedes the current-file binding check. A retry
        // must acknowledge a historical commit even if the source moved later.
        if let operation, let receipt = try one("SELECT request_json,drawing_id FROM drawing_create_receipts WHERE operation_id=?", [operation]) {
            guard try V.receiptMatches(receipt["request_json"], input) else { throw V.error("A drawing operation cannot be reused for different content") }
            return try drawing(row("pdf_drawings", id: receipt["drawing_id"] as! String, check: false))
        }
        if let revision = input["documentRevision"] { _ = try checkBinding(["courseId": course, "relPath": path, "documentRevision": revision]) }
        else { try checkPDF(course, path) }
        let id = UUID().uuidString.lowercased(), timestamp = now()
        return try context.transaction {
            _ = try db.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", params:
                [id, course, path, input["page"]!, input["kind"]!, try V.json(input["data"]!), try V.json(input["style"]!), timestamp, timestamp])
            if let operation { _ = try db.run("INSERT INTO drawing_create_receipts(operation_id,request_json,drawing_id) VALUES(?,?,?)", params: [operation, try V.json(input), id]) }
            return try drawing(row("pdf_drawings", id: id, check: false))
        }
    }
    private func mutationStatus(_ request: [String: Any], measuredOnly: Bool = true) throws -> [String: Any] {
        let operation = try V.uuid(request["clientMutationId"], "clientMutationId"), input = try drawingInput(request)
        if measuredOnly {
            guard ["ink", "highlighter"].contains(input["kind"] as! String), let data = input["data"] as? [String: Any],
                  data["inkVersion"] != nil, input["documentRevision"] != nil else { throw V.error("Native PDF mutation requires measured versioned ink and a document revision") }
        } else if input["documentRevision"] == nil { throw V.error("Drawing mutation recovery requires a document revision") }
        guard let receipt = try one("SELECT r.request_json,r.drawing_id,d.id AS current_id,d.deleted_at FROM drawing_create_receipts r LEFT JOIN pdf_drawings d ON d.id=r.drawing_id WHERE r.operation_id=?", [operation]) else { return ["status": "missing"] }
        guard try V.receiptMatches(receipt["request_json"], input) else { throw V.error("A drawing operation cannot be reused for different content") }
        guard let id = receipt["drawing_id"] as? String, UUID(uuidString: id) != nil, receipt["current_id"] as? String == id else { throw V.error("Committed native PDF drawing is missing; preserve its recovery journal") }
        if receipt["deleted_at"] is NSNull {
            var result: [String: Any] = ["status": "live", "drawingId": id]
            if !measuredOnly { result["drawing"] = try drawing(row("pdf_drawings", id: id, check: false)) }
            return result
        }
        guard let deleted = receipt["deleted_at"] as? String, !deleted.isEmpty else { throw V.error("Invalid native PDF deletion receipt") }
        return ["status": "deleted", "drawingId": id]
    }
    private func updateDrawing(_ request: [String: Any]) throws -> [String: Any] {
        let old = try row("pdf_drawings", id: V.id(request["id"])), kind = old["kind"] as! String
        let data = try request["data"].map { try V.data($0, kind: kind) } ?? V.parse(old["data_json"])
        let style = try request["style"].map { try V.style($0) } ?? V.parse(old["style_json"])
        let page = try request["page"].map { try V.integer($0, "page") } ?? V.integer(old["page"], "page")
        _ = try db.run("UPDATE pdf_drawings SET page=?,data_json=?,style_json=?,updated_at=? WHERE id=?", params: [page, try V.json(data), try V.json(style), now(), old["id"]!])
        return try drawing(row("pdf_drawings", id: old["id"] as! String, check: false))
    }
    /// Kind-changing correction with an immutable receipt. Keeping the row ID
    /// preserves native ACK/eraser aliases; a lost reply never repeats an edit.
    private func replaceDrawing(_ request: [String: Any]) throws -> [String: Any] {
        let id = try V.id(request["id"]), operation = try V.uuid(request["operationId"], "operationId")
        let (course, path) = try identity(request), revision = try V.digest(request["documentRevision"])
        let expected = try V.object(request["expected"], "expected")
        let expectedInput = try drawingInput(expected)
        let kind = try V.kind(request["kind"]), data = try V.data(request["data"], kind: kind), style = try V.style(request["style"])
        guard expectedInput["courseId"] as? String == course, expectedInput["relPath"] as? String == path else {
            throw V.error("A correction cannot change drawing ownership")
        }
        var expectedContent = expectedInput; expectedContent.removeValue(forKey: "documentRevision")
        let fingerprint: [String: Any] = ["id": id, "courseId": course, "relPath": path, "documentRevision": revision,
            "expected": expectedContent, "kind": kind, "data": data, "style": style]
        if let receipt = try one("SELECT request_json,before_json,after_json FROM drawing_replace_receipts WHERE operation_id=?", [operation]) {
            guard try V.receiptMatches(receipt["request_json"], fingerprint) else { throw V.error("A correction operation cannot be reused for different content") }
            return ["before": try V.parse(receipt["before_json"]), "after": try V.parse(receipt["after_json"])]
        }
        _ = try checkBinding(["courseId": course, "relPath": path, "documentRevision": revision])
        return try context.transaction {
            let before = try drawing(row("pdf_drawings", id: id, check: false))
            guard try V.receiptMatches(try V.json(drawingInput(before)), expectedContent) else {
                throw V.error("The drawing changed before its correction; the original recovery record was preserved")
            }
            _ = try db.run("UPDATE pdf_drawings SET kind=?,data_json=?,style_json=?,updated_at=? WHERE id=? AND deleted_at IS NULL",
                params: [kind, try V.json(data), try V.json(style), now(), id])
            let after = try drawing(row("pdf_drawings", id: id, check: false))
            _ = try db.run("INSERT INTO drawing_replace_receipts(operation_id,request_json,before_json,after_json) VALUES(?,?,?,?)",
                params: [operation, try V.json(fingerprint), try V.json(before), try V.json(after)])
            return ["before": before, "after": after]
        }
    }
    private func deleteDrawings(_ request: [String: Any]) throws {
        guard let values = request["ids"] as? [Any] else { throw V.error("ids must be an array") }
        let ids = try Set(values.map { try V.id($0) })
        for id in ids { _ = try row("pdf_drawings", id: id) }
        try context.transaction {
            let timestamp = now()
            for id in ids { _ = try db.run("UPDATE pdf_drawings SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL", params: [timestamp, timestamp, id]) }
        }
    }

    func listAnnotations(_ request: [String: Any]) throws -> [[String: Any]] {
        try listRows(table: "annotations", request: request).map(annotation)
    }
    private func annotation(_ row: [String: Any]) throws -> [String: Any] {
        ["id": row["id"]!, "courseId": row["course_id"]!, "relPath": row["rel_path"]!, "page": row["page"]!, "color": row["color"]!,
         "rects": try V.parse(row["rects_json"]), "anchor": try V.parse(row["anchor_json"]), "comment": row["comment"] ?? NSNull(),
         "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!]
    }
    private func annotationColor(_ value: Any?) throws -> String {
        guard let value = value as? String, ["yellow", "green", "pink", "blue"].contains(value) else { throw V.error("Invalid annotation color") }; return value
    }
    private func comment(_ value: Any?) throws -> Any {
        guard let value else { return NSNull() }
        guard value is String || value is NSNull else { throw V.error("comment must be a string or null") }; return value
    }
    private func createAnnotation(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request); try assertCourse(course)
        let page = try V.integer(request["page"], "page"), color = try annotationColor(request["color"])
        guard let rects = request["rects"] as? [[String: Any]], !rects.isEmpty else { throw V.error("rects must be a non-empty array") }
        for rect in rects {
            for key in ["x", "y", "width", "height"] { _ = try V.number(rect[key], "rect." + key) }
            guard try V.number(rect["width"], "rect.width") > 0, try V.number(rect["height"], "rect.height") > 0 else { throw V.error("Empty annotation rectangle") }
        }
        let anchor = try V.object(request["anchor"], "anchor")
        guard ["quote", "prefix", "suffix"].allSatisfy({ anchor[$0] is String }) else { throw V.error("anchor needs string quote/prefix/suffix") }
        var input: [String: Any] = ["courseId": course, "relPath": path, "page": page, "color": color,
                                   "rects": rects, "anchor": anchor, "comment": try comment(request["comment"])]
        if let revision = request["documentRevision"] { input["documentRevision"] = try V.digest(revision) }
        let operation = try request["clientMutationId"].map { try V.uuid($0, "clientMutationId") }
        if let operation, let receipt = try one("SELECT request_json,annotation_id FROM annotation_create_receipts WHERE operation_id=?", [operation]) {
            guard try V.receiptMatches(receipt["request_json"], input) else { throw V.error("An annotation operation cannot be reused for different content") }
            return try annotation(row("annotations", id: receipt["annotation_id"] as! String, check: false))
        }
        if let revision = input["documentRevision"] { _ = try checkBinding(["courseId": course, "relPath": path, "documentRevision": revision]) }
        else { try checkPDF(course, path) }
        let id = UUID().uuidString.lowercased(), timestamp = now()
        return try context.transaction {
            _ = try db.run("INSERT INTO annotations(id,course_id,rel_path,page,color,rects_json,anchor_json,comment,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)", params:
                [id, course, path, page, color, try V.json(rects), try V.json(anchor), input["comment"]!, timestamp, timestamp])
            if let operation { _ = try db.run("INSERT INTO annotation_create_receipts(operation_id,request_json,annotation_id) VALUES(?,?,?)", params: [operation, try V.json(input), id]) }
            return try annotation(row("annotations", id: id, check: false))
        }
    }
    private func updateAnnotation(_ request: [String: Any]) throws -> [String: Any] {
        let old = try row("annotations", id: V.id(request["id"]))
        let color = try request["color"].map(annotationColor) ?? old["color"] as! String
        let comment = try request["comment"].map(self.comment) ?? old["comment"] ?? NSNull()
        _ = try db.run("UPDATE annotations SET color=?,comment=?,updated_at=? WHERE id=?", params: [color, comment, now(), old["id"]!])
        return try annotation(row("annotations", id: old["id"] as! String, check: false))
    }
    private func deleteAnnotation(_ request: [String: Any]) throws {
        let old = try row("annotations", id: V.id(request["id"])), timestamp = now()
        _ = try db.run("UPDATE annotations SET deleted_at=?,updated_at=? WHERE id=?", params: [timestamp, timestamp, old["id"]!])
    }
    private func getViewState(_ request: [String: Any]) throws -> Any {
        let (course, path) = try identity(request)
        guard let row = try one("SELECT * FROM pdf_view_state WHERE course_id=? AND rel_path=?", [course, path]) else { return NSNull() }
        return ["courseId": course, "relPath": path, "page": row["page"]!, "zoom": row["zoom"]!, "updatedAt": row["updated_at"]!]
    }
    private func setViewState(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request), timestamp = now()
        let page = (try? V.integer(request["page"], "page")) ?? 1, zoom = (try? V.number(request["zoom"], "zoom", positive: true)) ?? 1
        _ = try db.run("INSERT INTO pdf_view_state(course_id,rel_path,page,zoom,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(course_id,rel_path) DO UPDATE SET page=excluded.page,zoom=excluded.zoom,updated_at=excluded.updated_at", params: [course, path, page, zoom, timestamp])
        return ["courseId": course, "relPath": path, "page": page, "zoom": zoom, "updatedAt": timestamp]
    }

    private func createPaper(_ request: [String: Any]) throws -> [String: Any] {
        try context.withMaterialLock { try createPaperUnlocked(request) }
    }
    private func createPaperUnlocked(_ request: [String: Any]) throws -> [String: Any] {
        let course = try V.id(request["courseId"], "courseId"); try assertCourse(course)
        guard let paper = request["paper"] as? String, ["blank", "lines", "grid", "dots"].contains(paper) else { throw V.error("paper must be blank, lines, grid or dots") }
        let orientation = request["orientation"] as? String ?? "portrait"
        guard ["portrait", "landscape"].contains(orientation) else { throw V.error("orientation must be portrait or landscape") }
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var title = String(String.UnicodeScalarView((request["title"] as? String ?? "").unicodeScalars.filter { !invalid.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(title.prefix(120)); if title.isEmpty { title = "노트" }
        let directoryPath = request["dirRelPath"] as? String ?? "노트"
        let folder = try context.courseFolder(course)
        let directory = directoryPath.isEmpty ? folder : try context.materialURL(courseID: course, relativePath: V.path(directoryPath), allowMissing: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = title + ".pdf", suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { name = "\(title) (\(suffix)).pdf"; suffix += 1 }
        let target = directory.appendingPathComponent(name), relative = directoryPath.isEmpty ? name : directoryPath + "/" + name
        var fixtureText: String?
        #if DEBUG
        if context.root.lastPathComponent == "BandalDesktop-Native-UI-Tests",
           ProcessInfo.processInfo.arguments.contains("--native-ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--native-text-selection-fixture") { fixtureText = "Native Source" }
        #endif
        let bytes = try NativePDFPageTestFixture.makeIfRequested(root: context.root) ?? Self.paperData(title: title, paper: paper, orientation: orientation, fixtureText: fixtureText)
        try context.atomicWrite(bytes, to: target) {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw V.error("같은 이름의 파일이 이미 있습니다.") }
        }
        context.emit?("materials:changed", ["courseId": course])
        return ["relPath": relative, "name": name]
    }
    private func exportBytes(_ request: [String: Any]) throws -> [String: Any] {
        let (course, path) = try identity(request), binding = try checkBinding(request)
        let source = try context.materialURL(courseID: course, relativePath: path)
        let sourceBytes = try Data(contentsOf: source)
        let digest = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
        guard digest == binding["documentRevision"] as? String else { throw mismatch() }
        let drawings = try listDrawings(request), annotations = try listAnnotations(request)
        var images: [NativePDFExport.ImageSource] = []
        for row in drawings where row["kind"] as? String == "image" {
            guard let data = row["data"] as? [String: Any], let image = data["image"] as? [String: Any], let relative = image["relPath"] as? String,
                  let id = row["id"] as? String else { throw V.error("PDF 이미지 자료의 경로가 올바르지 않습니다.") }
            let url = try context.materialURL(courseID: course, relativePath: relative)
            images.append(.init(drawingID: id, bytes: try Data(contentsOf: url)))
        }
        let output = try NativePDFExport.render(source: sourceBytes, drawings: drawings, annotations: annotations, images: images)
        let name = (path as NSString).lastPathComponent as NSString
        return ["data": output.base64EncodedString(), "suggestedName": name.deletingPathExtension + " (주석).pdf", "mime": "application/pdf"]
    }
    static func paperData(title: String, paper: String, orientation: String, fixtureText: String? = nil) throws -> Data {
        let width = orientation == "landscape" ? 841.89 : 595.28, height = orientation == "landscape" ? 595.28 : 841.89
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes), let canvas = CGContext(consumer: consumer, mediaBox: &box,
            [kCGPDFContextTitle: title, kCGPDFContextCreator: "Bandal", kCGPDFContextKeywords: "bandal-note paper=\(paper) orientation=\(orientation)"] as CFDictionary) else { throw V.error("PDF 종이를 만들지 못했습니다.") }
        canvas.beginPDFPage(nil); canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(box)
        let ruling = CGColor(red: 0.82, green: 0.84, blue: 0.88, alpha: paper == "dots" ? 0.72 : 0.68)
        canvas.setFillColor(ruling); canvas.setStrokeColor(ruling); canvas.setLineWidth(0.55)
        if paper == "dots" {
            for x in stride(from: 28.0, to: width, by: 28) { for y in stride(from: 28.0, to: height, by: 28) { canvas.fillEllipse(in: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7)) } }
        } else if paper == "lines" || paper == "grid" {
            for y in stride(from: 28.0, to: height, by: 28) { canvas.move(to: CGPoint(x: 0, y: y)); canvas.addLine(to: CGPoint(x: width, y: y)) }
            if paper == "grid" { for x in stride(from: 28.0, to: width, by: 28) { canvas.move(to: CGPoint(x: x, y: 0)); canvas.addLine(to: CGPoint(x: x, y: height)) } }
            canvas.strokePath()
        }
        #if DEBUG
        if let fixtureText {
            let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: fixtureText, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            canvas.setFillColor(CGColor(gray: 0, alpha: 1))
            canvas.textPosition = CGPoint(x: (width - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: height / 2)
            CTLineDraw(line, canvas)
        }
        #endif
        canvas.endPDFPage(); canvas.closePDF(); return bytes as Data
    }
}

private extension ISO8601DateFormatter {
    static let nativePDF: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
}
