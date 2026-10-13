import { readFileSync, statSync } from 'node:fs'
import type { Database } from 'better-sqlite3'
import { isTabDescriptor } from '../../../shared/tabs'
import { ValidationError } from '../../db/errors'
import {
  assertRealInside,
  requireId,
  requireNonEmptyString,
  resolveInside
} from '../../db/validate'
import { writeFileAtomic } from '../../lib/atomicWrite'
import {
  WIKILINK_RE,
  formatWikilink,
  parseWikilink,
  wikilinkKey,
  wikilinkStem
} from '../../../shared/wikilink'
import { createMaterialLink, parseMaterialLink } from '../link/materialLink'
import {
  parsePdfPageNote,
  serializePdfPageNote,
  sourceRelPath
} from '../../../shared/pdfPageNote'

const PATH_TABLES = [
  'annotations',
  'pdf_drawings',
  'media_progress',
  'pdf_view_state'
] as const
const UPDATED_TABLES = [...PATH_TABLES, 'favorites', 'material_links'] as const

type UpdatedTable = (typeof UPDATED_TABLES)[number]

export interface RepointMaterialPathInput {
  db: Database
  courseFolder: string
  courseId: string
  fromRelPath: string
  toRelPath: string
  isDirectory: boolean
  /**
   * Sources captured from content_links before the filesystem rename.
   *
   * Repository hooks run immediately after a successful rename and can omit
   * this because content_links is still the pre-rename derived cache. Callers
   * that split preparation from mutation can pass the explicit snapshot so a
   * concurrent cache refresh cannot replace it between those two phases.
   */
  candidateNoteRelPaths?: readonly string[]
}

export interface RepointMaterialPathResult {
  updatedRows: Record<UpdatedTable, number>
  rewrittenNotes: string[]
  failures: string[]
}

interface JsonRow {
  id: string
  descriptor_json: string
}

interface MaterialLinkRow {
  id: string
  source_json: string
  target_json: string
}

interface RelPathRow {
  row_id: number
  rel_path: string
}

interface DrawingDataRow {
  id: string
  data_json: string
}

interface JsonRecord {
  [key: string]: unknown
}

interface PathPayloadJson {
  value: JsonRecord
  payload: JsonRecord
}

function isRecord(value: unknown): value is JsonRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Matches the derived link index: NFC/case folding is comparison-only. */
function pathKey(value: string): string {
  return value.normalize('NFC').toLowerCase()
}

function repointedPath(
  candidate: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): string | null {
  if (pathKey(candidate) === pathKey(fromRelPath)) return toRelPath
  if (!isDirectory) return null

  // Compare complete path segments so an NFD spelling can retain its suffix
  // without slicing at an NFC string length (the code-point counts may differ).
  const fromParts = fromRelPath.split('/')
  const candidateParts = candidate.split('/')
  if (candidateParts.length <= fromParts.length) return null
  const candidatePrefix = candidateParts.slice(0, fromParts.length).join('/')
  if (pathKey(candidatePrefix) !== pathKey(fromRelPath)) return null
  return `${toRelPath}/${candidateParts.slice(fromParts.length).join('/')}`
}

function materialUrlPattern(): RegExp {
  return /bandal:\/\/material\/?\?[^\s)>]+/g
}

