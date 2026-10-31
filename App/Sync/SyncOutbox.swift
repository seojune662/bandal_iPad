import Foundation

/// Local changes → spec files (spec "동기화 루프" 1, design §1.6 and §1.8). `prepare` compares
/// courses, course folders and drawings with what was last exchanged and returns the files
/// to write; `commit` records them once the provider has written every one. Before that
/// only the clock, the seq counter and new ids are stored, and each may be wasted safely.
final class SyncOutbox {
    private typealias C = NativeRepositoryContext
    private typealias Stamp = SyncMerge.Stamp

    enum Content { case data(Data), file(URL) }
    struct Write { let path: String; let content: Content }

    struct Batch {
        fileprivate(set) var writes: [Write] = []
        fileprivate var courses: [String: SyncMerge.Entity] = [:], docs: [String: SyncMerge.Entity] = [:]
        fileprivate var objects: [String: (doc: String, page: Int, stamp: SyncMerge.Stamp, hash: String)] = [:]
        /// Dirty marks seen: a drawing written again after `prepare` keeps its newer mark.
        fileprivate var handled: [(id: String, mark: Int64)] = []
        fileprivate var files: [(path: String, key: String, content: String?)] = []
        fileprivate var deviceName: String?
        /// Files left for the next round (being written, unreadable), with the reason.
        fileprivate(set) var skipped: [(path: String, reason: String)] = []
    }

    let store: SyncStore
    private let library: NativeLibraryRepository
    private var context: NativeRepositoryContext { store.context }
    var now: () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    var deviceName = "iPad"
    /// A session file is replaced by a new one once its gzip passes this size (spec: 1 MB).
    var maxFile = 1 << 20

    init(store: SyncStore, library: NativeLibraryRepository) {
        self.store = store
        self.library = library
    }

    /// `remote` lists every path in the root now; files already there are not uploaded again.
    /// Call it only for an empty root or one whose merge is not blocked: nothing may be written
    /// into a root of another format (spec "원격 입력 검증", format).
    func prepare(remote: Set<String>) throws -> Batch {
        let me = try store.deviceID()
        var draft = Draft(me: me, remote: remote, ownMax: remote.compactMap(SyncFormat.writer).filter { $0.device == me }.map(\.seq).max() ?? 0)
        try courses(&draft)
        try documents(&draft)
        try drawings(&draft)
        // Order of a flush (design §1.5): pdf and assets went in first, then ink and notes, then the log.
        try assemble(&draft)
        let named = try store.value("device_name")
        if !remote.contains("devices/\(me).json") || named != deviceName {
            draft.batch.writes.append(Write(path: "devices/\(me).json", content: .data(try Self.json(["name": deviceName]))))
            draft.batch.deviceName = deviceName
        }
        if !remote.contains("bandal.json") { draft.batch.writes.append(Write(path: "bandal.json", content: .data(try Self.json(["format": SyncFormat.version])))) }
        return draft.batch
    }

    /// Run `prepare`, the writes and `commit` with no `SyncApply` in between: the registers
    /// stored here are the ones computed in `prepare`.
    func commit(_ batch: Batch) throws {
        try context.transaction {
            for (id, registers) in batch.courses { try context.run("UPDATE cloud_sync_courses SET registers=? WHERE sync_id=?", [SyncStore.encode(registers), id]) }
            for (id, registers) in batch.docs {
                // A deleted document no longer holds its path: a new file there is a new document.
                try context.run("UPDATE cloud_sync_docs SET registers=?,rel_path=CASE WHEN ? THEN '' ELSE rel_path END WHERE sync_id=?",
                                [SyncStore.encode(registers), !registers.isAlive, id])
            }
            for (id, object) in batch.objects {
                try context.run("INSERT OR REPLACE INTO cloud_sync_objects(id,doc,page,t,dev,seq,idx,hash) VALUES(?,?,?,?,?,?,?,?)",
                                [id, object.doc, object.page, object.stamp.t, object.stamp.device, object.stamp.seq, object.stamp.index, object.hash])
            }
            for item in batch.handled { try context.run("DELETE FROM cloud_sync_dirty WHERE id=? AND mark=?", [item.id, item.mark]) }
            for file in batch.files {
                try context.run("UPDATE cloud_sync_files SET open=0,content=NULL WHERE key=? AND path<>?", [file.key, file.path])
                try context.run("INSERT OR REPLACE INTO cloud_sync_files(path,key,open,content) VALUES(?,?,1,?)", [file.path, file.key, file.content ?? NSNull()])
            }
            if let name = batch.deviceName { try store.set("device_name", name) }
        }
    }

