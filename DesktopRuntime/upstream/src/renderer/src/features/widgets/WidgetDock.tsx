import { ensureSettingsLoaded } from '../../stores/settingsSnapshot'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { TASK_COLORS } from '../../../../shared/types/board'
import type {
  BoardTask,
  TaskColor,
  TaskStatus,
  UpdateTaskInput
} from '../../../../shared/types/board'
import { DEFAULT_SETTINGS, type Settings, type WidgetId } from '../../../../shared/types/settings'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { invoke, onPush } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useUiStore } from '../../stores/uiStore'
import { useUniversityStore } from '../../stores/universityStore'
import { dueDayLabel } from '../board/boardLogic'
import { localDateKey } from '../calendar/calendarDate'
import { NativeMailWidget } from './MailWidget'
import './widgets.css'

const LABELS: Record<WidgetId, string> = {
  todo: '투두',
  board: '보드',
  mail: '메일'
}

const TASK_COLOR_LABELS: Record<TaskColor, string> = {
  none: '색상 없음',
  red: '빨강',
  orange: '주황',
  yellow: '노랑',
  green: '초록',
  blue: '파랑',
  violet: '보라'
}

function TaskColorPicker({
  value,
  onChange,
  label = '할 일 색상'
}: {
  value: TaskColor
  onChange: (color: TaskColor) => void
  label?: string
}): JSX.Element {
  return (
    <div className="widget-color-picker" role="group" aria-label={label}>
      {TASK_COLORS.map((color) => (
        <button
          key={color}
          type="button"
          className="widget-color-swatch"
          data-color={color}
          aria-label={TASK_COLOR_LABELS[color]}
          aria-pressed={value === color}
          title={TASK_COLOR_LABELS[color]}
          onClick={() => onChange(color)}
        >
          {color === 'none' && <span aria-hidden="true">×</span>}
        </button>
      ))}
    </div>
  )
}

function useLiveSettings(): { settings: Settings; error: boolean; loading: boolean; retry: () => void } {
  const [settings, setSettings] = useState(DEFAULT_SETTINGS)
  const [error, setError] = useState(false)
  const [loading, setLoading] = useState(true)
  const sequence = useRef(0)
  const load = useCallback(() => {
    const request = ++sequence.current
    setLoading(true)
    void ensureSettingsLoaded().then((next) => {
      if (request !== sequence.current) return
      setSettings(next)
      setError(false)
    }).catch((loadError: unknown) => {
      if (request !== sequence.current) return
      setError(true)
      console.error('[Bandal] 위젯 설정을 불러오지 못했습니다.', loadError)
    }).finally(() => {
      if (request === sequence.current) setLoading(false)
    })
  }, [])
  useEffect(() => {
    load()
    const stop = onPush('settings:changed', ({ settings: next }) => {
      sequence.current += 1
      setSettings(next)
      setError(false)
      setLoading(false)
    })
    return () => {
      sequence.current += 1
      stop()
    }
  }, [load])
  return { settings, error, loading, retry: load }
}

