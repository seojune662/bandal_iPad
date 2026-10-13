/**
 * PDF 마지막 열람 위치(페이지·줌) 저장소 — 재시작 후에도 보던 자리로.
 * (course, file) 키의 파생 뷰 상태, upsert 전용 — mediaProgressRepo 와 같은 결.
 * 로컬 SQLite 에만 저장된다(Supabase 아님).
 */

import type { Database } from 'better-sqlite3'
import type { PdfViewState } from '../../../shared/types/pdfViewState'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'

interface PdfViewStateRow {
  course_id: string
  rel_path: string
  page: number
  zoom: number
  updated_at: string
}

export interface PdfViewStateRepo {
  get(courseId: string, relPath: string): PdfViewState | null
  set(input: {
    courseId: string
    relPath: string
    page: number
    zoom: number
  }): PdfViewState
}

function toState(row: PdfViewStateRow): PdfViewState {
  return {
    courseId: row.course_id,
    relPath: row.rel_path,
    page: row.page,
    zoom: row.zoom,
    updatedAt: row.updated_at
  }
}

export function createPdfViewStateRepo(db: Database): PdfViewStateRepo {
  const selectOne = db.prepare(
    `SELECT course_id, rel_path, page, zoom, updated_at
       FROM pdf_view_state WHERE course_id = ? AND rel_path = ?`
  )
  const upsert = db.prepare(
    `INSERT INTO pdf_view_state (course_id, rel_path, page, zoom, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (course_id, rel_path) DO UPDATE SET
       page = excluded.page,
       zoom = excluded.zoom,
       updated_at = excluded.updated_at`
  )

  return {
    get(rawCourseId, rawRelPath) {
      const courseId = requireId(rawCourseId, 'courseId')
      const relPath = requireNonEmptyString(rawRelPath, 'relPath')
      const row = selectOne.get(courseId, relPath) as
        | PdfViewStateRow
        | undefined
      return row === undefined ? null : toState(row)
    },

    set(input) {
      const courseId = requireId(input.courseId, 'courseId')
      const relPath = requireNonEmptyString(input.relPath, 'relPath')
      const page =
        Number.isInteger(input.page) && input.page >= 1 ? input.page : 1
      const zoom =
        Number.isFinite(input.zoom) && input.zoom > 0 ? input.zoom : 1
      const updatedAt = nowIso()
      upsert.run(courseId, relPath, page, zoom, updatedAt)
      return { courseId, relPath, page, zoom, updatedAt }
    }
  }
}
