import Foundation
import CryptoKit

public actor RecordStore {
    private let db: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws { db = try SQLiteConnection(url: url) }

    /// Commits a disk-journal mutation exactly once. A replay returns the current
    /// record, which may already contain a later edit, without creating an outbox entry.
    /// Receipts store only a digest, never another copy of the note or drawing.
    @discardableResult
    public func applyLocalJournalEntry(mutationID: String, id: String, kind: String, payload: Data) throws -> StoredRecord {
        guard !mutationID.isEmpty, mutationID.utf8.count <= 512 else {
            throw CoreError.invalidRecord("Invalid local mutation ID")
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try db.transaction {
            let receipt = try db.statement("SELECT record_id,kind,payload_hash FROM local_mutation_receipts WHERE mutation_id=?")
            try receipt.bind([.text(mutationID)])
            if try receipt.step() {
                guard receipt.text(0) == id, receipt.text(1) == kind, receipt.text(2) == digest else {
                    throw CoreError.invalidRecord("Local mutation ID reused with different content")
                }
                guard let current = try get(id: id) else { throw CoreError.missingRecord(id) }
                return current
            }
            let record = try upsertWithinTransaction(id: id, kind: kind, payload: payload)
            let save = try db.statement("INSERT INTO local_mutation_receipts(mutation_id,record_id,kind,payload_hash) VALUES(?,?,?,?)")
            try save.bind([.text(mutationID), .text(id), .text(kind), .text(digest)])
            try save.step()
            return record
        }
    }

    @discardableResult
    public func upsert(id: String = UUID().uuidString, kind: String, payload: Data) throws -> StoredRecord {
        try db.transaction { try upsertWithinTransaction(id: id, kind: kind, payload: payload) }
    }

    private func upsertWithinTransaction(id: String, kind: String, payload: Data) throws -> StoredRecord {
            let previous = try get(id: id)
            guard previous == nil || previous?.kind == kind else { throw CoreError.invalidRecord("Record kind cannot change") }
            let record = StoredRecord(id: id, kind: kind, payload: payload, revision: (previous?.revision ?? 0) + 1)
            try validate(record)
            try write(record)
            try enqueue(record, baseRevision: previous?.revision ?? 0)
            return record
    }

    @discardableResult
    public func upsert<T: Encodable & Sendable>(id: String = UUID().uuidString, kind: String, value: T) throws -> StoredRecord {
        try upsert(id: id, kind: kind, payload: encoder.encode(value))
    }

    /// Applies an exchange package as one local edit transaction. Imported
    /// revisions are not authoritative: each edit advances the current local
    /// revision and receives a matching outbox operation, including tombstones.
    /// All inputs are validated before the first record or outbox write.
    @discardableResult
    public func importLocalRecords(_ records: [StoredRecord]) throws -> [StoredRecord] {
        try db.transaction {
            var seen = Set<String>()
            var prepared: [(record: StoredRecord, baseRevision: Int)] = []
            prepared.reserveCapacity(records.count)
            for imported in records {
                guard SyncPolicy.allowedKinds.contains(imported.kind) else {
                    throw CoreError.invalidRecord("Unsupported exchange record kind")
                }
                guard seen.insert(imported.id).inserted else {
                    throw CoreError.invalidRecord("Duplicate ID in local import")
                }
                let previous = try get(id: imported.id)
                guard previous == nil || previous?.kind == imported.kind else {
                    throw CoreError.invalidRecord("Record kind cannot change")
                }
                let base = previous?.revision ?? 0
                let record = StoredRecord(id: imported.id, kind: imported.kind, payload: imported.payload,
                                          revision: base + 1, deleted: imported.deleted,
                                          formatVersion: imported.formatVersion)
                try validate(record)
                prepared.append((record, base))
            }
            for entry in prepared {
                try write(entry.record)
                try enqueue(entry.record, baseRevision: entry.baseRevision)
            }
            return prepared.map(\.record)
        }
    }

    public func get(id: String) throws -> StoredRecord? {
        let query = try db.statement("SELECT id,kind,payload,revision,deleted,format_version FROM records WHERE id=?")
        try query.bind([.text(id)])
        return try query.step() ? row(query) : nil
    }

    public func list(kind: String? = nil, includeDeleted: Bool = false) throws -> [StoredRecord] {
        var sql = "SELECT id,kind,payload,revision,deleted,format_version FROM records WHERE 1=1"
        if kind != nil { sql += " AND kind=?" }
        if !includeDeleted { sql += " AND deleted=0" }
        sql += " ORDER BY id"
        let query = try db.statement(sql)
        if let kind { try query.bind([.text(kind)]) }
        var records: [StoredRecord] = []
        while try query.step() { records.append(row(query)) }
        return records
    }

    public func delete(id: String) throws {
        try db.transaction {
            guard let previous = try get(id: id) else { throw CoreError.missingRecord(id) }
            if previous.deleted { return }
            let record = StoredRecord(id: id, kind: previous.kind, payload: previous.payload,
                                      revision: previous.revision + 1, deleted: true)
            try write(record)
            try enqueue(record, baseRevision: previous.revision)
        }
    }

    public func pendingOperations(limit: Int = 100) throws -> [SyncOperation] {
        let query = try db.statement("SELECT operation FROM outbox ORDER BY sequence LIMIT ?")
        try query.bind([.integer(Int64(max(1, min(limit, 1000))))])
        var operations: [SyncOperation] = []
        while try query.step() { operations.append(try decoder.decode(SyncOperation.self, from: query.data(0))) }
        return operations
    }

    func isPending(_ operationID: String) throws -> Bool {
        let query = try db.statement("SELECT 1 FROM outbox WHERE id=?")
        try query.bind([.text(operationID)])
        return try query.step()
    }

    public func conflicts() throws -> [SyncConflict] {
        let query = try db.statement("SELECT value FROM conflicts ORDER BY rowid")
        var conflicts: [SyncConflict] = []
        while try query.step() { conflicts.append(try decoder.decode(SyncConflict.self, from: query.data(0))) }
        return conflicts
    }

    /// Restoring a conflict creates a new ID; deleted remote objects never resurrect silently.
    public func restoreConflict(id: String, newRecordID: String = UUID().uuidString) throws -> StoredRecord {
        try db.transaction {
            let query = try db.statement("SELECT value FROM conflicts WHERE id=?")
            try query.bind([.text(id)])
            guard try query.step() else { throw CoreError.missingRecord(id) }
            let conflict = try decoder.decode(SyncConflict.self, from: query.data(0))
            guard try get(id: newRecordID) == nil else { throw CoreError.invalidRecord("Restore requires a new ID") }
            let restored = StoredRecord(id: newRecordID, kind: conflict.local.kind, payload: conflict.local.payload, revision: 1)
            try write(restored); try enqueue(restored, baseRevision: 0)
            // Keep the conflict history even after restoration for recovery/auditing.
            return restored
        }
    }

    public func syncCursor() throws -> Int64 {
        let query = try db.statement("SELECT value FROM metadata WHERE key='sync_cursor'")
        return try query.step() ? Int64(query.text(0)) ?? 0 : 0
    }

    /// Reads the existing binding without claiming an unbound local store.
    public func syncAccount() throws -> String? {
        let query = try db.statement("SELECT value FROM metadata WHERE key='sync_account'")
        return try query.step() ? query.text(0) : nil
    }

    /// Binds a database to a user before transport access. Switching accounts must
    /// select another database so one user's queued content cannot be uploaded to another.
    public func bindSyncAccount(userID: String) throws {
        guard !userID.isEmpty else { throw CoreError.invalidRecord("Missing sync account") }
        try db.transaction {
            let query = try db.statement("SELECT value FROM metadata WHERE key='sync_account'")
            if try query.step() {
                guard query.text(0) == userID else { throw CoreError.invalidRecord("Store belongs to another sync account") }
            } else {
                let insert = try db.statement("INSERT INTO metadata(key,value) VALUES('sync_account',?)")
                try insert.bind([.text(userID)]); try insert.step()
            }
        }
    }

    func acknowledge(_ operation: SyncOperation, result: PushResult) throws -> SyncAcknowledgement {
        try validate(result.record)
        guard result.record.id == operation.record.id, result.record.kind == operation.record.kind else {
            throw CoreError.invalidResponse("Push returned another record")
        }
        return try db.transaction {
            let pending = try db.statement("SELECT id FROM outbox WHERE id=?")
            try pending.bind([.text(operation.id)])
            guard try pending.step() else { return .accepted }
            if result.status == .conflict {
                guard let local = try get(id: operation.record.id) else { throw CoreError.missingRecord(operation.record.id) }
                if let merged = try DrawingMerge.merge(local: local, remote: result.record) {
                    let remove = try db.statement("DELETE FROM outbox WHERE record_id=?")
                    try remove.bind([.text(local.id)]); try remove.step()
                    try write(merged)
                    try enqueue(merged, baseRevision: result.record.revision)
                    return .merged
                }
                let conflict = SyncConflict(id: UUID().uuidString, local: local, remote: result.record, createdAt: Date())
                let save = try db.statement("INSERT INTO conflicts(id,value) VALUES(?,?)")
                try save.bind([.text(conflict.id), .data(try encoder.encode(conflict))]); try save.step()
                let remove = try db.statement("DELETE FROM outbox WHERE record_id=?")
                try remove.bind([.text(local.id)]); try remove.step()
                try write(result.record)
                return .conflict
            }
            guard result.record == operation.record else { throw CoreError.invalidResponse("Acknowledgement changed submitted content") }
            let remove = try db.statement("DELETE FROM outbox WHERE id=?")
            try remove.bind([.text(operation.id)]); try remove.step()
            // Later local revisions remain intact; acknowledgement only drains its own operation.
            return .accepted
        }
    }

    func apply(_ page: PullPage) throws {
        try db.transaction {
            guard page.cursor >= (try syncCursor()) else { throw CoreError.invalidResponse("Cursor moved backwards") }
            for record in page.records {
                try validate(record)
                guard SyncPolicy.allowedKinds.contains(record.kind) else { throw CoreError.invalidResponse("Unsupported sync kind") }
                let pending = try db.statement("SELECT 1 FROM outbox WHERE record_id=? LIMIT 1")
                try pending.bind([.text(record.id)])
                if try pending.step() { continue }
                if let local = try get(id: record.id) {
                    guard local.kind == record.kind else { throw CoreError.invalidResponse("Remote record kind changed") }
                    if local.revision >= record.revision { continue }
                }
                try write(record)
            }
            let cursor = try db.statement("INSERT INTO metadata(key,value) VALUES('sync_cursor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try cursor.bind([.text(String(page.cursor))]); try cursor.step()
        }
    }

    private func row(_ query: Statement) -> StoredRecord {
        StoredRecord(id: query.text(0), kind: query.text(1), payload: query.data(2),
                     revision: Int(query.integer(3)), deleted: query.integer(4) != 0, formatVersion: Int(query.integer(5)))
    }
    private func write(_ record: StoredRecord) throws {
        let update = try db.statement("""
            INSERT INTO records(id,kind,payload,revision,deleted,format_version) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,payload=excluded.payload,
            revision=excluded.revision,deleted=excluded.deleted,format_version=excluded.format_version
            """)
        try update.bind([.text(record.id), .text(record.kind), .data(record.payload), .integer(Int64(record.revision)),
                         .integer(record.deleted ? 1 : 0), .integer(Int64(record.formatVersion))])
        try update.step()
    }
    private func enqueue(_ record: StoredRecord, baseRevision: Int) throws {
        guard SyncPolicy.allowedKinds.contains(record.kind) else { return }
        let operation = SyncOperation(baseRevision: baseRevision, record: record)
        let insert = try db.statement("INSERT INTO outbox(id,record_id,operation) VALUES(?,?,?)")
        try insert.bind([.text(operation.id), .text(record.id), .data(try encoder.encode(operation))]); try insert.step()
    }
}
