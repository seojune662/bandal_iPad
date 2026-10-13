import Database from 'better-sqlite3'
import type { MaterialPathLock } from './materialPathJournal'

/** Dedicated rollback-journal DB: never WAL and never the user's data DB.
 * The sync projector uses this same path and BEGIN EXCLUSIVE protocol.
 * SQLite/OS release the lock if a process exits or is killed. */
export function createMaterialPathLock(path: string, open: (path: string) => Database.Database =
  path => new Database(path, { timeout: 0 })): MaterialPathLock {
  return { tryAcquire() {
    const lock = open(path)
    try { lock.exec('BEGIN EXCLUSIVE') }
    catch (error) {
      lock.close()
      if ((error as { code?: string }).code === 'SQLITE_BUSY' || (error as { code?: string }).code === 'SQLITE_LOCKED') return undefined
      throw error
    }
    let released = false
    return () => { if (released) return; released = true; try { lock.exec('ROLLBACK') } finally { lock.close() } }
  } }
}
