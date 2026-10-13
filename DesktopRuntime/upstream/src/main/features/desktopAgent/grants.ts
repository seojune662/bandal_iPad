import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'

export type DesktopCapability = 'screen' | 'clipboard'

export const DESKTOP_GRANT_DAYS = 30

export interface DesktopGrantListItem {
  id: string
  capability: DesktopCapability
  expiresAt: string
  lastUsedAt: string | null
}

export interface DesktopGrantsRepo {
  find(
    courseId: string,
    capability: DesktopCapability
  ): { id: string; expiresAt: string } | null
  grant(
    courseId: string,
    capability: DesktopCapability,
    days?: number
  ): void
  revoke(courseId: string, capability?: DesktopCapability): number
  touch(id: string): void
  list(courseId: string): DesktopGrantListItem[]
}

interface GrantRow {
  id: string
  capability: DesktopCapability
  expires_at: string
  last_used_at: string | null
}

const DAY_MS = 24 * 60 * 60 * 1000

export function createDesktopGrantsRepo(
  db: Database,
  now: () => Date = () => new Date()
): DesktopGrantsRepo {
  return {
    find(courseId, capability) {
      const row = db
        .prepare(
          `SELECT id, expires_at
             FROM desktop_grants
            WHERE course_id = ? AND capability = ?
              AND revoked_at IS NULL AND expires_at > ?
            ORDER BY created_at DESC, rowid DESC
            LIMIT 1`
        )
        .get(courseId, capability, now().toISOString()) as
        | Pick<GrantRow, 'id' | 'expires_at'>
        | undefined

      return row === undefined
        ? null
        : { id: row.id, expiresAt: row.expires_at }
    },

    grant(courseId, capability, days = DESKTOP_GRANT_DAYS) {
      const at = now()
      const expiresAt = new Date(at.getTime() + days * DAY_MS)
      db.prepare(
        `INSERT INTO desktop_grants
           (id, course_id, capability, created_at, expires_at,
            revoked_at, last_used_at)
         VALUES (?, ?, ?, ?, ?, NULL, NULL)`
      ).run(
        randomUUID(),
        courseId,
        capability,
        at.toISOString(),
        expiresAt.toISOString()
      )
    },

    revoke(courseId, capability) {
      const result =
        capability === undefined
          ? db
              .prepare(
                `UPDATE desktop_grants
                    SET revoked_at = ?
                  WHERE course_id = ? AND revoked_at IS NULL`
              )
              .run(now().toISOString(), courseId)
          : db
              .prepare(
                `UPDATE desktop_grants
                    SET revoked_at = ?
                  WHERE course_id = ? AND capability = ?
                    AND revoked_at IS NULL`
              )
              .run(now().toISOString(), courseId, capability)
      return result.changes
    },

    touch(id) {
      db.prepare('UPDATE desktop_grants SET last_used_at = ? WHERE id = ?').run(
        now().toISOString(),
        id
      )
    },

    list(courseId) {
      const rows = db
        .prepare(
          `SELECT id, capability, expires_at, last_used_at
             FROM desktop_grants
            WHERE course_id = ? AND revoked_at IS NULL AND expires_at > ?
            ORDER BY created_at DESC, rowid DESC`
        )
        .all(courseId, now().toISOString()) as GrantRow[]

      return rows.map((row) => ({
        id: row.id,
        capability: row.capability,
        expiresAt: row.expires_at,
        lastUsedAt: row.last_used_at
      }))
    }
  }
}
