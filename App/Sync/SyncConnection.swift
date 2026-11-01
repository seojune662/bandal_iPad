import Foundation

/// The first connection to a root that already holds data (design §4.2): what the root and this
/// iPad hold, and the mappings a merge or an overwrite starts from. Runs on the storage queue.
enum SyncConnection {
    private typealias C = NativeRepositoryContext

    enum Mode: String { case start, merge, overwrite }

    /// What only the cloud holds, sent as deletes by the first export after an overwrite.
    struct Pending: Codable {
        var deletes: [[String]] = []          // ["course" | "doc", id]
        var tombstones: [Tombstone] = []
        struct Tombstone: Codable { let id: String, doc: String, page: Int }
    }

    /// Counts for the connection sheet; the course pairs to join (`fixed` ones are this iPad's own
    /// courses from an earlier connection and are always joined); per pair how many cloud PDFs this
    /// iPad already has and how much cloud ink on them it lacks; and a fingerprint of the root, so an
    /// overwrite deletes only what the sheet showed.
    /// `forgetting`: another Apple ID, whose connection will forget what was matched with the old root.
    static func preview(_ state: SyncMerge.State, files: [String: SyncRemoteFile], forgetting: Bool, context: NativeRepositoryContext, library: NativeLibraryRepository) throws -> [String: Any] {
        try scan(context: context, library: library)
        let courses = state.courses.filter { $0.value.isAlive }
        let docs = state.docs.filter { $0.value.isAlive && courses[$0.value.text("course_id") ?? ""] != nil }
        let bytes = docs.values.compactMap { $0.text("pdf_sha256").flatMap { files["pdf/\($0).pdf"]?.size } }.reduce(0, +)
        let materials = try context.query("""
        SELECT COUNT(*) AS n, COALESCE(SUM(m.size),0) AS bytes FROM materials_index m JOIN courses c ON c.id=m.course_id
        WHERE c.deleted_at IS NULL AND c.source='managed' AND m.deleted_at IS NULL AND m.kind IN ('pdf','note')
        """).first
        let local = try context.query("SELECT id,name FROM courses WHERE deleted_at IS NULL AND source='managed' ORDER BY sort_order,id")
        let mapped = forgetting ? [] : try Set(context.query("SELECT sync_id FROM cloud_sync_courses").compactMap { $0["sync_id"] as? String })
        var pairs: [[String: Any]] = []
        for (local, remote, fixed) in try candidates(state, forgetting: forgetting, context: context) {
            let joined = try documents(local: local, remote: remote, forgetting: forgetting, state: state, context: context)
            let ink = try cloudOnlyInk(Set(joined.map(\.doc)), state: state, context: context).count
            let name = courses[remote]?.text("name") ?? ""
            pairs.append(["local": local, "remote": remote, "name": name, "fixed": fixed, "matched": joined.count, "ink": ink])
        }
        var remote: [[String: Any]] = []
        for id in courses.keys.sorted() where !mapped.contains(id) {
            let count = docs.values.filter { $0.text("course_id") == id }.count
            remote.append(["id": id, "name": courses[id]!.text("name") ?? "", "documents": count])
        }
        // Documents shared since an earlier connection lose their cloud-only ink in an overwrite too.
        let shared = forgetting ? [] : try Set(context.query("SELECT sync_id FROM cloud_sync_docs WHERE rel_path<>''").compactMap { $0["sync_id"] as? String })
        let sharedInk = try cloudOnlyInk(shared, state: state, context: context).count
        let documentCount = (materials?["n"] as? NSNumber)?.intValue ?? 0, localBytes = (materials?["bytes"] as? NSNumber)?.int64Value ?? 0
        let cloud: [String: Any] = ["courses": courses.count, "documents": docs.count, "bytes": bytes]
        let here: [String: Any] = ["courses": local.count, "documents": documentCount, "bytes": localBytes]
        return ["cloud": cloud, "local": here, "remoteCourses": remote, "sameName": pairs, "sharedInk": sharedInk, "fingerprint": fingerprint(files)]
    }

    /// The root as listed: an overwrite is refused when it changed after the sheet was shown.
    static func fingerprint(_ files: [String: SyncRemoteFile]) -> String {
        SyncFormat.sha256(Data(files.filter { SyncFormat.isSpecFile($0.key) }.map { $0.key + "\u{0}" + $0.value.version }.sorted().joined(separator: "\n").utf8))
    }

