const MINUTE_MS = 60_000
const HOUR_MS = 60 * MINUTE_MS
const DAY_MS = 24 * HOUR_MS
const MONTH_MS = 30 * DAY_MS
const YEAR_MS = 365 * DAY_MS

export function formatTokens(value: number): string {
  return new Intl.NumberFormat('en-US', {
    maximumFractionDigits: 0
  }).format(Math.max(0, value))
}

export function formatDuration(milliseconds: number): string {
  const totalMinutes = Math.floor(Math.max(0, milliseconds) / MINUTE_MS)
  if (totalMinutes === 0) return '—'

  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  if (hours === 0) return `${formatTokens(minutes)}분`
  return minutes === 0
    ? `${formatTokens(hours)}시간`
    : `${formatTokens(hours)}시간 ${formatTokens(minutes)}분`
}

export function formatRelative(iso: string, now: Date | number): string {
  const timestamp = new Date(iso).getTime()
  const nowMs = now instanceof Date ? now.getTime() : now
  if (!Number.isFinite(timestamp) || !Number.isFinite(nowMs)) return '—'

  const elapsed = Math.max(0, nowMs - timestamp)
  if (elapsed < MINUTE_MS) return '방금 전'
  if (elapsed < HOUR_MS) return `${Math.floor(elapsed / MINUTE_MS)}분 전`
  if (elapsed < DAY_MS) return `${Math.floor(elapsed / HOUR_MS)}시간 전`
  if (elapsed < MONTH_MS) return `${Math.floor(elapsed / DAY_MS)}일 전`
  if (elapsed < YEAR_MS) return `${Math.floor(elapsed / MONTH_MS)}개월 전`
  return `${Math.floor(elapsed / YEAR_MS)}년 전`
}