function basenameOf(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

function extensionOf(relPath: string): string {
  const name = basenameOf(relPath)
  const dot = name.lastIndexOf('.')
  return dot <= 0 ? '' : name.slice(dot)
}

function stripNoteExtension(value: string): string {
  return value.replace(/\.(?:md|markdown)$/iu, '')
}

/**
 * The new target for a wikilink, written in the SAME form the student used:
 * a bare name stays a bare name, a path stays a path, and an omitted
 * extension stays omitted (`[[Chap1]]` → `[[Chapter 1]]`, never
 * `[[Chapter 1.md]]`). Null when the link does not point at the renamed file.
 */
export function repointedWikilinkTarget(
  target: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): string | null {
  const key = wikilinkKey(target)
  const isPathForm = target.includes('/')

  if (isDirectory) {
    if (!isPathForm) return null
    const next = repointedPath(target, fromRelPath, toRelPath, true)
    return next === null ? null : next
  }

  const fromExtension = extensionOf(fromRelPath).toLowerCase()
  const wroteExtension =
    fromExtension.length > 0 &&
    target.normalize('NFC').trim().toLowerCase().endsWith(fromExtension)
  const withWrittenExtension = (next: string): string =>
    wroteExtension ? next : stripNoteExtension(next)

  if (isPathForm) {
    if (key !== wikilinkKey(fromRelPath)) return null
    return withWrittenExtension(toRelPath)
  }
  const matchesBasename =
    key === wikilinkKey(basenameOf(fromRelPath)) ||
    key === wikilinkKey(wikilinkStem(fromRelPath))
  if (!matchesBasename) return null
  const toBasename = basenameOf(toRelPath)
  // A bare `[[Chap1]]` for `Chap1.pdf` was written as the stem: keep it so.
  const wroteStem = !wroteExtension && key === wikilinkKey(wikilinkStem(fromRelPath))
  return wroteStem ? wikilinkStem(toBasename) : withWrittenExtension(toBasename)
}

function tableExists(db: Database, table: string): boolean {
  return db
    .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(table) !== undefined
}

/**
 * `onPathChanged` runs immediately after rename. At that point content_links
 * still represents the pre-rename scan, so capture its source refs before any
 * DB rewrite or later index refresh. A moved source note is mapped below with
 * the same exact/prefix rule; this is what keeps a self-referencing note alive.
 */
export function collectRepointNoteCandidates(
  input: Pick<
    RepointMaterialPathInput,
    'db' | 'courseId' | 'fromRelPath' | 'toRelPath' | 'isDirectory'
  >
): string[] {
  if (!tableExists(input.db, 'content_links')) return []
  const rows = input.db
    .prepare(
      `SELECT source_ref, target_path
         FROM content_links
        WHERE course_id = ? AND source_kind = 'note'`
    )
    .all(input.courseId) as { source_ref: string; target_path: string }[]
  const notes = new Set<string>()
  for (const row of rows) {
    if (
      repointedPath(
        row.target_path,
        input.fromRelPath,
        input.toRelPath,
        input.isDirectory
      ) === null
    ) {
      continue
    }
    notes.add(
      repointedPath(
        row.source_ref,
        input.fromRelPath,
        input.toRelPath,
        input.isDirectory
      ) ?? row.source_ref
    )
  }
  if (tableExists(input.db, 'material_links')) {
    const pageNotes = input.db.prepare(
      `SELECT source_json, target_json FROM material_links
        WHERE course_id = ? AND kind = 'pdf-page-note'`
    ).all(input.courseId) as Array<{ source_json: string; target_json: string }>
    for (const row of pageNotes) {
      try {
        const source = parsePayloadJson(row.source_json)
        const target = parsePayloadJson(row.target_json)
        const sourcePath = source.payload['relPath']
        const targetPath = target.payload['relPath']
        if (
          typeof sourcePath !== 'string' ||
          typeof targetPath !== 'string' ||
          repointedPath(
            sourcePath,
            input.fromRelPath,
            input.toRelPath,
            input.isDirectory
          ) === null
        ) continue
        notes.add(
          repointedPath(
            targetPath,
            input.fromRelPath,
            input.toRelPath,
            input.isDirectory
          ) ?? targetPath
        )
      } catch {
        // Malformed rows are reported by the database rewrite pass.
      }
    }
  }
  return [...notes]
}

function parsePayloadJson(json: string): PathPayloadJson {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    throw new ValidationError('value must be valid JSON')
  }
  if (!isRecord(value) || !isRecord(value['payload'])) {
    throw new ValidationError('value must contain an object payload')
  }
  const relPath = value['payload']['relPath']
  if (relPath !== undefined && (typeof relPath !== 'string' || relPath.length === 0)) {
    throw new ValidationError('payload.relPath must be a non-empty string')
  }
  return { value, payload: value['payload'] }
}

function rewritePayload(
  parsed: PathPayloadJson,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): string | null {
  const relPath = parsed.payload['relPath']
  if (typeof relPath !== 'string') return null
  const next = repointedPath(relPath, fromRelPath, toRelPath, isDirectory)
  if (next === null) return null
  parsed.payload['relPath'] = next
  return JSON.stringify(parsed.value)
}

function warning(table: string, id: string, error: unknown): void {
  const message = error instanceof Error ? error.message : String(error)
  console.warn(`[links] skipped invalid ${table} row "${id}": ${message}`)
}

function rewriteFavorites(
  db: Database,
  courseId: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): number {
  const rows = db
    .prepare(
      `SELECT id, descriptor_json FROM favorites
        WHERE course_id = ? OR course_id IS NULL`
    )
    .all(courseId) as JsonRow[]
  const update = db.prepare('UPDATE favorites SET descriptor_json = ? WHERE id = ?')
  let count = 0
  for (const row of rows) {
    let json: string | null
    try {
      const parsed = parsePayloadJson(row.descriptor_json)
      if (!isTabDescriptor(parsed.value)) {
        throw new ValidationError('descriptor_json must contain a valid TabDescriptor')
      }
      // App-global favorites have a NULL row course_id; their descriptor is
      // the only authority for which course owns the path.
      if (parsed.payload['courseId'] !== courseId) continue
      json = rewritePayload(parsed, fromRelPath, toRelPath, isDirectory)
    } catch (error) {
      warning('favorites', row.id, error)
      continue
    }
    if (json !== null) count += update.run(json, row.id).changes
  }
  return count
}

