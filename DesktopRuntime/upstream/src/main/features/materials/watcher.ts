/**
 * [M5] Per-course folder watcher backing the live materials tree.
 *
 * `materials:watch(courseId)` starts a chokidar watcher on the course folder;
 * every disk change is debounced (300ms) and surfaced through the `onChange`
 * callback, which registerHandlers turns into a `materials:changed` push.
 * Folder rename/delete out-of-band is non-fatal: chokidar keeps running (it
 * re-attaches if the path reappears) and the final debounced change lets the
 * renderer refresh into an empty tree. The `onChange` wiring in
 * registerHandlers also calls `materialsRepo.invalidateTree` — tree/search
 * now serve a per-course cache, and this watcher is what keeps that cache
 * honest against out-of-band disk changes.
 */

import { watch, type FSWatcher } from 'chokidar'
import { basename, relative, sep } from 'node:path'

export const MATERIALS_WATCH_DEBOUNCE_MS = 300

export interface MaterialsWatcher {
  /** Idempotent: re-watching an already-watched course is a no-op. */
  watch(courseId: string): void
  unwatch(courseId: string): void
  /** Close the course's native handles until the last returned token resumes. */
  pause(courseId: string): Promise<() => Promise<void>>
  dispose(): void
}

export interface MaterialsWatcherDeps {
  /** Absolute course folder for a live course id (throws otherwise). */
  getCourseFolder: (courseId: string) => string
  /** Fired (debounced) whenever the course folder changed on disk. */
  onChange: (courseId: string, changes: MaterialChanges) => void
  onReady?: (courseId: string) => void
  /** Suppress content-only churn for an actively written recording. Structural events still refresh. */
  ignoreContentChange?: (courseId: string, relPath: string) => boolean
  debounceMs?: number
}

export interface MaterialChanges { structural: boolean; paths: string[] }

interface WatchEntry {
  watcher: FSWatcher
  timer: NodeJS.Timeout | null
  structural: boolean
  paths: Set<string>
}

function isHidden(path: string): boolean {
  return basename(path).startsWith('.')
}

export function createMaterialsWatcher(
  deps: MaterialsWatcherDeps
): MaterialsWatcher {
  const debounceMs = deps.debounceMs ?? MATERIALS_WATCH_DEBOUNCE_MS
  const entries = new Map<string, WatchEntry>()
  const requested = new Set<string>()
  const closing = new Map<string, Promise<void>>()
  const paused = new Map<string, { count: number; ready: Promise<void> }>()

  function scheduleChange(courseId: string, structural = true, relPath?: string): void {
    const entry = entries.get(courseId)
    if (entry === undefined) return
    entry.structural ||= structural
    if (relPath && entry.paths.size < 100) entry.paths.add(relPath)
    else if (relPath) entry.structural = true
    if (entry.timer !== null) clearTimeout(entry.timer)
    entry.timer = setTimeout(() => {
      entry.timer = null
      const changes = { structural: entry.structural, paths: [...entry.paths] }
      entry.structural = false
      entry.paths.clear()
      deps.onChange(courseId, changes)
    }, debounceMs)
  }

  function stop(courseId: string): Promise<void> {
    const entry = entries.get(courseId)
    if (entry === undefined) return closing.get(courseId) ?? Promise.resolve()
    entries.delete(courseId)
    if (entry.timer !== null) clearTimeout(entry.timer)
    const task = entry.watcher.close().finally(() => {
      if (closing.get(courseId) === task) closing.delete(courseId)
    })
    closing.set(courseId, task)
    return task
  }

  async function start(courseId: string): Promise<void> {
    await closing.get(courseId)
    if (!requested.has(courseId) || paused.has(courseId) || entries.has(courseId)) return
    const folder = deps.getCourseFolder(courseId)
    const watcher = watch(folder, {
      ignoreInitial: true,
      ignored: isHidden,
      // The folder itself may be renamed/removed while watched; polling for
      // existence is unnecessary — missing paths simply stop emitting.
      ignorePermissionErrors: true
    })
    const entry = { watcher, timer: null, structural: false, paths: new Set<string>() }
    entries.set(courseId, entry)
    watcher.on('ready', () => { if (entries.get(courseId) === entry) deps.onReady?.(courseId) })
    watcher.on('all', (event, path) => {
      if (entries.get(courseId) !== entry) return
      const relPath = relative(folder, path).split(sep).join('/')
      if (
        event === 'change' &&
        deps.ignoreContentChange?.(courseId, relPath)
      ) return
      scheduleChange(courseId, event !== 'change', relPath)
    })
    watcher.on('error', (error) => {
      // e.g. the folder disappeared mid-scan. Keep the watcher; surface a
      // change so the renderer refreshes to the (possibly empty) tree.
      if (entries.get(courseId) !== entry) return
      console.warn(`[materials] watcher error for ${courseId}:`, error)
      scheduleChange(courseId)
    })
  }

  const warn = (courseId: string, error: unknown): void => {
    console.warn(`[materials] watcher transition failed for ${courseId}:`, error)
  }

  return {
    watch(courseId) {
      requested.add(courseId)
      void start(courseId).catch(error => warn(courseId, error))
    },

    unwatch(courseId) {
      requested.delete(courseId)
      void stop(courseId).catch(error => warn(courseId, error))
    },

    async pause(courseId) {
      let state = paused.get(courseId)
      if (!state) {
        state = { count: 0, ready: stop(courseId) }
        paused.set(courseId, state)
      }
      state.count += 1
      try { await state.ready } catch (error) {
        if (--state.count === 0) paused.delete(courseId)
        throw error
      }
      let resumed = false
      return async () => {
        if (resumed) return
        resumed = true
        if (--state.count > 0) return
        paused.delete(courseId)
        await start(courseId)
      }
    },

    dispose() {
      requested.clear()
      for (const courseId of [...entries.keys()]) {
        void stop(courseId).catch(error => warn(courseId, error))
      }
    }
  }
}
