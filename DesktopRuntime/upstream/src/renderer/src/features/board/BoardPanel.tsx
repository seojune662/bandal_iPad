import { useViewportBounds } from '../../lib/useViewportBounds'
import { createPortal } from 'react-dom'
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
  type KeyboardEvent
} from 'react'
import type { IDockviewPanelProps } from 'dockview'
import type { IpcRequest } from '../../../../shared/ipc/contract'
import type { BoardTask, TaskStatus } from '../../../../shared/types/board'
import type { Course } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { settingsSnapshot } from '../../stores/settingsSnapshot'
import { useFocusTrap } from '../../components/useFocusTrap'
import { invoke, onPush } from '../../lib/ipc'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { useCoursesStore } from '../../stores/coursesStore'
import { normalizeCourseColor } from '../courses/courseColors'
import { CalendarView } from '../calendar/CalendarView'
import {
  BOARD_STATUSES,
  dueDayLabel,
  dueState,
  filterTasks,
  planTaskMove,
  sortTasks
} from './boardLogic'
import { TaskEditorPopover, type TaskEditorDraft } from './TaskEditorPopover'
import { BoardQuickAdd, type BoardQuickAddDraft } from './BoardQuickAdd'
import { dueAtForLocalInput, localDateValue, localDayIso } from '../calendar/calendarDate'
import './board.css'
import './boardPopovers.css'
const STATUS_LABELS: Record<TaskStatus, string> = {
  todo: '할 일',
  'in-progress': '진행 중',
  done: '완료'
}

const STATUS_EMPTY_LABELS: Record<TaskStatus, string> = {
  todo: '할 일을 추가해보세요',
  'in-progress': '진행 중인 태스크가 없어요',
  done: '완료한 태스크가 없어요'
}

interface DropTarget {
  status: TaskStatus
  beforeTaskId: string | null
}

interface ContextMenuState {
  taskId: string
  x: number
  y: number
  placement: 'top' | 'bottom'
}

interface EditorState {
  taskId: string
  style: CSSProperties
}

export interface BoardOverlayProps {
  onClose: () => void
}

type ReorderUpdate = IpcRequest<'board:reorderTasks'>['updates'][number]

export function reorderCourseTasks(
  courseId: string,
  updates: ReorderUpdate[]
): Promise<BoardTask[]> {
  return invoke('board:reorderTasks', { courseId, updates })
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '요청을 처리하지 못했습니다.'
}

function formatDueDate(dueAt: string): string {
  const date = localDateValue(dueAt)
  const now = new Date()
  const includeYear = date.getFullYear() !== now.getFullYear()
  return new Intl.DateTimeFormat('ko-KR', {
    ...(includeYear ? { year: 'numeric' as const } : {}),
    month: 'short',
    day: 'numeric'
  }).format(date)
}

function courseForTask(task: BoardTask, courses: readonly Course[]): Course | null {
  if (task.courseId === null) return null
  return courses.find((course) => course.id === task.courseId) ?? null
}

function editorPosition(rect: DOMRect): CSSProperties {
  const width = 384
  const gutter = 16
  const left = Math.max(gutter, Math.min(rect.left, window.innerWidth - width - gutter))
  if (rect.top > window.innerHeight / 2) {
    return { left, bottom: Math.max(gutter, window.innerHeight - rect.top + 8) }
  }
  return { left, top: rect.bottom + 8 }
}

interface TaskCardProps {
  task: BoardTask
  course: Course | null
  now: number
  dragging: boolean
  recentlyCreated: boolean
  disabled: boolean
  onOpen: (rect: DOMRect) => void
  onContextMenu: (x: number, y: number) => void
  onDragStart: (event: DragEvent<HTMLElement>) => void
  onDragEnd: () => void
}