function rewriteMaterialLinks(
  db: Database,
  courseId: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): number {
  const rows = db
    .prepare(
      `SELECT id, source_json, target_json
         FROM material_links WHERE course_id = ?`
    )
    .all(courseId) as MaterialLinkRow[]
  const update = db.prepare(
    'UPDATE material_links SET source_json = ?, target_json = ? WHERE id = ?'
  )
  let count = 0
  for (const row of rows) {
    let sourceJson: string
    let targetJson: string
    try {
      // Validate both halves before changing either: one malformed endpoint
      // makes the row indivisible, so the valid half must remain untouched too.
      const source = parsePayloadJson(row.source_json)
      const target = parsePayloadJson(row.target_json)
      if (!isTabDescriptor(source.value) || !isTabDescriptor(target.value)) {
        throw new ValidationError(
          'source_json and target_json must contain valid TabDescriptors'
        )
      }
      sourceJson =
        rewritePayload(source, fromRelPath, toRelPath, isDirectory) ?? row.source_json
      targetJson =
        rewritePayload(target, fromRelPath, toRelPath, isDirectory) ?? row.target_json
    } catch (error) {
      warning('material_links', row.id, error)
      continue
    }
    if (sourceJson !== row.source_json || targetJson !== row.target_json) {
      count += update.run(sourceJson, targetJson, row.id).changes
    }
  }
  return count
}

function updateRelPathTables(
  db: Database,
  courseId: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean,
  counts: Record<UpdatedTable, number>
): void {
  const escapedPrefix = fromRelPath.replace(/[\\%_]/g, '\\$&') + '/%'
  for (const table of PATH_TABLES) {
    // SQLite has no built-in Unicode normalization. Capture only the rows
    // that the byte-exact statements below cannot reach, then update those by
    // rowid with the same NFC comparison used by linkIndex.
    const normalizedOnly = (db
      .prepare(`SELECT rowid AS row_id, rel_path FROM ${table} WHERE course_id = ?`)
      .all(courseId) as RelPathRow[])
      .map((row) => ({
        ...row,
        next: repointedPath(row.rel_path, fromRelPath, toRelPath, isDirectory)
      }))
      .filter(
        (row): row is RelPathRow & { next: string } =>
          row.next !== null &&
          row.next !== row.rel_path &&
          row.rel_path !== fromRelPath &&
          !(isDirectory && row.rel_path.startsWith(`${fromRelPath}/`))
      )

    counts[table] += db
      .prepare(`UPDATE ${table} SET rel_path = ? WHERE course_id = ? AND rel_path = ?`)
      .run(toRelPath, courseId, fromRelPath).changes
    if (isDirectory) {
      counts[table] += db
        .prepare(
          `UPDATE ${table}
              SET rel_path = ? || substr(rel_path, length(?) + 1)
            WHERE course_id = ? AND rel_path LIKE ? ESCAPE '\\'
              AND substr(rel_path, 1, length(?)) = ?`
        )
        .run(
          toRelPath,
          fromRelPath,
          courseId,
          escapedPrefix,
          fromRelPath,
          fromRelPath
        ).changes
    }

    const updateNormalized = db.prepare(
      `UPDATE ${table} SET rel_path = ? WHERE rowid = ?`
    )
    for (const row of normalizedOnly) {
      counts[table] += updateNormalized.run(row.next, row.row_id).changes
    }
  }
}

/**
 * Images placed on PDFs keep their course-relative material path inside
 * pdf_drawings.data_json. Updating only pdf_drawings.rel_path retargets the
 * PDF that owns the drawing, but leaves the image source pointing at the old
 * filename. Rewrite that nested reference in the same transaction as every
 * other rename repair so reopening (or refreshing) the PDF cannot lose it.
 */
function rewritePdfDrawingImageSources(
  db: Database,
  courseId: string,
  fromRelPath: string,
  toRelPath: string,
  isDirectory: boolean
): number {
  if (!tableExists(db, 'pdf_drawings')) return 0
  const rows = db
    .prepare(
      `SELECT id, data_json
         FROM pdf_drawings
        WHERE course_id = ? AND kind = 'image'`
    )
    .all(courseId) as DrawingDataRow[]
  const update = db.prepare(
    'UPDATE pdf_drawings SET data_json = ?, updated_at = ? WHERE id = ?'
  )
  let count = 0
  for (const row of rows) {
    try {
      const data: unknown = JSON.parse(row.data_json)
      if (!isRecord(data)) throw new ValidationError('data_json must be an object')
      const image = data['image']
      if (!isRecord(image)) continue
      const relPath = image['relPath']
      if (typeof relPath !== 'string' || relPath.length === 0) continue
      const next = repointedPath(relPath, fromRelPath, toRelPath, isDirectory)
      if (next === null) continue
      image['relPath'] = next
      image['label'] = basenameOf(next)
      count += update.run(JSON.stringify(data), new Date().toISOString(), row.id).changes
    } catch (error) {
      warning('pdf_drawings', row.id, error)
    }
  }
  return count
}

