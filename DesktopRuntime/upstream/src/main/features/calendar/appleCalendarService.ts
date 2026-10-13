import { taskCalendarInterval } from '../../../shared/taskSchedule'
import type { AppleCalendar, AppleCalendarEvent, AppleCalendarPreferences, AppleCalendarState, CalendarAuthorization } from '../../../shared/types/appleCalendar'
import type { BoardTask } from '../../../shared/types/board'

export interface CalendarConfig extends AppleCalendarPreferences {
  initialized: boolean
  exports: Record<string, string>
}
export const EMPTY_CALENDAR_CONFIG: CalendarConfig = {
  initialized: false, connected: false, selectedCalendarIds: [], destinationCalendarId: null, exports: {}
}
interface NativeState {
  authorization: CalendarAuthorization
  calendars: AppleCalendar[]
  defaultCalendarId: string | null
}
export interface CalendarNative {
  state(connect: boolean, includeCalendars: boolean): Promise<NativeState>
  events(input: { from: string; to: string; calendarIds: string[] }): Promise<AppleCalendarEvent[]>
  export(input: { taskId: string; calendarId: string; title: string; notes: string; start: string; end: string; allDay: boolean; eventId: string | null }): Promise<{ eventId: string; updated: boolean }>
}

export function sanitizeCalendarConfig(raw: unknown): CalendarConfig {
  const value = (raw !== null && typeof raw === 'object' ? raw : {}) as Partial<CalendarConfig>
  const ids = Array.isArray(value.selectedCalendarIds) ? value.selectedCalendarIds.filter((id): id is string => typeof id === 'string' && id.length > 0 && id.length < 1024) : []
  return {
    initialized: value.initialized === true || value.connected === true || ids.length > 0 || typeof value.destinationCalendarId === 'string',
    connected: value.connected === true,
    selectedCalendarIds: [...new Set(ids)].slice(0, 500),
    destinationCalendarId: typeof value.destinationCalendarId === 'string' ? value.destinationCalendarId : null,
    exports: value.exports && typeof value.exports === 'object' ? Object.fromEntries(Object.entries(value.exports).filter(([key, id]) => key.length < 1024 && typeof id === 'string' && id.length < 4096)) : {}
  }
}

export function createAppleCalendarService(deps: {
  supported: boolean
  native: CalendarNative
  load(): unknown
  save(config: CalendarConfig): void
  changed(): void
  task(id: string): BoardTask | undefined
}) {
  let config = sanitizeCalendarConfig(deps.load())
  let tail: Promise<unknown> = Promise.resolve()
  const mutate = <T>(action: () => Promise<T>): Promise<T> => {
    const result = tail.then(action)
    tail = result.catch(() => {})
    return result
  }
  const persist = (next: CalendarConfig): void => {
    deps.save(next) // Failed disk writes leave the in-memory state unchanged.
    config = next
    deps.changed()
  }
  const state = async (): Promise<AppleCalendarState> => {
    if (!deps.supported) return { ...EMPTY_CALENDAR_CONFIG, supported: false, authorization: 'not-determined', calendars: [] }
    const native = await deps.native.state(false, config.connected)
    return { connected: config.connected, selectedCalendarIds: config.selectedCalendarIds.filter(id => native.calendars.some(c => c.id === id)), destinationCalendarId: native.calendars.some(c => c.id === config.destinationCalendarId && c.writable) ? config.destinationCalendarId : null, supported: true, ...native }
  }
  const requireConnection = async (): Promise<NativeState> => {
    if (!deps.supported) throw new Error('Apple 캘린더는 Mac에서 연결할 수 있습니다.')
    if (!config.connected) throw new Error('설정에서 Apple 캘린더를 먼저 연결해주세요.')
    const native = await deps.native.state(false, true)
    if (native.authorization !== 'authorized') throw new Error('캘린더 접근 권한이 꺼져 있습니다. 시스템 설정에서 전체 접근을 허용해주세요.')
    return native
  }
  return {
    state,
    connect: () => mutate(async () => {
      if (!deps.supported) return state()
      const native = await deps.native.state(true, true)
      if (native.authorization === 'authorized') {
        // Preserve an intentionally empty selection when reconnecting an existing configuration.
        const firstConnection = !config.initialized
        persist({ ...config, initialized: true, connected: true,
          selectedCalendarIds: firstConnection ? native.calendars.map(c => c.id) : config.selectedCalendarIds,
          destinationCalendarId: firstConnection ? native.defaultCalendarId ?? native.calendars.find(c => c.writable)?.id ?? null : config.destinationCalendarId })
      }
      return { supported: true, connected: config.connected, selectedCalendarIds: [...config.selectedCalendarIds], destinationCalendarId: config.destinationCalendarId, ...native }
    }),
    disconnect: () => mutate(async () => {
      persist({ ...config, connected: false })
      return state()
    }),
    configure: (input: Pick<AppleCalendarPreferences, 'selectedCalendarIds' | 'destinationCalendarId'>) => mutate(async () => {
      const native = await requireConnection()
      if (!Array.isArray(input.selectedCalendarIds) || input.selectedCalendarIds.some(id => typeof id !== 'string' || !native.calendars.some(c => c.id === id))) throw new Error('더 이상 사용할 수 없는 캘린더가 있습니다. 목록을 새로고침해주세요.')
      if (input.destinationCalendarId !== null && !native.calendars.some(c => c.id === input.destinationCalendarId && c.writable)) throw new Error('일정을 저장할 수 있는 캘린더를 선택해주세요.')
      persist({ ...config, selectedCalendarIds: [...new Set(input.selectedCalendarIds)], destinationCalendarId: input.destinationCalendarId })
      return state()
    }),
    events: async (input: { from: string; to: string }): Promise<AppleCalendarEvent[]> => {
      if (!deps.supported || !config.connected) return []
      const from = Date.parse(input.from), to = Date.parse(input.to)
      if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from || to - from > 366 * 86400000) throw new Error('캘린더 조회 범위가 올바르지 않습니다.')
      const snapshot = config
      const native = await requireConnection()
      const ids = snapshot.selectedCalendarIds.filter(id => native.calendars.some(c => c.id === id))
      if (ids.length === 0) return []
      const events = await deps.native.events({ ...input, calendarIds: ids })
      return config === snapshot ? events : [] // Never paint events from a disconnected/changed selection.
    },
    exportTask: (taskId: string) => mutate(async () => {
      const native = await requireConnection()
      const task = deps.task(taskId)
      if (!task) throw new Error('일정을 찾을 수 없습니다. 삭제된 일정인지 확인해주세요.')
      const interval = taskCalendarInterval(task)
      if (!interval) throw new Error('일정에 날짜를 먼저 지정해주세요.')
      const calendarId = config.destinationCalendarId
      if (!calendarId || !native.calendars.some(c => c.id === calendarId && c.writable)) throw new Error('설정에서 일정을 보낼 캘린더를 선택해주세요.')
      const result = await deps.native.export({ taskId, calendarId, title: task.title, notes: task.notes, ...interval, eventId: config.exports[taskId] ?? null })
      persist({ ...config, exports: { ...config.exports, [taskId]: result.eventId } })
      return result
    })
  }
}
