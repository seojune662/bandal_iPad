import Foundation
import SQLite3

/// Swift repositories retain the existing SQL schema and transaction boundaries.
final class DesktopSQLite {
    private let db: OpaquePointer
    /// Rows changed on this connection since it opened; an unchanged value means no write happened.
    var totalChanges: Int64 { Int64(sqlite3_total_changes64(db)) }

    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }
            throw DesktopRuntimeError(message, code: "SQLITE_CANTOPEN")
        }
        db = handle
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 5_000)
        do { if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;") } }
        catch { sqlite3_close(db); throw error }
    }

    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func query(_ sql: String, params: Any?) throws -> [[String: Any]] {
        let statement = try prepare(sql, params: params)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                // iPadOS uses 64-bit Int. Return that native type so repository
                // results keep working when read directly by Swift UI models.
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, index))
                    let data = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: size) } ?? Data()
                    row[name] = ["__buffer": data.base64EncodedString()]
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
    }

    func run(_ sql: String, params: Any?) throws -> [String: Any] {
        let statement = try prepare(sql, params: params)
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
        return ["changes": Int(sqlite3_changes(db)), "lastInsertRowid": Int(sqlite3_last_insert_rowid(db))]
    }

    private func prepare(_ sql: String, params: Any?) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else { throw failure() }
        do {
            if let values = params as? [Any] {
                for (offset, value) in values.enumerated() { try bind(value, at: Int32(offset + 1), in: handle) }
            } else if let values = params as? [String: Any] {
                // better-sqlite3 accepts a repository object with extra fields.
                // Bind the statement's parameters, not every object property:
                // learning cache rows also contain arrays and derived metadata.
                let count = sqlite3_bind_parameter_count(handle)
                for index in 0..<count {
                    let position = index + 1
                    guard let rawName = sqlite3_bind_parameter_name(handle, position) else {
                        throw DesktopRuntimeError("An unnamed SQL parameter requires a positional value", code: "SQLITE_RANGE")
                    }
                    let name = String(cString: rawName)
                    let key = String(name.dropFirst())
                    guard let value = values[key] else {
                        throw DesktopRuntimeError("Missing SQL parameter: \(key)", code: "SQLITE_RANGE")
                    }
                    try bind(value, at: position, in: handle)
                }
            }
            return handle
        } catch { sqlite3_finalize(handle); throw error }
    }

    private func bind(_ value: Any, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status: Int32
        if value is NSNull { status = sqlite3_bind_null(statement, index) }
        else if let value = value as? String { status = sqlite3_bind_text(statement, index, value, -1, transient) }
        else if let value = value as? NSNumber {
            if CFNumberIsFloatType(value) { status = sqlite3_bind_double(statement, index, value.doubleValue) }
            else { status = sqlite3_bind_int64(statement, index, value.int64Value) }
        } else if let object = value as? [String: String], let encoded = object["__buffer"], let data = Data(base64Encoded: encoded) {
            status = data.withUnsafeBytes { buffer in
                if data.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
                return sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
            }
        } else { throw DesktopRuntimeError("Unsupported SQL binding", code: "SQLITE_MISMATCH") }
        guard status == SQLITE_OK else { throw failure() }
    }

    private func failure() -> DesktopRuntimeError {
        let code: String
        switch sqlite3_extended_errcode(db) {
        case SQLITE_CONSTRAINT | (8 << 8): code = "SQLITE_CONSTRAINT_UNIQUE"
        case SQLITE_CONSTRAINT | (6 << 8): code = "SQLITE_CONSTRAINT_PRIMARYKEY"
        case SQLITE_CONSTRAINT | (3 << 8): code = "SQLITE_CONSTRAINT_FOREIGNKEY"
        case SQLITE_CONSTRAINT | (5 << 8): code = "SQLITE_CONSTRAINT_NOTNULL"
        case SQLITE_BUSY: code = "SQLITE_BUSY"
        default: code = "SQLITE_ERROR"
        }
        return DesktopRuntimeError(String(cString: sqlite3_errmsg(db)), code: code)
    }
}

struct DesktopRuntimeError: LocalizedError {
    let message: String
    let code: String
    init(_ message: String, code: String = "ERR_DESKTOP_RUNTIME") { self.message = message; self.code = code }
    var errorDescription: String? { message }
}
