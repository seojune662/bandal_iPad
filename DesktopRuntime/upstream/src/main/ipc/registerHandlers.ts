import { installIPadCompanion } from '../features/ipadSync/runtime'
import { createStudyMarketClient } from '../features/studyMarket/client'
import { createStudyMarketBundles } from '../features/studyMarket/bundles'
import { registerStudyMarketHandlers } from './studyMarketHandlers'
import { assertAppRendererSender } from './appRendererSender'
import { forgetGoogleAccountNavigation } from '../features/browser/googleAccountNavigation'
import { createLearningRepo, normalizeLearningDraft } from '../features/learning'
import { createLearningApprovalDialogs } from '../features/learning/approvalDialogs'
import { createLearningCache } from '../features/learning/learningCache'
import { createDictionaryService } from '../features/learning/dictionary'
import { createLearningRuntime } from '../features/learning/learningRuntime'
import { sendLearningWithSession, validateConnectedLearningAi } from '../features/learning/learningAgent'
import { rejectAgentModel, resolveLearningAi, validateLearningAi } from '../features/agent/agentModels'
import { createAgentAvailabilityService } from '../features/agent/availability'
import { resolveConversationProvider } from '../features/agent/conversationRouting'
import type { AgentTurnFailure } from '../../shared/types/agent-events'
import { createArticleExtractor, matchArticleWords } from '../features/learning/articleExtractor'
import { createLearningGrounding } from '../features/learning/learningGrounding'
import { registerLearningHandlers } from './learningHandlers'
import { getLegacyPack } from '../../shared/workflowPacks/builtins'
import { assertLiveStudyBrowserSource } from '../features/workflowPacks/browserStudySource'
import { createHash } from 'node:crypto'
import type { MaterialContext, MessageContextSnapshot } from '../../shared/types/chatContext'
import { selectScreen, screenSelectionRequest } from '../windows/screenSelection'
import { DEFAULT_AI_ACCESS, parseAiAccess } from '../../shared/types/aiAccess'
import { appPermissionAllowed } from '../features/agent/accessPolicy'
import { registerBrowserImportHandlers } from './browserImportHandlers'
import { writeFileAtomic, quarantineFile } from '../lib/atomicWrite'
import { createQuitDrain } from '../lib/quitDrain'
import { existsSync, readFileSync } from 'node:fs'
import { initializeBrowserProfiles, listBrowserProfiles, saveBrowserProfile, deleteBrowserProfile, browserProfileResources, guestProfile, onBrowserSession, ensureProfileSession, profileDirectory, onBrowserProfileDeleted } from '../features/browser/profiles'
import { hardenBrowsingSession, useProfilePermissions, forgetProfilePermissions } from '../features/browser/hardenWebviews'
import { browserSessionForTab, prepareProfileSwitch, createBrowserPage, setBrowserPageCourse, setBrowserPageBounds, setBrowserHostOccluded, browserPageAction, destroyBrowserPage, prepareBrowserPageClose, onBrowserQuitCancelled } from '../features/browser/nativeTabs'
import { isManagedBrowserPage } from '../features/browser/managedPages'
import { isCleanBrowserAuthProbe } from '../features/browser/authProbe'
import { beginClipboardCopy, writeImageClipboard } from '../features/systemClipboard'
import { copyFile } from 'node:fs/promises'
import { browsingContext, setBrowsingCourse } from '../features/browser/browsingContext'
import { finishDownloadNavigation } from '../features/browser/popupLifecycle'
import { getDownloadFile } from '../features/browser/downloads'
import { setMaterialMediaHandler } from '../features/materials/mediaRegistration'
import { traceIpc } from '../performanceTrace'
import { createFolderAvailability } from '../features/courses/folderAvailability'
import { createBackgroundClient } from '../background/client'
import { startBackgroundCheckpoints } from '../db/backgroundCheckpoint'
import { createBackgroundMaterialsWatcher } from '../background/materialsWatcher'
import { createAppleCalendar } from '../features/calendar/appleCalendar'
/**
 * Registers a handler for EVERY channel in IpcContract.
 *
 * M1-A: courses / materials / notes / annotations / board / layout are real
 * implementations backed by src/main/features/* repos and the SQLite DB.
 * M4-H added the chat/agent runtime, M5 the materials watcher; the browser
 * runs as a renderer <webview> and needs no invoke channels here. Keep the
 * section comments so merges stay additive.
 */

import { randomUUID } from 'node:crypto'
import { importChatAttachments } from '../features/agent/chatAttachments'
import { collectChatArtifacts, createArtifactFolder } from '../features/agent/chatArtifacts'
import type { CreationKind } from '../../shared/types/chatCapabilities'
import { discoverChatSkills } from '../features/agent/chatSkills'
import { createGmailService } from '../features/mail/gmailService'
import { createPresentationService } from '../features/presentation/presentationService'
import {
  accessSync,
  constants as fsConstants,
  mkdirSync,
  writeFileSync
} from 'node:fs'
import { release, tmpdir } from 'node:os'
import { basename, extname, join } from 'node:path'
import {
  app,
  BrowserWindow,
  desktopCapturer,
  dialog,
  ipcMain,
  nativeImage,
  net,
  Notification,
  powerMonitor,
  session,
  shell,
  systemPreferences,
  webContents
} from 'electron'
import type { NativeImage } from 'electron'
import { IPC_CHANNELS } from '../../shared/ipc/contract'
import { resolveInside } from '../db/validate'
import { matchCourseByUrl } from '../../shared/universities/matchCourseByUrl'
import { resolveUniversity } from '../../shared/universities'
import type { LmsPlatform } from '../../shared/types/university'
import { TARGET_INDEX_SOURCE } from '../features/browserAgent/snapshot'
import {
  createAuditRepo,
  createBrowserTools,
  createGrantsRepo,
  createGuestRegistry,
  createPageSurface,
  createRunRegistry,
  createConversationRunScope,
  insertText,
  setFileInputFiles,
  createSeenRepo,
  GenerationTracker
} from '../features/browserAgent'
import type { IpcChannel, IpcRequest, IpcResponse } from '../../shared/ipc/contract'
import type { PushChannel, PushPayload } from '../../shared/ipc/events'
import type { AgentAppState } from '../../shared/types/agentTools'
import type {
  AgentProvider,
  TurnStopReason,
  Usage
} from '../../shared/types/agent-events'
import { isUsageWindowDays } from '../../shared/types/usage'
import type { ScreenPermissionState } from '../../shared/types/screenCapture'
import { isSystemPermissionId } from '../../shared/types/permissions'
import type { Settings, SettingsPatch } from '../../shared/types/settings'
import {
  getSettings,
  resetSettings,
  setSettings as persistSettings
} from '../settingsStore'
import { getDatabase } from '../db/database'
import { createLayoutRepo } from '../db/layoutRepo'
import {
  createCourseGroupsRepo,
  createCourseLinksRepo,
  createCoursesRepo,
  folderDisplayName,
  normalizeFolderPath
} from '../features/courses'
import { normalizeHttpUrl } from '../../shared/universities/courseLink'
import { isTabDescriptor } from '../../shared/tabs'
import { ValidationError } from '../db/errors'
import { PRINT_PDF_MAX_BYTES, printPdfBytes } from '../features/print'
import { setPrintMenuEnabled } from '../menu'
import {
  createMaterialsRepo,
  createMediaProgressRepo,
  createMediaProtocolHandler
} from '../features/materials'
import { DRAG_ICON_PNG_BASE64 } from './dragIcon'
import { createMaterialHoverPreviewService } from '../features/materials/hoverPreview'
import { createPdfViewStateRepo } from '../features/pdf/pdfViewStateRepo'
import { createNotesRepo } from '../features/notes'
import { createRecordingRepo } from '../features/recordings/recordingRepo'
import { createModelManager } from '../features/recordings/modelManager'
import { createRecordingService } from '../features/recordings/recordingService'
import { speechModel } from '../features/recordings/modelCatalog'
import { getMainWindow, onMainWindowClosed } from '../windows/mainWindow'
import { createAnnotationsRepo } from '../features/annotations'
import { createDrawingsRepo, createPdfExporter } from '../features/pdf'
import { createBoardRepo } from '../features/board'
import {
  createBinaryLocator,
  createChatRepo,
  createClaudeCodeAdapter,
  createEventBatcher,
  createSessionManager,
  createCodexAdapter,
  createCodexBinaryLocator,
  createGeminiAdapter,
  createGeminiBinaryLocator,
  createAgentInstaller,
  createLoginLauncher,
  killAllCodexProcessesSync,
  killAllGeminiProcessesSync,
  getAgentModels,
  killAllClaudeProcessesSync,
  serializeTranscript,
  CARRYOVER_HISTORY_LIMIT
} from '../features/agent'
import { createGeminiApiKeyStore } from '../features/agent/geminiApiKeyStore'
import { createUsageRepo } from '../features/usage/usageRepo'
import { runtimeSafeStorage } from '../lib/safeStorageGate'
import {
  attachDownloadHandler,
  BROWSING_PARTITION,
  createBrowserExtensionManager,
  downloadControls,
  createPermissionsRepo,
  useSitePermissions,
  createFaviconFetcher,
  createHistoryRepo,
  fetchLinkForMaterials
} from '../features/browser'
import { createFavoritesRepo } from '../features/favorites'
import {
  createLoginCapturer,
  createLoginFiller
} from '../features/credentials'
import { createActivityRepo, createContextWriter } from '../features/context'
import {
  createPackRunner,
  createPackRunGuard,
  createPackStore
} from '../features/workflowPacks'
import { createBoardPdfExporter, createCanvasRepo } from '../features/canvas'
import { createInsights } from '../features/insights'
import { createLinkService } from '../features/link'
import { createLinkIndex } from '../features/links'
import { createMaterialLinksRepo } from '../features/links/materialLinksRepo'
import { repointMaterialPath } from '../features/links/renameRepoint'
import { createAccountRuntime } from '../features/account/accountRuntime'
import { isAuthCallbackUrl } from '../features/account/authCallbackUrl'
import {
  createFeedbackRateGuard,
  createFeedbackService
} from '../features/feedback/feedbackService'
import { createUpdaterRuntime, resolveAppVersion } from '../features/updater'
import {
  createAgentConfirmer,
  createAgentJournal,
  parseMaterialEditTargetId,
  restoreMaterialBackup,
  startAgentToolsServer
} from '../features/agentTools'
import {
  createDesktopAuditRepo,
  createDesktopGrantsRepo,
  createDesktopRunRegistry,
  createDesktopSurface,
  createDesktopTools,
  createElectronDesktopDeps,
  type ScreenAccess
} from '../features/desktopAgent'
import { createMcpRegistry, testMcpServer } from '../features/mcpRegistry'
import { isMethodAllowed } from '../../shared/plugins/permissions'
import { createPluginApi } from '../features/plugins/pluginApi'
import { createPluginDataStore } from '../features/plugins/pluginDataStore'
import { createPluginSettings } from '../features/plugins/pluginSettings'
import { createPluginEditorBridge } from '../features/plugins/pluginEditor'
import { createPluginDevelopment } from '../features/plugins/pluginDevelopment'
import { createMarketplaceClient, marketplaceUrl } from '../features/plugins/marketplaceClient'
import { readFile, stat } from 'node:fs/promises'
import { inspectPluginArchive } from '../../shared/plugins/archive'
import { createPluginLog } from '../features/plugins/pluginLog'
import {
  configurePluginPanels,
  postPluginPanelMessage
} from '../features/plugins/pluginPanels'
import { createPluginRateLimiter } from '../features/plugins/rateLimit'
import { createPluginRuntime } from '../features/plugins/pluginRuntime'
import { createPluginStore } from '../features/plugins/pluginStore'
import { createCatalogService } from '../features/plugins/catalog/catalogService'
import { createCatalogInstaller } from '../features/plugins/catalog/catalogInstall'
import { createSystemPermissions } from '../features/permissions/systemPermissions'
import { createDiagnosticsBundle } from '../features/diagnostics/diagnosticsBundle'
import {
  createDeadlineScheduler,
  createSystemNotifier
} from '../features/notifications'
import {
  createMiniPlayerController,
  type MiniPlayerController
} from '../windows/miniPlayerController'

/**
 * What `registerHandlers` hands back to `main/index.ts`.
 *
 * Deep links cannot go through `ipcMain` — they arrive from the OS, not the
 * renderer — so this is the one seam that lets `index.ts` reach the group
 * runtime without owning it.
 */
export interface IpcRouter {
  /** Routes a `bandal://` URL. Fire-and-forget; never throws. */
  handleDeepLink(url: string): void
  miniPlayer: MiniPlayerController
}

export interface RegisterHandlersDeps {
  /** Bootstrap wrapper that fans persisted settings changes out to main UI. */
  setSettings?: (patch: SettingsPatch) => Settings
  preloadPath: string
  pluginPanelPreloadPath: string
  userDataPath: string
  windowBackground(): string
  openMaterial(payload: PushPayload<'ui:openMaterial'>): void
  openUrl(payload: PushPayload<'ui:openUrl'>): void
  openInTab(url: string): void
  consumePendingOpen(): IpcResponse<'ui:consumePendingOpen'>
  onMiniPlayerStateChanged?(open: boolean): void
}

/**
 * Contract-typed wrapper around ipcMain.handle. Logs failures with channel
 * context, then rethrows so the renderer receives a rejected promise.
 */
const registered = new Set<IpcChannel>()

/**
 * Boot-time guard: every contract channel must have a handler.
 *
 * `handle()` type-checks each registration individually, but nothing tied the
 * SET of registrations to the contract — a declared-but-unhandled channel
 * compiled fine and only failed in the user's hands with "No handler
 * registered for ...". This runs before the window is created, so the gap
 * becomes a loud startup failure instead of one broken button.
 */
function assertEveryChannelHandled(): void {
  const missing = IPC_CHANNELS.filter((channel) => !registered.has(channel))
  if (missing.length > 0) {
    throw new Error(
      `[ipc] ${missing.length} channel(s) declared in IpcContract have no handler: ${missing.join(', ')}`
    )
  }
}

function handle<K extends IpcChannel>(
  channel: K,
  fn: (req: IpcRequest<K>, event: Electron.IpcMainInvokeEvent) => Promise<IpcResponse<K>> | IpcResponse<K>
): void {
  registered.add(channel)
  ipcMain.handle(channel, async (_event, req: IpcRequest<K>) => {
    assertAppRendererSender(_event)
    const start = performance.now()
    try {
      return await fn(req, _event)
    } catch (error) {
      if (channel === 'browser:pageAction') console.error('[ipc] Browser action failed')
      else console.error(`[ipc] ${channel} failed:`, error)
      throw error
    } finally { traceIpc(channel, performance.now() - start) }
  })
}

const OK = { ok: true } as const

/**
 * [드래그아웃] startDrag 는 드래그 제스처와 같은 틱에 동기로 불러야 한다 —
 * app.getFileIcon 을 기다렸다가 부르면 제스처가 끝나 드래그가 조용히 죽는다.
 * 그래서 인라인 PNG 기본 아이콘으로 즉시 시작하고, 진짜 파일 아이콘은
 * 드래그 시작 "후" 비동기로 받아 확장자별 캐시에 채워 다음 드래그에 쓴다.
 *
 * 주의: startDrag 는 빈 이미지에 throw 하므로 폴백은 반드시 디코드 가능한
 * PNG 여야 한다 (tests/main/dragIcon.test.ts 가 상수를 검증한다).
 */
const FALLBACK_DRAG_ICON = nativeImage.createFromBuffer(
  Buffer.from(DRAG_ICON_PNG_BASE64, 'base64')
)
const dragIconCache = new Map<string, NativeImage>()

/**
 * How long quitting waits for in-flight IPC to land. Long enough for a message
 * already on the wire, short enough that ⌘Q still feels instant.
 */
const QUIT_DRAIN_MS = 150

/** Sends a push event to every open window. */
export function broadcast<K extends PushChannel>(
  channel: K,
  payload: PushPayload<K>
): void {
  for (const win of BrowserWindow.getAllWindows()) {
    if (win.isDestroyed() || win.webContents.isDestroyed()) continue
    try {
      win.webContents.send(channel, payload)
    } catch (error) {
      // One closing/broken window must not prevent the remaining windows from
      // receiving the event or turn a successful mutation into an IPC failure.
      console.error(`[ipc] ${channel} broadcast failed:`, error)
    }
  }
}

function screenPermissionState(access: ScreenAccess): ScreenPermissionState {
  if (access === 'granted') return 'granted'
  if (access === 'denied' || access === 'restricted') return 'denied'
  if (access === 'not-determined') return 'unknown'
  if (process.platform === 'win32') return 'granted'
  return 'unsupported'
}

