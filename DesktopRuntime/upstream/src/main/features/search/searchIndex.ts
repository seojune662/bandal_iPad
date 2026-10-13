/**
 * Rebuildable full-text cache for course material.
 *
 * This deliberately owns its schema instead of using db/migrations: losing
 * the table only loses derived text, never student data. Notes and lightweight
 * text files are rebuilt from disk; PDF pages arrive from the renderer's
 * existing pdf.js text extraction path.
 */

import {
  existsSync,
  lstatSync,
  readdirSync,
  readFileSync,
  statSync
} from 'node:fs'
import { extname, join, posix } from 'node:path'
import type { Database } from 'better-sqlite3'
import type {
  SearchHit,
  SearchHitKind
} from '../../../shared/types/search'
import { ValidationError } from '../../db/errors'
import {
  requireId,
  requireInt,
  requireNonEmptyString,
  resolveInsideReal
} from '../../db/validate'

const SEARCH_TABLE = 'course_content_fts'
const DEFAULT_LIMIT = 30
const MAX_LIMIT = 100
const SNIPPET_MAX_CHARS = 160
const FTS_OVERFETCH_FACTOR = 8
const MAX_SCANNED_FILES = 5_000
const MAX_SCAN_DEPTH = 10
const MAX_TEXT_FILE_BYTES = 2 * 1024 * 1024

const NOTE_EXTENSIONS = new Set(['.md', '.markdown'])
const TEXT_EXTENSIONS = new Set([
  '.txt',
  '.csv',
  '.tsv',
  '.json',
  '.yml',
  '.yaml',
  '.xml',
  '.html',
  '.css',
  '.js',
  '.ts',
  '.tex',
  '.log',
  '.srt',
  '.vtt'
])

interface SearchRow {
  rel_path: string
  kind: SearchHitKind
  page: number | null
  body: string
}

interface TextDocument {
  relPath: string
  kind: 'note' | 'text'
  body: string
}

interface TextFileMetadata {
  mtimeMs: number
  size: number
}

interface TextDocumentScan {
  changed: TextDocument[]
  removed: string[]
  metadata: Map<string, TextFileMetadata>
}

interface SearchIndexDeps {
  refreshOnQuery?: boolean
  getCourseFolder: (courseId: string) => string
  readTextFile?: (path: string) => string
  logger?: Pick<Console, 'warn'>
}

export interface SearchIndex {
  /** Refreshes changed notes/text files for the course. */
  refreshTextFiles(courseId: string): void
  /** Worker refresh releases the shared database write lock between batches. */
  refreshInBackground(courseId: string): Promise<void>
  indexPdfPages(input: {
    courseId: string
    relPath: string
    pages: { page: number; text: string }[]
  }): void
  query(courseId: string, query: string, limit?: number): SearchHit[]
  /** Drops rows for files that no longer exist. */
  prune(courseId: string): void
}

/** NFC is mandatory for Korean IME/macOS interoperability. */
export function contentSearchKey(value: string): string {
  return value.normalize('NFC').toLowerCase()
}

function kindForTextFile(name: string): 'note' | 'text' | null {
  const extension = extname(name).toLowerCase()
  if (NOTE_EXTENSIONS.has(extension)) return 'note'
  return TEXT_EXTENSIONS.has(extension) ? 'text' : null
}

