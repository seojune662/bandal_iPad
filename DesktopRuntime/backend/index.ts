import './globals'
import { env, emit, native } from './native'
import { createDatabase } from './database'
import { Buffer } from './shims/buffer'
import { mkdirSync, renameSync } from './shims/fs'
import { join, basename } from './shims/path'
import { randomUUID } from './shims/crypto'
import { runMigrations, migrations } from '../upstream/src/main/db/migrations'
import { getSettings, setSettings, resetSettings } from '../upstream/src/main/settingsStore'
import { createCoursesRepo } from '../upstream/src/main/features/courses/coursesRepo'
import { createCourseGroupsRepo } from '../upstream/src/main/features/courses/courseGroupsRepo'
import { createCourseLinksRepo } from '../upstream/src/main/features/courses/courseLinksRepo'
import { createMaterialsRepo } from '../upstream/src/main/features/materials/materialsRepo'
import { createNotesRepo } from '../upstream/src/main/features/notes/notesRepo'
import { createPdfViewStateRepo } from '../upstream/src/main/features/pdf/pdfViewStateRepo'
import { createMediaProgressRepo } from '../upstream/src/main/features/materials/mediaProgressRepo'
import { createBoardRepo } from '../upstream/src/main/features/board/boardRepo'
import { createCanvasRepo } from '../upstream/src/main/features/canvas/canvasRepo'
import { createFavoritesRepo } from '../upstream/src/main/features/favorites/favoritesRepo'
import { createLayoutRepo } from '../upstream/src/main/db/layoutRepo'
import { createMaterialLinksRepo } from '../upstream/src/main/features/links/materialLinksRepo'
import { createLinkIndex } from '../upstream/src/main/features/links/linkIndex'
import { repointMaterialPath } from '../upstream/src/main/features/links/renameRepoint'
import { createLinkService } from '../upstream/src/main/features/link/linkService'
import { createActivityRepo } from '../upstream/src/main/features/context/activityRepo'
import { createUsageRepo } from '../upstream/src/main/features/usage/usageRepo'
import { createChatRepo } from '../upstream/src/main/features/agent/chatRepo'
import { createRecordingRepo } from '../upstream/src/main/features/recordings/recordingRepo'
import { isTabDescriptor } from '../upstream/src/shared/tabs'
import { ValidationError } from '../upstream/src/main/db/errors'
import { installLearning } from './learning'
import { isUsageWindowDays } from '../upstream/src/shared/types/usage'
import { createAppleCalendarService } from '../upstream/src/main/features/calendar/appleCalendarService'
import { existsSync, readFileSync } from './shims/fs'
import { writeFileAtomic } from './shims/atomic-write'
import { migrateLegacy } from './legacy'
import { migrateLegacyViewState } from './legacy-view-state'
import { relocateManagedStorage } from './storage-relocation'
import { createSearchIndex } from '../upstream/src/main/features/search/searchIndex'
import { createPluginStore } from '../upstream/src/main/features/plugins/pluginStore'
import { createPluginDataStore } from '../upstream/src/main/features/plugins/pluginDataStore'
import { createPluginSettings } from '../upstream/src/main/features/plugins/pluginSettings'
import { createPackStore } from '../upstream/src/main/features/workflowPacks/packStore'
import { installPdfExport } from './pdf-export'
import { installMarket } from './market'
import { installHoverPreview } from './hover'
import { installMCP } from './mcp'
import { installPluginCatalog } from './plugins-catalog'
import { installAI } from './ai'
import { installSync } from './sync'
import { installApplication } from './application'
import { installMail } from './mail'
import { installNotifications } from './notifications'
import { installBrowserShortcuts } from './browser-shortcuts'
import { importBookmarkHTML } from './bookmark-import'
import { createBoundPDFRepositories, createPDFDocumentBindings, nativePDFMutationStatus } from './native-pdf'
import { createPDFOriginalPreserver } from './pdf-binding-originals'
import { installPresentation } from './presentation'
import { installStudy } from './study'
import { resolveInsideReal } from '../upstream/src/main/db/validate'
import { createMaterialWatchers } from './material-watch'

