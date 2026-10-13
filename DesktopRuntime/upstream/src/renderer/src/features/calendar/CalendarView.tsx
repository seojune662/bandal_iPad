import { TaskScheduleFields, useTaskSchedule } from './TaskScheduleFields'
import { boardTasksByDay } from './boardTaskDays'
import type { AppleCalendarEvent, AppleCalendarState } from '../../../../shared/types/appleCalendar'
import { useUiStore } from '../../stores/uiStore'
import { appleEventsByDay } from './appleCalendarDays'
import './appleCalendar.css'
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import type { BoardTask, TaskKind } from '../../../../shared/types/board'
import type { Course } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { invoke, onPush } from '../../lib/ipc'
import { normalizeCourseColor } from '../courses/courseColors'
import {
  calendarMonthGrid,
  localDateFromKey,
  localDateKey,
  taskIsOverdue
} from './calendarDate'
import './calendar.css'
import '../board/boardForms.css'

const WEEKDAYS = ['일', '월', '화', '수', '목', '금', '토'] as const
const KIND_LABELS: Record<TaskKind, string> = {
  task: '할 일',
  assignment: '과제',
  exam: '시험',
  class: '수업'
}

export function subscribeToToday(
  onToday: (today: Date) => void
): () => void {
  let timeout: ReturnType<typeof globalThis.setTimeout> | null = null

  const schedule = (): void => {
    const now = new Date()
    const nextMidnight = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate() + 1
    )
    timeout = globalThis.setTimeout(() => {
      onToday(new Date())
      schedule()
    }, nextMidnight.getTime() - now.getTime())
  }

  schedule()
  return () => {
    if (timeout !== null) globalThis.clearTimeout(timeout)
  }
}

export function useToday(): Date {
  const [today, setToday] = useState(() => new Date())
  useEffect(() => subscribeToToday(setToday), [])
  return today
}

export interface CalendarViewProps {
  courses: readonly Course[]
  /** undefined = all courses, null = global entries. */
  courseId: string | null | undefined
  onTasksChanged?: () => void | Promise<void>
  refreshKey?: number
}

interface CalendarDraft {
  title: string
  kind: TaskKind
  courseId: string | null
  dueAt: string
  startAt: string | null
  allDay: boolean
  dateKey: string
}

interface CalendarTaskFormProps {
  task: BoardTask | null
  dateKey: string
  defaultCourseId: string | null
  courses: readonly Course[]
  busy: boolean
  onCancel: () => void
  onSubmit: (draft: CalendarDraft) => Promise<void>
  onDelete?: () => Promise<void>
  onExport?: (draft: CalendarDraft) => Promise<void>
}

function messageFor(error: unknown): string {
  return error instanceof Error ? error.message : '일정을 불러오지 못했습니다.'
}

function monthTitle(cursor: Date): string {
  return new Intl.DateTimeFormat('ko-KR', {
    year: 'numeric',
    month: 'long'
  }).format(cursor)
}

function fullDateTitle(key: string): string {
  const [year = 0, month = 1, day = 1] = key.split('-').map(Number)
  return new Intl.DateTimeFormat('ko-KR', {
    month: 'long',
    day: 'numeric',
    weekday: 'short',
    ...(year !== new Date().getFullYear() ? { year: 'numeric' as const } : {})
  }).format(new Date(year, month - 1, day))
}

function timeLabel(task: BoardTask, dayKey?: string): string | null {
  if (task.allDay || task.dueAt === null) return null
  const end = new Date(task.dueAt)
  if (Number.isNaN(end.getTime())) return null
  const format = new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
  if (!task.startAt) return format.format(end)
  const start = new Date(task.startAt)
  if (localDateKey(start) === localDateKey(end)) return `${format.format(start)}–${format.format(end)}`
  if (dayKey) {
    if (dayKey === localDateKey(start)) return `${format.format(start)}부터`
    if (dayKey === localDateKey(end)) return `${format.format(end)}까지`
    return '진행 중'
  }
  return `${fullDateTitle(localDateKey(start))} ${format.format(start)} – ${fullDateTitle(localDateKey(end))} ${format.format(end)}`
}

