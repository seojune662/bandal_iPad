/**
 * SQLite database access for the Electron main process.
 *
 * better-sqlite3 is a native module. The copy in node_modules is rebuilt
 * against the ELECTRON ABI by `electron-builder install-app-deps` (wired as
 * the `postinstall` script), so it must only be require()d from inside
 * Electron — hence the lazy require below. Node-side tests use a separate
 * Node-ABI copy (see tests/main/helpers/testDb.ts).
 */

import { app } from 'electron'
import { join } from 'node:path'
import type { Database } from 'better-sqlite3'
import { runMigrations } from './migrations'

const DB_FILE = 'bandal.db'

let db: Database | null = null

/** Returns the open database. Throws if initDatabase has not run. */
export function getDatabase(): Database {
  if (db === null) {
    throw new Error('[db] Database not initialized — call initDatabase() first')
  }
  return db
}

/**
 * Opens (or creates) a database at `filePath`, enables WAL + foreign keys
 * and applies pending migrations. Exported for reuse; prefer initDatabase
 * in app code.
 */
export function openDatabase(filePath: string, migrate = true): Database {
  // Lazy require: keeps module load side-effect free and defers the native
  // binding load until Electron is actually running.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const BetterSqlite3 =
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    require('better-sqlite3') as typeof import('better-sqlite3')
  const opened = new BetterSqlite3(filePath)
  opened.pragma('journal_mode = WAL')
  opened.pragma('foreign_keys = ON')
  if (migrate) runMigrations(opened)
  return opened
}

/** Opens userData/bandal.db and runs migrations. Idempotent. */
export function initDatabase(migrate = true): void {
  if (db !== null) {
    return
  }
  const filePath = join(app.getPath('userData'), DB_FILE)
  try {
    db = openDatabase(filePath, migrate)
    console.log(`[db] opened ${filePath}`)
  } catch (error) {
    console.error(`[db] failed to open ${filePath}:`, error)
    throw error
  }
}

/** Closes the database if open. */
export function closeDatabase(): void {
  if (db !== null) {
    db.close()
    db = null
  }
}
