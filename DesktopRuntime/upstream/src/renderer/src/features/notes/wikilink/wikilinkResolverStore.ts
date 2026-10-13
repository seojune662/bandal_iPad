/**
 * Per-course cache of the flattened materials list, shared by every wikilink
 * chip and picker in the renderer. One `materials:tree` round trip per course
 * (re-fetched after `materials:changed`) instead of one per chip.
 *
 * The push subscription is lazy so importing this module in a headless test
 * never touches `window.bandal`.
 */

import {
  createWikilinkResolver,
  type WikilinkResolver
} from '../../../../../shared/wikilink'
import { invoke, onPush, type Unsubscribe } from '../../../lib/ipc'
import {
  flattenMaterialFiles,
  type LinkPickerFile
} from '../../links/LinkPickerDialog'

interface CourseEntry {
  files: readonly LinkPickerFile[] | null
  resolver: WikilinkResolver | null
  pending: Promise<readonly LinkPickerFile[]> | null
}

const EMPTY_ENTRY: CourseEntry = { files: null, resolver: null, pending: null }

const entries = new Map<string, CourseEntry>()
const listeners = new Set<() => void>()
let pushSubscription: Unsubscribe | null = null

function notify(): void {
  for (const listener of listeners) listener()
}

function ensurePushSubscription(): void {
  if (pushSubscription !== null) return
  try {
    pushSubscription = onPush('materials:changed', ({ courseId }) => {
      invalidateWikilinkResolver(courseId)
    })
  } catch (caught: unknown) {
    // No preload bridge (tests, storybook): resolve from explicit loads only.
    console.warn('[Bandal] materials:changed 구독에 실패했습니다.', caught)
    pushSubscription = () => undefined
  }
}

function entryFor(courseId: string): CourseEntry {
  return entries.get(courseId) ?? EMPTY_ENTRY
}

/** Re-renders chips (and picker lists) whenever a course's files change. */
export function subscribeWikilinkResolver(listener: () => void): Unsubscribe {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

/** Drops the cached list; the next resolve/load fetches a fresh tree. */
export function invalidateWikilinkResolver(courseId: string): void {
  if (!entries.has(courseId)) return
  entries.set(courseId, EMPTY_ENTRY)
  notify()
}

/** Loads (or returns the cached) flattened material list for a course. */
export function loadWikilinkFiles(
  courseId: string
): Promise<readonly LinkPickerFile[]> {
  ensurePushSubscription()
  const entry = entryFor(courseId)
  if (entry.files !== null) return Promise.resolve(entry.files)
  if (entry.pending !== null) return entry.pending

  // `Promise.resolve().then` turns a missing preload bridge (a synchronous
  // throw inside `invoke`) into a rejection the catch below can log.
  const pending = Promise.resolve()
    .then(() => invoke('materials:tree', { courseId }))
    .then((tree) => {
      const files = flattenMaterialFiles(tree)
      // A concurrent invalidate replaced the entry: keep its (empty) state.
      if (entryFor(courseId).pending !== pending) return files
      entries.set(courseId, {
        files,
        resolver: createWikilinkResolver(files),
        pending: null
      })
      notify()
      return files
    })
    .catch((caught: unknown) => {
      console.error('[Bandal] 위키링크 대상 목록을 불러오지 못했습니다.', caught)
      if (entryFor(courseId).pending === pending) {
        entries.set(courseId, EMPTY_ENTRY)
      }
      return [] as readonly LinkPickerFile[]
    })
  entries.set(courseId, { ...entry, pending })
  return pending
}

/** Cached list, or null while the first load is still in flight. */
export function wikilinkFilesSync(courseId: string): readonly LinkPickerFile[] | null {
  return entryFor(courseId).files
}

/**
 * Synchronous resolve from the cache. Returns null until the course's list
 * has loaded (the load is kicked off here); subscribers are notified once it
 * lands so chips can re-check.
 */
export function resolveWikilink(courseId: string, target: string): string | null {
  const entry = entryFor(courseId)
  if (entry.resolver === null) {
    void loadWikilinkFiles(courseId)
    return null
  }
  return entry.resolver.resolve(target)
}

/** Test seam: replaces a course's list without IPC. */
export function primeWikilinkFiles(
  courseId: string,
  files: readonly LinkPickerFile[]
): void {
  entries.set(courseId, {
    files,
    resolver: createWikilinkResolver(files),
    pending: null
  })
  notify()
}
