import type { AppleCalendarEvent } from '../../../../shared/types/appleCalendar'
import { localDateValue, type CalendarGridDay } from './calendarDate'

/** Calendar days, not 24-hour slices: overnight events and DST stay correct. */
export function appleEventsByDay(events: readonly AppleCalendarEvent[], days: readonly CalendarGridDay[], visibleTaskIds: ReadonlySet<string>): Map<string, AppleCalendarEvent[]> {
  const result = new Map<string, AppleCalendarEvent[]>()
  for (const day of days) {
    const next = new Date(day.date.getFullYear(), day.date.getMonth(), day.date.getDate() + 1)
    const entries = events.filter(event => {
      if (event.bandalTaskId && visibleTaskIds.has(event.bandalTaskId)) return false
      const start = localDateValue(event.start).getTime(), end = localDateValue(event.end).getTime()
      return start < next.getTime() && Math.max(end, start + 1) > day.date.getTime()
    }).sort((a, b) => Number(b.allDay) - Number(a.allDay) || a.start.localeCompare(b.start))
    if (entries.length) result.set(day.key, entries)
  }
  return result
}
