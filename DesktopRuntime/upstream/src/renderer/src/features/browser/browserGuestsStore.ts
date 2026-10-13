/**
 * Pages are created lazily when visited, then retained until explicitly closed.
 * Hidden pages keep forms, navigation history and active transfers intact;
 * Chromium's background throttling controls their idle work.
 */

import { create } from 'zustand'
import type { SavedLoginSummary } from '../../../../shared/types/credentials'
import type { BrowserAuthFallback } from '../../../../shared/types/browserAuth'
import type { BrowserOverlay } from './loadError'

export interface BrowserFindState {
  query: string
  /** 1-based position of the highlighted match; 0 = none yet. */
  activeMatch: number
  matchCount: number
  /** Bumped by ⌘F so the input re-focuses even when already open. */
  focusSeq: number
}
import { invoke } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'

export interface LiveGuest {
  tabId: string
  /** Initial native page URL; subsequent navigation lives in nav[tabId]. */
  src: string
  isPrivate: boolean
  profileId: string
  courseId: string | null
}

export interface BrowserNavState {
  httpStatus?: number
  /** A download navigation does not commit a document. */
  hasDocument?: boolean
  url: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
}

export interface BrowserVisit {
  url: string
  title: string
}

export const MAX_RECENT_VISITS = 6

export interface BrowserLoginState {
  origin: string | null
  hasLoginForm: boolean
  usernameFocused: boolean
  savedLogins: SavedLoginSummary[]
  savedLogin: SavedLoginSummary | null
  savePrompt: {
    origin: string
    username: string
    kind: 'save' | 'update'
  } | null
  pending: boolean
  message: 'saved' | 'filled' | 'needs-input' | 'failed' | null
}

interface BrowserGuestsState {
  /** Live pages in visit order (oldest first). */
  liveGuests: LiveGuest[]
  nav: Record<string, BrowserNavState>
  login: Record<string, BrowserLoginState>
  /** Recent pages live only for the lifetime of their browser tab. */
  recent: Record<string, BrowserVisit[]>
  /**
   * Host DOM shown in the tab's anchor INSTEAD of the guest. The guest keeps
   * living (and loading) underneath; only its rect is withheld, so dismissing
   * an overlay never costs a reload. null / absent = show the guest.
   */
  overlay: Record<string, BrowserOverlay | null | undefined>
  /**
   * Chromium zoom level per tab. The store is the source of truth: the level
   * lives on the render process, so a cross-origin navigation drops it and the
   * guest view re-applies from here.
   */
  zoom: Record<string, number | undefined>
  /**
   * Bumped to ask a panel's omnibox to take focus (⌘L). A counter rather than
   * a boolean so pressing ⌘L twice in a row still moves focus back.
   */
  addressFocusSeq: Record<string, number | undefined>
  /** ⌘F bar, per tab. Absent = closed. */
  find: Record<string, BrowserFindState | undefined>
  /** Favicon as a data URL, per tab. Absent = show the generic globe. */
  favicon: Record<string, string | undefined>
  /** Embedded auth failure URL; shown as an explicit external fallback. */
  authFallback: Record<string, BrowserAuthFallback | undefined>
  setFavicon: (tabId: string, dataUrl: string | null) => void
  setAuthFallback: (tabId: string, fallback: BrowserAuthFallback | null) => void
  ensureGuest: (tabId: string, initialUrl: string, isPrivate?: boolean, profileId?: string, courseId?: string | null) => void
  setGuestCourse: (tabId: string, courseId: string | null) => void
  requestAddressFocus: (tabId: string) => void
  openFind: (tabId: string) => void
  closeFind: (tabId: string) => void
  setFindQuery: (tabId: string, query: string) => void
  setFindResult: (
    tabId: string,
    result: { activeMatch: number; matchCount: number }
  ) => void
  setOverlay: (tabId: string, overlay: BrowserOverlay | null) => void
  setZoom: (tabId: string, level: number) => void
  touchGuest: (tabId: string) => void
  removeGuest: (tabId: string) => void
  updateNav: (tabId: string, patch: Partial<BrowserNavState>) => void
  updateLogin: (tabId: string, patch: Partial<BrowserLoginState>) => void
}

export function initialNavState(url: string): BrowserNavState {
  return {
    url,
    title: '',
    loading: false,
    canGoBack: false,
    canGoForward: false
  }
}

export function initialLoginState(): BrowserLoginState {
  return {
    origin: null,
    hasLoginForm: false,
    usernameFocused: false,
    savedLogins: [],
    savedLogin: null,
    savePrompt: null,
    pending: false,
    message: null
  }
}

