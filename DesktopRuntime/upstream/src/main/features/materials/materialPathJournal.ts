import { randomUUID } from 'node:crypto'
import { lstatSync, readdirSync, readFileSync } from 'node:fs'
import { prepareMaterialNoteWrites, type PlannedMaterialNoteWrite } from '../links/renameRepoint'
import { writeFileAtomic } from '../../lib/atomicWrite'
import { join } from 'node:path'
import { assertRealInside, resolveInside } from '../../db/validate'
import { ConflictError, ValidationError } from '../../db/errors'

export interface MaterialPathLock { tryAcquire(): (() => void) | undefined }
export interface MaterialPathChange { courseId: string; fromRelPath: string; toRelPath: string; isDirectory: boolean; noteWritesPrepared?: boolean }
interface Identity { dev: string; ino: string; size: string; mtimeNs: string; ctimeNs: string; directory: boolean; pdfs?: { relativePath: string; identity: Identity }[] }
interface Intent { id: string; course_id: string; folder_path: string; folder_identity: string; from_rel_path: string; to_rel_path: string; original_identity: string; moved_identity: string | null; note_writes: string | null }
const table = 'material_path_intents'
const key = (path: string) => path.normalize('NFC').toLowerCase()
const overlaps = (a: string, b: string) => key(a) === key(b) || key(a).startsWith(`${key(b)}/`) || key(b).startsWith(`${key(a)}/`)

/** Pending paths cannot seed a new, first-observed PDF binding or be exported
 * under a different file after an interrupted rename. This also guards older
 * repositories which do not own the recovery lifecycle. */
export function assertMaterialPathAvailable(db: any, courseId: string, relPath?: string): void {
  if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table)) return
  const hasNotes = db.prepare(`PRAGMA table_info(${table})`).all().some((column: any) => column.name === 'note_writes')
  const pending = db.prepare(`SELECT from_rel_path,to_rel_path${hasNotes ? ',note_writes' : ''} FROM ${table} WHERE course_id=?`).all(courseId)
  const conflict = pending.find((row: any) => relPath === undefined || overlaps(relPath, row.from_rel_path) || overlaps(relPath, row.to_rel_path) ||
    (row.note_writes && JSON.parse(row.note_writes).some((note: PlannedMaterialNoteWrite) => overlaps(relPath, note.relPath))))
  if (conflict) throw new ConflictError(`자료 경로 복구가 필요합니다. "${conflict.from_rel_path}" → "${conflict.to_rel_path}"의 파일과 기록을 보존했습니다. 반달을 다시 연 뒤 확인해 주세요.`)
}
function identity(path: string): Identity {
  const value = lstatSync(path, { bigint: true })
  if ((!value.isFile() && !value.isDirectory()) || [value.dev, value.ino, value.size, value.mtimeNs, value.ctimeNs].some(part => typeof part !== 'bigint')) {
    throw new ValidationError('Material identity cannot be verified for crash recovery')
  }
  return { dev: String(value.dev), ino: String(value.ino), size: String(value.size), mtimeNs: String(value.mtimeNs), ctimeNs: String(value.ctimeNs), directory: value.isDirectory() }
}
function optionalIdentity(path: string): Identity | undefined {
  try { return identity(path) } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error }
}
function same(a: Identity, b: Identity, includeChangeTime = true): boolean {
  // Repointing backlinks atomically replaces Markdown children and legitimately
  // changes a parent directory's metadata before the database commits.
  return a.dev === b.dev && a.ino === b.ino && a.directory === b.directory && (a.directory ||
    a.size === b.size && a.mtimeNs === b.mtimeNs && (!includeChangeTime || a.ctimeNs === b.ctimeNs))
}