    /// Joins this iPad to the root. This iPad's own courses from an earlier connection and the checked
    /// same-name courses become the cloud's course; inside them a PDF that is the cloud's document (by
    /// id from an earlier connection, or by the same bytes) becomes that document, keeping the ink of
    /// both sides. A merge takes the cloud's course values. An overwrite sends this iPad's values again
    /// whole and queues deletes for what only the cloud holds; its first export applies nothing first.
    static func connect(_ mode: Mode, pairs: [(local: String, remote: String)], state: SyncMerge.State, store: SyncStore, library: NativeLibraryRepository) throws {
        let context = store.context
        try scan(context: context, library: library)
        try context.transaction {
            // A connection starts from what is chosen now, never from an earlier attempt that did not finish.
            try context.run("DELETE FROM cloud_sync_state WHERE key IN ('pending_deletes','export_first')")
            let fixed = try candidates(state, forgetting: false, context: context).filter(\.fixed).map { (local: $0.local, remote: $0.remote) }
            for pair in fixed + pairs {
                guard let course = state.courses[pair.remote], course.isAlive,
                      try context.query("SELECT 1 FROM cloud_sync_courses WHERE sync_id=? OR local_id=?", [pair.remote, pair.local]).isEmpty else { continue }
                try context.run("INSERT INTO cloud_sync_courses(sync_id,local_id,origin,registers) VALUES(?,?,'local',?)", [pair.remote, pair.local, SyncStore.encode(course)])
                if mode == .merge { _ = try SyncApply(store: store, library: library, read: { _ in Data() }).bring(pair.local, to: course, known: .init()) }
                for (rel, doc) in try documents(local: pair.local, remote: pair.remote, forgetting: false, state: state, context: context) {
                    // The cloud's id and stamps, this iPad's place: nothing is moved here or renamed there.
                    var registers = state.docs[doc]!
                    let (folder, name) = SyncAdapter.docLocation(rel)
                    for (key, value) in ["name": name, "rel_path": folder] {
                        if let stamp = registers.fields[key]?.stamp { registers.fields[key] = SyncMerge.Register(value: value, stamp: stamp) }
                    }
                    try context.run("INSERT INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES(?,?,?,'local',?)", [doc, pair.local, rel, SyncStore.encode(registers)])
                }
            }
            guard mode == .overwrite else { return }
            // This iPad's values go out again whole, also for what it shared before (design §4.2): a course
            // or document the cloud deleted meanwhile comes back instead of being deleted here. A note keeps
            // the cloud's text as its base, so its version follows the cloud's without a conflict copy.
            for table in ["cloud_sync_courses", "cloud_sync_docs"] {
                for row in try context.query("SELECT sync_id,registers FROM \(table)\(table == "cloud_sync_docs" ? " WHERE rel_path<>''" : "")") {
                    var fresh = SyncMerge.Entity()
                    fresh.fields["md_hash"] = try SyncStore.decode(row["registers"] as! String).fields["md_hash"]
                    try context.run("UPDATE \(table) SET registers=? WHERE sync_id=?", [SyncStore.encode(fresh), row["sync_id"]!])
                }
            }
            let kept = try Set(context.query("SELECT sync_id FROM cloud_sync_courses").compactMap { $0["sync_id"] as? String })
            let shared = try Set(context.query("SELECT sync_id FROM cloud_sync_docs WHERE rel_path<>''").compactMap { $0["sync_id"] as? String })
            var pending = Pending()
            for (id, course) in state.courses.sorted(by: { $0.key < $1.key }) where course.isAlive && !kept.contains(id) { pending.deletes.append(["course", id]) }
            for (id, doc) in state.docs.sorted(by: { $0.key < $1.key }) where doc.isAlive && !shared.contains(id) { pending.deletes.append(["doc", id]) }
            for (id, entry) in try cloudOnlyInk(shared, state: state, context: context) { pending.tombstones.append(.init(id: id, doc: entry.doc, page: entry.object.page)) }
            try store.set("pending_deletes", String(decoding: try JSONEncoder().encode(pending), as: UTF8.self))
            try store.set("export_first", "1")
        }
    }

