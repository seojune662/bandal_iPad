export const CALLOUT_TYPES = [
  'note',
  'abstract',
  'info',
  'todo',
  'tip',
  'success',
  'question',
  'warning',
  'failure',
  'bug',
  'example',
  'quote'
] as const

export type CalloutType = (typeof CALLOUT_TYPES)[number]

const CALLOUT_TYPE_SET = new Set<string>(CALLOUT_TYPES)

export const CALLOUT_ALIASES: Readonly<Record<string, CalloutType>> = {
  summary: 'abstract',
  tldr: 'abstract',
  hint: 'tip',
  important: 'tip',
  check: 'success',
  done: 'success',
  help: 'question',
  faq: 'question',
  caution: 'warning',
  attention: 'warning',
  fail: 'failure',
  missing: 'failure',
  danger: 'failure',
  error: 'failure',
  cite: 'quote'
}

export const CALLOUT_LABELS: Readonly<Record<CalloutType, string>> = {
  note: '메모',
  abstract: '요약',
  info: '정보',
  todo: '할 일',
  tip: '팁',
  success: '성공',
  question: '질문',
  warning: '경고',
  failure: '실패',
  bug: '버그',
  example: '예시',
  quote: '인용'
}

export const CALLOUT_LINE =
  /^\[!([a-z][\w-]*)\]([+-])?(?:[ \t]+([^\n]*))?/i

/** Unknown source types keep their raw value in the node, but render as note. */
export function normalizeCalloutType(type: string): CalloutType {
  const normalized = type.trim().toLocaleLowerCase()
  if (CALLOUT_TYPE_SET.has(normalized)) return normalized as CalloutType
  return CALLOUT_ALIASES[normalized] ?? 'note'
}

export function calloutLabel(type: string): string {
  return CALLOUT_LABELS[normalizeCalloutType(type)]
}
