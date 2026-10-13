/**
 * Shared agent-preflight probe: "is any supported AI provider connected right
 * now?" This is only used inside onboarding; the app shell never nags users.
 *
 * One zustand store backs every consumer (boot probe, shell preflight
 * banners, onboarding step ③), so a 재확인 from any surface refreshes all of
 * them. State transitions live in the pure `reducePreflight` reducer;
 * issue derivation in `preflightIssues` — both unit-testable.
 */

import { create } from 'zustand'
import type { AgentAvailability } from '../../../../shared/types/agent-events'
import { AGENT_PROVIDERS } from '../../../../shared/types/agent-events'
import { invoke, onPush } from '../../lib/ipc'

export type PreflightIssueKind =
  | 'not-installed'
  | 'version-too-old'
  | 'not-logged-in'

export type PreflightStatus = 'idle' | 'checking' | 'ready' | 'error'

export interface PreflightState {
  status: PreflightStatus
  /** Last successful probe result; kept while re-checking. */
  availability: AgentAvailability | null
  /** Issue banners the user closed this session. */
  dismissed: readonly PreflightIssueKind[]
}

export const INITIAL_PREFLIGHT_STATE: PreflightState = {
  status: 'idle',
  availability: null,
  dismissed: []
}

export type PreflightAction =
  | { type: 'probe-start' }
  | { type: 'probe-success'; availability: AgentAvailability }
  | { type: 'probe-failure' }
  | { type: 'dismiss'; issue: PreflightIssueKind }

/** Issues implied by an availability snapshot (at most one, most blocking). */
export function issuesOf(
  availability: AgentAvailability | null
): PreflightIssueKind[] {
  if (availability === null) return []
  if (availability.code === 'version-too-old') return ['version-too-old']
  if (!availability.installed) return ['not-installed']
  if (!availability.loggedIn) return ['not-logged-in']
  return []
}

/** Pure state transition for probe lifecycle + per-issue dismissal. */
export function reducePreflight(
  state: PreflightState,
  action: PreflightAction
): PreflightState {
  switch (action.type) {
    case 'probe-start':
      return { ...state, status: 'checking' }
    case 'probe-success': {
      // A dismissal only survives while its issue persists: once the user
      // fixes it, a later regression must surface a fresh banner.
      const current = issuesOf(action.availability)
      return {
        status: 'ready',
        availability: action.availability,
        dismissed: state.dismissed.filter((issue) => current.includes(issue))
      }
    }
    case 'probe-failure':
      return { ...state, status: 'error' }
    case 'dismiss':
      return state.dismissed.includes(action.issue)
        ? state
        : { ...state, dismissed: [...state.dismissed, action.issue] }
  }
}

/** Issues that should currently be visible (probe result minus dismissals). */
export function visibleIssues(state: PreflightState): PreflightIssueKind[] {
  if (state.status !== 'ready') return []
  return issuesOf(state.availability).filter(
    (issue) => !state.dismissed.includes(issue)
  )
}

// -- store --------------------------------------------------------------------

interface PreflightStore extends PreflightState {
  /** Runs (or re-runs) the live probe. Concurrent calls collapse into one. */
  probe: () => Promise<void>
  dismissIssue: (issue: PreflightIssueKind) => void
}

let inflight: Promise<void> | null = null
let autoRefreshCleanup: (() => void) | null = null

function ensureAutoRefresh(): void {
  if (
    autoRefreshCleanup !== null ||
    typeof window === 'undefined' ||
    typeof document === 'undefined'
  ) {
    return
  }

  const probe = (): void => {
    void useAgentPreflight.getState().probe()
  }
  const probeWhenVisible = (): void => {
    if (document.visibilityState === 'visible') probe()
  }
  window.addEventListener('focus', probe)
  document.addEventListener('visibilitychange', probeWhenVisible)
  const unsubscribe = onPush('agent:install-progress', (progress) => {
    if (progress.done) probe()
  })
  autoRefreshCleanup = () => {
    window.removeEventListener('focus', probe)
    document.removeEventListener('visibilitychange', probeWhenVisible)
    unsubscribe()
  }
}

export const useAgentPreflight = create<PreflightStore>()((set, get) => {
  const dispatch = (action: PreflightAction): void => {
    const { status, availability, dismissed } = get()
    set(reducePreflight({ status, availability, dismissed }, action))
  }

  return {
    ...INITIAL_PREFLIGHT_STATE,

    probe: async () => {
      ensureAutoRefresh()
      if (inflight !== null) return inflight
      dispatch({ type: 'probe-start' })
      inflight = Promise.all(
        AGENT_PROVIDERS.map((provider) =>
          invoke('agent:availability', { provider })
        )
      )
        .then((availability) => {
          const representative =
            availability.find((state) => state.installed && state.loggedIn) ??
            availability.find((state) => state.installed) ??
            availability[0]
          if (representative === undefined) throw new Error('No AI providers')
          dispatch({ type: 'probe-success', availability: representative })
        })
        .catch(() => {
          dispatch({ type: 'probe-failure' })
        })
        .finally(() => {
          inflight = null
        })
      return inflight
    },

    dismissIssue: (issue) => {
      dispatch({ type: 'dismiss', issue })
    }
  }
})

/** Test-only: reset module-level probe state. */
export function resetPreflightForTests(): void {
  inflight = null
  useAgentPreflight.setState(INITIAL_PREFLIGHT_STATE)
}
