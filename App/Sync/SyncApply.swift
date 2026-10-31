import Foundation

/// Merged root → local database and course folders (spec "머지", design §2 and §3). Only
/// registers that a remote write moved past what was last exchanged are applied, and never
/// over a local change that has not gone out yet: that one is sent next with a later t and
/// wins. Whatever cannot be applied yet (a waiting item, a busy file) is retried next time.
final class SyncApply {
    private typealias C = NativeRepositoryContext
    private typealias Entity = SyncMerge.Entity

    /// Items left for the next round, with the reason (an id and an error).
    struct Report { var skipped: [(id: String, reason: String)] = [] }

    let store: SyncStore
    private let library: NativeLibraryRepository
    private var context: NativeRepositoryContext { store.context }
    /// Bytes of a root file (`pdf/…`, `notes/…`, `assets/…`).
    private let read: (String) throws -> Data

    init(store: SyncStore, library: NativeLibraryRepository, read: @escaping (String) throws -> Data) {
        self.store = store
        self.library = library
        self.read = read
    }

    @discardableResult func apply(_ state: SyncMerge.State) throws -> Report {
        var report = Report()
        guard state.blocked == nil else { return report }
        try observeClock(state)
        func each<T>(_ items: [(String, T)], _ body: (String, T) throws -> Void) {
            for (id, item) in items {
                do { try body(id, item) } catch { report.skipped.append((id, "\(error)")) }
            }
        }
        each(state.courses.sorted { $0.key < $1.key }, course)
        let waiting = Set(state.waitingDocs), renames = Dictionary(state.renames.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        each(state.docs.filter { !waiting.contains($0.key) }.sorted { $0.key < $1.key }) { try document($0, $1, renamed: renames[$0], note: state.notes[$0]?.file) }
        each(state.conflictCopies.map { ($0.id, $0) }, copy)
        let held = Set(state.waitingInk)
        each(state.ink.filter { !held.contains($0.key) }.sorted { $0.key < $1.key }) { try drawing($0, doc: $1.doc, object: $1.object, stamp: $1.stamp) }
        return report
    }

    /// Every t in the root is at most the t of some winning register, so the winners move the clock past all of them.
    private func observeClock(_ state: SyncMerge.State) throws {
        var latest: Int64 = 0
        for entity in Array(state.courses.values) + Array(state.docs.values) {
            latest = max(latest, entity.fields.values.map(\.stamp.t).max() ?? 0, entity.deleted?.stamp.t ?? 0)
        }
        latest = max(latest, state.ink.values.map(\.stamp.t).max() ?? 0)
        try store.observe(latest)
    }

    /// The registers last exchanged, with every register `merged` wrote later laid over them.
    private static func newer(_ merged: Entity, than known: Entity) -> (registers: Entity, changed: Bool) {
        var registers = known, changed = false
        for (key, register) in merged.fields where known.fields[key].map({ register.stamp > $0.stamp }) ?? true {
            registers.fields[key] = register; changed = true
        }
        if let value = merged.deleted, known.deleted.map({ value.stamp > $0.stamp }) ?? true { registers.deleted = value; changed = true }
        return (registers, changed)
    }

    // MARK: Courses

    private func course(_ id: String, _ entity: Entity) throws {
        let row = try context.query("SELECT local_id,registers FROM cloud_sync_courses WHERE sync_id=?", [id]).first
        let known = try row.map { try SyncStore.decode($0["registers"] as! String) } ?? Entity()
        let (target, changed) = Self.newer(entity, than: known)
        guard changed else { return }
        guard let local = row?["local_id"] as? String else {
            guard target.isAlive else { return }
            let name = target.text("name").flatMap { $0.isEmpty ? nil : $0 } ?? "과목"
            let created = try library.handle("courses:create", ["name": name, "color": SyncAdapter.localCourseColor(target.text("color") ?? "blue")])
            guard let made = (created as? [String: Any])?["id"] as? String else { return }
            try context.run("INSERT INTO cloud_sync_courses(sync_id,local_id,origin,registers) VALUES(?,?,'remote',?)", [id, made, SyncStore.encode(target)])
            try bring(made, to: target, known: Entity())
            return
        }
        guard let current = try context.query("SELECT name,color,archived,sort_order,deleted_at FROM courses WHERE id=?", [local]).first,
              Self.matches(current, known) else { return }  // An unsent local change goes out next and wins.
        let alive = current["deleted_at"] is NSNull
        if !target.isAlive, alive { _ = try library.handle("courses:delete", ["courseId": local]) }
        if target.isAlive, !alive { _ = try library.handle("courses:restore", ["courseId": local]) }
        if target.isAlive { try bring(local, to: target, known: known) }
        try context.run("UPDATE cloud_sync_courses SET registers=? WHERE sync_id=?", [SyncStore.encode(target), id])
    }

    /// The local row still holds the values last exchanged. A course never exchanged is this
    /// iPad's own, sent but not committed: whatever the root holds of it is not newer.
    private static func matches(_ row: [String: Any], _ known: Entity) -> Bool {
        guard known.deleted != nil else { return false }
        let local: [String: Any] = ["name": row["name"] as? String ?? "", "sort": row["sort_order"] ?? 0,
                                    "color": SyncAdapter.specCourseColor(row["color"] as? String ?? ""), "archived": (row["archived"] as? NSNumber)?.boolValue ?? false]
        return known.isAlive == (row["deleted_at"] is NSNull) && local.allSatisfy { key, value in known.fields[key].map { SyncStore.same($0.value, value) } ?? true }
    }

    private func bring(_ local: String, to target: Entity, known: Entity) throws {
        func changed(_ key: String) -> Any? { target.fields[key].flatMap { SyncStore.same($0.value, known.fields[key]?.value) ? nil : $0.value } }
        if let name = changed("name") as? String, !name.isEmpty { _ = try library.handle("courses:rename", ["courseId": local, "name": name]) }
        if let color = changed("color") as? String, !color.isEmpty { _ = try library.handle("courses:setColor", ["courseId": local, "color": SyncAdapter.localCourseColor(color)]) }
        if let archived = changed("archived") as? Bool { _ = try library.handle("courses:archive", ["courseId": local, "archived": archived]) }
        if let sort = changed("sort") as? NSNumber { try context.run("UPDATE courses SET sort_order=?,updated_at=? WHERE id=?", [sort.intValue, C.nowISO, local]) }
    }

    // MARK: Documents

    private func document(_ id: String, _ entity: Entity, renamed: String?, note: String?) throws {
        let row = try context.query("SELECT course_id,rel_path,registers FROM cloud_sync_docs WHERE sync_id=?", [id]).first
        let known = try row.map { try SyncStore.decode($0["registers"] as! String) } ?? Entity()
        let (target, changed) = Self.newer(entity, than: known)
        guard let course = try target.text("course_id").flatMap(localCourse), let name = renamed ?? target.text("name"), let folder = target.text("rel_path") else { return }
        let rel = folder.isEmpty ? name : folder + "/" + name
        guard let row, let path = row["rel_path"] as? String, !path.isEmpty else {
            // Not on this iPad yet.
            guard target.isAlive, changed, try place(target, id: id, note: note, course: course, rel: rel) else { return }
            try context.run("""
            INSERT INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES(?,?,?,'remote',?)
            ON CONFLICT(sync_id) DO UPDATE SET course_id=excluded.course_id,rel_path=excluded.rel_path,registers=excluded.registers
            """, [id, course, rel, SyncStore.encode(target)])
            return
        }
        let local = row["course_id"] as! String
        guard changed || rel != path, try unchanged(known, course: local, path: path) else { return }  // An unsent local change goes out next and wins.
        guard target.isAlive else {
            _ = try library.handle("materials:delete", ["courseId": local, "relPath": path])
            try context.run("UPDATE cloud_sync_docs SET registers=?,rel_path='' WHERE sync_id=?", [SyncStore.encode(target), id])
            return
        }
        // Moving between courses is not applied in v1; such a document stays where it is.
        var now = path
        if rel != path, course == local, try move(course: local, from: path, to: rel) { now = rel }
        try replaceContent(target, known: known, id: id, note: note, course: local, rel: now)
        try context.run("UPDATE cloud_sync_docs SET registers=?,rel_path=? WHERE sync_id=?", [SyncStore.encode(target), now, id])
    }

    private func localCourse(_ id: String) throws -> String? {
        guard let local = try context.query("SELECT local_id FROM cloud_sync_courses WHERE sync_id=?", [id]).first?["local_id"] as? String,
              try !context.query("SELECT 1 FROM courses WHERE id=? AND deleted_at IS NULL", [local]).isEmpty else { return nil }
        return local
    }

    /// The local file is where it was last exchanged and holds the same content.
    private func unchanged(_ known: Entity, course: String, path: String) throws -> Bool {
        guard let name = known.text("name"), let folder = known.text("rel_path"), path == (folder.isEmpty ? name : folder + "/" + name),
              let url = try? context.materialURL(courseID: course, relativePath: path) else { return false }
        if let sha = known.text("pdf_sha256") { return try context.contentHash(url) == sha }
        if let hash = known.text("md_hash") { return SyncFormat.sha256(SyncOutbox.normalized(try Data(contentsOf: url), course: course, context: context).data) == hash }
        return true
    }

    /// Writes a document that is new on this iPad; false when it cannot be placed yet.
    private func place(_ target: Entity, id: String, note: String?, course: String, rel: String) throws -> Bool {
        let url = try context.materialURL(courseID: course, relativePath: rel, allowMissing: true)
        guard !context.files.fileExists(atPath: url.path) else { return false }
        if target.text("type") == "pdf", let sha = target.text("pdf_sha256") {
            let bytes = try read("pdf/\(sha).pdf")
            guard SyncFormat.sha256(bytes) == sha else { return false }
            // What a removed file left at this path moves aside; what this document left when it was removed comes back.
            let leftover = try context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [course, rel]).first?["material_id"] as? String
            if leftover != id { try repoint(course: course, from: rel, to: Self.removed(leftover ?? UUID().uuidString.lowercased())) }
            try repoint(course: course, from: Self.removed(id), to: rel)
            try write(bytes, to: url, rel: rel)
            // Bound first, so the PDF repository takes the file as this document (design §2.6).
            // A document coming back keeps the binding its ink has unless the rule lets it follow.
            try context.run("INSERT OR IGNORE INTO pdf_document_bindings(material_id,bound_sha,evidence,legacy_unverified,created_at) VALUES(?,?,'sync',0,?)", [id, sha, C.nowISO])
            try follow(id, to: sha, target: target, course: course, rel: rel)
            try context.run("INSERT OR IGNORE INTO pdf_document_aliases(course_id,rel_path,material_id) VALUES(?,?,?)", [course, rel, id])
            return true
        }
        guard let note else { return false }
        try write(try noteText(note, course: course), to: url, rel: rel)
        return true
    }

