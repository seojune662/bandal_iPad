/**
 * ⌘D. `favoritesRepo` / `favorites:*` / `favoritesStore` were already
 * complete — only a way to reach them from the browser was missing.
 */

import { favoriteScopeKey, useFavoritesStore } from '../../stores/favoritesStore'
import { browserTabCourseId, useWorkspaceStore } from '../../stores/workspaceStore'
import { showToast } from '../../app/toast'
import { browserFavoriteLabel, browserFavoriteMatches } from './browserStartPageModel'
import type { Favorite } from '../../../../shared/types/favorite'
import { useBrowserGuests, type BrowserNavState } from './browserGuestsStore'

const EMPTY: readonly Favorite[] = []
const pendingFavorites = new Set<string>()

/** Course pins take precedence over imported global pins in the same profile. */
export function useBrowserFavorite(url: string, profileId = 'default', ownerCourseId?: string | null): Favorite | null {
  const courseId = useWorkspaceStore((state) => ownerCourseId === undefined ? state.activeCourseId : ownerCourseId)
  const favorites = useFavoritesStore(
    (state) => state.byCourse[favoriteScopeKey(courseId)] ?? EMPTY
  )
  const global = useFavoritesStore((state) => state.byCourse[favoriteScopeKey(null)] ?? EMPTY)
  if (url === '') return null
  return (
    favorites.find((favorite) => browserFavoriteMatches(favorite, url, profileId)) ??
    global.find((favorite) => browserFavoriteMatches(favorite, url, profileId)) ?? null
  )
}

export function toggleFavorite(tabId: string, nav: BrowserNavState): void {
  const url = nav.url
  if (url === '') return
  const guest = useBrowserGuests.getState().liveGuests.find((candidate) => candidate.tabId === tabId)
  const courseId = guest === undefined ? browserTabCourseId(tabId) : guest.courseId
  const profileId = guest?.profileId ?? 'default'
  const requestKey = JSON.stringify([courseId, profileId, url])
  if (pendingFavorites.has(requestKey)) return
  pendingFavorites.add(requestKey)
  const store = useFavoritesStore.getState()
  const existing = [...(store.byCourse[favoriteScopeKey(courseId)] ?? EMPTY), ...(courseId === null ? EMPTY : store.byCourse[favoriteScopeKey(null)] ?? EMPTY)]
    .find((favorite) => browserFavoriteMatches(favorite, url, profileId))

  if (existing !== undefined) {
    void store.remove(existing.id)
      .catch(() => { showToast('즐겨찾기에서 빼지 못했어요.', 'danger') })
      .finally(() => pendingFavorites.delete(requestKey))
    return
  }

  void store
    .add({
      courseId,
      label: browserFavoriteLabel(nav.title, url),
      descriptor: { kind: 'browser', payload: { tabId, initialUrl: url, profileId } }
    })
    .catch(() => {
      showToast('즐겨찾기에 추가하지 못했어요.', 'danger')
    })
    .finally(() => pendingFavorites.delete(requestKey))
}
