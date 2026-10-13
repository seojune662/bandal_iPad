/**
 * Append-only record of what the agent did in the browser.
 *
 * Separate from `agentTools/journal.ts` on purpose: the journal exists to
 * UNDO app changes, and a page read cannot be undone. This is a log the
 * student reads, so it answers "what did it look at, and where" — never
 * "what was on the page".
 *
 * Values arrive already redacted (`redact.ts`). Nothing here re-checks that,
 * because a redaction applied at the sink is one that a new call site can
 * forget; it is applied at every call site instead, and tested there.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'

export type AuditAction =
  | 'navigate'
  | 'read'
  | 'snapshot'
  | 'download'
  | 'grant'
  | 'revoke'
  | 'denied'

export interface AuditEntry {
  id: string
  courseId: string
  runId: string
  action: AuditAction
  /** Origin + path only — no query, no fragment. */
  url: string
  /** One redacted line: what was done, or why it was refused. */
  detail: string
  createdAt: string
}

/** A student reviewing "what has this thing been doing" wants weeks, not years. */
export const AUDIT_RETENTION_DAYS = 90

export interface AuditRepo {
  record(entry: Omit<AuditEntry, 'id' | 'createdAt'>, at?: Date): AuditEntry
  tail(courseId: string | null, limit?: number): AuditEntry[]
  prune(at?: Date): void
}

interface AuditRow {
  id: string
  course_id: string
  run_id: string
  action: AuditAction
  url: string
  detail: string
  created_at: string
}

const toEntry = (row: AuditRow): AuditEntry => ({
  id: row.id,
  courseId: row.course_id,
  runId: row.run_id,
  action: row.action,
  url: row.url,
  detail: row.detail,
  createdAt: row.created_at
})

export function createAuditRepo(db: Database): AuditRepo {
  return {
    record(entry, at = new Date()) {
      const row: AuditRow = {
        id: randomUUID(),
        course_id: entry.courseId,
        run_id: entry.runId,
        action: entry.action,
        url: entry.url,
        detail: entry.detail,
        created_at: at.toISOString()
      }
      db.prepare(
        `INSERT INTO browser_audit
           (id, course_id, run_id, action, url, detail, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run(
        row.id,
        row.course_id,
        row.run_id,
        row.action,
        row.url,
        row.detail,
        row.created_at
      )
      return toEntry(row)
    },

    tail(courseId, limit = 200) {
      const rows = (
        courseId === null
          ? db
              .prepare(
                'SELECT * FROM browser_audit ORDER BY created_at DESC LIMIT ?'
              )
              .all(limit)
          : db
              .prepare(
                `SELECT * FROM browser_audit WHERE course_id = ?
                   ORDER BY created_at DESC LIMIT ?`
              )
              .all(courseId, limit)
      ) as AuditRow[]
      return rows.map(toEntry)
    },

    prune(at = new Date()) {
      const cutoff = new Date(
        at.getTime() - AUDIT_RETENTION_DAYS * 24 * 60 * 60 * 1000
      ).toISOString()
      db.prepare('DELETE FROM browser_audit WHERE created_at < ?').run(cutoff)
    }
  }
}
