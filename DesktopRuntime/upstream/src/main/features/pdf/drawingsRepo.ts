/** SQLite repository for non-destructive, free-form PDF drawings. */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  CreateDrawingInput,
  Drawing,
  DrawingData,
  DrawingKind,
  DrawingStyle,
  UpdateDrawingInput
} from '../../../shared/types/drawing'
import { DRAWING_KINDS as ALL_DRAWING_KINDS } from '../../../shared/types/drawing'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireInt, requireNonEmptyString } from '../../db/validate'
import {
  assertDrawingData,
  assertDrawingKind,
  assertDrawingStyle
} from '../drawingValidation'

export interface DrawingsRepo {
  listForFile(courseId: string, relPath: string): Drawing[]
  create(input: CreateDrawingInput): Drawing
  update(input: UpdateDrawingInput): Drawing
  softDelete(ids: string[]): void
}

interface DrawingRow {
  id: string
  course_id: string
  rel_path: string
  page: number
  kind: string
  data_json: string
  style_json: string
  created_at: string
  updated_at: string
}

/** A PDF page accepts every drawing kind except a clip of another PDF page. */
const DRAWING_KINDS: readonly DrawingKind[] = ALL_DRAWING_KINDS.filter(
  (kind) => kind !== 'clip'
)

function rowToDrawing(row: DrawingRow): Drawing {
  return {
    id: row.id,
    courseId: row.course_id,
    relPath: row.rel_path,
    page: row.page,
    kind: row.kind as DrawingKind,
    data: JSON.parse(row.data_json) as DrawingData,
    style: JSON.parse(row.style_json) as DrawingStyle,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

export function createDrawingsRepo(db: Database): DrawingsRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) throw new NotFoundError('course', courseId)
  }

  function getRowOrThrow(id: string): DrawingRow {
    const row = db
      .prepare('SELECT * FROM pdf_drawings WHERE id = ? AND deleted_at IS NULL')
      .get(id) as DrawingRow | undefined
    if (row === undefined) throw new NotFoundError('drawing', id)
    return row
  }

  return {
    listForFile(courseIdInput, relPathInput) {
      const courseId = requireId(courseIdInput, 'courseId')
      const relPath = requireNonEmptyString(relPathInput, 'relPath')
      const rows = db
        .prepare(
          `SELECT * FROM pdf_drawings
           WHERE course_id = ? AND rel_path = ? AND deleted_at IS NULL
           ORDER BY page ASC, created_at ASC`
        )
        .all(courseId, relPath) as DrawingRow[]
      return rows.map(rowToDrawing)
    },

    create(input) {
      const courseId = requireId(input.courseId, 'courseId')
      assertCourseExists(courseId)
      const relPath = requireNonEmptyString(input.relPath, 'relPath')
      const page = requireInt(input.page, 'page', 1)
      const kind = assertDrawingKind(input.kind, DRAWING_KINDS)
      const data = assertDrawingData(input.data, kind)
      const style = assertDrawingStyle(input.style)
      const now = nowIso()
      const drawing: Drawing = {
        id: randomUUID(),
        courseId,
        relPath,
        page,
        kind,
        data,
        style,
        createdAt: now,
        updatedAt: now
      }
      db.prepare(
        `INSERT INTO pdf_drawings
           (id, course_id, rel_path, page, kind, data_json, style_json,
            created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).run(
        drawing.id,
        courseId,
        relPath,
        page,
        kind,
        JSON.stringify(data),
        JSON.stringify(style),
        now,
        now
      )
      return drawing
    },

    update(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      const kind = row.kind as DrawingKind
      const data = input.data === undefined
        ? JSON.parse(row.data_json) as DrawingData
        : assertDrawingData(input.data, kind)
      const style = input.style === undefined
        ? JSON.parse(row.style_json) as DrawingStyle
        : assertDrawingStyle(input.style)
      const now = nowIso()
      db.prepare(
        'UPDATE pdf_drawings SET data_json = ?, style_json = ?, updated_at = ? WHERE id = ?'
      ).run(JSON.stringify(data), JSON.stringify(style), now, row.id)
      return rowToDrawing({
        ...row,
        data_json: JSON.stringify(data),
        style_json: JSON.stringify(style),
        updated_at: now
      })
    },

    softDelete(idsInput) {
      if (!Array.isArray(idsInput)) {
        throw new ValidationError('ids must be an array')
      }
      const ids = [...new Set(idsInput.map((id) => requireId(id, 'id')))]
      if (ids.length === 0) return
      const now = nowIso()
      const remove = db.transaction(() => {
        const statement = db.prepare(
          'UPDATE pdf_drawings SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL'
        )
        for (const id of ids) {
          if (statement.run(now, now, id).changes === 0) {
            throw new NotFoundError('drawing', id)
          }
        }
      })
      remove()
    }
  }
}
