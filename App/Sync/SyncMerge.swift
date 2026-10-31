import CryptoKit
import Foundation

/// Pure merge of a parsed cloud root (spec v2.3 "머지"), mirroring the desktop's
/// `src/main/features/sync/merge.ts`. The result depends only on the set of
/// files, never on their order or on reading one twice.
enum SyncMerge {
    static let conflictCopyNamespace = UUID(uuidString: "9b1f6a2e-3c4d-4e5f-8a6b-7c8d9e0f1a2b")!

    /// Larger t, then larger device_id. Equal (t, device_id) only comes from a writer
    /// breaking the spec; the later write (seq, then position in the file) wins so both
    /// apps pick the same value without comparing JSON text (desktop PR #4, item 8).
    struct Stamp: Comparable {
        let t: Int64, device: String, seq: Int, index: Int

        static func < (a: Stamp, b: Stamp) -> Bool {
            if a.t != b.t { return a.t < b.t }
            if a.device != b.device { return a.device.utf8.lexicographicallyPrecedes(b.device.utf8) }
            return (a.seq, a.index) < (b.seq, b.index)
        }
    }

    struct Register { let value: Any; let stamp: Stamp }

    struct Entity {
        var fields: [String: Register] = [:]
        /// `*.delete` writes true and `*.upsert` writes false, both under the same order.
        var deleted: (value: Bool, stamp: Stamp)?
        var isAlive: Bool { deleted?.value != true }
        func text(_ key: String) -> String? { fields[key]?.value as? String }
    }

    struct ConflictCopy {
        let id, of, courseID, relPath, name, mdHash: String
        /// Root path of the losing version's content.
        let file: String
    }

    enum Blocked: String { case missingRoot = "missing-root", updateRequired = "update-required", unsupportedFormat = "unsupported-format" }

    struct State {
        /// Set when `bandal.json` is missing or not format 2: nothing else is read.
        var blocked: Blocked?
        var devices: [String: String] = [:]
        var courses: [String: Entity] = [:]
        var docs: [String: Entity] = [:]
        /// Winning version per drawing id, with the document its file sits under.
        var ink: [String: (doc: String, object: SyncFormat.InkObject, stamp: Stamp)] = [:]
        /// md body per document: the md_hash winner and the file holding it.
        var notes: [String: (hash: String, file: String?)] = [:]
        var conflictCopies: [ConflictCopy] = []
        /// `doc.upsert` renames that settle path collisions; every device computes the same list.
        var renames: [(id: String, name: String)] = []
        /// Not appliable yet: a referenced course, document, PDF, asset or note file is missing.
        /// A copy waits for its text only; it already holds its name.
        var waitingDocs: [String] = [], waitingInk: [String] = [], waitingCopies: [String] = []
    }

    private struct NoteVersion { let hash: String; let base: String?; let stamp: Stamp }
    private struct NoteFile { let path, author, hash: String; let seq: Int; let assets: [String] }