function TaskCard({
  task,
  course,
  now,
  dragging,
  recentlyCreated,
  disabled,
  onOpen,
  onContextMenu,
  onDragStart,
  onDragEnd
}: TaskCardProps): JSX.Element {
  const localDayDueAt = localDayIso(task.dueAt)
  const deadlineState = dueState(task.allDay ? localDayDueAt : task.dueAt, now, task.allDay)
  const deadlineLabel = dueDayLabel(localDayDueAt, now)
  const open = (element: HTMLElement): void => {
    if (!dragging) onOpen(element.getBoundingClientRect())
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLElement>): void => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      open(event.currentTarget)
    }
    if (event.key === 'F10' && event.shiftKey) {
      event.preventDefault()
      const rect = event.currentTarget.getBoundingClientRect()
      onContextMenu(rect.left + rect.width / 2, rect.top + rect.height / 2)
    }
  }

  return (
    <article
      className="board-card"
      data-status={task.status}
      data-color={task.color}
      data-task-id={task.id}
      data-due-state={task.status === 'done' ? undefined : deadlineState}
      data-dragging={dragging}
      data-recent={recentlyCreated || undefined}
      tabIndex={0}
      role="button"
      aria-label={`${task.title} 상세 편집`}
      draggable={!disabled}
      onClick={(event) => open(event.currentTarget)}
      onKeyDown={handleKeyDown}
      onContextMenu={(event) => {
        event.preventDefault()
        onContextMenu(event.clientX, event.clientY)
      }}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
    >
      <span className="board-card__grip" aria-hidden="true">
        <span />
        <span />
        <span />
      </span>
      <h4 className="board-card__title">{task.title}</h4>
      <div className="board-card__meta">
        <span
          className="board-course-tag"
          data-course-color={
            course === null ? undefined : normalizeCourseColor(course.color)
          }
          title={course?.name ?? (task.courseId === null ? '전체 태스크' : '목록에 없는 과목')}
        >
          <span className="board-course-dot" aria-hidden="true" />
          <span>{course?.name ?? (task.courseId === null ? '전체' : '알 수 없음')}</span>
        </span>
        {task.dueAt !== null && (
          <span
            className="board-due"
            data-due-state={task.status === 'done' ? 'later' : deadlineState}
          >
            {deadlineLabel !== null && <strong>{deadlineLabel}</strong>}
            <span>{task.startAt && `${formatDueDate(task.startAt)} – `}{formatDueDate(task.dueAt)}</span>
            <span className="sr-only">
              {task.status !== 'done' && deadlineState === 'overdue'
                ? '마감 지남'
                : task.status !== 'done' && deadlineState === 'upcoming'
                  ? '24시간 이내 마감'
                  : ''}
            </span>
          </span>
        )}
      </div>
    </article>
  )
}

