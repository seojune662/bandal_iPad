export type CalendarAuthorization = 'not-determined' | 'denied' | 'restricted' | 'write-only' | 'authorized'

export interface AppleCalendar {
  id: string
  title: string
  source: string
  color: string
  writable: boolean
}

export interface AppleCalendarPreferences {
  connected: boolean
  selectedCalendarIds: string[]
  destinationCalendarId: string | null
}

export interface AppleCalendarState extends AppleCalendarPreferences {
  supported: boolean
  authorization: CalendarAuthorization
  calendars: AppleCalendar[]
}

/** EventKit returns occurrences, including expanded recurring events. End is exclusive. */
export interface AppleCalendarEvent {
  id: string
  calendarId: string
  title: string
  start: string
  end: string
  allDay: boolean
  location: string
  calendarTitle: string
  color: string
  /** An event exported by this app; hide its duplicate when that task is visible. */
  bandalTaskId: string | null
}
