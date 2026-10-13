import CSQLite
import Foundation

// All access is confined to RecordStore's actor. This wrapper permits safe
// finalization from deinit without exposing a non-Sendable C pointer.
final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            let error = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite"
            if let opened { sqlite3_close(opened) }
            throw CoreError.database(error)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            try exec("""
                CREATE TABLE IF NOT EXISTS records (
                  id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL,
                  revision INTEGER NOT NULL, deleted INTEGER NOT NULL, format_version INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS outbox (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                  record_id TEXT NOT NULL, operation BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS outbox_record ON outbox(record_id);
                CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY, value BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS local_mutation_receipts (
                  mutation_id TEXT PRIMARY KEY, record_id TEXT NOT NULL,
                  kind TEXT NOT NULL, payload_hash TEXT NOT NULL);
                """)
        } catch { sqlite3_close(handle); throw error }
    }
    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> CoreError { .database(String(cString: sqlite3_errmsg(handle))) }
    func statement(_ sql: String) throws -> Statement { try Statement(connection: self, sql: sql) }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try action(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
}

final class Statement {
    private let connection: SQLiteConnection
    let handle: OpaquePointer
    init(connection: SQLiteConnection, sql: String) throws {
        self.connection = connection
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw connection.error()
        }
        handle = prepared
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(handle, index, text, -1, transient)
            case .integer(let integer): result = sqlite3_bind_int64(handle, index, integer)
            case .data(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else { throw connection.error() }
        }
    }
    @discardableResult func step() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw connection.error()
    }
    func text(_ index: Int32) -> String { String(cString: sqlite3_column_text(handle, index)) }
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    func data(_ index: Int32) -> Data {
        let size = Int(sqlite3_column_bytes(handle, index))
        guard size > 0, let pointer = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: pointer, count: size)
    }
}

enum SQLValue { case text(String), integer(Int64), data(Data) }