function useBoardTasks(): { tasks: BoardTask[]; loading: boolean; error: boolean; retry: () => void } {
  const [tasks, setTasks] = useState<BoardTask[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const loadSequence = useRef(0)
  const load = useCallback((showLoading = true) => {
    const sequence = ++loadSequence.current
    if (showLoading) setLoading(true)
    setError(false)
    void invoke('board:listTasks', { includeDone: true })
      .then((next) => {
        if (sequence === loadSequence.current) setTasks(next)
      })
      .catch((loadError: unknown) => {
        if (sequence === loadSequence.current) setError(true)
        console.error('[Bandal] 위젯 할 일을 불러오지 못했습니다.', loadError)
      })
      .finally(() => {
        if (sequence === loadSequence.current) setLoading(false)
      })
  }, [])
  useEffect(() => {
    load()
    const stop = onPush('board:changed', () => load(false))
    return () => {
      stop()
      loadSequence.current += 1
    }
  }, [load])
  return { tasks, loading, error, retry: load }
}

function byDue(left: BoardTask, right: BoardTask): number {
  if (left.dueAt === null && right.dueAt !== null) return 1
  if (left.dueAt !== null && right.dueAt === null) return -1
  return (left.dueAt ?? '').localeCompare(right.dueAt ?? '') || left.sortOrder - right.sortOrder
}

function taskDateLabel(task: BoardTask): string | null {
  if (task.dueAt === null) return null
  const dateKey = localDateKey(task.dueAt)
  const [year, month, day] = dateKey.split('-').map(Number)
  const date = new Date(year!, month! - 1, day!)
  if (Number.isNaN(date.getTime())) return null
  return new Intl.DateTimeFormat('ko-KR', {
    month: 'short',
    day: 'numeric'
  }).format(date)
}

function TaskScope({ currentOnly, currentAvailable, onChange }: { currentOnly: boolean; currentAvailable: boolean; onChange: (next: boolean) => void }): JSX.Element {
  return (
    <div className="widget-scope" role="group" aria-label="태스크 범위">
      <button type="button" aria-pressed={!currentOnly || !currentAvailable} onClick={() => onChange(false)}>전체</button>
      <button type="button" aria-pressed={currentOnly && currentAvailable} disabled={!currentAvailable} onClick={() => onChange(true)}>현재 과목</button>
    </div>
  )
}

function TaskWidget({ mode }: { mode: 'todo' | 'board' }): JSX.Element {
  const { tasks, loading, error, retry } = useBoardTasks()
  const courses = useCoursesStore((state) => state.courses)
  const selectedWorkspaceId = useCoursesStore((state) => state.selectedCourseId)
  const selectedCourseId = courses.find(course => course.id === selectedWorkspaceId && course.workspaceKind !== 'study-space')?.id ?? null
  const toggleBoard = useUiStore((state) => state.toggleBoardOverlay)
  const [currentOnly, setCurrentOnly] = useState(false)
  const [draft, setDraft] = useState('')
  const [draftDate, setDraftDate] = useState('')
  const [draftColor, setDraftColor] = useState<TaskColor>('none')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const pendingAdd = useRef(false)
  const draftVersion = useRef(0)
  const visible = useMemo(
    () => tasks.filter((task) => !currentOnly || !selectedCourseId || task.courseId === selectedCourseId),
    [currentOnly, selectedCourseId, tasks]
  )
  const courseNames = useMemo(() => new Map(courses.map((course) => [course.id, course.name])), [courses])

  const add = async (): Promise<void> => {
    const title = draft.trim()
    if (title === '' || pendingAdd.current) return
    pendingAdd.current = true
    const version = draftVersion.current
    setSaving(true)
    try {
      await invoke('board:createTask', {
        courseId: selectedCourseId,
        title,
        status: 'todo',
        color: draftColor,
        dueAt: draftDate === '' ? null : draftDate,
        allDay: draftDate !== ''
      })
      if (version === draftVersion.current) {
        setDraft('')
        setDraftDate('')
        setDraftColor('none')
      }
    } catch (createError) {
      console.error('[Bandal] 위젯 할 일을 추가하지 못했습니다.', createError)
      showToast('할 일을 추가하지 못했어요.', 'danger')
    } finally {
      pendingAdd.current = false
      setSaving(false)
    }
  }

  const updateTask = (input: UpdateTaskInput): void => {
    void invoke('board:updateTask', input).catch((updateError: unknown) => {
      console.error('[Bandal] 위젯 할 일을 수정하지 못했습니다.', updateError)
      showToast('할 일을 수정하지 못했어요.', 'danger')
    })
  }

  const updateStatus = (task: BoardTask, status: TaskStatus): void => {
    updateTask({ id: task.id, status })
  }

  const updateDate = (task: BoardTask, dueAt: string): void => {
    updateTask({
      id: task.id,
      dueAt: dueAt === '' ? null : dueAt,
      allDay: dueAt !== ''
    })
  }

  const updateColor = (task: BoardTask, color: TaskColor): void => {
    updateTask({ id: task.id, color })
  }

  const list = [...visible].sort(byDue)
  const pending = list.filter(task => task.status !== 'done')
  return (
    <div className="widget-task">
      <p className="widget-summary"><strong>{pending.length}</strong>개의 할 일{pending[0]?.dueAt ? ` · 가까운 일정 ${taskDateLabel(pending[0])}` : ''}</p>
      <div className="widget-toolbar">
        <TaskScope currentOnly={currentOnly} currentAvailable={selectedCourseId !== null} onChange={setCurrentOnly} />
        <button type="button" className="widget-open-board" onClick={toggleBoard}>전체 보드</button>
      </div>
      <form className="widget-quick-add" onSubmit={(event) => { event.preventDefault(); void add() }}>
        <div className="widget-quick-add__title">
          <input value={draft} onChange={(event) => { draftVersion.current++; setDraft(event.target.value) }} placeholder="할 일 추가" aria-label="할 일 추가" />
          <button type="submit" disabled={draft.trim() === '' || saving} aria-label="추가"><Icon name="plus" /></button>
        </div>
        <details className="widget-quick-options"><summary>날짜 · 색상</summary><div className="widget-quick-add__options">
          <label className="widget-date-field">
            <span>날짜</span>
            <input
              type="date"
              value={draftDate}
              aria-label="할 일 날짜"
              onChange={(event) => { draftVersion.current++; setDraftDate(event.target.value) }}
            />
          </label>
          <TaskColorPicker value={draftColor} onChange={color => { draftVersion.current++; setDraftColor(color) }} />
        </div></details>
      </form>
      {error && <p className="widget-empty" role="alert">할 일을 불러오지 못했어요. <button type="button" onClick={retry}>다시 불러오기</button></p>}
      {loading ? (
        <p className="widget-empty">불러오는 중…</p>
      ) : mode === 'todo' ? (
        <ul className="widget-todo-list">
          {pending.slice(0, 5).map((task) => (
            <li key={task.id} data-color={task.color} data-expanded={editingId === task.id || undefined}>
              <div className="widget-todo-row">
                <button type="button" className="widget-check" aria-label={`${task.title} 완료`} onClick={() => updateStatus(task, 'done')} />
                <button
                  type="button"
                  className="widget-task-copy"
                  aria-expanded={editingId === task.id}
                  onClick={() => setEditingId((current) => current === task.id ? null : task.id)}
                >
                  <strong>{task.title}</strong>
                  <small>
                    {task.courseId === null ? '전체' : (courseNames.get(task.courseId) ?? '알 수 없는 과목')}
                    {task.dueAt === null ? '' : ` · ${taskDateLabel(task) ?? ''} · ${dueDayLabel(task.dueAt) ?? ''}`}
                  </small>
                </button>
                <span className="widget-task-color" data-color={task.color} aria-hidden="true" />
              </div>
              {editingId === task.id && (
                <div className="widget-todo-editor" aria-label={`${task.title} 빠른 편집`}>
                  <label className="widget-date-field">
                    <span>날짜</span>
                    <input
                      type="date"
                      value={task.dueAt === null ? '' : localDateKey(task.dueAt)}
                      aria-label={`${task.title} 날짜`}
                      onChange={(event) => updateDate(task, event.target.value)}
                    />
                  </label>
                  <TaskColorPicker
                    value={task.color}
                    label={`${task.title} 색상`}
                    onChange={(color) => updateColor(task, color)}
                  />
                </div>
              )}
            </li>
          ))}
          {!error && list.every((task) => task.status === 'done') && <li className="widget-empty">남은 할 일이 없어요.</li>}
        </ul>
      ) : (
        <div className="widget-board-columns">
          {(['todo', 'in-progress', 'done'] as const).map((status) => (
            <section key={status}>
              <h4>{status === 'todo' ? '할 일' : status === 'in-progress' ? '진행 중' : '완료'} <span>{list.filter((task) => task.status === status).length}</span></h4>
              <button type="button" onClick={toggleBoard}>보드에서 보기 ↗</button>
            </section>
          ))}
        </div>
      )}
    </div>
  )
}

function MailWidget({ settings, active }: { settings: Settings; active: boolean }): JSX.Element {
  const services = useUniversityStore((state) => state.services)
  const init = useUniversityStore((state) => state.init)
  useEffect(() => void init(), [init])
  const mails = services.filter((service) => service.kind === 'mail')
  const selected = mails.find((service) => service.id === settings.widgets.mailServiceId) ?? mails[0] ?? null
  const target = selected === null
    ? (settings.widgets.mailUrl === '' ? null : {
        label: '웹메일',
        url: settings.widgets.mailUrl
      })
    : {
        label: selected.label,
        url: selected.url
      }

  return <NativeMailWidget fallback={target} active={active} />
}


export function WidgetDock(): JSX.Element | null {
  const { settings, error: settingsError, loading: settingsLoading, retry: retrySettings } = useLiveSettings()
  const widgets = settings.widgets
  const rightRailOpen = useUiStore(state => state.rightRailOpen)
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const dockRef = useRef<HTMLElement>(null)
  const [heightRatio, setHeightRatio] = useState(widgets.heightRatio)
  const heightRatioRef = useRef(heightRatio)
  const confirmedRatio = useRef(widgets.heightRatio)
  const heightSaveSequence = useRef(0)
  const heightSavePending = useRef(false)
  const resizeCleanup = useRef<(() => void) | null>(null)
  const alive = useRef(true)
  const collapsePending = useRef(false)
  const [savingCollapse, setSavingCollapse] = useState(false)

  const previewRatio = useCallback((ratio: number): void => {
    heightRatioRef.current = ratio
    setHeightRatio(ratio)
  }, [])

  useEffect(() => {
    confirmedRatio.current = widgets.heightRatio
    if (resizeCleanup.current === null && !heightSavePending.current) previewRatio(widgets.heightRatio)
  }, [previewRatio, widgets.heightRatio])

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
      resizeCleanup.current?.()
    }
  }, [])

  useEffect(() => {
    if (widgets.enabled.length === 0 || !rightRailOpen || settingsOpen) resizeCleanup.current?.()
  }, [widgets.enabled.length, rightRailOpen, settingsOpen])

  const saveRatio = async (ratio: number): Promise<void> => {
    const sequence = ++heightSaveSequence.current
    heightSavePending.current = true
    previewRatio(ratio)
    try {
      const next = await invoke('settings:set', { widgets: { heightRatio: ratio } })
      if (!alive.current || sequence !== heightSaveSequence.current) return
      confirmedRatio.current = next.widgets.heightRatio
      if (resizeCleanup.current === null) previewRatio(next.widgets.heightRatio)
    } catch (error) {
      if (!alive.current || sequence !== heightSaveSequence.current) return
      if (resizeCleanup.current === null) previewRatio(confirmedRatio.current)
      console.error('[Bandal] 위젯 크기를 저장하지 못했습니다.', error)
      showToast('위젯 크기를 저장하지 못했어요. 다시 조절해 주세요.', 'danger')
    } finally {
      if (sequence === heightSaveSequence.current) heightSavePending.current = false
    }
  }

  const beginResize = (event: React.PointerEvent<HTMLDivElement>): void => {
    if (event.button !== 0 || event.isPrimary === false) return
    const rail = dockRef.current?.parentElement
    if (rail === undefined || rail === null) return
    const rect = rail.getBoundingClientRect()
    if (rect.height <= 0) return
    resizeCleanup.current?.()
    const handle = event.currentTarget
    const pointerId = event.pointerId
    handle.setPointerCapture(pointerId)
    event.preventDefault()
    const ratioAt = (clientY: number): number => Math.min(0.65, Math.max(0.25, (rect.bottom - clientY) / rect.height))
    const cleanup = (): void => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', end)
      window.removeEventListener('pointercancel', cancelPointer)
      window.removeEventListener('keydown', escape)
      window.removeEventListener('blur', cancel)
      handle.removeEventListener('lostpointercapture', cancel)
      resizeCleanup.current = null
      if (handle.hasPointerCapture(pointerId)) handle.releasePointerCapture(pointerId)
    }
    const cancel = (): void => {
      cleanup()
      if (alive.current) previewRatio(confirmedRatio.current)
    }
    const cancelPointer = (cancelEvent: PointerEvent): void => {
      if (cancelEvent.pointerId === pointerId) cancel()
    }
    const escape = (keyEvent: KeyboardEvent): void => {
      if (keyEvent.key !== 'Escape') return
      keyEvent.preventDefault()
      cancel()
    }
    const move = (moveEvent: PointerEvent): void => {
      if (moveEvent.pointerId === pointerId) previewRatio(ratioAt(moveEvent.clientY))
    }
    const end = (upEvent: PointerEvent): void => {
      if (upEvent.pointerId !== pointerId) return
      cleanup()
      void saveRatio(ratioAt(upEvent.clientY))
    }
    resizeCleanup.current = cancel
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', end)
    window.addEventListener('pointercancel', cancelPointer)
    window.addEventListener('keydown', escape)
    window.addEventListener('blur', cancel)
    handle.addEventListener('lostpointercapture', cancel)
  }

  const resizeByKeyboard = (event: React.KeyboardEvent<HTMLDivElement>): void => {
    let ratio: number
    switch (event.key) {
      case 'ArrowUp': ratio = heightRatioRef.current + 0.02; break
      case 'ArrowDown': ratio = heightRatioRef.current - 0.02; break
      case 'Home': ratio = 0.25; break
      case 'End': ratio = 0.65; break
      default: return
    }
    event.preventDefault()
    resizeCleanup.current?.()
    void saveRatio(Math.min(0.65, Math.max(0.25, Math.round(ratio * 100) / 100)))
  }

  const toggleCollapsed = async (id: WidgetId): Promise<void> => {
    if (collapsePending.current) return
    collapsePending.current = true
    setSavingCollapse(true)
    const next = new Set(widgets.collapsed ?? [])
    if (next.has(id)) next.delete(id); else next.add(id)
    try {
      await invoke('settings:set', { widgets: { collapsed: [...next] } })
    } catch (error) {
      if (alive.current) {
        console.error('[Bandal] 위젯 상태를 저장하지 못했습니다.', error)
        showToast('위젯 상태를 저장하지 못했어요. 다시 시도해 주세요.', 'danger')
      }
    } finally {
      collapsePending.current = false
      if (alive.current) setSavingCollapse(false)
    }
  }

  if (settingsError) return (
    <section className="widget-dock" aria-label="위젯">
      <p className="widget-empty" role="alert">위젯 설정을 불러오지 못했어요. <button type="button" disabled={settingsLoading} onClick={retrySettings}>{settingsLoading ? '불러오는 중…' : '다시 불러오기'}</button></p>
    </section>
  )
  if (widgets.enabled.length === 0) return null

  return (
    <>
      <div className="widget-divider" role="separator" aria-orientation="horizontal"
        tabIndex={0} aria-label="위젯 높이 조절" aria-valuemin={25} aria-valuemax={65}
        aria-valuenow={Math.round(heightRatio * 100)} aria-valuetext={`${Math.round(heightRatio * 100)}%`}
        style={{ touchAction: 'none' }} onPointerDown={beginResize} onKeyDown={resizeByKeyboard} />
      <section ref={dockRef} className="widget-dock" style={{ maxHeight: `${heightRatio * 100}%` }} aria-label="위젯">
        {widgets.enabled.map(id => {
          const collapsed = widgets.collapsed?.includes(id) ?? false
          return <section className="widget-card" key={id} data-widget={id}>
            <header className="widget-card__header"><button type="button" aria-label={`${LABELS[id]} 위젯 ${collapsed ? '펼치기' : '접기'}`} aria-expanded={!collapsed} disabled={savingCollapse} onClick={() => { void toggleCollapsed(id) }}><span className="widget-card__icon" aria-hidden="true">{id === 'todo' ? '✓' : id === 'board' ? '▦' : '✉'}</span><strong>{LABELS[id]}</strong><span className="widget-card__chevron">{collapsed ? '⌄' : '⌃'}</span></button></header>
            <div className="widget-card__body" data-collapsed={collapsed} aria-hidden={collapsed} {...{ inert: collapsed ? '' : undefined }}><div className="widget-card__content">{id === 'mail' ? <MailWidget settings={settings} active={!collapsed && rightRailOpen && !settingsOpen} /> : <TaskWidget mode={id} />}</div></div>
          </section>
        })}
      </section>
    </>
  )
}
