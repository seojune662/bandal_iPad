/**
 * The glass box.
 *
 * A strip on the tab the agent is driving, saying what it is doing right now,
 * with a 중지 button. This is the mitigation for every reliability failure
 * mode in the agent feature: a model that misreads a Korean portal will do
 * something visibly wrong, and the only thing that turns "the agent did
 * something weird" into "I stopped it" is a person watching a real page.
 *
 * It is also why the agent works in a VISIBLE tab. A hidden guest would be
 * background-throttled by Chromium anyway, so there is nothing to gain and a
 * great deal of trust to lose.
 */

import { create } from 'zustand'
import type { BrowserAgentRunState } from '../../../../shared/ipc/events'
import { invoke, onPush } from '../../lib/ipc'

interface AgentRunStore {
  /** Live run per tabId. Absent = nothing running on that tab. */
  byTab: Record<string, BrowserAgentRunState | undefined>
  init: () => void
}

let initialized = false

export const useAgentRuns = create<AgentRunStore>()((set) => ({
  byTab: {},
  init: () => {
    if (initialized) return
    initialized = true
    onPush('browserAgent:run-state', (state) => {
      set((current) => {
        const next = { ...current.byTab }
        // A finished or stopped run leaves nothing behind — a stale strip
        // saying "reading…" over an idle page is worse than no strip.
        if (state.status === 'done') {
          if (next[state.tabId]?.runId === state.runId) delete next[state.tabId]
        }
        else next[state.tabId] = state
        return { byTab: next }
      })
    })
  }
}))

export function AgentRunBanner({ tabId }: { tabId: string }): JSX.Element | null {
  const run = useAgentRuns((state) => state.byTab[tabId])
  if (run === undefined) return null

  const waiting = run.status === 'waiting'
  const stopped = run.status === 'stopped'

  return (
    <div
      className="browser-agent-run"
      role="status"
      aria-live="polite"
      data-waiting={waiting ? 'true' : undefined}
      data-stopped={stopped ? 'true' : undefined}
    >
      <span className="browser-agent-run__dot" aria-hidden="true" />
      <span className="browser-agent-run__text">
        {stopped ? '중지했어요' : run.action}
      </span>
      {waiting && (
        <button
          type="button"
          className="browser-agent-run__action"
          onClick={() => {
            void invoke('browserAgent:resumeRun', { runId: run.runId })
          }}
        >
          계속
        </button>
      )}
      {!stopped && (
        <button
          type="button"
          className="browser-agent-run__action"
          onClick={() => {
            void invoke('browserAgent:stopRun', { runId: run.runId })
          }}
        >
          중지
        </button>
      )}
    </div>
  )
}
