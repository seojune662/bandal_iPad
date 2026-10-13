/**
 * Rebuildable reverse-link cache for course content.
 *
 * Like search's `course_content_fts`, this table deliberately lives outside
 * migrations: note markdown and local whiteboard clips are the source of
 * truth, so losing the table only costs one rescan and never loses user data.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { extname, join, posix } from 'node:path'
import type { Database } from 'better-sqlite3'
import type {
  DetailedMaterialBacklink,
  MaterialBacklink,
  MaterialBacklinkGroup,
  MaterialBacklinks
} from '../../../shared/types/link'
import { requireId, requireNonEmptyString } from '../../db/validate'
import {
  WIKILINK_RE,
  createWikilinkResolver,
  parseWikilink
} from '../../../shared/wikilink'
import { parseMaterialLink } from '../link/materialLink'

const LINK_TABLE = 'content_links'
const NOTE_EXTENSIONS = new Set(['.md', '.markdown'])
/**
 * Derived cache: an older table without this column is dropped and rebuilt
 * on startup (`createLinkIndex`) instead of migrated — one rescan is the
 * whole cost.
 */
const LINK_KIND_COLUMN = 'link_kind'

/**
 * Kept in sync with `features/link/linkService.ts` because that module does
 * not export its pattern. Return a fresh global RegExp for every document so
 * `lastIndex` state can never leak between scans.
 */
function materialLinkUrlPattern(): RegExp {
  return /bandal:\/\/material\/?\?[^\s)>]+/g
}

export interface LinkIndexDeps {
  db: Database
  getCourseFolder: (courseId: string) => string
}

// 타입은 그래프 뷰(renderer)와 공유하기 위해 shared/types/link.ts 로 이동했다.
export type {
  MaterialBacklinkGroup
} from '../../../shared/types/link'

export interface LinkIndex {
  /** Rescans the course, then returns everything that cites this material. */
  forMaterial(courseId: string, relPath: string): MaterialBacklinks
  /** Rescans the course, grouped by cited material. */
  allForCourse(courseId: string): MaterialBacklinkGroup[]
}

type SourceKind = 'note' | 'whiteboard'
type LinkKind = NonNullable<DetailedMaterialBacklink['linkKind']>

interface CourseFile {
  relPath: string
  absPath: string
}

interface CourseScan {
  files: CourseFile[]
  pathLookup: Map<string, string>
}

interface PendingLink {
  sourceKind: SourceKind
  sourceRef: string
  sourceLabel: string
  targetPath: string
  targetPage: number | null
  detail: string
  linkKind: LinkKind
}

interface LinkRow {
  source_kind: SourceKind
  source_ref: string
  source_label: string
  target_path: string
  target_page: number | null
  detail: string | null
  link_kind: string | null
}

interface ClipPayload {
  relPath: string
  page: number
  label: string
}

interface WhiteboardClipRow {
  board_id: string
  title: string
  data_json: string
}

/** NFC is a comparison form only; filesystem paths must keep their spelling. */
function pathKey(value: string): string {
  return value.normalize('NFC').toLowerCase()
}

function scanCourseFiles(root: string): CourseScan {
  const files: CourseFile[] = []
  const pathLookup = new Map<string, string>()

  function walk(absDir: string, relDir: string): void {
    let entries
    try {
      entries = readdirSync(absDir, { withFileTypes: true })
    } catch {
      return
    }

    for (const entry of entries) {
      const relPath = relDir === '' ? entry.name : posix.join(relDir, entry.name)
      const absPath = join(absDir, entry.name)
      if (entry.isDirectory()) {
        // `.bandal/` is generated context, not a student's source note. The
        // same rule also keeps editor/tool metadata out of the index.
        if (!entry.name.startsWith('.')) walk(absPath, relPath)
        continue
      }
      if (!entry.isFile()) continue

      files.push({ relPath, absPath })
      // Exact spelling wins when a filesystem happens to contain two paths
      // that collapse to the same NFC/case-insensitive comparison key.
      pathLookup.set(relPath, relPath)
      const normalized = pathKey(relPath)
      if (!pathLookup.has(normalized)) pathLookup.set(normalized, relPath)
    }
  }

  walk(root, '')
  return { files, pathLookup }
}

function actualTargetPath(
  pathLookup: ReadonlyMap<string, string>,
  requestedPath: string
): string | null {
  return pathLookup.get(requestedPath) ?? pathLookup.get(pathKey(requestedPath)) ?? null
}

