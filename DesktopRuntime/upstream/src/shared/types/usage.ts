/**
 * [v0.39] AI usage ledger. One row per finished turn (agent_usage, migration
 * 26), aggregated here for settings > 사용 통계. Token figures come straight
 * from the CLIs' turn-complete usage; there is no cost estimate on purpose —
 * subscription users have none.
 */
import type { AgentProvider } from './agent-events'

export const USAGE_WINDOWS = [7, 30, 0] as const
/** Days to look back; 0 = everything. */
export type UsageWindowDays = (typeof USAGE_WINDOWS)[number]

export function isUsageWindowDays(value: unknown): value is UsageWindowDays {
  return USAGE_WINDOWS.some((days) => days === value)
}

export interface UsageTotals {
  turns: number
  sessions: number
  inputTokens: number
  outputTokens: number
  cacheReadTokens: number
  /** Sum of turn durations the CLIs reported, ms. 0 when none reported. */
  agentMs: number
}

export interface UsageByProvider extends UsageTotals {
  provider: AgentProvider
  /** Most-used model in the window, null when the CLI never named one. */
  model: string | null
  lastUsedAt: string | null
}

export interface UsageSummary {
  windowDays: UsageWindowDays
  /** ISO of the oldest row in the ledger, null when the ledger is empty. */
  since: string | null
  totals: UsageTotals
  byProvider: UsageByProvider[]
}