    /// A new session (the app back in the foreground) starts new files; older ones are never rewritten.
    func endSession() throws { try context.run("UPDATE cloud_sync_files SET open=0,content=NULL") }

    // MARK: Changes

    private struct Event { let op: String; let id: String; let fields: [String: Any]?; let registers: SyncMerge.Entity }
    private struct Object { let id: String; let value: [String: Any]; let hash: String; let doc: String; let page: Int }

    private struct Draft {
        let me: String, remote: Set<String>, ownMax: Int
        var batch = Batch(), events: [Event] = [], ink: [String: [Object]] = [:], notes: [String: Data] = [:]
        mutating func upload(_ path: String, _ url: URL) {
            guard !remote.contains(path), !batch.writes.contains(where: { $0.path == path }) else { return }
            batch.writes.append(Write(path: path, content: .file(url)))
        }
    }

    /// Fields that differ from the registers go out in one upsert: only those for an entity
    /// already exchanged alive, all of them otherwise. A conflict copy this iPad derived holds
    /// its derived values without a delete register, so it is sent only once someone changes
    /// or removes it (spec: until then it is a derived document). An entity that disappears
    /// goes out as a delete unless it never went out at all.
    private static func event(_ op: String, _ id: String, _ registers: SyncMerge.Entity, _ fields: [String: Any], alive: Bool) -> Event? {
        guard alive else {
            let known = registers.deleted != nil || !registers.fields.isEmpty
            return registers.isAlive && known ? Event(op: op + ".delete", id: id, fields: nil, registers: registers) : nil
        }
        let changed = fields.filter { !SyncStore.same(registers.fields[$0.key]?.value, $0.value) }
        guard !changed.isEmpty || registers.deleted?.value == true else { return nil }
        return Event(op: op + ".upsert", id: id, fields: registers.deleted?.value == false ? changed : fields, registers: registers)
    }

    private func courses(_ draft: inout Draft) throws {
        var known: [String: (id: String, registers: String)] = [:]
        for row in try context.query("SELECT sync_id,local_id,registers FROM cloud_sync_courses") { known[row["local_id"] as! String] = (row["sync_id"] as! String, row["registers"] as! String) }
        // Linked folders stay on this iPad in v1 (user decision 2026-10-30).
        for row in try context.query("SELECT id,name,color,archived,sort_order,deleted_at FROM courses WHERE source='managed' ORDER BY sort_order,id") {
            let local = row["id"] as! String, alive = row["deleted_at"] is NSNull
            if known[local] == nil {
                guard alive else { continue }
                // Spec ids are lowercase UUIDs; an older id of another shape gets one once.
                let id = local == local.lowercased() && UUID(uuidString: local) != nil ? local : UUID().uuidString.lowercased()
                let empty = try SyncStore.encode(.init())
                try context.run("INSERT INTO cloud_sync_courses(sync_id,local_id,origin,registers) VALUES(?,?,'local',?)", [id, local, empty])
                known[local] = (id, empty)
            }
            let fields: [String: Any] = ["name": row["name"] as? String ?? "", "sort": row["sort_order"] ?? 0,
                                         "color": SyncAdapter.specCourseColor(row["color"] as? String ?? ""), "archived": (row["archived"] as? NSNumber)?.boolValue ?? false]
            if let event = Self.event("course", known[local]!.id, try SyncStore.decode(known[local]!.registers), fields, alive: alive) { draft.events.append(event) }
        }
    }

