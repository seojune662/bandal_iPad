import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { Database } from 'better-sqlite3'
import type { DictionaryEntry, DictionaryLookupResult } from '../../../shared/types/dictionary'

const DATASET_VERSION = 'koreader-dicts-en-ko-v1.2.0'
const MAX_RESULTS = 16
const MAX_CACHE = 256

/** Keep query normalization in step with the developer-only dictionary importer. */
function lookupKey(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 160) return null
  const text = value.normalize('NFKC').replace(/[‘’]/g, "'").replace(/[‐‑–—]/g, '-')
    .toLowerCase().replace(/\s+/g, ' ').trim().replace(/^["“”'([{]+|["“”'\])}.,!?;:]+$/g, '')
  if (!text || text.length > 120 || text.split(' ').length > 5 || !/^[\p{L}\p{N}]+(?:[ '-][\p{L}\p{N}]+)*$/u.test(text)) return null
  return text
}

export interface DictionaryOptions {
  directory: string
  /** Tests inject the Node binding; production lazily loads the Electron binding. */
  openDatabase?: (filePath: string) => Database
}

/** Immutable bundled resource: unrelated to user databases, AI, or network services. */
export function createDictionaryService(options: DictionaryOptions) {
  let db: Database | null = null
  let failed = false
  const cache = new Map<string, DictionaryLookupResult>()

  function close(): void {
    db?.close()
    db = null
    cache.clear()
  }
  function open(): Database {
    if (failed) throw new Error('Dictionary is unavailable')
    if (db) return db
    const manifest = JSON.parse(readFileSync(join(options.directory, 'manifest.json'), 'utf8')) as {
      schemaVersion?: number; datasetVersion?: string; database?: { file?: string; sha256?: string; bytes?: number }
    }
    if (manifest.schemaVersion !== 1 || manifest.datasetVersion !== DATASET_VERSION || manifest.database?.file !== 'en-ko.sqlite') {
      throw new Error('Unsupported dictionary resource')
    }
    const filePath = join(options.directory, 'en-ko.sqlite')
    const bytes = readFileSync(filePath)
    if (bytes.length !== manifest.database.bytes || createHash('sha256').update(bytes).digest('hex') !== manifest.database.sha256) {
      throw new Error('Dictionary integrity check failed')
    }
    const opened = options.openDatabase ? options.openDatabase(filePath) : (() => {
      // Same lazy native-binding convention as the application's primary database.
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const Sqlite = require('better-sqlite3') as typeof import('better-sqlite3')
      return new Sqlite(filePath, { readonly: true, fileMustExist: true })
    })()
    try {
      opened.pragma('query_only = ON')
      const version = opened.prepare("SELECT value FROM metadata WHERE key = 'datasetVersion'").get() as { value: string } | undefined
      if (opened.pragma('user_version', { simple: true }) !== 1 || version?.value !== DATASET_VERSION) throw new Error('Invalid dictionary schema')
      db = opened
      return opened
    } catch (error) {
      opened.close()
      throw error
    }
  }

  function lookup(text: unknown): DictionaryLookupResult {
    const key = lookupKey(text)
    if (!key) return { status: 'not-found', entries: [] }
    const cached = cache.get(key)
    if (cached) return cached
    try {
      const database = open()
      // Keep an exact entry first even when it is also an inflection of another
      // word (read/reed). Include the lemma as an additional choice (running/run).
      const rows = database.prepare(`
        SELECT content FROM (
          SELECT e.id, e.content, 0 AS priority FROM entries e WHERE e.lookup_key = ?
          UNION ALL
          SELECT e.id, e.content, 1 AS priority FROM aliases a
          JOIN entries e ON e.lookup_key = a.headword_key
          WHERE a.lookup_key = ? AND e.lookup_key <> ?
        ) ORDER BY priority, id LIMIT ?
      `).all(key, key, key, MAX_RESULTS) as Array<{ content: string }>
      const entries = rows.map(row => JSON.parse(row.content) as DictionaryEntry)
      const result: DictionaryLookupResult = { status: entries.length ? 'found' : 'not-found', entries }
      if (cache.size >= MAX_CACHE) cache.delete(cache.keys().next().value!)
      cache.set(key, result)
      return result
    } catch {
      close()
      failed = true
      return { status: 'unavailable', entries: [] }
    }
  }

  return { lookup, dispose: close }
}
