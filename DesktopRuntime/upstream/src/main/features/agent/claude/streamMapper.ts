/**
 * Maps raw Claude Code CLI stream-json lines to the C3 AgentEvent union.
 *
 * Wire behavior verified against claude 2.1.222 (see ../SPIKE-NOTES.md):
 *  - `stream_event` wraps raw Anthropic SSE events (deltas per block index);
 *  - a top-level `assistant` message re-reports each block once it completes
 *    (full text / fully parsed tool input) — this is the source of
 *    `text-final` and of the input-carrying refreshed `tool-start`;
 *  - `system:init` repeats every turn → session-started is deduped;
 *  - an interrupted turn ends with result subtype `error_during_execution`
 *    and terminal_reason `aborted_streaming`.
 */

import type {
  AgentEvent,
  AgentLimitEvent,
  AgentPermissionRequestEvent,
  AgentTurnCompleteEvent,
  PermissionSuggestion,
  ToolResultSummary,
  Usage
} from '../../../../shared/types/agent-events'

const TOOL_RESULT_SUMMARY_MAX = 120
const TOOL_RESULT_PREVIEW_MAX = 2000

export interface StreamMapper {
  /** Maps one parsed stdout JSON line into zero or more AgentEvents. */
  map(raw: unknown): AgentEvent[]
  /** Marks the in-flight turn as user-interrupted (affects stopReason). */
  markInterrupted(): void
  /** CLI session id, once the init event has been seen. */
  readonly cliSessionId: string | null
}

interface OpenBlock {
  blockId: string
  kind: 'text' | 'thinking' | 'tool_use'
  toolCallId?: string
}

type Raw = Record<string, unknown>

function asRecord(value: unknown): Raw | null {
  return typeof value === 'object' && value !== null ? (value as Raw) : null
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function mapUsage(raw: unknown): Usage | null {
  const record = asRecord(raw)
  if (record === null || typeof record['input_tokens'] !== 'number') {
    return null
  }
  const usage: Usage = {
    inputTokens: record['input_tokens'],
    outputTokens:
      typeof record['output_tokens'] === 'number' ? record['output_tokens'] : 0
  }
  if (typeof record['cache_read_input_tokens'] === 'number') {
    usage.cacheReadTokens = record['cache_read_input_tokens']
  }
  if (typeof record['cache_creation_input_tokens'] === 'number') {
    usage.cacheCreationTokens = record['cache_creation_input_tokens']
  }
  return usage
}

/** Human-readable one-liner for a tool invocation. */
export function toolLabel(toolName: string, input: unknown): string {
  const record = asRecord(input)
  const filePath = asString(record?.['file_path'])
  if (filePath !== null) {
    const base = filePath.split('/').pop() ?? filePath
    return `${toolName} ${base}`
  }
  const pattern = asString(record?.['pattern'])
  if (pattern !== null) {
    return `${toolName} "${pattern}"`
  }
  const query = asString(record?.['query'])
  if (query !== null) {
    return `${toolName} "${query}"`
  }
  const url = asString(record?.['url'])
  if (url !== null) {
    return `${toolName} ${url}`
  }
  return toolName
}

function extractResultText(content: unknown): string {
  if (typeof content === 'string') {
    return content
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => asString(asRecord(part)?.['text']) ?? '')
      .filter((text) => text !== '')
      .join('\n')
  }
  return ''
}

function summarizeToolResult(content: unknown): ToolResultSummary {
  const text = extractResultText(content).trim()
  if (text === '') {
    return { summary: 'Done' }
  }
  const firstLine = text.split('\n', 1)[0] ?? text
  const summary =
    firstLine.length > TOOL_RESULT_SUMMARY_MAX
      ? `${firstLine.slice(0, TOOL_RESULT_SUMMARY_MAX)}…`
      : firstLine
  const result: ToolResultSummary = { summary }
  if (text.length > summary.length) {
    result.preview = text.slice(0, TOOL_RESULT_PREVIEW_MAX)
    result.truncated = text.length > TOOL_RESULT_PREVIEW_MAX
  }
  return result
}

function mapSuggestions(raw: unknown, toolName: string): PermissionSuggestion[] {
  if (!Array.isArray(raw)) {
    return []
  }
  const suggestions: PermissionSuggestion[] = []
  raw.forEach((entry, index) => {
    const record = asRecord(entry)
    if (record === null) {
      return
    }
    const kind = asString(record['type'])
    if (kind === 'setMode') {
      suggestions.push({
        id: `s${index}`,
        label: `Allow edits for this session (${asString(record['mode']) ?? 'acceptEdits'})`,
        behavior: 'allow',
        remember: true
      })
    } else if (kind === 'addRules') {
      suggestions.push({
        id: `s${index}`,
        label: `Always allow ${toolName} in this course`,
        behavior: 'allow',
        remember: true
      })
    }
  })
  return suggestions
}