type Handler = (request: any) => unknown | Promise<unknown>
const handlers = new Map<string, Handler>()
const privateHandlers = new Map<string, Handler>()
let initialized = false
let repositories: any
const OK = { ok: true as const }
function handle(channel: string, action: Handler) { if (handlers.has(channel)) throw new Error(`Duplicate channel ${channel}`); handlers.set(channel, action) }
function handlePrivate(channel: string, action: Handler) { if (privateHandlers.has(channel)) throw new Error(`Duplicate private channel ${channel}`); privateHandlers.set(channel, action) }
function unsupported(channel: string): never { const error = new Error(`iPad native service is not connected: ${channel}`) as Error & { code: string }; error.code = 'UNSUPPORTED_CHANNEL'; throw error }
function wire(value: any): any {
  if (value instanceof Uint8Array) return { __bandalBytes: Buffer.from(value).toString('base64') }
  if (Array.isArray(value)) return value.map(wire)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, wire(item)]))
  return value
}
function unwire(value: any): any {
  if (value && typeof value === 'object' && typeof value.__bandalBytes === 'string') return Buffer.from(value.__bandalBytes, 'base64')
  if (Array.isArray(value)) return value.map(unwire)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, unwire(item)]))
  return value
}

export function initialize() {
  if (initialized) return { schemaVersion: migrations.length, supportedChannels: [...handlers.keys()] }
  mkdirSync(env().userDataPath, { recursive: true }); mkdirSync(env().dataRoot, { recursive: true })
  const db: any = createDatabase()
  db.pragma('foreign_keys = ON'); db.pragma('journal_mode = WAL'); db.pragma('synchronous = FULL')
  runMigrations(db)
  relocateManagedStorage(db)
  const migration = migrateLegacy(db)
  const viewStateMigration = migrateLegacyViewState(db)
  const courses = createCoursesRepo({ db, getDataRoot: () => getSettings().dataRoot })
  const groups = createCourseGroupsRepo(db), courseLinks = createCourseLinksRepo(db)
  const activity = createActivityRepo(db), usage = createUsageRepo(db), chat = createChatRepo(db)
  const recordings = createRecordingRepo(db, id => courses.getFolder(id))
  const linkIndex = createLinkIndex({ db, getCourseFolder: id => courses.getFolder(id) })
  const links = createMaterialLinksRepo(db)
  let materialWatchChanged = (_courseId: string): void => {}
  const changed = (courseId: string) => { materialWatchChanged(courseId); emit('materials:changed', { courseId }) }
  const courseChanged = <T>(result: T): T => { emit('courses:changed', {}); return result }
  // iOS has no OS Trash API. Retain deleted files, with a recoverable path,
  // under this app's Trash instead of unlinking a user's course material.
  const trash = async (path: string) => {
    const directory = join(env().userDataPath, 'Trash', randomUUID())
    mkdirSync(directory, { recursive: true }); renameSync(path, join(directory, basename(path)))
  }
  let learning: ReturnType<typeof installLearning>
  const materialPathLock = { tryAcquire() {
    const token = native<number | null>('fs.lockAcquire', { path: join(env().userDataPath, 'material-path-lock.db') })
    return token === null ? undefined : () => { native('fs.lockRelease', { token }) }
  } }
  const repoint = (change: any) => {
    db.transaction(() => {
      learning.paths.enqueue(change)
      pdfBindings.repoint(change)
      repointMaterialPath({ db, courseFolder: courses.getFolder(change.courseId), ...change })
      materials.repointAddedState(change.courseId, change.fromRelPath, change.toRelPath, change.isDirectory)
    })()
    recordings.repoint(change.courseId, change.fromRelPath, change.toRelPath, change.isDirectory)
    learning.paths.schedule()
  }
  const materials = createMaterialsRepo({ db, getCourseFolder: id => courses.getFolder(id),
    pathLock: materialPathLock,
    revealItem: path => native('platform.reveal', { path }), trashItem: trash, onPathChanged: repoint })
  handlePrivate('nativeMaterial:path', req => materials.absolutePathForAsync(req.courseId,req.relPath))
  const notes = createNotesRepo({ renameWithMarkdown: input => materials.renameWithMarkdown(input),
    assertPathAvailable: (courseId, relPath) => materials.assertPathAvailable(courseId, relPath), getCourseFolder: id => courses.getFolder(id), onPathChanged: repoint,
    onCreated: ref => materials.recordAdded(ref.courseId, ref.relPath) })
  installHoverPreview({handle,materials})
  const pdfSourcePath = (courseId: string, relPath: string) => resolveInsideReal(courses.getFolder(courseId), relPath)
  const pdfBindings = createPDFDocumentBindings(db, (courseId, relPath) => native<string>('fs.sha256', { path: pdfSourcePath(courseId, relPath) }), createPDFOriginalPreserver(pdfSourcePath))
  const { annotations, drawings } = createBoundPDFRepositories(db, pdfBindings)
  const media = createMediaProgressRepo(db), pdf = createPdfViewStateRepo(db)
  const board = createBoardRepo(db), canvas = createCanvasRepo(db), favorites = createFavoritesRepo(db), layout = createLayoutRepo(db)
  const linkService = createLinkService({ notes, getCourseFolder: id => courses.getFolder(id) })
  const materialMutation = (action: Handler): Handler => async request => {
    const result = await action(request); materials.invalidateTree(request.courseId); changed(request.courseId); return result
  }
  handle('settings:get', getSettings); handle('settings:set', setSettings); handle('settings:reset', () => resetSettings())
  handle('courses:list', req => courses.list(req))
  for (const action of ['create', 'addFromFolder', 'relink', 'rename', 'setColor', 'archive', 'organize'] as const)
    handle(`courses:${action}`, req => courseChanged((courses[action] as any)(req)))
  handle('courses:delete', req => courseChanged(courses.softDelete(req)))
  handle('courses:purge', async req => { const result = courses.purge(req); await trash(result.folderPath); return courseChanged(OK) })
  for (const action of ['list', 'create', 'rename', 'delete'] as const)
    handle(`courseGroups:${action}`, req => action === 'list' ? groups.list() : courseChanged((groups[action] as any)(req)))
  for (const action of ['list', 'create', 'update', 'delete'] as const) handle(`courseLinks:${action}`, req => (courseLinks[action] as any)(req))
  handle('materials:snapshot', req => ({ tree: materials.snapshot(req.courseId) }))
  handle('materials:tree', req => materials.tree(req.courseId)); handle('materials:search', req => materials.search(req.courseId, req.query))
  handle('materials:readFile', req => materials.readFile(req.courseId, req.relPath))
  handle('materials:import', materialMutation(req => materials.import(req.courseId, req.paths, req.dirRelPath)))
  for (const action of ['move', 'writeFile', 'rename', 'duplicate', 'createFolder'] as const)
    handle(`materials:${action}`, materialMutation(req => materials[action](req)))
  handle('materials:delete', materialMutation(req => materials.softDelete(req)))
  handle('materials:reveal', req => materials.reveal(req.courseId, req.relPath))
  // Watch requests establish a real polling subscription; content mutations
  // also invalidate synchronously so renderer updates do not await the poll.
  const watchers = createMaterialWatchers({ tree: id => materials.tree(id), invalidate: id => materials.invalidateTree(id), changed,
    failed: error => emit('backend:error', { message: String(error), operation: 'materials.watch' }) })
  materialWatchChanged = courseId => watchers.mutated(courseId)
  handle('materials:watch', async req => {
    courses.getById(req.courseId)
    await watchers.watch(req)
    return OK
  })
  handle('materials:unwatch', req => { watchers.unwatch(req); return OK })
  handlePrivate('nativeRuntime:rendererReady', req => { if (typeof req.rendererSessionId !== 'string' || req.rendererSessionId.length > 128) throw new Error('Invalid renderer session'); watchers.setSession(req.rendererSessionId); return OK })
  handlePrivate('nativeRuntime:rendererReset', () => { watchers.reset(); return OK })
  handlePrivate('nativeRuntime:active', req => { watchers.setActive(req.active === true); return OK })
  handlePrivate('nativeRuntime:capabilities', () => ({ channels: [...handlers.keys()].sort() }))
  handle('notes:read', req => notes.read(req))
  for (const action of ['create', 'write', 'rename'] as const) handle(`notes:${action}`, materialMutation(req => notes[action](req as any)))
  handle('annotations:listForFile', req => annotations.listForFile(req))
  handle('annotations:create', req => annotations.create(req)); handle('annotations:update', req => annotations.update(req)); handle('annotations:delete', req => annotations.softDelete(req))
  handle('drawings:listForFile', req => drawings.listForFile(req.courseId, req.relPath))
  handle('drawings:create', req => drawings.create(req)); handle('drawings:update', req => drawings.update(req))
  handlePrivate('nativePDF:mutationStatus', req => nativePDFMutationStatus(db, req))
  handlePrivate('nativePDF:binding', req => pdfBindings.check(req))
  handle('drawings:delete', req => { drawings.softDelete(req.ids); return OK })
  handle('media:getProgress', req => media.get(req.courseId, req.relPath)); handle('media:setProgress', req => media.set(req))
  handle('pdf:getViewState', req => pdf.get(req.courseId, req.relPath)); handle('pdf:setViewState', req => pdf.set(req))
  handle('board:listTasks', req => board.list(req)); handle('calendar:range', req => board.listRange(req)); handle('calendar:upcoming', req => board.upcoming(req))
  for (const [channel, method] of [['createTask', 'create'], ['updateTask', 'update'], ['deleteTask', 'softDelete']] as const)
    handle(`board:${channel}`, req => { const result = board[method](req); emit('board:changed', { courseId: 'courseId' in result ? result.courseId : null }); return result })
  handle('board:reorderTasks', req => { const result = board.reorderTasks(req.courseId, req.updates); emit('board:changed', { courseId: req.courseId }); return result })
  handle('canvas:list', req => canvas.listBoards(req.courseId))
  handle('canvas:create', req => { const result = canvas.createBoard(req); return canvas.setBackground({ boardId: result.id, background: getSettings().tabs.whiteboardBackground }) })
  handle('canvas:rename', req => canvas.renameBoard(req)); handle('canvas:remove', req => { canvas.removeBoard(req.id); return OK })
  handle('canvas:open', req => canvas.open(req.boardId)); handle('canvas:hoverPreview', req => canvas.hoverPreview(req.boardId))
  handle('canvas:setBackground', req => canvas.setBackground(req)); handle('canvas:setPageCount', req => canvas.setPageCount(req))
  handle('canvas:putShape', req => canvas.putShape(req)); handle('canvas:removeShapes', req => { canvas.removeShapes(req); return OK })
  handle('favorites:list', req => favorites.list(req.courseId)); handle('favorites:add', req => favorites.add(req)); handle('favorites:rename', req => favorites.rename(req))
  handle('favorites:remove', req => { favorites.softDelete(req.id); return OK }); handle('favorites:reorder', req => { favorites.reorder(req); return OK })
  handlePrivate('nativeBookmark:import', req => importBookmarkHTML(db, favorites, req))
  handle('layout:get', req => layout.get(req.courseId)); handle('layout:save', req => layout.save(req.courseId, req.layout)); handle('layout:saveMany', req => layout.saveMany(req.layouts))
  handle('links:create', materialMutation(req => links.create({ ...req, label: req.label ?? '' })))
  handle('links:remove', materialMutation(req => links.remove(req.courseId, req.id)))
  handle('links:updatePageNote', req => links.updateMetadata(req.courseId, req.id, req.metadata))
  handle('links:listFor', req => links.listFor(req.courseId, req.relPath))
  handle('links:listForDescriptor', req => { if (!isTabDescriptor(req.descriptor)) throw new ValidationError('Invalid TabDescriptor'); return links.listForDescriptor(req.courseId, req.descriptor) })
  handle('links:graph', req => ({ links: links.listAll(req.courseId), backlinks: linkIndex.allForCourse(req.courseId) }))
  handle('links:forMaterial', req => linkIndex.forMaterial(req.courseId, req.relPath))
  handle('link:sendHighlightToNote', materialMutation(req => linkService.sendHighlightToNote(req)))
  handle('link:sendWebClipToNote', materialMutation(req => linkService.sendWebClipToNote(req)))
  handle('activity:record', req => activity.record(req)); handle('activity:recent', req => activity.recent(req.courseId, req.limit))
  handle('usage:summary', req => { if (!isUsageWindowDays(req.windowDays)) throw new ValidationError('Invalid usage window'); return usage.summary(req.windowDays) })
  handle('chat:conversations', req => ({ conversations: (req.surface ? chat.listConversations(req.courseId,req.surface) : [...chat.listConversations(req.courseId, 'app'), ...chat.listConversations(req.courseId, 'desktop')]).sort((a, b) => (b.lastUsedAt ?? b.createdAt).localeCompare(a.lastUsedAt ?? a.createdAt)) }))
  handle('chat:grants', req => ({ grants: chat.listGrantDetails(req.courseId) }))
  handle('chat:revokeGrant', req => { chat.removeGrant(req.id); return OK })
  handle('recordings:list', req => recordings.list(req.courseId)); handle('recordings:resolve', req => recordings.resolve(req.courseId, req.relPath))
  handle('recordings:read', req => recordings.read(req.id, req.afterId))
  handle('recordings:anchor', req => recordings.anchor(req.id, req.label, req.relPath, req.page, req.sample))
  handle('recordings:export', req => {
    const recording = recordings.get(req.id), file = materials.writeFile({ courseId: recording.courseId,
      dirRelPath: '', fileName: `${recording.title.replace(/[/\\:*?"<>|]/g, '').trim() || '강의 녹음'}.md`, encoding: 'utf8', data: recordings.markdown(req.id) })
    materials.invalidateTree(recording.courseId); changed(recording.courseId); return { courseId: recording.courseId, relPath: file.relPath }
  })
  let searchIndex: ReturnType<typeof createSearchIndex> | undefined
  const search = () => searchIndex ??= createSearchIndex(db, { getCourseFolder: id => courses.getFolder(id) })
  handle('search:query', req => ({ hits: search().query(req.courseId, req.query, req.limit) }))
  handle('search:indexPdfPages', req => { search().indexPdfPages(req); emit('search:changed', { courseId: req.courseId }); return OK })
  const plugins = createPluginStore({ userDataDir: env().userDataPath })
  installApplication({ handle, plugins })
  installMail(handle)
  const pluginData = createPluginDataStore({ userDataDir: env().userDataPath })
  const pluginSettings = createPluginSettings({ data: pluginData, manifest: id => plugins.manifestFor(id),
    changed: (pluginId, values) => emit('plugins:settingsChanged', { pluginId, values }) })
  handle('plugins:list', () => ({ plugins: plugins.list() }))
  handle('plugins:getSettings', req => ({ values: pluginSettings.get(req.id) }))
  handle('plugins:setSetting', req => { pluginSettings.set(req.id, req.key, req.value); return { values: pluginSettings.get(req.id) } })
  handle('plugins:resetSettings', req => ({ values: pluginSettings.reset(req.id) }))
  handle('plugins:installFromFolder', async req => { const installed = await plugins.installFromFolder(req.path); emit('plugins:changed', { plugins: plugins.list() }); return installed })
  handle('plugins:uninstall', async req => { await plugins.uninstall(req.id); pluginData.remove(req.id); emit('plugins:changed', { plugins: plugins.list() }); return OK })
  const packs = createPackStore({ userDataPath: env().userDataPath, onChanged: () => emit('packs:changed', { packs: packs.list() }) })
  installPluginCatalog({handle,plugins,packs})
  handle('packs:list', () => ({ packs: packs.list() })); handle('packs:importText', req => packs.importText(req.json))
  handle('packs:remove', req => { packs.remove(req.id); return OK }); handle('packs:setEnabled', req => { packs.setEnabled(req.id, req.enabled); return OK })
  // Enabling executable plugin code is supplied by the sandbox runtime; the
  // persistent registry is available independently for metadata/settings.
  learning = installLearning({ db, courses, packs, handle, pathLock: materialPathLock, changed: () => courseChanged(OK), changedMaterials: changed })
  materials.recoverPathChanges()
  learning.paths.schedule()
  const calendarPath = join(env().userDataPath, 'apple-calendar.json')
  const platform = (channel: string, request: unknown) => {
    if (!(globalThis as any).__bandalPlatform?.invoke) unsupported(channel)
    return (globalThis as any).__bandalPlatform.invoke(channel, request)
  }
  const calendar = createAppleCalendarService({ supported: true,
    native: { state: (connect, includeCalendars) => platform('native:calendarState', { connect, includeCalendars }),
      events: input => platform('native:calendarEvents', input), export: input => platform('native:calendarExport', input) },
    load: () => existsSync(calendarPath) ? JSON.parse(readFileSync(calendarPath, 'utf8') as string) : {},
    save: config => writeFileAtomic(calendarPath, JSON.stringify(config)),
    changed: () => emit('appleCalendar:changed', {}), task: id => board.list({ includeDone: true }).find(task => task.id === id) })
  for (const action of ['state', 'connect', 'disconnect', 'configure', 'events'] as const) handle(`appleCalendar:${action}`, req => calendar[action](req))
  handle('appleCalendar:export', req => calendar.exportTask(req.taskId))
  const pdfExport=installPdfExport({ handle, courses, drawings, annotations, canvas, materials, changed, pdfBindings })
  installMarket({handle,courses,materials,annotations,pdfExport:pdfExport.exportAnnotated})
  installPresentation({ handle,courses,drawings,annotations,materials,changed })
  installSync({ handlePrivate, db, courses, materials, notes, drawings, annotations, board, canvas, recordings, learning, pdfBindings })
  installNotifications({ db,handlePrivate })
  installBrowserShortcuts({ handlePrivate })
  handlePrivate('nativeRecording:create', req => recordings.create(req.courseId,req.title,req.modelId))
  handlePrivate('nativeRecording:get', req => recordings.get(req.id))
  handlePrivate('nativeRecording:save', req => recordings.save(req.session))
  handlePrivate('nativeRecording:status', req => recordings.save({ ...recordings.get(req.id),status:req.status,error:req.error ?? null }))
  handlePrivate('nativeRecording:append', req => recordings.append(req.id,req.sequence,req.pcm))
  handlePrivate('nativeRecording:segment', req => recordings.addSegment(req.id,req.startSample,req.endSample,req.text))
  handlePrivate('nativeRecording:commitTranscriptWindow', req => db.transaction(() => {
    const session=recordings.get(req.id)
    const {startSample,endSample,text}=req
    if (!Number.isSafeInteger(startSample)||!Number.isSafeInteger(endSample)||startSample<0||endSample<=startSample||endSample>session.samples||typeof text!=='string'||text.length>1_000_000) throw new Error('Invalid transcript window')
    if (endSample<=session.transcribedSamples) return {session}
    if (startSample!==session.transcribedSamples) throw new Error('Transcript cursor conflict')
    const segment=text.trim()?recordings.addSegment(req.id,startSample,endSample,text):undefined
    const saved=recordings.save({...session,transcribedSamples:endSample,error:null})
    return {session:saved,...(segment?{segment}:{})}
  })())
  handlePrivate('nativeRecording:resetTranscript', req => recordings.resetTranscript(req.id))
  handlePrivate('nativeRecording:replaceTranscript', req => db.transaction(() => {
    const session=recordings.get(req.id)
    if (!Array.isArray(req.segments)||!Number.isInteger(req.transcribedSamples)||req.transcribedSamples<0||req.transcribedSamples>session.samples) throw new Error('Invalid transcript replacement')
    for (const s of req.segments) if (!Number.isInteger(s.startSample)||!Number.isInteger(s.endSample)||s.startSample<0||s.endSample<s.startSample||s.endSample>session.samples||typeof s.text!=='string') throw new Error('Invalid transcript segment')
    recordings.resetTranscript(req.id)
    for (const s of req.segments) recordings.addSegment(req.id,s.startSample,s.endSample,s.text)
    return recordings.save({...session,modelId:req.modelId??session.modelId,transcribedSamples:req.transcribedSamples,status:'complete',error:null})
  })())
  handlePrivate('nativeRecording:audioPath', req => { const session = recordings.get(req.id); return resolveInsideReal(courses.getFolder(session.courseId),session.audioRelPath) })
  handlePrivate('nativeRecording:recover', () => { recordings.recover(); return OK })
  const mcp=installMCP({handle})
  const ai=installAI({ handle, handlePrivate, db, courses, chat, usage, mcp, repositories: { groups, courseLinks, materials, notes, links, favorites, board, canvas, linkService }, invoke: (channel, request) => invoke(channel, request) })
  learning.connectAI?.(ai)
  installStudy({db,courses,materials,canvas,board,activity,linkIndex,packs,ai,handle,changed})
  repositories = { db, courses, groups, materials, notes, annotations, drawings, board, canvas, layout, recordings, learning: learning.repo }
  initialized = true
  return { schemaVersion: migrations.length, supportedChannels: [...handlers.keys()], migration, viewStateMigration }
}

export async function invoke(channel: string, request?: unknown) {
  if (!initialized) initialize()
  const action = handlers.get(channel)
  if (!action) unsupported(channel)
  return wire(await action(unwire(request ?? {})))
}
export async function invokePrivate(channel: string, request?: unknown) {
  if (!initialized) initialize()
  const action = privateHandlers.get(channel)
  if (!action) unsupported(channel)
  return wire(await action(unwire(request ?? {})))
}
// Additional native adapters may register concrete services, never overwrite
// a repository contract silently. Kept off window.bandal's public IPC surface.
;(globalThis as any).BandalBackend = { initialize, invoke, invokePrivate,
  get supportedChannels() { return [...handlers.keys()] },
  get repositories() { if (!initialized) initialize(); return repositories } }
