/**
 * Materials repository. Source of truth is the course folder on disk;
 * `materials_index` is a rebuildable cache used by search and the dossier.
 */

import {
  cpSync, copyFileSync, existsSync, lstatSync, mkdirSync,
  renameSync, statSync, unlinkSync,
  writeFileSync
} from 'node:fs'
import { readFile, stat, realpath } from 'node:fs/promises'
import { basename, extname, isAbsolute, join, posix, sep, relative } from 'node:path'
import { randomUUID } from 'node:crypto'
import { traceSyncWork } from '../../performanceTrace'
import type { Database } from 'better-sqlite3'
import type { ImportResult, MaterialFileContent, MaterialKind,
  MaterialNode, MaterialSearchHit } from '../../../shared/types/materials'
import { scanMaterialTree, type MaterialWalk, type ScanTruncation } from './scanMaterialTree'
import { renameWithRetry } from './renameWithRetry'
import { assertMaterialPathAvailable, createMaterialPathJournal, type MaterialPathLock } from './materialPathJournal'
import { createMaterialAddedState } from './materialAddedState'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import { assertRealInside, nowIso, requireId, requireNonEmptyString,
  resolveInside } from '../../db/validate'

export interface MaterialsRepo {
  /** Called after dependent repositories are initialized, before exposing data. */
  recoverPathChanges(): void
  tree(courseId: string): Promise<MaterialNode[]>
  snapshot(courseId: string): MaterialNode[] | null
  search(courseId: string, query: string): Promise<MaterialSearchHit[]>
  /**
   * 캐시된 트리를 버린다. 저장소 자신의 변이는 내부에서 알아서 무효화하므로,
   * 밖에서(watcher, 에이전트의 직접 파일 쓰기 등) 폴더가 바뀌었을 때만
   * 호출하면 된다.
   */
  invalidateTree(courseId: string): void
  /** Record an explicit creation, including before a course's first scan. */
  recordAdded(courseId: string, relPath: string): void
  repointAddedState(courseId: string, fromRelPath: string, toRelPath: string, isDirectory: boolean): void
  /** 경로 이탈 가드를 거친 절대 경로. 네이티브 파일 드래그(startDrag)용. */
  absolutePathFor(courseId: string, relPath: string): string
  absolutePathForAsync(courseId: string, relPath: string): Promise<string>
  /** `dirRelPath` ''/생략 = 과목 폴더 루트. */
  import(courseId: string, paths: string[], dirRelPath?: string): ImportResult
  /** 파일/폴더를 다른 과목-상대 디렉터리로 옮긴다 ('' = 루트). */
  move(input: { courseId: string; fromRelPath: string; toDirRelPath: string }): Promise<{ relPath: string }>
  readFile(courseId: string, relPath: string): Promise<MaterialFileContent>
  reveal(courseId: string, relPath: string): { ok: true }
  rename(input: { courseId: string; relPath: string; newName: string }): Promise<{ relPath: string }>
  softDelete(input: { courseId: string; relPath: string }): Promise<{ ok: true }>
  duplicate(input: { courseId: string; relPath: string }): { relPath: string }
  createFolder(input: { courseId: string; dirRelPath: string; name: string }): { relPath: string }
  writeFile(input: {
    courseId: string
    dirRelPath: string
    createDirIfMissing?: boolean
    fileName: string
    encoding: 'utf8' | 'base64'
    data: string
  }): { relPath: string }
  /**
   * Moves an already-written file into the course folder.
   *
   * `writeFile` takes the whole payload as a string, which is fine for a note
   * but would hold a 300MB lecture video in memory. A browser download is
   * streamed to a staging path by Chromium and then adopted here, so the bytes
   * never pass through the main process — but every path guard `writeFile`
   * runs still applies.
   */
  adoptFile(input: { courseId: string; dirRelPath: string; fileName: string
    /** Absolute path of the staged file. It is consumed (moved). */
    sourcePath: string
  }): { relPath: string }
}

export interface MaterialsRepoDeps {
  db: Database
  /** Absolute course folder for a live course id (throws otherwise). */
  getCourseFolder: (courseId: string) => string
  /** Reveals an absolute path in the OS file manager (electron shell). */
  revealItem: (absPath: string) => void
  /** Moves an absolute path to the OS trash (electron shell.trashItem). */
  trashItem: (absPath: string) => Promise<void>
  /** Required in production: shared with every process using this material DB. */
  pathLock?: MaterialPathLock
  /** Production uses the exported defaults; tests may lower them. */
  scan?: typeof scanMaterialTree
  scanLimits?: MaterialsScanLimits
  onIndexBuilt?: () => void
  onPathChanged?: (change: { courseId: string; fromRelPath: string; toRelPath: string; isDirectory: boolean }) => void
  /** Await native watcher close before a path mutation; restore it afterwards. */
  pauseWatching?: (courseId: string) => Promise<() => Promise<void>>
}

