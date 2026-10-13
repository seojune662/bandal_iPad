import type { BoardTask } from '../../../../shared/types/board'

const DAY_MS = 24 * 60 * 60 * 1000

export interface CalendarGridDay {
  date: Date
  key: string
  inMonth: boolean
  isToday: boolean
}

export interface CalendarMonthGrid {
  days: CalendarGridDay[]
  from: string
  to: string
}

function pad(value: number): string {
  return String(value).padStart(2, '0')
}

interface LocalDateParts {
  year: number
  month: number
  day: number
}

const DATE_KEY_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/u

function dateKeyParts(value: string): LocalDateParts | null {
  const match = DATE_KEY_PATTERN.exec(value)
  if (match === null) return null
  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if (month < 1 || month > 12 || day < 1 || day > (daysInMonth[month - 1] ?? 0)) {
    return null
  }
  return { year, month, day }
}

/** Parses BND-014 date keys at local midnight and keeps legacy ISO support. */
export function localDateValue(value: Date | string): Date {
  if (value instanceof Date) return value
  const parts = dateKeyParts(value)
  return parts === null
    ? new Date(value)
    : new Date(parts.year, parts.month - 1, parts.day)
}

/** Local-calendar midnight as ISO for legacy helpers that still take ISO. */
export function localDayIso(value: string | null): string | null {
  if (value === null) return null
  return localDateFromKey(localDateKey(value)).toISOString()
}

/** Stable YYYY-MM-DD key using local—not UTC—date parts. */
export function localDateKey(value: Date | string): string {
  // An all-day dueAt is already a calendar key. Returning it directly is the
  // round-trip guarantee: no timezone conversion can move it to another day.
  if (typeof value === 'string' && dateKeyParts(value) !== null) return value
  const date = localDateValue(value)
  if (Number.isNaN(date.getTime())) return ''
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

/** Difference between local calendar dates, independent of hours and DST. */
export function localCalendarDayDifference(
  due: Date | string,
  now: Date | string
): number {
  const dueDate = localDateValue(due)
  const nowDate = localDateValue(now)
  const dueDay = Date.UTC(
    dueDate.getFullYear(),
    dueDate.getMonth(),
    dueDate.getDate()
  )
  const nowDay = Date.UTC(
    nowDate.getFullYear(),
    nowDate.getMonth(),
    nowDate.getDate()
  )
  return Math.round((dueDay - nowDay) / DAY_MS)
}

export function localDateFromKey(key: string, time = '00:00'): Date {
  const parts = dateKeyParts(key)
  if (parts === null) return new Date(Number.NaN)
  const [hour = 0, minute = 0] = time.split(':').map(Number)
  return new Date(parts.year, parts.month - 1, parts.day, hour, minute)
}

export function dueAtForLocalInput(
  dateKey: string,
  time: string,
  allDay: boolean
): string {
  if (!dateKeyParts(dateKey)) throw new Error('유효한 날짜를 입력해주세요.')
  if (allDay) return dateKey
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) throw new Error('유효한 시각을 입력해주세요.')
  const date = localDateFromKey(dateKey, time)
  if (localDateKey(date) !== dateKey || localTimeInput(date.toISOString()) !== time) {
    throw new Error('선택한 시간대에 존재하지 않는 시각입니다. 다른 시각을 지정해주세요.')
  }
  return date.toISOString()
}

export function localTimeInput(value: string | null): string {
  if (value === null) return '23:59'
  const date = localDateValue(value)
  if (Number.isNaN(date.getTime())) return '23:59'
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export function calendarMonthGrid(
  cursor: Date,
  today: Date = new Date()
): CalendarMonthGrid {
  const year = cursor.getFullYear()
  const month = cursor.getMonth()
  const first = new Date(year, month, 1)
  const monthDays = new Date(year, month + 1, 0).getDate()
  const cellCount = Math.ceil((first.getDay() + monthDays) / 7) * 7
  const start = new Date(year, month, 1 - first.getDay())
  const days = Array.from({ length: cellCount }, (_, index) => {
    const date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + index)
    return {
      date,
      key: localDateKey(date),
      inMonth: date.getMonth() === month,
      isToday: localDateKey(date) === localDateKey(today)
    }
  })
  const end = new Date(
    start.getFullYear(),
    start.getMonth(),
    start.getDate() + cellCount
  )
  return { days, from: start.toISOString(), to: end.toISOString() }
}

export function taskIsOverdue(task: BoardTask, now: Date = new Date()): boolean {
  if (task.dueAt === null || task.status === 'done') return false
  const due = localDateValue(task.dueAt)
  if (Number.isNaN(due.getTime())) return false
  return task.allDay
    ? localCalendarDayDifference(task.dueAt, now) < 0
    : due.getTime() < now.getTime()
}