function scanTextDocuments(
  root: string,
  previousMetadata: Map<string, TextFileMetadata>,
  readTextFile: (path: string) => string,
  logger: Pick<Console, 'warn'>
): TextDocumentScan {
  const changed: TextDocument[] = []
  const removed = new Set<string>()
  const metadata = new Map(previousMetadata)
  const visitedTextPaths = new Set<string>()
  let scannedFiles = 0
  let fileLimitReached = false

  function walk(absDir: string, relDir: string, depth: number): void {
    let entries
    try {
      entries = readdirSync(absDir, { withFileTypes: true })
    } catch (error) {
      logger.warn(`[search-index] failed to read directory: ${absDir}`, error)
      return
    }

    for (const entry of entries) {
      if (fileLimitReached) return
      if (entry.name.startsWith('.')) continue
      const relPath = relDir === '' ? entry.name : posix.join(relDir, entry.name)
      const absPath = join(absDir, entry.name)
      if (entry.isDirectory()) {
        if (depth >= MAX_SCAN_DEPTH) {
          logger.warn(
            `[search-index] skipped directory beyond depth ${MAX_SCAN_DEPTH}: ${relPath}`
          )
          continue
        }
        walk(absPath, relPath, depth + 1)
        continue
      }
      if (!entry.isFile()) continue
      if (scannedFiles >= MAX_SCANNED_FILES) {
        fileLimitReached = true
        logger.warn(
          `[search-index] stopped after ${MAX_SCANNED_FILES} files in ${root}`
        )
        return
      }
      scannedFiles += 1
      const kind = kindForTextFile(entry.name)
      if (kind === null) continue
      visitedTextPaths.add(relPath)

      let fileMetadata: TextFileMetadata
      try {
        const stats = statSync(absPath)
        fileMetadata = { mtimeMs: stats.mtimeMs, size: stats.size }
      } catch (error) {
        logger.warn(`[search-index] failed to stat text file: ${absPath}`, error)
        continue
      }

      const previous = previousMetadata.get(relPath)
      const isUnchanged =
        previous?.mtimeMs === fileMetadata.mtimeMs &&
        previous.size === fileMetadata.size
      if (isUnchanged) continue

      if (fileMetadata.size > MAX_TEXT_FILE_BYTES) {
        logger.warn(
          `[search-index] skipped text file over ${MAX_TEXT_FILE_BYTES} bytes: ${relPath}`
        )
        metadata.set(relPath, fileMetadata)
        removed.add(relPath)
        continue
      }

      try {
        changed.push({
          relPath,
          kind,
          body: readTextFile(absPath).normalize('NFC')
        })
        metadata.set(relPath, fileMetadata)
      } catch (error) {
        // A file may disappear or become unreadable during the scan. Search is
        // a cache refresh, so one bad file must not block the user's query.
        logger.warn(`[search-index] failed to read text file: ${absPath}`, error)
      }
    }
  }

  if (existsSync(root)) walk(root, '', 0)

  // A scan cap can leave live paths unvisited, so absence from this scan alone
  // is not proof of deletion. Verify cached paths before removing their rows.
  for (const relPath of previousMetadata.keys()) {
    if (visitedTextPaths.has(relPath) || isLiveRegularFile(root, relPath)) continue
    metadata.delete(relPath)
    removed.add(relPath)
  }

  return { changed, removed: [...removed], metadata }
}

function quoteFtsPhrase(value: string): string {
  return `"${value.replace(/"/g, '""')}"`
}

function occurrenceCount(haystack: string, needle: string): number {
  let count = 0
  let from = 0
  while (count < 50) {
    const found = haystack.indexOf(needle, from)
    if (found < 0) break
    count += 1
    from = found + Math.max(needle.length, 1)
  }
  return count
}

function snippetAround(body: string, matchAt: number, matchLength: number): string {
  const ellipsis = '…'
  const contextBudget = SNIPPET_MAX_CHARS - ellipsis.length * 2
  let start = Math.max(0, matchAt - Math.floor((contextBudget - matchLength) / 2))
  let end = Math.min(body.length, start + contextBudget)
  if (end === body.length) start = Math.max(0, end - contextBudget)

  const prefix = start > 0 ? ellipsis : ''
  const suffix = end < body.length ? ellipsis : ''
  const context = body
    .slice(start, end)
    .replace(/\s+/g, ' ')
    .trim()
  return `${prefix}${context}${suffix}`.slice(0, SNIPPET_MAX_CHARS)
}

function rowsToHits(rows: SearchRow[], needle: string): SearchHit[] {
  const hits: SearchHit[] = []
  for (const row of rows) {
    const key = contentSearchKey(row.body)
    const matchAt = key.indexOf(needle)
    if (matchAt < 0) continue
    const occurrences = occurrenceCount(key, needle)
    hits.push({
      kind: row.kind,
      relPath: row.rel_path,
      page: row.page,
      snippet: snippetAround(row.body, matchAt, needle.length),
      score:
        occurrences * 100 +
        Math.max(0, 50 - Math.floor(matchAt / 20)) +
        (matchAt === 0 ? 25 : 0)
    })
  }
  return hits
}

function validateLimit(limit: number | undefined): number {
  if (limit === undefined) return DEFAULT_LIMIT
  return Math.min(requireInt(limit, 'limit', 1), MAX_LIMIT)
}

function isLiveRegularFile(root: string, relPath: string): boolean {
  try {
    return lstatSync(resolveInsideReal(root, relPath)).isFile()
  } catch {
    return false
  }
}