export interface MaterialsScanLimits {
  maxDepth: number
  maxEntries: number
}

/**
 * Comparison form for filename search.
 *
 * NFC because macOS stores Korean filenames decomposed (NFD) while IME input
 * produces composed (NFC) — without this, searching a Hangul filename that is
 * visibly right in the tree returns nothing. Never use this for filesystem
 * access; it is a matching key only.
 */
export function searchKey(value: string): string {
  return value.normalize('NFC').toLowerCase()
}

const TEXT_EXTENSIONS = new Set([
  '.md', '.markdown', '.txt', '.csv', '.tsv', '.json', '.yml', '.yaml',
  '.xml', '.html', '.css', '.js', '.ts', '.tex', '.log', '.srt', '.vtt'
])
/** Files larger than this are refused by readFile (base64 over IPC). */
const MAX_READ_BYTES = 64 * 1024 * 1024
/** Clipboard payloads are copied over IPC, so cap their decoded size. */
export const MAX_WRITE_BYTES = 50 * 1024 * 1024

/**
 * Twelve nested folders covers ordinary course layouts while bounding hostile
 * or accidentally generated directory chains. Root entries are depth zero.
 */
export const MATERIAL_SCAN_MAX_DEPTH = 12
/**
 * Twenty thousand directory entries is well beyond a normal course, but puts
 * a finite ceiling on background filesystem work.
 */
export const MATERIAL_SCAN_MAX_ENTRIES = 20_000

export const MATERIAL_TREE_TRUNCATION_REL_PATH =
  '.bandal/__materials_scan_truncated__'
export const MATERIAL_INDEX_STATE_REL_PATH = '.bandal/__materials_index_state__'

const TRUNCATED_BY_DEPTH = 1
const TRUNCATED_BY_ENTRY_COUNT = 2
export { kindForFile } from './scanMaterialTree'
function truncationNode(
  truncation: Set<ScanTruncation>,
  limits: MaterialsScanLimits
): MaterialNode {
  const reasons: string[] = []
  if (truncation.has('depth')) {
    reasons.push(`깊이 ${limits.maxDepth}`)
  }
  if (truncation.has('entries')) {
    reasons.push(`엔트리 ${limits.maxEntries.toLocaleString()}개`)
  }
  return {
    relPath: MATERIAL_TREE_TRUNCATION_REL_PATH,
    name: `⚠ 일부 자료만 표시됨 — 스캔 상한(${reasons.join(', ')}) 도달`,
    kind: 'dir',
    children: []
  }
}

/** Picks `name.ext`, `name (2).ext`, … until the target does not exist. */
function unusedTargetName(dir: string, fileName: string): string {
  const ext = extname(fileName)
  const stem = basename(fileName, ext)
  for (let n = 1; n < 1000; n += 1) {
    const candidate = n === 1 ? fileName : `${stem} (${n})${ext}`
    if (!existsSync(join(dir, candidate))) {
      return candidate
    }
  }
  throw new ValidationError(`could not find a free name for "${fileName}"`)
}

/** Picks `name-2.ext`, `name-3.ext`, …, matching duplicate's convention. */
function unusedDuplicateName(dir: string, fileName: string): string {
  const extension = extname(fileName)
  const stem = extension === '' ? fileName : basename(fileName, extension)
  for (let number = 2; number <= 1000; number += 1) {
    const candidate = `${stem}-${number}${extension}`
    if (!existsSync(join(dir, candidate))) return candidate
  }
  throw new ValidationError(`could not find a free name for "${fileName}"`)
}

function decodeWriteData(
  encoding: unknown,
  data: unknown
): Buffer {
  if (encoding !== 'utf8' && encoding !== 'base64') {
    throw new ValidationError('encoding must be "utf8" or "base64"')
  }
  if (typeof data !== 'string') {
    throw new ValidationError('data must be a string')
  }

  const byteLength = Buffer.byteLength(data, encoding)
  if (byteLength > MAX_WRITE_BYTES) {
    throw new ValidationError(
      `material is too large to write over IPC (${byteLength} bytes; maximum ${MAX_WRITE_BYTES} bytes)`
    )
  }
  const bytes = Buffer.from(data, encoding)
  // Keep the post-decode check too: malformed base64 must never bypass the cap.
  if (bytes.byteLength > MAX_WRITE_BYTES) {
    throw new ValidationError(
      `material is too large to write over IPC (${bytes.byteLength} bytes; maximum ${MAX_WRITE_BYTES} bytes)`
    )
  }
  return bytes
}

/**
 * Validates a single filesystem entry name. Unlike a path sanitizer, this
 * rejects separators instead of deleting them: renderer input must never be
 * transformed into a different path and then accepted.
 */
