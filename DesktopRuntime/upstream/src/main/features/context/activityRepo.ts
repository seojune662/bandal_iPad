import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  ActivityEvent,
  ActivityKind,
  RecordActivityInput
} from '../../../shared/types/study'
import {
  nowIso,
  requireId,
  requireInt,
  requireNonEmptyString
} from '../../db/validate'
import { ValidationError } from '../../db/errors'

export interface ActivityRepo {
  record(input: RecordActivityInput): ActivityEvent
  recent(courseId: string, limit?: number): ActivityEvent[]
  prune(courseId: string): void
}

interface ActivityRow {
  id: string
  course_id: string
  kind: string
  rel_path: string | null
  summary: string
  created_at: string
}

const ACTIVITY_KINDS: readonly ActivityKind[] = [
  'material-added',
  'material-opened',
  'note-created',
  'note-edited',
  'highlight-created',
  'drawing-created',
  'task-created',
  'task-completed',
  'question-asked',
  'study-tool-run'
]

const DEFAULT_RECENT_LIMIT = 50
const RETAINED_PER_COURSE = 500
const PRUNE_EVERY_RECORDS = 50
const MAX_SUMMARY_LENGTH = 300

function assertKind(value: unknown): ActivityKind {
  if (!ACTIVITY_KINDS.includes(value as ActivityKind)) {
    throw new ValidationError(`unknown activity kind "${String(value)}"`)
  }
  return value as ActivityKind
}

/** Activity summaries are deliberately one short, human-readable line. */
function normalizeSummary(value: unknown): string {
  const summary = requireNonEmptyString(value, 'summary')
    .replace(/\s+/g, ' ')
    .trim()
  return Array.from(summary).slice(0, MAX_SUMMARY_LENGTH).join('')
}

function rowToActivity(row: ActivityRow): ActivityEvent {
  return {
    id: row.id,
    courseId: row.course_id,
    kind: row.kind as ActivityKind,
    relPath: row.rel_path,
    summary: row.summary,
    createdAt: row.created_at
  }
}

export function createActivityRepo(db: Database): ActivityRepo {
  const recordsSincePrune = new Map<string, number>()

  function prune(courseIdInput: string): void {
    const courseId = requireId(courseIdInput, 'courseId')
    db.prepare(
      `DELETE FROM activity_events
       WHERE course_id = ?
         AND id IN (
           SELECT id FROM activity_events
           WHERE course_id = ?
           ORDER BY created_at DESC, rowid DESC
           LIMIT -1 OFFSET ?
         )`
    ).run(courseId, courseId, RETAINED_PER_COURSE)
  }

  return {
    record(input) {
      const courseId = requireId(input.courseId, 'courseId')
      const kind = assertKind(input.kind)
      const relPath =
        input.relPath === undefined || input.relPath === null
          ? null
          : requireNonEmptyString(input.relPath, 'relPath')
      const event: ActivityEvent = {
        id: randomUUID(),
        courseId,
        kind,
        relPath,
        summary: normalizeSummary(input.summary),
        createdAt: nowIso()
      }

      db.prepare(
        `INSERT INTO activity_events
           (id, course_id, kind, rel_path, summary, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      ).run(
        event.id,
        event.courseId,
        event.kind,
        event.relPath,
        event.summary,
        event.createdAt
      )

      const count = (recordsSincePrune.get(courseId) ?? 0) + 1
      if (count >= PRUNE_EVERY_RECORDS) {
        prune(courseId)
        recordsSincePrune.set(courseId, 0)
      } else {
        recordsSincePrune.set(courseId, count)
      }
      return event
    },

    recent(courseIdInput, limitInput = DEFAULT_RECENT_LIMIT) {
      const courseId = requireId(courseIdInput, 'courseId')
      const limit = requireInt(limitInput, 'limit', 1)
      const rows = db
        .prepare(
          `SELECT id, course_id, kind, rel_path, summary, created_at
           FROM activity_events
           WHERE course_id = ?
           ORDER BY created_at DESC, rowid DESC
           LIMIT ?`
        )
        .all(courseId, limit) as ActivityRow[]
      return rows.map(rowToActivity)
    },

    prune
  }
}
