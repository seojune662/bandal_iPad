/**
 * Persisted dockview layout per course (`tabs_layout` table).
 * Backs the `layout:get` / `layout:save` IPC channels.
 */

import type { Database } from 'better-sqlite3'
import { ValidationError } from './errors'
import { nowIso, requireId } from './validate'

export interface LayoutRepo {
  get(courseId: string): { layout: unknown | null }
  save(courseId: string, layout: unknown): { ok: true }
  saveMany(layouts: Array<{ courseId: string; layout: unknown }>): { ok: true }
}

interface LayoutRow {
  layout_json: string
}

export function createLayoutRepo(db: Database): LayoutRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) {
      throw new ValidationError(`courseId "${courseId}" does not exist`)
    }
  }

  function serialize(courseId: string, layout: unknown): { id: string; json: string } {
    const id = requireId(courseId, 'courseId')
    assertCourseExists(id)
    let json: string | undefined
    try { json = JSON.stringify(layout) } catch {
      throw new ValidationError('layout must be JSON-serializable')
    }
    if (typeof json !== 'string') throw new ValidationError('layout must be JSON-serializable')
    return { id, json }
  }
  const write = db.prepare(
    `INSERT INTO tabs_layout (course_id, layout_json, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(course_id) DO UPDATE
       SET layout_json = excluded.layout_json, updated_at = excluded.updated_at`
  )
  const writeMany = db.transaction((rows: Array<{ id: string; json: string }>) => {
    const now = nowIso()
    for (const row of rows) write.run(row.id, row.json, now, now)
  })

  return {
    get(courseId) {
      const id = requireId(courseId, 'courseId')
      const row = db
        .prepare('SELECT layout_json FROM tabs_layout WHERE course_id = ?')
        .get(id) as LayoutRow | undefined
      if (row === undefined) {
        return { layout: null }
      }
      try {
        return { layout: JSON.parse(row.layout_json) as unknown }
      } catch (error) {
        console.error(`[layout] corrupt layout_json for course ${id}:`, error)
        return { layout: null }
      }
    },

    save(courseId, layout) {
      writeMany([serialize(courseId, layout)])
      return { ok: true }
    },

    saveMany(layouts) {
      if (!Array.isArray(layouts) || layouts.length === 0) throw new ValidationError('layouts are required')
      const rows = layouts.map(entry => serialize(entry.courseId, entry.layout))
      if (new Set(rows.map(row => row.id)).size !== rows.length) throw new ValidationError('courseIds must be distinct')
      writeMany(rows)
      return { ok: true }
    }
  }
}
