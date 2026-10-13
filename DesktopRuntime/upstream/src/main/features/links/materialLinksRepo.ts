import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type { TabDescriptor } from '../../../shared/tabs'
import {
  isPdfPageNoteLinkMetadata,
  type MaterialLinkKind,
  type MaterialLinkRecord,
  type PdfPageNoteLinkMetadata
} from '../../../shared/types/link'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'
import {
  parseDescriptor,
  serializeDescriptor
} from '../favorites/descriptorJson'

export interface CreateMaterialLinkInput {
  courseId: string
  source: TabDescriptor
  target: TabDescriptor
  label: string
  kind?: MaterialLinkKind
  metadata?: PdfPageNoteLinkMetadata | null
}

export interface MaterialLinksForPath {
  outgoing: MaterialLinkRecord[]
  incoming: MaterialLinkRecord[]
}

export interface MaterialLinksRepo {
  create(input: CreateMaterialLinkInput): MaterialLinkRecord
  remove(courseId: string, id: string): { ok: true }
  updateMetadata(
    courseId: string,
    id: string,
    metadata: PdfPageNoteLinkMetadata
  ): MaterialLinkRecord
  listFor(courseId: string, relPath: string): MaterialLinksForPath
  listForDescriptor(
    courseId: string,
    descriptor: TabDescriptor
  ): MaterialLinksForPath
  /** 과목의 수동 링크 전체 — 그래프 뷰용. */
  listAll(courseId: string): MaterialLinkRecord[]
}

interface MaterialLinkRow {
  id: string
  course_id: string
  source_json: string
  target_json: string
  label: string
  kind: string
  metadata_json: string | null
  created_at: string
}

function rowToRecord(row: MaterialLinkRow): MaterialLinkRecord {
  let metadata: PdfPageNoteLinkMetadata | null = null
  if (row.metadata_json !== null) {
    try {
      const parsed: unknown = JSON.parse(row.metadata_json)
      if (isPdfPageNoteLinkMetadata(parsed)) metadata = parsed
    } catch {
      // A malformed optional payload must not hide the underlying connection.
    }
  }
  return {
    id: row.id,
    courseId: row.course_id,
    source: parseDescriptor(row.source_json),
    target: parseDescriptor(row.target_json),
    kind:
      row.kind === 'sequence' || row.kind === 'pdf-page-note'
        ? row.kind
        : 'related',
    label: row.label,
    metadata,
    createdAt: row.created_at
  }
}

function descriptorRelPath(descriptor: TabDescriptor): string | null {
  switch (descriptor.kind) {
    case 'pdf':
    case 'note':
    case 'image':
    case 'file':
      return descriptor.payload.relPath
    case 'browser':
    case 'chat':
    case 'board':
    case 'whiteboard':
    case 'plugin-panel':
    case 'recording':
    case 'learning':
      return null
  }
}

/**
 * Comparison-only key copied from `links/linkIndex.ts:pathKey`.
 * Keep filesystem spelling intact; NFC only reconciles macOS NFD paths with
 * composed input, and lowercase makes material lookups case-insensitive.
 */
function pathKey(value: string): string {
  return value.normalize('NFC').toLowerCase()
}

function requireLabel(value: unknown): string {
  if (typeof value !== 'string') {
    throw new ValidationError('label must be a string')
  }
  return value
}

function requireKind(value: unknown): MaterialLinkKind {
  if (value === 'related' || value === 'sequence' || value === 'pdf-page-note') {
    return value
  }
  throw new ValidationError('kind must be a supported material link kind')
}

function validatePageNoteLink(
  kind: MaterialLinkKind,
  source: TabDescriptor,
  target: TabDescriptor,
  metadata: unknown
): PdfPageNoteLinkMetadata | null {
  if (kind !== 'pdf-page-note') return null
  if (!(source.kind === 'pdf' || (source.kind === 'file' && /\.pptx?$/i.test(source.payload.relPath))) || target.kind !== 'note') {
    throw new ValidationError('page notes must point from a PDF or presentation to a note')
  }
  if (!isPdfPageNoteLinkMetadata(metadata)) {
    throw new ValidationError('pdf-page-note metadata is invalid')
  }
  return metadata
}