    private func replaceContent(_ target: Entity, known: Entity, id: String, note: String?, course: String, rel: String) throws {
        let url = try context.materialURL(courseID: course, relativePath: rel)
        if let sha = target.text("pdf_sha256"), sha != known.text("pdf_sha256") {
            let bytes = try read("pdf/\(sha).pdf")
            guard SyncFormat.sha256(bytes) == sha else { throw C.validation("pdf/\(sha).pdf does not match its hash") }
            let material = try boundMaterial(course: course, rel: rel)
            try preserve(url)
            try context.withMaterialLock { try context.atomicWrite(bytes, to: url) }
            if let material { try follow(material, to: sha, target: target, course: course, rel: rel) }
            // As after a page change (NativePDFPageRepository.invalidate).
            try context.run("UPDATE materials_index SET size=?,mtime=?,updated_at=? WHERE course_id=? AND rel_path=?", [bytes.count, Date().timeIntervalSince1970 * 1000, C.nowISO, course, rel])
            for table in ["native_search_documents", "native_search_files"] where try context.tableExists(table) {
                try context.run("DELETE FROM \(table) WHERE course_id=? AND rel_path=?", [course, rel])
            }
        }
        if let hash = target.text("md_hash"), hash != known.text("md_hash"), let note {
            let text = try noteText(note, course: course)
            try context.withMaterialLock { try context.atomicWrite(text, to: url) }
        }
    }