function BoardSurface(): JSX.Element {
  const allCourses = useCoursesStore((state) => state.courses)
  const courses = useMemo(() => allCourses.filter(course => course.workspaceKind !== 'study-space'), [allCourses])
  const [view, setView] = useState<'board' | 'calendar'>(() => settingsSnapshot().tabs.boardDefaultView)
  const [calendarRefreshKey, setCalendarRefreshKey] = useState(0)
  const [tasks, setTasks] = useState<BoardTask[]>([])
  const [courseFilter, setCourseFilter] = useState<string | null | undefined>(undefined)
  const [hideDone, setHideDone] = useState(() => settingsSnapshot().tabs.boardHideDone)
  const [isLoading, setIsLoading] = useState(true)
  const [isMutating, setIsMutating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [creatingStatus, setCreatingStatus] = useState<TaskStatus | null>(null)
  const [draggedTaskId, setDraggedTaskId] = useState<string | null>(null)
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null)
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null)
  const [editor, setEditor] = useState<EditorState | null>(null)
  const [recentTaskId, setRecentTaskId] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const boardRef = useRef<HTMLElement>(null)
  const loadSequence = useRef(0)
  const contextMenuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(contextMenuRef)
  useFocusTrap(contextMenuRef, { active: contextMenu !== null, onEscape: () => setContextMenu(null) })

  const loadTasks = useCallback(async (showLoading = true): Promise<void> => {
    const sequence = ++loadSequence.current
    if (showLoading) setIsLoading(true)
    setError(null)
    try {
      const listed = await invoke('board:listTasks', { includeDone: true })
      if (sequence === loadSequence.current) setTasks(listed)
    } catch (loadError) {
      if (sequence === loadSequence.current) setError(errorMessage(loadError))
    } finally {
      if (sequence === loadSequence.current) setIsLoading(false)
    }
  }, [])

  useEffect(() => {
    void loadTasks()
    const stop = onPush('board:changed', () => void loadTasks(false))
    return () => {
      stop()
      loadSequence.current += 1
    }
  }, [loadTasks])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 60_000)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    if (recentTaskId === null) return
    const frame = window.requestAnimationFrame(() => {
      boardRef.current
        ?.querySelector<HTMLElement>(`[data-task-id="${recentTaskId}"]`)
        ?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    })
    const timer = window.setTimeout(() => setRecentTaskId(null), 2400)
    return () => {
      window.cancelAnimationFrame(frame)
      window.clearTimeout(timer)
    }
  }, [recentTaskId])

  useEffect(() => {
    if (contextMenu === null) return
    const frame = window.requestAnimationFrame(() => {
      contextMenuRef.current?.querySelector<HTMLButtonElement>('button')?.focus()
    })
    const closeOnPointerDown = (event: PointerEvent): void => {
      if (!contextMenuRef.current?.contains(event.target as Node)) setContextMenu(null)
    }
    const closeOnEscape = (event: globalThis.KeyboardEvent): void => {
      if (event.key === 'Escape') setContextMenu(null)
    }
    window.addEventListener('pointerdown', closeOnPointerDown)
    window.addEventListener('keydown', closeOnEscape)
    return () => {
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', closeOnPointerDown)
      window.removeEventListener('keydown', closeOnEscape)
    }
  }, [contextMenu])

  const visibleTasks = useMemo(
    () => filterTasks(tasks, { courseId: courseFilter, hideDone }),
    [courseFilter, hideDone, tasks]
  )
  const statuses = hideDone ? BOARD_STATUSES.slice(0, 2) : BOARD_STATUSES

  const tasksByStatus = useMemo(() => {
    const grouped: Record<TaskStatus, BoardTask[]> = {
      todo: [],
      'in-progress': [],
      done: []
    }
    visibleTasks.forEach((task) => grouped[task.status].push(task))
    BOARD_STATUSES.forEach((status) => {
      grouped[status] = sortTasks(grouped[status])
    })
    return grouped
  }, [visibleTasks])

  const createTask = async (status: TaskStatus, draft: BoardQuickAddDraft): Promise<void> => {
    setIsMutating(true)
    setError(null)
    try {
      const created = await invoke('board:createTask', {
        courseId: courseFilter === undefined ? null : courseFilter,
        title: draft.title,
        status,
        kind: draft.kind,
        color: draft.color,
        dueAt: draft.dueDate.length === 0
          ? null
          : dueAtForLocalInput(draft.dueDate, '', true),
        allDay: draft.dueDate.length > 0
      })
      setTasks((current) => [...current.filter(task => task.id !== created.id), created])
      setRecentTaskId(created.id)
      setCreatingStatus(null)
    } catch (createError) {
      setError(errorMessage(createError))
      throw createError
    } finally {
      setIsMutating(false)
    }
  }

  const moveTask = async (
    taskId: string,
    targetStatus: TaskStatus,
    beforeTaskId: string | null
  ): Promise<void> => {
    if (isMutating) return
    const plan = planTaskMove(tasks, taskId, targetStatus, beforeTaskId)
    const draggedCourseId = tasks.find((task) => task.id === taskId)?.courseId
    setDraggedTaskId(null)
    setDropTarget(null)
    setContextMenu(null)
    if (plan.updates.length === 0) return

    setIsMutating(true)
    setError(null)
    setTasks(plan.tasks)
    try {
      let changed: BoardTask[]
      if (draggedCourseId === null || draggedCourseId === undefined) {
        changed = []
        for (const update of plan.updates) {
          changed.push(await invoke('board:updateTask', update))
        }
      } else {
        // planTaskMove always supplies sortOrder for every changed row.
        changed = await reorderCourseTasks(
          draggedCourseId,
          plan.updates as ReorderUpdate[]
        )
      }
      const persisted = new Map(changed.map((task) => [task.id, task]))
      setTasks((current) =>
        current.map((task) => persisted.get(task.id) ?? task)
      )
    } catch (moveError) {
      setError(errorMessage(moveError))
      await loadTasks(false)
    } finally {
      setIsMutating(false)
    }
  }

  const deleteTask = async (task: BoardTask): Promise<void> => {
    if (!window.confirm(`“${task.title}” 태스크를 삭제할까요?`)) return
    setIsMutating(true)
    setError(null)
    try {
      await invoke('board:deleteTask', { id: task.id })
      setTasks((current) => current.filter((entry) => entry.id !== task.id))
      setContextMenu(null)
      setEditor(null)
    } catch (deleteError) {
      setError(errorMessage(deleteError))
      throw deleteError
    } finally {
      setIsMutating(false)
    }
  }

  const saveTask = async (task: BoardTask, draft: TaskEditorDraft): Promise<void> => {
    setIsMutating(true)
    setError(null)
    try {
      const updated = await invoke('board:updateTask', {
        id: task.id,
        title: draft.title,
        notes: draft.notes,
        kind: draft.kind,
        color: draft.color,
        startAt: draft.startAt,
        dueAt: draft.dueAt,
        allDay: draft.allDay,
        // Only send courseId on an actual move — same-course saves keep the
        // task's position untouched.
        ...(draft.courseId === task.courseId ? {} : { courseId: draft.courseId })
      })
      setTasks((current) =>
        current.map((entry) => (entry.id === updated.id ? updated : entry))
      )
    } catch (saveError) {
      setError(errorMessage(saveError))
      throw saveError
    } finally {
      setIsMutating(false)
    }
  }

  const openContextMenu = (x: number, y: number, taskId: string): void => {
    setEditor(null)
    setContextMenu({
      taskId,
      x,
      y,
      placement: y > window.innerHeight / 2 ? 'top' : 'bottom'
    })
  }

  const contextTask =
    contextMenu === null
      ? null
      : tasks.find((task) => task.id === contextMenu.taskId) ?? null
  const editingTask =
    editor === null ? null : tasks.find((task) => task.id === editor.taskId) ?? null

  return (
    <section
      ref={boardRef}
      className="board"
      aria-label="학업 보드"
      aria-busy={isLoading || isMutating}
    >
      <header className="board-toolbar">
        <div className="board-toolbar__title">
          <h2>{view === 'board' ? '과제와 시험' : '달력과 마감'}</h2>
        </div>
        <div className="board-view-switch" role="group" aria-label="학업 보드 화면">
          <button
            type="button"
            aria-pressed={view === 'calendar'}
            onClick={() => setView('calendar')}
          >
            달력
          </button>
          <button
            type="button"
            aria-pressed={view === 'board'}
            onClick={() => setView('board')}
          >
            목록
          </button>
        </div>
        <div className="board-toolbar__filters" aria-label="과목 필터">
          <button
            type="button"
            className="board-filter-chip"
            aria-pressed={courseFilter === undefined}
            onClick={() => setCourseFilter(undefined)}
          >
            모든 과목
          </button>
          <button
            type="button"
            className="board-filter-chip"
            aria-pressed={courseFilter === null}
            onClick={() => setCourseFilter(null)}
          >
            <span className="board-course-dot" aria-hidden="true" />
            전체
          </button>
          {courses.map((course) => (
            <button
              key={course.id}
              type="button"
              className="board-filter-chip"
              data-course-color={normalizeCourseColor(course.color)}
              aria-pressed={courseFilter === course.id}
              onClick={() => setCourseFilter(course.id)}
            >
              <span className="board-course-dot" aria-hidden="true" />
              {course.name}
            </button>
          ))}
        </div>
        <div className="board-toolbar__actions">
          {view === 'board' && <label className="board-toggle">
            <input
              type="checkbox"
              checked={hideDone}
              onChange={(event) => setHideDone(event.target.checked)}
            />
            <span aria-hidden="true" />
            완료 숨기기
          </label>}
          <button
            type="button"
            className="board-icon-button"
            aria-label={`${view === 'board' ? '태스크' : '달력'} 새로고침`}
            title="새로고침"
            disabled={isLoading || isMutating}
            onClick={() => view === 'board' ? void loadTasks() : setCalendarRefreshKey((key) => key + 1)}
          >
            <Icon name="refresh" />
          </button>
        </div>
      </header>

      {error !== null && (
        <div className="board-error" role="alert">
          <span>{error}</span>
          <button type="button" onClick={() => setError(null)} aria-label="오류 닫기">
            <Icon name="x" />
          </button>
        </div>
      )}

      {view === 'calendar' && (
        <CalendarView
          courses={courses}
          courseId={courseFilter}
          refreshKey={calendarRefreshKey}
          onTasksChanged={() => loadTasks(false)}
        />
      )}

      {view === 'board' && tasks.length === 0 && !isLoading && (
        <div className="board-zero-state">
          <span className="board-zero-state__mark" aria-hidden="true" />
          <button
            type="button"
            className="board-button board-button--primary"
            onClick={() => setCreatingStatus('todo')}
          >
            <Icon name="plus" /> 첫 일정 추가
          </button>
        </div>
      )}

      {view === 'board' && <div className="board-columns" data-column-count={statuses.length}>
        {statuses.map((status) => {
          const columnTasks = tasksByStatus[status]
          const targetInColumn = dropTarget?.status === status
          return (
            <section
              key={status}
              className="board-column"
              data-status={status}
              data-drag-over={targetInColumn}
              onDragOver={(event) => {
                event.preventDefault()
                event.dataTransfer.dropEffect = 'move'
                setDropTarget({ status, beforeTaskId: null })
              }}
              onDrop={(event) => {
                event.preventDefault()
                const taskId = draggedTaskId ?? event.dataTransfer.getData('text/plain')
                if (taskId.length > 0) void moveTask(taskId, status, null)
              }}
            >
              <header className="board-column__header">
                <div className="board-column__heading">
                  <span className="board-column__status" aria-hidden="true" />
                  <h3>{STATUS_LABELS[status]}</h3>
                  <span className="board-column__count" aria-label={`${columnTasks.length}개`}>
                    {columnTasks.length}
                  </span>
                </div>
              </header>

              {isLoading && tasks.length === 0 ? (
                <div className="board-column__loading" aria-label="태스크 불러오는 중">
                  <span />
                  <span />
                </div>
              ) : (
                <div className="board-column__cards">
                  {columnTasks.length === 0 && (
                    <div className="board-column__empty">
                      <span aria-hidden="true" />
                      <p>{STATUS_EMPTY_LABELS[status]}</p>
                    </div>
                  )}
                  {columnTasks.map((task, index) => {
                    const nextTask = columnTasks[index + 1]
                    const beforeTaskId = task.id
                    const afterTaskId = nextTask?.id ?? null
                    return (
                      <div
                        key={task.id}
                        className="board-card-slot"
                        data-drop-before={
                          targetInColumn && dropTarget?.beforeTaskId === beforeTaskId
                        }
                        onDragOver={(event) => {
                          event.preventDefault()
                          event.stopPropagation()
                          const rect = event.currentTarget.getBoundingClientRect()
                          const before = event.clientY < rect.top + rect.height / 2
                          setDropTarget({
                            status,
                            beforeTaskId: before ? beforeTaskId : afterTaskId
                          })
                        }}
                        onDrop={(event) => {
                          event.preventDefault()
                          event.stopPropagation()
                          const taskId =
                            draggedTaskId ?? event.dataTransfer.getData('text/plain')
                          if (taskId.length > 0) {
                            void moveTask(
                              taskId,
                              status,
                              dropTarget?.status === status
                                ? dropTarget.beforeTaskId
                                : beforeTaskId
                            )
                          }
                        }}
                      >
                        <TaskCard
                          task={task}
                          course={courseForTask(task, courses)}
                          now={now}
                          dragging={draggedTaskId === task.id}
                          recentlyCreated={recentTaskId === task.id}
                          disabled={isMutating}
                          onOpen={(rect) => {
                            setContextMenu(null)
                            setEditor({ taskId: task.id, style: editorPosition(rect) })
                          }}
                          onContextMenu={(x, y) => openContextMenu(x, y, task.id)}
                          onDragStart={(event) => {
                            event.dataTransfer.effectAllowed = 'move'
                            event.dataTransfer.setData('text/plain', task.id)
                            event.dataTransfer.setDragImage(event.currentTarget, 24, 18)
                            setEditor(null)
                            setContextMenu(null)
                            setDraggedTaskId(task.id)
                            setDropTarget({ status: task.status, beforeTaskId: task.id })
                          }}
                          onDragEnd={() => {
                            setDraggedTaskId(null)
                            setDropTarget(null)
                          }}
                        />
                      </div>
                    )
                  })}
                  <div
                    className="board-column__drop-end"
                    data-active={targetInColumn && dropTarget?.beforeTaskId === null}
                    aria-hidden="true"
                  />
                </div>
              )}
              <BoardQuickAdd
                status={status}
                active={creatingStatus === status}
                disabled={isMutating}
                onOpen={() => setCreatingStatus(status)}
                onCancel={() => setCreatingStatus(null)}
                onCreate={(draft) => createTask(status, draft)}
              />
            </section>
          )
        })}
      </div>}

      {view === 'board' && contextMenu !== null && contextTask !== null && createPortal(
        <div
          ref={contextMenuRef}
          className="board-context-menu"
          role="menu"
          data-placement={contextMenu.placement}
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <p>{contextTask.title}</p>
          <span className="board-context-menu__label">다른 컬럼으로 이동</span>
          {BOARD_STATUSES.filter((status) => status !== contextTask.status).map(
            (status) => (
              <button
                key={status}
                type="button"
                role="menuitem"
                data-status={status}
                disabled={isMutating}
                onClick={() => void moveTask(contextTask.id, status, null)}
              >
                <span className="board-column__status" aria-hidden="true" />
                {STATUS_LABELS[status]}
              </button>
            )
          )}
          <span className="board-context-menu__separator" />
          <button
            type="button"
            role="menuitem"
            className="board-context-menu__danger"
            disabled={isMutating}
            onClick={() => void deleteTask(contextTask).catch(() => undefined)}
          >
            <Icon name="trash" /> 삭제
          </button>
        </div>, document.body
      )}

      {view === 'board' && editor !== null && editingTask !== null && (
        <TaskEditorPopover
          key={editingTask.id}
          task={editingTask}
          courses={courses}
          anchorStyle={editor.style}
          onClose={() => setEditor(null)}
          onSave={(draft) => saveTask(editingTask, draft)}
          onDelete={() => deleteTask(editingTask)}
        />
      )}
    </section>
  )
}

