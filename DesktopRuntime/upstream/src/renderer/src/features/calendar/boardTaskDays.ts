import type { BoardTask } from '../../../../shared/types/board'
import { taskCalendarInterval } from '../../../../shared/taskSchedule'
import { localDateValue, type CalendarGridDay } from './calendarDate'

export function boardTasksByDay(tasks: readonly BoardTask[], days: readonly CalendarGridDay[]): Map<string, BoardTask[]> {
  const result = new Map<string, BoardTask[]>()
  for (const task of tasks) {
    const interval = taskCalendarInterval(task)
    if (!interval) continue
    const start = localDateValue(interval.start).getTime()
    const end = Math.max(localDateValue(interval.end).getTime(), start + 1)
    for (const day of days) {
      const next = new Date(day.date.getFullYear(), day.date.getMonth(), day.date.getDate() + 1)
      if (start < next.getTime() && end > day.date.getTime()) {
        const entries = result.get(day.key) ?? []
        entries.push(task)
        result.set(day.key, entries)
      }
    }
  }
  result.forEach(entries => entries.sort((a, b) => Number(b.allDay) - Number(a.allDay) || (a.startAt ?? a.dueAt ?? '').localeCompare(b.startAt ?? b.dueAt ?? '')))
  return result
}
