/**
 * PDF annotations repository (CRUD over the `annotations` table).
 * Geometry and text anchors are stored as JSON columns.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  Annotation,
  AnnotationAnchor,
  AnnotationRect,
  CreateAnnotationInput,
  HighlightColor,
  UpdateAnnotationInput
} from '../../../shared/types/annotation'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireInt, requireNonEmptyString } from '../../db/validate'

export interface AnnotationsRepo {
  listForFile(input: { courseId: string; relPath: string }): Annotation[]
  create(input: CreateAnnotationInput): Annotation
  update(input: UpdateAnnotationInput): Annotation
  softDelete(input: { id: string }): { ok: true }
}

interface AnnotationRow {
  id: string
  course_id: string
  rel_path: string
  page: number
  color: string
  rects_json: string
  anchor_json: string
  comment: string | null
  created_at: string
  updated_at: string
}

const HIGHLIGHT_COLORS: readonly HighlightColor[] = ['yellow', 'green', 'pink', 'blue']

function assertColor(value: unknown): HighlightColor {
  if (!HIGHLIGHT_COLORS.includes(value as HighlightColor)) {
    throw new ValidationError(
      `color must be one of ${HIGHLIGHT_COLORS.join(', ')} (got "${String(value)}")`
    )
  }
  return value as HighlightColor
}

function assertRects(value: unknown): AnnotationRect[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ValidationError('rects must be a non-empty array')
  }
  for (const rect of value as unknown[]) {
    const r = rect as Partial<AnnotationRect> | null
    if (
      r === null ||
      typeof r !== 'object' ||
      ![r.x, r.y, r.width, r.height].every(
        (n) => typeof n === 'number' && Number.isFinite(n)
      )
    ) {
      throw new ValidationError('each rect needs finite numeric x/y/width/height')
    }
  }
  return value as AnnotationRect[]
}

function assertAnchor(value: unknown): AnnotationAnchor {
  const anchor = value as Partial<AnnotationAnchor> | null
  if (
    anchor === null ||
    typeof anchor !== 'object' ||
    typeof anchor.quote !== 'string' ||
    typeof anchor.prefix !== 'string' ||
    typeof anchor.suffix !== 'string'
  ) {
    throw new ValidationError('anchor needs string quote/prefix/suffix')
  }
  return anchor as AnnotationAnchor
}

function rowToAnnotation(row: AnnotationRow): Annotation {
  return {
    id: row.id,
    courseId: row.course_id,
    relPath: row.rel_path,
    page: row.page,
    color: row.color as HighlightColor,
    rects: JSON.parse(row.rects_json) as AnnotationRect[],
    anchor: JSON.parse(row.anchor_json) as AnnotationAnchor,
    comment: row.comment,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

export function createAnnotationsRepo(db: Database): AnnotationsRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) {
      throw new NotFoundError('course', courseId)
    }
  }

  function getRowOrThrow(id: string): AnnotationRow {
    const row = db
      .prepare('SELECT * FROM annotations WHERE id = ? AND deleted_at IS NULL')
      .get(id) as AnnotationRow | undefined
    if (row === undefined) {
      throw new NotFoundError('annotation', id)
    }
    return row
  }

  return {
    listForFile(input) {
      const courseId = requireId(input.courseId, 'courseId')
      const relPath = requireNonEmptyString(input.relPath, 'relPath')
      const rows = db
        .prepare(
          `SELECT * FROM annotations
           WHERE course_id = ? AND rel_path = ? AND deleted_at IS NULL
           ORDER BY page ASC, created_at ASC`
        )
        .all(courseId, relPath) as AnnotationRow[]
      return rows.map(rowToAnnotation)
    },

    create(input) {
      const courseId = requireId(input.courseId, 'courseId')
      assertCourseExists(courseId)
      const relPath = requireNonEmptyString(input.relPath, 'relPath')
      const page = requireInt(input.page, 'page', 1)
      const color = assertColor(input.color)
      const rects = assertRects(input.rects)
      const anchor = assertAnchor(input.anchor)
      const comment = input.comment ?? null
      if (comment !== null && typeof comment !== 'string') {
        throw new ValidationError('comment must be a string or null')
      }

      const now = nowIso()
      const annotation: Annotation = {
        id: randomUUID(),
        courseId,
        relPath,
        page,
        color,
        rects,
        anchor,
        comment,
        createdAt: now,
        updatedAt: now
      }
      db.prepare(
        `INSERT INTO annotations
           (id, course_id, rel_path, page, color, rects_json, anchor_json,
            comment, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).run(
        annotation.id,
        courseId,
        relPath,
        page,
        color,
        JSON.stringify(rects),
        JSON.stringify(anchor),
        comment,
        now,
        now
      )
      return annotation
    },

    update(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      const color = input.color === undefined ? (row.color as HighlightColor) : assertColor(input.color)
      const comment = input.comment === undefined ? row.comment : input.comment
      if (comment !== null && typeof comment !== 'string') {
        throw new ValidationError('comment must be a string or null')
      }
      const now = nowIso()
      db.prepare(
        'UPDATE annotations SET color = ?, comment = ?, updated_at = ? WHERE id = ?'
      ).run(color, comment, now, row.id)
      return rowToAnnotation({ ...row, color, comment, updated_at: now })
    },

    softDelete(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      const now = nowIso()
      db.prepare('UPDATE annotations SET deleted_at = ?, updated_at = ? WHERE id = ?').run(
        now,
        now,
        row.id
      )
      return { ok: true }
    }
  }
}
