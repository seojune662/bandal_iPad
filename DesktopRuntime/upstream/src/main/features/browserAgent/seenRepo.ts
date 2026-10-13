/**
 * What this course has already been shown.
 *
 * Without it, "새 공지 있어?" can only be answered with the whole list, which
 * is not an answer — the student can already see the whole list themselves.
 * With it the agent reports a delta, which is the actual question.
 *
 * Stores ids and titles only. No page content, no URLs beyond what the LMS
 * itself calls the item, and it is deleted with the course.
 */

import { createHash } from 'node:crypto'
import type { Database } from 'better-sqlite3'

export interface SeenItem {
  /** Platform id when there is one, else a hash of title+date. */
  key: string
  title: string
}

export interface SeenRepo {
  /**
   * Returns the items not yet recorded, and records them.
   *
   * Deliberately one call: a caller that could read without marking would
   * eventually report the same "new" announcement twice.
   */
  diffAndRecord(input: {
    courseId: string
    listKey: string
    items: SeenItem[]
  }, at?: Date): SeenItem[]
  /** For the first run on a course: record everything, report nothing new. */
  seed(input: { courseId: string; listKey: string; items: SeenItem[] }, at?: Date): void
  has(courseId: string, listKey: string): boolean
  clear(courseId: string): void
}

/** Stable key for a platform that gives no id of its own. */
export function itemKey(id: string | null, title: string, at: string | null): string {
  if (id !== null && id.trim() !== '') return id.trim()
  return createHash('sha256').update(`${title}|${at ?? ''}`).digest('hex').slice(0, 32)
}

export function createSeenRepo(db: Database): SeenRepo {
  const insert = db.prepare(
    `INSERT OR IGNORE INTO browser_seen
       (course_id, list_key, item_key, title, first_seen)
     VALUES (?, ?, ?, ?, ?)`
  )

  return {
    has(courseId, listKey) {
      const row = db
        .prepare(
          'SELECT 1 AS n FROM browser_seen WHERE course_id = ? AND list_key = ? LIMIT 1'
        )
        .get(courseId, listKey)
      return row !== undefined
    },

    seed({ courseId, listKey, items }, at = new Date()) {
      const stamp = at.toISOString()
      const run = db.transaction(() => {
        for (const item of items) {
          insert.run(courseId, listKey, item.key, item.title, stamp)
        }
      })
      run()
    },

    diffAndRecord({ courseId, listKey, items }, at = new Date()) {
      const stamp = at.toISOString()
      const known = new Set(
        (
          db
            .prepare(
              'SELECT item_key FROM browser_seen WHERE course_id = ? AND list_key = ?'
            )
            .all(courseId, listKey) as { item_key: string }[]
        ).map((row) => row.item_key)
      )
      const fresh = items.filter((item) => !known.has(item.key))
      const run = db.transaction(() => {
        for (const item of fresh) {
          insert.run(courseId, listKey, item.key, item.title, stamp)
        }
      })
      run()
      return fresh
    },

    clear(courseId) {
      db.prepare('DELETE FROM browser_seen WHERE course_id = ?').run(courseId)
    }
  }
}
