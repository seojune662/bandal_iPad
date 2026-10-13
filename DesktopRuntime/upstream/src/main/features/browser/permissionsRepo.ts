/**
 * Site permission decisions, remembered per origin.
 *
 * A SEPARATE table from `browser_grants` on purpose. Those are what the AI
 * agent may do in a course; these are what a website may do in the browser.
 * Mixing them would make one revocation screen that lies about both — the
 * student would revoke "camera on myetl" and wonder why the assistant still
 * reads the page.
 *
 * There is no expiry here, unlike agent grants: Chrome and Safari both
 * remember a site permission until it is revoked, and a camera permission
 * that lapses silently mid-semester is worse than one the student can see and
 * remove.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'

export type PermissionDecision = 'granted' | 'denied'

export interface SitePermission {
  id: string
  /** Exact origin including the port. */
  origin: string
  permission: string
  decision: PermissionDecision
  decidedAt: string
}

interface Row {
  id: string
  origin: string
  permission: string
  decision: string
  decided_at: string
}

function toPermission(row: Row): SitePermission {
  return {
    id: row.id,
    origin: row.origin,
    permission: row.permission,
    decision: row.decision === 'granted' ? 'granted' : 'denied',
    decidedAt: row.decided_at
  }
}

export interface PermissionsRepo {
  /** The remembered answer, or null when the student has not been asked. */
  decisionFor: (origin: string, permission: string) => PermissionDecision | null
  remember: (
    origin: string,
    permission: string,
    decision: PermissionDecision
  ) => void
  list: () => SitePermission[]
  forget: (id: string) => void
  forgetAll: () => void
}

export function createPermissionsRepo(db: Database): PermissionsRepo {
  return {
    decisionFor(origin, permission) {
      const row = db
        .prepare(
          `SELECT decision FROM browser_permissions
            WHERE origin = ? AND permission = ?`
        )
        .get(origin, permission) as { decision?: string } | undefined
      if (row === undefined) return null
      return row.decision === 'granted' ? 'granted' : 'denied'
    },

    remember(origin, permission, decision) {
      db.prepare(
        `INSERT INTO browser_permissions
           (id, origin, permission, decision, decided_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (origin, permission) DO UPDATE SET
           decision = excluded.decision,
           decided_at = excluded.decided_at`
      ).run(
        randomUUID(),
        origin,
        permission,
        decision,
        new Date().toISOString()
      )
    },

    list() {
      const rows = db
        .prepare(
          `SELECT id, origin, permission, decision, decided_at
             FROM browser_permissions
            ORDER BY decided_at DESC`
        )
        .all() as Row[]
      return rows.map(toPermission)
    },

    forget(id) {
      db.prepare('DELETE FROM browser_permissions WHERE id = ?').run(id)
    },

    forgetAll() {
      db.prepare('DELETE FROM browser_permissions').run()
    }
  }
}
