import Database, { type Database as SqliteDatabase } from 'better-sqlite3'
import { ImportReadError } from './types'

/** A SQLite read transaction sees a consistent snapshot, including committed WAL.
 * No copying/chmod/checkpoint of the user's database and no plaintext temp files.
 */
export function readSnapshot<T>(path: string, read: (db: SqliteDatabase) => T): T {
  let db: SqliteDatabase | undefined
  try {
    db = new Database(path, { readonly: true, fileMustExist: true, timeout: 750 })
    db.pragma('query_only = ON')
    return db.transaction(() => read(db!))()
  } catch (error) {
    if (error instanceof ImportReadError) throw error
    const code = typeof error === 'object' && error !== null && 'code' in error ? String(error.code) : ''
    throw new ImportReadError(code.includes('BUSY') || code.includes('LOCKED') ? 'locked' : code === 'EACCES' || code === 'EPERM' ? 'permission' : 'format')
  } finally { db?.close() }
}

export function tableColumns(db: SqliteDatabase, table: string): Set<string> {
  if (!/^[a-z_]+$/i.test(table)) throw new ImportReadError('format')
  return new Set((db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>).map((column) => column.name))
}