/**
 * Creates a course-body index using FTS5's trigram tokenizer.
 *
 * better-sqlite3 13.0.2 updated its bundled SQLite to 3.53.4; the runtime
 * dependency and Node test alias now share the 13.x line. SQLite 3.53.4
 * includes FTS5 trigram support. Shorter than three-character searches use
 * the normalized JS fallback below because a trigram index cannot produce
 * tokens for them.
 */
export function createSearchIndex(
  db: Database,
  deps: SearchIndexDeps
): SearchIndex {
  db.exec(
    `CREATE VIRTUAL TABLE IF NOT EXISTS ${SEARCH_TABLE} USING fts5(
       course_id UNINDEXED,
       rel_path UNINDEXED,
       kind UNINDEXED,
       page UNINDEXED,
       body,
       tokenize='trigram'
     )`
  )

  // This is a derived cache, but its folder binding must survive restarts:
  // the same course/relative path can point to unrelated content after relink.
  db.exec('CREATE TABLE IF NOT EXISTS course_content_roots (course_id TEXT PRIMARY KEY, folder TEXT NOT NULL)')
  const cachedRoots = new Map<string, string>()
  const selectRoot = db.prepare('SELECT folder FROM course_content_roots WHERE course_id = ?')
  const resetRoot = db.transaction((id: string, folder: string) => {
    db.prepare(`DELETE FROM ${SEARCH_TABLE} WHERE course_id = ?`).run(id)
    db.prepare('INSERT OR REPLACE INTO course_content_roots (course_id, folder) VALUES (?, ?)').run(id, folder)
  })
  function courseRoot(id: string): string {
    const folder = deps.getCourseFolder(id)
    const stored = selectRoot.get(id) as { folder: string } | undefined
    if (stored?.folder !== folder) resetRoot(id, folder)
    if (cachedRoots.get(id) !== folder || stored?.folder !== folder) textFileMetadataByCourse.delete(id)
    cachedRoots.set(id, folder)
    return folder
  }

  const insert = db.prepare(
    `INSERT INTO ${SEARCH_TABLE} (course_id, rel_path, kind, page, body)
     VALUES (?, ?, ?, ?, ?)`
  )
  const removeTextFile = db.prepare(
    `DELETE FROM ${SEARCH_TABLE}
     WHERE course_id = ? AND rel_path = ? AND kind IN ('note', 'text')`
  )
  const textFileMetadataByCourse = new Map<
    string,
    Map<string, TextFileMetadata>
  >()
  const readTextFile =
    deps.readTextFile ?? ((path: string) => readFileSync(path, 'utf8'))
  const logger = deps.logger ?? console

  function* refreshTextFileBatches(courseId: string): Generator<void> {
    const id = requireId(courseId, 'courseId')
    const root = courseRoot(id)
    const current = (): boolean => deps.getCourseFolder(id) === root && cachedRoots.get(id) === root
    const previousMetadata =
      textFileMetadataByCourse.get(id) ?? new Map<string, TextFileMetadata>()
    const scan = scanTextDocuments(
      root,
      previousMetadata,
      readTextFile,
      logger
    )

    for (let offset = 0; offset < scan.removed.length; offset += 100) {
      if (!current()) return
      db.transaction(() => {
        for (const relPath of scan.removed.slice(offset, offset + 100)) removeTextFile.run(id, relPath)
      })()
      yield
    }
    for (let offset = 0; offset < scan.changed.length;) {
      if (!current()) return
      const batch: TextDocument[] = []
      let chars = 0
      while (offset < scan.changed.length && batch.length < 100 && chars < 256_000) {
        const document = scan.changed[offset++]!
        batch.push(document)
        chars += document.body.length
      }
      db.transaction(() => {
        for (const document of batch) {
          removeTextFile.run(id, document.relPath)
          insert.run(id, document.relPath, document.kind, null, document.body)
        }
      })()
      yield
    }
    if (current()) textFileMetadataByCourse.set(id, scan.metadata)
  }

  function refreshTextFiles(courseId: string): void {
    for (const _batch of refreshTextFileBatches(courseId)) { /* synchronous API */ }
  }

  function indexPdfPages(input: {
    courseId: string
    relPath: string
    pages: { page: number; text: string }[]
  }): void {
    const courseId = requireId(input.courseId, 'courseId')
    const relPath = requireNonEmptyString(input.relPath, 'relPath')
    const root = courseRoot(courseId)
    const absPath = resolveInsideReal(root, relPath)
    if (extname(relPath).toLowerCase() !== '.pdf') {
      throw new ValidationError('relPath must point to a PDF')
    }
    if (!existsSync(absPath) || !lstatSync(absPath).isFile()) {
      throw new ValidationError('relPath must point to an existing PDF')
    }
    if (!Array.isArray(input.pages)) {
      throw new ValidationError('pages must be an array')
    }

    const pages = new Map<number, string>()
    for (const entry of input.pages) {
      const page = requireInt(entry?.page, 'page', 1)
      if (typeof entry?.text !== 'string') {
        throw new ValidationError('page text must be a string')
      }
      pages.set(page, entry.text.normalize('NFC'))
    }
    if (pages.size === 0) return

    const replacePages = db.transaction(() => {
      const remove = db.prepare(
        `DELETE FROM ${SEARCH_TABLE}
         WHERE course_id = ? AND rel_path = ? AND kind = 'pdf' AND page = ?`
      )
      for (const [page, text] of pages) {
        remove.run(courseId, relPath, page)
        if (text.length > 0) insert.run(courseId, relPath, 'pdf', page, text)
      }
    })
    replacePages()
  }

  function* pruneBatches(courseId: string): Generator<void> {
    const id = requireId(courseId, 'courseId')
    const root = courseRoot(id)
    const rows = db
      .prepare(
        `SELECT DISTINCT rel_path FROM ${SEARCH_TABLE} WHERE course_id = ?`
      )
      .all(id) as { rel_path: string }[]
    const stale = rows
      .map((row) => row.rel_path)
      .filter((relPath) => !isLiveRegularFile(root, relPath))
    if (stale.length === 0) return
    const remove = db.prepare(
      `DELETE FROM ${SEARCH_TABLE} WHERE course_id = ? AND rel_path = ?`
    )
    for (let offset = 0; offset < stale.length; offset += 100) {
      db.transaction(() => {
        for (const relPath of stale.slice(offset, offset + 100)) remove.run(id, relPath)
      })()
      yield
    }
  }

  function prune(courseId: string): void {
    for (const _batch of pruneBatches(courseId)) { /* synchronous API */ }
  }

  async function refreshInBackground(courseId: string): Promise<void> {
    for (const _batch of refreshTextFileBatches(courseId)) {
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
    for (const _batch of pruneBatches(courseId)) {
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
  }

  function query(courseId: string, queryText: string, limit?: number): SearchHit[] {
    const id = requireId(courseId, 'courseId')
    const needle = contentSearchKey(
      requireNonEmptyString(queryText, 'query').trim()
    )
    const resolvedLimit = validateLimit(limit)
    courseRoot(id)

    // Text files are cheap and mutable outside Bandal, so every search gets a
    // fresh view. Pruning also removes cached PDF pages after an out-of-band
    // delete without ever reparsing a PDF in main.
    if (deps.refreshOnQuery !== false) { refreshTextFiles(id); prune(id) }

    let rows: SearchRow[] = []
    if (needle.length >= 3) {
      rows = db
        .prepare(
          `SELECT rel_path, kind, page, body
           FROM ${SEARCH_TABLE}
           WHERE ${SEARCH_TABLE} MATCH ? AND course_id = ?
           ORDER BY bm25(${SEARCH_TABLE}) ASC
           LIMIT ?`
        )
        .all(
          quoteFtsPhrase(needle),
          id,
          Math.min(resolvedLimit * FTS_OVERFETCH_FACTOR, MAX_LIMIT * FTS_OVERFETCH_FACTOR)
        ) as SearchRow[]
    }

    // Trigram has no tokens below three characters. The same fallback also
    // covers punctuation-heavy phrases that FTS5 chooses not to tokenize.
    if (rows.length === 0) {
      rows = db
        .prepare(
          `SELECT rel_path, kind, page, body
           FROM ${SEARCH_TABLE}
           WHERE course_id = ?`
        )
        .all(id) as SearchRow[]
    }

    return rowsToHits(rows, needle)
      .sort(
        (a, b) =>
          b.score - a.score ||
          a.relPath.localeCompare(b.relPath, 'ko') ||
          (a.page ?? 0) - (b.page ?? 0)
      )
      .slice(0, resolvedLimit)
  }

  return { refreshTextFiles, refreshInBackground, indexPdfPages, query, prune }
}