function linksFromNotes(scan: CourseScan): PendingLink[] {
  const links: PendingLink[] = []
  // One stem/path map per scan so every `[[…]]` resolves in O(1).
  const wikilinks = createWikilinkResolver(scan.files)
  for (const file of scan.files) {
    if (!NOTE_EXTENSIONS.has(extname(file.relPath).toLowerCase())) continue

    let markdown: string
    try {
      // Highlight links are appended, so the whole document must be read.
      markdown = readFileSync(file.absPath, 'utf8')
    } catch {
      // Files may disappear or become unreadable during a cache refresh.
      continue
    }

    for (const match of markdown.matchAll(materialLinkUrlPattern())) {
      const parsed = parseMaterialLink(match[0])
      if (parsed === null) continue
      const targetPath = actualTargetPath(scan.pathLookup, parsed.relPath)
      // A stale link to a removed material is not a live edge.
      if (targetPath === null) continue
      links.push({
        sourceKind: 'note',
        sourceRef: file.relPath,
        sourceLabel: posix.basename(file.relPath),
        targetPath,
        targetPage: parsed.page,
        detail: parsed.annotationId ?? '',
        linkKind: 'material'
      })
    }

    for (const match of markdown.matchAll(WIKILINK_RE)) {
      const parsed = parseWikilink(match[0])
      if (parsed === null) continue
      const targetPath = wikilinks.resolve(parsed.target)
      // An unresolved wikilink is a note-to-be, not an edge — same as a
      // stale bandal:// link.
      if (targetPath === null) continue
      links.push({
        sourceKind: 'note',
        sourceRef: file.relPath,
        sourceLabel: posix.basename(file.relPath),
        targetPath,
        targetPage: null,
        detail: '',
        linkKind: 'wikilink'
      })
    }
  }
  return links
}

function parseClipPayload(dataJson: string): ClipPayload | null {
  try {
    const data: unknown = JSON.parse(dataJson)
    if (data === null || typeof data !== 'object' || Array.isArray(data)) return null
    const clip = (data as { clip?: unknown }).clip
    if (clip === null || typeof clip !== 'object' || Array.isArray(clip)) return null
    const candidate = clip as Partial<ClipPayload>
    if (
      typeof candidate.relPath !== 'string' ||
      candidate.relPath.length === 0 ||
      !Number.isSafeInteger(candidate.page) ||
      (candidate.page ?? 0) < 1 ||
      typeof candidate.label !== 'string'
    ) {
      return null
    }
    return {
      relPath: candidate.relPath,
      page: candidate.page as number,
      label: candidate.label
    }
  } catch {
    return null
  }
}

function linksFromWhiteboards(
  db: Database,
  courseId: string,
  scan: CourseScan
): PendingLink[] {
  const rows = db
    .prepare(
      `SELECT b.id AS board_id, b.title, s.data_json
         FROM whiteboards b
         JOIN whiteboard_local_shapes s ON s.board_id = b.id
        WHERE b.course_id = ?
          AND b.deleted_at IS NULL
          AND s.deleted_at IS NULL
          AND s.kind = 'clip'
        ORDER BY b.sort_order ASC, b.id ASC, s.created_at ASC, s.id ASC`
    )
    .all(courseId) as WhiteboardClipRow[]

  const links: PendingLink[] = []
  for (const row of rows) {
    const clip = parseClipPayload(row.data_json)
    if (clip === null) continue
    const targetPath = actualTargetPath(scan.pathLookup, clip.relPath)
    if (targetPath === null) continue
    links.push({
      sourceKind: 'whiteboard',
      sourceRef: row.board_id,
      sourceLabel: row.title,
      targetPath,
      targetPage: clip.page,
      detail: clip.label,
      linkKind: 'material'
    })
  }
  return links
}

function backlinkFromRow(row: LinkRow): MaterialBacklink {
  return {
    ref: row.source_ref,
    label: row.source_label,
    page: row.target_page
  }
}

function detailedBacklinkFromRow(row: LinkRow): DetailedMaterialBacklink {
  const backlink: DetailedMaterialBacklink = {
    ...backlinkFromRow(row),
    detail: row.detail ?? ''
  }
  // Absent means `bandal://` so pre-wikilink consumers keep their shape.
  return row.link_kind === 'wikilink'
    ? { ...backlink, linkKind: 'wikilink' }
    : backlink
}

function hasColumn(db: Database, table: string, column: string): boolean {
  const columns = db.pragma(`table_info(${table})`) as { name: string }[]
  return columns.some((entry) => entry.name === column)
}