    static func merge(_ files: [SyncFormat.File]) -> State {
        var state = State()
        guard let format = files.lazy.compactMap({ file -> Int? in if case .root(let format) = file.content { return format }; return nil }).first else {
            state.blocked = .missingRoot; return state
        }
        guard format == SyncFormat.version else { state.blocked = format > SyncFormat.version ? .updateRequired : .unsupportedFormat; return state }

        var present = Set<String>(), versions: [String: [NoteVersion]] = [:], noteFiles: [String: [NoteFile]] = [:]
        for file in files {
            switch file.content {
            case .root: break
            case .device(let id, let name): state.devices[id] = name
            case .pdf, .asset: present.insert(file.path)
            case .note(let author, let seq, let doc, let hash, let assets):
                noteFiles[doc, default: []].append(NoteFile(path: file.path, author: author, hash: hash, seq: seq, assets: assets))
            case .ink(let author, let seq, let doc, let objects, _):
                for object in objects {
                    let stamp = Stamp(t: object.t, device: author, seq: seq, index: object.index)
                    if state.ink[object.id].map({ stamp > $0.stamp }) ?? true { state.ink[object.id] = (doc, object, stamp) }
                }
            case .log(let author, let seq, let events, _):
                for event in events {
                    let stamp = Stamp(t: event.t, device: author, seq: seq, index: event.index), isCourse = event.op.hasPrefix("course.")
                    var entity = (isCourse ? state.courses[event.id] : state.docs[event.id]) ?? Entity()
                    let deleting = event.op.hasSuffix(".delete")
                    if entity.deleted.map({ stamp > $0.stamp }) ?? true { entity.deleted = (deleting, stamp) }
                    if !deleting {
                        for (key, value) in event.fields where entity.fields[key].map({ stamp > $0.stamp }) ?? true {
                            entity.fields[key] = Register(value: value, stamp: stamp)
                        }
                        if event.op == "doc.upsert", let hash = event.fields["md_hash"] as? String {
                            // A missing md_base reads as a fresh start (null): writers send md_hash and md_base together.
                            versions[event.id, default: []].append(NoteVersion(hash: hash, base: event.fields["md_base"] as? String, stamp: stamp))
                        }
                    }
                    if isCourse { state.courses[event.id] = entity } else { state.docs[event.id] = entity }
                }
            }
        }

        /// Course, folder and name are all known; until then a document takes part in no naming rule.
        func place(_ entity: Entity) -> (course: String, folder: String, name: String)? {
            guard let course = entity.text("course_id"), let folder = entity.text("rel_path"), let name = entity.text("name") else { return nil }
            return (course, folder, name)
        }
        /// The author's own file first, then any file with the same hash: later seq, then larger path.
        func contentFile(_ doc: String, _ hash: String, author: String) -> NoteFile? {
            (noteFiles[doc] ?? []).filter { $0.hash == hash }.min { a, b in
                if (a.author == author) != (b.author == author) { return a.author == author }
                if a.seq != b.seq { return a.seq > b.seq }
                return b.path.utf16.lexicographicallyPrecedes(a.path.utf16)
            }
        }

        var waiting = Set<String>(), copies: [(id: String, of: String, course: String, folder: String, name: String, hash: String, file: String?)] = []
        for (doc, entity) in state.docs {
            guard let body = entity.text("md_hash") else { continue }
            let own = versions[doc] ?? []
            /// Writer of a hash: the latest stamp among the versions that carry it.
            func author(of hash: String) -> String { own.filter { $0.hash == hash }.max { $0.stamp < $1.stamp }!.stamp.device }
            let bodyFile = contentFile(doc, body, author: author(of: body))
            state.notes[doc] = (body, bodyFile?.path)
            if entity.isAlive, bodyFile.map({ $0.assets.contains { !present.contains($0) } }) ?? true { waiting.insert(doc) }

            guard let place = place(entity) else { continue }
            // A version stops being a head only when a later version (larger t) started from its text, so a revert
            // to an old hash stays a head and the LWW winner always is one. Each base's latest t is collected once.
            var latestFrom: [String: Int64] = [:]
            for version in own { if let base = version.base { latestFrom[base] = max(latestFrom[base] ?? .min, version.stamp.t) } }
            for hash in Set(own.filter { (latestFrom[$0.hash] ?? .min) <= $0.stamp.t }.map(\.hash)) where hash != body {
                let id = uuidV5("\(doc):\(hash)")
                guard state.docs[id] == nil else { continue }
                // Until the writer's device file arrives its id stands in; a derived copy's name is recomputed on every merge.
                let writer = author(of: hash)
                let device = nameSafe((state.devices[writer] ?? String(writer.prefix(8))).precomposedStringWithCanonicalMapping)
                copies.append((id, doc, place.course, place.folder, "\(splitName(place.name).stem) (충돌 사본 \(device)).md", hash,
                               contentFile(doc, hash, author: writer)?.path))
            }
        }

        var byPath: [[Unicode.Scalar]: [String]] = [:]
        for (id, entity) in state.docs where entity.isAlive {
            if let place = place(entity) { byPath[pathKey(place.course, place.folder, place.name), default: []].append(id) }
        }
        for ids in byPath.values {
            for id in ids.sorted().dropFirst() {
                let (stem, ext) = splitName(state.docs[id]!.text("name")!)
                state.renames.append((id, "\(stem) (\(id.prefix(4)))\(ext)"))
            }
        }
        state.renames.sort { $0.id < $1.id }

        // Copies join the collision rule: a live document keeps its name, and among copies the smallest id does.
        // Copies still waiting for their text take part too, so a late note file never renames a made copy.
        var taken = Set(byPath.keys)
        for copy in copies.sorted(by: { $0.id < $1.id }) {
            let key = pathKey(copy.course, copy.folder, copy.name), (stem, ext) = splitName(copy.name)
            let name = taken.contains(key) ? "\(stem) (\(copy.id.prefix(4)))\(ext)" : copy.name
            taken.insert(key)
            guard let file = copy.file else { state.waitingCopies.append(copy.id); continue }
            state.conflictCopies.append(ConflictCopy(id: copy.id, of: copy.of, courseID: copy.course, relPath: copy.folder, name: name, mdHash: copy.hash, file: file))
        }

        for (id, entity) in state.docs where entity.isAlive {
            let missingCourse = entity.text("course_id").map { state.courses[$0] == nil } ?? true
            let missingPDF = entity.text("type") == "pdf" && !(entity.text("pdf_sha256").map { present.contains("pdf/\($0).pdf") } ?? false)
            if missingCourse || missingPDF { waiting.insert(id) }
        }
        for (id, entry) in state.ink {
            let image = entry.object.value["del"] == nil ? (entry.object.value["data"] as? [String: Any])?["image"] as? [String: Any] : nil
            let missingAsset = image.map { !present.contains("assets/\($0["sha256"] as! String).\($0["ext"] as! String)") } ?? false
            if state.docs[entry.doc] == nil || missingAsset { state.waitingInk.append(id) }
        }
        state.waitingDocs = waiting.sorted()
        state.waitingInk.sort()
        return state
    }