export function registerHandlers(deps: RegisterHandlersDeps): IpcRouter {
  const mail = createGmailService(app.getPath('userData'))
  handle('mail:state', () => mail.state())
  handle('mail:connect', () => mail.connect())
  handle('mail:cancelConnect', () => { mail.cancelConnect(); return OK })
  handle('mail:disconnect', async () => { await mail.disconnect(); return OK })
  handle('mail:list', (req) => mail.list(req))
  handle('mail:read', (req) => mail.read(req.id))
  handle('mail:modify', async (req) => { await mail.modify(req); return OK })
  handle('mail:reply', async (req) => { await mail.reply(req); return OK })
  const db = getDatabase()
  const usageRepo = createUsageRepo(db)
  const setSettings = deps.setSettings ?? persistSettings
  const notifier = createSystemNotifier(getSettings)
  const desktopGrants = createDesktopGrantsRepo(db)
  const desktopAudit = createDesktopAuditRepo(db)
  const desktopRun = createDesktopRunRegistry({
    emit: (payload) => broadcast('desktopAgent:run-state', payload)
  })
  const desktopSurface = createDesktopSurface(
    createElectronDesktopDeps()
  )
  const mcpRegistry = createMcpRegistry({
    safeStorage: runtimeSafeStorage(),
    userDataPath: app.getPath('userData')
  })
  const coursesRepo = createCoursesRepo({
    db,
    folderMissing: createFolderAvailability(() => broadcast('courses:changed', {})),
    getDataRoot: () => getSettings().dataRoot
  })
  const legacyPackSettlers = new Map<string, { resolve(): void; reject(error: Error): void }>()
  const legacyGuardSessions = new Map<string, string>()
  const settleStudyTurn = (info: { sessionId: string; reason: 'success' | 'error' | 'interrupted'; error?: AgentTurnFailure }): void => {
    void learningRuntime?.settle(info.sessionId, info.reason, info.error)
    const pending = legacyPackSettlers.get(info.sessionId)
    if (pending) {
      legacyPackSettlers.delete(info.sessionId)
      if (info.reason === 'success') pending.resolve()
      else pending.reject(new Error(info.error?.message ?? (info.reason === 'error' ? 'AI 학습 작업에 실패했습니다.' : 'AI 학습 작업이 중단되었습니다.')))
    }
  }
  let learningRuntime: ReturnType<typeof createLearningRuntime> | undefined
  const learningCache = createLearningCache(db)
  const dictionary = createDictionaryService({ directory: app.isPackaged
    ? join(process.resourcesPath, 'dictionary') : join(__dirname, '../../resources/dictionary') })
  const learningRepo = createLearningRepo({
    getCourseFolder: courseId => coursesRepo.getFolder(courseId),
    getCourseFolderIncludingDeleted: courseId => coursesRepo.getFolderIncludingDeleted(courseId),
    listCourseIds: () => coursesRepo.list({ includeArchived: true, includeDeleted: true }).filter(course => !course.deletedAt || course.workspaceKind === 'study-space').map(course => course.id),
    onChanged: binding => {
      broadcast('learning:changed', { binding })
      materialsRepo.invalidateTree(binding.courseId)
      broadcast('materials:changed', { courseId: binding.courseId })
      void learningRepo.readDeleted(binding).then(snapshot => learningCache.index(snapshot)).catch(error => console.warn('[learning] cache rebuild failed', error))
    }
  })
  const onMaterialPathChanged = (change: {
    courseId: string
    fromRelPath: string
    toRelPath: string
    isDirectory: boolean
  }): void => {
    materialsRepo.repointAddedState(change.courseId, change.fromRelPath, change.toRelPath, change.isDirectory)
    repointMaterialPath({
      ...change,
      db,
      courseFolder: coursesRepo.getFolder(change.courseId)
    })
    recordings.repoint(change.courseId, change.fromRelPath, change.toRelPath, change.isDirectory)
    void learningRepo.repoint(change).catch(error => console.error('[learning] path update failed', error))
    // Notes bypass materialsRepo, and a rewritten backlink can change more
    // than the renamed path. Invalidate before telling renderers to re-read.
    materialsRepo.invalidateTree(change.courseId)
    broadcast('materials:changed', { courseId: change.courseId })
  }
  const background = createBackgroundClient()
  const checkpoints = startBackgroundCheckpoints(db,
    () => background.request('checkpoint', { dbPath: db.name }, 3),
    error => console.warn('[db] background checkpoint failed', error))
  app.once('will-quit', () => checkpoints.dispose())
  // Derived search writes must never hold the user database's write lock.
  const searchCachePath = join(deps.userDataPath, 'search-cache.db')
  const materialsRepo = createMaterialsRepo({
    onIndexBuilt: checkpoints.request,
    scan: (folder, limits) => background.request('scan', { folder, limits }),
    db,
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    revealItem: (absPath) => shell.showItemInFolder(absPath),
    // Trash, never unlink: these are the student's lecture materials and a
    // mis-click must stay recoverable.
    trashItem: (absPath) => shell.trashItem(absPath),
    pauseWatching: (courseId) => materialsWatcher.pause(courseId),
    onPathChanged: onMaterialPathChanged
  })
  const hoverPreview = createMaterialHoverPreviewService({ materials: materialsRepo, userData: deps.userDataPath })
  app.once('will-quit', () => hoverPreview.dispose())
  const notesRepo = createNotesRepo({
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    onCreated: ({ courseId, relPath }) => materialsRepo.recordAdded(courseId, relPath),
    onPathChanged: onMaterialPathChanged
  })
  const recordings = createRecordingRepo(db, (id) => coursesRepo.getFolder(id), session => materialsRepo.recordAdded(session.courseId, session.audioRelPath))
  const speechModels = createModelManager(
    join(deps.userDataPath, 'speech-models'),
    (models) => broadcast('recordings:modelsChanged', models)
  )
  const recordingService = createRecordingService({
    repo: recordings,
    models: speechModels,
    hostEntry: join(__dirname, 'speechHost.js'),
    emit: (event) => broadcast('recordings:event', event),
    onActivityChanged: (active, session) => {
      getMainWindow()?.webContents.setBackgroundThrottling(!active)
      if (!active) {
        materialsRepo.invalidateTree(session.courseId)
        broadcast('materials:changed', { courseId: session.courseId })
      }
    }
  })
  handle('recordings:models', () => speechModels.list())
  handle('recordings:downloadModel', (req) => {
    speechModel(req.modelId)
    void speechModels.download(req.modelId)
    return OK
  })
  handle('recordings:cancelDownload', (req) => {
    speechModels.cancel(req.modelId)
    return OK
  })
  handle('recordings:list', (req) => recordings.list(req.courseId))
  handle('recordings:resolve', (req) => recordings.resolve(req.courseId, req.relPath))
  handle('recordings:create', (req) => recordings.create(req.courseId, req.title, req.modelId))
  handle('recordings:read', (req) => recordings.read(req.id, req.afterId))
  handle('recordings:control', (req) => recordingService.control(req.id, req.action, req.modelId))
  handle('recordings:append', (req) => recordingService.append(req.id, req.sequence, req.pcm))
  handle('recordings:anchor', (req) =>
    recordings.anchor(req.id, req.label, req.relPath, req.page, req.sample)
  )
  handle('recordings:export', (req) => {
    const recording = recordings.get(req.id)
    const note = notesRepo.create({
      courseId: recording.courseId,
      dirRelPath: '',
      title: `${recording.title} · 강의 기록`
    })
    notesRepo.write({ ...note, markdown: recordings.markdown(req.id) })
    materialsRepo.invalidateTree(recording.courseId)
    broadcast('materials:changed', { courseId: recording.courseId })
    return note
  })
  powerMonitor.on('suspend', () =>
    recordingService.interrupt('컴퓨터가 잠자기에 들어가 녹음이 중단되었습니다. 저장된 원음은 보존됩니다.')
  )
  onMainWindowClosed(() =>
    recordingService.interrupt('녹음 창이 닫혔습니다. 저장된 음성에서 다시 자막을 생성할 수 있어요.')
  )
  powerMonitor.on('thermal-state-change', (detail) =>
    recordingService.setThermalState(detail.state)
  )
  if (process.platform === 'darwin')
    recordingService.setThermalState(powerMonitor.getCurrentThermalState())
  // A browser page can cancel quit. Keep services usable until all windows accept.
  app.on('will-quit', () => recordingService.dispose())
  const courseLinksRepo = createCourseLinksRepo(db)
  const materialLinksRepo = createMaterialLinksRepo(db)
  const annotationsRepo = createAnnotationsRepo(db)
  const boardRepo = createBoardRepo(db)
  const layoutRepo = createLayoutRepo(db)
  const deadlineScheduler = createDeadlineScheduler({
    db,
    getSettings,
    setSettings,
    notifier,
    onError: (error) => console.error('[notifications] deadline scheduler failed', error)
  })
  // Plugin event producers are registered before the runtime is constructed.
  // Keeping this indirection local avoids moving the long-established course
  // and note handlers merely to satisfy initialization order.
  let emitPluginEvent: (
    name: import('../../shared/types/pluginRpc').PluginEventName,
    payload: unknown
  ) => void = () => undefined

  const materialsWatcher = createBackgroundMaterialsWatcher({
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    ignoreContentChange: (courseId, relPath) => {
      const active = recordingService.getActiveSession()
      return active?.courseId === courseId && active.audioRelPath === relPath
    },
    onChange: (courseId) => {
      // 브로드캐스트보다 먼저 캐시를 비운다 — 렌더러의 조용한 재조회가
      // 반드시 새 트리를 보게 하기 위한 순서다.
      materialsRepo.invalidateTree(courseId)
      refreshSearch(courseId)
      broadcast('materials:changed', { courseId })
    }
  })

  // [bandal-media] 동영상 스트리밍 프로토콜. 스킴 특권 등록은 index.ts 가
  // whenReady 전에 마쳤고, 핸들러는 materialsRepo 의 경로 가드를 재사용하므로
  // 여기(레포 생성 직후)에서 등록한다. registerHandlers 는 앱당 한 번 불린다.
  setMaterialMediaHandler(
    createMediaProtocolHandler({
      absolutePathFor: (courseId, relPath) =>
        materialsRepo.absolutePathForAsync(courseId, relPath)
    })
  )

  /** Course went away (delete/archive) → release its live resources. */
  function releaseCourseRuntime(courseId: string): void {
    if (recordingService.getActiveSession()?.courseId === courseId)
      recordingService.interrupt('과목이 닫혀 녹음을 중단했습니다. 저장된 음성은 과목 폴더에 남아 있습니다.')
    materialsWatcher.unwatch(courseId)
    const watchedIndex = watchedCourses.indexOf(courseId)
    if (watchedIndex >= 0) watchedCourses.splice(watchedIndex, 1)
    // Sessions are conversation-keyed now: close every conversation of the
    // course on all managers (only ones with messages can hold a warm CLI).
    for (const conversation of chatRepo.listConversations(courseId)) {
      sessionManager.close(courseId, conversation.id)
      codexSessionManager.close(courseId, conversation.id)
      geminiSessionManager.close(courseId, conversation.id)
      eventBatcher.flush(conversation.id)
    }
  }

  // -- courses --------------------------------------------------------------
  handle('courses:list', (req) => coursesRepo.list(req))
  /**
   * Broadcast on every course mutation, not just the agent's.
   * Two windows can be open, and the assistant can now change the list from
   * outside whichever one the student is looking at.
   */
  function courseListChanged<T>(result: T): T {
    broadcast('courses:changed', {})
    emitPluginEvent('course:changed', {})
    return result
  }
  handle('courses:create', (req) => courseListChanged(coursesRepo.create(req)))
  handle('courses:pickFolder', async () => {
    const parent = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
    const options: Electron.OpenDialogOptions = {
      title: '과목 폴더 선택',
      buttonLabel: '이 폴더 사용',
      properties: ['openDirectory', 'createDirectory']
    }
    const result =
      parent === undefined
        ? await dialog.showOpenDialog(options)
        : await dialog.showOpenDialog(parent, options)
    const picked = result.filePaths[0]
    if (result.canceled || picked === undefined) return null
    const path = normalizeFolderPath(picked)
    return { path, name: folderDisplayName(path) }
  })
  handle('courses:addFromFolder', (req) =>
    courseListChanged(coursesRepo.addFromFolder(req))
  )
  handle('courses:relink', (req) => {
    const result = coursesRepo.relink(req)
    if (result.status === 'ok') {
      // The folder (and therefore the agent cwd) moved — drop everything that
      // was bound to the old path so the next watch/chat attaches to the new one.
      releaseCourseRuntime(req.courseId)
      return courseListChanged(result)
    }
    return result
  })
  handle('courses:rename', (req) => {
    const course = courseListChanged(coursesRepo.rename(req))
    return course
  })
  handle('courses:setColor', (req) =>
    courseListChanged(coursesRepo.setColor(req))
  )
  handle('courses:archive', (req) => {
    const course = coursesRepo.archive(req)
    if (req.archived) releaseCourseRuntime(req.courseId)
    return courseListChanged(course)
  })
  handle('courses:purge', async (req) => {
    const { folderPath } = coursesRepo.purge(req)
    // Trash, never unlink: even the tutorial's own folder stays recoverable.
    // The DB row removal above is the invariant; a trash failure only logs.
    try {
      await shell.trashItem(folderPath)
    } catch (error) {
      console.error('[courses] purge trash failed', error)
    }
    return courseListChanged(OK)
  })
  handle('courses:delete', (req) => {
    const result = coursesRepo.softDelete(req)
    releaseCourseRuntime(req.courseId)
    return courseListChanged(result)
  })
  // 한 번의 드래그 = 한 번의 원자적 호출 (소속 + 위치). 갱신된 전체 목록을
  // 돌려주고, 다른 창을 위해 courses:changed 도 쏜다.
  handle('courses:organize', (req) => courseListChanged(coursesRepo.organize(req)))

  // -- course groups (과목 그룹/학기) ----------------------------------------
  const courseGroupsRepo = createCourseGroupsRepo(db)
  handle('courseGroups:list', () => courseGroupsRepo.list())
  handle('courseGroups:create', (req) =>
    courseListChanged(courseGroupsRepo.create(req))
  )
  handle('courseGroups:rename', (req) =>
    courseListChanged(courseGroupsRepo.rename(req))
  )
  // 그룹 삭제는 멤버 과목의 groupId 를 NULL로 되돌릴 뿐, 과목은 지우지 않는다.
  handle('courseGroups:delete', (req) =>
    courseListChanged(courseGroupsRepo.delete(req))
  )

  // -- course links (M8) ----------------------------------------------------
  handle('courseLinks:list', (req) => courseLinksRepo.list(req))
  handle('courseLinks:create', (req) => courseLinksRepo.create(req))
  handle('courseLinks:update', (req) => courseLinksRepo.update(req))
  handle('courseLinks:delete', (req) => courseLinksRepo.delete(req))

  // -- authored material links ---------------------------------------------
  handle('links:create', (req) => {
    const result = materialLinksRepo.create({
      ...req,
      label: req.label ?? ''
    })
    broadcast('materials:changed', { courseId: req.courseId })
    return result
  })
  handle('links:remove', (req) => {
    const result = materialLinksRepo.remove(req.courseId, req.id)
    broadcast('materials:changed', { courseId: req.courseId })
    return result
  })
  handle('links:updatePageNote', (req) => {
    return materialLinksRepo.updateMetadata(
      req.courseId,
      req.id,
      req.metadata
    )
  })
  handle('links:listFor', (req) =>
    materialLinksRepo.listFor(req.courseId, req.relPath)
  )
  handle('links:listForDescriptor', (req) => {
    if (!isTabDescriptor(req.descriptor)) {
      throw new ValidationError('descriptor must be a TabDescriptor')
    }
    return materialLinksRepo.listForDescriptor(req.courseId, req.descriptor)
  })
  handle('links:graph', (req) => ({
    links: materialLinksRepo.listAll(req.courseId),
    backlinks: linkIndex.allForCourse(req.courseId)
  }))

  // -- shell ----------------------------------------------------------------
  // Re-validated here rather than trusted from the renderer: this is the one
  // channel that hands a URL to the OS, so anything but http(s) is refused.
  handle('shell:openExternal', async (req) => {
    const url = normalizeHttpUrl(req.url)
    if (url === null) {
      throw new ValidationError('url must be an http(s) URL')
    }
    await shell.openExternal(url)
    return OK
  })

  // -- materials ------------------------------------------------------------
  handle('materials:snapshot', (req) => ({ tree: materialsRepo.snapshot(req.courseId) }))
  handle('materials:tree', (req) => materialsRepo.tree(req.courseId))
  handle('materials:search', (req) => materialsRepo.search(req.courseId, req.query))
  handle('materials:import', (req) => {
    const result = materialsRepo.import(req.courseId, req.paths, req.dirRelPath)
    note(req.courseId, 'material-added', `자료 ${req.paths.length}개를 가져왔습니다.`)
    return result
  })
  // 이동 후 트리 갱신은 폴더 watcher 가 materials:changed 로 밀어준다.
  handle('materials:move', async (req) => await materialsRepo.move(req))
  handle('materials:reveal', (req) => materialsRepo.reveal(req.courseId, req.relPath))
  handle('materials:preview', (req) => {
    // 앱이 렌더링하지 못하는 형식(.ppt 등) — macOS 는 Quick Look, 그 외는
    // 기본 앱. 경로 가드는 absolutePathFor(assertRealInside)가 담당한다.
    const abs = materialsRepo.absolutePathFor(req.courseId, req.relPath)
    if (process.platform === 'darwin') {
      const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
      win?.previewFile(abs, basename(abs))
    } else {
      void shell.openPath(abs)
    }
    return OK
  })
  handle('materials:readFile', (req) => materialsRepo.readFile(req.courseId, req.relPath))
  handle('materials:hoverPreview', (req) => hoverPreview.read(req))
  handle('materials:writeFile', (req) => materialsRepo.writeFile(req))
  handle('materials:rename', async (req) => await materialsRepo.rename(req))
  handle('materials:delete', (req) => materialsRepo.softDelete(req))
  handle('materials:duplicate', (req) => materialsRepo.duplicate(req))
  handle('materials:createFolder', (req) => materialsRepo.createFolder(req))
  // invoke 계약 밖의 fire-and-forget: startDrag 는 이벤트의 sender 가 필요하다.
  // 자료 행을 끌면 진짜 OS 파일 드래그가 되어 웹뷰 안의 업로드 폼(메일 첨부,
  // 과제 제출)이 일반 파일처럼 받는다.
  ipcMain.on('materials:startDrag', (event, req: unknown) => {
    try {
      assertAppRendererSender(event)
      const record = req as { courseId?: unknown; relPath?: unknown }
      if (
        typeof record?.courseId !== 'string' ||
        typeof record?.relPath !== 'string'
      ) {
        return
      }
      const abs = materialsRepo.absolutePathFor(record.courseId, record.relPath)
      // e2e 가드: 합성 dragstart 로 발동된 startDrag 는 macOS 에서 중첩
      // 런루프에 걸려 앱 종료(close)를 영영 막을 수 있다 — 테스트에서는
      // 드래그 상태 기록(renderer 쪽)만으로 충분하다.
      if (process.env['BANDAL_DISABLE_NATIVE_DRAG'] === '1') return
      // 동기 호출이 핵심 — await/then 을 거치면 드래그 제스처가 죽는다.
      const ext = extname(abs).toLowerCase()
      const icon = dragIconCache.get(ext) ?? FALLBACK_DRAG_ICON
      event.sender.startDrag({ file: abs, icon })
      // 다음 드래그를 위한 캐시 채우기 — 이번 드래그에는 관여하지 않는다.
      if (!dragIconCache.has(ext)) {
        void app
          .getFileIcon(abs, { size: 'normal' })
          .then((fileIcon) => {
            if (!fileIcon.isEmpty()) dragIconCache.set(ext, fileIcon)
          })
          .catch((error: unknown) => {
            console.error('[materials] startDrag icon cache failed', error)
          })
      }
    } catch (error) {
      console.error('[materials] startDrag failed', error)
    }
  })
  handle('materials:downloadFromUrl', async (req, event) => {
    const { fileName, dataBase64 } = await fetchLinkForMaterials(req.url, browserSessionForTab(event, req.tabId))
    return materialsRepo.writeFile({
      courseId: req.courseId,
      dirRelPath: req.dirRelPath,
      fileName,
      encoding: 'base64',
      data: dataBase64
    })
  })
  const watchedCourses: string[] = []
  handle('materials:watch', (req) => {
    const previous = watchedCourses.indexOf(req.courseId)
    if (previous >= 0) watchedCourses.splice(previous, 1)
    else materialsRepo.invalidateTree(req.courseId)
    watchedCourses.push(req.courseId)
    materialsWatcher.watch(req.courseId)
    while (watchedCourses.length > 3) materialsWatcher.unwatch(watchedCourses.shift()!)
    refreshSearch(req.courseId)
    return OK
  })
  // Keep the last three folders watched, matching retained workspaces. This
  // avoids rescanning a warm course and still observes external edits there.
  handle('materials:unwatch', () => OK)


  // -- notes ----------------------------------------------------------------
  // 필기는 notesRepo 가 과목 폴더에 직접 쓰므로 자료 트리 캐시를 여기서
  // 무효화한다 (materialsRepo 변이는 스스로 무효화한다).
  handle('notes:read', (req) => notesRepo.read(req))
  handle('notes:write', (req) => {
    const result = notesRepo.write(req)
    materialsRepo.invalidateTree(req.courseId)
    note(req.courseId, 'note-edited', `필기를 수정했습니다: ${req.relPath}`, req.relPath)
    emitPluginEvent('note:saved', {
      courseId: req.courseId,
      relPath: req.relPath
    })
    return result
  })
  handle('notes:rename', async (req) => {
    const result = await notesRepo.rename(req)
    materialsRepo.invalidateTree(req.courseId)
    broadcast('materials:changed', { courseId: req.courseId })
    emitPluginEvent('note:saved', {
      courseId: req.courseId,
      relPath: result.relPath
    })
    return result
  })
  handle('notes:create', (req) => {
    const result = notesRepo.create(req)
    materialsRepo.invalidateTree(req.courseId)
    note(req.courseId, 'note-created', `필기를 만들었습니다: ${result.relPath}`, result.relPath)
    emitPluginEvent('note:saved', {
      courseId: req.courseId,
      relPath: result.relPath
    })
    return result
  })

  // -- annotations ----------------------------------------------------------
  handle('annotations:listForFile', (req) => annotationsRepo.listForFile(req))
  handle('annotations:create', (req) => {
    const result = annotationsRepo.create(req)
    // The quote is the single best signal of what the student found important.
    note(
      req.courseId,
      'highlight-created',
      `${req.relPath} ${req.page}쪽을 강조했습니다: "${req.anchor.quote}"`,
      req.relPath
    )
    return result
  })
  handle('annotations:update', (req) => annotationsRepo.update(req))
  handle('annotations:delete', (req) => annotationsRepo.softDelete(req))

  // -- pdf drawings (M9: free-form markup, kept apart from text highlights) --
  const drawingsRepo = createDrawingsRepo(db)
  handle('drawings:listForFile', (req) =>
    drawingsRepo.listForFile(req.courseId, req.relPath)
  )
  handle('drawings:create', (req) => drawingsRepo.create(req))
  handle('drawings:update', (req) => drawingsRepo.update(req))
  handle('drawings:delete', (req) => {
    drawingsRepo.softDelete(req.ids)
    return OK
  })

  // -- media progress (M18: 영상 이어보기) ----------------------------------
  const mediaProgressRepo = createMediaProgressRepo(db)
  const pdfViewStateRepo = createPdfViewStateRepo(db)
  handle('media:getProgress', (req) =>
    mediaProgressRepo.get(req.courseId, req.relPath)
  )
  handle('media:setProgress', (req) => mediaProgressRepo.set(req))
  handle('pdf:getViewState', (req) =>
    pdfViewStateRepo.get(req.courseId, req.relPath)
  )
  handle('pdf:setViewState', (req) => pdfViewStateRepo.set(req))

  handle('ui:consumePendingOpen', () => deps.consumePendingOpen())

  // -- picture-in-picture ---------------------------------------------------
  const miniPlayer = createMiniPlayerController({
    preloadPath: deps.preloadPath,
    userDataPath: deps.userDataPath,
    windowBackground: deps.windowBackground,
    broadcast: (channel, payload) => {
      broadcast(channel, payload)
      if (channel === 'pip:state') {
        deps.onMiniPlayerStateChanged?.(
          (payload as PushPayload<'pip:state'>).open
        )
      }
    },
    openMaterial: deps.openMaterial,
    openUrl: deps.openUrl,
    openInTab: deps.openInTab
  })
  handle('pip:open', (req) => {
    miniPlayer.open(req)
    return OK
  })
  handle('pip:close', () => {
    miniPlayer.close()
    return OK
  })
  handle('pip:restore', () => {
    miniPlayer.restore()
    return OK
  })
  handle('pip:getState', () => miniPlayer.getState())
  handle('pip:report', (req) => {
    miniPlayer.report(req)
    const state = miniPlayer.getState()
    if (state.source?.kind === 'local') {
      const previous = mediaProgressRepo.get(
        state.source.courseId,
        state.source.relPath
      )
      mediaProgressRepo.set({
        courseId: state.source.courseId,
        relPath: state.source.relPath,
        positionSec: state.positionSec,
        durationSec: previous?.durationSec ?? null,
        playbackRate: state.playbackRate
      })
    }
    return OK
  })
  handle('pip:moveBy', (req) => {
    miniPlayer.moveBy(req.dx, req.dy)
    return OK
  })

  // Export burns markup into a NEW file — the source pdf is never written to.
  const pdfExporter = createPdfExporter({
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    listDrawings: (courseId, relPath) =>
      drawingsRepo.listForFile(courseId, relPath),
    listAnnotations: (courseId, relPath) =>
      annotationsRepo.listForFile({ courseId, relPath })
  })
  const presentations = createPresentationService({
    userData: app.getPath('userData'), materials: materialsRepo, exporter: pdfExporter,
    changed: (courseId) => { materialsRepo.invalidateTree(courseId); broadcast('materials:changed', { courseId }) }
  })
  handle('presentation:runtime', () => presentations.runtime.getState())
  handle('presentation:installRuntime', () => presentations.runtime.install())
  handle('presentation:cancelRuntime', () => { presentations.runtime.cancelInstall(); return OK })
  handle('presentation:prepare', (req) => presentations.prepare(req))
  handle('presentation:cancelPrepare', (req) => { presentations.runtime.cancel(req.requestId); return OK })
  handle('presentation:pdfStart', (req) => presentations.start(req))
  handle('presentation:pdfPage', async (req) => { await presentations.append(req); return OK })
  handle('presentation:pdfFinish', (req) => presentations.finish(req.sessionId))
  handle('presentation:pdfCancel', async (req) => { await presentations.cancel(req.sessionId); return OK })
  // -- printing ---------------------------------------------------------------
  handle('print:pdf', async (req) => {
    const bytes = Buffer.from(req.base64, 'base64')
    if (bytes.byteLength > PRINT_PDF_MAX_BYTES) {
      throw new ValidationError('인쇄할 내용이 너무 큽니다')
    }
    const result = await printPdfBytes({
      bytes,
      jobName: req.jobName,
      parent: BrowserWindow.getFocusedWindow()
    })
    return { ok: true as const, printed: result.printed }
  })
  handle('print:savePdfAs', async (req) => {
    const result = await dialog.showSaveDialog({
      title: 'PDF로 저장',
      defaultPath: req.suggestedName,
      filters: [{ name: 'PDF', extensions: ['pdf'] }]
    })
    if (result.canceled || result.filePath === undefined) {
      return { ok: true as const, canceled: true, savedPath: null }
    }
    writeFileSync(result.filePath, Buffer.from(req.base64, 'base64'))
    return { ok: true as const, canceled: false, savedPath: result.filePath }
  })
  handle('print:pdfFromUrl', async (req, event) => {
    // The guest is already showing this PDF, but printToPDF cannot rasterize
    // plugin content — so fetch the original bytes instead of a blank render.
    const fetched = await fetchLinkForMaterials(req.url, browserSessionForTab(event, req.tabId))
    return { base64: fetched.dataBase64 }
  })
  handle('window:setPrintEnabled', (req) => {
    setPrintMenuEnabled(req.enabled)
    return OK
  })
  handle('window:getState', (_req, event) => ({ fullscreen: BrowserWindow.fromWebContents(event.sender)?.isFullScreen() ?? false }))

  handle('pdf:exportAnnotated', async (req) => {
    const baseName = req.relPath.split('/').pop() ?? 'document.pdf'
    const suggested = baseName.replace(/\.pdf$/i, '') + ' (주석).pdf'
    const result = await dialog.showSaveDialog({
      title: '주석 포함 PDF로 내보내기',
      defaultPath: suggested,
      filters: [{ name: 'PDF', extensions: ['pdf'] }]
    })
    if (result.canceled || result.filePath === undefined) {
      return { savedPath: null }
    }
    await pdfExporter.exportAnnotated(req, result.filePath)
    return { savedPath: result.filePath }
  })

  // -- course activity + AI context ------------------------------------------
  //
  // Recording lives HERE rather than in each feature repo on purpose: every
  // action worth remembering already funnels through this file, so one place
  // stays consistent instead of a `record()` call scattered across a dozen
  // modules that later drift.
  //
  // Every call is best-effort. A failed activity write must never break the
  // action the student actually asked for.
  const activityRepo = createActivityRepo(db)
  // Backlinks: who cites this material. Derived on demand from note text and
  // clip payloads — see features/links. Declared before insights and the
  // dossier because both now answer with real citations instead of guessing
  // from filenames.
  const linkIndex = createLinkIndex({
    db,
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId)
  })
  const insights = createInsights({
    db,
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    getMaterialCitations: (courseId) =>
      linkIndex.allForCourse(courseId).map((group) => group.relPath)
  })
  const contextWriter = createContextWriter({
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId),
    getCourse: (courseId) => ({ name: coursesRepo.getById(courseId).name }),
    activity: activityRepo,
    db,
    // Injected rather than read inside the dossier so the context feature does
    // not depend on board/insights. This is the only forward-looking part of
    // the dossier — it turns "summarise this PDF" into "the exam is in 12 days
    // and week 3 is still unopened".
    getUpcomingDeadlines: (courseId) =>
      boardRepo.upcoming({ courseId, withinDays: 30, limit: 8 }),
    getStudyGaps: (courseId) => insights.gaps(courseId),
    // The AI could not see whiteboards at all — no disk representation, no
    // dossier section. `canvasRepo` is declared further down; these run at
    // rebuild time (chat:open), long after registration finishes.
    // countShapes 는 COUNT(*) 한 번이다 — 도시에가 개수만 쓰는데 보드마다
    // 도형 전체를 열어 JSON 파싱하던 것이 chat:open 을 무겁게 만들었다.
    getWhiteboards: (courseId) =>
      canvasRepo.listBoards(courseId).map((board) => ({
        title: board.title,
        shapeCount: canvasRepo.countShapes(board.id)
      })),
    getMaterialLinks: (courseId) => linkIndex.allForCourse(courseId)
  })
  const note = (
    courseId: string,
    kind: Parameters<typeof activityRepo.record>[0]['kind'],
    summary: string,
    relPath: string | null = null
  ): void => {
    try {
      activityRepo.record({ courseId, kind, relPath, summary })
    } catch (error) {
      console.error('[activity] failed to record', kind, error)
    }
  }

  handle('activity:record', (req) => {
    note(req.courseId, req.kind, req.summary, req.relPath ?? null)
    return OK
  })
  handle('activity:recent', (req) =>
    activityRepo.recent(req.courseId, req.limit)
  )

  /**
   * chat:open 마다 rebuild 를 반복할 필요는 없다 — 같은 과목에서 이 시간 안에
   * 끝난 rebuild 가 있으면 건너뛴다. 대화를 연달아 여닫는 흔한 동선에서
   * 자료가 많은 과목의 rebuild 폭주를 막는다.
   */
  const CONTEXT_REBUILD_COALESCE_MS = 15_000
  const contextRebuiltAt = new Map<string, number>()
  function rebuildContextCoalesced(courseId: string): void {
    const last = contextRebuiltAt.get(courseId)
    if (last !== undefined && Date.now() - last < CONTEXT_REBUILD_COALESCE_MS) {
      return
    }
    contextWriter.rebuild(courseId)
    contextRebuiltAt.set(courseId, Date.now())
  }

  handle('context:rebuild', (req) => {
    // 명시적 요청은 절대 건너뛰지 않는다 — 완료 시각만 기록해 둔다.
    const result = contextWriter.rebuild(req.courseId)
    contextRebuiltAt.set(req.courseId, Date.now())
    return result
  })

  // -- board ----------------------------------------------------------------
  handle('board:listTasks', (req) => boardRepo.list(req))
  handle('board:createTask', (req) => {
    const result = boardRepo.create(req)
    if (req.courseId != null) {
      note(req.courseId, 'task-created', `할 일을 추가했습니다: ${req.title}`)
    }
    broadcast('board:changed', { courseId: result.courseId })
    return result
  })
  handle('board:updateTask', (req) => {
    const result = boardRepo.update(req)
    broadcast('board:changed', { courseId: result.courseId })
    return result
  })
  handle('board:reorderTasks', (req) => {
    const result = boardRepo.reorderTasks(req.courseId, req.updates)
    broadcast('board:changed', { courseId: req.courseId })
    return result
  })
  const appleCalendar = createAppleCalendar(boardRepo, () => broadcast('appleCalendar:changed', {}))
  handle('appleCalendar:state', () => appleCalendar.state())
  handle('appleCalendar:connect', () => appleCalendar.connect())
  handle('appleCalendar:disconnect', () => appleCalendar.disconnect())
  handle('appleCalendar:configure', req => appleCalendar.configure(req))
  handle('appleCalendar:events', req => appleCalendar.events(req))
  handle('appleCalendar:export', req => appleCalendar.exportTask(req.taskId))
  handle('appleCalendar:permissions', async () => {
    if (process.platform === 'darwin') await shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars')
    return OK
  })
  handle('calendar:range', (req) => boardRepo.listRange(req))
  handle('calendar:upcoming', (req) => boardRepo.upcoming(req))
  handle('board:deleteTask', (req) => {
    const result = boardRepo.softDelete(req)
    broadcast('board:changed', { courseId: null })
    return result
  })

  // -- chat (M4-H: Claude Code CLI runtime) ---------------------------------
  const chatRepo = createChatRepo(db)
  chatRepo.markDanglingInterrupted()
  const binaryLocator = createBinaryLocator()
  const claudeAdapter = createClaudeCodeAdapter({ locator: binaryLocator })
  const eventBatcher = createEventBatcher({
    send: (batch) => broadcast('chat:event-batch', batch)
  })
  const codexLocator = createCodexBinaryLocator()
  const codexAdapter = createCodexAdapter({ locator: codexLocator })
  const geminiApiKeyStore = createGeminiApiKeyStore(deps.userDataPath)
  const geminiLocator = createGeminiBinaryLocator({
    hasApiKey: () => geminiApiKeyStore.readKey() !== null
  })
  const geminiAdapter = createGeminiAdapter({
    locator: geminiLocator,
    userDataPath: deps.userDataPath,
    apiKey: () => geminiApiKeyStore.readKey()
  })
  const agentLocators: Record<AgentProvider, typeof binaryLocator> = {
    'claude-code': binaryLocator,
    codex: codexLocator,
    gemini: geminiLocator
  }
  const agentAvailability = createAgentAvailabilityService({ locators: agentLocators })

  // -- assistant acting on the app -------------------------------------------
  // Keep scope settings, the action journal and per-turn budgets independent
  // from the UI: routine work can proceed without confirmation cards.
  const agentJournal = createAgentJournal(db)
  const learningApprovals = createLearningApprovalDialogs({
    getOwner: getMainWindow,
    show: (owner, options) => dialog.showMessageBox(owner, options)
  })
  const agentConfirmer = createAgentConfirmer({
    allow: request => {
      const session = chatRepo.getSession(request.conversationId)
      // A background task still uses its own restricted learning approvals.
      if (session?.surface === 'study') return false
      return appPermissionAllowed(session?.accessPolicy ?? DEFAULT_AI_ACCESS, request.tool, request.courseId === session?.courseId)
    },
    emit: (request) => {
      broadcast('agentTools:confirm', request)
      // Dedicated study conversations have no chat panel to show approval cards.
      if (learningRuntime?.isStudySession(request.conversationId)) {
        void learningApprovals.request(request.requestId, { type: 'question', message: request.summary,
          detail: request.details.join('\n'), buttons: ['취소', '이번만 허용'], defaultId: 0, cancelId: 0 })
          .then(answer => agentConfirmer.resolve({ requestId: request.requestId, approved: answer?.response === 1, scope: 'once' }))
      }
    },
    changed: (state) => {
      if (state.status !== 'pending') learningApprovals.cancel(state.request.requestId)
      broadcast('agentTools:confirmationChanged', state)
    }
  })
  const packStore: ReturnType<typeof createPackStore> = createPackStore({ userDataPath: deps.userDataPath,
    onChanged: () => broadcast('packs:changed', { packs: packStore.list() }) })
  // One guard is shared by every MCP server and the pack runner. Creating a
  // guard per conversation would make the runner arm an instance no tool can
  // see, silently defeating a pack's declared tool allowlist.
  const packRunGuard = createPackRunGuard()
  // -- the agent's view of the browser and the course's LMS ----------------
  // Registered for EVERY session. This used to be gated on the course having a
  // classroom linked, to save the ~1k tokens the schemas cost per turn — but
  // the gate meant a student looking at their university portal was told the
  // agent had "no tool to read the browser", which was literally true and
  // completely wrong. The schemas ride at the front of the prompt cache, so
  // the real cost is near zero; the gate cost a whole feature.
  //
  // The LMS-only tools (`lms_*`) still degrade on their own when no classroom
  // is linked — siteRecipes.ts bails on a null lmsCourseId — so keeping them
  // registered costs nothing but an honest "this course has no classroom yet".
  /**
   * The active school's LMS spec, when this URL is on its classroom host.
   * The spec carries the platform, which is what decides whether a JSON
   * endpoint exists at all.
   */
  const specForUrl = (url: string): { platform: LmsPlatform } | null => {
    const spec = resolveUniversity(getSettings().university)?.courseLink
    if (spec === undefined) return null
    try {
      return new RegExp(spec.idPattern).test(url)
        ? { platform: spec.platform }
        : null
    } catch {
      return null
    }
  }

  const browserGrants = createGrantsRepo(db)
  const browserAudit = createAuditRepo(db)
  browserAudit.prune()
  desktopAudit.prune()
  const browserSeen = createSeenRepo(db)
  /** One beat after a load ends, so the new document has committed. */
  const SETTLE_QUIET_MS = 150
  const browserRunScopes = new Map<string, ReturnType<typeof createConversationRunScope>>()
  const finishBrowserConversation = (conversationId: string): void => {
    const scope = browserRunScopes.get(conversationId)
    const run = scope?.current()
    if (run) {
      pendingResumes.get(run.runId)?.('stopped')
      pendingResumes.delete(run.runId)
    }
    scope?.finish()
  }

  const browserToolsFor = (
    courseId: string,
    conversationId: string,
    getRunId: () => string
  ): ReturnType<typeof createBrowserTools> => {
    finishBrowserConversation(conversationId)
    const runScope = createConversationRunScope({ registry: browserRuns, courseId, getTurnId: getRunId })
    browserRunScopes.set(conversationId, runScope)
    const recipeSession = (): Electron.Session => {
      if (openBrowserTabs.courseId === courseId && openBrowserTabs.activeTabId) {
        const guest = guestRegistry.resolve(openBrowserTabs.activeTabId)
        if (guest) return guest.session as Electron.Session
      }
      return ensureProfileSession()
    }
    return createBrowserTools({
      courseId,
      getRunId,
      getAgentUse: () => getSettings().browser.agentUse,
      grants: browserGrants,
      audit: browserAudit,
      seen: browserSeen,
      courseLinks: (id) =>
        courseLinksRepo
          .list({ courseId: id })
          .map((link) => ({ url: link.url, lmsCourseId: link.lmsCourseId })),
      specFor: (url) => specForUrl(url),
      // Scoped to the course this conversation belongs to: a chat about
      // 자료구조 has no business naming the tabs open under another course.
      openTabs: () =>
        openBrowserTabs.courseId === courseId
          ? {
              tabs: openBrowserTabs.tabs,
              activeTabId: openBrowserTabs.activeTabId
            }
          : { tabs: [], activeTabId: null },
      // The app's own confirmer, not the CLI's permission flow — Codex has no
      // interactive approval at all (agentTools/confirm.ts).
      confirm: (request) =>
        agentConfirmer.confirm({ ...request, conversationId, turnId: getRunId() }),
      // A live run drives a VISIBLE tab: the student watches the page move and
      // can stop it. That is the mitigation for every reliability failure mode
      // here, and a hidden guest would be background-throttled anyway.
      page: createPageSurface({
        resolveGuest: (tabId) => guestRegistry.resolve(tabId),
        framesOf: (guest) => {
          const wc = guest as unknown as Electron.WebContents
          const main = wc.mainFrame
          // Every frame, not just the main one: LearningX wraps Canvas in an
          // iframe and SSO lives in one too. The existing in-page bridges are
          // main-frame only, which is why they are blind to both.
          return main.framesInSubtree.map((frame) => ({
            executeJavaScript: (code: string) => frame.executeJavaScript(code)
          }))
        },
        requestTab: (url, timeoutMs) =>
          new Promise((resolve) => {
            const requestId = randomUUID()
            // Opening a page IS the start of a run — from here on the student
            // has a strip and a 중지 button on the tab being driven.
            runScope.assertLive()
            runScope.step('페이지를 여는 중', url)
            const runId = runScope.current()!.runId
            pendingTabOpens.set(requestId, { resolve, runId })
            broadcast('browser:open-url', { url, requestId })
            setTimeout(() => {
              const pending = pendingTabOpens.get(requestId)
              if (pending === undefined) return
              pendingTabOpens.delete(requestId)
              // The run was started for a tab that never arrived. Ending it
              // stops a 중지 strip from outliving the attempt, bound to
              // nothing, for the rest of the session.
              if (pending.runId === runScope.current()?.runId) runScope.finish()
              resolve(null)
            }, timeoutMs)
          }),
        /**
         * Resolve once the guest has stopped moving, or the budget runs out.
         *
         * A click is synchronous; the navigation it starts is not. Without
         * this the next snapshot read the OLD document — and since the ref
         * generation only bumps on the renderer's `dom-ready` round trip, the
         * stale outline still looked valid. A confident wrong picture.
         */
        settle: (tabId, timeoutMs) =>
          new Promise<void>((resolve) => {
            const guest = guestRegistry.resolve(tabId)
            if (guest === null) {
              resolve()
              return
            }
            const contents = guest as unknown as Electron.WebContents
            let done = false
            const finish = (): void => {
              if (done) return
              done = true
              clearTimeout(budget)
              contents.off('did-stop-loading', onStop)
              resolve()
            }
            // A short beat after the load ends: the new document commits and
            // its first paint lands just after the event.
            const onStop = (): void => {
              setTimeout(finish, SETTLE_QUIET_MS)
            }
            const budget = setTimeout(finish, timeoutMs)
            try {
              if (!contents.isLoading()) {
                // Nothing navigated — give the page one beat for a JS-driven
                // DOM change, then report.
                setTimeout(finish, SETTLE_QUIET_MS)
                return
              }
            } catch {
              finish()
              return
            }
            contents.on('did-stop-loading', onStop)
          }),
        /**
         * A real key press.
         *
         * `browser_type` writes a field's value through the native setter and
         * stops there — no key ever travels. Korean portal search boxes
         * overwhelmingly submit on Enter, so without this the agent could fill
         * a box and had no way to run the search.
         */
        sendKey: async (tabId, key) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) return
          const contents = guest as unknown as Electron.WebContents
          contents.sendInputEvent({ type: 'keyDown', keyCode: key })
          contents.sendInputEvent({ type: 'keyUp', keyCode: key })
        },

        /** back / forward / reload / stop — the app could already do all four. */
        history: async (tabId, action) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) return
          const contents = guest as unknown as Electron.WebContents
          if (action === 'back') contents.navigationHistory.goBack()
          else if (action === 'forward') contents.navigationHistory.goForward()
          else if (action === 'reload') contents.reload()
          else contents.stop()
        },

        /**
         * Bringing a tab forward or closing it belongs to the RENDERER — guests
         * live in its fixed layer and the workspace owns the tab strip.
         */
        tabLifecycle: async (tabId, action) => {
          if (action === 'focus') {
            broadcast('browser:activate-tab', { tabId })
            return true
          }
          broadcast('browser:close-tab', { tabId })
          return true
        },

        findInPage: (tabId, text) =>
          new Promise<number>((resolve) => {
            const guest = guestRegistry.resolve(tabId)
            if (guest === null || text === '') {
              resolve(0)
              return
            }
            const contents = guest as unknown as Electron.WebContents
            let done = false
            const finish = (matches: number): void => {
              if (done) return
              done = true
              clearTimeout(budget)
              contents.off('found-in-page', onFound)
              // Otherwise the student is left staring at a highlight the agent
              // put there and cannot clear.
              try {
                contents.stopFindInPage('clearSelection')
              } catch {
                // The guest went away mid-search; nothing to clear.
              }
              resolve(matches)
            }
            const onFound = (
              _event: unknown,
              result: { matches?: number }
            ): void => finish(result.matches ?? 0)
            const budget = setTimeout(() => finish(0), 3_000)
            contents.on('found-in-page', onFound)
            try {
              contents.findInPage(text)
            } catch {
              finish(0)
            }
          }),

        requestActivateTab: (tabId) => {
          broadcast('browser:activate-tab', { tabId })
        },
        awaitTabRegister: (tabId, timeoutMs) =>
          new Promise((resolve) => {
            pendingTabWakes.set(tabId, resolve)
            setTimeout(() => {
              if (pendingTabWakes.delete(tabId)) resolve(false)
            }, timeoutMs)
          }),
        generations,
        // Hangul: `sendInputEvent` has no IME path, so text typed through the
        // DOM tier never fires `compositionend`. This is the gap CDP is here
        // for; it degrades silently when the debugger is unavailable.
        insertText: async (tabId, text) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) throw new Error('no guest')
          await insertText(
            guest as unknown as { debugger: Electron.Debugger },
            text
          )
        },
        run: {
          assertLive: runScope.assertLive,
          step: runScope.step,
          wait: runScope.wait,
          awaitResume: (timeoutMs) =>
            new Promise((resolve) => {
              const live = runScope.current()
              if (live === null) {
                resolve('stopped')
                return
              }
              pendingResumes.set(live.runId, resolve)
              setTimeout(() => {
                if (pendingResumes.delete(live.runId)) resolve('stopped')
              }, timeoutMs)
            })
        }
      }),
      commit: {
        /**
         * The submit click itself. Reached only after an explicit yes that is
         * never remembered — see `browser_submit`.
         */
        submit: async (tabId, frameIndex, elementIndex) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) return false
          const wc = guest as unknown as Electron.WebContents
          const frame = wc.mainFrame.framesInSubtree[frameIndex]
          if (frame === undefined) return false
          // The SAME enumeration the snapshot indexed with — this was the
          // third hand-written copy of it, and the copies had drifted.
          const source = `(() => {
            ${TARGET_INDEX_SOURCE}
            const target = __bandalTargets()[${elementIndex}];
            if (!target) return false;
            target.click();
            return true;
          })()`
          try {
            return (await frame.executeJavaScript(source)) === true
          } catch {
            return false
          }
        },

        /**
         * Reuses `createLoginFiller` unchanged. The agent hands over a tab and
         * learns whether it worked — the secret never enters the agent path,
         * let alone the model's context.
         */
        useSavedLogin: async (tabId) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) return { filled: false, username: null }
          const result = await loginBridgeFor(guest.id).fill({
            origin: guest.getURL(),
            guestWebContentsId: guest.id,
            allowAutoSubmit: false
          })
          return { filled: result.filled, username: null }
        },

        /**
         * `DOM.setFileInputFiles` — the one thing JavaScript genuinely cannot
         * do. CDP is attached for this single call and detached immediately.
         */
        attachFile: async (tabId, frameIndex, elementIndex, target, relPath) => {
          const guest = guestRegistry.resolve(tabId)
          if (guest === null) return false
          const wc = guest as unknown as Electron.WebContents
          const frame = wc.mainFrame.framesInSubtree[frameIndex]
          if (frame === undefined) return false
          const absPath = resolveInside(coursesRepo.getFolder(target), relPath)
          try {
            return await setFileInputFiles(
              guest as unknown as { debugger: Electron.Debugger },
              frame,
              elementIndex,
              [absPath]
            )
          } catch {
            // DevTools already owns the debugger, or the page went away.
            return false
          }
        }
      },
      // The student's own login — the same session they signed in to by hand.
      fetch: (url) => recipeSession().fetch(url),
      // Same path a link-drag takes: browsing-session fetch with the 200MB
      // cap, then materialsRepo's own guards. One download implementation,
      // not two.
      collect: async ({ courseId: target, url, dirRelPath }) => {
        const { fileName, dataBase64 } = await fetchLinkForMaterials(url, recipeSession())
        return materialsRepo.writeFile({
          courseId: target,
          dirRelPath,
          fileName,
          encoding: 'base64',
          data: dataBase64
        })
      }
    })
  }

  // The glass box + the tab map the agent addresses pages through.
  const browserRuns = createRunRegistry({
    emit: (state) => broadcast('browserAgent:run-state', state)
  })
  const guestRegistry = createGuestRegistry({
    isManagedPage: (guest) => isManagedBrowserPage(guest.id),
    fromId: (id) => webContents.fromId(id) as never,
    // A guest the agent may drive is a webview on the hardened partition and
    // nothing else — never the app's own renderer.
    isBrowsingPartition: (guest) => {
      if (!isManagedBrowserPage(guest.id)) return false
      return !guestProfile(guest.id).isPrivate
    }
  })
  const generations = new GenerationTracker()

  /**
   * Resolvers waiting for a tab the agent asked the renderer to open.
   *
   * Keyed by a request id, NOT by URL. Prefix matching could not survive a
   * host change, so a portal that redirects — 서울대's my.snu → shine.snu —
   * made `browser_open` report failure about a tab that had opened fine, and
   * left an orphan run bound to no tab. It also had a hole: a guest that
   * failed to resolve gave `url === ''`, and `pending.url.startsWith('')` is
   * always true, so ONE bad registration resolved EVERY outstanding open.
   */
  const pendingTabOpens = new Map<
    string,
    { resolve: (tabId: string | null) => void; runId: string | null }
  >()
  /** Resolvers waiting on a student who was handed the wheel. */
  const pendingResumes = new Map<
    string,
    (outcome: 'resumed' | 'stopped') => void
  >()
  /** Resolvers waiting for a restored tab's page to be created lazily. */
  const pendingTabWakes = new Map<string, (woke: boolean) => void>()
  /**
   * What the student is looking at in Bandal, published by the renderer.
   *
   * The browser half of this already existed; the app half did not, which is
   * why an instruction about the sidebar was resolved against the portal.
   */
  let workspaceSnapshot: {
    activeKind?: string
    selectedCourseId: string | null
    tabs: { kind: string; title: string; active: boolean }[]
  } = { selectedCourseId: null, tabs: [] }

  const panelMaterials = new Map<string, MaterialContext>()
  const lastMaterials = new Map<string, MaterialContext>()
  const updateMaterial = (courseId: string, material: MaterialContext): void => {
    const previous = lastMaterials.get(courseId)
    if (JSON.stringify(previous) === JSON.stringify(material)) return
    lastMaterials.set(courseId, material)
    broadcast('assistant:contextChanged', { courseId })
  }
  const contextRefreshes = new Map<string, () => void>()
  const refreshWorkspace = async (): Promise<boolean> => {
    const requestId = randomUUID()
    return new Promise(resolve => {
      const timer = setTimeout(() => { contextRefreshes.delete(requestId); resolve(false) }, 1000)
      contextRefreshes.set(requestId, () => { clearTimeout(timer); contextRefreshes.delete(requestId); resolve(true) })
      broadcast('assistant:contextRefresh', { requestId })
    })
  }
  const snapshotContext = async (courseId: string, sourcePanelId?: string): Promise<MessageContextSnapshot> => {
    const fresh = await refreshWorkspace()
    const candidate = sourcePanelId ? panelMaterials.get(sourcePanelId) : lastMaterials.get(courseId)
    let material = candidate?.courseId === courseId && !candidate.unavailable && (!sourcePanelId || fresh) ? { ...candidate } : undefined
    let failed = !!sourcePanelId && !material
    if (material?.browserTabId) {
      const guest = guestRegistry.resolve(material.browserTabId)
      const contents = guest ? webContents.fromId(guest.id) : null
      if (!contents || contents.isDestroyed()) { failed = true; material = undefined }
      else {
        try {
          const cleanProbe = isCleanBrowserAuthProbe()
          const selection = cleanProbe ? undefined : await Promise.race([
            contents.executeJavaScript('window.getSelection()?.toString().slice(0, 8000) || ""'),
            new Promise<never>((_, reject) => setTimeout(() => reject(new Error('문맥 읽기 시간 초과')), 1500))
          ])
          if (sourcePanelId && !panelMaterials.has(sourcePanelId)) { failed = true; material = undefined }
          else {
            material = { ...material, url: contents.getURL(), title: contents.getTitle() || material.title, ...(typeof selection === 'string' && selection ? { selection } : {}) }
            if (cleanProbe) delete material.selection
          }
        } catch { failed = true; material = undefined }
      }
    }
    return { id: createHash('sha256').update(JSON.stringify([courseId, sourcePanelId, material])).digest('hex').slice(0, 20), courseId, courseName: coursesRepo.getById(courseId).name, capturedAt: new Date().toISOString(), refresh: failed ? 'failed' : fresh ? 'fresh' : 'cached', ...(material ? { material } : {}) }
  }
  handle('chat:context', req => snapshotContext(req.courseId, req.sourcePanelId))

  const appStateSnapshot = (): AgentAppState => {
    const groups = courseGroupsRepo.list()
    const names = new Map(groups.map((group) => [group.id, group.name]))
    return {
      selectedCourseId: workspaceSnapshot.selectedCourseId,
      groups: groups.map((group) => ({ id: group.id, name: group.name })),
      courses: coursesRepo.list({ includeArchived: false }).map((course) => ({
        id: course.id,
        name: course.name,
        groupId: course.groupId,
        groupName:
          course.groupId === null ? null : (names.get(course.groupId) ?? null)
      })),
      workspaceTabs: workspaceSnapshot.tabs,
      browserTabs: openBrowserTabs.tabs.map((tab) => ({
        tabId: tab.tabId,
        title: tab.title,
        url: tab.url,
        active: tab.tabId === openBrowserTabs.activeTabId,
        asleep: tab.asleep
      }))
    }
  }

  let openBrowserTabs: {
    courseId: string
    tabs: { tabId: string; title: string; url: string; asleep: boolean }[]
    activeTabId: string | null
  } = { courseId: '', tabs: [], activeTabId: null }

  handle('browserAgent:registerTab', (req) => {
    guestRegistry.register(req.tabId, req.webContentsId)
    // A fresh attach means a fresh document: every outstanding ref dies.
    generations.invalidate(req.tabId)
    const openRequestId = req.openRequestId
    if (openRequestId !== undefined) {
      const pending = pendingTabOpens.get(openRequestId)
      if (pending !== undefined) {
        pendingTabOpens.delete(openRequestId)
        // The strip belongs to the tab that just appeared.
        try {
          if (pending.runId !== null) browserRuns.attachTab(pending.runId, req.tabId)
          pending.resolve(req.tabId)
        } catch {
          if (pending.runId !== null) browserRuns.stop(pending.runId)
          pending.resolve(null)
        }
      }
    }
    pendingTabWakes.get(req.tabId)?.(true)
    pendingTabWakes.delete(req.tabId)
    return OK
  })
  handle('agent:syncWorkspace', (req) => {
    panelMaterials.clear()
    for (const doc of req.documents ?? []) if (doc.documentId) panelMaterials.set(doc.documentId, doc)
    const previousCourseId = workspaceSnapshot.selectedCourseId
    workspaceSnapshot = {
      ...(req.activeKind ? { activeKind: req.activeKind } : {}),
      selectedCourseId: req.selectedCourseId,
      tabs: req.tabs.map((tab) => ({ ...tab }))
    }
    const active = req.tabs.find(tab => tab.active && tab.kind !== 'chat' && tab.courseId)
    if (active?.courseId) {
      const detail = req.documents?.find(doc => doc.documentId === active.documentId)
      updateMaterial(active.courseId, { courseId: active.courseId, kind: active.kind, title: active.title, ...(active.relPath ? { relPath: active.relPath } : {}), ...(active.documentId ? { documentId: active.documentId } : {}), ...detail, ...(req.selection ? { selection: req.selection.slice(0, 8000) } : {}) })
    }
    for (const doc of req.documents ?? []) {
      const last = lastMaterials.get(doc.courseId)
      if (last?.relPath && last.relPath === doc.relPath) updateMaterial(doc.courseId, { ...last, ...doc })
    }
    if (req.activeKind === 'browser' && req.selectedCourseId === openBrowserTabs.courseId) {
      const tab = openBrowserTabs.tabs.find(tab => tab.tabId === openBrowserTabs.activeTabId)
      if (tab) updateMaterial(openBrowserTabs.courseId, { courseId: openBrowserTabs.courseId, kind: 'browser', title: tab.title, browserTabId: tab.tabId, url: tab.url, ...(req.selection ? { selection: req.selection } : {}) })
    }
    if (req.refreshId) contextRefreshes.get(req.refreshId)?.()
    if (previousCourseId !== req.selectedCourseId) {
      emitPluginEvent('course:changed', { courseId: req.selectedCourseId })
    }
    return OK
  })
  handle('browserAgent:syncTabs', (req) => {
    const current = req.tabs.find(tab => tab.tabId === req.activeTabId)
    if (current && workspaceSnapshot.selectedCourseId === req.courseId && workspaceSnapshot.activeKind === 'browser') updateMaterial(req.courseId, { courseId: req.courseId, kind: 'browser', title: current.title, browserTabId: current.tabId, url: current.url })

    openBrowserTabs = {
      courseId: req.courseId,
      tabs: req.tabs.map((tab) => ({ ...tab })),
      activeTabId: req.activeTabId
    }
    return OK
  })
  handle('browserAgent:stopRun', (req) => {
    browserRuns.stop(req.runId)
    pendingResumes.get(req.runId)?.('stopped')
    pendingResumes.delete(req.runId)
    return OK
  })
  handle('browserAgent:resumeRun', (req) => {
    browserRuns.resume(req.runId)
    pendingResumes.get(req.runId)?.('resumed')
    pendingResumes.delete(req.runId)
    return OK
  })

  handle('browserAgent:grants', () => ({ grants: browserGrants.list() }))
  handle('browserAgent:revokeGrant', (req) => {
    browserGrants.revoke(req.id)
    return OK
  })
  handle('browserAgent:auditTail', (req) => ({
    entries: browserAudit
      .tail(req.courseId, req.limit)
      .map(({ id, courseId, action, url, detail, createdAt }) => ({
        id,
        courseId,
        action,
        url,
        detail,
        createdAt
      }))
  }))

  const startToolServer = async (
    courseId: string,
    sessionKey: string,
    getTurnSeq: () => number,
    surface: 'app' | 'desktop' | 'study'
  ): Promise<Awaited<ReturnType<typeof startAgentToolsServer>>> =>
    startAgentToolsServer({
      sessionId: sessionKey,
      userDataPath: app.getPath('userData'),
      ...(surface === 'desktop'
        ? { userMcpServers: mcpRegistry.resolveEnabled() }
        : {}),
      deps: {
        courseId,
        // Keyed by conversation, not course: two conversations in one course
        // are separate turn streams, and all providers share this factory.
        // The number comes from `chatRepo.nextTurnSeq` via SessionManager —
        // a module-level counter here would never advance, which silently
        // froze `AGENT_TURN_LIMITS` (a spent budget stayed spent until the app
        // restarted) and lumped every action ever into one undo group.
        getTurnId: () => `${sessionKey}:${getTurnSeq()}`,
        coursesRepo,
        courseGroupsRepo,
        courseLinksRepo,
        favoritesRepo,
        searchIndex: { query: (courseId, query, limit) => background.request('searchQuery', {
          dbPath: searchCachePath, courseId, folder: coursesRepo.getFolder(courseId), query, ...(limit === undefined ? {} : { limit }), fresh: true
        }, 0) },
        linkService,
        appState: () => appStateSnapshot(),
        materialsRepo,
        materialLinksRepo,
        notesRepo,
        boardRepo,
        canvasRepo,
        packRunGuard,
        packGuardKey: sessionKey,
        learning: {
          restriction: () => learningRuntime?.restrictionFor(sessionKey) ?? null,
          verifyArticle: async url => {
            if (!learningRuntime) throw new Error('학습 실행을 준비 중입니다.')
            return learningRuntime.verifyArticle(sessionKey, url)
          },
          submitResult: async draft => {
            if (!learningRuntime) throw new Error('학습 실행을 준비 중입니다.')
            return learningRuntime.submitResult(sessionKey, draft)
          },
          readMaterial: async (requestedCourseId, relPath, maxChars) => {
            if (requestedCourseId !== courseId) throw new Error('이 학습 공간의 과목 자료만 사용할 수 있어요.')
            const source = await grounding.material({ courseId, rootRelPath: '' }, relPath)
            return { relPath, pathScope: 'course', supported: true, contentHash: source.contentHash,
              text: source.text.slice(0, maxChars),
              truncated: source.truncated || source.text.length > maxChars }
          }
        },
        accessMode: () => chatRepo.getSession(sessionKey)?.accessPolicy?.mode ?? 'auto',
        confirm: async (request) =>
          (await agentConfirmer.confirm({ ...request, conversationId: sessionKey, turnId: `${sessionKey}:${getTurnSeq()}` })) !==
          false,
        browser: browserToolsFor(
          courseId,
          sessionKey,
          () => `${sessionKey}:${getTurnSeq()}`
        ),
        ...(true
          ? {
              desktop: createDesktopTools({
                courseId,
                conversationId: sessionKey,
                getTurnId: () => `${sessionKey}:${getTurnSeq()}`,
                surface: desktopSurface,
                grants: desktopGrants,
                audit: desktopAudit,
                confirm: (input) =>
                  agentConfirmer.confirm({
                    ...input,
                    courseId,
                    conversationId: sessionKey,
                    turnId: `${sessionKey}:${getTurnSeq()}`
                  }),
                run: desktopRun,
                onPermission: (payload) => {
                  broadcast('desktopAgent:permission', payload)
                }
              })
            }
          : {}),
        journal: {
          record: (entry) => {
            agentJournal.record(entry)
            // Whatever the tool touched, the UI is now stale. 자료 캐시도
            // 마찬가지다 — 필기 도구는 materialsRepo 를 거치지 않고 디스크에
            // 쓰므로 여기서 무효화해야 한다.
            materialsRepo.invalidateTree(entry.courseId)
            broadcast('courses:changed', {})
            broadcast('board:changed', { courseId: entry.courseId })
            broadcast('canvas:changed', { courseId: entry.courseId })
            broadcast('materials:changed', { courseId: entry.courseId })
            broadcast('agentTools:changed', {
              courseId: entry.courseId,
              // Route to the conversation that caused it. Course-level routing
              // put the change list in every chat of that course.
              conversationId: sessionKey,
              turnId: entry.turnId
            })
          }
        }
      }
    })

  const chatOperations = new Map<string, { cancelled: boolean }>()
  const assertChatIdle = (sessionId: string): void => {
    if (chatOperations.has(sessionId)) throw new Error('진행 중인 작업이 끝난 뒤 다시 시도해 주세요.')
  }
  const cancelChatOperation = (sessionId: string): void => {
    const operation = chatOperations.get(sessionId)
    if (operation) operation.cancelled = true
  }
  const artifactJobs = new Map<string, { courseId: string; dir: string; creation: CreationKind }>()
  const notifyTurnComplete = (info: {
    courseId: string
    sessionId: string
    turnSeq?: number
    stopReason?: TurnStopReason
  }): void => {
    agentConfirmer.cancelConversation(info.sessionId)
    if (info.stopReason === 'error' || info.stopReason === 'interrupted') {
      artifactJobs.delete(info.sessionId)
      return
    }
    if (learningRuntime?.isStudySession(info.sessionId)) return
    const job = artifactJobs.get(info.sessionId)
    if (job) {
      artifactJobs.delete(info.sessionId)
      void collectChatArtifacts(job.courseId, coursesRepo.getFolder(job.courseId), job.dir, job.creation).then((artifacts) => {
        const message = chatRepo.appendMessage(job.courseId, info.sessionId, 'assistant', info.turnSeq ?? 0, artifacts.length
          ? artifacts.map((artifact) => ({ kind: 'artifact' as const, payload: artifact }))
          : [{ kind: 'text' as const, payload: { text: '생성된 파일을 확인하지 못했어요. 위 작업 결과에서 필요한 연결이나 실행 오류를 확인해 주세요.' } }])
        eventBatcher.flush(info.sessionId)
        broadcast('chat:message', { sessionId: info.sessionId, message })
        materialsRepo.invalidateTree(job.courseId)
        broadcast('materials:changed', { courseId: job.courseId })
      }).catch((error) => {
        console.error('[chat] artifact verification failed', error)
        try {
          const message = chatRepo.appendMessage(job.courseId, info.sessionId, 'assistant', info.turnSeq ?? 0, [
            { kind: 'text', payload: { text: '생성 파일을 확인하지 못했어요. 과목 자료의 생성 결과 폴더를 확인하거나 다시 시도해 주세요.' } }
          ])
          eventBatcher.flush(info.sessionId)
          broadcast('chat:message', { sessionId: info.sessionId, message })
        } catch { /* The conversation or course may have been deleted. */ }
      })
    }
    try {
      let courseName = ''
      try {
        courseName = coursesRepo.getById(info.courseId).name
      } catch {
        // A deleted course can finish a turn while its process is winding down.
      }
      notifier.notify({
        kind: 'agentComplete',
        title: 'AI 응답이 도착했어요',
        body: courseName,
        courseId: info.courseId
      })
    } catch (error) {
      console.error('[notifications] agent completion failed', error)
    }
  }

  const recordUsage = (info: {
    courseId: string
    sessionId: string
    provider: AgentProvider
    model: string | null
    usage?: Usage
    durationMs?: number
  }): void => {
    try {
      usageRepo.record(info)
    } catch (error) {
      console.error('[usage] failed to record agent turn', error)
    }
  }

  const sessionManager = createSessionManager({
    adapter: claudeAdapter,
    repo: chatRepo,
    requestPermission: (request) => agentConfirmer.confirm(request),
    onPermissionResolved: (sessionId, requestId) => agentConfirmer.cancelProviderRequest(sessionId, requestId),
    eventCheckpoint: sessionId => eventBatcher.checkpoint(sessionId),
    onUserMessage: message => broadcast('chat:message', { sessionId: message.sessionId, message }),
    getCourse: (courseId) => ({
      folder: coursesRepo.getFolder(courseId),
      name: coursesRepo.getById(courseId).name
    }),
    emit: (courseId, sessionId, event) => {
      if (event.type === 'error' && event.fatal) artifactJobs.delete(sessionId)
      eventBatcher.push(courseId, sessionId, event)
    },
    startToolServer,
    reportToolsUnavailable: (courseId, sessionId) => {
      broadcast('agentTools:unavailable', { courseId, sessionId })
    },
    onTurnComplete: notifyTurnComplete,
    onTurnSettled: info => { finishBrowserConversation(info.sessionId); settleStudyTurn(info) },
    onRequestsCancelled: (sessionId) => { finishBrowserConversation(sessionId); browserRunScopes.delete(sessionId); agentConfirmer.cancelConversation(sessionId) },
    onUsage: recordUsage
  })
  app.on('will-quit', () => {
    agentConfirmer.disposeAll()
    learningApprovals.dispose()
    browserRuns.disposeAll()
    materialsWatcher.dispose()
    learningRuntime?.dispose()
    dictionary.dispose()
    articleExtractor.dispose()
    sessionManager.disposeAll()
    codexSessionManager.disposeAll()
    geminiSessionManager.disposeAll()
    eventBatcher.dispose()
  })
  process.on('exit', () => {
    killAllClaudeProcessesSync()
    killAllCodexProcessesSync()
    killAllGeminiProcessesSync()
  })

  // The session manager is per-adapter, so the
  // active one is resolved per call from settings rather than captured once —
  // switching providers in settings must take effect on the next message, not
  // on the next app launch.
  const codexSessionManager = createSessionManager({
    adapter: codexAdapter,
    repo: chatRepo,
    requestPermission: (request) => agentConfirmer.confirm(request),
    onPermissionResolved: (sessionId, requestId) => agentConfirmer.cancelProviderRequest(sessionId, requestId),
    eventCheckpoint: sessionId => eventBatcher.checkpoint(sessionId),
    onUserMessage: message => broadcast('chat:message', { sessionId: message.sessionId, message }),
    getCourse: (courseId) => ({
      folder: coursesRepo.getFolder(courseId),
      name: coursesRepo.getById(courseId).name
    }),
    emit: (courseId, sessionId, event) => {
      if (event.type === 'error' && event.fatal) artifactJobs.delete(sessionId)
      eventBatcher.push(courseId, sessionId, event)
    },
    startToolServer,
    reportToolsUnavailable: (courseId, sessionId) => {
      broadcast('agentTools:unavailable', { courseId, sessionId })
    },
    onTurnComplete: notifyTurnComplete,
    onTurnSettled: info => { finishBrowserConversation(info.sessionId); settleStudyTurn(info) },
    onRequestsCancelled: (sessionId) => { finishBrowserConversation(sessionId); browserRunScopes.delete(sessionId); agentConfirmer.cancelConversation(sessionId) },
    onUsage: recordUsage
  })
  const geminiSessionManager = createSessionManager({
    adapter: geminiAdapter,
    repo: chatRepo,
    requestPermission: (request) => agentConfirmer.confirm(request),
    onPermissionResolved: (sessionId, requestId) => agentConfirmer.cancelProviderRequest(sessionId, requestId),
    eventCheckpoint: sessionId => eventBatcher.checkpoint(sessionId),
    onUserMessage: message => broadcast('chat:message', { sessionId: message.sessionId, message }),
    getCourse: (courseId) => ({
      folder: coursesRepo.getFolder(courseId),
      name: coursesRepo.getById(courseId).name
    }),
    emit: (courseId, sessionId, event) => {
      if (event.type === 'error' && event.fatal) artifactJobs.delete(sessionId)
      eventBatcher.push(courseId, sessionId, event)
    },
    startToolServer,
    reportToolsUnavailable: (courseId, sessionId) => {
      broadcast('agentTools:unavailable', { courseId, sessionId })
    },
    onTurnComplete: notifyTurnComplete,
    onTurnSettled: info => { finishBrowserConversation(info.sessionId); settleStudyTurn(info) },
    onRequestsCancelled: (sessionId) => { finishBrowserConversation(sessionId); browserRunScopes.delete(sessionId); agentConfirmer.cancelConversation(sessionId) },
    onUsage: recordUsage
  })
  const managerFor = (provider: string): typeof sessionManager =>
    provider === 'codex'
      ? codexSessionManager
      : provider === 'gemini'
        ? geminiSessionManager
        : sessionManager

  const closeConversationManagers = (
    courseId: string,
    sessionId: string
  ): void => {
    sessionManager.close(courseId, sessionId)
    codexSessionManager.close(courseId, sessionId)
    geminiSessionManager.close(courseId, sessionId)
    eventBatcher.flush(sessionId)
  }

  const switchConversationProvider = (
    courseId: string,
    sessionId: string,
    provider: AgentProvider
  ): ReturnType<typeof chatRepo.switchProvider> => {
    const row = chatRepo.getSession(sessionId)
    closeConversationManagers(courseId, sessionId)
    if (row === null || row.provider === provider) return row
    const { text: _text, ...carried } = serializeTranscript(
      chatRepo.historyTail(sessionId, CARRYOVER_HISTORY_LIMIT)
    )
    const sessionInfo = chatRepo.switchProvider(sessionId, provider)
    chatRepo.appendNotice(courseId, sessionId, {
      kind: 'provider-switch',
      from: row.provider,
      to: provider,
      carried
    })
    return sessionInfo
  }

  /** Pick a ready provider lazily, only when a chat surface is actually used. */
  const resolveConnectedManager = async (
    courseId: string,
    sessionId: string
  ): Promise<typeof sessionManager> => {
    const row = chatRepo.getSession(sessionId)
    if (row && row.courseId !== courseId) throw new Error('대화가 이 과목에 속하지 않아요.')
    if (row?.status === 'running') return managerFor(row.provider)
    const warmProvider = sessionManager.has(sessionId)
      ? 'claude-code'
      : codexSessionManager.has(sessionId)
        ? 'codex'
        : geminiSessionManager.has(sessionId)
          ? 'gemini'
          : null
    const chosen = await resolveConversationProvider({
      storedProvider: row?.provider ?? null,
      warmProvider,
      preferredProvider: getSettings().agentProvider,
      check: provider => agentAvailability.check(provider)
    })
    // An explicit switch can finish while the initial automatic probes await.
    const current = chatRepo.getSession(sessionId)
    if (current) return managerFor(current.provider)
    if (sessionManager.has(sessionId)) return sessionManager
    if (codexSessionManager.has(sessionId)) return codexSessionManager
    if (geminiSessionManager.has(sessionId)) return geminiSessionManager
    return managerFor(chosen)
  }
  /**
   * Provider is a per-CONVERSATION property: a persisted row routes by its own
   * provider, a warm-but-unpersisted entry stays with whichever manager holds
   * it, and only a brand-new conversation follows the settings default.
   */
  const resolveManager = (sessionId: string): typeof sessionManager => {
    const row = chatRepo.getSession(sessionId)
    if (row !== null) {
      return managerFor(row.provider)
    }
    if (sessionManager.has(sessionId)) {
      return sessionManager
    }
    if (codexSessionManager.has(sessionId)) {
      return codexSessionManager
    }
    if (geminiSessionManager.has(sessionId)) {
      return geminiSessionManager
    }
    return managerFor(getSettings().agentProvider)
  }

  const articleExtractor = createArticleExtractor({
    resolveSourceTab: tabId => {
      const guest = guestRegistry.resolve(tabId)
      return guest ? webContents.fromId(guest.id) ?? null : null
    }
  })
  const grounding = createLearningGrounding(courseId => coursesRepo.getFolder(courseId))
  learningRuntime = createLearningRuntime({
    repo: learningRepo,
    extractUrl: (url, signal) => articleExtractor.extractUrl(url, signal),
    matchWords: matchArticleWords,
    validateDraft: async (draft, state) => {
      const result = await normalizeLearningDraft(draft, state,
        id => learningRepo.readArticle(state.binding, id),
        grounding.validator(state.binding, state.linkedCourseId))
      const refs = [...(result.words?.map(word => word.sourceRef) ?? []), ...(result.artifacts?.flatMap(artifact => [
        ...(artifact.sourceRefs ?? []),
        ...(artifact.kind === 'quiz' ? artifact.questions.flatMap(question => question.sourceRefs) :
          artifact.kind === 'cards' ? artifact.cards.flatMap(card => card.sourceRefs) : [])
      ]) ?? [])]
      if (refs.some(ref => ref.kind === 'web')) throw new Error('웹 출처는 가져온 기사 본문의 근거 문장으로 연결하세요.')
      return result
    },
    modelRejected: rejectAgentModel,
    resolveAi: ai => validateConnectedLearningAi(ai, provider => agentAvailability.check(provider), resolveLearningAi),
    recipe: (packId, kind) => {
      const id = packId ?? (kind === 'find-articles' ? 'vocab-chain-en' : kind === 'create-quiz' ? 'quiz' : kind === 'create-cards' ? 'flashcards' : undefined)
      if (!id) return ''
      const pack = packStore.resolve(id)
      if (!pack || pack.schemaVersion !== 2) throw new Error('학습 팩을 사용할 수 없어요. 플러그인 설정을 확인하세요.')
      return pack.recipe
    },
    tools: packId => packId ? packStore.resolve(packId)?.allowedTools ?? [] : [
      'learning_verify_article', 'learning_submit_result', 'read_material', 'list_materials', 'app_state',
      'browser_tabs', 'browser_open', 'browser_snapshot', 'browser_read', 'browser_scroll', 'browser_handoff'
    ],
    close: (courseId, sessionId, provider) => managerFor(provider).close(courseId, sessionId),
    sourceText: async (binding, source) => {
      if (source?.kind !== 'material') return source?.selection ?? ''
      if (!source.relPath) throw new Error('대상 자료를 선택하세요.')
      const material = await grounding.material(binding, source.relPath, source.sourceCourseId, source.selection ? source.page : undefined)
      if (source.selection && !material.text.replace(/\s+/gu, ' ').includes(source.selection.replace(/\s+/gu, ' ').trim())) throw new Error('선택한 내용이 원본 자료와 일치하지 않아요.')
      return JSON.stringify({ relPath: source.relPath, pathScope: 'course', ...(source.sourceCourseId ? { sourceCourseId: source.sourceCourseId } : {}), ...(source.page === undefined ? {} : { page: source.page }), contentHash: material.contentHash,
        text: source.selection ?? material.text, truncated: material.truncated })
    },
    send: async (courseId, sessionId, provider, prompt, ai) => {
      return sendLearningWithSession(managerFor(provider), courseId, sessionId, prompt, ai, validateLearningAi)
    },
    cancel: (courseId, sessionId, provider) => {
      agentConfirmer.cancelConversation(sessionId)
      managerFor(provider).cancel(courseId, sessionId)
    }
  })
  registerLearningHandlers(handle, {
    repo: learningRepo, runtime: learningRuntime, extractor: articleExtractor, cache: learningCache, dictionary,
    validateAi: ai => validateConnectedLearningAi(ai, provider => agentAvailability.check(provider), validateLearningAi),
    courses: coursesRepo,
    resolvePack: id => packStore.resolve(id),
    approvePack: async (id, courseId) => {
      const summary = packStore.list().find(item => item.pack.id === id)
      if (!summary || !summary.enabled) throw new Error('학습 팩을 사용할 수 없어요.')
      if (summary.source === 'builtin' || summary.approvedAt) return
      coursesRepo.getById(courseId)
      const answer = await learningApprovals.request(randomUUID(), { type: 'question', message: `사용자 설치 팩 «${summary.pack.name}»을 실행할까요?`,
        detail: `버전: ${summary.pack.version}\n${summary.pack.description}`, buttons: ['취소', '이번만 허용', '항상 허용'], defaultId: 0, cancelId: 0 })
      if (!answer || (answer.response !== 1 && answer.response !== 2)) throw new Error('학습 팩 실행이 취소되었습니다.')
      if (answer.response === 2) packStore.approve(id, new Date().toISOString())
    },
    changedCourse: () => broadcast('courses:changed', {}),
    deletedCourse: releaseCourseRuntime,
    assertSourceTab: (courseId, tabId, url) => {
      coursesRepo.getById(courseId)
      const guest = guestRegistry.resolve(tabId)
      assertLiveStudyBrowserSource({ courseId, relPath: null, browserTabUrl: url, browserTabId: tabId }, guest, browsingContext(guest?.id ?? null))
    },
    resolveSource: async (binding, ref) => grounding.resolve(binding, ref, (await learningRepo.read(binding)).linkedCourseId),
    validateDraft: async (binding, draft) => {
      const state = await learningRepo.read(binding)
      const result = await normalizeLearningDraft(draft, state, id => learningRepo.readArticle(binding, id), grounding.validator(binding, state.linkedCourseId))
      if (result.articles?.length || result.wordUpdates?.length) throw new Error('가져오기에서는 퀴즈·카드·학습노트만 저장할 수 있어요.')
      const refs = [...(result.words?.map(word => word.sourceRef) ?? []), ...(result.artifacts?.flatMap(artifact => [...(artifact.sourceRefs ?? []), ...(artifact.kind === 'quiz' ? artifact.questions.flatMap(question => question.sourceRefs) : artifact.kind === 'cards' ? artifact.cards.flatMap(card => card.sourceRefs) : [])]) ?? [])]
      if (refs.some(ref => ref.kind === 'web')) throw new Error('원본 자료에서 확인한 출처 문장을 사용하세요.')
      return result
    }
  })

  // Refresh the dossier the agent reads at session start.
  // Best-effort: a context failure must not stop the student from chatting.
  // 응답한 뒤에 fire-and-forget 으로 미룬다 — 자료가 많은 과목에서 동기
  // rebuild 가 대화 열기(과목 전환)를 통째로 막고 있었다. 실제 첫 메시지가
  // 나가기 전에는 넉넉히 끝난다.
  handle('chat:open', async (req) => {
    setImmediate(() => {
      try {
        rebuildContextCoalesced(req.courseId)
      } catch (error) {
        console.error('[context] rebuild failed', error)
      }
    })
    const manager = await resolveConnectedManager(req.courseId, req.sessionId)
    return manager.open(
      req.courseId,
      req.sessionId,
      req.surface ?? 'app'
    )
  })
  handle('agent:skills', async (req) => (await discoverChatSkills(req.provider, coursesRepo.getFolder(req.courseId))).map(({ path: _path, ...skill }) => skill))
  handle('chat:importAttachments', async (req) => {
    const result = await importChatAttachments(coursesRepo.getFolder(req.courseId), req.paths)
    materialsRepo.invalidateTree(req.courseId)
    broadcast('materials:changed', { courseId: req.courseId })
    return result
  })
  handle('chat:openArtifact', (req) => {
    materialsRepo.absolutePathFor(req.courseId, req.relPath)
    deps.openMaterial({ ...req, positionSec: 0, playbackRate: 1 })
    return OK
  })
  handle('chat:pickAttachments', async () => {
    const result = await dialog.showOpenDialog({ title: '대화에 첨부', properties: ['openFile', 'multiSelections'] })
    return { paths: result.canceled ? [] : result.filePaths }
  })
  handle('chat:send', async (req) => {
    assertChatIdle(req.sessionId)
    const operation = { cancelled: false }
    chatOperations.set(req.sessionId, operation)
    let createdArtifactJob = false
    try {
      const manager = resolveManager(req.sessionId)
      const opened = await manager.open(req.courseId, req.sessionId)
      if (opened.sessionInfo?.status === 'running') throw new Error('진행 중인 응답이 끝난 뒤 보내 주세요.')
      const context = { ...req.context, snapshot: await snapshotContext(req.courseId, req.context?.sourcePanelId) }
      if (req.context?.excludeCurrentMaterial) delete context.snapshot.material
      try { contextWriter.rebuild(req.courseId, true) } catch { context.snapshot.refresh = 'failed' }
      // Only the attached page/selection is inline. The rest remains in the course file.
      if (context.snapshot.material?.relPath) materialsRepo.absolutePathFor(req.courseId, context.snapshot.material.relPath)
      if (context) delete context.outputDir
      if (context?.files && context.files.length > 20) throw new Error('파일은 한 번에 20개까지 첨부할 수 있어요.')
      for (const file of context?.files ?? []) materialsRepo.absolutePathFor(req.courseId, file.relPath)
      const installed = context?.skillIds?.length ? await discoverChatSkills(opened.sessionInfo?.provider ?? 'claude-code', coursesRepo.getFolder(req.courseId)) : []
      const skills = (context?.skillIds ?? []).map((id) => {
        const skill = installed.find((candidate) => candidate.id === id)
        if (!skill) throw new Error('선택한 스킬을 찾을 수 없어요. 추가 메뉴에서 다시 선택해 주세요.')
        return skill
      })
      if (context) context.skillNames = skills.map((skill) => skill.name)
      if (context?.creation && !skills.some((skill) => skill.creationKinds.includes(context.creation!))) throw new Error('이 생성 작업에 연결된 스킬이 없어요.')
      if (operation.cancelled) throw new Error('전송을 취소했어요.')
      if (context?.creation) {
        const dir = await createArtifactFolder(coursesRepo.getFolder(req.courseId))
        if (operation.cancelled) throw new Error('전송을 취소했어요.')
        context.outputDir = dir
        createdArtifactJob = true
        artifactJobs.set(req.sessionId, { courseId: req.courseId, dir, creation: context.creation })
      }
      return await manager.send(req.courseId, req.sessionId, req.content, req.attachments, context, skills.map((skill) => skill.path))
    } catch (error) {
      if (createdArtifactJob) artifactJobs.delete(req.sessionId)
      throw error
    } finally { chatOperations.delete(req.sessionId) }
  })
  handle('chat:cancel', (req) => {
    cancelChatOperation(req.sessionId)
    agentConfirmer.cancelConversation(req.sessionId)
    resolveManager(req.sessionId).cancel(req.courseId, req.sessionId)
    return OK
  })
  handle('chat:conversations', (req) => ({
    conversations: [...chatRepo.listConversations(req.courseId, 'app'), ...chatRepo.listConversations(req.courseId, 'desktop')].sort((a, b) => (b.lastUsedAt ?? b.createdAt).localeCompare(a.lastUsedAt ?? a.createdAt))
  }))
  handle('chat:grants', (req) => ({
    grants: chatRepo.listGrantDetails(req.courseId)
  }))
  handle('chat:revokeGrant', (req) => {
    chatRepo.removeGrant(req.id)
    return OK
  })

  handle('desktopAgent:permissionStatus', () => ({
    state: screenPermissionState(desktopSurface.access()),
    platform: process.platform
  }))
  handle('desktopAgent:openPermissionSettings', async () => {
    if (process.platform === 'darwin') {
      await shell.openExternal(
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
      )
    }
    return OK
  })

  // -- user MCP registry ---------------------------------------------------
  handle('mcp:list', () => ({
    servers: mcpRegistry.list(),
    availability: mcpRegistry.availability()
  }))
  handle('mcp:save', (req) => {
    const server = mcpRegistry.save(req)
    broadcast('mcp:changed', {})
    return { server }
  })
  handle('mcp:delete', (req) => {
    mcpRegistry.delete(req.id)
    broadcast('mcp:changed', {})
    return OK
  })
  handle('mcp:test', async (req) => {
    // Probe the saved authentication before enabling the server. Secrets stay
    // in main; the connection result and renderer summaries are redacted.
    const config = mcpRegistry.resolve(req.id)
    if (config === undefined) {
      throw new ValidationError('테스트할 MCP 서버를 찾을 수 없습니다.')
    }
    const result = await testMcpServer(config)
    if (!mcpRegistry.recordTest(req.id, result, config)) {
      return {
        ok: false,
        tools: [],
        durationMs: result.durationMs,
        error: '연결 검사 중 MCP 서버 설정이 바뀌거나 삭제되었습니다. 설정을 확인한 뒤 다시 연결을 확인해 주세요.'
      }
    }
    broadcast('mcp:changed', {})
    return result
  })
  handle('chat:deleteConversation', (req) => {
    // Close any warm CLI on every manager before the row disappears.
    sessionManager.close(req.courseId, req.sessionId)
    codexSessionManager.close(req.courseId, req.sessionId)
    geminiSessionManager.close(req.courseId, req.sessionId)
    chatRepo.softDeleteSession(req.sessionId)
    return OK
  })
  handle('agentTools:changes', (req) => agentJournal.forTurn(req.turnId))
  handle('agentTools:undo', (req) =>
    agentJournal.undoTurn(req.turnId, {
      course: async ({ targetId }) => {
        coursesRepo.softDelete({ courseId: targetId })
      },
      // Notes are files, so both go to the OS trash — recoverable, unlike a
      // hard unlink.
      material: async ({ courseId, targetId }) => {
        await materialsRepo.softDelete({ courseId, relPath: targetId })
      },
      link: async ({ courseId, targetId }) => {
        materialLinksRepo.remove(courseId, targetId)
        broadcast('materials:changed', { courseId })
      },
      note: async ({ courseId, targetId }) => {
        await materialsRepo.softDelete({ courseId, relPath: targetId })
      },
      task: async ({ targetId }) => {
        boardRepo.softDelete({ id: targetId })
      },
      board: async ({ targetId }) => {
        canvasRepo.removeBoard(targetId)
      },
      shape: async ({ targetId }) => {
        const [boardId, shapeId] = targetId.split('\u0000')
        if (boardId === undefined || shapeId === undefined) return
        canvasRepo.removeShapes({ boardId, ids: [shapeId] })
      },
      // 문서 제자리 편집(edit_sheet / edit_docx_text)의 되돌리기 —
      // 편집 직전 백업을 원래 경로 위로 복사한다. 파일이 그 사이
      // 이동/개명됐어도 원래 경로에 복원한다.
      'material-edit': async ({ courseId, targetId }) => {
        const parsed = parseMaterialEditTargetId(targetId)
        if (parsed === null) return
        restoreMaterialBackup({
          courseFolder: coursesRepo.getFolder(courseId),
          relPath: parsed.relPath,
          backupAbs: parsed.backupAbs
        })
        // watcher 도 곧 알아채지만, 즉시성을 위해 직접 무효화·브로드캐스트.
        materialsRepo.invalidateTree(courseId)
        refreshSearch(courseId)
        broadcast('materials:changed', { courseId })
      }
    })
  )
  handle('agentTools:confirmations', (req) => agentConfirmer.list(req.conversationId))
  handle('agentTools:respondConfirm', (req) => {
    return { ok: true as const, state: agentConfirmer.resolve(req) }
  })

  handle('chat:accessPolicy', async (req) => {
    const existing = chatRepo.getSession(req.sessionId)
    if (existing && existing.courseId !== req.courseId) throw new Error('대화가 이 과목에 속하지 않아요.')
    if (!req.policy) return existing?.accessPolicy ?? structuredClone(DEFAULT_AI_ACCESS)
    const manager = resolveManager(req.sessionId)
    const opened = await manager.open(req.courseId, req.sessionId)
    if (opened.sessionInfo?.status === 'running') throw new Error('진행 중인 응답을 마친 뒤 허용 모드를 바꿔 주세요.')
    if (!existing) chatRepo.createSession(req.sessionId, req.courseId, opened.sessionInfo?.provider ?? getSettings().agentProvider)
    const policy = parseAiAccess(req.policy)
    chatRepo.setAccessPolicy(req.sessionId, policy)
    manager.close(req.courseId, req.sessionId)
    return policy
  })

  handle('chat:respondPermission', (req) => {
    resolveManager(req.sessionId).respondPermission(
      req.courseId,
      req.sessionId,
      req.requestId,
      req.response
    )
    return OK
  })
  handle('chat:close', (req) => {
    cancelChatOperation(req.sessionId)
    artifactJobs.delete(req.sessionId)
    agentConfirmer.cancelConversation(req.sessionId)
    resolveManager(req.sessionId).close(req.courseId, req.sessionId)
    eventBatcher.flush(req.sessionId)
    return OK
  })
  handle('chat:setConfiguration', async (req) => {
    assertChatIdle(req.sessionId)
    const operation = { cancelled: false }
    chatOperations.set(req.sessionId, operation)
    try {
      const opened = await resolveManager(req.sessionId).open(req.courseId, req.sessionId)
      const provider = opened.sessionInfo?.provider ?? 'claude-code'
      const { models } = await getAgentModels(provider)
      const selected = models.find((model) => model.id === req.model || model.resolvedModel === req.model)
      if (!selected || (req.effort !== null && !selected.supportedEfforts?.includes(req.effort))) {
        throw new Error('이 모델에서 지원하지 않는 설정이에요. 모델 목록을 다시 확인해 주세요.')
      }
      if (operation.cancelled) throw new Error('설정 변경을 취소했어요.')
      resolveManager(req.sessionId).setModel(req.courseId, req.sessionId, req.model, req.effort)
      broadcast('chat:configurationChanged', { sessionId: req.sessionId, model: req.model, effort: req.effort })
      return { model: req.model, effort: req.effort }
    } finally { chatOperations.delete(req.sessionId) }
  })
  handle('chat:setModel', (req) => {
    assertChatIdle(req.sessionId)
    resolveManager(req.sessionId).setModel(req.courseId, req.sessionId, req.model)
    return OK
  })
  handle('chat:setProvider', async (req) => {
    assertChatIdle(req.sessionId)
    const row = chatRepo.getSession(req.sessionId)
    if (row?.status === 'running') {
      throw new Error('답변이 끝난 뒤에 바꿀 수 있어요.')
    }
    if (row === null || row.provider === req.provider) {
      closeConversationManagers(req.courseId, req.sessionId)
      const opened = await managerFor(req.provider).open(req.courseId, req.sessionId, req.surface ?? row?.surface ?? 'app')
      return { sessionInfo: opened.sessionInfo, carried: null }
    }
    const { text: _text, ...carried } = serializeTranscript(
      chatRepo.historyTail(req.sessionId, CARRYOVER_HISTORY_LIMIT)
    )
    const sessionInfo = switchConversationProvider(
      req.courseId,
      req.sessionId,
      req.provider
    )
    return { sessionInfo, carried }
  })

  // -- agent (M4-H) ---------------------------------------------------------
  handle('agent:availability', async (req) =>
    agentAvailability.check(req.provider, { refresh: req.refresh })
  )

  // An explicit Connect click authorizes the official installation. The UI
  // keeps installation details available without requiring terminal knowledge.
  // The SAME locator singletons
  // that serve `agent:availability` are passed in so post-install
  // verification resets the caches the renderer actually queries.
  const agentInstaller = createAgentInstaller({
    broadcast: (progress) => broadcast('agent:install-progress', progress),
    locators: agentLocators
  })
  const loginLauncher = createLoginLauncher({
    locators: agentLocators,
    broadcast: progress => broadcast('agent:login-progress', progress),
    openBrowser: (url, context) => broadcast('browser:open-url', { url, isPrivate: true, loginRequestId: context.requestId, loginProvider: context.provider }),
    openExternal: url => shell.openExternal(url)
  })
  app.on('will-quit', () => loginLauncher.dispose())
  process.on('exit', () => loginLauncher.dispose())
  // -- AI study tools --------------------------------------------------------
  // The recipes run through the course's normal agent session and write their
  // answer into the course folder, so a result is editable, survives the
  // session, and becomes context for later questions.
  const workflowSessionIds = new Map<string, string>()
  const workflowSessionIdFor = (courseId: string): string => {
    const active = workflowSessionIds.get(courseId)
    if (active !== undefined) return active
    const sessionId = chatRepo.listConversations(courseId)[0]?.id ?? randomUUID()
    workflowSessionIds.set(courseId, sessionId)
    return sessionId
  }
  const releaseWorkflowSession = (
    courseId: string,
    sessionId: string
  ): void => {
    if (workflowSessionIds.get(courseId) === sessionId) {
      workflowSessionIds.delete(courseId)
    }
  }
  const packRunner = createPackRunner({
    store: {
      resolve: id => { const pack = packStore.resolve(id); return pack ? getLegacyPack(pack) : null },
      list: () => packStore.list().map(summary => summary.source === 'builtin' ? { ...summary, pack: getLegacyPack(summary.pack) } : summary),
      approve: (id, at) => packStore.approve(id, at)
    },
    runGuard: {
      arm(courseId, restriction) {
        const sessionId = workflowSessionIdFor(courseId)
        legacyGuardSessions.set(courseId, sessionId)
        packRunGuard.arm(sessionId, restriction)
      },
      clear(courseId) {
        const sessionId = legacyGuardSessions.get(courseId)
        if (sessionId) { packRunGuard.clear(sessionId); legacyGuardSessions.delete(courseId) }
      }
    },
    getCourse: (courseId) => ({
      name: coursesRepo.getById(courseId).name,
      folder: coursesRepo.getFolder(courseId)
    }),
    ask: async (courseId, prompt) => {
      // Study tools ride the course's newest conversation so their answer
      // lands where the student is already talking; a course with no
      // conversations yet gets a fresh one.
      const sessionId = workflowSessionIdFor(courseId)
      const completed = new Promise<void>((resolve, reject) => legacyPackSettlers.set(sessionId, { resolve, reject }))
      void completed.catch(() => undefined)
      // Attach before dispatch: a provider can complete synchronously during sendMessage.
      const manager = resolveManager(sessionId)
      const timer = setTimeout(() => { manager.cancel(courseId, sessionId); legacyPackSettlers.get(sessionId)?.reject(new Error('학습 작업 시간이 초과되었습니다.')) }, 15 * 60 * 1000)
      timer.unref()
      try {
        await manager.send(courseId, sessionId, prompt)
        await completed
      } finally {
        clearTimeout(timer)
        legacyPackSettlers.delete(sessionId)
        releaseWorkflowSession(courseId, sessionId)
      }
    },
    confirm: async (request) => {
      const sessionId = workflowSessionIdFor(request.courseId)
      try {
        const result = await agentConfirmer.confirm({
          ...request,
          conversationId: sessionId
        })
        if (result === false) {
          releaseWorkflowSession(request.courseId, sessionId)
        }
        return result
      } catch (error) {
        releaseWorkflowSession(request.courseId, sessionId)
        throw error
      }
    },
    recordActivity: (courseId, summary, relPath) => {
      note(courseId, 'study-tool-run', summary, relPath)
    },
    getPlanningContext: (courseId) => ({
      asOf: new Date().toISOString(),
      upcomingDeadlines: boardRepo
        .upcoming({ courseId, withinDays: 30, limit: 8 })
        .flatMap(({ task, daysLeft }) =>
          task.dueAt === null
            ? []
            : [{ title: task.title, dueAt: task.dueAt, daysLeft }]
        ),
      studyGaps: insights.gaps(courseId)
    })
  })

  handle('packs:list', () => ({ packs: packStore.list() }))
  handle('packs:importText', (req) => packStore.importText(req.json))
  handle('packs:remove', (req) => {
    packStore.remove(req.id)
    return OK
  })
  handle('packs:setEnabled', (req) => {
    packStore.setEnabled(req.id, req.enabled)
    return OK
  })
  handle('study:tools', () => ({
    tools: packStore.list().map(({ pack, source, enabled }) => ({
      id: pack.id,
      label: pack.name,
      description: pack.description,
      worksOnCourse: pack.worksOn.includes('course'),
      source,
      enabled,
      usesWeb: pack.usesWeb,
      ...(pack.schemaVersion === 2 ? { experience: pack.experience } : {}),
      outputs: { ...pack.outputs },
      ...(pack.followUp === undefined
        ? {}
        : { followUp: { ...pack.followUp } })
    }))
  }))
  handle('study:run', (req) => {
    const sourceGuest = req.browserTabId ? guestRegistry.resolve(req.browserTabId) : null
    assertLiveStudyBrowserSource(req, sourceGuest, browsingContext(sourceGuest?.id ?? null))
    return packRunner.run({
      courseId: req.courseId,
      packId: req.tool,
      ...(req.relPath === null ? {} : { targetRelPath: req.relPath }),
      ...(req.selection === undefined
        ? {}
        : { selectionText: req.selection }),
      ...(req.browserTabUrl === undefined ? {} : { browserTabUrl: req.browserTabUrl }),
      ...(req.followUpOf === undefined
        ? {}
        : { followUpOf: req.followUpOf })
    })
  })

  handle('agent:installCommand', (req) => agentInstaller.commandFor(req.provider))
  handle('agent:install', (req) => agentInstaller.install(req.provider))
  handle('agent:login', async (req) => {
    const result = await loginLauncher.login(req.provider, req.requestId)
    void agentAvailability.check(req.provider, { refresh: true }).catch(() => undefined)
    return result
  })
  handle('agent:cancelLogin', req => loginLauncher.cancel(req.provider, req.requestId))
  handle('agent:reopenLogin', req => loginLauncher.reopen(req.provider, req.external, req.requestId))
  handle('agent:submitLoginCode', req => loginLauncher.submitCode(req.provider, req.code, req.requestId))
  handle('agent:models', (req) => getAgentModels(req.provider, req.refresh))
  handle('agent:geminiApiKey', () => geminiApiKeyStore.get())
  handle('agent:setGeminiApiKey', (req) => {
    const result = geminiApiKeyStore.set(req.key)
    geminiSessionManager.invalidateCredentials()
    void agentAvailability.check('gemini', { refresh: true }).catch(() => undefined)
    return result
  })

  // -- saved logins ----------------------------------------------------------
  // `resolve()` deliberately has no channel. The password is read here, put
  // straight into the guest page, and never travels back to the renderer.
  initializeBrowserProfiles(db)
  handle('assistant:capture', req => selectScreen(req.region))
  handle('assistant:selection', (req, event) => screenSelectionRequest(event, req))
  handle('browser:profiles', () => listBrowserProfiles())
  handle('browser:saveProfile', (req) => saveBrowserProfile(req))
  handle('browser:deleteProfile', async (req) => {
    if (browserImportService.isProfileBusy(req.id)) throw new Error('가져오기가 진행 중인 프로필은 삭제할 수 없습니다.')
    const answer = await dialog.showMessageBox({ type: 'warning', message: '이 브라우저 프로필과 로그인·방문 기록을 삭제할까요?', buttons: ['취소', '삭제'], defaultId: 0, cancelId: 0 })
    if (answer.response === 1) {
      if (browserImportService.isProfileBusy(req.id)) throw new Error('가져오기가 진행 중인 프로필은 삭제할 수 없습니다.')
      await deleteBrowserProfile(req.id)
    }
    return OK
  })
  const loginBridges = new Map<string, { fill: ReturnType<typeof createLoginFiller>; capture: ReturnType<typeof createLoginCapturer> }>()
  function loginBridgeFor(id: number) {
    const profile = guestProfile(id)
    if (profile.isPrivate) throw new Error('시크릿 탭에는 로그인 정보를 저장하지 않습니다.')
    if (!loginBridges.has(profile.profileId)) {
      const store = browserProfileResources(profile.profileId).credentials
      loginBridges.set(profile.profileId, { fill: createLoginFiller(store), capture: createLoginCapturer(store) })
    }
    return loginBridges.get(profile.profileId)!
  }
  handle('credentials:availability', (req) => browserProfileResources(req.profileId).credentials.availability())
  handle('credentials:list', (req) => browserProfileResources(req.profileId).credentials.list())
  handle('credentials:save', (req) => browserProfileResources(req.profileId).credentials.save(req))
  handle('credentials:capture', (req) => loginBridgeFor(req.guestWebContentsId).capture(req))
  handle('credentials:forget', (req) => browserProfileResources(req.profileId).credentials.forget(req.origin, req.credentialId))
  handle('credentials:fill', (req) => loginBridgeFor(req.guestWebContentsId).fill(req))


  // -- favorites (left-rail pins for any TabDescriptor) ---------------------
  const favoritesRepo = createFavoritesRepo(db)
  handle('favorites:list', (req) => favoritesRepo.list(req.courseId))
  handle('favorites:add', (req) => favoritesRepo.add(req))
  handle('favorites:rename', (req) => favoritesRepo.rename(req))
  handle('favorites:remove', (req) => {
    favoritesRepo.softDelete(req.id)
    return OK
  })
  handle('favorites:reorder', (req) => {
    favoritesRepo.reorder(req)
    return OK
  })
  const browserImportService = registerBrowserImportHandlers(handle, favoritesRepo)

  // -- browser session ------------------------------------------------------
  // Restore / auto-persist / before-quit are already wired inside
  // hardenBrowsingSession; this factory returns that same singleton, so only
  // the IPC surface is left to connect.
  const extensionManagers = new Map<string, ReturnType<typeof createBrowserExtensionManager>>()
  const extensionPreferences = new Map<string, import('../../shared/types/settings').BrowserExtensionPreference[]>()
  function extensionManagerFor(id = 'default') {
    ensureProfileSession(id)
    if (extensionManagers.has(id)) return extensionManagers.get(id)!
    const preferencesFile = id === 'default' ? '' : join(profileDirectory(id), 'extensions.json')
    if (preferencesFile && existsSync(preferencesFile)) {
      try {
        const raw: unknown = JSON.parse(readFileSync(preferencesFile, 'utf8'))
        if (!Array.isArray(raw)) throw new Error('Invalid extension preferences')
        extensionPreferences.set(id, raw.filter(p => typeof p?.path === 'string' && typeof p?.enabled === 'boolean'))
      } catch { quarantineFile(preferencesFile) }
    }
    const manager = createBrowserExtensionManager({
    session: ensureProfileSession(id),
    getPreferences: () => id === 'default' ? getSettings().browser.extensions : extensionPreferences.get(id) ?? [],
    setPreferences: (extensions) => {
      if (id === 'default') setSettings({ browser: { extensions } })
      else {
        extensionPreferences.set(id, [...extensions])
        mkdirSync(profileDirectory(id), { recursive: true })
        writeFileAtomic(preferencesFile, JSON.stringify(extensions))
      }
    }
  })
  extensionManagers.set(id, manager)
  void manager.restore().catch((error: unknown) => {
    console.warn('[browser] extension restore failed', error)
  })
  return manager
  }
  const browserExtensionManager = extensionManagerFor()
  handle('browser:sessionSites', async (req) => ({
    sites: await browserProfileResources(req.profileId).cookies.listSites()
  }))
  handle('browser:extensions', (req) => ({
    extensions: extensionManagerFor(req.profileId).list()
  }))
  handle('browser:installExtension', async (req) => {
    const owner = BrowserWindow.getFocusedWindow()
    const options: Electron.OpenDialogOptions = {
      title: '압축 해제된 Manifest V3 확장 폴더 선택',
      buttonLabel: '확장 추가',
      properties: ['openDirectory']
    }
    const picked = owner === null
      ? await dialog.showOpenDialog(options)
      : await dialog.showOpenDialog(owner, options)
    const path = picked.filePaths[0]
    if (picked.canceled || path === undefined) return { extension: null }
    return { extension: await extensionManagerFor(req.profileId).install(path) }
  })
  handle('browser:setExtensionEnabled', async (req) => ({
    extensions: await extensionManagerFor(req.profileId).setEnabled(req.path, req.enabled)
  }))
  handle('browser:removeExtension', async (req) => ({
    extensions: await extensionManagerFor(req.profileId).remove(req.path)
  }))

  handle('browser:controlDownload', (req) => {
    if (req.action === 'cancel') downloadControls.cancel(req.id)
    else if (req.action === 'pause') downloadControls.pause(req.id)
    else downloadControls.resume(req.id)
    return OK
  })
  /**
   * Clearing cookies was never enough.
   *
   * An LMS keeps its JWT in localStorage and a Canvas-style SPA restores from
   * IndexedDB, so "로그아웃" left the student logged in. And a stale service
   * worker registered by a 학사 포털 serves an old bundle forever — the
   * classic "저만 깨져요, 크롬에선 되는데요" with no button that fixes it.
   */
  handle('browser:clearStorage', async (req) => {
    const browsing = ensureProfileSession(req.profileId)
    forgetGoogleAccountNavigation(browsing)
    await browsing.clearStorageData(
      req.origin === null ? {} : { origin: req.origin }
    )
    if (req.cache) await browsing.clearCache()
    return OK
  })

  // -- site permissions -----------------------------------------------------
  // The session's permission handlers are installed before any window exists,
  // so they take the repo by injection rather than importing the database.
  const permissionsRepo = createPermissionsRepo(db)
  useSitePermissions(permissionsRepo)
  handle('browser:sitePermissions', (req) => ({
    permissions: browserProfileResources(req.profileId).permissions.list()
  }))
  handle('browser:forgetPermission', (req) => {
    const permissionsRepo = browserProfileResources(req.profileId).permissions
    if (req.id === null) permissionsRepo.forgetAll()
    else permissionsRepo.forget(req.id)
    return OK
  })
  handle('browser:setPopupPermission', (req) => {
    let origin: string
    try {
      const parsed = new URL(req.origin)
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new Error()
      origin = parsed.origin
    } catch {
      throw new ValidationError('팝업 사이트 주소가 올바르지 않아요')
    }
    browserProfileResources(req.profileId).permissions.remember(origin, 'popups', req.decision)
    return OK
  })

  // -- browser downloads ----------------------------------------------------
  handle('browser:setDownloadTarget', (req) => {
    setBrowsingCourse(req.webContentsId, req.tabId, req.courseId)
    return OK
  })
  // -- browser history ------------------------------------------------------
  const historyRepo = createHistoryRepo(db)
  // Pruning on boot rather than per write keeps the visit path a single upsert.
  historyRepo.prune()
  handle('browser:recordVisit', (req) => {
    browserProfileResources(req.profileId).history.recordVisit(req)
    return OK
  })
  handle('browser:searchHistory', (req) => ({
    entries: browserProfileResources(req.profileId).history
      .search(req.query, req.limit)
      .map(({ url, title, host, visitCount, lastVisitedAt }) => ({
        url,
        title,
        host,
        visitCount,
        lastVisitedAt
      }))
  }))
  handle('browser:clearHistory', (req) => {
    browserProfileResources(req.profileId).history.clear(req.courseId)
    return OK
  })
  const faviconFetchers = new Map<string, ReturnType<typeof createFaviconFetcher>>()
  onBrowserProfileDeleted((profileId, partitions) => {
    loginBridges.delete(profileId)
    extensionManagers.delete(profileId)
    extensionPreferences.delete(profileId)
    for (const key of faviconFetchers.keys()) if (key.startsWith(`${profileId}:`)) faviconFetchers.delete(key)
    forgetProfilePermissions(partitions)
  })
  handle('browser:favicon', async (req) => {
    const profileId = req.profileId ?? 'default'
    const id = `${profileId}:${req.isPrivate === true}`
    if (!faviconFetchers.has(id)) faviconFetchers.set(id, createFaviconFetcher({ fetch: (url) => ensureProfileSession(profileId, req.isPrivate).fetch(url) }))
    return { dataUrl: await faviconFetchers.get(id)!(req.url) }
  })
  handle('browser:courseForUrl', (req) => ({
    courseId: matchCourseByUrl(
      req.url,
      coursesRepo
        .list({ includeArchived: false })
        .flatMap((course) =>
          courseLinksRepo.list({ courseId: course.id }).map((link) => ({
            courseId: course.id,
            url: link.url,
            lmsCourseId: link.lmsCourseId ?? null
          }))
        )
    )
  }))

  handle('browser:prepareProfileSwitch', (req, event) => prepareProfileSwitch(event, req.tabId))
  handle('browser:prepareClose', (req, event) => prepareBrowserPageClose(event, req.tabId))
  handle('browser:createPage', (req, event) => createBrowserPage(event, req))
  handle('browser:setCourse', (req, event) => {
    if (req.courseId !== null) coursesRepo.getById(req.courseId)
    return setBrowserPageCourse(event, req)
  })
  handle('browser:pageBounds', (req, event) => setBrowserPageBounds(event, req))
  handle('browser:setHostOccluded', (req, event) => setBrowserHostOccluded(event, req.occluded))
  handle('browser:pageAction', (req, event) => browserPageAction(event, req))
  handle('browser:destroyPage', (req, event) => { destroyBrowserPage(event, req.tabId, req.expectedWebContentsId); return OK })
  handle('clipboard:beginCopy', () => ({ token: beginClipboardCopy() }))
  handle('clipboard:writeImage', writeImageClipboard)

  handle('browser:downloadFile', async ({ id, action }) => {
    const file = getDownloadFile(id)
    if (action === 'retry') {
      if (!file.retry) throw new Error('다시 저장할 파일이 없어요.')
      file.retry()
    } else if (action === 'reveal') shell.showItemInFolder(file.path)
    else if (action === 'open') {
      const error = await shell.openPath(file.path)
      if (error) throw new Error(error)
    } else {
      const result = await dialog.showSaveDialog({
        title: '다운로드 파일 다른 위치에 저장', defaultPath: file.fileName
      })
      if (!result.canceled && result.filePath && result.filePath !== file.path) {
        await copyFile(file.path, result.filePath)
      }
    }
    return OK
  })

  onBrowserSession((partition, id) => {
    hardenBrowsingSession(partition)
    if (partition.startsWith('persist:')) useProfilePermissions(partition, browserProfileResources(id).permissions)
    attachDownloadHandler(session.fromPartition(partition), {
      stagingRoot: join(app.getPath('userData'), 'download-recovery'),
      getTargetCourseId: (id) => browsingContext(id)?.courseId ?? null,
      resolveCourseFile: (courseId, relPath) => materialsRepo.absolutePathFor(courseId, relPath),
      onNavigationSettled: finishDownloadNavigation,
      getOwnerWebContentsId: (id) => browsingContext(id)?.rootId ?? id,
      adoptFile: (input) => materialsRepo.adoptFile(input),
      emit: (update) => {
        broadcast('browser:download', update)
        // The watcher also fires, but announcing the course explicitly keeps the
        // tree honest when the file lands while another course is on screen.
        if (update.state === 'completed' && update.courseId !== null) {
          broadcast('materials:changed', { courseId: update.courseId })
        }
      },
      onCompleted: (fileName) => {
        try {
          notifier.notify({
            kind: 'download',
            title: '다운로드 완료',
            body: fileName,
            courseId: null
          })
        } catch (error) {
          console.error('[notifications] download completion failed', error)
        }
      }
    })
  })
  ensureProfileSession()
  ensureProfileSession('default', true)
  for (const profile of listBrowserProfiles()) extensionManagerFor(profile.id)
  handle('browser:clearSession', (req) => browserProfileResources(req.profileId).cookies.clear(req.origin))

  // -- personal whiteboards (local only) -------------------------------------
  // `canvas:` and not `board:` — the latter already means the study TASK board.
  const canvasRepo = createCanvasRepo(db)
  handle('canvas:list', (req) => canvasRepo.listBoards(req.courseId))
  handle('canvas:create', (req) => {
    const board = canvasRepo.createBoard(req)
    return canvasRepo.setBackground({ boardId: board.id, background: getSettings().tabs.whiteboardBackground })
  })
  handle('canvas:rename', (req) => canvasRepo.renameBoard(req))
  handle('canvas:remove', (req) => {
    canvasRepo.removeBoard(req.id)
    return OK
  })
  handle('canvas:open', (req) => canvasRepo.open(req.boardId))
  handle('canvas:hoverPreview', (req) => canvasRepo.hoverPreview(req.boardId))
  handle('canvas:setBackground', (req) => canvasRepo.setBackground(req))
  handle('canvas:setPageCount', (req) => canvasRepo.setPageCount(req))
  const boardPdfExporter = createBoardPdfExporter({
    openBoard: (boardId) => canvasRepo.open(boardId),
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId)
  })
  handle('canvas:exportPdf', async (req) => {
    const result = await boardPdfExporter.exportBoard(req.boardId)
    const board = canvasRepo.open(req.boardId).board
    // 내보내기는 과목 폴더에 PDF 를 직접 떨어뜨린다 — 트리 캐시 무효화.
    materialsRepo.invalidateTree(board.courseId)
    // The export really does drop a new PDF into the course folder, so this is
    // a material appearing — no new activity kind needed.
    note(
      board.courseId,
      'material-added',
      `화이트보드를 PDF로 내보냈습니다: ${board.title}`,
      result.relPath
    )
    return result
  })
  handle('canvas:putShape', (req) => canvasRepo.putShape(req))
  handle('canvas:removeShapes', (req) => {
    canvasRepo.removeShapes(req)
    return OK
  })

  // -- note <-> material links -------------------------------------------------
  // The note stays plain markdown; the link is an ordinary markdown link with
  // a bandal: target, so the file still opens correctly in any other editor.
  const linkService = createLinkService({
    notes: notesRepo,
    getCourseFolder: (courseId) => coursesRepo.getFolder(courseId)
  })
  handle('links:forMaterial', (req) =>
    linkIndex.forMaterial(req.courseId, req.relPath)
  )

  handle('link:sendHighlightToNote', (req) => {
    const result = linkService.sendHighlightToNote(req)
    // 필기 파일이 과목 폴더에 새로 생기거나 바뀔 수 있다.
    materialsRepo.invalidateTree(req.courseId)
    note(
      req.courseId,
      'note-edited',
      `하이라이트를 필기로 보냈습니다: ${result.relPath}`,
      result.relPath
    )
    return result
  })

  handle('link:sendWebClipToNote', (req) => {
    const result = linkService.sendWebClipToNote(req)
    materialsRepo.invalidateTree(req.courseId)
    note(
      req.courseId,
      'note-edited',
      `웹 페이지를 필기로 보냈습니다: ${result.relPath}`,
      result.relPath
    )
    return result
  })

  // -- full-text search + study gaps -----------------------------------------
  // All full-text cache reads/writes belong to the background process and a
  // separate database, including pages already extracted by the renderer.
  const searchRefreshedAt = new Map<string, number>()
  const searchRefreshes = new Map<string, Promise<unknown>>()
  const refreshSearch = (courseId: string): void => {
    if (searchRefreshes.has(courseId) || Date.now() - (searchRefreshedAt.get(courseId) ?? 0) < 2000) return
    const task = background.request('searchRefresh', {
      dbPath: searchCachePath, courseId, folder: coursesRepo.getFolder(courseId)
    }, 2).then(() => { searchRefreshedAt.set(courseId, Date.now()); broadcast('search:changed', { courseId }) })
      .catch(error => console.warn('[search] background refresh failed', error))
      .finally(() => searchRefreshes.delete(courseId))
    searchRefreshes.set(courseId, task)
  }
  handle('search:query', async (req) => {
    const hits = await background.request('searchQuery', {
      ...req, dbPath: searchCachePath, folder: coursesRepo.getFolder(req.courseId)
    }, 0)
    refreshSearch(req.courseId)
    return { hits }
  })
  handle('search:indexPdfPages', async (req) => {
    await background.request('searchIndexPdf', { ...req, dbPath: searchCachePath, folder: coursesRepo.getFolder(req.courseId) }, 1)
    return OK
  })

  // -- third-party plugins -------------------------------------------------
  const pluginStore = createPluginStore({ userDataDir: deps.userDataPath })
  const pluginCatalog = createCatalogService({
    getMarketplaceUrl: marketplaceUrl,
    userDataDir: deps.userDataPath,
    getPluginSources: () => {
      const marketplace = marketplaceUrl()
      return [...getSettings().pluginSources, ...(marketplace === null ? [] : [`${marketplace}/index.json`])]
    },
    fetch: (url, init) => net.fetch(url, init)
  })
  const catalogInstaller = createCatalogInstaller({
    catalog: pluginCatalog,
    pluginStore,
    packStore,
    fetch: (url, init) => net.fetch(url, init),
    appVersion: () => resolveAppVersion(app.isPackaged, app.getVersion(), __APP_VERSION__)
  })
  const pluginData = createPluginDataStore({ userDataDir: deps.userDataPath })
  const studyMarketClient = createStudyMarketClient({ getClient: () => account.getClient(), fetch: (url, init) => net.fetch(url instanceof URL ? url.href : url, init) })
  const studyMarketBundles = createStudyMarketBundles({
    getCourseFolder: courseId => coursesRepo.getFolder(courseId),
    exportAnnotated: (input, path) => pdfExporter.exportAnnotated(input, path),
    listAnnotations: (courseId, relPath) => annotationsRepo.listForFile({ courseId, relPath }),
    fetch: (url, init) => net.fetch(url instanceof URL ? url.href : url, init),
    sanitizePreview: bytes => {
      const image = nativeImage.createFromBuffer(bytes)
      const size = image.getSize()
      if (image.isEmpty() || size.width > 2048 || size.height > 2048) throw new ValidationError('미리보기 이미지를 확인해 주세요.')
      return image.toPNG()
    }
  })
  app.once('will-quit', () => { void studyMarketBundles.dispose() })
  registerStudyMarketHandlers(handle, {
    client: studyMarketClient, bundles: studyMarketBundles,
    createCourse: name => { const course = coursesRepo.create({ name, color: 'blue' }); broadcast('courses:changed', {}); return course },
    changed: courseId => { materialsRepo.invalidateTree(courseId); broadcast('materials:changed', { courseId }); broadcast('courses:changed', {}) },
    openExternal: url => shell.openExternal(url),
    pickPreviewImage: async () => {
      const picked = await dialog.showOpenDialog({ title: '공개할 미리보기 이미지 선택', properties: ['openFile'], filters: [{ name: '이미지', extensions: ['png', 'jpg', 'jpeg', 'webp'] }] })
      if (picked.canceled || !picked.filePaths[0]) return null
      const { readFile, stat } = await import('node:fs/promises')
      if ((await stat(picked.filePaths[0])).size > 10 * 1024 * 1024) throw new ValidationError('미리보기 이미지는 10MB 이하로 선택해 주세요.')
      let image = nativeImage.createFromBuffer(await readFile(picked.filePaths[0]))
      if (image.isEmpty()) throw new ValidationError('이미지를 읽지 못했어요.')
      const size = image.getSize(); const ratio = Math.min(1, 1600 / Math.max(size.width, size.height))
      if (ratio < 1) image = image.resize({ width: Math.round(size.width * ratio), height: Math.round(size.height * ratio), quality: 'good' })
      const bytes = image.toPNG()
      if (bytes.length > 4 * 1024 * 1024) throw new ValidationError('더 작은 미리보기 이미지를 선택해 주세요.')
      return { dataUrl: `data:image/png;base64,${bytes.toString('base64')}` }
    }
  })
  const marketplace = createMarketplaceClient({ getClient: () => account.getClient(), fetch: (url, init) => net.fetch(url instanceof URL ? url.href : url, init) })
  handle('marketplace:dashboard', () => marketplace.dashboard())
  handle('marketplace:release', (req) => marketplace.release(req.id))
  handle('marketplace:resolveReport', async (req) => { await marketplace.resolveReport(req.id, req.reason); return OK })
  handle('marketplace:register', async (req) => { await marketplace.register(req.id, req.displayName); return OK })
  handle('marketplace:submit', async (req) => {
    const picked = await dialog.showOpenDialog({ title: 'Submit plugin ZIP', properties: ['openFile'], filters: [{ name: 'Plugin archive', extensions: ['zip'] }] })
    const file = picked.filePaths[0]
    if (picked.canceled || file === undefined) return { canceled: true }
    if ((await stat(file)).size > 8 * 1024 * 1024) throw new ValidationError('Plugin ZIP exceeds 8 MiB')
    const bytes = await readFile(file)
    await inspectPluginArchive(bytes)
    await marketplace.submit(bytes.toString('base64'), req.changelog)
    return { canceled: false }
  })
  handle('marketplace:review', async (req) => { await marketplace.review(req.id, req.decision, req.reason); return OK })
  handle('marketplace:report', async (req) => { await marketplace.report(req.releaseId, req.reason); return OK })
  handle('marketplace:reviewBundle', async (req) => {
    const picked = await dialog.showSaveDialog({ title: 'Save plugin review bundle', defaultPath: 'plugin-review.zip', filters: [{ name: 'Plugin archive', extensions: ['zip'] }] })
    if (picked.canceled || !picked.filePath) return { canceled: true }
    const bytes = await marketplace.reviewBundle(req.id)
    writeFileSync(picked.filePath, bytes)
    return { canceled: false }
  })
  const pluginEditor = createPluginEditorBridge((request) => broadcast('plugins:editorRequest', request))
  const pluginSettings = createPluginSettings({
    data: pluginData,
    manifest: (id) => pluginStore.manifestFor(id),
    changed: (pluginId, values) => {
      broadcast('plugins:settingsChanged', { pluginId, values })
      emitPluginEvent('settings:changed', { pluginId, values })
    }
  })
  const pluginLog = createPluginLog()
  const pluginLimiter = createPluginRateLimiter()
  const pluginChanged = (): void => {
    broadcast('plugins:changed', { plugins: pluginStore.list() })
  }
  const pluginApi = createPluginApi({
    editor: pluginEditor,
    configuration: {
      ...pluginSettings,
      has: (id, key) => pluginStore.manifestFor(id)?.contributes.settings?.some((field) => field.key === key) ?? false
    },
    courses: coursesRepo,
    notes: notesRepo,
    materials: materialsRepo,
    data: pluginData,
    currentCourseId: () => workspaceSnapshot.selectedCourseId,
    onNoteSaved: (courseId, relPath) => {
      emitPluginEvent('note:saved', { courseId, relPath })
      broadcast('materials:changed', { courseId })
    },
    showNotice: (pluginId, message, tone) => {
      const pluginName =
        pluginStore.get(pluginId)?.manifest.name ?? pluginId
      broadcast('plugins:notice', { pluginId, pluginName, message, tone })
      try {
        notifier.notify({
          kind: 'plugin',
          title: pluginName,
          body: message,
          courseId: null
        })
      } catch (error) {
        console.error('[notifications] plugin notice failed', error)
      }
    },
    openPanel: (pluginId, panelId) => {
      broadcast('plugins:openPanel', { pluginId, panelId })
    },
    closePanel: (pluginId, panelId) => broadcast('plugins:closePanel', { pluginId, panelId }),
    postPanel: postPluginPanelMessage,
    panelExists: (pluginId, panelId) =>
      pluginStore
        .manifestFor(pluginId)
        ?.contributes.panels.some((panel) => panel.id === panelId) ?? false,
    networkAllowed: (pluginId, url) => {
      const plugin = pluginStore.get(pluginId)
      return (
        plugin?.approvedPermissions !== null &&
        plugin?.approvedPermissions !== undefined &&
        isMethodAllowed(plugin.approvedPermissions, 'net.fetch', url)
      )
    }
  })
  const pluginRuntime = createPluginRuntime({
    store: pluginStore,
    api: pluginApi,
    limiter: pluginLimiter,
    log: pluginLog,
    preloadPath: join(__dirname, '../preload/pluginHost.js'),
    appVersion: resolveAppVersion(
      app.isPackaged,
      app.getVersion(),
      __APP_VERSION__
    ),
    changed: pluginChanged
  })
  emitPluginEvent = (name, payload) => pluginRuntime.sendEvent(name, payload)
  const pluginDevelopment = createPluginDevelopment({ store: pluginStore,
    unload: (id) => pluginRuntime.unload(id), changed: pluginChanged,
    log: (pluginId, message) => pluginLog.push({ pluginId, level: 'info', message }) })
  const stopPluginPanels = configurePluginPanels({
    store: pluginStore,
    preloadPath: deps.pluginPanelPreloadPath,
    onPanelMessage: (pluginId, panelId, payload) => {
      pluginRuntime.sendPanelMessage(pluginId, panelId, payload)
    },
    log: (pluginId, message) => {
      pluginLog.push({ pluginId, level: 'denied', message })
    }
  })

  const syncEnabledPlugins = (): void => {
    if (!getSettings().experimental.extensionRuntime) return
    void pluginRuntime.syncEnabled().catch((error: unknown) => {
      console.error('[plugins] enabled-plugin startup failed', error)
    })
  }
  const stopEnabledPlugins = (): void => {
    for (const plugin of pluginStore.list()) {
      pluginRuntime.unload(plugin.manifest.id)
      pluginStore.setState(plugin.manifest.id, 'disabled')
    }
    pluginChanged()
  }
  syncEnabledPlugins()

  app.on('will-quit', () => {
    stopPluginPanels()
    void pluginDevelopment.dispose()
    pluginEditor.dispose()
    pluginRuntime.dispose()
  })

  handle('plugins:list', () => ({ plugins: pluginStore.list() }))
  handle('plugins:devFolders', () => ({ folders: pluginDevelopment.list() }))
  handle('plugins:watchFolder', async (req) => { await pluginDevelopment.start(req.path); return OK })
  handle('plugins:unwatchFolder', async (req) => { await pluginDevelopment.stop(req.id); return OK })
  handle('plugins:getSettings', (req) => ({ values: pluginSettings.get(req.id) }))
  handle('plugins:editorReply', (req) => {
    pluginEditor.reply(req.requestId, req.value, req.error)
    return OK
  })
  handle('plugins:setSetting', (req) => {
    pluginSettings.set(req.id, req.key, req.value)
    return { values: pluginSettings.get(req.id) }
  })
  handle('plugins:resetSettings', (req) => ({ values: pluginSettings.reset(req.id) }))
  handle('plugins:catalog', (req) => pluginCatalog.get(req.refresh))
  handle('plugins:installFromCatalog', async (req) => {
    const installed = await catalogInstaller.install(req.sourceUrl, req.id)
    if (installed.kind === 'extension') {
      pluginRuntime.unload(installed.plugin.manifest.id)
      pluginChanged()
    }
    return installed
  })
  handle('plugins:pickFolder', async () => {
    const parent =
      BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
    const options: Electron.OpenDialogOptions = {
      title: '플러그인 폴더 선택',
      buttonLabel: '이 폴더 설치',
      properties: ['openDirectory']
    }
    const result =
      parent === undefined
        ? await dialog.showOpenDialog(options)
        : await dialog.showOpenDialog(parent, options)
    return { path: result.canceled ? null : (result.filePaths[0] ?? null) }
  })
  handle('plugins:installFromFolder', async (req) => {
    const installed = await pluginStore.installFromFolder(req.path)
    // A re-install replaces files underneath a possibly active old instance.
    // Stop that instance even though the new registry entry is disabled.
    pluginRuntime.unload(installed.plugin.manifest.id)
    pluginChanged()
    return installed
  })
  handle('plugins:uninstall', async (req) => {
    await pluginDevelopment.stop(req.id)
    pluginRuntime.unload(req.id)
    await pluginStore.uninstall(req.id)
    pluginData.remove(req.id)
    pluginLimiter.reset(req.id)
    pluginChanged()
    return OK
  })
  handle('plugins:setEnabled', async (req) => {
    let plugin = pluginStore.setEnabled(req.id, req.enabled)
    if (!req.enabled) {
      pluginRuntime.unload(req.id)
      pluginChanged()
      return { plugin }
    }
    pluginChanged()
    if (plugin.state === 'needs-approval') return { plugin }
    if (!getSettings().experimental.extensionRuntime) return { plugin }
    try {
      plugin = await pluginRuntime.load(req.id)
    } catch (error) {
      pluginLog.push({
        pluginId: req.id,
        level: 'error',
        message: `activation failed: ${
          error instanceof Error ? error.message : String(error)
        }`
      })
      plugin = pluginStore.get(req.id) ?? plugin
    }
    return { plugin }
  })
  handle('plugins:approve', (req) => {
    const plugin = pluginStore.approve(req.id)
    pluginChanged()
    return { plugin }
  })
  handle('plugins:reload', async (req) => {
    let plugin = pluginStore.get(req.id)
    if (plugin === null) throw new ValidationError(`unknown plugin "${req.id}"`)
    if (!getSettings().experimental.extensionRuntime) return { plugin }
    try {
      plugin = await pluginRuntime.reload(req.id)
    } catch (error) {
      pluginLog.push({
        pluginId: req.id,
        level: 'error',
        message: `reload failed: ${
          error instanceof Error ? error.message : String(error)
        }`
      })
      plugin = pluginStore.get(req.id) ?? plugin
    }
    return { plugin }
  })
  handle('plugins:runCommand', async (req) => {
    if (!getSettings().experimental.extensionRuntime) {
      throw new ValidationError('확장 플러그인 런타임이 설정에서 꺼져 있어요')
    }
    await pluginRuntime.runCommand(req.pluginId, req.commandId, req.context)
    return OK
  })
  handle('plugins:logs', (req) => ({
    entries: pluginLog.list(req.id)
  }))

  // -- system permissions & diagnostics -----------------------------------
  const systemPermissions = createSystemPermissions({
    platform: process.platform,
    getDataRoot: () => getSettings().dataRoot,
    getScreenAccess: () => systemPreferences.getMediaAccessStatus('screen'),
    requestScreenAccess: () =>
      desktopCapturer.getSources({
        types: ['screen'],
        thumbnailSize: { width: 1, height: 1 }
      }),
    isTrustedAccessibilityClient: (prompt) =>
      systemPreferences.isTrustedAccessibilityClient(prompt),
    notificationIsSupported: () => Notification.isSupported(),
    openExternal: (url) => shell.openExternal(url)
  })
  const writeDiagnostics = createDiagnosticsBundle({
    tempDir: tmpdir,
    now: () => new Date(),
    appVersion: () =>
      resolveAppVersion(app.isPackaged, app.getVersion(), __APP_VERSION__),
    electronVersion: () => process.versions.electron ?? 'unknown',
    platform: process.platform,
    osVersion: release,
    getSettings,
    getAgentAvailability: (provider) =>
      agentAvailability.check(provider),
    getPlugins: () => pluginStore.list(),
    getPluginLogs: () => pluginLog.list(null),
    logsPath: () => app.getPath('logs'),
    reveal: (path) => shell.showItemInFolder(path)
  })

  handle('permissions:status', () => systemPermissions.status())
  handle('permissions:request', (req) => {
    if (!isSystemPermissionId(req.id)) {
      throw new ValidationError('권한 항목이 올바르지 않아요')
    }
    return systemPermissions.request(req.id)
  })
  handle('permissions:openSettings', (req) => {
    if (!isSystemPermissionId(req.id)) {
      throw new ValidationError('권한 항목이 올바르지 않아요')
    }
    return systemPermissions.openSettings(req.id)
  })
  handle('app:diagnostics', () => writeDiagnostics())

  // -- settings (real implementation, settingsStore-owned) ------------------
  handle('settings:get', () => getSettings())
  const applyExtensionRuntimeChange = (
    previous: Settings,
    next: Settings
  ): void => {
    if (
      previous.experimental.extensionRuntime ===
      next.experimental.extensionRuntime
    ) {
      return
    }
    if (next.experimental.extensionRuntime) syncEnabledPlugins()
    else stopEnabledPlugins()
  }
  handle('settings:set', (req) => {
    const previous = getSettings()
    const next = setSettings(req)
    applyExtensionRuntimeChange(previous, next)
    if (JSON.stringify(previous.browser.extensions) !== JSON.stringify(next.browser.extensions)) {
      void browserExtensionManager.reconcile()
    }
    return next
  })
  // [R3] dataRoot 변경. 새 과목만 새 위치에 생긴다 — 기존 과목 폴더는 절대
  // 경로로 저장되어 있으므로 옮기지 않고 그대로 동작한다.
  handle('settings:pickDataRoot', async () => {
    const parent = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
    const options: Electron.OpenDialogOptions = {
      title: '과목 데이터 폴더 선택',
      buttonLabel: '이 폴더 사용',
      defaultPath: getSettings().dataRoot,
      properties: ['openDirectory', 'createDirectory']
    }
    const result =
      parent === undefined
        ? await dialog.showOpenDialog(options)
        : await dialog.showOpenDialog(parent, options)
    const picked = result.filePaths[0]
    if (result.canceled || picked === undefined) return null
    const dataRoot = normalizeFolderPath(picked)
    try {
      accessSync(dataRoot, fsConstants.W_OK)
    } catch {
      throw new ValidationError(
        '선택한 폴더에 쓸 수 없습니다. 다른 폴더를 골라 주세요.'
      )
    }
    // setSettings 가 저장 + settings:changed 브로드캐스트까지 처리한다.
    setSettings({ dataRoot })
    return { dataRoot }
  })
  handle('settings:reset', () => {
    const previous = getSettings()
    const next = resetSettings(setSettings)
    applyExtensionRuntimeChange(previous, next)
    void browserExtensionManager.reconcile()
    return next
  })
  handle('notifications:test', () => notifier.test())
  handle('app:openLogs', async () => {
    const logsPath = app.getPath('logs')
    mkdirSync(logsPath, { recursive: true })
    const error = await shell.openPath(logsPath)
    if (error !== '') throw new Error(error)
    return OK
  })
  handle('app:clearCache', async () => {
    await Promise.all([
      session.fromPartition(BROWSING_PARTITION).clearCache(),
      session.defaultSession.clearCache()
    ])
    return OK
  })
  handle('usage:summary', (req) => {
    if (!isUsageWindowDays(req.windowDays)) {
      throw new ValidationError('사용량 조회 기간이 올바르지 않습니다.')
    }
    return usageRepo.summary(req.windowDays)
  })

  // -- layout ---------------------------------------------------------------
  handle('layout:get', (req) => layoutRepo.get(req.courseId))
  handle('layout:save', (req) => layoutRepo.save(req.courseId, req.layout))
  handle('layout:saveMany', (req) => layoutRepo.saveMany(req.layouts))

  const account = createAccountRuntime(state => broadcast('auth:changed', state))
  const ipadCompanion = installIPadCompanion({
    db,
    userDataPath: deps.userDataPath ?? app.getPath('userData'),
    getClient: () => account.getClient(),
    changed: courseIds => {
      broadcast('courses:changed', {})
      broadcast('board:changed', { courseId: null })
      for (const courseId of courseIds) {
        materialsRepo.invalidateTree(courseId)
        broadcast('materials:changed', { courseId })
      }
    }
  })
  app.on('will-quit', () => ipadCompanion.dispose())


  // Give queued IPC one turn of the event loop before the process goes away.
  //
  // `notes:write` is synchronous once its handler runs, so a note is safe the
  // moment main *handles* the message. The gap is earlier: the renderer's
  // autosave fires `invoke('notes:write')` and the app can quit while that
  // message is still in flight, which loses the student's last edit with no
  // error anywhere. The renderer cannot close this on its own.
  //
  // This is a mitigation, not a guarantee — it does not survive SIGKILL or a
  // crash. It does cover the ordinary "⌘Q right after typing" case, which is
  // the one students actually hit.
  const quitDrain = createQuitDrain(() => app.quit(), QUIT_DRAIN_MS)
  app.on('before-quit', quitDrain.beforeQuit)

  app.on('will-quit', () => account.dispose())

  // auth
  handle('auth:getState', () => account.auth().getState())
  handle('auth:signIn', (req) => account.auth().signIn(req.provider))
  handle('auth:signOut', async () => {
    ipadCompanion.pause()
    await account.auth().signOut()
    return OK
  })
  handle('auth:setNickname', (req) => account.auth().setNickname(req.nickname))
  // -- auto update ----------------------------------------------------------
  // Constructed eagerly (unlike account authentication): it owns the periodic check, and
  // in an unpackaged build the factory returns an inert stub anyway.
  const updater = createUpdaterRuntime({
    broadcast: (status) => broadcast('update:changed', status)
  })
  onBrowserQuitCancelled(() => {
    quitDrain.reset()
    updater.cancelInstall()
  })
  app.on('will-quit', () => {
    updater.dispose()
  })

  handle('update:status', () => updater.status())
  handle('update:check', () => updater.check())
  handle('update:download', () => updater.download())
  handle('update:install', () => ({ ok: updater.install() }))

  // -- feedback -------------------------------------------------------------
  // Uses the account runtime's lazy client so boot stays offline and feedback
  // remains available before sign-in when the Supabase project is configured.
  const feedback = createFeedbackService({
    getClient: () => account.getClient(),
    rateGuard: createFeedbackRateGuard(),
    appVersion: resolveAppVersion(
      app.isPackaged,
      app.getVersion(),
      __APP_VERSION__
    ),
    platform: process.platform,
    getPalette: () => getSettings().palette
  })
  handle('feedback:send', (req) => feedback.send(req))

  assertEveryChannelHandled()
  try {
    deadlineScheduler.start()
  } catch (error) {
    console.error('[notifications] deadline scheduler startup failed', error)
  }
  app.on('will-quit', () => deadlineScheduler.dispose())

  return {
    miniPlayer,
    handleDeepLink(url) {
      // Checked HERE so an unrelated `bandal://` route never constructs the
      // Supabase client — the laziness rule (§1.4-2) survives deep links.
      if (!isAuthCallbackUrl(url)) return
      void account.auth()
        .handleDeepLink(url)
        .catch((error: unknown) => {
          console.error('[ipc] deep link handling failed', error)
        })
    }
  }
}
