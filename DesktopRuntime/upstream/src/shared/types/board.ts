/**
 * Task board (kanban) types. Tasks may belong to a course or be global
 * (courseId === null).
 */

export type TaskStatus = 'todo' | 'in-progress' | 'done'

export const TASK_COLORS = [
  'none',
  'red',
  'orange',
  'yellow',
  'green',
  'blue',
  'violet'
] as const
export type TaskColor = (typeof TASK_COLORS)[number]

/**
 * What the entry represents on the calendar.
 *
 * Everything shares one table because a task, an assignment and an exam differ
 * only in how they read on a date — splitting them would mean three queries to
 * build one month view and three places to keep due-date logic correct.
 */
export type TaskKind = 'task' | 'assignment' | 'exam' | 'class'

export interface BoardTask {
  id: string
  /** null = global task not tied to a course. */
  courseId: string | null
  title: string
  notes: string
  status: TaskStatus
  kind: TaskKind
  /** Optional personal label color, independent of course/status colors. */
  color: TaskColor
  /** Optional range start; null means a single day or a deadline only. */
  startAt: string | null
  /** Range end/deadline. Inclusive YYYY-MM-DD for all-day, exclusive ISO end for timed ranges. */
  dueAt: string | null
  /** True when `dueAt` marks a whole day rather than a moment. */
  allDay: boolean
  sortOrder: number
  createdAt: string
  updatedAt: string
}

export interface CreateTaskInput {
  courseId: string | null
  title: string
  notes?: string
  status?: TaskStatus
  kind?: TaskKind
  color?: TaskColor
  dueAt?: string | null
  startAt?: string | null
  allDay?: boolean
}

export interface UpdateTaskInput {
  id: string
  title?: string
  notes?: string
  status?: TaskStatus
  kind?: TaskKind
  color?: TaskColor
  dueAt?: string | null
  startAt?: string | null
  allDay?: boolean
  sortOrder?: number
  /** Move the task to another course (null = global). Omit to keep. */
  courseId?: string | null
}

export interface ListTasksInput {
  /** Omit to list tasks for all courses plus global tasks. */
  courseId?: string | null
  includeDone?: boolean
}

/** Half-open range [from, to) in ISO datetimes — what the calendar asks for. */
export interface CalendarRangeInput {
  from: string
  to: string
  /** Omit for every course plus global entries. */
  courseId?: string | null
}

/** One upcoming deadline, already resolved against "now" for the UI. */
export interface UpcomingDeadline {
  task: BoardTask
  courseName: string | null
  /** Whole days until due. Negative when overdue. */
  daysLeft: number
  overdue: boolean
}
