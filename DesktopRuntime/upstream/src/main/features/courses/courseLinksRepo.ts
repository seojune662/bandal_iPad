/**
 * Per-course shortcuts repository (`course_links`, migration 004).
 *
 * The renderer pastes a URL; classification happens here so the main process
 * stays the single boundary that validates it. Anything that is a valid
 * http(s) URL is accepted — a link that does not match the school's
 * `CourseLinkSpec` is stored as a plain link rather than rejected
 * (docs/university-sites.md §4.3).
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  CourseLink,
  CourseLinkKind,
  CreateCourseLinkInput,
  UpdateCourseLinkInput
} from '../../../shared/types/courseLink'
import { normalizeHttpUrl } from '../../../shared/universities/courseLink'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'

const LINK_KINDS: readonly CourseLinkKind[] = [
  'lms-course',
  'portal',
  'lms',
  'library',
  'mail',
  'registration',
  'homepage',
  'other'
]

/** Guard against a label that would render as an empty row in the sidebar. */
const MAX_LABEL_LENGTH = 60

export interface CourseLinksRepo {
  list(input: { courseId: string }): CourseLink[]
  create(input: CreateCourseLinkInput): CourseLink
  update(input: UpdateCourseLinkInput): CourseLink
  delete(input: { id: string }): { ok: true }
}

interface CourseLinkRow {
  id: string
  course_id: string
  label: string
  url: string
  raw_url: string
  kind: string
  lms_course_id: string | null
  sort_order: number
  created_at: string
  updated_at: string
}

function toKind(value: unknown): CourseLinkKind {
  if (!LINK_KINDS.includes(value as CourseLinkKind)) {
    throw new ValidationError(
      `kind must be one of ${LINK_KINDS.join(', ')} (got "${String(value)}")`
    )
  }
  return value as CourseLinkKind
}

function rowToLink(row: CourseLinkRow): CourseLink {
  return {
    id: row.id,
    courseId: row.course_id,
    label: row.label,
    url: row.url,
    rawUrl: row.raw_url,
    kind: row.kind as CourseLinkKind,
    lmsCourseId: row.lms_course_id,
    sortOrder: row.sort_order,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

function requireLabel(value: unknown): string {
  const label = requireNonEmptyString(value, 'label').trim()
  if (label.length > MAX_LABEL_LENGTH) {
    throw new ValidationError(`label must be at most ${MAX_LABEL_LENGTH} characters`)
  }
  return label
}

/** http(s) only — a `javascript:` or `file:` pin must never reach a webview. */
function requireHttpUrl(value: unknown, field: string): string {
  const raw = requireNonEmptyString(value, field)
  const normalized = normalizeHttpUrl(raw)
  if (normalized === null) {
    throw new ValidationError(`${field} must be an http(s) URL`)
  }
  return normalized
}

export function createCourseLinksRepo(db: Database): CourseLinksRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) {
      throw new NotFoundError('course', courseId)
    }
  }

  function getRowOrThrow(id: string): CourseLinkRow {
    const row = db.prepare('SELECT * FROM course_links WHERE id = ?').get(id) as
      | CourseLinkRow
      | undefined
    if (row === undefined) {
      throw new NotFoundError('courseLink', id)
    }
    return row
  }

  function nextSortOrder(courseId: string): number {
    const row = db
      .prepare(
        'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM course_links WHERE course_id = ?'
      )
      .get(courseId) as { max_order: number }
    return row.max_order + 1
  }

  return {
    list(input) {
      const courseId = requireId(input.courseId, 'courseId')
      const rows = db
        .prepare(
          `SELECT * FROM course_links
           WHERE course_id = ?
           ORDER BY sort_order ASC, created_at ASC`
        )
        .all(courseId) as CourseLinkRow[]
      return rows.map(rowToLink)
    },

    create(input) {
      const courseId = requireId(input.courseId, 'courseId')
      assertCourseExists(courseId)
      const label = requireLabel(input.label)
      const rawUrl = requireNonEmptyString(input.rawUrl, 'rawUrl').trim()
      // `url` is what we actually open; it falls back to the pasted URL so a
      // link is never stored without a loadable address.
      const url = requireHttpUrl(input.url ?? rawUrl, 'url')
      const kind = toKind(input.kind)
      const lmsCourseId =
        input.lmsCourseId === undefined || input.lmsCourseId === null
          ? null
          : requireNonEmptyString(input.lmsCourseId, 'lmsCourseId').trim()

      const now = nowIso()
      const link: CourseLink = {
        id: randomUUID(),
        courseId,
        label,
        url,
        rawUrl,
        kind,
        lmsCourseId,
        sortOrder: nextSortOrder(courseId),
        createdAt: now,
        updatedAt: now
      }
      db.prepare(
        `INSERT INTO course_links
           (id, course_id, label, url, raw_url, kind, lms_course_id,
            sort_order, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).run(
        link.id,
        link.courseId,
        link.label,
        link.url,
        link.rawUrl,
        link.kind,
        link.lmsCourseId,
        link.sortOrder,
        now,
        now
      )
      return link
    },

    update(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      const label = input.label === undefined ? row.label : requireLabel(input.label)
      const sortOrder =
        input.sortOrder === undefined ? row.sort_order : input.sortOrder
      if (!Number.isInteger(sortOrder) || sortOrder < 0) {
        throw new ValidationError('sortOrder must be an integer >= 0')
      }
      const now = nowIso()
      db.prepare(
        'UPDATE course_links SET label = ?, sort_order = ?, updated_at = ? WHERE id = ?'
      ).run(label, sortOrder, now, row.id)
      return rowToLink({
        ...row,
        label,
        sort_order: sortOrder,
        updated_at: now
      })
    },

    delete(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      // Hard delete: a shortcut carries no history worth soft-deleting.
      db.prepare('DELETE FROM course_links WHERE id = ?').run(row.id)
      return { ok: true }
    }
  }
}
