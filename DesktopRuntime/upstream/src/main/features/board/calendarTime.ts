const DAY_MS = 24 * 60 * 60 * 1000

/**
 * Calendar-day difference in the machine's local timezone.
 *
 * Local date parts are projected onto UTC before subtraction so DST-length
 * days still count as exactly one calendar boundary.
 */
export function localCalendarDayDifference(due: Date, now: Date): number {
  const dueDay = Date.UTC(due.getFullYear(), due.getMonth(), due.getDate())
  const nowDay = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate())
  return Math.round((dueDay - nowDay) / DAY_MS)
}

/** Exclusive local midnight after `daysFromToday`, for an indexed SQL bound. */
export function localDayEndExclusive(now: Date, daysFromToday: number): Date {
  return new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate() + daysFromToday + 1
  )
}