    /// RFC 4122 name-based UUID (SHA-1), lowercase, as the desktop's `uuid` v5 makes it.
    static func uuidV5(_ name: String, namespace: UUID = conflictCopyNamespace) -> String {
        let seed = withUnsafeBytes(of: namespace.uuid) { Data($0) } + Data(name.utf8)
        var bytes = Array(Insecure.SHA1.hash(data: seed).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
    }

    /// `name.lastIndexOf('.')` split, on scalars so a combining mark cannot move the cut.
    static func splitName(_ name: String) -> (stem: String, ext: String) {
        let scalars = name.unicodeScalars
        guard let dot = scalars.lastIndex(of: "."), dot > scalars.startIndex else { return (name, "") }
        return (String(scalars[..<dot]), String(scalars[dot...]))
    }

    /// Path-collision key (spec v2.3): folder and name upper- then lower-cased one code point at a time
    /// (desktop: `c.toUpperCase().toLowerCase()`), so Σ, σ and ς are one letter as on APFS and NTFS,
    /// and ß becomes ss. Validated names and folders hold no control characters, so NUL separates the parts.
    /// Scalars, not a String: Swift strings compare canonically equivalent text as equal, JavaScript does not.
    private static func pathKey(_ course: String, _ folder: String, _ name: String) -> [Unicode.Scalar] {
        Array(course.unicodeScalars) + ["\u{0}"] + foldCase(folder) + ["\u{0}"] + foldCase(name)
    }

    private static func foldCase(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.flatMap { $0.properties.uppercaseMapping.unicodeScalars.flatMap(\.properties.lowercaseMapping.unicodeScalars) }
    }

    /// Device names are user text; keep the copy's name one valid path segment.
    private static func nameSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0 == "/" ? "_" : $0 }))
    }
}