function ensureLinkTable(db: Database): void {
  const exists = db
    .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(LINK_TABLE) !== undefined
  if (exists && !hasColumn(db, LINK_TABLE, LINK_KIND_COLUMN)) {
    db.exec(`DROP TABLE ${LINK_TABLE}`)
  }
  db.exec(
    `CREATE TABLE IF NOT EXISTS ${LINK_TABLE} (
       course_id    TEXT NOT NULL,
       source_kind  TEXT NOT NULL CHECK (source_kind IN ('note', 'whiteboard')),
       source_ref   TEXT NOT NULL,
       source_label TEXT NOT NULL,
       target_path  TEXT NOT NULL,
       target_page  INTEGER,
       detail       TEXT,
       ${LINK_KIND_COLUMN} TEXT NOT NULL DEFAULT 'material'
     );
     CREATE INDEX IF NOT EXISTS idx_content_links_material
       ON ${LINK_TABLE} (course_id, target_path);`
  )
}

export function createLinkIndex(deps: LinkIndexDeps): LinkIndex {
  ensureLinkTable(deps.db)

  const insert = deps.db.prepare(
    `INSERT INTO ${LINK_TABLE}
       (course_id, source_kind, source_ref, source_label,
        target_path, target_page, detail, ${LINK_KIND_COLUMN})
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  )

  function refreshCourse(courseIdInput: string): CourseScan {
    const courseId = requireId(courseIdInput, 'courseId')
    const scan = scanCourseFiles(deps.getCourseFolder(courseId))
    const links = [
      ...linksFromNotes(scan),
      ...linksFromWhiteboards(deps.db, courseId, scan)
    ]

    const replaceCourse = deps.db.transaction(() => {
      // The entire course is replaced instead of relying on UNIQUE because
      // SQLite treats NULL pages as distinct. Full replacement is simpler and
      // guarantees deleted notes, shapes, boards, and materials leave no ghosts.
      deps.db.prepare(`DELETE FROM ${LINK_TABLE} WHERE course_id = ?`).run(courseId)
      for (const link of links) {
        insert.run(
          courseId,
          link.sourceKind,
          link.sourceRef,
          link.sourceLabel,
          link.targetPath,
          link.targetPage,
          link.detail,
          link.linkKind
        )
      }
    })
    replaceCourse()
    return scan
  }

  return {
    forMaterial(courseIdInput, relPathInput) {
      const courseId = requireId(courseIdInput, 'courseId')
      const relPath = requireNonEmptyString(relPathInput, 'relPath')
      const scan = refreshCourse(courseId)
      const targetPath = actualTargetPath(scan.pathLookup, relPath)
      if (targetPath === null) return { notes: [], boards: [] }

      const rows = deps.db
        .prepare(
          `SELECT source_kind, source_ref, source_label,
                  target_path, target_page, detail, ${LINK_KIND_COLUMN}
             FROM ${LINK_TABLE}
            WHERE course_id = ? AND target_path = ?
            ORDER BY source_kind ASC, source_label ASC,
                     target_page ASC, source_ref ASC`
        )
        .all(courseId, targetPath) as LinkRow[]
      const result: MaterialBacklinks = { notes: [], boards: [] }
      for (const row of rows) {
        const backlink = backlinkFromRow(row)
        if (row.source_kind === 'note') result.notes.push(backlink)
        else result.boards.push(backlink)
      }
      return result
    },

    allForCourse(courseIdInput) {
      const courseId = requireId(courseIdInput, 'courseId')
      refreshCourse(courseId)
      const rows = deps.db
        .prepare(
          `SELECT source_kind, source_ref, source_label,
                  target_path, target_page, detail, ${LINK_KIND_COLUMN}
             FROM ${LINK_TABLE}
            WHERE course_id = ?
            ORDER BY target_path ASC, source_kind ASC, source_label ASC,
                     target_page ASC, source_ref ASC`
        )
        .all(courseId) as LinkRow[]

      const groups = new Map<string, MaterialBacklinkGroup>()
      for (const row of rows) {
        let group = groups.get(row.target_path)
        if (group === undefined) {
          group = { relPath: row.target_path, notes: [], boards: [] }
          groups.set(row.target_path, group)
        }
        const backlink = detailedBacklinkFromRow(row)
        if (row.source_kind === 'note') group.notes.push(backlink)
        else group.boards.push(backlink)
      }
      return [...groups.values()]
    }
  }
}