function requireBasename(value: unknown, field: string): string {
  const name = requireNonEmptyString(value, field).trim()
  if (name.includes('/') || name.includes('\\')) {
    throw new ValidationError(`${field} must be a basename without path separators`)
  }
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f]/.test(name)) {
    throw new ValidationError(`${field} contains control characters`)
  }
  if (name === '.' || name === '..') {
    throw new ValidationError(`${field} must name a file or folder`)
  }
  if (/[:*?"<>|]/.test(name)) {
    throw new ValidationError(`${field} contains filesystem-hostile characters`)
  }
  if (name.length > 120) {
    throw new ValidationError(`${field} must be at most 120 characters`)
  }
  return name
}

function assertFileOrDirectory(absPath: string, relPath: string): 'file' | 'dir' {
  if (!existsSync(absPath)) {
    throw new NotFoundError('material', relPath)
  }
  const stat = lstatSync(absPath)
  if (stat.isFile()) return 'file'
  if (stat.isDirectory()) return 'dir'
  throw new ValidationError(`"${relPath}" is not a regular file or directory`)
}

function resolveCoursePath(
  folder: string,
  relPath: string,
  allowRoot = false
): string {
  const abs = resolveInside(
    folder,
    relPath,
    allowRoot ? { allowRoot: true } : {}
  )
  return assertRealInside(folder, abs)
}

