import type { BoardTask, TaskStatus, UpdateTaskInput } from '../../../../shared/types/board'

export const BOARD_STATUSES: readonly TaskStatus[] = [
  'todo',
  'in-progress',
  'done'
]

export interface BoardFilters {
  /** undefined = every course, null = global tasks only. */
  courseId: string | null | undefined
  hideDone: boolean
}

export type DueState = 'none' | 'upcoming' | 'overdue' | 'later'

export interface TaskMovePlan {
  tasks: BoardTask[]
  updates: UpdateTaskInput[]
}

const UPCOMING_WINDOW_MS = 24 * 60 * 60 * 1000

function compareTasks(left: BoardTask, right: BoardTask): number {
  return (
    left.sortOrder - right.sortOrder ||
    left.createdAt.localeCompare(right.createdAt) ||
    left.id.localeCompare(right.id)
  )
}

/** Returns a stable display order for a single status column. */
export function sortTasks(tasks: readonly BoardTask[]): BoardTask[] {
  return [...tasks].sort(compareTasks)
}

/** Applies the board's course and completed-task filters. */
export function filterTasks(
  tasks: readonly BoardTask[],
  filters: BoardFilters
): BoardTask[] {
  return tasks.filter((task) => {
    if (filters.hideDone && task.status === 'done') return false
    if (filters.courseId === undefined) return true
    return task.courseId === filters.courseId
  })
}

/** Classifies a due date relative to `now`; invalid dates are treated as absent. */
export function dueState(
  dueAt: string | null,
  now: number | Date = Date.now(),
  allDay = false
): DueState {
  if (dueAt === null) return 'none'
  const dueTime = Date.parse(dueAt)
  if (Number.isNaN(dueTime)) return 'none'
  const nowTime = now instanceof Date ? now.getTime() : now
  if (allDay) {
    const due = new Date(dueTime)
    const current = new Date(nowTime)
    const dueDay = Date.UTC(due.getFullYear(), due.getMonth(), due.getDate())
    const currentDay = Date.UTC(
      current.getFullYear(),
      current.getMonth(),
      current.getDate()
    )
    if (dueDay < currentDay) return 'overdue'
    return dueDay === currentDay ? 'upcoming' : 'later'
  }
  if (dueTime < nowTime) return 'overdue'
  if (dueTime - nowTime <= UPCOMING_WINDOW_MS) return 'upcoming'
  return 'later'
}

/** Formats a due date as a local-calendar D-day label. */
export function dueDayLabel(
  dueAt: string | null,
  now: number | Date = Date.now()
): string | null {
  if (dueAt === null) return null
  const due = new Date(dueAt)
  const current = now instanceof Date ? now : new Date(now)
  if (Number.isNaN(due.getTime()) || Number.isNaN(current.getTime())) return null
  const dueDay = Date.UTC(due.getFullYear(), due.getMonth(), due.getDate())
  const currentDay = Date.UTC(
    current.getFullYear(),
    current.getMonth(),
    current.getDate()
  )
  const difference = Math.round((dueDay - currentDay) / (24 * 60 * 60 * 1000))
  if (difference === 0) return 'D-Day'
  return difference > 0 ? `D-${difference}` : `D+${Math.abs(difference)}`
}

/**
 * Produces the normalized sort orders needed for a move.
 *
 * The repository scopes sort_order to (courseId, status), so only tasks that
 * share the dragged task's course participate. `beforeTaskId === null` means
 * append to the destination column for that course.
 */
export function planTaskMove(
  tasks: readonly BoardTask[],
  taskId: string,
  targetStatus: TaskStatus,
  beforeTaskId: string | null
): TaskMovePlan {
  const dragged = tasks.find((task) => task.id === taskId)
  if (dragged === undefined || beforeTaskId === taskId) {
    return { tasks: [...tasks], updates: [] }
  }

  const sameCourse = (task: BoardTask): boolean =>
    task.courseId === dragged.courseId
  const sourceTasks = sortTasks(
    tasks.filter(
      (task) => sameCourse(task) && task.status === dragged.status && task.id !== taskId
    )
  )
  const targetTasks =
    targetStatus === dragged.status
      ? sourceTasks
      : sortTasks(
          tasks.filter(
            (task) => sameCourse(task) && task.status === targetStatus && task.id !== taskId
          )
        )

  let targetIndex = targetTasks.length
  if (beforeTaskId !== null) {
    const foundIndex = targetTasks.findIndex((task) => task.id === beforeTaskId)
    if (foundIndex !== -1) targetIndex = foundIndex
  }

  const destination = [...targetTasks]
  destination.splice(targetIndex, 0, {
    ...dragged,
    status: targetStatus
  })

  const nextById = new Map<string, BoardTask>()
  if (targetStatus !== dragged.status) {
    sourceTasks.forEach((task, index) => {
      nextById.set(task.id, { ...task, sortOrder: index })
    })
  }
  destination.forEach((task, index) => {
    nextById.set(task.id, { ...task, status: targetStatus, sortOrder: index })
  })

  const nextTasks = tasks.map((task) => nextById.get(task.id) ?? task)
  const updates = nextTasks.flatMap<UpdateTaskInput>((task) => {
    const previous = tasks.find((candidate) => candidate.id === task.id)
    if (
      previous === undefined ||
      (previous.status === task.status && previous.sortOrder === task.sortOrder)
    ) {
      return []
    }
    return [{ id: task.id, status: task.status, sortOrder: task.sortOrder }]
  })

  return { tasks: nextTasks, updates }
}
