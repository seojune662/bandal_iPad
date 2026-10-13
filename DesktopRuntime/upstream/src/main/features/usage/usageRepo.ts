import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import {
  AGENT_PROVIDERS,
  isAgentProvider,
  type AgentProvider,
  type Usage
} from '../../../shared/types/agent-events'
import type {
  UsageByProvider,
  UsageSummary,
  UsageTotals,
  UsageWindowDays
} from '../../../shared/types/usage'

interface UsageRecordInput {
  courseId: string
  sessionId: string
  provider: AgentProvider
  model: string | null
  usage?: Usage
  durationMs?: number
  turnAt?: string
  id?: string
}

interface UsageRow {
  session_id: string
  provider: string
  model: string | null
  turn_at: string
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  duration_ms: number | null
}

function whole(value: number | undefined): number {
  return value === undefined || !Number.isFinite(value)
    ? 0
    : Math.max(0, Math.trunc(value))
}

function emptyTotals(): UsageTotals {
  return {
    turns: 0,
    sessions: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    agentMs: 0
  }
}

function favoriteModel(rows: UsageRow[]): string | null {
  const counts = new Map<string, { count: number; last: string }>()
  for (const row of rows) {
    if (row.model === null) continue
    const current = counts.get(row.model)
    counts.set(row.model, {
      count: (current?.count ?? 0) + 1,
      last: current === undefined || row.turn_at > current.last
        ? row.turn_at
        : current.last
    })
  }
  return [...counts.entries()]
    .sort((a, b) =>
      b[1].count - a[1].count ||
      b[1].last.localeCompare(a[1].last) ||
      a[0].localeCompare(b[0])
    )[0]?.[0] ?? null
}

function totalsFor(rows: UsageRow[]): UsageTotals {
  const totals = emptyTotals()
  const sessions = new Set<string>()
  for (const row of rows) {
    totals.turns += 1
    totals.inputTokens += row.input_tokens
    totals.outputTokens += row.output_tokens
    totals.cacheReadTokens += row.cache_read_tokens
    totals.agentMs += row.duration_ms ?? 0
    sessions.add(row.session_id)
  }
  totals.sessions = sessions.size
  return totals
}

function providerSummary(
  provider: AgentProvider,
  rows: UsageRow[]
): UsageByProvider {
  return {
    provider,
    model: favoriteModel(rows),
    lastUsedAt: rows.reduce<string | null>(
      (latest, row) => latest === null || row.turn_at > latest ? row.turn_at : latest,
      null
    ),
    ...totalsFor(rows)
  }
}

export function createUsageRepo(db: Database): {
  record(row: UsageRecordInput): void
  summary(windowDays: UsageWindowDays): UsageSummary
} {
  const insert = db.prepare(
    `INSERT INTO agent_usage
       (id, session_id, course_id, provider, model, turn_at, input_tokens,
        output_tokens, cache_read_tokens, cache_write_tokens, duration_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )

  function record(row: UsageRecordInput): void {
    insert.run(
      row.id ?? randomUUID(),
      row.sessionId,
      row.courseId,
      row.provider,
      row.model,
      row.turnAt ?? new Date().toISOString(),
      whole(row.usage?.inputTokens),
      whole(row.usage?.outputTokens),
      whole(row.usage?.cacheReadTokens),
      whole(row.usage?.cacheCreationTokens),
      row.durationMs === undefined ? null : whole(row.durationMs)
    )
  }

  function summary(windowDays: UsageWindowDays): UsageSummary {
    const sinceBoundary = windowDays === 0
      ? null
      : new Date(Date.now() - windowDays * 86_400_000).toISOString()
    const rows = db.prepare(
      `SELECT session_id, provider, model, turn_at, input_tokens, output_tokens,
              cache_read_tokens, duration_ms
         FROM agent_usage
        WHERE (? IS NULL OR turn_at >= ?)
        ORDER BY turn_at ASC`
    ).all(sinceBoundary, sinceBoundary) as UsageRow[]
    const validRows = rows.filter((row) => isAgentProvider(row.provider))
    return {
      windowDays,
      since: validRows[0]?.turn_at ?? null,
      totals: totalsFor(validRows),
      byProvider: AGENT_PROVIDERS
        .map((provider) => ({
          provider,
          rows: validRows.filter((row) => row.provider === provider)
        }))
        .filter(({ rows: providerRows }) => providerRows.length > 0)
        .map(({ provider, rows: providerRows }) =>
          providerSummary(provider, providerRows)
        )
    }
  }

  return { record, summary }
}