    /// Course pairs to join: this iPad's own course ids the cloud already holds (an earlier connection
    /// to this root, forgotten since), then unmapped courses with the same name. Each side pairs once.
    private static func candidates(_ state: SyncMerge.State, forgetting: Bool, context: NativeRepositoryContext) throws -> [(local: String, remote: String, fixed: Bool)] {
        let mapped = forgetting ? [] : try context.query("SELECT sync_id,local_id FROM cloud_sync_courses")
        let usedRemote = Set(mapped.compactMap { $0["sync_id"] as? String }), usedLocal = Set(mapped.compactMap { $0["local_id"] as? String })
        let local = try context.query("SELECT id,name FROM courses WHERE deleted_at IS NULL AND source='managed' ORDER BY sort_order,id")
            .filter { !usedLocal.contains($0["id"] as! String) }
        let remote = state.courses.filter { $0.value.isAlive && !usedRemote.contains($0.key) }
        var result: [(local: String, remote: String, fixed: Bool)] = [], taken = Set<String>()
        for row in local where remote[row["id"] as! String] != nil {
            let id = row["id"] as! String
            result.append((id, id, true)); taken.insert(id)
        }
        for row in local where !taken.contains(row["id"] as! String) {
            let name = (row["name"] as? String ?? "").precomposedStringWithCanonicalMapping
            guard let match = remote.keys.sorted().first(where: { !taken.contains($0) && (remote[$0]!.text("name") ?? "").precomposedStringWithCanonicalMapping == name }) else { continue }
            result.append((row["id"] as! String, match, false)); taken.insert(match)
        }
        return result
    }

    /// The cloud's live PDFs that are already here in a local course, by local path: this iPad's PDF
    /// identity from an earlier connection first, then the same bytes. Each matches once. A file that
    /// cannot be read stops the connection rather than counting as missing (an overwrite would delete it).
    private static func documents(local: String, remote: String, forgetting: Bool, state: SyncMerge.State, context: NativeRepositoryContext) throws -> [(rel: String, doc: String)] {
        let candidates = state.docs.filter { $0.value.isAlive && $0.value.text("course_id") == remote && $0.value.text("type") == "pdf" }
        var free = Dictionary(grouping: candidates.keys.sorted(), by: { candidates[$0]!.text("pdf_sha256") ?? "" }), used = Set<String>()
        var result: [(rel: String, doc: String)] = []
        for row in try context.query("SELECT rel_path FROM materials_index WHERE course_id=? AND deleted_at IS NULL AND kind='pdf' ORDER BY rel_path", [local]) {
            let rel = row["rel_path"] as! String
            guard try forgetting || context.query("SELECT 1 FROM cloud_sync_docs WHERE course_id=? AND rel_path=?", [local, rel]).isEmpty else { continue }
            let own = try context.query("SELECT material_id FROM pdf_document_aliases WHERE course_id=? AND rel_path=?", [local, rel]).first?["material_id"] as? String
            let doc: String
            if let own, candidates[own] != nil, !used.contains(own) { doc = own } else {
                let hash = try context.contentHash(context.materialURL(courseID: local, relativePath: rel))
                guard let match = free[hash]?.first(where: { !used.contains($0) }) else { continue }
                doc = match
            }
            used.insert(doc); free = free.mapValues { $0.filter { $0 != doc } }
            result.append((rel, doc))
        }
        return result
    }

    /// Cloud ink in these documents that this iPad does not hold, of kinds it understands (others stay).
    private static func cloudOnlyInk(_ docs: Set<String>, state: SyncMerge.State, context: NativeRepositoryContext) throws -> [(id: String, entry: (doc: String, object: SyncFormat.InkObject, stamp: SyncMerge.Stamp))] {
        try state.ink.sorted(by: { $0.key < $1.key }).filter { id, entry in
            guard docs.contains(entry.doc), entry.object.value["del"] == nil, SyncAdapter.understands(entry.object) else { return false }
            return try context.query("SELECT 1 FROM pdf_drawings WHERE id=? AND deleted_at IS NULL", [id]).isEmpty
        }.map { ($0.key, $0.value) }
    }

    /// The library index is filled by folder scans; files added since the last one count too.
    private static func scan(context: NativeRepositoryContext, library: NativeLibraryRepository) throws {
        for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL AND source='managed'") { _ = try library.handle("materials:tree", ["courseId": row["id"]!]) }
    }
}
