/**
 * What the agent is allowed to do, and where.
 *
 * The CLI tool-permission grant is a bare tool name applied course-wide. This
 * browser-specific grant deliberately inherits none of that broad scope.
 *
 * A grant is a TUPLE — (course, exact origin, capability) — and it expires.
 * There is no "forever" and no wildcard: a permission the student cannot
 * picture is a permission they cannot withdraw.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'

export type BrowserCapability = 'read' | 'interact' | 'download'

export interface BrowserGrant {
  id: string
  courseId: string
  /** Exact https origin, port included. */
  origin: string
  capability: BrowserCapability
  createdAt: string
  expiresAt: string
  revokedAt: string | null
  /** Last time a tool actually used it, for the settings list. */
  lastUsedAt: string | null
}

/** Long enough to cover a semester's worth of one course, short enough to lapse. */
export const GRANT_DAYS = 30

/** A grant that covers every site in the course, chosen deliberately. */
export const ANY_ORIGIN = '*'

/**
 * Exact origin including the port — 인하대 `:8443` and 아주대 `:30443` are real
 * and a grant that ignored them would cover a different service.
 */
export function normalizeOrigin(url: string): string | null {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null
    return parsed.origin
  } catch {
    return null
  }
}

/**
 * One approval covers reading, clicking and fetching on that site.
 *
 * These used to be three separate askable capabilities, and `read` did not
 * imply `interact`, so ONE task across two origins produced FOUR prompts
 * (2 sites × 2 capabilities) — six if it also downloaded. The student was
 * being asked the same question in slices they had no way to distinguish.
 *
 * What the split was protecting is not lost, because it never lived here:
 *  - `browser_submit` and `browser_use_saved_login` ask EVERY time and are
 *    never remembered at any scope
 *  - `actionPolicy.ts` refuses submit controls and password fields
 *    structurally, before any grant is consulted
 *  - 수강신청·결제 origins are refused categorically and never asked about
 *
 * So the grant means "look at this site and move around in it". Writing to it
 * is a different question, asked separately, every time.
 */
export function capabilitySatisfies(
  held: BrowserCapability,
  needed: BrowserCapability
): boolean {
  void needed
  return held === 'read' || held === 'interact' || held === 'download'
}

export interface GrantsRepo {
  list(courseId?: string): BrowserGrant[]
  /** The live grant covering this action, or null. */
  find(input: {
    courseId: string
    url: string
    capability: BrowserCapability
  }): BrowserGrant | null
  grant(input: {
    courseId: string
    url: string
    capability: BrowserCapability
    days?: number
  }): BrowserGrant | null
  revoke(id: string): void
  /** Stamps `last_used_at` so the settings list can show staleness. */
  touch(id: string, at?: Date): void
}

interface GrantRow {
  id: string
  course_id: string
  origin: string
  capability: BrowserCapability
  created_at: string
  expires_at: string
  revoked_at: string | null
  last_used_at: string | null
}

function toGrant(row: GrantRow): BrowserGrant {
  return {
    id: row.id,
    courseId: row.course_id,
    origin: row.origin,
    capability: row.capability,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at,
    lastUsedAt: row.last_used_at
  }
}

export function createGrantsRepo(
  db: Database,
  now: () => Date = () => new Date()
): GrantsRepo {
  return {
    list(courseId) {
      const rows = (
        courseId === undefined
          ? db
              .prepare(
                'SELECT * FROM browser_grants ORDER BY created_at DESC'
              )
              .all()
          : db
              .prepare(
                'SELECT * FROM browser_grants WHERE course_id = ? ORDER BY created_at DESC'
              )
              .all(courseId)
      ) as GrantRow[]
      return rows.map(toGrant)
    },

    find({ courseId, url, capability }) {
      const origin = normalizeOrigin(url)
      if (origin === null) return null
      // ANY_ORIGIN is the "이 과목 전체" answer. It never reaches a
      // categorically denied site: checkNavigation refuses those before a
      // grant is ever consulted.
      const rows = db
        .prepare(
          `SELECT * FROM browser_grants
             WHERE course_id = ? AND origin IN (?, ?)
               AND revoked_at IS NULL AND expires_at > ?
             ORDER BY CASE origin WHEN ? THEN 0 ELSE 1 END`
        )
        .all(
          courseId,
          origin,
          ANY_ORIGIN,
          now().toISOString(),
          origin
        ) as GrantRow[]
      const match = rows.find((row) =>
        capabilitySatisfies(row.capability, capability)
      )
      return match === undefined ? null : toGrant(match)
    },

    grant({ courseId, url, capability, days = GRANT_DAYS }) {
      const origin = url === ANY_ORIGIN ? ANY_ORIGIN : normalizeOrigin(url)
      if (origin === null) return null
      const at = now()
      const expiresAt = new Date(
        at.getTime() + days * 24 * 60 * 60 * 1000
      ).toISOString()
      const row: GrantRow = {
        id: randomUUID(),
        course_id: courseId,
        origin,
        capability,
        created_at: at.toISOString(),
        expires_at: expiresAt,
        revoked_at: null,
        last_used_at: null
      }
      db.prepare(
        `INSERT INTO browser_grants
           (id, course_id, origin, capability, created_at, expires_at,
            revoked_at, last_used_at)
         VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)`
      ).run(
        row.id,
        row.course_id,
        row.origin,
        row.capability,
        row.created_at,
        row.expires_at
      )
      return toGrant(row)
    },

    revoke(id) {
      db.prepare(
        'UPDATE browser_grants SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL'
      ).run(now().toISOString(), id)
    },

    touch(id, at = now()) {
      db.prepare(
        'UPDATE browser_grants SET last_used_at = ? WHERE id = ?'
      ).run(at.toISOString(), id)
    }
  }
}
