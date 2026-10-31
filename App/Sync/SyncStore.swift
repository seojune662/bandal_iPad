import Foundation

/// The sync engine's state in bandal.db (design §1.7 and §1.9): this device's id, the
/// seq counter and the clock, what was last exchanged for every course, document and
/// drawing, and this device's own files. Runs on the storage queue like every
/// repository. The legacy `ipad_sync_*` tables are not touched.
final class SyncStore {
    private typealias C = NativeRepositoryContext

    /// Keychain access, replaced in tests.
    struct Keychain {
        var read: (String) -> String?
        var write: (String, String) throws -> Void
        static let live = Keychain(read: KeychainStore.read, write: { try KeychainStore.write($1, account: $0) })
    }

    let context: NativeRepositoryContext
    private let keychain: Keychain, account: String

    init(context: NativeRepositoryContext, keychain: Keychain = .live) throws {
        self.context = context
        self.keychain = keychain
        // Each profile root is its own device, as each keeps its own login session.
        account = context.root.lastPathComponent == "BandalDesktop" ? "sync.device" : "sync.device." + context.root.lastPathComponent
        // `registers` holds the spec registers last exchanged (sent or applied), so a newer
        // remote write is told apart from this device's own write that is not visible yet.
        try context.db.exec("""
        CREATE TABLE IF NOT EXISTS cloud_sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_sync_courses(
          sync_id TEXT PRIMARY KEY, local_id TEXT NOT NULL UNIQUE,
          origin TEXT NOT NULL CHECK(origin IN ('local','remote')), registers TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_sync_docs(
          sync_id TEXT PRIMARY KEY, course_id TEXT NOT NULL, rel_path TEXT NOT NULL,
          origin TEXT NOT NULL CHECK(origin IN ('local','remote')), registers TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS cloud_sync_docs_path ON cloud_sync_docs(course_id, rel_path);
        CREATE TABLE IF NOT EXISTS cloud_sync_objects(
          id TEXT PRIMARY KEY, doc TEXT NOT NULL, page INTEGER NOT NULL,
          t INTEGER NOT NULL, dev TEXT NOT NULL, seq INTEGER NOT NULL, idx INTEGER NOT NULL, hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_sync_dirty(id TEXT PRIMARY KEY, mark INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_sync_files(path TEXT PRIMARY KEY, key TEXT NOT NULL, open INTEGER NOT NULL, content TEXT);
        """)
    }

    // MARK: Identity (spec "식별자와 시간")

    /// This device's id. The database keeps it and the keychain keeps a copy that never
    /// leaves the device: a database restored from a backup of another iPad, or copied,
    /// no longer matches, so it gets a new id and two devices never write as one.
    func deviceID() throws -> String {
        let stored = try value("device_id")
        if let stored, stored == keychain.read(account) { return stored }
        let id = UUID().uuidString.lowercased()
        try keychain.write(account, id)
        try context.transaction {
            try set("device_id", id)
            try set("next_seq", "1")
            // Files written under the old id now belong to another device.
            try context.run("DELETE FROM cloud_sync_files")
        }
        return id
    }

    /// Seq for a new own file. One counter serves log, ink and notes, and it always passes
    /// the largest own seq in the root, so a database restored to an older state never
    /// overwrites a file it wrote before.
    func nextSeq(pastRemote remoteMax: Int) throws -> Int {
        let seq = max(Int(try value("next_seq") ?? "1") ?? 1, remoteMax + 1)
        try set("next_seq", String(seq + 1))
        return seq
    }

    /// t for a local change: `max(now, clock + 1)`. The clock is the largest t seen, own
    /// or remote, so a later local change always passes everything this device has read.
    func stamp(now: Int64) throws -> Int64 {
        let t = max(now, try clock() + 1)
        try set("clock", String(t))
        return t
    }

    func observe(_ t: Int64) throws {
        if t > (try clock()) { try set("clock", String(t)) }
    }

    private func clock() throws -> Int64 { Int64(try value("clock") ?? "0") ?? 0 }

    func value(_ key: String) throws -> String? {
        try context.query("SELECT value FROM cloud_sync_state WHERE key=?", [key]).first?["value"] as? String
    }

    func set(_ key: String, _ value: String) throws {
        try context.run("INSERT INTO cloud_sync_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    // MARK: Change capture (design §1.6)

    /// Drawing writes are captured by triggers only while sync is on, so the table never
    /// grows while it is off. Turning it on marks every drawing for one full comparison;
    /// unchanged ones are skipped by their content hash. Each write leaves a new random
    /// mark, so a drawing written again while its export is in flight stays dirty.
    func setCapturing(_ on: Bool) throws {
        guard on else {
            try context.db.exec("DROP TRIGGER IF EXISTS cloud_sync_ink_insert; DROP TRIGGER IF EXISTS cloud_sync_ink_update; DROP TRIGGER IF EXISTS cloud_sync_ink_delete")
            return
        }
        try context.transaction {
            try context.db.exec("""
            CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_insert AFTER INSERT ON pdf_drawings BEGIN INSERT OR REPLACE INTO cloud_sync_dirty VALUES(NEW.id, random()); END;
            CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_update AFTER UPDATE ON pdf_drawings BEGIN INSERT OR REPLACE INTO cloud_sync_dirty VALUES(NEW.id, random()); END;
            CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_delete AFTER DELETE ON pdf_drawings BEGIN INSERT OR REPLACE INTO cloud_sync_dirty VALUES(OLD.id, random()); END;
            INSERT OR REPLACE INTO cloud_sync_dirty SELECT id, random() FROM pdf_drawings;
            """)
        }
    }

    // MARK: Registers

    /// `{"fields": {name: [value, t, device, seq, index]}, "deleted": [bool, t, device, seq, index]}`
    static func encode(_ entity: SyncMerge.Entity) throws -> String {
        func pack(_ value: Any, _ stamp: SyncMerge.Stamp) -> [Any] { [value, stamp.t, stamp.device, stamp.seq, stamp.index] }
        var object: [String: Any] = ["fields": entity.fields.mapValues { pack($0.value, $0.stamp) }]
        if let deleted = entity.deleted { object["deleted"] = pack(deleted.value, deleted.stamp) }
        return try C.json(object)
    }

    static func decode(_ text: String) throws -> SyncMerge.Entity {
        func unpack(_ value: Any?) throws -> (Any, SyncMerge.Stamp) {
            guard let items = value as? [Any], items.count == 5, let t = (items[1] as? NSNumber)?.int64Value, let device = items[2] as? String,
                  let seq = (items[3] as? NSNumber)?.intValue, let index = (items[4] as? NSNumber)?.intValue else { throw C.validation("Invalid sync register") }
            return (items[0], SyncMerge.Stamp(t: t, device: device, seq: seq, index: index))
        }
        guard let object = try C.jsonObject(text) as? [String: Any], let fields = object["fields"] as? [String: Any] else { throw C.validation("Invalid sync registers") }
        var entity = SyncMerge.Entity()
        for (key, value) in fields {
            let (item, stamp) = try unpack(value)
            entity.fields[key] = SyncMerge.Register(value: item, stamp: stamp)
        }
        if let deleted = object["deleted"] {
            let (item, stamp) = try unpack(deleted)
            entity.deleted = ((item as? NSNumber)?.boolValue ?? false, stamp)
        }
        return entity
    }

    /// JSON value equality for register values (numbers by value, booleans apart from numbers).
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (try? C.json([a])) == (try? C.json([b]))
    }
}