export function createStreamMapper(): StreamMapper {
  let cliSessionId: string | null = null
  let sessionStarted = false
  let currentMessageId: string | null = null
  let interrupted = false
  let syntheticCounter = 0
  /** Streaming blocks by stream index. */
  let openBlocks = new Map<number, OpenBlock>()

  function blockIdFor(index: number): string {
    const messageId = currentMessageId ?? `synthetic-${(syntheticCounter += 1)}`
    return `${messageId}#${index}`
  }

  function findOpenByKind(kind: OpenBlock['kind']): OpenBlock | null {
    for (const block of openBlocks.values()) {
      if (block.kind === kind) {
        return block
      }
    }
    return null
  }

  function mapStreamEvent(event: Raw): AgentEvent[] {
    const type = asString(event['type'])
    if (type === 'message_start') {
      const message = asRecord(event['message'])
      currentMessageId = asString(message?.['id'])
      openBlocks = new Map()
      return []
    }
    if (type === 'content_block_start') {
      return mapBlockStart(event)
    }
    if (type === 'content_block_delta') {
      return mapBlockDelta(event)
    }
    if (type === 'content_block_stop') {
      const index = event['index']
      if (typeof index === 'number') {
        openBlocks.delete(index)
      }
      return []
    }
    if (type === 'message_delta') {
      const usage = mapUsage(event['usage'])
      return usage === null ? [] : [{ type: 'usage', usage }]
    }
    return []
  }

  function mapBlockStart(event: Raw): AgentEvent[] {
    const index = event['index']
    const contentBlock = asRecord(event['content_block'])
    if (typeof index !== 'number' || contentBlock === null) {
      return []
    }
    const kind = asString(contentBlock['type'])
    if (kind !== 'text' && kind !== 'thinking' && kind !== 'tool_use') {
      return []
    }
    const block: OpenBlock = { blockId: blockIdFor(index), kind }
    if (kind === 'tool_use') {
      const toolCallId = asString(contentBlock['id']) ?? block.blockId
      const toolName = asString(contentBlock['name']) ?? 'tool'
      block.toolCallId = toolCallId
      openBlocks.set(index, block)
      return [
        {
          type: 'tool-start',
          toolCallId,
          toolName,
          label: toolName
        }
      ]
    }
    openBlocks.set(index, block)
    return []
  }

  function mapBlockDelta(event: Raw): AgentEvent[] {
    const index = event['index']
    const delta = asRecord(event['delta'])
    if (typeof index !== 'number' || delta === null) {
      return []
    }
    const block = openBlocks.get(index)
    if (block === undefined) {
      return []
    }
    const kind = asString(delta['type'])
    if (kind === 'text_delta') {
      const text = asString(delta['text']) ?? ''
      return text === ''
        ? []
        : [{ type: 'text-delta', blockId: block.blockId, text }]
    }
    if (kind === 'thinking_delta') {
      const text = asString(delta['thinking']) ?? ''
      return text === ''
        ? []
        : [{ type: 'thinking-delta', blockId: block.blockId, text }]
    }
    if (kind === 'input_json_delta' && block.toolCallId !== undefined) {
      const partial = asString(delta['partial_json']) ?? ''
      return partial === ''
        ? []
        : [
            {
              type: 'tool-input-delta',
              toolCallId: block.toolCallId,
              partialInput: partial
            }
          ]
    }
    return []
  }

  /** Completed blocks re-reported by the CLI (source of finals). */
  function mapAssistantMessage(raw: Raw): AgentEvent[] {
    const message = asRecord(raw['message'])
    const content = message?.['content']
    if (!Array.isArray(content)) {
      return []
    }
    // Claude emits expired OAuth failures as synthetic assistant messages.
    // Keep them in the existing connection notice instead of saving API text
    // as if it were the tutor's answer.
    const messageText = extractResultText(content)
    if (raw['error'] === 'authentication_failed' || /^Failed to authenticate[.:]/i.test(messageText.trim())) {
      return [{ type: 'error', code: 'not-logged-in', message: 'Claude 연결이 만료됐어요. 설정 → AI에서 다시 로그인해 주세요.', fatal: false }]
    }
    const events: AgentEvent[] = []
    for (const entry of content) {
      const block = asRecord(entry)
      if (block === null) {
        continue
      }
      const kind = asString(block['type'])
      if (kind === 'text') {
        const open = findOpenByKind('text')
        const blockId =
          open?.blockId ??
          `${asString(message?.['id']) ?? 'msg'}#final-${(syntheticCounter += 1)}`
        events.push({
          type: 'text-final',
          blockId,
          text: asString(block['text']) ?? ''
        })
      } else if (kind === 'tool_use') {
        const toolCallId = asString(block['id']) ?? `tool-${(syntheticCounter += 1)}`
        const toolName = asString(block['name']) ?? 'tool'
        events.push({
          type: 'tool-start',
          toolCallId,
          toolName,
          label: toolLabel(toolName, block['input']),
          input: block['input']
        })
      } else if (kind === 'thinking' && findOpenByKind('thinking') === null) {
        // Non-streamed thinking block (no prior deltas): surface it once.
        const text = asString(block['thinking']) ?? ''
        if (text !== '') {
          events.push({
            type: 'thinking-delta',
            blockId: `${asString(message?.['id']) ?? 'msg'}#think-${(syntheticCounter += 1)}`,
            text
          })
        }
      }
    }
    return events
  }

  function mapToolResults(raw: Raw): AgentEvent[] {
    const message = asRecord(raw['message'])
    const content = message?.['content']
    if (!Array.isArray(content)) {
      return []
    }
    const events: AgentEvent[] = []
    for (const entry of content) {
      const block = asRecord(entry)
      if (block === null || asString(block['type']) !== 'tool_result') {
        continue
      }
      const toolCallId = asString(block['tool_use_id'])
      if (toolCallId === null) {
        continue
      }
      events.push({
        type: 'tool-end',
        toolCallId,
        ok: block['is_error'] !== true,
        result: summarizeToolResult(block['content'])
      })
    }
    return events
  }

  function mapResult(raw: Raw): AgentEvent[] {
    const subtype = asString(raw['subtype'])
    const wasInterrupted = interrupted
    interrupted = false
    openBlocks = new Map()
    currentMessageId = null

    let stopReason: 'success' | 'max-turns' | 'interrupted' | 'error'
    if (subtype === 'success') {
      stopReason = 'success'
    } else if (
      wasInterrupted &&
      (raw['terminal_reason'] === 'aborted_streaming' ||
        subtype === 'error_during_execution')
    ) {
      stopReason = 'interrupted'
    } else if (subtype === 'error_max_turns') {
      stopReason = 'max-turns'
    } else {
      stopReason = 'error'
    }

    const event: AgentTurnCompleteEvent = { type: 'turn-complete', stopReason }
    const usage = mapUsage(raw['usage'])
    if (usage !== null) {
      event.usage = usage
    }
    if (typeof raw['total_cost_usd'] === 'number') {
      event.costUsd = raw['total_cost_usd']
    }
    if (typeof raw['duration_ms'] === 'number') {
      event.durationMs = raw['duration_ms']
    }
    return [event]
  }

  function mapSystem(raw: Raw): AgentEvent[] {
    if (asString(raw['subtype']) !== 'init') {
      return []
    }
    cliSessionId = asString(raw['session_id'])
    if (sessionStarted) {
      return [] // init repeats every turn — report the session once
    }
    sessionStarted = true
    return [
      {
        type: 'session-started',
        sessionId: cliSessionId ?? 'unknown',
        model: asString(raw['model']) ?? 'unknown',
        provider: 'claude-code'
      }
    ]
  }

  function mapRateLimit(raw: Raw): AgentEvent[] {
    const info = asRecord(raw['rate_limit_info'])
    if (info === null || info['status'] === 'allowed') {
      return []
    }
    const event: AgentLimitEvent = {
      type: 'limit',
      limitKind: 'rate',
      message: `Claude Code rate limit reached (${asString(info['status']) ?? 'limited'})`
    }
    if (typeof info['resetsAt'] === 'number') {
      event.resetsAt = new Date(info['resetsAt'] * 1000).toISOString()
    }
    return [event]
  }

  function mapControlRequest(raw: Raw): AgentEvent[] {
    const request = asRecord(raw['request'])
    const requestId = asString(raw['request_id'])
    if (
      request === null ||
      requestId === null ||
      asString(request['subtype']) !== 'can_use_tool'
    ) {
      return []
    }
    const toolName = asString(request['tool_name']) ?? 'tool'
    const suggestions = mapSuggestions(
      request['permission_suggestions'],
      toolName
    )
    const event: AgentPermissionRequestEvent = {
      type: 'permission-request',
      requestId,
      toolName,
      input: request['input']
    }
    if (suggestions.length > 0) {
      event.suggestions = suggestions
    }
    return [event]
  }

  return {
    get cliSessionId() {
      return cliSessionId
    },
    markInterrupted: () => {
      interrupted = true
    },
    map: (raw) => {
      const record = asRecord(raw)
      if (record === null) {
        return []
      }
      switch (asString(record['type'])) {
        case 'system':
          return mapSystem(record)
        case 'stream_event': {
          const event = asRecord(record['event'])
          return event === null ? [] : mapStreamEvent(event)
        }
        case 'assistant':
          return mapAssistantMessage(record)
        case 'user':
          return mapToolResults(record)
        case 'result':
          return mapResult(record)
        case 'rate_limit_event':
          return mapRateLimit(record)
        case 'control_request':
          return mapControlRequest(record)
        default:
          return []
      }
    }
  }
}
