/**
 * [R3] Module-level cached settings for stores that need a SYNCHRONOUS read
 * (workspaceStore.openTab must decide tab placement without awaiting IPC).
 *
 * Not a zustand store on purpose: nothing renders from this — UI surfaces
 * that display settings (SettingsApp, uiStore theme, localeStore …) keep
 * their own subscriptions. This is a read-only warm cache:
 *
 *  - `ensureSettingsLoaded()` fetches once and subscribes to the
 *    `settings:changed` broadcast; every later change (from either window or
 *    from main) lands here automatically.
 *  - `settingsSnapshot()` returns the latest value, or DEFAULT_SETTINGS
 *    before the first load resolves.
 *
 * coursesStore.loadCourses awaits ensureSettingsLoaded() on boot, so the
 * cache is warm before the first course (and therefore the first tab) opens.
 */

import { DEFAULT_SETTINGS } from '../../../shared/types/settings'
import type { Settings } from '../../../shared/types/settings'
import { invoke, onPush } from '../lib/ipc'

let snapshot: Settings | null = null
let loading: Promise<Settings> | null = null
let subscribed = false

/** Fetches settings once and keeps the cache fresh via settings:changed. */
export function ensureSettingsLoaded(): Promise<Settings> {
  if (snapshot !== null) return Promise.resolve(snapshot)
  if (loading === null) {
    if (!subscribed) {
      subscribed = true
      onPush('settings:changed', ({ settings }) => {
        snapshot = settings
      })
    }
    loading = invoke('settings:get', {})
      .then((settings) => {
        // 브로드캐스트가 먼저 도착했다면 그쪽이 더 최신이다.
        snapshot ??= settings
        return snapshot
      })
      .catch((error: unknown) => {
        // 다음 호출이 다시 시도할 수 있게 실패는 캐시하지 않는다.
        loading = null
        if (snapshot !== null) return snapshot
        throw error
      })
  }
  return loading
}

/** Latest known settings; defaults until the first load resolves. */
export function settingsSnapshot(): Settings {
  return snapshot ?? DEFAULT_SETTINGS
}

/** Test-only: reset the module-level cache. */
export function resetSettingsSnapshotForTests(): void {
  snapshot = null
  loading = null
  subscribed = false
}