    private func documents(_ draft: inout Draft) throws {
        let courses = try context.query("SELECT s.sync_id,s.local_id FROM cloud_sync_courses s JOIN courses c ON c.id=s.local_id WHERE c.deleted_at IS NULL AND c.source='managed'")
        for course in courses {
            let local = course["local_id"] as! String
            // A course folder that cannot be read sends nothing, and above all no deletes.
            guard (try? library.handle("materials:tree", ["courseId": local])) != nil else { continue }
            var known: [String: (path: String, registers: SyncMerge.Entity)] = [:]
            for row in try context.query("SELECT sync_id,rel_path,registers FROM cloud_sync_docs WHERE course_id=?", [local]) {
                known[row["sync_id"] as! String] = (row["rel_path"] as! String, try SyncStore.decode(row["registers"] as! String))
            }
            var byPath = Dictionary(known.map { ($0.value.path, $0.key) }, uniquingKeysWith: min)
            let materials = try context.query("SELECT rel_path,kind FROM materials_index WHERE course_id=? AND deleted_at IS NULL AND kind IN ('pdf','note') ORDER BY rel_path", [local])
            var gone = Set(known.keys).subtracting(materials.compactMap { byPath[$0["rel_path"] as! String] })
            for material in materials {
                let rel = material["rel_path"] as! String, pdf = material["kind"] as? String == "pdf"
                // A file that cannot be read now goes next time; it is not taken as removed.
                let url: URL, note: Data?, hash: String
                do {
                    url = try context.materialURL(courseID: local, relativePath: rel)
                    if pdf { note = nil; hash = try context.contentHash(url) } else {
                        let normalized = Self.normalized(try Data(contentsOf: url), course: local, context: context)
                        for asset in normalized.assets { draft.upload(asset.path, asset.url) }
                        note = normalized.data; hash = SyncFormat.sha256(normalized.data)
                    }
                } catch {
                    draft.batch.skipped.append((rel, "\(error)")); continue
                }
                let key = pdf ? "pdf_sha256" : "md_hash", id: String
                if let mapped = byPath[rel] { id = mapped }
                else if let moved = gone.filter({ known[$0]!.registers.deleted?.value == false && known[$0]!.registers.fields[key]?.value as? String == hash })
                    .min(by: { (known[$0]!.registers.fields["name"]?.value as? String == SyncAdapter.docLocation(rel).name ? 0 : 1, $0) < (known[$1]!.registers.fields["name"]?.value as? String == SyncAdapter.docLocation(rel).name ? 0 : 1, $1) }) {
                    // Moved outside the app: same content where a document's path disappeared keeps that id.
                    id = moved; gone.remove(moved)
                    try context.run("UPDATE cloud_sync_docs SET rel_path=? WHERE sync_id=?", [rel, id])
                } else {
                    id = try newDocument(course: local, rel: rel, pdf: pdf)
                    known[id] = (rel, .init())
                }
                byPath[rel] = id
                let (folder, name) = SyncAdapter.docLocation(rel), registers = known[id]!.registers
                // The iPad never moves a document to another course, so a remote move it has not
                // applied (v1 applies none) is not sent back as a move to the old course.
                let courseID = registers.fields["course_id"]?.value ?? course["sync_id"]!
                var fields: [String: Any] = ["course_id": courseID, "type": pdf ? "pdf" : "md", "name": name, "rel_path": folder, key: hash]
                if pdf { draft.upload("pdf/\(hash).pdf", url) }
                guard var event = Self.event("doc", id, registers, fields, alive: true) else { continue }
                if pdf, event.fields?["pdf_sha256"] != nil {
                    // Spec v2.3: always sent with pdf_sha256, so the two never come from different writes.
                    fields = event.fields!; fields["pdf_prev_sha256"] = try carried(from: registers.text("pdf_sha256"), to: hash, course: local, rel: rel) ?? NSNull()
                    event = Event(op: event.op, id: id, fields: fields, registers: registers)
                }
                if let note, event.fields?["md_hash"] != nil {
                    // A new version starts from the text last exchanged (null for the first).
                    fields = event.fields!; fields["md_base"] = registers.fields["md_hash"]?.value ?? NSNull()
                    event = Event(op: event.op, id: id, fields: fields, registers: registers)
                    draft.notes[id] = note
                }
                draft.events.append(event)
            }
            for id in gone.sorted() {
                // The scan skips some files (dot names, deep folders, other kinds); only a file really gone is removed.
                let path = known[id]!.path
                if !path.isEmpty, let url = try? context.materialURL(courseID: local, relativePath: path, allowMissing: true), context.files.fileExists(atPath: url.path) { continue }
                if let event = Self.event("doc", id, known[id]!.registers, [:], alive: false) { draft.events.append(event) }
            }
        }
    }