function protectedPDFs(folder: string): NonNullable<Identity['pdfs']> {
  const files: NonNullable<Identity['pdfs']> = []
  let visited = 0
  function walk(relativePath: string, depth: number): void {
    if (depth > 64) throw new ValidationError('Material move is too deep to journal safely')
    for (const entry of readdirSync(join(folder, relativePath), { withFileTypes: true })) {
      if (++visited > 100_000) throw new ValidationError('Material move is too large to journal safely')
      const child = relativePath ? `${relativePath}/${entry.name}` : entry.name
      if (entry.isDirectory()) walk(child, depth + 1)
      else if (entry.isFile() && /\.pdf$/i.test(entry.name)) files.push({ relativePath: child, identity: identity(join(folder, child)) })
    }
  }
  walk('', 0); return files
}
function verifyProtectedPDFs(original: Identity, destination: string): void {
  for (const file of original.pdfs ?? []) {
    if (!same(file.identity, identity(assertRealInside(destination, resolveInside(destination, file.relativePath))))) {
      throw new ConflictError('A PDF inside the renamed folder changed; its existing ink was preserved')
    }
  }
}

/** Intent commits are standalone and FULL-synchronous before filesystem work.
 * Never keep the user's database transaction open across an await. */
export function createMaterialPathJournal(db: any, getCourseFolder: (courseId: string) => string) {
  db.exec(`CREATE TABLE IF NOT EXISTS ${table} (
    id TEXT PRIMARY KEY, course_id TEXT NOT NULL, folder_path TEXT NOT NULL,
    folder_identity TEXT NOT NULL, from_rel_path TEXT NOT NULL, to_rel_path TEXT NOT NULL,
    original_identity TEXT NOT NULL, moved_identity TEXT, created_at TEXT NOT NULL
  )`)
  if (!db.prepare(`PRAGMA table_info(${table})`).all().some((column: any) => column.name === 'note_writes')) db.exec(`ALTER TABLE ${table} ADD COLUMN note_writes TEXT`)
  function durable<T>(operation: () => T): T {
    const synchronous = Number(db.pragma('synchronous', { simple: true }))
    db.pragma('synchronous = FULL')
    try { return operation() } finally { db.pragma(`synchronous = ${synchronous}`) }
  }
  function paths(intent: Intent) {
    // iOS can relocate an app container on update. Trust the stable folder
    // inode, not its former absolute prefix; relinking to other bytes still fails.
    const folderPath = getCourseFolder(intent.course_id)
    const folder = identity(folderPath), originalFolder: Identity = JSON.parse(intent.folder_identity)
    if (!folder.directory || folder.dev !== originalFolder.dev || folder.ino !== originalFolder.ino) throw new ConflictError('Course folder was replaced during material recovery')
    const source = assertRealInside(folderPath, resolveInside(folderPath, intent.from_rel_path))
    const destination = assertRealInside(folderPath, resolveInside(folderPath, intent.to_rel_path))
    return { source, destination, folderPath }
  }
  function plannedNotes(intent: Intent): PlannedMaterialNoteWrite[] { return intent.note_writes === null ? [] : JSON.parse(intent.note_writes) }
  function stableMarkdown(path: string): string {
    const before = identity(path)
    if (before.directory) throw new ConflictError('A note was replaced by a directory')
    const markdown = readFileSync(path, 'utf8')
    if (!same(before, identity(path))) throw new ConflictError('Note changed while preparing recovery')
    return markdown
  }
  function isCompletedNote(intent: Intent, destination: string): boolean {
    const note = plannedNotes(intent).find(note => note.relPath === intent.to_rel_path)
    return !!note && stableMarkdown(destination) === note.after
  }
  function writePlannedNotes(intent: Intent, folder: string): void {
    for (const note of plannedNotes(intent)) {
      const target = () => assertRealInside(folder, resolveInside(folder, note.relPath))
      const current = stableMarkdown(target())
      if (current === note.after) continue
      if (current !== note.before) throw new ConflictError(`Note changed outside this rename: ${note.relPath}; original, proposed and current text were preserved`)
      writeFileAtomic(target(), note.after, { mode: note.mode, beforePublish: () => {
        // Check again after staging/fsync, and on every Windows retry. A newer
        // editor write must never be replaced by our older captured body.
        if (stableMarkdown(target()) !== note.before) throw new ConflictError(`Note changed before publishing rename: ${note.relPath}`)
      } })
    }
  }
  function begin(change: MaterialPathChange, folder: string, heading?: { before: string; after: string }): string {
    assertMaterialPathAvailable(db, change.courseId)
    const source = assertRealInside(folder, resolveInside(folder, change.fromRelPath)), destination = assertRealInside(folder, resolveInside(folder, change.toRelPath))
    if (source !== destination && optionalIdentity(destination)) throw new ConflictError('Material destination already exists')
    const sourceIdentity = identity(source)
    if (sourceIdentity.directory) sourceIdentity.pdfs = protectedPDFs(source)
    if (sourceIdentity.directory !== change.isDirectory) throw new ConflictError('Material type changed before rename')
    const notes = prepareMaterialNoteWrites({ ...change, db, courseFolder: folder }, heading)
    if (!same(sourceIdentity, identity(source))) throw new ConflictError('Material changed while preparing rename recovery')
    const id = randomUUID()
    durable(() => db.prepare(`INSERT INTO ${table}(id,course_id,folder_path,folder_identity,from_rel_path,to_rel_path,original_identity,created_at,note_writes) VALUES(?,?,?,?,?,?,?,?,?)`)
      .run(id, change.courseId, folder, JSON.stringify(identity(folder)), change.fromRelPath, change.toRelPath, JSON.stringify(sourceIdentity), new Date().toISOString(), JSON.stringify(notes)))
    return id
  }
  const find = (id: string): Intent => {
    const value = db.prepare(`SELECT * FROM ${table} WHERE id=?`).get(id)
    if (!value) throw new ValidationError('Material path recovery intent is missing')
    return value
  }
  const remove = (id: string) => db.prepare(`DELETE FROM ${table} WHERE id=?`).run(id)
  function markMoved(id: string): void {
    const intent = find(id), { source, destination } = paths(intent), moved = identity(destination)
    if (source !== destination && optionalIdentity(source) || !same(JSON.parse(intent.original_identity), moved, false)) throw new ConflictError('Material changed while rename was in progress')
    verifyProtectedPDFs(JSON.parse(intent.original_identity), destination)
    durable(() => db.prepare(`UPDATE ${table} SET moved_identity=? WHERE id=?`).run(JSON.stringify(moved), id))
  }
  function complete(id: string, apply: (change: MaterialPathChange) => void): void {
    const intent = find(id), { source, destination, folderPath } = paths(intent), moved = identity(destination)
    if (source !== destination && optionalIdentity(source) ||
      !same(JSON.parse(intent.moved_identity ?? intent.original_identity), moved, intent.moved_identity !== null) && !isCompletedNote(intent, destination)) throw new ConflictError('Material paths changed before recovery could finish')
    verifyProtectedPDFs(JSON.parse(intent.original_identity), destination)
    // File effects finish outside the SQL transaction. Their before/after text
    // is already durable, so a killed atomic replacement is safely replayable.
    writePlannedNotes(intent, folderPath)
    durable(() => db.transaction(() => {
      apply({ courseId: intent.course_id, fromRelPath: intent.from_rel_path, toRelPath: intent.to_rel_path, isDirectory: moved.directory, ...(intent.note_writes !== null ? { noteWritesPrepared: true } : {}) })
      remove(id)
    })())
  }
  /** Only erase a failed/not-started intent when the original inode is still at
   * the original path and the destination is absent. No recovery overwrites. */
  function discardIfOriginal(id: string): boolean {
    const intent = find(id), { source, destination } = paths(intent), original = optionalIdentity(source)
    if (source === destination) return false
    if (!original || optionalIdentity(destination) || !same(JSON.parse(intent.original_identity), original, false)) return false
    verifyProtectedPDFs(JSON.parse(intent.original_identity), source)
    durable(() => remove(id)); return true
  }
  function recover(apply: (change: MaterialPathChange) => void, report: (error: unknown) => void): void {
    // Caller must hold the cross-process lock throughout this synchronous pass.
    for (const { id } of db.prepare(`SELECT id FROM ${table} ORDER BY created_at,id`).all()) {
      try { if (!discardIfOriginal(id)) complete(id, apply) } catch (error) { report(error) }
    }
  }
  return { begin, markMoved, complete, discardIfOriginal, recover }
}
