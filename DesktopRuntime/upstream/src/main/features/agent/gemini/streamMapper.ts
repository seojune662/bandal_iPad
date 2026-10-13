import type {
  AgentErrorCode,
  AgentEvent,
  ToolResultSummary,
  Usage
} from '../../../../shared/types/agent-events'

type Raw = Record<string, unknown>

export interface GeminiStreamMapper {
  beginTurn(): void
  map(raw: unknown): AgentEvent[]
  finishProcess(interrupted: boolean, exitCode: number | null, stderr: string): AgentEvent[]
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

function errorMessage(value: unknown, fallback: string): string {
  const raw = asRecord(value)
  return asString(raw?.['message']) ?? asString(value) ?? fallback
}

function mapUsage(value: unknown): Usage | null {
  const raw = asRecord(value)
  const input = asNumber(raw?.['input_tokens'])
  const output = asNumber(raw?.['output_tokens'])
  if (input === null && output === null) return null
  const usage: Usage = {
    inputTokens: input ?? 0,
    outputTokens: output ?? 0
  }
  const cached = asNumber(raw?.['cached'])
  if (cached !== null) usage.cacheReadTokens = cached
  return usage
}

function summarize(value: unknown): ToolResultSummary {
  const text =
    typeof value === 'string' ? value.trim() : JSON.stringify(value ?? '')
  const firstLine = text.split('\n', 1)[0] ?? text
  const summary = firstLine.length > 160 ? `${firstLine.slice(0, 160)}…` : firstLine
  return {
    summary: summary === '' ? '완료' : summary,
    ...(text.length > summary.length
      ? { preview: text.slice(0, 2000), truncated: text.length > 2000 }
      : {})
  }
}

const INELIGIBLE_ACCOUNT =
  /IneligibleTierError|not eligible|RESTRICTED_DASHER/iu

function classifyError(message: string): AgentErrorCode {
  return /IneligibleTierError|not eligible|RESTRICTED_DASHER|auth method|authenticate|authentication|login|logged in|credential/iu.test(
    message
  )
    ? 'not-logged-in'
    : 'unknown'
}

function visibleError(message: string): string {
  if (INELIGIBLE_ACCOUNT.test(message)) {
    return '이 구글 계정은 무료 Gemini를 쓸 수 없어요(학교·회사 계정). 개인 Gmail 계정으로 로그인하거나 설정 > AI 엔진에서 Gemini API 키를 넣어 주세요.'
  }
  if (classifyError(message) === 'not-logged-in') {
    return 'Gemini에 로그인이 필요해요.'
  }
  const visible = message
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) =>
      line !== '' &&
      !/^at\s+.*file:\/\//iu.test(line) &&
      !/Warning:\s*256-color support not detected/iu.test(line) &&
      !/Ripgrep is not available/iu.test(line)
    )
    .slice(0, 2)
  return visible.join('\n') || 'Gemini가 알 수 없는 오류로 종료했습니다.'
}

export function mapGeminiProcessFailure(
  exitCode: number | null,
  stderr: string
): AgentEvent[] {
  if (exitCode === 53) {
    return [
      {
        type: 'error',
        code: 'unknown',
        message: '턴 한도에 도달했어요.',
        fatal: false
      },
      { type: 'turn-complete', stopReason: 'max-turns' }
    ]
  }
  const detail = stderr.trim() || `Gemini가 코드 ${exitCode ?? '없음'}로 종료했습니다.`
  const code = classifyError(detail)
  return [
    {
      type: 'error',
      code: code === 'unknown' ? 'process-crashed' : code,
      message: visibleError(detail),
      fatal: true
    }
  ]
}

export function createGeminiStreamMapper(): GeminiStreamMapper {
  let cliSessionId: string | null = null
  let sessionStarted = false
  let activeTurn = false
  let completedTurn = false
  let turnNumber = 0
  let assistantText = ''

  function blockId(): string {
    return `gemini-assistant-${turnNumber}`
  }

  function mapInit(raw: Raw): AgentEvent[] {
    const sessionId = asString(raw['session_id'])
    if (sessionId === null) return []
    cliSessionId = sessionId
    if (sessionStarted) return []
    sessionStarted = true
    return [{
      type: 'session-started',
      sessionId,
      model: asString(raw['model']) ?? 'auto',
      provider: 'gemini'
    }]
  }

  function mapResult(raw: Raw): AgentEvent[] {
    completedTurn = true
    activeTurn = false
    const events: AgentEvent[] = []
    if (assistantText !== '') {
      events.push({ type: 'text-final', blockId: blockId(), text: assistantText })
    }
    if (raw['status'] === 'error') {
      const message = errorMessage(raw['error'], 'Gemini 턴이 실패했습니다.')
      events.push({
        type: 'error',
        code: classifyError(message),
        message: visibleError(message),
        fatal: false
      })
    }
    const stats = asRecord(raw['stats'])
    const usage = mapUsage(stats)
    const durationMs = asNumber(stats?.['duration_ms'])
    events.push({
      type: 'turn-complete',
      stopReason: raw['status'] === 'success' ? 'success' : 'error',
      ...(usage === null ? {} : { usage }),
      ...(durationMs === null ? {} : { durationMs })
    })
    return events
  }

  return {
    beginTurn() {
      activeTurn = true
      completedTurn = false
      assistantText = ''
      turnNumber += 1
    },
    map(value) {
      const raw = asRecord(value)
      if (raw === null) return []
      const type = asString(raw['type'])
      if (type === 'init') return mapInit(raw)
      if (type === 'message' && raw['role'] === 'assistant') {
        const text = asString(raw['content']) ?? ''
        if (text === '') return []
        assistantText += text
        return [{ type: 'text-delta', blockId: blockId(), text }]
      }
      if (type === 'tool_use') {
        const id = asString(raw['tool_id']) ?? `gemini-tool-${turnNumber}`
        const name = asString(raw['tool_name']) ?? 'tool'
        return [{
          type: 'tool-start',
          toolCallId: id,
          toolName: name,
          label: name,
          input: raw['parameters']
        }]
      }
      if (type === 'tool_result') {
        return [{
          type: 'tool-end',
          toolCallId: asString(raw['tool_id']) ?? `gemini-tool-${turnNumber}`,
          ok: raw['status'] === 'success',
          result: summarize(raw['output'] ?? raw['error'])
        }]
      }
      if (type === 'result') return mapResult(raw)
      if (type === 'error') {
        const message = errorMessage(raw['error'] ?? raw['message'], 'Gemini 스트림 오류가 발생했습니다.')
        completedTurn = true
        activeTurn = false
        return [{
          type: 'error',
          code: classifyError(message),
          message: visibleError(message),
          fatal: true
        }]
      }
      return []
    },
    finishProcess(interrupted, exitCode, stderr) {
      if (completedTurn || !activeTurn) return []
      completedTurn = true
      activeTurn = false
      if (interrupted) {
        return [{ type: 'turn-complete', stopReason: 'interrupted' }]
      }
      return exitCode === 0
        ? [{ type: 'turn-complete', stopReason: 'success' }]
        : mapGeminiProcessFailure(exitCode, stderr)
    },
    get cliSessionId() {
      return cliSessionId
    },
    get turnComplete() {
      return completedTurn
    }
  }
}
