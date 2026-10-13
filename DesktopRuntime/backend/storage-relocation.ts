import { env } from './native'
import { existsSync, readFileSync, readdirSync, realpathSync, statSync } from './shims/fs'
import { join, resolve } from './shims/path'
import { writeFileAtomic } from './shims/atomic-write'

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
// Bootstrap only the precise data-container layout used by prior iPad builds.
// Other absolute paths (including linked folders) are never guessed or moved.
const oldContainer = new RegExp(`^((?:/private)?/var/mobile/Containers/Data/Application/${uuid}/Documents/BandalDesktop)(?:/|$)`, 'i')
const inside = (path: string, root: string) => path === root || path.startsWith(root + '/')
const clean = (value: unknown): value is string => typeof value === 'string' && value.startsWith('/') && !/[\\\x00]/.test(value) && resolve(value) === value

/** iOS preserves Documents across installs while changing the container UUID.
 * Repair local location metadata before repositories or sync journals open it.
 * File edits precede the SQL receipt and are idempotent if startup is interrupted.
 * Canonical sync envelopes, IDs, history, revisions and external grants stay intact.
 */
export function relocateManagedStorage(db: any) {
  if (env().platform !== 'ios') return { courses: 0, files: 0 }
  const root = resolve(env().userDataPath), realRoot = realpathSync(root)
  db.exec('CREATE TABLE IF NOT EXISTS ipad_storage_locations(root TEXT PRIMARY KEY)')
  const roots = new Set<string>(db.prepare('SELECT root FROM ipad_storage_locations').all().map((row: any) => row.root).filter(clean))
  const courses = db.prepare('SELECT id,source,folder_path FROM courses').all()
  const settingsPath = join(root, 'settings.json')
  let settings: any
  if (existsSync(settingsPath)) {
    const text = readFileSync(settingsPath, 'utf8') as string
    try { settings = JSON.parse(text) } catch { /* Original settingsStore owns corrupt-file recovery. */ }
  }
  const remember = (value: unknown) => { if (clean(value)) { const match = oldContainer.exec(value); if (match) roots.add(match[1]) } }
  for (const course of courses) if (course.source === 'managed') remember(course.folder_path)
  remember(settings?.dataRoot)
  for (const previous of [...roots]) if (oldContainer.exec(previous)?.[1] === previous) {
    roots.add(previous.startsWith('/private/') ? previous.slice('/private'.length) : '/private' + previous)
  }
  roots.delete(root)
  if (!roots.size) {
    db.prepare('INSERT OR IGNORE INTO ipad_storage_locations(root) VALUES(?)').run(root)
    return { courses: 0, files: 0 }
  }
  const replacement = (value: unknown): string | undefined => {
    if (!clean(value)) return undefined
    for (const previous of roots) if (inside(value, previous)) return root + value.slice(previous.length)
    return undefined
  }
  const existsInside = (path: string, directory = false) => {
    if (!existsSync(path)) return false
    const actual = realpathSync(path)
    return inside(actual, realRoot) && (!directory || statSync(path).isDirectory())
  }
  const moved = new Map<string, { from: string; to: string }>()
  for (const course of courses) {
    if (course.source !== 'managed') continue
    const target = replacement(course.folder_path)
    if (!target || !target.startsWith(join(root, 'Courses') + '/') || !existsInside(target, true)) continue
    moved.set(course.id, { from: course.folder_path, to: target })
  }
  // A course path must have a matching preserved destination; do not fabricate
  // missing course folders, infer names, or overwrite a linked registration.
  for (const [id, entry] of moved) if (courses.some((other: any) => other.id !== id && other.folder_path === entry.to)) {
    throw new Error('A moved course folder is already registered; preserved both registrations')
  }
  const rebase = (value: unknown): unknown => {
    if (!clean(value)) return value
    for (const entry of moved.values()) if (inside(value, entry.from)) return entry.to + value.slice(entry.from.length)
    const target = replacement(value)
    if (!target) return value
    // These locations belong to the local sync/recovery implementation. There
    // is deliberately no recursive replacement of arbitrary JSON strings.
    for (const directory of ['SyncRecovery', 'SyncConflictAssets', 'CommonSync', 'Temporary', 'MigrationRecovery']) {
      if (inside(target, join(root, directory))) return target
    }
    return value
  }
  const fileChanges: Array<{ path: string; value: any }> = []
  if (settings && typeof settings === 'object' && !Array.isArray(settings)) {
    const target = replacement(settings.dataRoot)
    if (target && inside(target, join(root, 'Courses')) && existsInside(target, true)) {
      fileChanges.push({ path: settingsPath, value: { ...settings, dataRoot: target } })
    }
  }
  const recovery = join(root, 'SyncRecovery')
  if (existsSync(recovery)) for (const entry of readdirSync(recovery, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) continue
    const path = join(recovery, entry.name, 'intent.json')
    if (!existsSync(path)) continue
    const intent = JSON.parse(readFileSync(path, 'utf8') as string)
    if (!Array.isArray(intent.entries)) throw new Error('Invalid storage recovery journal')
    const next = { ...intent, entries: intent.entries.map((item: any) => ({ ...item, target: rebase(item.target),
      ...(item.source === undefined ? {} : { source: rebase(item.source) }), backup: rebase(item.backup) })) }
    if (JSON.stringify(next) !== JSON.stringify(intent)) fileChanges.push({ path, value: next })
  }
  const hasTable = (name: string) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name)
  const jsonChanges: Array<{ table: string; column: string; key: string; id: string; text: string }> = []
  const jsonRows = (table: string, column: string, key: string, update: (value: any) => any) => {
    if (!hasTable(table) || !db.prepare(`PRAGMA table_info(${table})`).all().some((c: any) => c.name === column)) return
    for (const row of db.prepare(`SELECT ${key},${column} FROM ${table}`).all()) {
      const value = JSON.parse(row[column]), next = update(value)
      if (JSON.stringify(next) !== JSON.stringify(value)) jsonChanges.push({ table, column, key, id: row[key], text: JSON.stringify(next) })
    }
  }
  jsonRows('ipad_sync_projection', 'source_json', 'id', value => {
    if (value.courseID && courses.some((c: any) => c.id === value.courseID && c.source === 'linked')) return value
    return { ...value, ...(value.path === undefined ? {} : { path: rebase(value.path) }), ...(value.folder === undefined ? {} : { folder: rebase(value.folder) }),
      ...(value.root === undefined ? {} : { root: rebase(value.root) }) }
  })
  jsonRows('ipad_sync_conflicts', 'assets_json', 'id', value => value.map((asset: any) => ({ ...asset, path: rebase(asset.path) })))
  jsonRows('ipad_legacy_migrations', 'report_json', 'version', value => ({ ...value, ...(value.recoveryPath === undefined ? {} : { recoveryPath: rebase(value.recoveryPath) }) }))
  // This is retry evidence, not a completion marker. In particular a settings-
  // only old installation can lose its last old-root hint after settings publish.
  db.transaction(() => { for (const previous of roots) db.prepare('INSERT OR IGNORE INTO ipad_storage_locations(root) VALUES(?)').run(previous) })()
  for (const change of fileChanges) writeFileAtomic(change.path, JSON.stringify(change.value))
  db.transaction(() => {
    for (const [id, entry] of moved) {
      db.prepare('UPDATE courses SET folder_path=? WHERE id=? AND folder_path=?').run(entry.to, id, entry.from)
      if (hasTable('material_added_baselines')) db.prepare('UPDATE material_added_baselines SET folder=? WHERE course_id=? AND folder=?').run(entry.to, id, entry.from)
    }
    for (const change of jsonChanges) db.prepare(`UPDATE ${change.table} SET ${change.column}=? WHERE ${change.key}=?`).run(change.text, change.id)
    db.prepare('INSERT OR IGNORE INTO ipad_storage_locations(root) VALUES(?)').run(root)
  })()
  return { courses: moved.size, files: fileChanges.length }
}