export function createMaterialsRepo(deps: MaterialsRepoDeps): MaterialsRepo {
  const { db, getCourseFolder, revealItem, trashItem } = deps
  const addedState = createMaterialAddedState(db, getCourseFolder)
  const scanLimits = deps.scanLimits ?? {
    maxDepth: MATERIAL_SCAN_MAX_DEPTH,
    maxEntries: MATERIAL_SCAN_MAX_ENTRIES
  }

  const treeCache = new Map<string, { folder: string; nodes: MaterialNode[] }>()
  const generations = new Map<string, number>()
  const scans = new Map<string, Promise<MaterialNode[]>>()
  const scanWork = new Map<string, Promise<MaterialNode[] | null>>()
  const mutationTails = new Map<string, Promise<unknown>>()
  const scanGates = new Map<string, Promise<void>>()
  db.exec(`CREATE TABLE IF NOT EXISTS material_tree_snapshots (
    course_id TEXT PRIMARY KEY REFERENCES courses(id) ON DELETE CASCADE,
    folder TEXT NOT NULL, tree TEXT NOT NULL
  )`)
  const journal = createMaterialPathJournal(db, getCourseFolder)
  let localLockHeld = false
  const pathLock = deps.pathLock ?? { tryAcquire() {
    if (localLockHeld) return undefined
    localLockHeld = true
    return () => { localLockHeld = false }
  } }
  const applyPathChange = (change: { courseId: string; fromRelPath: string; toRelPath: string; isDirectory: boolean }) => {
    addedState.repoint(change.courseId, change.fromRelPath, change.toRelPath, change.isDirectory)
    deps.onPathChanged?.(change)
    invalidate(change.courseId)
  }
  const recoverLocked = () => journal.recover(applyPathChange, error => console.error('[materials] preserved interrupted path change:', error))
  function recoverPathChanges(): void {
    // A local-only test repository must not recover a live, other process.
    if (!deps.pathLock) return
    const unlock = pathLock.tryAcquire()
    if (!unlock) return
    try { recoverLocked() } finally { unlock() }
  }
  function invalidate(courseId: string): void {
    treeCache.delete(courseId)
    generations.set(courseId, (generations.get(courseId) ?? 0) + 1)
  }

  function completePathChange(courseId: string, fromRelPath: string, toRelPath: string, intent: string): void {
    try {
      journal.markMoved(intent)
      // Backlink files may already have been atomically rewritten by the
      // callback. Keep filesystem movement monotonic; a retry completes SQL
      // and PDF identity at the same new path instead of undoing those links.
      journal.complete(intent, applyPathChange)
    } catch (error) {
      throw new Error(`자료 경로 변경을 마무리하지 못했습니다. "${fromRelPath}" → "${toRelPath}"의 파일과 이전 필기 기록을 보존했으며 다음 실행에서 다시 확인합니다. ${String(error)}`, { cause: error })
    } finally { invalidate(courseId) }
  }

  function mutatePath<T>(courseId: string, operation: () => Promise<T>): Promise<T> {
    const id = requireId(courseId, 'courseId')
    const previous = mutationTails.get(id) ?? Promise.resolve()
    const task = previous.catch(() => undefined).then(async () => {
      let release!: () => void
      const gate = new Promise<void>(resolve => { release = resolve })
      scanGates.set(id, gate)
      let resume: (() => Promise<void>) | undefined
      let unlock: (() => void) | undefined
      try {
        resume = await deps.pauseWatching?.(id)
        // Drain the real walk/index work, not scans' invalidation continuation:
        // that continuation may need to rescan and therefore await our gate.
        await scanWork.get(id)?.catch(() => undefined)
        unlock = pathLock.tryAcquire()
        if (!unlock) throw new ConflictError('다른 반달 작업에서 자료 경로를 변경 중입니다. 잠시 후 다시 시도해 주세요.')
        if (deps.pathLock) recoverLocked()
        assertMaterialPathAvailable(db, id)
        return await operation()
      } finally {
        unlock?.()
        try { await resume?.() } catch (error) {
          console.error(`[materials] watcher restoration failed for ${id}:`, error)
        }
        scanGates.delete(id)
        release()
      }
    })
    mutationTails.set(id, task)
    void task.finally(() => { if (mutationTails.get(id) === task) mutationTails.delete(id) }).catch(() => undefined)
    return task
  }

  function requireCourseFolder(courseId: string): { id: string; folder: string } {
    const id = requireId(courseId, 'courseId')
    assertMaterialPathAvailable(db, id)
    const folder = getCourseFolder(id)
    if (!existsSync(folder)) {
      throw new NotFoundError('course folder', folder)
    }
    return { id, folder }
  }

  /** Apply only changed cache rows in bounded transactions; never hold a
   * write lock across an await or monopolize the main event loop. */
  async function rebuildIndex(courseId: string, scan: MaterialWalk, current: () => boolean): Promise<void> {
    const now = nowIso()
    const existing = new Map((db.prepare('SELECT rel_path, kind, size, mtime FROM materials_index WHERE course_id = ?')
      .all(courseId) as { rel_path: string; kind: string; size: number; mtime: number }[]).map(row => [row.rel_path, row]))
    const files = [...scan.files, {
      relPath: MATERIAL_INDEX_STATE_REL_PATH, kind: 'other', size:
        (scan.truncation.has('depth') ? TRUNCATED_BY_DEPTH : 0) |
        (scan.truncation.has('entries') ? TRUNCATED_BY_ENTRY_COUNT : 0), mtime: Date.now()
    }]
    const upsert = db.prepare(`INSERT INTO materials_index
      (id, course_id, rel_path, kind, size, mtime, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(course_id, rel_path) DO UPDATE SET kind=excluded.kind,
        size=excluded.size, mtime=excluded.mtime, updated_at=excluded.updated_at, deleted_at=NULL`)
    for (let offset = 0; offset < files.length; offset += 100) {
      if (!current()) return
      traceSyncWork('materials.indexBatch', () => db.transaction(() => {
        for (const file of files.slice(offset, offset + 100)) {
          const old = existing.get(file.relPath)
          existing.delete(file.relPath)
          if (old?.kind === file.kind && old.size === file.size && old.mtime === file.mtime) continue
          upsert.run(randomUUID(), courseId, file.relPath, file.kind, file.size ?? 0, file.mtime ?? 0, now, now)
        }
      })())
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
    // A capped scan is not proof that an unvisited file was deleted.
    if (scan.truncation.size > 0) return
    const stale = [...existing.keys()]
    const remove = db.prepare('DELETE FROM materials_index WHERE course_id = ? AND rel_path = ?')
    for (let offset = 0; offset < stale.length; offset += 100) {
      if (!current()) return
      traceSyncWork('materials.pruneBatch', () => db.transaction(() => { for (const path of stale.slice(offset, offset + 100)) remove.run(courseId, path) })())
      await new Promise<void>(resolve => setTimeout(resolve, 0))
    }
  }

  function resolveMaterialAbs(courseId: string, relPath: string): string {
    const { abs } = resolveMaterial(courseId, relPath)
    if (!existsSync(abs)) {
      throw new NotFoundError('material', relPath)
    }
    return abs
  }

  function resolveMaterial(courseId: string, relPath: string): { abs: string; folder: string } {
    const { folder } = requireCourseFolder(courseId)
    const abs = resolveCoursePath(folder, requireNonEmptyString(relPath, 'relPath'))
    return { abs, folder }
  }

  async function cachedTree(courseId: string, folder: string): Promise<MaterialNode[]> {
    const gate = scanGates.get(courseId)
    if (gate) { await gate; return cachedTree(courseId, getCourseFolder(courseId)) }
    assertMaterialPathAvailable(db, courseId)
    const cached = treeCache.get(courseId)
    if (cached?.folder === folder) return cached.nodes
    const pending = scans.get(courseId)
    if (pending) return pending
    const generation = generations.get(courseId) ?? 0
    const current = (): boolean => (generations.get(courseId) ?? 0) === generation && getCourseFolder(courseId) === folder
    const work = (async () => {
      let scan: MaterialWalk
      let rootDisappeared = false
      try { scan = await (deps.scan ?? scanMaterialTree)(folder, scanLimits) }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        // A disappearing child must not replace the whole course with an empty tree.
        try { await stat(folder); throw error } catch (rootError) {
          if (rootError === error || (rootError as NodeJS.ErrnoException).code !== 'ENOENT') throw rootError
        }
        rootDisappeared = true
        scan = { nodes: [], files: [], truncation: new Set() }
      }
      if (!current()) return null
      await rebuildIndex(courseId, scan, current)
      if (!current()) return null
      await addedState.reconcile(courseId, scan.files, scan.truncation.size === 0 && !rootDisappeared, current)
      if (!current()) return null
      if (scan.truncation.size > 0) scan.nodes.push(truncationNode(scan.truncation, scanLimits))
      const nodes = addedState.decorate(courseId, scan.nodes)
      treeCache.set(courseId, { folder, nodes })
      if (treeCache.size > 16) treeCache.delete(treeCache.keys().next().value!)
      traceSyncWork('materials.snapshotWrite', () => db.prepare('INSERT OR REPLACE INTO material_tree_snapshots (course_id, folder, tree) VALUES (?, ?, ?)')
        .run(courseId, folder, JSON.stringify(nodes)))
      deps.onIndexBuilt?.()
      return nodes
    })()
    scanWork.set(courseId, work)
    void work.finally(() => { if (scanWork.get(courseId) === work) scanWork.delete(courseId) }).catch(() => undefined)
    const task = work.then(async result => {
      scans.delete(courseId)
      return result ?? cachedTree(courseId, getCourseFolder(courseId))
    }, error => { scans.delete(courseId); throw error })
    scans.set(courseId, task)
    return task
  }

  async function absolutePathForAsync(courseId: string, relPath: string): Promise<string> {
    assertMaterialPathAvailable(db, courseId, relPath)
    const folder = getCourseFolder(requireId(courseId, 'courseId'))
    const abs = resolveInside(folder, requireNonEmptyString(relPath, 'relPath'))
    const [root, target] = await Promise.all([realpath(folder), realpath(abs)])
    const rel = relative(root, target)
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) throw new ValidationError('path resolves outside the course folder')
    return abs
  }

  return {
    recoverPathChanges,
    absolutePathForAsync,
    absolutePathFor(courseId, relPath) {
      return resolveMaterialAbs(courseId, relPath)
    },

    invalidateTree(courseId) { invalidate(requireId(courseId, 'courseId')) },
    recordAdded(courseId, relPath) {
      const id = requireId(courseId, 'courseId')
      resolveMaterialAbs(id, relPath)
      addedState.recordAdded(id, relPath)
      invalidate(id)
    },
    repointAddedState(courseId, fromRelPath, toRelPath, isDirectory) {
      addedState.repoint(requireId(courseId, 'courseId'), fromRelPath, toRelPath, isDirectory)
      invalidate(courseId)
    },

    snapshot(courseId) {
      const id = requireId(courseId, 'courseId'), folder = getCourseFolder(id)
      const cached = treeCache.get(id)
      if (cached?.folder === folder) return cached.nodes
      const row = db.prepare('SELECT tree FROM material_tree_snapshots WHERE course_id = ? AND folder = ?').get(id, folder) as { tree: string } | undefined
      try {
        if (!row) return null
        const value: unknown = JSON.parse(row.tree)
        const valid = (nodes: unknown, depth = 0): nodes is MaterialNode[] =>
          depth <= MATERIAL_SCAN_MAX_DEPTH + 1 && Array.isArray(nodes) && nodes.length <= MATERIAL_SCAN_MAX_ENTRIES + 1 && nodes.every(node =>
            node !== null && typeof node === 'object' && typeof node.relPath === 'string' && typeof node.name === 'string' &&
            typeof node.kind === 'string' && (node.kind !== 'dir' || valid(node.children ?? [], depth + 1)))
        return valid(value) ? addedState.decorate(id, value) : null
      } catch { return null }
    },

    async tree(courseId) {
      const id = requireId(courseId, 'courseId')
      const folder = getCourseFolder(id)
      // Async existence check also detects removed roots on a warm cache.
      try { await stat(folder) } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        invalidate(id)
        return []
      }
      return cachedTree(id, folder)
    },

    async search(courseId, query) {
      const id = requireId(courseId, 'courseId')
      const needle = searchKey(requireNonEmptyString(query, 'query').trim())
      await cachedTree(id, getCourseFolder(id))

      // Matching happens in JS, not in SQL, because SQLite's `instr` compares
      // bytes. macOS hands back decomposed (NFD) filenames from readdir while
      // a query typed with a Korean IME arrives composed (NFC), so
      // `instr(lower(rel_path), '과제')` finds nothing for a file the student
      // can plainly see in the tree. Comparing NFC-normalized forms fixes it.
      //
      // The STORED rel_path is deliberately left untouched — it is the
      // filesystem's own spelling, and every read/open path resolves against
      // it. Normalizing what we persist would break opening the very files
      // this makes findable.
      const rows = db
        .prepare(
          `SELECT rel_path, kind FROM materials_index
           WHERE course_id = ?
             AND deleted_at IS NULL
             AND rel_path != ?
           ORDER BY rel_path ASC`
        )
        .all(id, MATERIAL_INDEX_STATE_REL_PATH) as {
          rel_path: string
          kind: MaterialKind
        }[]

      const added = addedState.timestamps(id)
      return rows
        .filter((row) => searchKey(row.rel_path).includes(needle))
        .map((row) => {
          const name = posix.basename(row.rel_path)
          const nameKey = searchKey(name)
          let score = 1
          if (nameKey.includes(needle)) score = 2
          if (nameKey.startsWith(needle)) score = 3
          const addedAt = added.get(row.rel_path)
          return { relPath: row.rel_path, name, kind: row.kind, score, ...(addedAt === undefined ? {} : { addedAt }) }
        })
        .sort((a, b) => b.score - a.score || a.relPath.localeCompare(b.relPath))
    },

    import(courseId, paths, dirRelPath) {
      const id = requireId(courseId, 'courseId')
      const folder = getCourseFolder(id)
      // An arbitrary course folder can disappear (moved / unmounted); never
      // re-create it silently under a stale path.
      if (!existsSync(folder)) {
        throw new NotFoundError('course folder', folder)
      }
      if (!Array.isArray(paths) || paths.length === 0) {
        throw new ValidationError('paths must be a non-empty array')
      }
      if (dirRelPath !== undefined && typeof dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      // '' 또는 생략 = 과목 폴더 루트. 하위 폴더는 존재하는 디렉터리여야 한다.
      const targetDirRel = dirRelPath ?? ''
      const targetDirAbs = resolveCoursePath(folder, targetDirRel, true)
      if (!existsSync(targetDirAbs) || !lstatSync(targetDirAbs).isDirectory()) {
        throw new NotFoundError('material directory', targetDirRel)
      }

      const imported: string[] = []
      const failed: ImportResult['failed'] = []
      for (const sourcePath of paths) {
        try {
          const source = requireNonEmptyString(sourcePath, 'path')
          if (!isAbsolute(source)) {
            throw new ValidationError(`"${source}" is not an absolute path`)
          }
          if (!existsSync(source)) {
            throw new NotFoundError('file', source)
          }
          if (!statSync(source).isFile()) {
            throw new ValidationError(`"${source}" is not a regular file`)
          }
          const targetName = unusedTargetName(targetDirAbs, basename(source))
          const targetAbs = join(targetDirAbs, targetName)
          assertRealInside(folder, targetAbs)
          copyFileSync(source, targetAbs)
          const importedPath = targetDirRel === '' ? targetName : posix.join(targetDirRel, targetName)
          imported.push(importedPath)
          addedState.recordAdded(id, importedPath)
        } catch (error) {
          const reason = error instanceof Error ? error.message : String(error)
          failed.push({ path: String(sourcePath), reason })
        }
      }
      if (imported.length > 0) invalidate(id)
      return { imported, failed }
    },

    async move(input) {
      const { abs: sourceAbs, folder } = resolveMaterial(
        input.courseId,
        input.fromRelPath
      )
      const sourceKind = assertFileOrDirectory(sourceAbs, input.fromRelPath)
      if (typeof input.toDirRelPath !== 'string') {
        throw new ValidationError('toDirRelPath must be a string')
      }
      const destDirAbs = resolveCoursePath(folder, input.toDirRelPath, true)
      if (!existsSync(destDirAbs) || !lstatSync(destDirAbs).isDirectory()) {
        throw new NotFoundError('material directory', input.toDirRelPath)
      }
      // 폴더를 자기 자신이나 그 하위로 옮기면 파일계가 꼬인다 — 거부한다.
      if (destDirAbs === sourceAbs || destDirAbs.startsWith(sourceAbs + sep)) {
        throw new ValidationError('폴더를 자기 안으로 옮길 수 없습니다')
      }
      const name = posix.basename(input.fromRelPath)
      const parentRelPath = posix.dirname(input.fromRelPath)
      const parentAbs =
        parentRelPath === '.' ? folder : resolveCoursePath(folder, parentRelPath)
      // 같은 폴더로의 이동은 no-op — 충돌 개명이 이름만 바꾸는 사고를 막는다.
      if (parentAbs === destDirAbs) {
        return { relPath: input.fromRelPath }
      }
      const targetName = unusedTargetName(destDirAbs, name)
      const relPath =
        input.toDirRelPath === ''
          ? targetName
          : posix.join(input.toDirRelPath, targetName)
      const destAbs = resolveCoursePath(folder, relPath)
      return mutatePath(input.courseId, async () => {
        const intent = journal.begin({ courseId: input.courseId, fromRelPath: input.fromRelPath, toRelPath: relPath, isDirectory: sourceKind === 'dir' }, folder)
        try {
          await renameWithRetry(sourceAbs, destAbs, () => {
            if (getCourseFolder(input.courseId) !== folder) throw new ValidationError('과목 폴더가 변경되었습니다. 자료 목록을 새로고침하고 다시 시도하세요.')
            assertRealInside(folder, sourceAbs)
            assertRealInside(folder, destDirAbs)
            assertRealInside(folder, destAbs)
            assertFileOrDirectory(sourceAbs, input.fromRelPath)
            if (!existsSync(destDirAbs) || !lstatSync(destDirAbs).isDirectory()) {
              throw new NotFoundError('material directory', input.toDirRelPath)
            }
            if (destDirAbs === sourceAbs || destDirAbs.startsWith(sourceAbs + sep)) {
              throw new ValidationError('폴더를 자기 안으로 옮길 수 없습니다')
            }
            if (existsSync(destAbs)) throw new ConflictError(`material "${relPath}" already exists`)
          })
          const courseId = requireId(input.courseId, 'courseId')
          completePathChange(courseId, input.fromRelPath, relPath, intent)
          return { relPath }
        } catch (error) {
          try { journal.discardIfOriginal(intent) } catch { /* Preserve unresolved intent and the original error. */ }
          throw error
        }
      })
    },

    async readFile(courseId, relPath) {
      const abs = await absolutePathForAsync(courseId, relPath)
      const info = await stat(abs).catch((error: NodeJS.ErrnoException) => {
        if (error.code === 'ENOENT') throw new NotFoundError('material', relPath)
        throw error
      })
      if (!info.isFile()) throw new NotFoundError('material', relPath)
      const size = info.size
      if (size > MAX_READ_BYTES) {
        const sizeMb = Math.round(size / (1024 * 1024))
        throw new ValidationError(
          `"${relPath}" 파일이 너무 커서 열 수 없어요 (${sizeMb}MB — 최대 64MB)`
        )
      }
      const ext = extname(abs).toLowerCase()
      if (TEXT_EXTENSIONS.has(ext)) {
        return { encoding: 'utf8', data: await readFile(abs, 'utf8') }
      }
      return { encoding: 'base64', data: (await readFile(abs)).toString('base64') }
    },

    reveal(courseId, relPath) {
      const { abs } = resolveMaterial(courseId, relPath)
      if (!existsSync(abs)) {
        throw new NotFoundError('material', relPath)
      }
      revealItem(abs)
      return { ok: true }
    },

    async rename(input) {
      const { abs: sourceAbs, folder } = resolveMaterial(
        input.courseId,
        input.relPath
      )
      const sourceKind = assertFileOrDirectory(sourceAbs, input.relPath)
      const newName = requireBasename(input.newName, 'newName')
      const parentRelPath = posix.dirname(input.relPath)
      const destinationRelPath =
        parentRelPath === '.' ? newName : posix.join(parentRelPath, newName)
      // Validate the destination independently before any existence check or
      // mutation. This remains necessary even though newName is a basename.
      const destinationAbs = resolveCoursePath(folder, destinationRelPath)
      if (destinationAbs === sourceAbs) return { relPath: input.relPath }
      if (existsSync(destinationAbs)) {
        throw new ConflictError(`material "${destinationRelPath}" already exists`)
      }
      return mutatePath(input.courseId, async () => {
        const intent = journal.begin({ courseId: input.courseId, fromRelPath: input.relPath, toRelPath: destinationRelPath, isDirectory: sourceKind === 'dir' }, folder)
        try {
          await renameWithRetry(sourceAbs, destinationAbs, () => {
            if (getCourseFolder(input.courseId) !== folder) throw new ValidationError('과목 폴더가 변경되었습니다. 자료 목록을 새로고침하고 다시 시도하세요.')
            assertRealInside(folder, sourceAbs)
            assertRealInside(folder, destinationAbs)
            assertFileOrDirectory(sourceAbs, input.relPath)
            if (existsSync(destinationAbs)) throw new ConflictError(`material "${destinationRelPath}" already exists`)
          })
          const courseId = requireId(input.courseId, 'courseId')
          completePathChange(courseId, input.relPath, destinationRelPath, intent)
          return { relPath: destinationRelPath }
        } catch (error) {
          try { journal.discardIfOriginal(intent) } catch { /* Preserve unresolved intent and the original error. */ }
          throw error
        }
      })
    },

    async softDelete(input) {
      const { abs, folder } = resolveMaterial(input.courseId, input.relPath)
      assertFileOrDirectory(abs, input.relPath)
      assertRealInside(folder, abs)
      await trashItem(abs)
      invalidate(requireId(input.courseId, 'courseId'))
      return { ok: true }
    },

    duplicate(input) {
      const { abs: sourceAbs, folder } = resolveMaterial(
        input.courseId,
        input.relPath
      )
      const sourceKind = assertFileOrDirectory(sourceAbs, input.relPath)
      const sourceName = posix.basename(input.relPath)
      const parentRelPath = posix.dirname(input.relPath)
      const parentAbs =
        parentRelPath === '.'
          ? folder
          : resolveCoursePath(folder, parentRelPath)
      const candidateName = unusedDuplicateName(parentAbs, sourceName)
      const candidateRelPath =
        parentRelPath === '.'
          ? candidateName
          : posix.join(parentRelPath, candidateName)
      const candidateAbs = resolveCoursePath(folder, candidateRelPath)
      assertRealInside(folder, sourceAbs)
      assertRealInside(folder, candidateAbs)
      if (sourceKind === 'dir') {
        cpSync(sourceAbs, candidateAbs, {
          recursive: true,
          errorOnExist: true,
          force: false
        })
      } else {
        copyFileSync(sourceAbs, candidateAbs)
      }
      addedState.recordAdded(input.courseId, candidateRelPath, sourceKind === 'dir')
      invalidate(requireId(input.courseId, 'courseId'))
      return { relPath: candidateRelPath }
    },

    createFolder(input) {
      const { folder } = requireCourseFolder(input.courseId)
      if (typeof input.dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      const parentAbs = resolveCoursePath(folder, input.dirRelPath, true)
      if (!existsSync(parentAbs) || !lstatSync(parentAbs).isDirectory()) {
        throw new NotFoundError('material directory', input.dirRelPath)
      }
      const name = requireBasename(input.name, 'name')
      const relPath =
        input.dirRelPath === '' ? name : posix.join(input.dirRelPath, name)
      const abs = resolveCoursePath(folder, relPath)
      if (existsSync(abs)) {
        throw new ConflictError(`material "${relPath}" already exists`)
      }
      assertRealInside(folder, abs)
      mkdirSync(abs)
      invalidate(requireId(input.courseId, 'courseId'))
      return { relPath }
    },

    writeFile(input) {
      const { folder } = requireCourseFolder(input.courseId)
      if (typeof input.dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      if (
        input.createDirIfMissing !== undefined &&
        typeof input.createDirIfMissing !== 'boolean'
      ) {
        throw new ValidationError('createDirIfMissing must be a boolean')
      }
      const parentAbs = resolveCoursePath(folder, input.dirRelPath, true)
      if (!existsSync(parentAbs) && input.createDirIfMissing === true) {
        mkdirSync(parentAbs, { recursive: true })
      }
      if (!existsSync(parentAbs) || !lstatSync(parentAbs).isDirectory()) {
        throw new NotFoundError('material directory', input.dirRelPath)
      }

      const requestedName = requireBasename(input.fileName, 'fileName')
      const requestedRelPath =
        input.dirRelPath === ''
          ? requestedName
          : posix.join(input.dirRelPath, requestedName)
      const requestedAbs = resolveCoursePath(folder, requestedRelPath)
      const fileName = existsSync(requestedAbs)
        ? unusedDuplicateName(parentAbs, requestedName)
        : requestedName
      const relPath =
        input.dirRelPath === '' ? fileName : posix.join(input.dirRelPath, fileName)
      const abs = resolveCoursePath(folder, relPath)
      const bytes = decodeWriteData(input.encoding, input.data)
      assertRealInside(folder, abs)
      writeFileSync(abs, bytes, { flag: 'wx' })
      addedState.recordAdded(input.courseId, relPath)
      invalidate(requireId(input.courseId, 'courseId'))
      return { relPath }
    },

    adoptFile(input) {
      const { folder } = requireCourseFolder(input.courseId)
      if (typeof input.dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      const sourcePath = requireNonEmptyString(input.sourcePath, 'sourcePath')
      if (!isAbsolute(sourcePath)) {
        throw new ValidationError('sourcePath must be absolute')
      }
      if (!existsSync(sourcePath) || !lstatSync(sourcePath).isFile()) {
        throw new NotFoundError('staged download', sourcePath)
      }
      const parentAbs = resolveCoursePath(folder, input.dirRelPath, true)
      if (!existsSync(parentAbs) || !lstatSync(parentAbs).isDirectory()) {
        throw new NotFoundError('material directory', input.dirRelPath)
      }

      const requestedName = requireBasename(input.fileName, 'fileName')
      const requestedAbs = resolveCoursePath(
        folder,
        input.dirRelPath === ''
          ? requestedName
          : posix.join(input.dirRelPath, requestedName)
      )
      const fileName = existsSync(requestedAbs)
        ? unusedDuplicateName(parentAbs, requestedName)
        : requestedName
      const relPath =
        input.dirRelPath === '' ? fileName : posix.join(input.dirRelPath, fileName)
      const abs = resolveCoursePath(folder, relPath)

      try {
        assertRealInside(folder, abs)
        renameSync(sourcePath, abs)
      } catch (error) {
        // Staging lives in the OS temp dir, which is very often a different
        // volume — rename fails with EXDEV there and a copy is the only move.
        if ((error as NodeJS.ErrnoException).code !== 'EXDEV') throw error
        assertRealInside(folder, abs)
        copyFileSync(sourcePath, abs)
        unlinkSync(sourcePath)
      }
      addedState.recordAdded(input.courseId, relPath)
      invalidate(requireId(input.courseId, 'courseId'))
      return { relPath }
    }
  }
}
