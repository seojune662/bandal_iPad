/**
 * Omnibox candidates for what is currently typed.
 *
 * History lives in main (SQLite), so it arrives asynchronously; everything
 * else — open tabs, favorites, school shortcuts — is already in the renderer
 * and shows instantly. The list therefore fills in twice, which is why the
 * local sources are not gated on the fetch.
 */

import { useEffect, useState } from 'react'
import { invoke } from '../../lib/ipc'
import { settingsSnapshot } from '../../stores/settingsSnapshot'
import {
  favoriteScopeKey,
  useFavoritesStore
} from '../../stores/favoritesStore'
import type { Favorite } from '../../../../shared/types/favorite'
import { useBrowserGuests } from './browserGuestsStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useUniversityStore } from '../../stores/universityStore'
import { browserFavoriteShortcuts } from './browserStartPageModel'
import {
  DEFAULT_SEARCH_ENGINE,
  suggestionsFor,
  type AddressSuggestion,
  type SearchEngineId
} from './urlInput'

/** Stable identity so the zustand selector does not re-render every tick. */
const EMPTY_FAVORITES: readonly Favorite[] = []

/** Typing is faster than SQLite; this keeps the query off every keystroke. */
const HISTORY_DEBOUNCE_MS = 90

export function searchEngine(): SearchEngineId {
  return settingsSnapshot().browserSearchEngine ?? DEFAULT_SEARCH_ENGINE
}

interface HistoryHit {
  url: string
  title: string
  host: string
}

export function useAddressSuggestions(
  draft: string | null,
  includeHistory = true,
  profileId = 'default',
  ownerCourseId?: string | null
): AddressSuggestion[] {
  const [history, setHistory] = useState<{ query: string; profileId: string; entries: HistoryHit[] } | null>(null)
  const courseId = useWorkspaceStore((state) => ownerCourseId === undefined ? state.activeCourseId : ownerCourseId)
  const favorites = useFavoritesStore(
    (state) => state.byCourse[favoriteScopeKey(courseId)] ?? EMPTY_FAVORITES
  )
  const globalFavorites = useFavoritesStore(
    (state) => state.byCourse[favoriteScopeKey(null)] ?? EMPTY_FAVORITES
  )
  const openTabs = useWorkspaceStore((state) => state.openTabs)
  // Closed address bars need not re-render when another guest navigates.
  const nav = useBrowserGuests((state) => draft === null ? undefined : state.nav)
  const services = useUniversityStore((state) => state.services)

  useEffect(() => {
    if (!includeHistory || draft === null) {
      setHistory(null)
      return
    }
    let cancelled = false
    const timer = setTimeout(() => {
      void invoke('browser:searchHistory', { query: draft, limit: 24, profileId })
        .then((result) => {
          if (!cancelled) setHistory({ query: draft, profileId, entries: result.entries })
        })
        .catch(() => {
          if (!cancelled) setHistory(null)
        })
    }, HISTORY_DEBOUNCE_MS)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [draft, includeHistory, profileId])

  if (draft === null) return []

  return suggestionsFor(
    draft,
    {
      history: includeHistory && history?.profileId === profileId && history?.query === draft ? history.entries : [],
      favorites: browserFavoriteShortcuts([...favorites, ...globalFavorites], profileId),
      services: services.map((service) => ({
        label: service.label,
        url: service.url
      })),
      openTabs: Object.entries(openTabs).flatMap(([tabId, descriptor]) =>
        descriptor.kind === 'browser' && (descriptor.payload.profileId ?? 'default') === profileId && !descriptor.payload.isPrivate
          ? [
              {
                title: nav?.[tabId]?.title || descriptor.payload.initialUrl,
                url: nav?.[tabId]?.url || descriptor.payload.initialUrl
              }
            ]
          : []
      )
    },
    searchEngine()
  )
}