function hasBoardDescriptor(params: unknown): boolean {
  if (typeof params !== 'object' || params === null) return false
  const descriptor = (params as Record<string, unknown>)['descriptor']
  return (
    typeof descriptor === 'object' &&
    descriptor !== null &&
    (descriptor as Record<string, unknown>)['kind'] === 'board'
  )
}

/** Dockview drop-in panel. Register this default export for the `board` kind. */
function BoardPanel(props: IDockviewPanelProps): JSX.Element {
  if (!hasBoardDescriptor(props.params)) {
    return <div className="board-panel" data-kind="unknown" />
  }
  return (
    <div className="board-panel" data-kind="board">
      <BoardSurface />
    </div>
  )
}

/** Reuses the same board surface as a workspace-level overlay. */
export function BoardOverlay({ onClose }: BoardOverlayProps): JSX.Element {
  const dialogRef = useRef<HTMLDivElement>(null)

  useFocusTrap(dialogRef, {
    active: true,
    onEscape: () => {
      const hasInnerPopover =
        document.querySelector('.board-editor, .board-context-menu') !== null
      if (!hasInnerPopover) onClose()
    }
  })

  // [M5] While the overlay is up, webview guests must not eat the pointer
  // stream (the overlay floats above the browser layer).
  useEffect(() => acquirePointerPassthrough(), [])

  return (
    <div className="board-overlay" role="presentation">
      <button
        type="button"
        className="board-overlay__backdrop"
        aria-label="학업 보드 닫기"
        onClick={onClose}
      />
      <div
        ref={dialogRef}
        className="board-overlay__surface"
        role="dialog"
        aria-modal="true"
      >
        <button
          type="button"
          className="board-overlay__close board-icon-button"
          aria-label="학업 보드 닫기"
          onClick={onClose}
        >
          <Icon name="x" />
        </button>
        <BoardSurface />
      </div>
    </div>
  )
}

export default BoardPanel