function rewriteCandidateNotes(
  input: RepointMaterialPathInput,
  candidates: readonly string[]
): Pick<RepointMaterialPathResult, 'rewrittenNotes' | 'failures'> {
  const rewrittenNotes: string[] = []
  const failures: string[] = []
  for (const relPath of candidates) {
    try {
      const absPath = resolveInside(input.courseFolder, relPath)
      assertRealInside(input.courseFolder, absPath)
      const mode = statSync(absPath).mode
      if ((mode & 0o222) === 0) {
        throw new Error('note is read-only')
      }
      const markdown = readFileSync(absPath, 'utf8')
      let changed = false
      let rewritten = markdown.replace(materialUrlPattern(), (href) => {
        const parsed = parseMaterialLink(href)
        if (parsed === null) return href
        const relPathNext = repointedPath(
          parsed.relPath,
          input.fromRelPath,
          input.toRelPath,
          input.isDirectory
        )
        if (relPathNext === null) return href
        changed = true
        return createMaterialLink({ ...parsed, relPath: relPathNext })
      }).replace(WIKILINK_RE, (text) => {
        const parsed = parseWikilink(text)
        if (parsed === null) return text
        const targetNext = repointedWikilinkTarget(
          parsed.target,
          input.fromRelPath,
          input.toRelPath,
          input.isDirectory
        )
        if (targetNext === null || targetNext === parsed.target) return text
        changed = true
        return formatWikilink({ ...parsed, target: targetNext })
      })
      const pageNote = parsePdfPageNote(rewritten)
      if (pageNote !== null) {
        const nextSource = repointedPath(
          sourceRelPath(pageNote.manifest),
          input.fromRelPath,
          input.toRelPath,
          input.isDirectory
        )
        if (nextSource !== null) {
          pageNote.manifest.source = encodeURIComponent(nextSource)
          rewritten = serializePdfPageNote(pageNote)
          changed = true
        }
      }
      if (!changed) continue
      writeFileAtomic(absPath, rewritten, { mode })
      rewrittenNotes.push(relPath)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      failures.push(`${relPath}: ${message}`)
      console.warn(`[links] failed to rewrite note "${relPath}": ${message}`)
    }
  }
  return { rewrittenNotes, failures }
}

export function repointMaterialPath(
  input: RepointMaterialPathInput
): RepointMaterialPathResult {
  const courseId = requireId(input.courseId, 'courseId')
  const fromRelPath = requireNonEmptyString(input.fromRelPath, 'fromRelPath')
  const toRelPath = requireNonEmptyString(input.toRelPath, 'toRelPath')
  if (typeof input.isDirectory !== 'boolean') {
    throw new ValidationError('isDirectory must be a boolean')
  }
  assertRealInside(input.courseFolder, resolveInside(input.courseFolder, fromRelPath))
  assertRealInside(input.courseFolder, resolveInside(input.courseFolder, toRelPath))

  const normalizedInput = { ...input, courseId, fromRelPath, toRelPath }
  const candidates = input.candidateNoteRelPaths === undefined
    ? collectRepointNoteCandidates(normalizedInput)
    : [...new Set(input.candidateNoteRelPaths)]
  const repointDatabase = input.db.transaction(() => {
    const updatedRows = Object.fromEntries(
      UPDATED_TABLES.map((table) => [table, 0])
    ) as Record<UpdatedTable, number>
    updateRelPathTables(
      input.db,
      courseId,
      fromRelPath,
      toRelPath,
      input.isDirectory,
      updatedRows
    )
    updatedRows.pdf_drawings += rewritePdfDrawingImageSources(
      input.db,
      courseId,
      fromRelPath,
      toRelPath,
      input.isDirectory
    )
    updatedRows.favorites = rewriteFavorites(
      input.db,
      courseId,
      fromRelPath,
      toRelPath,
      input.isDirectory
    )
    updatedRows.material_links = rewriteMaterialLinks(
      input.db,
      courseId,
      fromRelPath,
      toRelPath,
      input.isDirectory
    )
    return updatedRows
  })

  const updatedRows = repointDatabase()
  const notes = rewriteCandidateNotes(normalizedInput, candidates)
  return { updatedRows, ...notes }
}
