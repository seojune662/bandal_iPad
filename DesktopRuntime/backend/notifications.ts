import { getSettings, setSettings } from '../upstream/src/main/settingsStore'
/** Exact desktop deadline task selection and durable notification ledger. */
export function installNotifications(deps: { db: any; handlePrivate(channel: string, action: (request: any) => any): void }) {
  deps.handlePrivate('nativeNotification:snapshot', () => ({ settings: getSettings(), tasks: deps.db.prepare(`SELECT t.id, t.course_id AS courseId, t.title, t.due_at AS dueAt, t.all_day AS allDay, c.name AS courseName FROM board_tasks t LEFT JOIN courses c ON c.id = t.course_id AND c.deleted_at IS NULL WHERE t.due_at IS NOT NULL AND t.deleted_at IS NULL AND t.status != 'done' AND (t.course_id IS NULL OR c.id IS NOT NULL)`).all() }))
  deps.handlePrivate('nativeNotification:markSent', request => {
    if (!Array.isArray(request.keys) || request.keys.length > 1000 || request.keys.some((key: unknown) => typeof key !== 'string' || !/^[a-zA-Z0-9_-]{1,128}:(?:1|3|7)$/.test(key))) throw new Error('Invalid deadline notification key')
    const date = new Date(request.at)
    if (!Number.isFinite(date.getTime()) || Math.abs(Date.now() - date.getTime()) > 24 * 60 * 60 * 1000) throw new Error('Invalid notification timestamp')
    const settings = getSettings(), cutoff = Date.now() - 90 * 24 * 60 * 60 * 1000
    const sent = Object.fromEntries(Object.entries(settings.notifications.sent).filter(([, value]) => Date.parse(value) >= cutoff))
    for (const key of request.keys) sent[key] = date.toISOString()
    setSettings({ notifications: { sent } }); return { ok: true }
  })
}
