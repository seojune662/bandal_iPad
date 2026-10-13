import type { AgentTurnFailure } from '../../../shared/types/agent-events'
import type { LearningRun } from '../../../shared/types/learning'

export interface LearningFailure {
  message: string
  code: string
  category: NonNullable<LearningRun['errorCategory']>
  actionable: string
}

export class LearningExecutionError extends Error {
  constructor(readonly failure: LearningFailure) { super(failure.message); this.name = 'LearningExecutionError' }
}

function providerDiagnostic(raw: string): { message: string; code?: string } {
  // CLI adapters can prefix an HTTP response with a short human-readable label.
  // Scan a bounded JSON object, respecting escaped quotes and braces in strings.
  const text = raw.slice(0, 16_000), start = text.indexOf('{')
  let depth = 0, quoted = false, escaped = false
  for (let index = start; start >= 0 && index < text.length; index += 1) {
    const character = text[index]
    if (quoted) {
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === '"') quoted = false
    } else if (character === '"') quoted = true
    else if (character === '{') depth += 1
    else if (character === '}' && --depth === 0) {
      try {
        const value = JSON.parse(text.slice(start, index + 1)) as Record<string, unknown>
        const error = value['error'] && typeof value['error'] === 'object' && !Array.isArray(value['error']) ? value['error'] as Record<string, unknown> : value
        const message = error['message']
        const code = [error['code'], error['type']].find(candidate => typeof candidate === 'string' && candidate !== 'error' && /^[a-zA-Z0-9_.:-]{1,128}$/.test(candidate))
        if (typeof message === 'string') return { message: message.slice(0, 4_000), ...(typeof code === 'string' ? { code } : {}) }
      } catch { /* Malformed envelopes retain a bounded plain diagnostic. */ }
      break
    }
  }
  return { message: raw.slice(0, 4_000) }
}

/** Keep the provider's useful reason, without persisting its full protocol envelope. */
export function learningFailure(error: unknown, fallback: LearningFailure['category'] = 'unknown'): LearningFailure {
  if (error instanceof LearningExecutionError) return error.failure
  const event = error && typeof error === 'object' ? error as Partial<AgentTurnFailure> : undefined
  const diagnostic = providerDiagnostic(error instanceof Error ? error.message : typeof error === 'string' ? error : typeof event?.message === 'string' ? event.message : 'AI 작업이 정상적으로 끝나지 않았어요.')
  const message = diagnostic.message
  const code = typeof event?.code === 'string' && event.code !== 'unknown' ? event.code : diagnostic.code ?? 'unknown'
  if (/model[\s\S]{0,160}(?:not supported|unsupported|not available|does not exist|not found|access|permission)|(?:unsupported|unavailable|invalid)[ -]model|모델.*(?:지원하지|사용할 수 없)/iu.test(message)) return { message, code: code === 'unknown' ? 'model-unavailable' : code, category: 'model', actionable: '이 연결에서 사용할 수 있는 다른 모델을 선택한 뒤 다시 시도하세요. 필요하면 모델 목록을 새로고침하세요.' }
  if (code === 'usage-limit' || /rate.?limit|quota|usage.?limit|insufficient.?quota|too many requests|한도|할당량/iu.test(message)) return { message, code: code === 'unknown' ? 'usage-limit' : code, category: 'quota', actionable: '제공자의 사용 한도와 초기화 시간을 확인한 뒤 다시 시도하세요.' }
  if (['not-installed', 'version-too-old', 'not-logged-in', 'spawn-failed'].includes(code) || /not.?logged.?in|unauthorized|authentication|login|sign.?in|로그인/iu.test(message)) return { message, code, category: 'connection', actionable: '설정에서 선택한 AI 연결을 확인하고 로그인한 뒤 다시 시도하세요.' }
  if (/network|connection|ECONN|ENOTFOUND|ERR_|fetch failed|timed?\s*out/iu.test(message)) return { message, code, category: 'network', actionable: '네트워크와 제공자 연결을 확인한 뒤 다시 시도하세요.' }
  const actionable = fallback === 'source' ? '원본 자료와 학습 공간의 연결을 확인한 뒤 다시 시도하세요.' : fallback === 'validation' ? '검증할 결과를 받지 못했어요. 다시 시도하거나 원본 자료를 확인하세요.' : '오류 내용을 확인하고 AI 연결이나 모델을 바꾼 뒤 다시 시도하세요.'
  return { message, code, category: fallback, actionable }
}
