/**
 * Maps the line-oriented `codex exec --json` protocol to Bandal's frozen
 * AgentEvent contract.
 *
 * The protocol shape was checked against Codex CLI 0.146.0's help/status and
 * the public CLI JSONL examples after a nested sandbox prevented a live turn
 * from reaching `thread.started` in the development runner. The fixture in
 * tests/main/agent/fixtures/codex-turn.jsonl records the exact consumed wire
 * vocabulary: thread.started, turn.started, item.started/item.updated/
 * item.completed and turn.completed.
 */

import type {
  AgentEvent,
  ToolResultSummary,
  Usage
} from '../../../../shared/types/agent-events'

type Raw = Record<string, unknown>
type ItemPhase = 'started' | 'updated' | 'completed'

interface ItemState {
  started: boolean
  text: string
}

const SUMMARY_MAX = 160
const PREVIEW_MAX = 2000

export interface CodexStreamMapper {
  map(raw: unknown): AgentEvent[]
  /** Emits a terminal event when an older CLI exits without turn.completed. */
  finishProcess(interrupted: boolean): AgentEvent[]
  readonly cliSessionId: string | null
  readonly turnComplete: boolean
}

function asRecord(value: unknown): Raw | null {
  return typeof value === 'object' && value !== null ? (value as Raw) : null
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function truncate(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max)}…`
}

function mapUsage(value: unknown): Usage | null {
  const raw = asRecord(value)
  const input = asNumber(raw?.['input_tokens'])
  const output = asNumber(raw?.['output_tokens'])
  if (input === null && output === null) {
    return null
  }
  const usage: Usage = {
    inputTokens: input ?? 0,
    outputTokens: output ?? 0
  }
  const cached = asNumber(raw?.['cached_input_tokens'])
  if (cached !== null) {
    usage.cacheReadTokens = cached
  }
  const cacheWrite = asNumber(raw?.['cache_write_input_tokens'])
  if (cacheWrite !== null) {
    usage.cacheCreationTokens = cacheWrite
  }
  return usage
}

function itemId(item: Raw): string {
  return asString(item['id']) ?? `codex-${asString(item['type']) ?? 'item'}`
}

function itemText(item: Raw): string {
  return (
    asString(item['text']) ??
    asString(item['message']) ??
    asString(item['aggregated_output']) ??
    ''
  )
}

function changedPaths(item: Raw): string[] {
  const changes = item['changes']
  if (!Array.isArray(changes)) {
    return []
  }
  return changes
    .map((change) => asString(asRecord(change)?.['path']))
    .filter((path): path is string => path !== null)
}

function toolLabel(item: Raw): string {
  const type = asString(item['type']) ?? 'tool'
  const command = asString(item['command'])
  if (command !== null) {
    return `명령 실행: ${truncate(command, SUMMARY_MAX)}`
  }
  const paths = changedPaths(item)
  if (paths.length > 0) {
    return `파일 변경: ${truncate(paths.join(', '), SUMMARY_MAX)}`
  }
  const query = asString(item['query'])
  if (query !== null) {
    return `검색: ${truncate(query, SUMMARY_MAX)}`
  }
  // Observed live but absent from the upstream docs we mapped against: Codex
  // emits todo_list items while it plans. Without this it rendered as the raw
  // string "todo list".
  if (type === 'todo_list') {
    const count = Array.isArray(item['items']) ? item['items'].length : 0
    return count > 0 ? `할 일 정리 (${count}개)` : '할 일 정리'
  }
  return type.replaceAll('_', ' ')
}

function toolInput(item: Raw): unknown {
  const type = asString(item['type'])
  if (type === 'command_execution') {
    return { command: asString(item['command']) ?? '' }
  }
  if (type === 'file_change') {
    return { changes: item['changes'] ?? [] }
  }
  if (type === 'todo_list') {
    return { items: item['items'] ?? [] }
  }
  const query = asString(item['query'])
  return query === null ? undefined : { query }
}

function toolSucceeded(item: Raw): boolean {
  const status = asString(item['status'])
  const exitCode = asNumber(item['exit_code'])
  return (
    status !== 'failed' &&
    status !== 'declined' &&
    (exitCode === null || exitCode === 0)
  )
}

function toolResult(item: Raw): ToolResultSummary {
  const output = (
    asString(item['aggregated_output']) ??
    asString(item['output']) ??
    asString(item['message']) ??
    ''
  ).trim()
  if (output !== '') {
    const firstLine = output.split('\n', 1)[0] ?? output
    return {
      summary: truncate(firstLine, SUMMARY_MAX),
      ...(output.length > SUMMARY_MAX
        ? {
            preview: output.slice(0, PREVIEW_MAX),
            truncated: output.length > PREVIEW_MAX
          }
        : {})
    }
  }
  const paths = changedPaths(item)
  if (paths.length > 0) {
    return { summary: `${paths.length}개 파일 변경: ${truncate(paths.join(', '), SUMMARY_MAX)}` }
  }
  return { summary: toolSucceeded(item) ? '완료' : '실패' }
}

function appendedText(previous: string, next: string): string {
  if (next.startsWith(previous)) {
    return next.slice(previous.length)
  }
  // A provider may replace a partial snapshot instead of extending it. The
  // frozen delta event has no replacement operation, so preserve the update.
  return next === previous ? '' : next
}

export function createCodexStreamMapper(): CodexStreamMapper {
  let cliSessionId: string | null = null
  let sessionStarted = false
  let activeTurn = false
  let completedTurn = false
  const items = new Map<string, ItemState>()

  function stateFor(id: string): ItemState {
    const current = items.get(id)
    if (current !== undefined) {
      return current
    }
    const created = { started: false, text: '' }
    items.set(id, created)
    return created
  }

  function mapTextItem(item: Raw, phase: ItemPhase): AgentEvent[] {
    const id = itemId(item)
    const state = stateFor(id)
    const text = itemText(item)
    const delta = appendedText(state.text, text)
    state.text = text
    const events: AgentEvent[] = []
    if (delta !== '') {
      events.push({ type: 'text-delta', blockId: id, text: delta })
    }
    if (phase === 'completed') {
      events.push({ type: 'text-final', blockId: id, text })
    }
    return events
  }

  function mapReasoningItem(item: Raw): AgentEvent[] {
    const id = itemId(item)
    const state = stateFor(id)
    const text = itemText(item)
    const delta = appendedText(state.text, text)
    state.text = text
    return delta === ''
      ? []
      : [{ type: 'thinking-delta', blockId: id, text: delta }]
  }

  function mapToolItem(item: Raw, phase: ItemPhase): AgentEvent[] {
    const id = itemId(item)
    const state = stateFor(id)
    const type = asString(item['type']) ?? 'tool'
    const events: AgentEvent[] = []
    if (!state.started) {
      state.started = true
      const input = toolInput(item)
      events.push({
        type: 'tool-start',
        toolCallId: id,
        toolName: type,
        label: toolLabel(item),
        ...(input === undefined ? {} : { input })
      })
    }
    if (phase === 'completed') {
      events.push({
        type: 'tool-end',
        toolCallId: id,
        ok: toolSucceeded(item),
        result: toolResult(item)
      })
    }
    return events
  }

  function mapItem(raw: Raw, phase: ItemPhase): AgentEvent[] {
    const item = asRecord(raw['item'])
    if (item === null) {
      return []
    }
    const type = asString(item['type'])
    if (type === 'agent_message') {
      return mapTextItem(item, phase)
    }
    if (type === 'reasoning') {
      return mapReasoningItem(item)
    }
    if (type === 'error') {
      const message = itemText(item) || 'Codex 도구 항목에서 오류가 발생했습니다.'
      return [{ type: 'error', code: 'unknown', message, fatal: false }]
    }
    return mapToolItem(item, phase)
  }

  function map(rawValue: unknown): AgentEvent[] {
    const raw = asRecord(rawValue)
    if (raw === null) {
      return []
    }
    const type = asString(raw['type'])
    if (type === 'thread.started') {
      const threadId = asString(raw['thread_id'])
      if (threadId === null) {
        return []
      }
      cliSessionId = threadId
      if (sessionStarted) {
        return []
      }
      sessionStarted = true
      return [
        {
          type: 'session-started',
          sessionId: threadId,
          model: asString(raw['model']) ?? 'codex',
          provider: 'codex'
        }
      ]
    }
    if (type === 'turn.started') {
      activeTurn = true
      completedTurn = false
      items.clear()
      return []
    }
    if (type === 'item.started') {
      return mapItem(raw, 'started')
    }
    if (type === 'item.updated') {
      return mapItem(raw, 'updated')
    }
    if (type === 'item.completed') {
      return mapItem(raw, 'completed')
    }
    if (type === 'turn.completed') {
      activeTurn = false
      completedTurn = true
      const usage = mapUsage(raw['usage'])
      return [
        {
          type: 'turn-complete',
          stopReason: 'success',
          ...(usage === null ? {} : { usage })
        }
      ]
    }
    if (type === 'turn.failed') {
      activeTurn = false
      completedTurn = true
      const error = asRecord(raw['error'])
      const message =
        asString(error?.['message']) ??
        asString(raw['message']) ??
        'Codex 턴이 실패했습니다.'
      return [
        { type: 'error', code: 'unknown', message, fatal: false },
        { type: 'turn-complete', stopReason: 'error' }
      ]
    }
    if (type === 'error') {
      activeTurn = false
      completedTurn = true
      return [
        {
          type: 'error',
          code: 'unknown',
          message: asString(raw['message']) ?? 'Codex 스트림 오류가 발생했습니다.',
          fatal: true
        }
      ]
    }
    return []
  }

  return {
    map,
    finishProcess(interrupted) {
      if (completedTurn || !activeTurn) {
        return []
      }
      activeTurn = false
      completedTurn = true
      return [
        {
          type: 'turn-complete',
          stopReason: interrupted ? 'interrupted' : 'success'
        }
      ]
    },
    get cliSessionId() {
      return cliSessionId
    },
    get turnComplete() {
      return completedTurn
    }
  }
}
