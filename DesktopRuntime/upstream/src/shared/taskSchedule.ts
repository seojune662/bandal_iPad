import type { BoardTask } from './types/board'

/** Date keys are floating calendar dates, never UTC instants. */
export function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const date = new Date(`${value}T00:00:00.000Z`)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
}

/** All-day end dates include the selected final day; calendar APIs use exclusive ends. */
export function taskCalendarInterval(task: Pick<BoardTask, 'startAt' | 'dueAt' | 'allDay'>): {
  start: string; end: string; allDay: boolean
} | null {
  if (!task.dueAt) return null
  const start = task.startAt ?? task.dueAt
  let end = task.dueAt
  if (task.allDay) {
    if (!isCalendarDate(start) || !isCalendarDate(end) || start > end) {
      throw new Error('시작일과 종료일을 확인해주세요.')
    }
    const exclusive = new Date(`${end}T00:00:00.000Z`)
    exclusive.setUTCDate(exclusive.getUTCDate() + 1)
    end = exclusive.toISOString().slice(0, 10)
  } else if (!Number.isFinite(Date.parse(start)) || !Number.isFinite(Date.parse(end)) || Date.parse(start) > Date.parse(end)) {
    throw new Error('종료 시각은 시작 시각보다 빠를 수 없습니다.')
  }
  // A deadline is a point in time. Never invent a duration that crosses midnight.
  return { start, end, allDay: task.allDay }
}