export function createMaterialLinksRepo(db: Database): MaterialLinksRepo {
  const selectCourse = db.prepare(
    'SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL'
  )
  // The same pair may carry one relationship of each kind.
  const selectDuplicate = db.prepare(
    `SELECT * FROM material_links
      WHERE course_id = ? AND source_json = ? AND target_json = ? AND kind = ?
      ORDER BY created_at ASC, rowid ASC
      LIMIT 1`
  )
  const selectForCourse = db.prepare(
    `SELECT * FROM material_links
      WHERE course_id = ?
      ORDER BY created_at ASC, rowid ASC`
  )
  const insert = db.prepare(
    `INSERT INTO material_links
       (id, course_id, source_json, target_json, kind, label, metadata_json, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  )
  const remove = db.prepare(
    'DELETE FROM material_links WHERE course_id = ? AND id = ?'
  )
  const selectById = db.prepare(
    'SELECT * FROM material_links WHERE course_id = ? AND id = ?'
  )
  const updateMetadata = db.prepare(
    'UPDATE material_links SET metadata_json = ? WHERE course_id = ? AND id = ?'
  )

  function assertCourseExists(courseId: string): void {
    if (selectCourse.get(courseId) === undefined) {
      throw new NotFoundError('course', courseId)
    }
  }

  function listFor(rawCourseId: string, rawRelPath: string): MaterialLinksForPath {
    const courseId = requireId(rawCourseId, 'courseId')
    const relPath = requireNonEmptyString(rawRelPath, 'relPath')
    const requestedKey = pathKey(relPath)
    const rows = selectForCourse.all(courseId) as MaterialLinkRow[]
    const records = rows.map(rowToRecord)

    return {
      outgoing: records.filter((record) => {
        const sourcePath = descriptorRelPath(record.source)
        return sourcePath !== null && pathKey(sourcePath) === requestedKey
      }),
      incoming: records.filter((record) => {
        const targetPath = descriptorRelPath(record.target)
        return targetPath !== null && pathKey(targetPath) === requestedKey
      })
    }
  }

  return {
    create(input) {
      const courseId = requireId(input.courseId, 'courseId')
      assertCourseExists(courseId)
      const source = serializeDescriptor(input.source)
      const target = serializeDescriptor(input.target)
      const label = requireLabel(input.label)
      const kind = requireKind(
        input.kind ?? (label === 'next' ? 'sequence' : 'related')
      )
      const metadata = validatePageNoteLink(
        kind,
        source.descriptor,
        target.descriptor,
        input.metadata ?? null
      )

      if (source.json === target.json) {
        throw new ValidationError('source and target must be different')
      }

      if (kind === 'pdf-page-note') {
        const existingForNote = (selectForCourse.all(courseId) as MaterialLinkRow[])
          .find(
            (row) =>
              row.kind === 'pdf-page-note' &&
              row.target_json === target.json &&
              row.source_json !== source.json
          )
        if (existingForNote !== undefined) {
          throw new ValidationError(
            'a PDF page note can belong to only one source PDF'
          )
        }
      }

      const duplicate = selectDuplicate.get(
        courseId,
        source.json,
        target.json,
        kind
      ) as MaterialLinkRow | undefined
      if (duplicate !== undefined) return rowToRecord(duplicate)

      const record: MaterialLinkRecord = {
        id: randomUUID(),
        courseId,
        source: source.descriptor,
        target: target.descriptor,
        kind,
        label,
        metadata,
        createdAt: nowIso()
      }
      insert.run(
        record.id,
        record.courseId,
        source.json,
        target.json,
        record.kind,
        record.label,
        metadata === null ? null : JSON.stringify(metadata),
        record.createdAt
      )
      return record
    },

    remove(rawCourseId, rawId) {
      const courseId = requireId(rawCourseId, 'courseId')
      const id = requireId(rawId, 'id')
      const result = remove.run(courseId, id)
      if (result.changes !== 1) throw new NotFoundError('materialLink', id)
      return { ok: true }
    },

    updateMetadata(rawCourseId, rawId, rawMetadata) {
      const courseId = requireId(rawCourseId, 'courseId')
      const id = requireId(rawId, 'id')
      if (!isPdfPageNoteLinkMetadata(rawMetadata)) {
        throw new ValidationError('pdf-page-note metadata is invalid')
      }
      const existing = selectById.get(courseId, id) as MaterialLinkRow | undefined
      if (existing === undefined) throw new NotFoundError('materialLink', id)
      if (existing.kind !== 'pdf-page-note') {
        throw new ValidationError('only pdf-page-note metadata can be updated')
      }
      updateMetadata.run(JSON.stringify(rawMetadata), courseId, id)
      return rowToRecord(selectById.get(courseId, id) as MaterialLinkRow)
    },

    listForDescriptor(rawCourseId, descriptor) {
      // Path-backed kinds match by relPath (tolerant of NFC/case drift);
      // pathless kinds (browser tabs, …) match by canonical descriptor JSON.
      const relPath = descriptorRelPath(descriptor)
      if (relPath !== null) return listFor(rawCourseId, relPath)

      const courseId = requireId(rawCourseId, 'courseId')
      const { json } = serializeDescriptor(descriptor)
      const rows = selectForCourse.all(courseId) as MaterialLinkRow[]
      return {
        outgoing: rows
          .filter((row) => row.source_json === json)
          .map(rowToRecord),
        incoming: rows
          .filter((row) => row.target_json === json)
          .map(rowToRecord)
      }
    },

    listFor,

    listAll(rawCourseId) {
      const courseId = requireId(rawCourseId, 'courseId')
      const rows = selectForCourse.all(courseId) as MaterialLinkRow[]
      return rows.map(rowToRecord)
    }
  }
}