function visitLabel(url: string, title: string): string {
  const trimmedTitle = title.trim()
  if (trimmedTitle.length > 0) return trimmedTitle
  try {
    return new URL(url).hostname
  } catch {
    return url
  }
}

function canRememberVisit(url: string): boolean {
  try {
    const protocol = new URL(url).protocol
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

function rememberVisit(
  visits: readonly BrowserVisit[],
  url: string,
  title: string
): BrowserVisit[] {
  if (!canRememberVisit(url)) return [...visits]
  return [
    { url, title: visitLabel(url, title) },
    ...visits.filter((visit) => visit.url !== url)
  ].slice(0, MAX_RECENT_VISITS)
}

function withoutKeys<T>(
  nav: Record<string, T>,
  keys: readonly string[]
): Record<string, T> {
  if (keys.length === 0) return nav
  const next = { ...nav }
  for (const key of keys) delete next[key]
  return next
}

/**
 * Remembers a page once it has both a committed URL and a title.
 *
 * Fired from `updateNav` rather than from a navigation event so a page is
 * recorded with the name a student would recognise: `did-navigate` lands
 * before `page-title-updated`, and a history row titled with its own URL is
 * useless in the omnibox.
 */
function recordVisitFrom(
  tabId: string,
  current: BrowserNavState,
  patch: Partial<BrowserNavState>
): void {
  if (useBrowserGuests.getState().liveGuests.some(
    (guest) => guest.tabId === tabId && guest.isPrivate
  )) return
  const url = patch.url ?? current.url
  const title = patch.title ?? current.title
  if (url === '' || title === '') return
  // Same (url, title) as we already reported for this tab: nothing new.
  if (patch.url === undefined && patch.title === undefined) return
  void invoke('browser:recordVisit', {
    profileId: useBrowserGuests.getState().liveGuests.find(g => g.tabId === tabId)?.profileId ?? 'default',
    url,
    title,
    courseId: useBrowserGuests.getState().liveGuests.find(g => g.tabId === tabId)?.courseId ?? null
  }).catch(() => {
    // History is a convenience; never let it surface as an error.
  })
}

export const useBrowserGuests = create<BrowserGuestsState>()((set, get) => ({
  liveGuests: [],
  nav: {},
  login: {},
  recent: {},
  overlay: {},
  zoom: {},
  addressFocusSeq: {},
  find: {},
  favicon: {},
  authFallback: {},

  setAuthFallback: (tabId, fallback) => {
    const current = get().authFallback
    set({
      authFallback: fallback === null
        ? withoutKeys(current, [tabId])
        : { ...current, [tabId]: fallback }
    })
  },

  ensureGuest: (tabId, initialUrl, isPrivate = false, profileId = 'default', courseId = useCoursesStore.getState().selectedCourseId) => {
    const { liveGuests, nav, login, recent, authFallback } = get()
    const currentGuest = liveGuests.find((guest) => guest.tabId === tabId)
    if (currentGuest !== undefined && currentGuest.isPrivate === isPrivate && currentGuest.profileId === profileId) {
      get().setGuestCourse(tabId, courseId)
      get().touchGuest(tabId)
      return
    }
    const changedSession = currentGuest !== undefined &&
      (currentGuest.profileId !== profileId || currentGuest.isPrivate !== isPrivate)
    const src = initialUrl
    const grown = [
      ...liveGuests.filter((guest) => guest.tabId !== tabId),
      { tabId, src, isPrivate, profileId, courseId }
    ]
    set({
      liveGuests: grown,
      favicon: withoutKeys(get().favicon, [tabId]),
      overlay: withoutKeys(get().overlay, [tabId]),
      ...(changedSession ? {
        find: withoutKeys(get().find, [tabId]),
        zoom: withoutKeys(get().zoom, [tabId])
      } : {}),
      nav: {
        ...nav,
        [tabId]: initialNavState(src)
      },
      login: {
        ...login,
        [tabId]: initialLoginState()
      },
      recent: {
        ...recent,
        [tabId]: isPrivate || changedSession ? [] : (recent[tabId] ?? [])
      },
      authFallback: withoutKeys(authFallback, [tabId])
    })
  },

  setGuestCourse: (tabId, courseId) => {
    const guest = get().liveGuests.find(entry => entry.tabId === tabId)
    if (!guest || guest.courseId === courseId) return
    set({ liveGuests: get().liveGuests.map(entry => entry.tabId === tabId ? { ...entry, courseId } : entry) })
  },

  setFavicon: (tabId, dataUrl) => {
    const { favicon } = get()
    if ((favicon[tabId] ?? null) === dataUrl) return
    set({
      favicon:
        dataUrl === null
          ? withoutKeys(favicon, [tabId])
          : { ...favicon, [tabId]: dataUrl }
    })
  },

  openFind: (tabId) => {
    const { find } = get()
    // Re-opening while open must re-focus the field, not reset the query.
    set({
      find: {
        ...find,
        [tabId]: {
          query: find[tabId]?.query ?? '',
          activeMatch: find[tabId]?.activeMatch ?? 0,
          matchCount: find[tabId]?.matchCount ?? 0,
          focusSeq: (find[tabId]?.focusSeq ?? 0) + 1
        }
      }
    })
  },

  closeFind: (tabId) => {
    const { find } = get()
    if (find[tabId] === undefined) return
    set({ find: withoutKeys(find, [tabId]) })
  },

  setFindQuery: (tabId, query) => {
    const { find } = get()
    const current = find[tabId]
    if (current === undefined) return
    set({
      find: {
        ...find,
        // A new query invalidates the old counts; showing them would lie.
        [tabId]: { ...current, query, activeMatch: 0, matchCount: 0 }
      }
    })
  },

  setFindResult: (tabId, result) => {
    const { find } = get()
    const current = find[tabId]
    if (current === undefined) return
    set({ find: { ...find, [tabId]: { ...current, ...result } } })
  },

  requestAddressFocus: (tabId) => {
    const { addressFocusSeq } = get()
    set({
      addressFocusSeq: {
        ...addressFocusSeq,
        [tabId]: (addressFocusSeq[tabId] ?? 0) + 1
      }
    })
  },

  setZoom: (tabId, level) => {
    const { zoom } = get()
    if (zoom[tabId] === level) return
    set({ zoom: { ...zoom, [tabId]: level } })
  },

  setOverlay: (tabId, overlay) => {
    const current = get().overlay
    if ((current[tabId] ?? null) === overlay) return
    set({ overlay: { ...current, [tabId]: overlay } })
  },

  touchGuest: (tabId) => {
    const { liveGuests } = get()
    if (!liveGuests.some((guest) => guest.tabId === tabId)) return
    if (liveGuests.at(-1)?.tabId === tabId) return
    set({ liveGuests: [...liveGuests.filter(guest => guest.tabId !== tabId), liveGuests.find(guest => guest.tabId === tabId)!] })
  },

  removeGuest: (tabId) => {
    const { liveGuests, nav, login, recent, overlay, zoom } = get()
    set({
      liveGuests: liveGuests.filter((guest) => guest.tabId !== tabId),
      nav: withoutKeys(nav, [tabId]),
      login: withoutKeys(login, [tabId]),
      recent: withoutKeys(recent, [tabId]),
      overlay: withoutKeys(overlay, [tabId]),
      zoom: withoutKeys(zoom, [tabId]),
      addressFocusSeq: withoutKeys(get().addressFocusSeq, [tabId]),
      find: withoutKeys(get().find, [tabId]),
      favicon: withoutKeys(get().favicon, [tabId]),
      authFallback: withoutKeys(get().authFallback, [tabId])
    })
  },

  updateNav: (tabId, patch) => {
    const { nav, recent } = get()
    const current = nav[tabId]
    if (current === undefined) return
    const isPrivate = get().liveGuests.some(
      (guest) => guest.tabId === tabId && guest.isPrivate
    )
    recordVisitFrom(tabId, current, patch)
    const next = { ...current, ...patch }

    let nextRecent = isPrivate ? [] : (recent[tabId] ?? [])
    if (!isPrivate && typeof patch.url === 'string' && patch.url.length > 0) {
      // A title from the prior page is stale until page-title-updated arrives.
      nextRecent = rememberVisit(nextRecent, patch.url, patch.title ?? '')
    } else if (!isPrivate && typeof patch.title === 'string' && current.url.length > 0) {
      nextRecent = rememberVisit(nextRecent, current.url, patch.title)
    }

    set({
      nav: { ...nav, [tabId]: next },
      recent: { ...recent, [tabId]: nextRecent }
    })
  },

  updateLogin: (tabId, patch) => {
    const { login } = get()
    const current = login[tabId]
    if (current === undefined) return
    set({ login: { ...login, [tabId]: { ...current, ...patch } } })
  },

}))

/** Test-only: reset retained page state. */
export function resetBrowserGuestsForTests(): void {
  useBrowserGuests.setState({
    liveGuests: [],
    nav: {},
    login: {},
    recent: {},
    overlay: {},
    zoom: {},
    addressFocusSeq: {},
    find: {},
    favicon: {},
    authFallback: {}
  })
}
