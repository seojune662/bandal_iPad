import type { Database } from 'better-sqlite3'
import type { MaterialNode } from '../../../shared/types/materials'

interface AddedRow { rel_path: string; added_at: number | null; pending_children: number }

/** Durable appearance history, deliberately independent of rebuildable indexes. */
export function createMaterialAddedState(db: Database, getFolder: (courseId: string) => string) {
  function binding(courseId: string): boolean {
    const folder = getFolder(courseId)
    const row = db.prepare('SELECT folder, completed FROM material_added_baselines WHERE course_id = ?')
      .get(courseId) as { folder: string; completed: number } | undefined
    if (row?.folder === folder) return row.completed === 1
    db.transaction(() => {
      db.prepare('DELETE FROM material_added_state WHERE course_id = ?').run(courseId)
      db.prepare('INSERT OR REPLACE INTO material_added_baselines (course_id, folder, completed) VALUES (?, ?, 0)').run(courseId, folder)
    })()
    return false
  }

  function rows(courseId: string): Map<string, AddedRow> {
    return new Map((db.prepare('SELECT rel_path, added_at, pending_children FROM material_added_state WHERE course_id = ?')
      .all(courseId) as AddedRow[]).map(row => [row.rel_path, row]))
  }

  function recordAdded(courseId: string, relPath: string, directory = false): void {
    binding(courseId)
    db.transaction(() => {
      // A copied directory can reuse a path removed before the next scan.
      // Its descendants belong to the new copy, not the old cached history.
      if (directory) {
        const remove = db.prepare('DELETE FROM material_added_state WHERE course_id = ? AND rel_path = ?')
        for (const path of rows(courseId).keys()) if (path.startsWith(`${relPath}/`)) remove.run(courseId, path)
      }
      db.prepare(`INSERT INTO material_added_state (course_id, rel_path, added_at, pending_children) VALUES (?, ?, ?, ?)
        ON CONFLICT(course_id, rel_path) DO UPDATE SET added_at=excluded.added_at, pending_children=excluded.pending_children`)
        .run(courseId, relPath, Date.now(), directory ? 1 : 0)
    })()
  }

  function repoint(courseId: string, from: string, to: string, directory: boolean): void {
    if (from === to) return
    binding(courseId)
    const matching = [...rows(courseId).values()].filter(row => row.rel_path === from || directory && row.rel_path.startsWith(`${from}/`))
    db.transaction(() => {
      for (const row of matching) {
        const next = `${to}${row.rel_path.slice(from.length)}`
        db.prepare('DELETE FROM material_added_state WHERE course_id = ? AND rel_path = ?').run(courseId, next)
        db.prepare('UPDATE material_added_state SET rel_path = ? WHERE course_id = ? AND rel_path = ?').run(next, courseId, row.rel_path)
      }
    })()
  }

  async function reconcile(courseId: string, files: readonly MaterialNode[], complete: boolean, current: () => boolean): Promise<void> {
    const initialized = binding(courseId)
    const existing = rows(courseId)
    const additions = [...existing.values()].filter(row => row.pending_children === 1 && row.added_at !== null)
      .sort((a, b) => b.rel_path.length - a.rel_path.length)
    const now = Date.now()
    const insert = db.prepare('INSERT OR IGNORE INTO material_added_state (course_id, rel_path, added_at) VALUES (?, ?, ?)')
    for (let offset = 0; offset < files.length; offset += 100) {
      if (!current()) return
      db.transaction(() => {
        for (const file of files.slice(offset, offset + 100)) {
          if (existing.delete(file.relPath)) continue
          const parent = additions.find(row => file.relPath.startsWith(`${row.rel_path}/`))
          insert.run(courseId, file.relPath, parent?.added_at ?? (initialized ? now : null))
        }
      })()
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
    // Only a full, still-current walk can declare a deleted path or finish
    // the initial baseline. A capped walk must not turn unseen old files new.
    if (!complete || !current()) return
    const remove = db.prepare('DELETE FROM material_added_state WHERE course_id = ? AND rel_path = ? AND added_at IS ?')
    const stale = [...existing.values()]
    for (let offset = 0; offset < stale.length; offset += 100) {
      if (!current()) return
      db.transaction(() => {
        for (const row of stale.slice(offset, offset + 100)) remove.run(courseId, row.rel_path, row.added_at)
      })()
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
    if (current()) db.prepare('UPDATE material_added_baselines SET completed = 1 WHERE course_id = ?').run(courseId)
  }

  function timestamps(courseId: string): Map<string, number> {
    binding(courseId)
    return new Map([...rows(courseId).values()].flatMap(row => row.added_at === null ? [] : [[row.rel_path, row.added_at]]))
  }

  function decorate(courseId: string, nodes: MaterialNode[]): MaterialNode[] {
    const added = timestamps(courseId)
    const visit = (entries: MaterialNode[]): MaterialNode[] => entries.map(node => {
      const { addedAt: _old, ...rest } = node
      const timestamp = added.get(node.relPath)
      return { ...rest, ...(node.kind === 'dir' ? { children: visit(node.children ?? []) } : timestamp === undefined ? {} : { addedAt: timestamp }) }
    })
    return visit(nodes)
  }

  return { recordAdded, repoint, reconcile, timestamps, decorate }
}