    /// The PDF identity at a path, found by path because a PDF made here is bound under its local
    /// id. One never opened here that already holds ink from another device is bound now, as
    /// opening it would, so that ink is protected like any other.
    private func boundMaterial(course: String, rel: String) throws -> String? {
        func alias() throws -> String? {
            try context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [course, rel]).first?["material_id"] as? String
        }
        if let material = try alias() { return material }
        guard try hasInk(course: course, rel: rel) else { return nil }
        do { _ = try NativePDFRepository(context: context).checkBinding(["courseId": course, "relPath": rel]) }
        catch { guard try alias() != nil else { throw error } }  // A mismatch is reported after the binding is kept.
        return try alias()
    }

    /// Spec v2.3: a binding moves to new bytes only when their writer says they continue the PDF
    /// bound here (`pdf_prev_sha256`, written with that `pdf_sha256`) or when no ink here could be
    /// shown on the wrong PDF. Otherwise it stays, and the PDF repository keeps the ink off the new bytes.
    private func follow(_ material: String, to sha: String, target: Entity, course: String, rel: String) throws {
        guard let bound = try context.query("SELECT bound_sha FROM pdf_document_bindings WHERE material_id=?", [material]).first?["bound_sha"] as? String,
              bound != sha else { return }
        let previous = target.fields["pdf_prev_sha256"]
        let continued = previous?.stamp == target.fields["pdf_sha256"]?.stamp && previous?.value as? String == bound
        guard try continued || !hasInk(course: course, rel: rel) else { return }
        try context.run("UPDATE pdf_document_bindings SET bound_sha=?,evidence='sync',legacy_unverified=0 WHERE material_id=?", [sha, material])
    }

    private func hasInk(course: String, rel: String) throws -> Bool {
        try !context.query("SELECT 1 FROM pdf_drawings WHERE course_id=? AND rel_path=? UNION ALL SELECT 1 FROM annotations WHERE course_id=? AND rel_path=? LIMIT 1",
                           [course, rel, course, rel]).isEmpty
    }

    /// The bytes a synced PDF replaces stay in PDFOriginals, like the bytes before any page change.
    private func preserve(_ url: URL) throws {
        let sha = try context.contentHash(url), folder = context.root.appendingPathComponent("PDFOriginals", isDirectory: true)
        let target = folder.appendingPathComponent(sha + ".pdf")
        guard !context.files.fileExists(atPath: target.path) else { return }
        try context.files.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.atomicWrite(try Data(contentsOf: url), to: target)
    }

    private func move(course: String, from: String, to: String) throws -> Bool {
        let parent = (to as NSString).deletingLastPathComponent, name = (to as NSString).lastPathComponent
        var now = from
        if parent != (from as NSString).deletingLastPathComponent {
            try folder(try context.resolve(in: context.courseFolder(course), relativePath: parent, allowRoot: true))
            guard let moved = try library.handle("materials:move", ["courseId": course, "fromRelPath": from, "toDirRelPath": parent]) as? [String: Any],
                  let path = moved["relPath"] as? String else { return false }
            now = path
        }
        if (now as NSString).lastPathComponent != name { _ = try library.handle("materials:rename", ["courseId": course, "relPath": now, "newName": name]) }
        return true
    }

    /// Where the ink, highlights and PDF identity of a removed file wait: a path no file uses.
    static func removed(_ id: String) -> String { ".bandal-sync/removed/\(id)" }

    private func repoint(course: String, from: String, to: String) throws {
        for table in ["pdf_drawings", "annotations", "pdf_document_aliases"] where try context.tableExists(table) {
            try context.run("UPDATE OR REPLACE \(table) SET rel_path=? WHERE course_id=? AND rel_path=?", [to, course, from])
        }
    }

    /// A folder that already exists under another letter case (a case-insensitive volume) is used as is.
    private func folder(_ url: URL) throws {
        if !context.files.fileExists(atPath: url.path) { try context.files.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    private func write(_ bytes: Data, to url: URL, rel: String) throws {
        try context.withMaterialLock {
            try folder(url.deletingLastPathComponent())
            try context.atomicWrite(bytes, to: url) { if self.context.files.fileExists(atPath: url.path) { throw C.conflict("\(rel) appeared while syncing") } }
        }
    }

    /// A note file from the root with its attachment links made local again
    /// (`../../assets/<sha>.<ext>` → `assets/<sha>.<ext>`) and those files placed.
    private func noteText(_ path: String, course: String) throws -> Data {
        let bytes = try read(path), text = String(decoding: bytes, as: UTF8.self)
        guard text.contains("](../../assets/"), Data(text.utf8) == bytes else { return bytes }
        // Only spec links whose file is now here change; any other text stays as written.
        var result = "", last = text.startIndex
        for match in Self.remoteAttachment.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let range = Range(match.range(at: 1), in: text),
                  try asset(String(text[range]), course: course) != nil else { continue }
            result += text[last..<whole.lowerBound] + "](" + text[range] + ")"
            last = whole.upperBound
        }
        return Data((result + text[last...]).utf8)
    }
    private static let remoteAttachment = try! NSRegularExpression(pattern: #"\]\(\.\./\.\./(assets/[0-9a-f]{64}\.[a-z0-9]{1,16})\)"#)

    /// `assets/<sha>.<ext>` from the root, kept in the course's `assets/` folder under that name.
    private func asset(_ path: String, course: String) throws -> String? {
        let url = try context.materialURL(courseID: course, relativePath: path, allowMissing: true)
        if context.files.fileExists(atPath: url.path) { return path }
        guard let bytes = try? read(path), SyncFormat.sha256(bytes) == String((path as NSString).lastPathComponent.prefix(64)) else { return nil }
        try write(bytes, to: url, rel: path)
        return path
    }

    /// A conflict copy is written as a note of this iPad. Its registers hold the derived values
    /// with t 0 and no delete register: every device derives the same copy, so it is sent only
    /// once someone edits or removes it, and a remote write of it always wins over the derivation.
    /// While derived, its name follows the merge (a device file arriving late renames it).
    private func copy(_ id: String, _ copy: SyncMerge.ConflictCopy) throws {
        guard let course = try localCourse(copy.courseID) else { return }
        let rel = copy.relPath.isEmpty ? copy.name : copy.relPath + "/" + copy.name
        var derived = Entity()
        for (key, value) in ["course_id": copy.courseID, "type": "md", "name": copy.name, "rel_path": copy.relPath, "md_hash": copy.mdHash] {
            derived.fields[key] = SyncMerge.Register(value: value, stamp: SyncMerge.Stamp(t: 0, device: "", seq: 0, index: 0))
        }
        if let row = try context.query("SELECT course_id,rel_path,registers FROM cloud_sync_docs WHERE sync_id=?", [id]).first {
            let known = try SyncStore.decode(row["registers"] as! String), path = row["rel_path"] as? String ?? ""
            guard known.deleted == nil, !path.isEmpty, path != rel, row["course_id"] as? String == course,
                  try unchanged(known, course: course, path: path), try move(course: course, from: path, to: rel) else { return }
            try context.run("UPDATE cloud_sync_docs SET rel_path=?,registers=? WHERE sync_id=?", [rel, SyncStore.encode(derived), id])
            return
        }
        let url = try context.materialURL(courseID: course, relativePath: rel, allowMissing: true)
        guard !context.files.fileExists(atPath: url.path) else { return }
        try write(try noteText(copy.file, course: course), to: url, rel: rel)
        try context.run("INSERT INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES(?,?,?,'remote',?)", [id, course, rel, SyncStore.encode(derived)])
    }

    // MARK: Drawings

    private func drawing(_ id: String, doc: String, object: SyncFormat.InkObject, stamp: SyncMerge.Stamp) throws {
        let stored = try context.query("SELECT page,t,dev,seq,idx,hash FROM cloud_sync_objects WHERE id=?", [id]).first
        if let stored {
            let last = SyncMerge.Stamp(t: (stored["t"] as? NSNumber)?.int64Value ?? 0, device: stored["dev"] as? String ?? "",
                                       seq: (stored["seq"] as? NSNumber)?.intValue ?? 0, index: (stored["idx"] as? NSNumber)?.intValue ?? 0)
            guard stamp > last else { return }
        }
        guard let place = try context.query("SELECT course_id,rel_path FROM cloud_sync_docs WHERE sync_id=? AND rel_path<>''", [doc]).first,
              let course = place["course_id"] as? String, let path = place["rel_path"] as? String else { return }
        // An unsent local edit of this drawing goes out next and wins; so does removing it outright.
        if let current = try context.query("SELECT * FROM pdf_drawings WHERE id=?", [id]).first {
            let form = (try? SyncOutbox.form(current, context: context)) ?? nil
            guard try form.map({ try SyncOutbox.hash($0.value) }) == stored?["hash"] as? String else { return }
        } else if let stored, stored["hash"] as? String != (try SyncOutbox.hash(["id": id, "page": stored["page"] ?? 0, "del": true])) {
            return
        }
        switch try SyncAdapter.importInkObject(object, imagePath: { try? self.asset("assets/\($0.sha256).\($0.ext)", course: course) }) {
        case let .upsert(kind, page, data, style, createdAt, updatedAt):
            try context.run("""
            INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id,rel_path=excluded.rel_path,page=excluded.page,kind=excluded.kind,
              data_json=excluded.data_json,style_json=excluded.style_json,created_at=excluded.created_at,updated_at=excluded.updated_at,deleted_at=NULL
            """, [id, course, path, page, kind, try NativePDFRepositoryValidation.json(data), try NativePDFRepositoryValidation.json(style), createdAt, updatedAt])
        case .delete(let deletedAt):
            try context.run("UPDATE pdf_drawings SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL", [deletedAt, deletedAt, id])
        case .hold:
            return
        }
        // Record what is stored now (clamped values included), so this write is not sent back.
        let saved = try context.query("SELECT * FROM pdf_drawings WHERE id=?", [id]).first
        let form = try saved.flatMap { try SyncOutbox.form($0, context: context) }?.value ?? ["id": id, "page": object.page, "del": true]
        try context.run("INSERT OR REPLACE INTO cloud_sync_objects(id,doc,page,t,dev,seq,idx,hash) VALUES(?,?,?,?,?,?,?,?)",
                        [id, doc, object.page, stamp.t, stamp.device, stamp.seq, stamp.index, try SyncOutbox.hash(form)])
    }
}
