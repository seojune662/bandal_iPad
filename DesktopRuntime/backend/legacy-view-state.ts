import { isTabDescriptor, NEW_TAB_URL, type TabDescriptor } from '../upstream/src/shared/tabs'
import { materialKindForPath } from '../upstream/src/shared/materialKind'
import { isViewableFile } from '../upstream/src/renderer/src/features/file/fileFormats'
import { resolveInsideReal } from '../upstream/src/main/db/validate'
import { getSettings, setSettings } from '../upstream/src/main/settingsStore'
import { native } from './native'
import { statSync } from './shims/fs'

// Independent of the content migration: installed v1 apps already have that
// receipt and must not copy assets or insert courses again.
export const LEGACY_VIEW_STATE_VERSION = 'native-to-desktop-view-state-v1'
type Skip = { recordID: string; tabID?: string; reason: string }
type Report = {
  version: string; phase: 'views-saved' | 'complete'; layouts: number; positions: number; skipped: Skip[]
  selection: { target: string | null; status: 'pending' | 'restored' | 'preserved' | 'skipped'; reason?: string }
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const isID = (value: unknown): value is string => typeof value === 'string' && uuid.test(value)
const object = (value: unknown): value is Record<string, any> => !!value && typeof value === 'object' && !Array.isArray(value)
function json(value: string): Record<string, any> | null { try { const p = JSON.parse(value); return object(p) ? p : null } catch { return null } }

function panelID(descriptor: TabDescriptor): string {
  const p = descriptor.payload as any
  switch (descriptor.kind) {
    case 'pdf': case 'note': case 'image': case 'file': return `${descriptor.kind}:${p.courseId}:${p.relPath}`
    case 'browser': return `browser:${p.tabId}`
    case 'whiteboard': return `whiteboard:${p.courseId}:${p.boardId}`
    case 'chat': return `chat:${p.courseId}:${p.conversationId}`
    case 'recording': return `recording:${p.courseId}${p.sessionId ? `:${p.sessionId}` : ''}`
    case 'learning': return `learning:${p.courseId}:overview`
    case 'board': return 'board'
    default: throw new Error('Unsupported legacy tab descriptor')
  }
}

/** Builds the original Dockview document, without changing renderer markup. */
export function legacyDockviewLayout(courseID: string, workspace: any, tabs: Array<{ oldID: string; title: string; descriptor: TabDescriptor }>) {
  const panels: Record<string, any> = {}, identities = new Map<string, string>()
  for (const tab of tabs) {
    const canonical = panelID(tab.descriptor)
    const id = Object.hasOwn(panels, canonical) ? `${canonical}::duplicate::${tab.oldID}` : canonical
    panels[id] = { id, title: tab.title, contentComponent: tab.descriptor.kind, params: { descriptor: tab.descriptor } }
    identities.set(tab.oldID, id)
  }
  const selected = workspace.selectedCourseID === courseID
  const primary = selected ? identities.get(workspace.primaryID) : undefined
  const secondary = selected && workspace.splitEnabled === true ? identities.get(workspace.secondaryID) : undefined
  const split = selected && workspace.splitEnabled === true
  const leftID = `legacy-${courseID}-primary`, rightID = `legacy-${courseID}-secondary`
  const left = Object.keys(panels).filter(id => !split || id !== secondary || id === primary)
  const right = secondary && secondary !== primary ? [secondary] : []
  const leaf = (id: string, views: string[], activeView?: string) => ({ type: 'leaf', size: split ? 512 : 1024,
    data: { id, views, ...(activeView && views.includes(activeView) ? { activeView } : views[0] ? { activeView: views[0] } : {}) } })
  return { grid: { width: 1024, height: 768, orientation: 'HORIZONTAL', root: { type: 'branch', size: 768,
    data: [leaf(leftID, left, primary), ...(split ? [leaf(rightID, right, secondary)] : [])] } }, panels,
    activeGroup: split && workspace.focusedPane === 1 ? rightID : leftID }
}

export function migrateLegacyViewState(db: any): Report | null {
  db.exec('CREATE TABLE IF NOT EXISTS ipad_legacy_view_state_migrations(version TEXT PRIMARY KEY, report_json TEXT NOT NULL)')
  const readReceipt = db.prepare('SELECT report_json FROM ipad_legacy_view_state_migrations WHERE version=?')
  const previous = readReceipt.get(LEGACY_VIEW_STATE_VERSION)
  if (previous) {
    const report = JSON.parse(previous.report_json) as Report
    if (report.phase === 'complete') return report
    return finishSelection(db, report)
  }
  // Do not reload ink/chat/article bodies for a view-state-only upgrade. Native
  // positions have a stable ID prefix; material metadata is fetched on demand.
  const archived = db.prepare("SELECT record_id,kind,payload_json,envelope_json FROM ipad_legacy_archive WHERE (kind='workspace' AND record_id='workspace:ipad') OR (kind='artifact' AND record_id LIKE 'position:%') ORDER BY record_id").all()
  const source = new Map<string, { payload: any; deleted: boolean }>()
  const skipped: Skip[] = []
  for (const row of archived) {
    const payload = json(row.payload_json), envelope = json(row.envelope_json)
    if (payload && envelope) source.set(row.record_id, { payload, deleted: envelope.deleted === true || envelope.deleted === 1 })
    else skipped.push({ recordID: row.record_id, reason: 'invalid-archive' })
  }
  const workspace = source.get('workspace:ipad')
  const positions = archived.filter((row: any) => row.kind === 'artifact' && source.get(row.record_id)?.payload.recordType === 'reading-position')
  if (!workspace && !positions.length) return null // A later v1 archive may still be created.
  const report: Report = { version: LEGACY_VIEW_STATE_VERSION, phase: 'views-saved', layouts: 0, positions: 0, skipped,
    selection: { target: null, status: 'skipped', reason: 'workspace-unavailable' } }
  const course = (id: unknown) => isID(id) ? db.prepare('SELECT id,folder_path FROM courses WHERE id=? AND deleted_at IS NULL').get(id) : undefined
  const materialSource = (id: unknown) => {
    if (!isID(id)) return undefined
    const recordID = `material:${id}`
    if (!source.has(recordID)) {
      const row = db.prepare("SELECT payload_json,envelope_json FROM ipad_legacy_archive WHERE record_id=? AND kind='material'").get(recordID)
      const payload = row && json(row.payload_json), envelope = row && json(row.envelope_json)
      if (payload && envelope) source.set(recordID, { payload, deleted: envelope.deleted === true || envelope.deleted === 1 })
    }
    return source.get(recordID)
  }
  const material = (id: unknown, courseID: string) => {
    if (!isID(id)) return null
    const archived = materialSource(id), p = archived?.payload
    if (!p || archived!.deleted || p.courseID !== courseID) return null
    const row = db.prepare('SELECT id,course_id,rel_path,kind FROM materials_index WHERE id=? AND deleted_at IS NULL').get(id)
    return row?.course_id === courseID ? { ...row, original: p } : null
  }
  const layouts: Array<{ courseID: string; layout: any }> = [], viewStates: Array<{ courseID: string; relPath: string; page: number }> = []
  const skip = (recordID: string, reason: string, tabID?: string) => skipped.push({ recordID, ...(tabID ? { tabID } : {}), reason })
  if (workspace) {
    const p = workspace.payload, recordID = 'workspace:ipad'
    if (workspace.deleted || !Array.isArray(p.tabs)) skip(recordID, workspace.deleted ? 'deleted-workspace' : 'invalid-workspace')
    else {
      const grouped = new Map<string, Array<{ oldID: string; title: string; descriptor: TabDescriptor }>>()
      const seen = new Set<string>()
      for (const tab of p.tabs) {
        if (!object(tab) || !isID(tab.id) || !isID(tab.courseID)) { skip(recordID, 'invalid-tab'); continue }
        if (seen.has(tab.id)) { skip(recordID, 'duplicate-tab-id', tab.id); continue }
        seen.add(tab.id)
        if (tab.isPrivate === true) { skip(recordID, 'private-tab', tab.id); continue }
        const c = course(tab.courseID)
        if (!c) { skip(recordID, 'deleted-or-missing-course', tab.id); continue }
        let descriptor: TabDescriptor | undefined
        if (['pdf', 'note', 'file', 'whiteboard'].includes(tab.kind)) {
          const original = materialSource(tab.materialID)
          if (tab.kind === 'whiteboard' && isID(tab.materialID) && original && !original.deleted && original.payload.kind === 'whiteboard' && original.payload.courseID === c.id &&
              db.prepare('SELECT id FROM whiteboards WHERE id=? AND course_id=? AND deleted_at IS NULL').get(tab.materialID, c.id)) {
            descriptor = { kind: 'whiteboard', payload: { courseId: c.id, boardId: tab.materialID } }
          } else {
            const m = material(tab.materialID, c.id)
            if (!m) { skip(recordID, 'deleted-or-missing-material', tab.id); continue }
            try { if (!statSync(resolveInsideReal(c.folder_path, m.rel_path)).isFile()) throw new Error('Not a file') } catch { skip(recordID, 'missing-or-unsafe-material-file', tab.id); continue }
            const kind = materialKindForPath(m.rel_path)
            if (kind === 'pdf' || kind === 'note' || kind === 'image') descriptor = { kind, payload: { courseId: c.id, relPath: m.rel_path } }
            else if (isViewableFile(m.rel_path)) descriptor = { kind: 'file', payload: { courseId: c.id, relPath: m.rel_path } }
            else { skip(recordID, 'unsupported-material-viewer', tab.id); continue }
          }
        } else if (tab.kind === 'browser') {
          try {
            const url = new URL(typeof tab.url === 'string' && tab.url ? tab.url : NEW_TAB_URL)
            if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new Error('Invalid browser URL')
            descriptor = { kind: 'browser', payload: { tabId: tab.id, initialUrl: url.href } }
          } catch { skip(recordID, 'unsupported-browser-url', tab.id); continue }
        } else if (tab.kind === 'board') descriptor = { kind: 'board', payload: {} }
        // The native tab saved only the course, never its locally selected
        // recording/project. Reopen the original overview without inventing IDs.
        else if (tab.kind === 'recording') descriptor = { kind: 'recording', payload: { courseId: c.id } }
        else if (tab.kind === 'learning') descriptor = { kind: 'learning', payload: { courseId: c.id } }
        else if (tab.kind === 'chat') {
          const session = db.prepare('SELECT id FROM agent_sessions WHERE id=? AND course_id=? AND deleted_at IS NULL').get(tab.id, c.id)
          if (session) descriptor = { kind: 'chat', payload: { courseId: c.id, conversationId: tab.id } }
          else { skip(recordID, 'chat-content-not-projected', tab.id); continue }
        } else { skip(recordID, `unsupported-native-tab:${String(tab.kind)}`, tab.id); continue }
        if (!isTabDescriptor(descriptor)) { skip(recordID, 'invalid-descriptor', tab.id); continue }
        const tabs = grouped.get(c.id) ?? []
        tabs.push({ oldID: tab.id, title: typeof tab.title === 'string' ? tab.title : descriptor.kind, descriptor }); grouped.set(c.id, tabs)
      }
      for (const [courseID, tabs] of grouped) {
        if (db.prepare('SELECT course_id FROM tabs_layout WHERE course_id=?').get(courseID)) { skip(recordID, `existing-layout:${courseID}`); continue }
        layouts.push({ courseID, layout: legacyDockviewLayout(courseID, p, tabs) })
      }
      const current = getSettings()
      if (current.lastActiveCourseId !== null) report.selection = { target: null, status: 'preserved', reason: 'existing-last-course' }
      else if (!current.restoreLastCourse) report.selection = { target: null, status: 'preserved', reason: 'restore-last-course-disabled' }
      else if (course(p.selectedCourseID)) report.selection = { target: p.selectedCourseID, status: 'pending' }
      else report.selection = { target: null, status: 'skipped', reason: 'deleted-or-missing-selected-course' }
    }
  }
  for (const row of positions) {
    const saved = source.get(row.record_id)!, p = saved.payload
    if (saved.deleted) { skip(row.record_id, 'deleted-position'); continue }
    const c = course(p.courseID), m = c && material(p.materialID, c.id)
    if (!c || !m || materialKindForPath(m.rel_path) !== 'pdf') { skip(row.record_id, 'deleted-or-missing-pdf'); continue }
    if (p.documentRevision !== m.original.revision || !/^[0-9a-f]{64}$/.test(p.documentRevision)) { skip(row.record_id, 'document-revision-mismatch'); continue }
    if (!Number.isSafeInteger(p.page) || p.page < 1) { skip(row.record_id, 'invalid-page'); continue }
    if (db.prepare('SELECT course_id FROM pdf_view_state WHERE course_id=? AND rel_path=?').get(c.id, m.rel_path)) { skip(row.record_id, 'existing-pdf-view-state'); continue }
    try {
      const path = resolveInsideReal(c.folder_path, m.rel_path)
      if (native('fs.sha256', { path }) !== p.documentRevision) { skip(row.record_id, 'current-document-revision-mismatch'); continue }
      const pages = native<Array<{ page: number }>>('pdf.geometry', { path })
      if (!pages.some(page => page.page === p.page)) { skip(row.record_id, 'page-out-of-range'); continue }
    } catch { skip(row.record_id, 'pdf-verification-failed'); continue }
    viewStates.push({ courseID: c.id, relPath: m.rel_path, page: p.page })
  }
  db.transaction(() => {
    const now = new Date().toISOString()
    for (const { courseID, layout } of layouts) {
      report.layouts += db.prepare('INSERT OR IGNORE INTO tabs_layout(course_id,layout_json,created_at,updated_at) VALUES(?,?,?,?)').run(courseID, JSON.stringify(layout), now, now).changes
    }
    for (const { courseID, relPath, page } of viewStates) {
      report.positions += db.prepare('INSERT OR IGNORE INTO pdf_view_state(course_id,rel_path,page,zoom,updated_at) VALUES(?,?,?,?,?)').run(courseID, relPath, page, 1, now).changes
    }
    db.prepare('INSERT INTO ipad_legacy_view_state_migrations VALUES(?,?)').run(LEGACY_VIEW_STATE_VERSION, JSON.stringify(report))
  })()
  return finishSelection(db, report)
}

// File-backed settings cannot share a SQLite transaction. The receipt first
// commits the views, then records this resumable final step. A restart never
// reapplies layouts or replaces a last-course selection made in the meantime.
function finishSelection(db: any, report: Report): Report {
  if (report.selection.status === 'pending' && report.selection.target) {
    const current = getSettings(), target = report.selection.target
    if (!db.prepare('SELECT id FROM courses WHERE id=? AND deleted_at IS NULL').get(target)) report.selection = { target, status: 'skipped', reason: 'selected-course-removed' }
    else if (!current.restoreLastCourse || current.lastActiveCourseId !== null && current.lastActiveCourseId !== target) report.selection = { target, status: 'preserved', reason: 'selection-changed' }
    else {
      if (current.lastActiveCourseId === null) setSettings({ lastActiveCourseId: target })
      report.selection = { target, status: 'restored' }
    }
  }
  report.phase = 'complete'
  db.prepare('UPDATE ipad_legacy_view_state_migrations SET report_json=? WHERE version=?').run(JSON.stringify(report), LEGACY_VIEW_STATE_VERSION)
  return report
}