function courseFor(task: BoardTask, courses: readonly Course[]): Course | null {
  return courses.find((course) => course.id === task.courseId) ?? null
}

function CalendarTaskForm({
  task,
  dateKey,
  defaultCourseId,
  courses,
  busy,
  onCancel,
  onSubmit,
  onDelete,
  onExport
}: CalendarTaskFormProps): JSX.Element {
  const [title, setTitle] = useState(task?.title ?? '')
  const [kind, setKind] = useState<TaskKind>(task?.kind ?? 'assignment')
  const [courseId, setCourseId] = useState(task?.courseId ?? defaultCourseId ?? '')
  const schedule = useTaskSchedule(task, dateKey)
  const [error, setError] = useState<string | null>(null)
  const currentCourseMissing =
    courseId.length > 0 && !courses.some((course) => course.id === courseId)

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault()
    if (busy) return
    if (title.trim().length === 0 || schedule.endDate.length === 0) {
      setError('제목과 날짜를 입력해주세요.')
      return
    }
    setError(null)
    try {
      const action = (event.nativeEvent as SubmitEvent).submitter?.getAttribute('data-action') === 'export' && onExport ? onExport : onSubmit
      const timing = schedule.value()
      if (!timing.dueAt) throw new Error('날짜를 입력해주세요.')
      await action({
        title: title.trim(),
        kind,
        courseId: courseId.length === 0 ? null : courseId,
        ...timing,
        dueAt: timing.dueAt,
        dateKey: schedule.hasRange ? schedule.startDate : schedule.endDate
      })
    } catch (submitError) {
      setError(messageFor(submitError))
    }
  }

  return (
    <form className="calendar-form" onSubmit={(event) => void submit(event)}>
      <label className="board-field">
        <span>제목</span>
        <input
          value={title}
          maxLength={200}
          disabled={busy}
          required
          autoFocus
          placeholder="과제나 시험 이름"
          onChange={(event) => setTitle(event.target.value)}
        />
      </label>
      <fieldset className="board-kind-picker calendar-kind-picker">
        <legend>종류</legend>
        <div>
          {Object.entries(KIND_LABELS).map(([value, label]) => (
            <label key={value}>
              <input
                type="radio"
                disabled={busy}
                name="calendar-task-kind"
                value={value}
                checked={kind === value}
                onChange={() => setKind(value as TaskKind)}
              />
              <span>{label}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <label className="board-field">
        <span>과목</span>
        <select disabled={busy} value={courseId} onChange={(event) => setCourseId(event.target.value)}>
          <option value="">전체</option>
          {currentCourseMissing && <option value={courseId}>목록에 없는 과목</option>}
          {courses.map((course) => (
            <option key={course.id} value={course.id}>{course.name}</option>
          ))}
        </select>
      </label>
      <TaskScheduleFields schedule={schedule} required disabled={busy} />
      {error !== null && <p className="calendar-form__error" role="alert">{error}</p>}
      <footer className="calendar-form__actions">
        {onDelete !== undefined && (
          <button
            type="button"
            className="board-button board-button--danger"
            disabled={busy}
            onClick={() => void onDelete().catch((deleteError) => setError(messageFor(deleteError)))}
          >
            <Icon name="trash" /> 삭제
          </button>
        )}
        <span className="calendar-form__action-spacer" />
        <button type="button" className="board-button" disabled={busy} onClick={onCancel}>취소</button>
        <button type="submit" className="board-button board-button--primary" disabled={busy}>
          {busy ? '저장 중…' : '저장'}
        </button>
      </footer>
      {onExport && <div className="calendar-export"><button type="submit" className="board-button" data-action="export" disabled={busy}>저장하고 Apple 캘린더로 보내기</button><small>설정한 날짜와 시간을 그대로 보냅니다. 다시 보내면 기존 일정이 갱신됩니다.</small></div>}
    </form>
  )
}

export function CalendarView({
  courses,
  courseId,
  onTasksChanged,
  refreshKey = 0
}: CalendarViewProps): JSX.Element {
  const [appleState, setAppleState] = useState<AppleCalendarState | null>(null)
  const [appleEvents, setAppleEvents] = useState<AppleCalendarEvent[]>([])
  const [appleError, setAppleError] = useState<string | null>(null)
  const [selectedAppleId, setSelectedAppleId] = useState<string | null>(null)
  const optionsRef = useRef<HTMLDetailsElement>(null)
  const refreshApple = useRef<() => Promise<void>>(async () => {})
  const openCalendarSettings = () => { if (optionsRef.current) optionsRef.current.open = false; useUiStore.getState().openSettings('calendar') }
  const today = useToday()
  const [cursor, setCursor] = useState(() => new Date(today.getFullYear(), today.getMonth(), 1))
  const [selectedKey, setSelectedKey] = useState(() => localDateKey(today))
  const [tasks, setTasks] = useState<BoardTask[]>([])
  const [editingId, setEditingId] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)
  const [loading, setLoading] = useState(true)
  const [mutating, setMutating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [recentTaskId, setRecentTaskId] = useState<string | null>(null)
  const [saveNotice, setSaveNotice] = useState<string | null>(null)
  const loadSequence = useRef(0)
  const gridRef = useRef<HTMLDivElement>(null)
  const grid = useMemo(() => calendarMonthGrid(cursor, today), [cursor, today])

  const selection = useRef(0)
  const mutationPending = useRef(false)
  const scope = `${courseId === undefined ? 'all' : courseId ?? 'global'}:${grid.from}:${grid.to}`
  const currentScope = useRef(scope)
  if (currentScope.current !== scope) { currentScope.current = scope; selection.current++ }
  useEffect(() => { setTasks([]); setAdding(false); setEditingId(null); setSelectedAppleId(null); setSaveNotice(null) }, [courseId])
  useEffect(() => { currentScope.current = scope; return () => { selection.current++; currentScope.current = '' } }, [])

  const load = useCallback(async (): Promise<void> => {
    const sequence = ++loadSequence.current
    setLoading(true)
    setError(null)
    try {
      const result = await invoke('calendar:range', {
        from: grid.from,
        to: grid.to,
        ...(courseId === undefined ? {} : { courseId })
      })
      if (sequence === loadSequence.current) setTasks(result)
    } catch (loadError) {
      if (sequence === loadSequence.current) setError(messageFor(loadError))
    } finally {
      if (sequence === loadSequence.current) setLoading(false)
    }
  }, [courseId, grid.from, grid.to])

  useEffect(() => {
    void load()
    const off = onPush('board:changed', () => { void load() })
    return () => { off(); loadSequence.current += 1 }
  }, [load, refreshKey])

  useEffect(() => {
    let active = true
    let sequence = 0
    const refresh = async () => {
      const current = ++sequence
      try {
        const state = await invoke('appleCalendar:state', {})
        const events = await invoke('appleCalendar:events', { from: grid.from, to: grid.to })
        if (active && current === sequence) { setAppleState(state); setAppleEvents(events); setAppleError(null) }
      } catch (e) { if (active && current === sequence) { setAppleEvents([]); setAppleError(messageFor(e)) } }
    }
    refreshApple.current = refresh
    const focus = () => { if (!document.hidden) void refresh() }
    void refresh()
    const off = onPush('appleCalendar:changed', () => { setAppleEvents([]); void refresh() })
    const timer = window.setInterval(focus, 60000)
    window.addEventListener('focus', focus)
    document.addEventListener('visibilitychange', focus)
    return () => { active = false; off(); clearInterval(timer); window.removeEventListener('focus', focus); document.removeEventListener('visibilitychange', focus) }
  }, [grid.from, grid.to, refreshKey])

  useEffect(() => {
    const close = (event: PointerEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent && event.key !== 'Escape') return
      if (event instanceof PointerEvent && optionsRef.current?.contains(event.target as Node)) return
      if (optionsRef.current?.open) { optionsRef.current.open = false; if (event instanceof KeyboardEvent) optionsRef.current.querySelector('summary')?.focus() }
    }
    document.addEventListener('pointerdown', close)
    document.addEventListener('keydown', close)
    return () => { document.removeEventListener('pointerdown', close); document.removeEventListener('keydown', close) }
  }, [])
  const externalByDay = useMemo(() => appleEventsByDay(appleEvents, grid.days, new Set(tasks.map(task => task.id))), [appleEvents, grid.days, tasks])
  const selectedApple = appleEvents.find(event => event.id === selectedAppleId) ?? null
  const chooseApple = (event: AppleCalendarEvent, day: string) => { selection.current++; setSelectedKey(day); setSelectedAppleId(event.id); setEditingId(null); setAdding(false) }

  useEffect(() => {
    if (recentTaskId === null) return
    const frame = window.requestAnimationFrame(() => {
      gridRef.current
        ?.querySelector<HTMLElement>(`[data-task-id="${recentTaskId}"]`)
        ?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    })
    const timer = window.setTimeout(() => setRecentTaskId(null), 2400)
    return () => {
      window.cancelAnimationFrame(frame)
      window.clearTimeout(timer)
    }
  }, [recentTaskId, tasks])

  const tasksByDay = useMemo(() => boardTasksByDay(tasks, grid.days), [tasks, grid.days])

  const selectDay = (key: string): void => {
    selection.current++
    setSelectedKey(key)
    setSelectedAppleId(null)
    setEditingId(null)
    setAdding(false)
    setSaveNotice(null)
  }

  const revealDate = (dateKey: string): void => {
    const date = localDateFromKey(dateKey)
    setCursor(new Date(date.getFullYear(), date.getMonth(), 1))
    setSelectedKey(dateKey)
  }

  const beginAdd = (dateKey: string): void => {
    selection.current++
    revealDate(dateKey)
    setSelectedAppleId(null)
    setEditingId(null)
    setAdding(true)
    setSaveNotice(null)
  }

  const createTask = async (draft: CalendarDraft): Promise<void> => {
    if (mutationPending.current) return
    const selected = selection.current, startedScope = currentScope.current
    mutationPending.current = true
    setMutating(true)
    try {
      const created = await invoke('board:createTask', {
        courseId: draft.courseId,
        title: draft.title,
        status: 'todo',
        kind: draft.kind,
        startAt: draft.startAt,
        dueAt: draft.dueAt,
        allDay: draft.allDay
      })
      if (currentScope.current === startedScope) {
        loadSequence.current++; setLoading(false)
        if (courseId === undefined || created.courseId === courseId) setTasks((current) => [...current.filter((task) => task.id !== created.id), created])
      }
      if (selection.current === selected && currentScope.current === startedScope) {
        revealDate(draft.dateKey)
        setRecentTaskId(created.id)
        setSaveNotice(`${fullDateTitle(draft.dateKey)}에 “${created.title}” 일정을 추가했어요.`)
        setAdding(false)
      }
      await onTasksChanged?.()
    } finally {
      mutationPending.current = false
      setMutating(false)
    }
  }

  const editingTask = tasks.find((task) => task.id === editingId) ?? null
  const updateTask = async (task: BoardTask, draft: CalendarDraft): Promise<void> => {
    if (mutationPending.current) return
    const selected = selection.current, startedScope = currentScope.current
    mutationPending.current = true
    setMutating(true)
    try {
      const updated = await invoke('board:updateTask', {
        id: task.id,
        title: draft.title,
        kind: draft.kind,
        startAt: draft.startAt,
        dueAt: draft.dueAt,
        allDay: draft.allDay,
        ...(draft.courseId === task.courseId ? {} : { courseId: draft.courseId })
      })
      if (currentScope.current === startedScope) {
        loadSequence.current++; setLoading(false)
        setTasks((current) => current.map((entry) => entry.id === updated.id ? updated : entry).filter(entry => courseId === undefined || entry.courseId === courseId))
      }
      if (selection.current === selected && currentScope.current === startedScope) {
        revealDate(draft.dateKey)
        setRecentTaskId(updated.id)
        setSaveNotice(`${fullDateTitle(draft.dateKey)}에서 변경한 일정을 확인하세요.`)
        setEditingId(null)
      }
      await onTasksChanged?.()
    } finally {
      mutationPending.current = false
      setMutating(false)
    }
  }

  const deleteTask = async (task: BoardTask): Promise<void> => {
    if (mutationPending.current) return
    const selected = selection.current, startedScope = currentScope.current
    if (!window.confirm(`“${task.title}” 일정을 삭제할까요?`)) return
    mutationPending.current = true
    setMutating(true)
    try {
      await invoke('board:deleteTask', { id: task.id })
      if (currentScope.current === startedScope) {
        loadSequence.current++; setLoading(false)
        setTasks((current) => current.filter((entry) => entry.id !== task.id))
      }
      if (selection.current === selected && currentScope.current === startedScope) {
        setEditingId(null)
        setSaveNotice('일정을 삭제했어요.')
      }
      await onTasksChanged?.()
    } finally {
      mutationPending.current = false
      setMutating(false)
    }
  }

  const selectedTasks = tasksByDay.get(selectedKey) ?? []
  const moveMonth = (offset: number): void => {
    selection.current++
    setCursor((current) => new Date(current.getFullYear(), current.getMonth() + offset, 1))
    setEditingId(null)
    setAdding(false)
  }
  const goToday = (): void => {
    const now = new Date()
    setCursor(new Date(now.getFullYear(), now.getMonth(), 1))
    selectDay(localDateKey(now))
  }

  return (
    <div className="calendar" aria-busy={loading || mutating}>
      <section className="calendar-month" aria-label={`${monthTitle(cursor)} 달력`}>
        <header className="calendar-month__nav">
          <div className="calendar-month__nav-buttons">
            <button type="button" className="board-icon-button" aria-label="이전 달" onClick={() => moveMonth(-1)}>
              <Icon name="chevronRight" />
            </button>
            <button type="button" className="board-button" onClick={goToday}>오늘</button>
            <button type="button" className="board-icon-button" aria-label="다음 달" onClick={() => moveMonth(1)}>
              <Icon name="chevronRight" />
            </button>
          </div>
          <h3>{monthTitle(cursor)}</h3>
          <span className="calendar-month__count">{tasks.length + new Set([...externalByDay.values()].flat().map(event => event.id)).size}개 일정</span>
          <details ref={optionsRef} className="calendar-options"><summary className="board-icon-button" aria-label="달력 더 보기">···</summary><div className="calendar-options__menu"><button type="button" onClick={openCalendarSettings}><Icon name="settings" /> 달력 설정 · Apple 캘린더</button><button type="button" onClick={() => { if (optionsRef.current) optionsRef.current.open = false; void load(); void refreshApple.current() }}><Icon name="refresh" /> 일정 새로고침</button></div></details>
        </header>
        {appleError && <div className="board-error" role="alert"><span>{appleError}</span><button type="button" onClick={openCalendarSettings}>연결 설정</button></div>}
        {error !== null && (
          <div className="board-error" role="alert">
            <span>{error}</span>
            <button type="button" aria-label="다시 시도" onClick={() => void load()}><Icon name="refresh" /></button>
          </div>
        )}
        {!loading && error === null && tasks.length === 0 && appleEvents.length === 0 && (
          <div className="calendar-empty-state">
            <strong>일정 없음</strong>
            <button
              type="button"
              className="board-button board-button--primary"
              onClick={() => beginAdd(selectedKey)}
            >
              <Icon name="plus" /> 첫 일정 추가
            </button>
          </div>
        )}
        <div className="calendar-weekdays" aria-hidden="true">
          {WEEKDAYS.map((weekday) => <span key={weekday}>{weekday}</span>)}
        </div>
        <div ref={gridRef} className="calendar-grid">
          {grid.days.map((day) => {
            const dayTasks = tasksByDay.get(day.key) ?? []
            const dayEvents = externalByDay.get(day.key) ?? []
            const containsRecentTask = dayTasks.some((task) => task.id === recentTaskId)
            return (
              <section
                key={day.key}
                className="calendar-day"
                data-date-key={day.key}
                data-outside={!day.inMonth || undefined}
                data-today={day.isToday || undefined}
                data-selected={selectedKey === day.key || undefined}
                data-recent={containsRecentTask || undefined}
              >
                <button
                  type="button"
                  className="calendar-day__number"
                  title={`${fullDateTitle(day.key)}에 일정 추가`}
                  onClick={() => beginAdd(day.key)}
                >
                  <time dateTime={day.key} aria-current={day.isToday ? 'date' : undefined}>{day.date.getDate()}</time>
                  <Icon name="plus" />
                  <span className="sr-only">{fullDateTitle(day.key)}에 일정 추가</span>
                </button>
                <div className="calendar-day__items">
                  {dayTasks.slice(0, 3).map((task) => {
                    const course = courseFor(task, courses)
                    return (
                      <button
                        key={task.id}
                        type="button"
                        className="calendar-entry"
                        data-task-id={task.id}
                        data-kind={task.kind}
                        data-overdue={taskIsOverdue(task) || undefined}
                        data-done={task.status === 'done' || undefined}
                        data-recent={recentTaskId === task.id || undefined}
                        data-course-color={course === null ? undefined : normalizeCourseColor(course.color)}
                        title={`${KIND_LABELS[task.kind]} · ${task.title}${task.startAt && task.dueAt ? ` · ${fullDateTitle(localDateKey(task.startAt))} – ${fullDateTitle(localDateKey(task.dueAt))}` : ''}`}
                        onClick={() => { selection.current++; setSelectedKey(day.key); setAdding(false); setSelectedAppleId(null); setEditingId(task.id) }}
                      >
                        <span className="board-course-dot" aria-hidden="true" />
                        <span className="calendar-entry__kind">{KIND_LABELS[task.kind]}</span>
                        <span className="calendar-entry__title">{task.title}</span>
                        {taskIsOverdue(task) && <span className="calendar-entry__overdue">지남</span>}
                        {timeLabel(task, day.key) !== null && <time>{timeLabel(task, day.key)}</time>}
                      </button>
                    )
                  })}
                  {dayEvents.slice(0, Math.max(0, 3 - dayTasks.length)).map(event => <button type="button" key={event.id} className="calendar-entry calendar-external" title={`${event.calendarTitle} · ${event.title}`} onClick={() => chooseApple(event, day.key)}><span className="apple-calendar-dot" style={{ backgroundColor: event.color }} /><span className="calendar-entry__title">{event.title}</span></button>)}
                  {dayTasks.length + dayEvents.length > 3 && (
                    <button type="button" className="calendar-day__more" onClick={() => selectDay(day.key)}>
                      {dayTasks.length + dayEvents.length - 3}개 더 보기
                    </button>
                  )}
                </div>
              </section>
            )
          })}
        </div>
      </section>

      <aside className="calendar-agenda" aria-label={`${fullDateTitle(selectedKey)} 일정`}>
        <header className="calendar-agenda__header">
          <div>
            <h3>{fullDateTitle(selectedKey)}</h3>
          </div>
          {!adding && editingTask === null && (
            <button type="button" className="board-button board-button--primary" onClick={() => beginAdd(selectedKey)}>
              <Icon name="plus" /> 일정 추가
            </button>
          )}
        </header>

        {saveNotice !== null && (
          <p className="calendar-agenda__notice" role="status">{saveNotice}</p>
        )}

        {adding ? (
          <CalendarTaskForm
            key={`new-${selectedKey}`}
            task={null}
            dateKey={selectedKey}
            defaultCourseId={courseId ?? null}
            courses={courses}
            busy={mutating}
            onCancel={() => { selection.current++; setAdding(false) }}
            onSubmit={createTask}
          />
        ) : selectedApple !== null ? (
          <article className="calendar-external__detail"><p>Apple 캘린더 · {selectedApple.calendarTitle}</p><h4>{selectedApple.title}</h4><p>{selectedApple.allDay ? '하루 종일' : new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(selectedApple.start))}{!selectedApple.allDay && ` – ${new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(selectedApple.end))}`}</p>{selectedApple.location && <p>{selectedApple.location}</p>}<p>이 일정은 Apple 캘린더 앱에서 수정할 수 있습니다.</p><button className="board-button" onClick={() => setSelectedAppleId(null)}>목록으로</button></article>
        ) : editingTask !== null ? (
          <CalendarTaskForm
            key={editingTask.id}
            task={editingTask}
            dateKey={selectedKey}
            defaultCourseId={courseId ?? null}
            courses={courses}
            busy={mutating}
            onCancel={() => { selection.current++; setEditingId(null) }}
            onSubmit={(draft) => updateTask(editingTask, draft)}
            onDelete={() => deleteTask(editingTask)}
            {...(appleState?.connected && appleState.authorization === 'authorized' && appleState.destinationCalendarId ? { onExport: async (draft: CalendarDraft) => {
              const selected = selection.current, startedScope = currentScope.current
              await updateTask(editingTask, draft)
              try {
                const result = await invoke('appleCalendar:export', { taskId: editingTask.id })
                if (selection.current === selected && currentScope.current === startedScope) setSaveNotice(result.updated ? 'Apple 캘린더의 기존 일정을 갱신했어요.' : 'Apple 캘린더로 일정을 보냈어요.')
              } catch (e) { if (selection.current === selected && currentScope.current === startedScope) setAppleError(messageFor(e)) }
            } } : {})}
          />
        ) : selectedTasks.length === 0 && (externalByDay.get(selectedKey)?.length ?? 0) === 0 ? (
          <div className="calendar-agenda__empty">
            <strong>일정 없음</strong>
            <button
              type="button"
              className="board-button board-button--primary"
              onClick={() => beginAdd(selectedKey)}
            >
              <Icon name="plus" /> 이 날짜에 추가
            </button>
          </div>
        ) : (
          <ul className="calendar-agenda__list">
            {selectedTasks.map((task) => {
              const course = courseFor(task, courses)
              return (
                <li key={task.id}>
                  <button
                    type="button"
                    className="calendar-agenda__item"
                    data-task-id={task.id}
                    data-kind={task.kind}
                    data-overdue={taskIsOverdue(task) || undefined}
                    data-recent={recentTaskId === task.id || undefined}
                    data-course-color={course === null ? undefined : normalizeCourseColor(course.color)}
                    onClick={() => { selection.current++; setSelectedAppleId(null); setEditingId(task.id) }}
                  >
                    <span className="board-course-dot" aria-hidden="true" />
                    <span>
                      <strong>{task.title}</strong>
                      <small>
                        {KIND_LABELS[task.kind]} · {course?.name ?? '전체'}
                        {timeLabel(task) === null ? '' : ` · ${timeLabel(task)}`}
                        {taskIsOverdue(task) ? ' · 마감 지남' : ''}
                      </small>
                    </span>
                    <Icon name="chevronRight" />
                  </button>
                </li>
              )
            })}
          </ul>
        )}
        {!adding && !editingTask && !selectedApple && (externalByDay.get(selectedKey)?.length ?? 0) > 0 && <div className="calendar-external__list"><p className="board-eyebrow">APPLE CALENDAR</p>{externalByDay.get(selectedKey)?.map(event => <button type="button" key={event.id} className="calendar-agenda__item" onClick={() => chooseApple(event, selectedKey)}><span className="apple-calendar-dot" style={{ backgroundColor: event.color }} /><span><strong>{event.title}</strong><small>{event.calendarTitle} · {event.allDay ? '하루 종일' : new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit' }).format(new Date(event.start))}</small></span></button>)}</div>}
      </aside>
    </div>
  )
}
