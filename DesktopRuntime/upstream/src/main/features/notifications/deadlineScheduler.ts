import type { Database } from 'better-sqlite3'
import type {
  DeadlineLeadDays,
  Settings,
  SettingsPatch
} from '../../../shared/types/settings'
import type { Notifier } from './notifier'

const DAY_MS = 24 * 60 * 60 * 1000
const INTERVAL_MS = 30 * 60 * 1000
const SENT_RETENTION_MS = 90 * DAY_MS
const LOCAL_DATE_KEY = /^\d{4}-\d{2}-\d{2}$/u

export interface DeadlineTask {
  id: string
  courseId: string | null
  courseName: string | null
  title: string
  dueAt: string
  allDay: boolean
}

interface DeadlineRow {
  id: string
  course_id: string | null
  course_name: string | null
  title: string
  due_at: string
  all_day: number
}

function taskDueDate(task: Pick<DeadlineTask, 'dueAt' | 'allDay'>): Date {
  if (task.allDay && LOCAL_DATE_KEY.test(task.dueAt)) {
    const [year, month, day] = task.dueAt.split('-').map(Number)
    return new Date(year ?? 0, (month ?? 1) - 1, day ?? 1)
  }
  return new Date(task.dueAt)
}

export function dueKeys(
  now: Date,
  leadDays: readonly DeadlineLeadDays[],
  tasks: readonly DeadlineTask[]
): string[] {
  const nowMs = now.getTime()
  const keys: string[] = []
  for (const task of tasks) {
    const dueMs = taskDueDate(task).getTime()
    if (!Number.isFinite(dueMs) || nowMs >= dueMs) continue
    // Returning after a few days should produce the nearest reminder once,
    // rather than a burst of stale D-7, D-3 and D-1 notices for the same task.
    const eligible = leadDays.filter(lead => nowMs >= dueMs - lead * DAY_MS)
    if (eligible.length > 0) keys.push(`${task.id}:${Math.min(...eligible)}`)
  }
  return keys
}

function listDeadlineTasks(db: Database): DeadlineTask[] {
  const rows = db
    .prepare(
      `SELECT t.id, t.course_id, t.title, t.due_at, t.all_day,
              c.name AS course_name
       FROM board_tasks t
       LEFT JOIN courses c ON c.id = t.course_id AND c.deleted_at IS NULL
       WHERE t.due_at IS NOT NULL
         AND t.deleted_at IS NULL
         AND t.status != 'done'
         AND (t.course_id IS NULL OR c.id IS NOT NULL)`
    )
    .all() as DeadlineRow[]
  return rows.map((row) => ({
    id: row.id,
    courseId: row.course_id,
    courseName: row.course_name,
    title: row.title,
    dueAt: row.due_at,
    allDay: row.all_day === 1
  }))
}

function formatDue(task: DeadlineTask, locale: string): string {
  const due = taskDueDate(task)
  const options: Intl.DateTimeFormatOptions = task.allDay
    ? { dateStyle: 'medium' }
    : { dateStyle: 'medium', timeStyle: 'short' }
  return new Intl.DateTimeFormat(locale, options).format(due)
}

function prunedLedger(
  sent: Readonly<Record<string, string>>,
  nowMs: number
): { sent: Record<string, string>; changed: boolean } {
  const next: Record<string, string> = {}
  let changed = false
  for (const [key, value] of Object.entries(sent)) {
    if (Date.parse(value) < nowMs - SENT_RETENTION_MS) {
      changed = true
    } else {
      next[key] = value
    }
  }
  return { sent: next, changed }
}

export interface DeadlineScheduler {
  run(): void
  start(): void
  dispose(): void
}

export function createDeadlineScheduler(deps: {
  db: Database
  getSettings: () => Settings
  setSettings: (patch: SettingsPatch) => Settings
  notifier: Pick<Notifier, 'notify'>
  now?: () => Date
  onError?: (error: unknown) => void
}): DeadlineScheduler {
  let timer: NodeJS.Timeout | null = null

  const run = (): void => {
    const now = deps.now?.() ?? new Date()
    const settings = deps.getSettings()
    const ledger = prunedLedger(settings.notifications.sent, now.getTime())
    const tasks = listDeadlineTasks(deps.db)
    const candidates = new Set(
      dueKeys(now, settings.notifications.deadlineLeadDays, tasks)
    )
    for (const task of tasks) {
      for (const lead of settings.notifications.deadlineLeadDays) {
        const key = `${task.id}:${lead}`
        if (!candidates.has(key) || ledger.sent[key] !== undefined) continue
        const result = deps.notifier.notify({
          kind: 'deadline',
          title: `마감 D-${lead}: ${task.title}`,
          body: `${task.courseName ?? '반달'} · ${formatDue(task, settings.locale)}`,
          courseId: task.courseId
        })
        if (result === 'sent' || result === 'suppressed') {
          ledger.sent[key] = now.toISOString()
          ledger.changed = true
        }
      }
    }
    if (ledger.changed) {
      deps.setSettings({
        notifications: { ...settings.notifications, sent: ledger.sent }
      })
    }
  }

  const safelyRun = (): void => {
    try {
      run()
    } catch (error) {
      deps.onError?.(error)
    }
  }

  return {
    run,
    start() {
      if (timer !== null) return
      safelyRun()
      timer = setInterval(safelyRun, INTERVAL_MS)
    },
    dispose() {
      if (timer === null) return
      clearInterval(timer)
      timer = null
    }
  }
}
