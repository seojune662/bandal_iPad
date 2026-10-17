import Foundation

/// A batch commits records individually. A later failure must not reactivate
/// editors whose canonical data was already replaced or could not be restored.
struct NativeSyncImportFailure: LocalizedError {
    let underlyingError: Error
    let changedCourseIDs: Set<String>
    var errorDescription: String? { underlyingError.localizedDescription }
}

/// Canonical CommonSync projection, entirely on the serial Swift storage queue.
final class NativeSyncRepository {
    private typealias F = NativeSyncFormat
    private typealias C = NativeRepositoryContext
    private let context: C
    private let library: NativeLibraryRepository
    private let materials: NativeSyncMaterials
    private let journal: NativeSyncJournal
    private var providers: [(snapshot: () throws -> NativeSyncSnapshot, plan: ([String: Any], [String: URL]) throws -> NativeSyncPlan?)] = []
    private var running = false
    init(context: NativeRepositoryContext, library: NativeLibraryRepository, checkPDFBinding: @escaping ([String: Any]) throws -> [String: Any]) throws {
        self.context = context; self.library = library
        materials = NativeSyncMaterials(context: context, checkBinding: checkPDFBinding)
        try context.db.exec("""
        CREATE TABLE IF NOT EXISTS ipad_sync_projection(id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload_json TEXT NOT NULL,deleted INTEGER NOT NULL,source_json TEXT NOT NULL,baseline_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS ipad_sync_conflicts(id TEXT PRIMARY KEY,record_id TEXT NOT NULL,reason TEXT NOT NULL,local_json TEXT,remote_json TEXT NOT NULL,created_at TEXT NOT NULL,resolved_at TEXT,assets_json TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE IF NOT EXISTS ipad_sync_commits(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ipad_sync_asset_cache(sha256 TEXT PRIMARY KEY,path TEXT NOT NULL);
        """)
        if try !context.columns("ipad_sync_conflicts").contains("assets_json") { try context.db.exec("ALTER TABLE ipad_sync_conflicts ADD COLUMN assets_json TEXT NOT NULL DEFAULT '[]'") }
        if try !context.columns("ipad_sync_conflicts").contains("related_json") { try context.db.exec("ALTER TABLE ipad_sync_conflicts ADD COLUMN related_json TEXT NOT NULL DEFAULT '{}'") }
        journal = try NativeSyncJournal(context: context)
        try context.withMaterialLock { try journal.recover() }
    }
    static func recoverFiles(context: NativeRepositoryContext) throws { try context.withMaterialLock { try NativeSyncJournal(context: context).recover() } }
    func registerProjection(snapshot: @escaping () throws -> NativeSyncSnapshot, plan: @escaping ([String: Any], [String: URL]) throws -> NativeSyncPlan?) { providers.append((snapshot, plan)) }
    /// Product scope never changes the wire protocol: out-of-scope records stay
    /// in the engine store and are neither published nor materialized here.
    static let personalScope = "personal-content-v1"
    static func inScope(_ record: [String: Any], _ scope: String?) -> Bool {
        guard scope == personalScope else { return true }
        let kind = record["kind"] as? String ?? ""
        if ["course", "material", "note", "drawing", "annotation"].contains(kind) { return true }
        return kind == "artifact" && ((record["payload"] as? [String: Any])?["recordType"] as? String) == "desktop-course-group"
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard ["nativeSync:export", "nativeSync:import", "nativeSync:conflicts", "nativeSync:restoreConflict"].contains(channel) else { return nil }
        if channel == "nativeSync:conflicts" { return try conflicts(scope: request["scope"] as? String, summary: request["summary"] as? Bool == true) }
        guard !running else { throw C.conflict("A sync projection operation is already running") }; running = true; defer { running = false }
        return try context.withMaterialLock {
            try journal.requireSettled()
            switch channel {
            case "nativeSync:export":
                let scope = request["scope"] as? String
                try refresh(); let snapshot = try snapshot()
                let blocked = Set(try context.query("SELECT DISTINCT record_id FROM ipad_sync_conflicts WHERE resolved_at IS NULL").compactMap { $0["record_id"] as? String })
                let records = snapshot.records.filter { !blocked.contains($0["id"] as? String ?? "") && Self.inScope($0, scope) }
                try context.transaction { for record in records { try F.validate(record); try save(record, source: snapshot.sources[record["id"] as! String] ?? [:]) } }
                guard scope == Self.personalScope else { return ["records": records, "assets": snapshot.assets] }
                let materials = Set(records.filter { $0["kind"] as? String == "material" }.compactMap { ($0["payload"] as? [String: Any])?["id"] as? String })
                let assets = snapshot.assets.filter { asset in
                    guard let owner = asset["materialID"] as? String else { return false }
                    return materials.contains(owner) || owner.hasPrefix("clip:")
                }
                return ["records": records, "assets": assets]
            case "nativeSync:import": return try importRecords(request)
            case "nativeSync:restoreConflict":
                guard let id = request["conflictID"] as? String, let variant = request["variant"] as? String, ["local", "remote"].contains(variant), let row = try context.query("SELECT * FROM ipad_sync_conflicts WHERE id=? AND resolved_at IS NULL", [id]).first, let selected = row[variant + "_json"] as? String else { throw C.validation("Conflict or selected variant is unavailable") }
                let related = try JSONSerialization.jsonObject(with: Data((row["related_json"] as? String ?? "{}").utf8)) as? [String: [[String: Any]]] ?? [:]
                let records = try [F.object(selected)] + (related[variant] ?? [])
                let reviewed = try [row["local_json"], row["remote_json"]].compactMap { $0 as? String }.map { try F.object($0) } + (related["local"] ?? []) + (related["remote"] ?? [])
                let storedAssets = try JSONSerialization.jsonObject(with: Data((row["assets_json"] as? String ?? "[]").utf8)) as? [[String: Any]] ?? []
                var result = try importRecords(["scope": request["scope"] ?? Self.personalScope, "records": records, "assets": (request["assets"] as? [[String: Any]] ?? []) + storedAssets], force: true, reviewed: reviewed)
                let resolved = (result["conflicts"] as? [Any])?.isEmpty == true && result["applied"] as? Int == records.count
                do {
                    if resolved {
                        let now = C.nowISO
                        try context.run("UPDATE ipad_sync_conflicts SET resolved_at=? WHERE id=?", [now, id])
                        // A complete structural restore also settles page conflicts whose
                        // exact selected envelopes were applied. Archived originals remain.
                        for page in records {
                            for pending in try context.query("SELECT id,local_json,remote_json FROM ipad_sync_conflicts WHERE record_id=? AND resolved_at IS NULL", [page["id"]!]) {
                                guard try F.comparable(F.object(pending["remote_json"])) == F.comparable(page) else { continue }
                                if let localJSON = pending["local_json"] as? String {
                                    let local = try F.object(localJSON)
                                    guard try reviewed.contains(where: { try F.comparable($0) == F.comparable(local) }) else { continue }
                                }
                                try context.run("UPDATE ipad_sync_conflicts SET resolved_at=? WHERE id=?", [now, pending["id"]!])
                            }
                        }
                        context.emit?("sync:conflictsChanged", [:])
                    }
                } catch {
                    let changed = Set(result["changedCourseIDs"] as? [String] ?? [])
                    guard !changed.isEmpty else { throw error }
                    throw NativeSyncImportFailure(underlyingError: error, changedCourseIDs: changed)
                }
                result["appliedRecords"] = result["applied"]; result["applied"] = resolved ? 1 : 0; result["resolved"] = resolved
                return result
            default: return NSNull()
            }
        }
    }
    private func refresh() throws {
        for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL") { _ = try library.handle("materials:tree", ["courseId": row["id"]!]) }
        // Restore canonical IDs after a rebuildable filesystem index was lost.
        try context.transaction {
            for row in try context.query("SELECT id,source_json FROM ipad_sync_projection WHERE kind='material'") {
                let source = try F.object(row["source_json"])
                guard let id = row["id"] as? String, id.hasPrefix("material:"), let course = source["courseID"] as? String, let path = source["relPath"] as? String, let current = try context.query("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [course, path]).first?["id"] as? String else { continue }
                let canonical = String(id.dropFirst(9))
                if current != canonical, try context.query("SELECT id FROM materials_index WHERE id=?", [canonical]).isEmpty { try context.run("UPDATE materials_index SET id=? WHERE id=?", [canonical, current]) }
            }
        }
    }
    private func snapshot() throws -> NativeSyncSnapshot {
        var result = try materials.snapshot()
        for provider in providers { result.append(try provider.snapshot()) }
        let old = try context.query("SELECT * FROM ipad_sync_projection")
        var byID: [String: [String: Any]] = [:]
        for row in old { byID[row["id"] as! String] = row }
        for index in result.records.indices {
            let id = result.records[index]["id"] as! String
            if let prior = byID[id] {
                var payload = try F.object(prior["payload_json"])
                payload.merge(result.records[index]["payload"] as? [String: Any] ?? [:]) { _, next in next }; result.records[index]["payload"] = payload
            }
        }
        let emitted = Set(result.records.compactMap { $0["id"] as? String })
        for row in old where !emitted.contains(row["id"] as! String) {
            let id = row["id"] as! String, kind = row["kind"] as! String, source = try F.object(row["source_json"])
            let disappeared = ["material", "note"].contains(kind) && (source["path"] as? String).map { !context.files.fileExists(atPath: $0) } == true
            result.records.append(F.record(id: id, kind: kind, payload: try F.object(row["payload_json"]), deleted: disappeared || (row["deleted"] as? NSNumber)?.boolValue == true)); result.sources[id] = source
        }
        // Unknown future envelope kinds retain their verified binary references.
        var hashes = Set(result.assets.compactMap { $0["sha256"] as? String })
        for row in try context.query("SELECT * FROM ipad_sync_asset_cache") {
            guard let hash = row["sha256"] as? String, let path = row["path"] as? String, hashes.insert(hash).inserted, context.files.fileExists(atPath: path), try F.hash(URL(fileURLWithPath: path)) == hash else { continue }
            result.assets.append(["sha256": hash, "path": path, "materialID": "preserved:\(hash)", "originalName": hash, "contentType": "application/octet-stream", "byteCount": (try context.files.attributesOfItem(atPath: path)[.size]) ?? 0])
        }
        return result
    }
    private func save(_ record: [String: Any], source: [String: Any], accepted: [String: Any]? = nil) throws {
        try context.run("INSERT INTO ipad_sync_projection(id,kind,payload_json,deleted,source_json,baseline_json) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,payload_json=excluded.payload_json,deleted=excluded.deleted,source_json=excluded.source_json,baseline_json=excluded.baseline_json", [record["id"]!, record["kind"]!, F.canonical(record["payload"]!), record["deleted"] as? Bool == true ? 1 : 0, F.canonical(source), F.comparable(accepted ?? record)])
    }
    private func importRecords(_ request: [String: Any], force: Bool = false, reviewed: [[String: Any]] = []) throws -> [String: Any] {
        var changed = Set<String>()
        do { return try performImport(request, force: force, reviewed: reviewed, changed: &changed) }
        catch {
            guard !changed.isEmpty else { throw error }
            throw NativeSyncImportFailure(underlyingError: error, changedCourseIDs: changed)
        }
    }
    private func performImport(_ request: [String: Any], force: Bool, reviewed: [[String: Any]], changed: inout Set<String>) throws -> [String: Any] {
        guard let incomingRecords = request["records"] as? [[String: Any]], request["assets"] == nil || request["assets"] is [[String: Any]], request["conflicts"] == nil || request["conflicts"] is [[String: Any]] else { throw C.validation("Invalid sync import") }
        let scope = request["scope"] as? String
        let records = incomingRecords.filter { Self.inScope($0, scope) }
        var seen = Set<String>()
        for record in records {
            try F.validate(record); let id = record["id"] as! String
            guard seen.insert(id).inserted else { throw C.validation("Duplicate sync record") }
            if let kind = try context.query("SELECT kind FROM ipad_sync_projection WHERE id=?", [id]).first?["kind"] as? String, kind != record["kind"] as? String { throw C.validation("Sync record kind changed") }
        }
        let assets = try preserveAssets(request["assets"] as? [[String: Any]] ?? [])
        try refresh(); let projected = try snapshot(); var current: [String: [String: Any]] = [:]
        for record in projected.records { current[record["id"] as! String] = record }
        // A PDF revision and its page records are reviewed as one choice.
        func relatedPages(_ local: [String: Any]?, _ remote: [String: Any]) -> [String: [[String: Any]]] {
            guard remote["kind"] as? String == "material", let p = remote["payload"] as? [String: Any], p["kind"] as? String == "pdf", let material = p["id"] as? String else { return [:] }
            func pages(_ values: [[String: Any]], revision: String?) -> [[String: Any]] {
                values.filter { $0["kind"] as? String == "drawing" && (($0["payload"] as? [String: Any])?["materialID"] as? String) == material && (($0["payload"] as? [String: Any])?["documentRevision"] as? String) == revision }
            }
            return ["local": pages(Array(current.values), revision: (local?["payload"] as? [String: Any])?["revision"] as? String), "remote": pages(records, revision: p["revision"] as? String)]
        }
        for item in request["conflicts"] as? [[String: Any]] ?? [] {
            guard let local = item["local"] as? [String: Any], let remote = item["remote"] as? [String: Any] else { throw C.validation("Invalid engine sync conflict") }
            guard Self.inScope(remote, scope) else { continue }
            try F.validate(local); try F.validate(remote); _ = try conflict(local, remote, reason: "Concurrent edits from another device", assets: assets, related: relatedPages(local, remote))
        }
        var applied = 0, found: [[String: Any]] = []
        var publishedHashes: [String: String] = [:], removedPaths = Set<String>()
        var blockedPDFMaterials = Set<String>(), blockedPageNotes = Set<String>()
        func blockPDF(_ record: [String: Any]) throws {
            guard record["kind"] as? String == "material", let payload = record["payload"] as? [String: Any], payload["kind"] as? String == "pdf", let material = payload["id"] as? String else { return }
            blockedPDFMaterials.insert(material)
            guard let row = try context.query("SELECT course_id,rel_path FROM materials_index WHERE id=?", [material]).first else { return }
            for link in try context.query("SELECT source_json,target_json FROM material_links WHERE kind='pdf-page-note'") {
                let source = try F.object(link["source_json"]), target = try F.object(link["target_json"]), a = source["payload"] as? [String: Any] ?? [:], b = target["payload"] as? [String: Any] ?? [:]
                if a["courseId"] as? String == row["course_id"] as? String, a["relPath"] as? String == row["rel_path"] as? String,
                   let course = b["courseId"] as? String, let path = b["relPath"] as? String,
                   let id = try context.query("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [course, path]).first?["id"] as? String { blockedPageNotes.insert(id) }
            }
        }
        func priority(_ r: [String: Any]) -> Int {
            let payload = r["payload"] as? [String: Any] ?? [:], type = payload["recordType"] as? String
            if type == "desktop-course-group" { return -1 }; if type == "desktop-chat-session" { return 6 }; if type == "desktop-chat-message" { return 7 }
            if r["kind"] as? String == "material", payload["kind"] as? String == "pdf" { return 1 }
            return ["course": 0, "material": 2, "note": 3, "drawing": 4, "task": 5, "recording": 6][r["kind"] as? String ?? ""] ?? 9
        }
        let ordered = records.enumerated().sorted { priority($0.element) == priority($1.element) ? $0.offset < $1.offset : priority($0.element) < priority($1.element) }.map(\.element)
        for incoming in ordered {
            var incoming = incoming
            let accepted = incoming, id = incoming["id"] as! String, local = current[id], mapped = try context.query("SELECT * FROM ipad_sync_projection WHERE id=?", [id]).first
            let payload = incoming["payload"] as? [String: Any] ?? [:]
            let dependency = payload["materialID"] as? String ?? (incoming["kind"] as? String == "material" ? payload["id"] as? String : nil)
            if let dependency, (incoming["kind"] as? String == "drawing" && blockedPDFMaterials.contains(dependency)) || blockedPageNotes.contains(dependency) {
                found.append(try conflict(local, incoming, reason: "The PDF page revision was not applied; dependent ink and page notes remain preserved", assets: assets, related: relatedPages(local, incoming))); continue
            }
            if force, let local, try !reviewed.contains(where: { try F.comparable($0) == F.comparable(local) }) {
                // Explicit selection replaces the visible version only after
                // newer edits and their assets have a durable conflict copy.
                // A failed preservation write throws before any file changes.
                found.append(try conflict(local, incoming, reason: "Local content changed while reviewing the earlier conflict", assets: assets, related: relatedPages(local, incoming))); continue
            }
            if let local, try F.comparable(local) == F.comparable(incoming) { try save(incoming, source: mapped.map { try F.object($0["source_json"]) } ?? projected.sources[id] ?? [:]); applied += 1; continue }
            if !force, let local {
                let baseline = try mapped.map { try F.canonical(F.object($0["baseline_json"])) }
                if try F.comparable(local) != baseline {
                    var merged: [String: Any]?
                    if incoming["kind"] as? String == "drawing", let mapped {
                        var base = try F.object(mapped["baseline_json"]); base["id"] = id; base["formatVersion"] = 1
                        merged = try mergeInk(base: base, local: local, remote: incoming)
                    }
                    guard let merged else { try blockPDF(incoming); found.append(try conflict(local, incoming, reason: "Local content changed after sync export", assets: assets, related: relatedPages(local, incoming))); continue }
                    incoming = merged
                }
            }
            var publishingCourseID: String?
            var publishingAffectedCourses = Set<String>()
            do {
                var plan = try materials.plan(incoming, assets: assets)
                for provider in providers where plan == nil { plan = try provider.plan(incoming, assets) }
                // Future schemas stay intact in SQLite until a compatible client opens them.
                var resolved = try plan ?? NativeSyncPlan(source: mapped.map { try F.object($0["source_json"]) } ?? [:])
                // The snapshot is the conflict decision. An external editor must not
                // be overwritten if it changed a file during planning.
                if let local, let source = projected.sources[id], let path = source["path"] as? String {
                    let payload = local["payload"] as? [String: Any] ?? [:]
                    let expected = local["kind"] as? String == "note" ? (payload["markdown"] as? String).map { F.hash(Data($0.utf8)) } : source["hash"] as? String
                    for index in resolved.files.indices where resolved.files[index].target.path == path { resolved.files[index].expectedHash = expected }
                }
                // Material and note envelopes intentionally share one file.
                // Compare later plans against this batch's own committed bytes.
                for index in resolved.files.indices {
                    let path = resolved.files[index].target.path
                    if let hash = publishedHashes[path] { resolved.files[index].expectedHash = hash; resolved.files[index].expectedMissing = false }
                    else if removedPaths.contains(path) { resolved.files[index].expectedHash = nil; resolved.files[index].expectedMissing = true }
                }
                publishingCourseID = resolved.courseID; publishingAffectedCourses = resolved.affectedCourseIDs
                try journal.apply(resolved) { try save(incoming, source: resolved.source, accepted: accepted) }
                if let course = resolved.courseID { changed.insert(course) }; changed.formUnion(resolved.affectedCourseIDs)
                for file in resolved.files {
                    if let data = file.data { publishedHashes[file.target.path] = F.hash(data); removedPaths.remove(file.target.path) }
                    else { publishedHashes.removeValue(forKey: file.target.path); removedPaths.insert(file.target.path) }
                }
                applied += 1; current[id] = incoming
            } catch {
                if (error as? DesktopRuntimeError)?.code == "RECOVERY_REQUIRED" {
                    // This plan may have published bytes which rollback could
                    // not restore. Include it even without a SQLite receipt.
                    if let course = publishingCourseID { changed.insert(course) }; changed.formUnion(publishingAffectedCourses)
                    throw error
                }
                try blockPDF(incoming)
                found.append(try conflict(local, incoming, reason: error.localizedDescription, assets: assets, related: relatedPages(local, incoming)))
            }
        }
        for course in changed { context.emit?("materials:changed", ["courseId": course]) }
        if !changed.isEmpty { context.emit?("courses:changed", [:]); context.emit?("board:changed", ["courseId": NSNull()]) }
        if !found.isEmpty { context.emit?("sync:conflictsChanged", ["count": found.count]) }
        return ["applied": applied, "changedCourseIDs": changed.sorted(), "conflicts": found]
    }
    private func preserveAssets(_ values: [[String: Any]]) throws -> [String: URL] {
        let directory = context.root.appendingPathComponent("SyncConflictAssets")
        try context.files.createDirectory(at: directory, withIntermediateDirectories: true)
        var assets: [String: URL] = [:]
        for row in try context.query("SELECT * FROM ipad_sync_asset_cache") { if let hash = row["sha256"] as? String, let path = row["path"] as? String { assets[hash] = URL(fileURLWithPath: path) } }
        for value in values {
            guard let hash = value["sha256"] as? String, hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil, let path = value["path"] as? String, path.hasPrefix("/") else { throw C.validation("Invalid sync asset") }
            let source = URL(fileURLWithPath: path), target = directory.appendingPathComponent(hash)
            _ = try C.identity(source)
            guard try F.hash(source) == hash else { throw C.conflict("Sync asset checksum mismatch") }
            if try !context.files.fileExists(atPath: target.path) || F.hash(target) != hash {
                let bytes = try Data(contentsOf: source); guard F.hash(bytes) == hash else { throw C.conflict("Sync asset changed during preservation") }; try context.atomicWrite(bytes, to: target)
            }
            assets[hash] = target; try context.run("INSERT OR REPLACE INTO ipad_sync_asset_cache(sha256,path) VALUES(?,?)", [hash, target.path])
        }
        return assets
    }
    private func conflict(_ local: [String: Any]?, _ remote: [String: Any], reason: String, assets: [String: URL], related: [String: [[String: Any]]] = [:]) throws -> [String: Any] {
        var digestInput: [String: Any] = ["local": local ?? NSNull() as Any, "remote": remote, "reason": reason]
        if !related.isEmpty { digestInput["related"] = related }
        var id = try F.digest(digestInput)
        // Keep resolutions across runtimes whose JSON encoders spell the same
        // numeric value differently. Existing envelopes are compared structurally.
        for old in try context.query("SELECT id,local_json,remote_json FROM ipad_sync_conflicts WHERE record_id=? AND reason=?", [remote["id"]!, reason]) {
            let priorLocal: Any = try (old["local_json"] as? String).map { try F.object($0) } ?? NSNull() as Any
            if try F.canonical(priorLocal) == F.canonical(local ?? NSNull() as Any), try F.canonical(F.object(old["remote_json"])) == F.canonical(remote) { id = old["id"] as! String; break }
        }
        var copies: [[String: Any]] = []
        for record in [local, remote].compactMap({ $0 }) where record["deleted"] as? Bool != true {
            let p = record["payload"] as? [String: Any] ?? [:]
            let hash = p["assetRevision"] as? String ?? (record["kind"] as? String == "material" ? p["revision"] as? String : nil)
            if let hash, let url = assets[hash] { copies.append(["sha256": hash, "path": url.path]); continue }
            if let hash, hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil {
                let mapped = try context.query("SELECT source_json FROM ipad_sync_projection WHERE id=?", [record["id"]!]).first
                let source = try mapped.map { try F.object($0["source_json"]) } ?? [:]
                var path = source["path"] as? String
                if let mid = p["id"] as? String, record["kind"] as? String == "material", let item = try context.query("SELECT course_id,rel_path FROM materials_index WHERE id=?", [mid]).first { path = try context.materialURL(courseID: item["course_id"] as! String, relativePath: item["rel_path"] as! String, allowMissing: true).path }
                if let path, context.files.fileExists(atPath: path), try F.hash(URL(fileURLWithPath: path)) == hash { let saved = try preserveAssets([["sha256": hash, "path": path]]); if let url = saved[hash] { copies.append(["sha256": hash, "path": url.path]) } }
            }
        }
        // Include verified bundle assets for future/learning payloads as well.
        for (hash, url) in assets where !copies.contains(where: { $0["sha256"] as? String == hash }) { copies.append(["sha256": hash, "path": url.path]) }
        try context.run("INSERT INTO ipad_sync_conflicts(id,record_id,reason,local_json,remote_json,created_at,assets_json,related_json) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET assets_json=excluded.assets_json,related_json=excluded.related_json", [id, remote["id"]!, reason, try local.map { try F.canonical($0) } ?? NSNull(), F.canonical(remote), C.nowISO, F.canonical(copies), F.canonical(related)])
        return ["id": id, "recordID": remote["id"]!, "reason": reason]
    }
    private func conflicts(scope: String?, summary: Bool) throws -> [[String: Any]] {
        try context.query("SELECT * FROM ipad_sync_conflicts WHERE resolved_at IS NULL ORDER BY created_at DESC").compactMap { row in
            let local = try (row["local_json"] as? String).map { try F.object($0) }, remote = try F.object(row["remote_json"]), p = (local ?? remote)["payload"] as? [String: Any] ?? [:]
            guard Self.inScope(remote, scope) else { return nil }
            let related = try JSONSerialization.jsonObject(with: Data((row["related_json"] as? String ?? "{}").utf8)) as? [String: [[String: Any]]] ?? [:]
            let mapped = try context.query("SELECT source_json FROM ipad_sync_projection WHERE id=?", [row["record_id"]!]).first
            let source = try mapped.map { try F.object($0["source_json"]) } ?? [:]
            let material = try (p["materialID"] as? String).flatMap { try context.query("SELECT course_id,rel_path FROM materials_index WHERE id=?", [$0]).first }
            let course = p["courseID"] as? String ?? source["courseID"] as? String ?? material?["course_id"] as? String
            let name = try course.flatMap { try context.query("SELECT name FROM courses WHERE id=?", [$0]).first?["name"] as? String }
            let title = p["title"] as? String ?? p["name"] as? String ?? material?["rel_path"] as? String ?? source["relPath"] as? String ?? p["rootRelPath"] as? String ?? row["record_id"] as! String
            let label = name.map { "\($0) · \(title)" } ?? title
            if summary {
                // Human-review metadata only; the complete envelopes stay on disk.
                return ["id": row["id"]!, "recordID": row["record_id"]!, "label": label, "reason": row["reason"]!, "local": local != nil, "remote": true, "createdAt": row["created_at"]!,
                        "variants": ["local": Self.variantSummary(local, related: related["local"] ?? []), "remote": Self.variantSummary(remote, related: related["remote"] ?? [])]]
            }
            return ["id": row["id"]!, "recordID": row["record_id"]!, "label": label, "reason": row["reason"]!, "local": local ?? NSNull() as Any, "remote": remote, "assets": try JSONSerialization.jsonObject(with: Data((row["assets_json"] as? String ?? "[]").utf8)), "related": related, "createdAt": row["created_at"]!]
        }
    }
    static func variantSummary(_ record: [String: Any]?, related: [[String: Any]]) -> [String: Any] {
        guard let record else { return ["exists": false, "deleted": false] }
        let p = record["payload"] as? [String: Any] ?? [:]
        var result: [String: Any] = ["exists": true, "deleted": record["deleted"] as? Bool == true]
        if let title = (p["title"] ?? p["name"] ?? p["fileName"]) as? String { result["title"] = String(title.prefix(160)) }
        if let revision = (p["revision"] ?? p["documentRevision"]) as? String { result["revision"] = String(revision.prefix(128)) }
        if let page = p["page"] as? NSNumber, page.intValue > 0 { result["page"] = page.intValue }
        let parser = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> (String, Date)? { guard let text = value as? String, let date = parser.date(from: text) ?? fractional.date(from: text) else { return nil }; return (text, date) }
        var dates = [p["updatedAt"], p["modifiedAt"], p["createdAt"]].compactMap(date)
        var snippets: [String] = []
        if let markdown = p["markdown"] as? String { snippets.append(markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)) }
        var objects = 0, hasPages = false
        for pageRecord in [record] + related where pageRecord["kind"] as? String == "drawing" {
            guard let page = try? NativeSyncFormat.decodePage(pageRecord) else { continue }
            hasPages = true
            let deletedObjects = Set(page["deletedObjectIDs"] as? [String] ?? []), deletedHighlights = Set(page["deletedHighlightIDs"] as? [String] ?? [])
            let values = (page["objects"] as? [[String: Any]] ?? []).filter { !deletedObjects.contains($0["id"] as? String ?? "") } + (page["highlights"] as? [[String: Any]] ?? []).filter { !deletedHighlights.contains($0["id"] as? String ?? "") }
            objects += values.count
            for object in values {
                if let updated = date(object["updatedAt"] ?? object["createdAt"]) { dates.append(updated) }
                let text = ((object["data"] as? [String: Any])?["text"] ?? object["comment"] ?? object["quote"]) as? String
                if let text, snippets.joined(separator: "\n").count < 500 { snippets.append(text) }
            }
        }
        if hasPages { result["objects"] = objects }
        if let latest = dates.max(by: { $0.1 < $1.1 }) { result["updatedAt"] = latest.0 }
        let excerpt = String(snippets.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if !excerpt.isEmpty { result["text"] = excerpt }
        return result
    }
    private func mergeInk(base: [String: Any], local: [String: Any], remote: [String: Any]) throws -> [String: Any]? {
        if [base, local, remote].contains(where: { $0["deleted"] as? Bool == true }) { return nil }
        let a = try F.decodePage(base), b = try F.decodePage(local), c = try F.decodePage(remote)
        guard try F.canonical(a["geometry"] ?? NSNull()) == F.canonical(b["geometry"] ?? NSNull()), try F.canonical(a["geometry"] ?? NSNull()) == F.canonical(c["geometry"] ?? NSNull()), a["documentRevision"] as? String == b["documentRevision"] as? String, a["documentRevision"] as? String == c["documentRevision"] as? String else { return nil }
        var result = c; result.removeValue(forKey: "nativeCache")
        for (collection, tombstones) in [("objects", "deletedObjectIDs"), ("highlights", "deletedHighlightIDs")] {
            func keyed(_ page: [String: Any]) throws -> [String: [String: Any]] { var values: [String: [String: Any]] = [:]; for item in page[collection] as? [[String: Any]] ?? [] { guard let id = item["id"] as? String, values[id] == nil else { throw C.validation("Duplicate ink identity") }; values[id] = item }; return values }
            let original = try keyed(a), left = try keyed(b), right = try keyed(c)
            let removed = Set((a[tombstones] as? [String] ?? []) + (b[tombstones] as? [String] ?? []) + (c[tombstones] as? [String] ?? []))
            var merged: [[String: Any]] = []
            func equal(_ lhs: [String: Any]?, _ rhs: [String: Any]?) throws -> Bool { try F.canonical(lhs ?? NSNull() as Any) == F.canonical(rhs ?? NSNull() as Any) }
            for id in Set(left.keys).union(right.keys).sorted() {
                let before = original[id], l = left[id], r = right[id]
                if removed.contains(id) { if before != nil, try (l != nil && !equal(l, before)) || (r != nil && !equal(r, before)) { return nil }; continue }
                if l != nil && r != nil, try !equal(l, r) && !equal(l, before) && !equal(r, before) { return nil }
                if let value = try !equal(l, before) ? l ?? r : r ?? l { merged.append(value) }
            }
            result[collection] = merged; result[tombstones] = removed.sorted()
        }
        var merged = remote; merged["payload"] = try F.encodePage(result); try F.validate(merged); return merged
    }
}
