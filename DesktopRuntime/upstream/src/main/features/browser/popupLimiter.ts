/**
 * How many real popup windows a page may have open at once.
 *
 * Allowing `about:blank` and `blob:` popups is what makes Korean report
 * viewers work, but it also removes the only thing that was stopping a page
 * from opening windows in a loop. Chromium's own popup blocker does not run
 * for `<webview>` guests — `allowpopups` plus our handler is the entire gate,
 * and `HandlerDetails` carries no user-gesture flag — so the cap has to live
 * here.
 *
 * Two limits, because they catch different things: a burst window catches the
 * loop, and a concurrent cap catches the slow accumulation. Both are per guest
 * and there is an app-wide ceiling on top, so one tab cannot fill the screen.
 */

/** A document that needs more than this at once is not a document. */
export const POPUP_MAX_PER_GUEST = 3
/** Across every guest — a split view of five tabs still cannot bury the app. */
export const POPUP_MAX_TOTAL = 6
export const POPUP_BURST_WINDOW_MS = 1000
export const POPUP_MAX_PER_BURST = 2

export type PopupAdmission =
  | { ok: true }
  | { ok: false; reason: 'burst' | 'limit' }

export interface PopupLimiter {
  admit: (guestId: number) => PopupAdmission
  release: (guestId: number) => void
  /** Everything this guest had open, when the guest itself goes away. */
  forget: (guestId: number) => void
}

interface GuestState {
  open: number
  /** Timestamps of recent admissions, oldest first. */
  recent: number[]
}

export function createPopupLimiter(now: () => number): PopupLimiter {
  const byGuest = new Map<number, GuestState>()

  function stateFor(guestId: number): GuestState {
    const existing = byGuest.get(guestId)
    if (existing !== undefined) return existing
    const created: GuestState = { open: 0, recent: [] }
    byGuest.set(guestId, created)
    return created
  }

  function totalOpen(): number {
    let total = 0
    for (const state of byGuest.values()) total += state.open
    return total
  }

  return {
    admit(guestId) {
      const at = now()
      const state = stateFor(guestId)
      const recent = state.recent.filter(
        (stamp) => at - stamp < POPUP_BURST_WINDOW_MS
      )
      if (recent.length >= POPUP_MAX_PER_BURST) {
        byGuest.set(guestId, { ...state, recent })
        return { ok: false, reason: 'burst' }
      }
      if (state.open >= POPUP_MAX_PER_GUEST || totalOpen() >= POPUP_MAX_TOTAL) {
        byGuest.set(guestId, { ...state, recent })
        return { ok: false, reason: 'limit' }
      }
      byGuest.set(guestId, { open: state.open + 1, recent: [...recent, at] })
      return { ok: true }
    },

    release(guestId) {
      const state = byGuest.get(guestId)
      if (state === undefined) return
      byGuest.set(guestId, { ...state, open: Math.max(0, state.open - 1) })
    },

    forget(guestId) {
      byGuest.delete(guestId)
    }
  }
}