    /// The PDF last exchanged, when the ink here followed the change to `sha`: a page change in
    /// the app or a rebinding by sync moves the binding along. Bytes replaced outside the app
    /// leave it behind, so devices with ink on the old PDF keep that ink protected.
    private func carried(from previous: String?, to sha: String, course: String, rel: String) throws -> String? {
        guard let previous, previous != sha,
              let binding = try context.query("SELECT b.bound_sha,b.evidence FROM pdf_document_aliases a JOIN pdf_document_bindings b ON b.material_id=a.material_id WHERE a.course_id=? AND a.rel_path=?", [course, rel]).first,
              binding["bound_sha"] as? String == sha, ["page-history", "sync"].contains(binding["evidence"] as? String) else { return nil }
        return previous
    }

    /// A PDF keeps its binding id (as the desktop does); a note gets a new UUID.
    private func newDocument(course: String, rel: String, pdf: Bool) throws -> String {
        var id = UUID().uuidString.lowercased()
        if pdf, let bound = try context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [course, rel]).first?["material_id"] as? String,
           bound == bound.lowercased(), UUID(uuidString: bound) != nil, try context.query("SELECT 1 FROM cloud_sync_docs WHERE sync_id=?", [bound]).isEmpty { id = bound }
        try context.run("INSERT INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES(?,?,?,'local',?)", [id, course, rel, SyncStore.encode(.init())])
        return id
    }

    /// A note as the spec stores it (spec "첨부"): local links `](assets/<name>)` become
    /// `](../../assets/<sha256>.<ext>)`, and the files they name are returned for upload. Bytes
    /// that are not plain UTF-8, and links to missing files, stay as they are. md_hash is the
    /// SHA-256 of this form, so a note received and written back locally hashes the same.
    static func normalized(_ bytes: Data, course: String, context: NativeRepositoryContext) -> (data: Data, assets: [(path: String, url: URL)]) {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.contains("](assets/"), Data(text.utf8) == bytes else { return (bytes, []) }
        var result = "", last = text.startIndex, assets: [(path: String, url: URL)] = []
        for match in attachment.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let encoded = Range(match.range(at: 1), in: text) else { continue }
            let name = text[encoded].removingPercentEncoding ?? String(text[encoded])
            guard let url = try? context.materialURL(courseID: course, relativePath: "assets/" + name), let sha = try? context.contentHash(url) else { continue }
            let path = "assets/\(sha).\(SyncAdapter.assetExt(name))"
            result += text[last..<whole.lowerBound] + "](../../\(path))"
            last = whole.upperBound
            assets.append((path, url))
        }
        return (Data((result + text[last...]).utf8), assets)
    }
    private static let attachment = try! NSRegularExpression(pattern: #"\]\(assets/([^)\s]+)\)"#)

    private func drawings(_ draft: inout Draft) throws {
        for dirty in try context.query("SELECT id,mark FROM cloud_sync_dirty ORDER BY id") {
            let id = dirty["id"] as! String, mark = (dirty["mark"] as? NSNumber)?.int64Value ?? 0
            let stored = try context.query("SELECT doc,page,hash FROM cloud_sync_objects WHERE id=?", [id]).first
            var value: [String: Any]?, doc: String, page: Int
            if let row = try context.query("SELECT * FROM pdf_drawings WHERE id=?", [id]).first {
                // Ink in a course that is not synced (a linked folder), or set aside with a removed file, is not sent.
                guard !(row["rel_path"] as? String ?? "").hasPrefix(".bandal-sync/"),
                      try !context.query("SELECT 1 FROM cloud_sync_courses WHERE local_id=?", [row["course_id"]!]).isEmpty else { draft.batch.handled.append((id, mark)); continue }
                // Its document is synced first; until then the drawing stays dirty.
                guard let mapped = try context.query("SELECT sync_id FROM cloud_sync_docs WHERE course_id=? AND rel_path=?", [row["course_id"]!, row["rel_path"]!]).first?["sync_id"] as? String else { continue }
                doc = mapped; page = (row["page"] as? NSNumber)?.intValue ?? 0
                // A row that cannot be exported (board clip, unreadable) is not retried until it changes.
                let form = try? Self.form(row, context: context)
                if let asset = form?.asset { draft.upload(asset.path, asset.url) }
                value = form?.value
            } else if let stored {
                doc = stored["doc"] as! String; page = (stored["page"] as? NSNumber)?.intValue ?? 0
                value = ["id": id, "page": page, "del": true]
            } else { draft.batch.handled.append((id, mark)); continue }
            draft.batch.handled.append((id, mark))
            guard let value else { continue }
            let hash = try Self.hash(value)
            if stored?["hash"] as? String == hash { continue }
            draft.ink["ink/\(doc)/\(page)", default: []].append(Object(id: id, value: value, hash: hash, doc: doc, page: page))
        }
    }

    /// A `pdf_drawings` row in spec form without `t` (which `assemble` adds) and the image file it
    /// needs; nil for a row that is not exported, such as a board clip. Applying a remote drawing
    /// records the hash of this same form, so the write it causes is never sent back.
    static func form(_ row: [String: Any], context: NativeRepositoryContext) throws -> (value: [String: Any], asset: (path: String, url: URL)?)? {
        let course = row["course_id"] as! String, deleted = row["deleted_at"] as? String
        var image: SyncAdapter.AssetRef?, asset: (path: String, url: URL)?
        if row["kind"] as? String == "image", deleted == nil, let data = try C.jsonObject(row["data_json"] as? String ?? "{}") as? [String: Any],
           let rel = (data["image"] as? [String: Any])?["relPath"] as? String {
            let url = try context.materialURL(courseID: course, relativePath: rel)
            image = SyncAdapter.AssetRef(sha256: try context.contentHash(url), ext: SyncAdapter.assetExt(rel))
            asset = ("assets/\(image!.sha256).\(image!.ext)", url)
        }
        let local = SyncAdapter.DrawingRow(id: row["id"] as! String, kind: row["kind"] as? String ?? "", page: (row["page"] as? NSNumber)?.intValue ?? 0,
                                           dataJSON: row["data_json"] as? String ?? "{}", styleJSON: row["style_json"] as? String ?? "{}",
                                           createdAt: row["created_at"] as? String ?? "", updatedAt: row["updated_at"] as? String ?? "", deletedAt: deleted)
        return try SyncAdapter.inkObject(local, t: 0, image: image).map { ($0.filter { $0.key != "t" }, asset) }
    }

    static func hash(_ form: [String: Any]) throws -> String { SyncFormat.sha256(try json(form)) }

    // MARK: Files

    /// Stamps every change and writes this session's files: one per (document, page) for
    /// ink, one per document for notes and one for the log, each rewritten in place.
    private func assemble(_ draft: inout Draft) throws {
        let me = draft.me
        func name(_ seq: Int) -> String { String(format: "%08d", seq) }
        for (key, objects) in draft.ink.sorted(by: { $0.key < $1.key }) {
            let (doc, page) = (objects[0].doc, objects[0].page)
            var file = try session(key, &draft) { "ink/\(doc)/\(page)/\(me)-\(name($0)).json.gz" }
            var items = try file.content.map { try C.jsonObject($0) as? [[String: Any]] ?? [] } ?? []
            var stamps: [(Object, Int)] = []
            for object in objects {
                var value = object.value
                value["t"] = try store.stamp(now: now())
                // A newer version replaces the one this session already wrote, at the same position.
                let index = items.firstIndex { $0["id"] as? String == object.id } ?? items.count
                if index == items.count { items.append(value) } else { items[index] = value }
                stamps.append((object, index))
            }
            var bytes = try SyncFormat.gzip(try Self.json(items))
            if bytes.count > maxFile, items.count > objects.count {
                // Over 1 MB: this file is done and the changes start a new one.
                file = try session(key, &draft, new: true) { "ink/\(doc)/\(page)/\(me)-\(name($0)).json.gz" }
                items = stamps.map { var value = $0.0.value; value["t"] = items[$0.1]["t"]; return value }
                stamps = stamps.enumerated().map { ($0.element.0, $0.offset) }
                bytes = try SyncFormat.gzip(try Self.json(items))
            }
            for (object, index) in stamps {
                let t = (items[index]["t"] as? Int64) ?? 0
                draft.batch.objects[object.id] = (doc, page, Stamp(t: t, device: me, seq: file.seq, index: index), object.hash)
            }
            draft.batch.writes.append(Write(path: file.path, content: .data(bytes)))
            draft.batch.files.append((file.path, key, String(decoding: try Self.json(items), as: UTF8.self)))
        }
        for (doc, bytes) in draft.notes.sorted(by: { $0.key < $1.key }) {
            let file = try session("notes/\(doc)", &draft) { "notes/\(doc)/\(me)-\(name($0)).md" }
            draft.batch.writes.append(Write(path: file.path, content: .data(bytes)))
            draft.batch.files.append((file.path, "notes/\(doc)", nil))
        }
        guard !draft.events.isEmpty else { return }
        let file = try session("log", &draft) { "log/\(me)/\(name($0)).json" }
        var items = try file.content.map { try C.jsonObject($0) as? [[String: Any]] ?? [] } ?? []
        for event in draft.events {
            let stamp = Stamp(t: try store.stamp(now: now()), device: me, seq: file.seq, index: items.count)
            var item: [String: Any] = ["t": stamp.t, "op": event.op, "id": event.id]
            if let fields = event.fields { item["fields"] = fields }
            items.append(item)
            var registers = event.registers
            registers.deleted = (event.fields == nil, stamp)
            for (key, value) in event.fields ?? [:] { registers.fields[key] = SyncMerge.Register(value: value, stamp: stamp) }
            if event.op.hasPrefix("course.") { draft.batch.courses[event.id] = registers } else { draft.batch.docs[event.id] = registers }
        }
        let text = try Self.json(items)
        draft.batch.writes.append(Write(path: file.path, content: .data(text)))
        draft.batch.files.append((file.path, "log", String(decoding: text, as: UTF8.self)))
    }

    /// This session's open file for `key` with its content, or a new file under a new seq.
    private func session(_ key: String, _ draft: inout Draft, new: Bool = false, path: (Int) -> String) throws -> (path: String, seq: Int, content: String?) {
        if !new, let row = try context.query("SELECT path,content FROM cloud_sync_files WHERE key=? AND open=1", [key]).first,
           let path = row["path"] as? String, let seq = SyncFormat.writer(of: path)?.seq {
            return (path, seq, row["content"] as? String)
        }
        let seq = try store.nextSeq(pastRemote: draft.ownMax)
        return (path(seq), seq, nil)
    }

    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}
