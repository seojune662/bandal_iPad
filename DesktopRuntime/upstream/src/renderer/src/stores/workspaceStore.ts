/**
 * Workspace store: owns the active and retained course Dockviews, the
 * open/close/activate tab API, and per-course layout persistence.
 *
 * Persistence design (see docs/orca-analysis.md §5):
 *  - NO zustand persist middleware. Hydration is explicit and ordered:
 *    course switch → flush pending save → `layout:get` → validate hard →
 *    `fromJSON` (read failures retain the saved layout for an explicit retry).
 *  - Saves are debounced (1s) and only scheduled for *structural* changes
 *    (open/close/move/resize). Decorative churn — focus/active-tab changes —
 *    refreshes the pending snapshot but never starts a save on its own.
 *  - `flushPendingSave` runs on course switch and on `beforeunload`.
 *  - Rapid course switching is guarded with a monotonic serial: stale
 *    `layout:get` responses are discarded.
 *
 * The dockview `DockviewApi` is imperative and lives outside React state;
 * `WorkspaceHost` attaches each retained API; `api` points at the active one.
 */

import { create } from 'zustand'
import type { DockviewApi, IDockviewPanel } from 'dockview'
import { isTabDescriptor } from '../../../shared/tabs'
import type { TabDescriptor } from '../../../shared/tabs'
import type { LearningBinding } from '../../../shared/types/learning'
import { isPageNoteSource } from '../../../shared/pdfPageNote'
import { showToast } from '../app/toast'
import { invoke } from '../lib/ipc'
import { settingsSnapshot } from './settingsSnapshot'
import { tabPanelId, tabTitle } from '../features/workspace/tabIdentity'
import {
  createDuplicatePanelId,
  duplicateTabDescriptor,
  panelIdMatchesDescriptor
} from '../features/workspace/tabDuplication'
import { canCloseTab } from '../features/workspace/tabCloseGuard'
import { rebindPanelContent } from '../features/workspace/panelContentHost'
import type { WorkspaceTarget } from '../features/workspace/placementContext'
import { closeWorkspacePanel } from '../features/workspace/workspaceLayout'
import { useBrowserGuests } from '../features/browser/browserGuestsStore'
import {
  LAYOUT_SAVE_DEBOUNCE_MS,
  persistentLayout,
  structuralKey,
  tabsFromLayout,
  validateLayout
} from '../features/workspace/layoutPersistence'

export type WorkspaceHydration = 'idle' | 'loading' | 'ready' | 'error'
export type WorkspaceSurface = 'course' | 'learning-home' | 'study-market'

interface WorkspaceState {
  /** Global home keeps the selected course and its live layout intact. */
  surface: WorkspaceSurface
  showStudyMarket: () => void
  showLearningHome: () => void
  showCourseWorkspace: (courseId: string | null) => void
  prepareCloseLearningSpace: (binding: LearningBinding, standalone: boolean) => Promise<boolean>
  closeLearningSpace: (binding: LearningBinding, standalone: boolean) => Promise<boolean>
  /** Course whose layout is (being) mounted; null = no course selected. */
  activeCourseId: string | null
  /** Actual Dockview identity, including duplicate instances. */
  activePanelId: string | null
  hydration: WorkspaceHydration
  retryHydration: () => void
  /** Mirror of the descriptors currently open in dockview, by panel id. */
  openTabs: Record<string, TabDescriptor>
  attachCourseApi: (courseId: string | null, api: DockviewApi) => void
  detachCourseApi: (courseId: string | null) => void
  attachApi: (api: DockviewApi) => void
  detachApi: () => void
  /** Swap the whole layout: save current course, hydrate the target. */
  setActiveCourse: (courseId: string | null) => void
  /** Open a tab, focusing the existing panel when the identity matches. */
  openTab: (
    descriptor: TabDescriptor,
    options?: {
      newInstance?: boolean
      /** Open a document alongside the current recording or other panel. */
      beside?: boolean
      /** ⌘-click: open it but stay where you are, as every browser does. */
      background?: boolean
      target?: WorkspaceTarget
    }
  ) => void
  /** Opens one PDF and its page-matched note as a persisted 50:50 pair. */
  openPdfNotePair: (
    pdf: TabDescriptor,
    note: TabDescriptor,
    connectionId: string,
    initialPage: number
  ) => void
  /** Closes the canonical tab and all its duplicate views. */
  closeTabsMatching: (descriptor: TabDescriptor) => void
  closeTab: (panelId: string) => Promise<void>
  saveRetainedLayout: (courseId: string | null, layout: ReturnType<DockviewApi['toJSON']>) => void
  rememberDetachedBrowserPage: (tabId: string, url: string, title: string) => void
  closeOthers: (panelId: string, scope?: 'group' | 'workspace') => Promise<void>
  closeTabs: (panelIds: readonly string[]) => Promise<void>
  /** [M6-A] ⌘W: close the focused tab; no tab → no-op (never the window). */
  closeActiveTab: () => Promise<void>
  /** [M6-A] ⌘1..8: activate the nth open tab (0-based); out of range → no-op. */
  activateTabAt: (index: number) => void
  activatePanel: (panelId: string) => void
  /** ⌘9: the LAST tab, following browser convention rather than the 9th. */
  activateLastTab: () => void
  /** ⌃Tab / ⌘⇧[ ] — wraps at both ends. */
  activateRelativeTab: (delta: number) => void
  /** ⌘⇧T. Re-opens the most recently closed tab of the current course. */
  reopenClosedTab: () => void
  /**
   * tabId of the focused browser tab, or null when the active tab is anything
   * else. Browser-only chords (⌘R, ⌘L, zoom) are no-ops over a PDF or a note.
   */
  activeBrowserTabId: () => string | null
  /** The descriptor of whatever tab is focused, for ⌘P and the like. */
  activeTabDescriptor: () => TabDescriptor | null
  activePanelSource: () => { panelId: string; descriptor: TabDescriptor } | null
  /** Wired to dockview's onDidLayoutChange by WorkspaceHost. */
  notifyLayoutChanged: () => void
  /** Send any pending save immediately (course switch / beforeunload). */
  flushPendingSave: () => void
  /**
   * [M5] Drop a pending save for a course that no longer exists
   * (delete/archive) — saving it would fail against the dead course row.
   */
  discardPendingSave: (courseId: string) => void
}

interface PendingSave {
  courseId: string
  layout: unknown
  exhausted: boolean
  revision: number
}

interface ActiveSave {
  saves: PendingSave[]
  failures: number
  inFlight: boolean
  retryTimer: ReturnType<typeof setTimeout> | null
}

// Imperative, non-reactive internals.
let api: DockviewApi | null = null
let activePanelSubscription: { dispose(): void } | null = null
let retainedMode = false
const courseApis = new Map<string | null, DockviewApi>()
const hydratedCourses = new Set<string>()
const pendingOpens = new Map<string, (() => void)[]>()

/** Recent user closures retain their location; private pages never enter history. */
const CLOSED_TAB_LIMIT = 10
interface ClosedTab {
  courseId: string | null
  panelId: string
  descriptor: TabDescriptor
  title: string
  params: Record<string, unknown>
  groupId: string | undefined
  index: number
}
let closedTabs: ClosedTab[] = []
/** Full, unfiltered layouts for course switching inside this renderer run. */
const runtimeLayouts = new Map<string, unknown>()
const discardedCourses = new Set<string>()

function closedSnapshot(panel: IDockviewPanel, courseId: string | null): ClosedTab | null {
  const descriptor = panel.params?.descriptor
  if (!isTabDescriptor(descriptor) || (descriptor.kind === 'browser' && descriptor.payload.isPrivate)) return null
  return {
    courseId, panelId: panel.id, descriptor, title: panel.title ?? tabTitle(descriptor),
    params: { ...panel.params }, groupId: panel.group?.id,
    index: panel.group?.panels.findIndex(entry => entry.id === panel.id) ?? -1
  }
}
let switchSerial = 0
let suppressLayoutEvents = false
let lastStructuralKey = ''
let pendingSaves: PendingSave[] = []
let saveTimer: ReturnType<typeof setTimeout> | null = null
let activeSave: ActiveSave | null = null
let saveRevision = 0

const LAYOUT_SAVE_RETRY_LIMIT = 3
const LAYOUT_SAVE_RETRY_BASE_MS = 250

function sameTabs(
  a: Record<string, TabDescriptor>,
  b: Record<string, TabDescriptor>
): boolean {
  const aKeys = Object.keys(a)
  const bKeys = Object.keys(b)
  return (
    aKeys.length === bKeys.length &&
    aKeys.every((key) => JSON.stringify(a[key]) === JSON.stringify(b[key]))
  )
}

function clearSaveTimer(): void {
  if (saveTimer !== null) {
    clearTimeout(saveTimer)
    saveTimer = null
  }
}

export const useWorkspaceStore = create<WorkspaceState>()((set, get) => {
  let replayingOpens = false
  const syncActivePanel = (): void => {
    const activePanelId = get().surface === 'course' && get().hydration === 'ready' ? api?.activePanel?.id ?? null : null
    if (get().activePanelId !== activePanelId) set({ activePanelId })
  }
  const bindApi = (nextApi: DockviewApi | null): void => {
    activePanelSubscription?.dispose()
    activePanelSubscription = null
    api = nextApi
    // The optional call also supports lightweight, older test adapters.
    activePanelSubscription = api?.onDidActivePanelChange?.(syncActivePanel) ?? null
    syncActivePanel()
  }
  const pendingCloses = new Map<IDockviewPanel, Promise<void>>()
  const requestClose = (target: DockviewApi, panel: IDockviewPanel, courseId: string | null): Promise<void> => {
    const pending = pendingCloses.get(panel)
    if (pending) return pending
    const snapshot = closedSnapshot(panel, courseId)
    const close = (allowed: boolean): void => {
      if (!allowed || target.getPanel(panel.id) !== panel) return
      if (snapshot) closedTabs = [...closedTabs, snapshot].slice(-CLOSED_TAB_LIMIT)
      closeWorkspacePanel(target, panel.id)
      if (get().activeCourseId !== courseId && courseId !== null) get().saveRetainedLayout(courseId, target.toJSON())
    }
    try {
      const descriptor = panel.params?.descriptor
      const result = isTabDescriptor(descriptor) ? canCloseTab(descriptor) : true
      if (typeof result === 'boolean') { close(result); return Promise.resolve() }
      const job = result.then(close).catch(error => {
        console.error('[Bandal] 탭을 닫지 못했습니다.', error)
        showToast('탭을 닫지 못했어요. 다시 시도해 주세요.', 'danger')
      }).finally(() => pendingCloses.delete(panel))
      pendingCloses.set(panel, job)
      return job
    } catch (error) {
      console.error('[Bandal] 탭을 닫지 못했습니다.', error)
      showToast('탭을 닫지 못했어요. 다시 시도해 주세요.', 'danger')
      return Promise.resolve()
    }
  }

  const queueDuringHydration = (open: () => void): boolean => {
    const { activeCourseId, hydration } = get()
    if (activeCourseId === null || (hydration !== 'loading' && hydration !== 'error')) return false
    const queued = pendingOpens.get(activeCourseId) ?? []
    queued.push(open)
    pendingOpens.set(activeCourseId, queued)
    return true
  }
  const replayOpens = (courseId: string): void => {
    const queued = pendingOpens.get(courseId) ?? []
    pendingOpens.delete(courseId)
    replayingOpens = true
    try { for (const open of queued) open() } finally { replayingOpens = false }
  }

  const saveIsPending = (save: PendingSave): boolean =>
    pendingSaves.some(current => current.courseId === save.courseId && current.revision === save.revision)

  const finishActiveSave = (job: ActiveSave): void => {
    if (activeSave !== job) return
    if (job.retryTimer !== null) clearTimeout(job.retryTimer)
    activeSave = null
    flush()
  }

  const attemptSave = (job: ActiveSave): void => {
    if (activeSave !== job) return
    if (!job.saves.every(saveIsPending)) {
      finishActiveSave(job)
      return
    }
    job.retryTimer = null
    job.inFlight = true
    const single = job.saves.length === 1 ? job.saves[0]! : null
    const request = single
      ? invoke('layout:save', { courseId: single.courseId, layout: single.layout })
      : invoke('layout:saveMany', { layouts: job.saves.map(({ courseId, layout }) => ({ courseId, layout })) })
    void request.then(
      () => {
        if (activeSave !== job) return
        job.inFlight = false
        // A newer snapshot for the same course may have replaced this exact
        // object while IPC was in flight. Only the ACKed snapshot is removed.
        pendingSaves = pendingSaves.filter((save) => !job.saves.some(saved => saved.courseId === save.courseId && saved.revision === save.revision))
        finishActiveSave(job)
      },
      (error: unknown) => {
        if (activeSave !== job) return
        job.inFlight = false
        // Deleted courses and superseded snapshots no longer need a retry.
        if (!job.saves.every(saveIsPending)) {
          finishActiveSave(job)
          return
        }
        job.failures += 1
        if (job.failures <= LAYOUT_SAVE_RETRY_LIMIT) {
          const retryDelay =
            LAYOUT_SAVE_RETRY_BASE_MS * 2 ** (job.failures - 1)
          job.retryTimer = setTimeout(() => attemptSave(job), retryDelay)
          return
        }
        job.saves.forEach(save => { save.exhausted = true })
        console.error('[Bandal] 레이아웃을 저장하지 못했습니다.', error)
        showToast('작업 공간을 저장하지 못했어요', 'danger')
        finishActiveSave(job)
      }
    )
  }

  const flush = (): void => {
    clearSaveTimer()
    if (activeSave !== null) {
      // beforeunload/course-switch flushes remain immediate even if a failed
      // background save was waiting in its retry backoff.
      if (!activeSave.inFlight && activeSave.retryTimer !== null) {
        clearTimeout(activeSave.retryTimer)
        activeSave.retryTimer = null
        attemptSave(activeSave)
      }
      return
    }
    const saves = pendingSaves.filter(save => !save.exhausted)
    if (saves.length === 0) return
    const job: ActiveSave = {
      saves,
      failures: 0,
      inFlight: false,
      retryTimer: null
    }
    activeSave = job
    attemptSave(job)
  }

  const replacePendingSave = (courseId: string, layout: unknown): void => {
    if (discardedCourses.has(courseId)) return
    pendingSaves = pendingSaves.filter((save) => save.courseId !== courseId)
    pendingSaves.push({
      courseId,
      layout,
      exhausted: false,
      revision: ++saveRevision
    })
    // A failed paired save must resume as a pair, even if only one side changed.
    for (const save of pendingSaves) save.exhausted = false
  }

  const scheduleSave = (courseId: string, layout: unknown): void => {
    replacePendingSave(courseId, layout)
    clearSaveTimer()
    saveTimer = setTimeout(flush, LAYOUT_SAVE_DEBOUNCE_MS)
  }

  const clearDockview = (): void => {
    if (api === null) return
    suppressLayoutEvents = true
    try {
      api.clear()
    } finally {
      suppressLayoutEvents = false
    }
  }

  const hydrate = async (courseId: string, serial: number): Promise<void> => {
    if (api === null) return // attachApi re-runs hydration once ready
    set({ hydration: 'loading', activePanelId: null })

    let raw: unknown = runtimeLayouts.get(courseId) ?? null
    if (raw === null) {
      try {
        raw = (await invoke('layout:get', { courseId })).layout
      } catch (error) {
        console.error('[Bandal] 레이아웃을 불러오지 못했습니다.', error)
        if (serial === switchSerial && api !== null) set({ hydration: 'error', activePanelId: null })
        return
      }
    }
    // A newer switch won the race — drop this hydration entirely.
    if (serial !== switchSerial || api === null) return

    const validated = raw === null ? null : validateLayout(raw)
    suppressLayoutEvents = true
    try {
      api.clear()
      if (validated !== null) api.fromJSON(validated.layout)
    } catch (error) {
      console.error(
        '[Bandal] 저장된 레이아웃이 손상되어 빈 화면으로 시작합니다.',
        error
      )
      try {
        api.clear()
      } catch {
        // dockview is already empty; nothing more to recover.
      }
    } finally {
      suppressLayoutEvents = false
    }

    const live = api.toJSON()
    runtimeLayouts.set(courseId, live)
    lastStructuralKey = structuralKey(live)
    hydratedCourses.add(courseId)
    set({ openTabs: tabsFromLayout(live), hydration: 'ready', activePanelId: get().surface === 'course' ? api.activePanel?.id ?? null : null })

    // Persist the cleaned document when validation dropped anything, so the
    // next hydration starts from a healthy file.
    if (validated !== null && validated.droppedPanelIds.length > 0) {
      scheduleSave(courseId, persistentLayout(live))
    }
    replayOpens(courseId)
  }

  return {
    surface: 'course',
    prepareCloseLearningSpace: (binding, standalone) => prepareCloseLearningSpace(binding, standalone),
    closeLearningSpace: (binding, standalone) => closeLearningSpace(binding, standalone),
    showStudyMarket: () => {
      if (get().surface === 'study-market') return
      get().notifyLayoutChanged()
      flush()
      set({ surface: 'study-market', activePanelId: null })
    },
    showLearningHome: () => {
      if (get().surface === 'learning-home') return
      get().notifyLayoutChanged()
      flush()
      set({ surface: 'learning-home', activePanelId: null })
    },
    showCourseWorkspace: (courseId) => {
      if (get().activeCourseId !== courseId) get().setActiveCourse(courseId)
      set({ surface: 'course' })
      syncActivePanel()
    },
    activeCourseId: null,
    activePanelId: null,
    hydration: 'idle',
    retryHydration: () => {
      const { activeCourseId, hydration } = get()
      if (activeCourseId !== null && hydration === 'error') void hydrate(activeCourseId, ++switchSerial)
    },
    openTabs: {},

    attachCourseApi: (courseId, nextApi) => {
      retainedMode = true
      if (courseId !== null) discardedCourses.delete(courseId)
      courseApis.set(courseId, nextApi)
      if (get().activeCourseId !== courseId) return
      bindApi(nextApi)
      if (courseId === null) set({ hydration: 'ready', openTabs: {}, activePanelId: get().surface === 'course' ? nextApi.activePanel?.id ?? null : null })
      else void hydrate(courseId, ++switchSerial)
    },

    detachCourseApi: (courseId) => {
      const outgoing = courseApis.get(courseId)
      if (outgoing && courseId !== null && hydratedCourses.has(courseId)) {
        const live = outgoing.toJSON()
        runtimeLayouts.set(courseId, live)
        replacePendingSave(courseId, persistentLayout(live))
        flush()
      }
      courseApis.delete(courseId)
      if (courseId !== null) hydratedCourses.delete(courseId)
      if (api === outgoing) bindApi(null)
      set({ openTabs: { ...get().openTabs } })
    },

    attachApi: (nextApi) => {
      bindApi(nextApi)
      lastStructuralKey = ''
      const { activeCourseId } = get()
      if (activeCourseId === null) {
        set({ hydration: 'ready', openTabs: {}, activePanelId: get().surface === 'course' ? nextApi.activePanel?.id ?? null : null })
        return
      }
      void hydrate(activeCourseId, ++switchSerial)
    },

    detachApi: () => {
      flush()
      bindApi(null)
      set({ hydration: 'idle', openTabs: {}, activePanelId: null })
    },

    setActiveCourse: (courseId) => {
      if (get().activeCourseId === courseId) return
      const serial = ++switchSerial
      const outgoingCourseId = get().activeCourseId
      if (api !== null && outgoingCourseId !== null && get().hydration === 'ready') {
        const live = api.toJSON()
        runtimeLayouts.set(outgoingCourseId, live)
        replacePendingSave(outgoingCourseId, persistentLayout(live))
      }
      flush() // persist the outgoing course's layout before swapping
      set({
        activeCourseId: courseId,
        activePanelId: null,
        openTabs: {},
        hydration: courseId === null ? 'ready' : 'loading'
      })
      lastStructuralKey = ''
      if (retainedMode) {
        bindApi(courseApis.get(courseId) ?? null)
        if (api && courseId !== null && hydratedCourses.has(courseId)) {
          const live = api.toJSON()
          lastStructuralKey = structuralKey(live)
          set({ openTabs: tabsFromLayout(live), hydration: 'ready', activePanelId: get().surface === 'course' ? api.activePanel?.id ?? null : null })
          replayOpens(courseId)
          return
        }
      }
      if (courseId === null) {
        if (retainedMode && api) {
          const live = api.toJSON()
          set({ openTabs: tabsFromLayout(live), activePanelId: get().surface === 'course' ? api.activePanel?.id ?? null : null })
          return
        }
        clearDockview()
        return
      }
      void hydrate(courseId, serial)
    },

    openTab: (descriptor, options) => {
      const destination = options?.target
      if (destination && destination.courseId !== get().activeCourseId) {
        const target = workspaceApiForCourse(destination.courseId)
        const group = target?.getGroup(destination.groupId)
        if (!target || !group || (destination.courseId !== null && !hydratedCourses.has(destination.courseId))) {
          showToast('원래 작업 영역을 찾을 수 없어요. 만든 자료는 원래 과목에서 열 수 있어요.')
          return
        }
        const copy = options.newInstance ? duplicateTabDescriptor(descriptor) : descriptor
        const id = options.newInstance && copy.kind !== 'browser' ? createDuplicatePanelId(copy) : tabPanelId(copy)
        if (!target.getPanel(id)) target.addPanel({ id, component: copy.kind, title: tabTitle(copy), params: { descriptor: copy },
          position: { referenceGroup: group.id, index: group.panels.length }, inactive: options.background === true })
        get().saveRetainedLayout(destination.courseId, target.toJSON())
        return
      }
      if (!destination && !replayingOpens && options?.background !== true && get().surface !== 'course') get().showCourseWorkspace(get().activeCourseId)
      if (queueDuringHydration(() => get().openTab(descriptor, options))) return
      if (api === null) return
      const targetGroup = destination ? api.getGroup(destination.groupId) : undefined
      if (destination && !targetGroup) {
        showToast('원래 작업 영역이 닫혔어요. 만든 자료는 과목에서 다시 열 수 있어요.')
        return
      }
      // newInstance: 같은 파일의 새 뷰를 하나 더 연다 (⌘클릭/분할 열기).
      // 복제 패널 id 규칙은 탭 복제와 동일 — validateLayout이 이미 수용한다.
      if (options?.newInstance) descriptor = duplicateTabDescriptor(descriptor)
      let panelId = options?.newInstance && descriptor.kind !== 'browser'
        ? createDuplicatePanelId(descriptor) : tabPanelId(descriptor)
      let existing = api.getPanel(panelId)
      if (options?.beside && existing && existing.group === api.activePanel?.group) {
        descriptor = duplicateTabDescriptor(descriptor)
        panelId = descriptor.kind === 'browser' ? tabPanelId(descriptor) : createDuplicatePanelId(descriptor)
        existing = undefined
      }
      if (existing !== undefined) {
        // An expanded AI tab keeps its conversation ID while its source link
        // can change, so refresh the descriptor before focusing it.
        existing.api.updateParameters({ descriptor })
        if (options?.background !== true) existing.api.setActive()
        return
      }
      // [R3] "현재 탭 옆에 열기" 설정: 새 탭을 활성 그룹의 끝이 아니라
      // 지금 보고 있는 탭 바로 다음 칸에 넣는다(복제 탭과 같은 위치 규칙,
      // TabContextMenu.duplicateTab 참고). 기존 패널을 포커스만 하는 위의
      // 경로에는 적용하지 않는다 — 이미 있는 탭은 자리를 옮기지 않는다.
      const focusedPanel = api.activePanel
      const activePanel = targetGroup ? targetGroup.activePanel : focusedPanel
      const activeIndex =
        activePanel === undefined
          ? -1
          : activePanel.group.panels.findIndex(
              (panel) => panel.id === activePanel.id
            )
      const position =
        options?.beside && activePanel
          ? { position: { referencePanel: activePanel, direction: 'right' as const } }
          : settingsSnapshot().openAdjacentTab &&
              activePanel !== undefined &&
              activeIndex >= 0
          ? { position: { referencePanel: activePanel, index: activeIndex + 1 } }
          : targetGroup ? { position: { referenceGroup: targetGroup.id, index: targetGroup.panels.length } } : {}
      const added = api.addPanel({
        id: panelId,
        component: descriptor.kind,
        title: tabTitle(descriptor),
        params: { descriptor },
        inactive: options?.background === true,
        ...position
      })
      // dockview activates a new panel by default. ⌘-clicking five 공지 links
      // would otherwise yank focus five times and leave the student on the
      // last one.
      if (options?.background === true && focusedPanel !== undefined) {
        focusedPanel.api.setActive()
        void added
      }
    },

    openPdfNotePair: (pdfDescriptor, noteDescriptor, connectionId, initialPage) => {
      if (queueDuringHydration(() => get().openPdfNotePair(pdfDescriptor, noteDescriptor, connectionId, initialPage))) return
      if (
        api === null ||
        !isPageNoteSource(pdfDescriptor) ||
        noteDescriptor.kind !== 'note'
      ) {
        return
      }
      const pairId = crypto.randomUUID()
      const current = api.activePanel
      let pdfPanel =
        current !== undefined && panelIdMatchesDescriptor(current.id, pdfDescriptor)
          ? current
          : api.getPanel(tabPanelId(pdfDescriptor))

      if (pdfPanel === undefined) {
        pdfPanel = api.addPanel({
          id: tabPanelId(pdfDescriptor),
          component: pdfDescriptor.kind,
          title: tabTitle(pdfDescriptor),
          params: {
            descriptor: pdfDescriptor,
            pageNotePair: {
              connectionId,
              pairId,
              role: 'pdf',
              initialPage
            }
          }
        })
      } else {
        pdfPanel.api.updateParameters({
          descriptor: pdfDescriptor,
          pageNotePair: {
            connectionId,
            pairId,
            role: 'pdf',
            initialPage
          }
        })
      }

      const canonicalNoteId = tabPanelId(noteDescriptor)
      const noteId =
        api.getPanel(canonicalNoteId) === undefined
          ? canonicalNoteId
          : createDuplicatePanelId(noteDescriptor)
      const notePanel = api.addPanel({
        id: noteId,
        component: 'note',
        title: tabTitle(noteDescriptor),
        params: {
          descriptor: noteDescriptor,
          pageNotePair: {
            connectionId,
            pairId,
            role: 'note',
            initialPage
          }
        },
        position: { referencePanel: pdfPanel, direction: 'right' }
      })
      pdfPanel.api.setActive()
      notePanel.api.setActive()
    },

    saveRetainedLayout: (courseId, layout) => {
      if (courseId === null || discardedCourses.has(courseId)) return
      runtimeLayouts.set(courseId, layout)
      scheduleSave(courseId, persistentLayout(layout))
      // Reaping must see closures in inactive retained workspaces too.
      set({ openTabs: { ...get().openTabs } })
    },

    rememberDetachedBrowserPage: (tabId, url, title) => {
      if (!url || url === 'about:blank') return
      for (const [courseId, raw] of runtimeLayouts) {
        if (courseApis.has(courseId)) continue
        const match = Object.entries(tabsFromLayout(raw)).find(([, descriptor]) =>
          descriptor.kind === 'browser' && descriptor.payload.tabId === tabId)
        if (!match) continue
        const [panelId, descriptor] = match
        if (descriptor.kind !== 'browser') continue
        const layout = structuredClone(raw) as RetainedLayout
        const panel = layout.panels[panelId]!
        panel.params = { ...panel.params, descriptor: { ...descriptor, payload: { ...descriptor.payload, initialUrl: url } } }
        if (title) panel.title = title
        runtimeLayouts.set(courseId, layout)
        // Navigation is decorative: park the latest URL for the next normal
        // save/quit, without starting a write timer for each background event.
        replacePendingSave(courseId, persistentLayout(layout))
      }
    },

    closeTab: (panelId) => {
      const target = api
      const panel = target?.getPanel(panelId)
      if (!target || !panel) return Promise.resolve()
      return requestClose(target, panel, get().activeCourseId)
    },

    closeTabs: async (panelIds) => {
      const target = api
      const courseId = get().activeCourseId
      if (!target) return
      for (const id of panelIds) {
        const panel = target.getPanel(id)
        if (panel) await requestClose(target, panel, courseId)
      }
    },

    closeTabsMatching: (descriptor) => {
      // Closes the canonical panel AND every duplicate view of the same tab —
      // closing only tabPanelId(descriptor) leaves ::duplicate:: panels open.
      closeResourceTabs(candidate => JSON.stringify(candidate) === JSON.stringify(descriptor) || tabPanelId(candidate) === tabPanelId(descriptor))
    },

    closeOthers: (panelId, scope = 'group') => {
      const panel = api?.getPanel(panelId)
      if (!panel || !api) return Promise.resolve()
      const panels = scope === 'workspace' ? api.panels : panel.group?.panels ?? api.panels
      return get().closeTabs(panels.filter(entry => entry.id !== panelId).map(entry => entry.id))
    },

    closeActiveTab: () => {
      if (get().surface !== 'course') return Promise.resolve()
      const panel = api?.activePanel
      return panel ? get().closeTab(panel.id) : Promise.resolve()
    },

    activateTabAt: (index) => {
      if (get().surface !== 'course') return
      if (api === null || index < 0) return
      api.panels[index]?.api.setActive()
    },

    activatePanel: (panelId) => {
      api?.getPanel(panelId)?.api.setActive()
    },

    activateLastTab: () => {
      if (get().surface !== 'course') return
      if (api === null) return
      api.panels[api.panels.length - 1]?.api.setActive()
    },

    activateRelativeTab: (delta) => {
      if (get().surface !== 'course') return
      if (api === null) return
      const panels = api.panels
      if (panels.length === 0) return
      const current = panels.findIndex(
        (panel) => panel.id === api?.activePanel?.id
      )
      const from = current === -1 ? 0 : current
      const next = (((from + delta) % panels.length) + panels.length) % panels.length
      panels[next]?.api.setActive()
    },

    reopenClosedTab: () => {
      if (get().surface !== 'course') return
      if (!api) return
      const index = closedTabs.findLastIndex(tab => tab.courseId === get().activeCourseId)
      if (index < 0) return
      const [closed] = closedTabs.splice(index, 1)
      if (!closed) return
      const existing = api.getPanel(closed.panelId)
      if (existing) { existing.api.setActive(); return }
      const group = closed.groupId ? api.groups?.find(group => group.id === closed.groupId) : undefined
      api.addPanel({
        id: closed.panelId, component: closed.descriptor.kind, title: closed.title,
        params: closed.params,
        ...(group ? { position: { referenceGroup: group, index: Math.max(0, Math.min(closed.index, group.panels.length)) } } : {})
      })
    },

    activeTabDescriptor: () => {
      if (get().surface !== 'course' || api === null) return null
      const descriptor = (
        api.activePanel?.params as { descriptor?: unknown } | undefined
      )?.descriptor
      return isTabDescriptor(descriptor) ? descriptor : null
    },

    activePanelSource: () => {
      const panel = api?.activePanel
      if (get().surface !== 'course' || get().hydration !== 'ready' || !panel || panel.id !== get().activePanelId) return null
      const descriptor = panel.params?.descriptor
      return isTabDescriptor(descriptor) ? { panelId: panel.id, descriptor } : null
    },

    activeBrowserTabId: () => {
      if (get().surface !== 'course' || api === null) return null
      const descriptor = (
        api.activePanel?.params as { descriptor?: unknown } | undefined
      )?.descriptor
      if (!isTabDescriptor(descriptor) || descriptor.kind !== 'browser') {
        return null
      }
      return descriptor.payload.tabId
    },

    notifyLayoutChanged: () => {
      if (suppressLayoutEvents || api === null) return
      syncActivePanel()
      const { activeCourseId, hydration, openTabs } = get()
      if ((activeCourseId !== null && discardedCourses.has(activeCourseId)) || hydration !== 'ready') return

      const layout = api.toJSON()
      const tabs = tabsFromLayout(layout)
      if (!sameTabs(openTabs, tabs)) set({ openTabs: tabs })
      if (activeCourseId === null) return
      runtimeLayouts.set(activeCourseId, layout)

      const key = structuralKey(layout)
      if (key === lastStructuralKey) {
        // Decorative churn (focus change). No debounce timer for focus alone,
        // but always park the snapshot so flush (beforeunload / course switch)
        // carries the latest active tab — otherwise quitting after only
        // switching tabs restores the wrong active tab.
        replacePendingSave(activeCourseId, persistentLayout(layout))
        return
      }
      lastStructuralKey = key
      scheduleSave(activeCourseId, persistentLayout(layout))
    },

    flushPendingSave: () => {
      flush()
    },

    discardPendingSave: (courseId) => {
      discardedCourses.add(courseId)
      pendingOpens.delete(courseId)
      closedTabs = closedTabs.filter(tab => tab.courseId !== courseId)
      runtimeLayouts.delete(courseId)
      hydratedCourses.delete(courseId)
      const previousLength = pendingSaves.length
      pendingSaves = pendingSaves.filter((save) => save.courseId !== courseId)
      if (pendingSaves.length !== previousLength && pendingSaves.length === 0) {
        clearSaveTimer()
      }
      set({ openTabs: { ...get().openTabs } })
    }
  }
})

/** Test-only: reset the store's imperative internals and state. */
export function resetWorkspaceStoreForTests(): void {
  clearSaveTimer()
  if (activeSave?.retryTimer !== null && activeSave?.retryTimer !== undefined) {
    clearTimeout(activeSave.retryTimer)
  }
  activePanelSubscription?.dispose()
  activePanelSubscription = null
  api = null
  retainedMode = false
  courseApis.clear()
  closedTabs = []
  hydratedCourses.clear()
  pendingOpens.clear()
  switchSerial = 0
  suppressLayoutEvents = false
  lastStructuralKey = ''
  pendingSaves = []
  runtimeLayouts.clear()
  discardedCourses.clear()
  activeSave = null
  saveRevision = 0
  useWorkspaceStore.setState({
    surface: 'course',
    activeCourseId: null,
    activePanelId: null,
    hydration: 'idle',
    openTabs: {}
  })
}

export function retainedTabDescriptors(courseId?: string): TabDescriptor[] {
  const state = useWorkspaceStore.getState()
  const activeIsRetained = state.activeCourseId === null || !discardedCourses.has(state.activeCourseId)
  const descriptors = activeIsRetained && (courseId === undefined || state.activeCourseId === courseId) ? Object.values(state.openTabs) : []
  // Native browser pages outlive the small cache of mounted course Dockviews.
  for (const [id, layout] of runtimeLayouts) {
    if (id === state.activeCourseId || (courseId !== undefined && id !== courseId)) continue
    descriptors.push(...Object.values(tabsFromLayout(layout)))
  }
  // The temporary no-course canvas has no persisted row, but its pages are live.
  const temporary = courseApis.get(null)
  if (temporary && state.activeCourseId !== null && courseId === undefined) {
    descriptors.push(...temporary.panels.flatMap(panel => isTabDescriptor(panel.params?.descriptor) ? [panel.params.descriptor] : []))
  }
  return descriptors
}

export function workspaceApiForCourse(courseId: string | null): DockviewApi | null {
  return courseApis.get(courseId) ?? (useWorkspaceStore.getState().activeCourseId === courseId ? api : null)
}

/** Placement lookup, independent of descriptors' original resource bindings. */
export function workspaceCourseForPanel(panelId: string): string | null {
  for (const [courseId, target] of courseApis) if (target.getPanel(panelId)) return courseId
  for (const [courseId, layout] of runtimeLayouts) if (tabsFromLayout(layout)[panelId]) return courseId
  return null
}

export interface WorkspacePanelPlacement {
  courseId: string
  panelId: string
  descriptor: TabDescriptor
}

export function workspacePanelPlacements(): WorkspacePanelPlacement[] {
  const placements: WorkspacePanelPlacement[] = []
  for (const [courseId, layout] of runtimeLayouts) {
    if (discardedCourses.has(courseId)) continue
    const target = workspaceApiForCourse(courseId)
    const tabs = target ? Object.fromEntries(target.panels.flatMap(panel => isTabDescriptor(panel.params?.descriptor) ? [[panel.id, panel.params.descriptor]] : [])) : tabsFromLayout(layout)
    for (const [panelId, descriptor] of Object.entries(tabs)) placements.push({ courseId, panelId, descriptor })
  }
  return placements
}

/** Resource deletion closes every placement, including evicted course layouts. */
export function closeResourceTabs(matches: (descriptor: TabDescriptor) => boolean): void {
  const state = useWorkspaceStore.getState()
  for (const courseId of new Set([...runtimeLayouts.keys(), ...courseApis.keys(), state.activeCourseId])) {
    if (courseId === null || discardedCourses.has(courseId)) continue
    const target = workspaceApiForCourse(courseId)
    if (target) {
      let changed = false
      for (const panel of [...target.panels]) if (isTabDescriptor(panel.params?.descriptor) && matches(panel.params.descriptor)) {
        panel.api.close(); changed = true
      }
      if (!changed) continue
      if (courseId === state.activeCourseId) state.notifyLayoutChanged()
      else state.saveRetainedLayout(courseId, target.toJSON())
    } else {
      const raw = runtimeLayouts.get(courseId)
      const ids = Object.entries(tabsFromLayout(raw)).filter(([, descriptor]) => matches(descriptor)).map(([id]) => id)
      if (!ids.length) continue
      const layout = structuredClone(raw) as RetainedLayout
      for (const id of ids) delete layout.panels[id]
      const remaining = validateLayout(layout)?.layout ?? { ...layout, panels: {}, grid: { ...layout.grid, root: { type: 'branch' as const, data: [] } } }
      state.saveRetainedLayout(courseId, remaining)
    }
  }
  closedTabs = closedTabs.filter(tab => !matches(tab.descriptor))
}

/** File operations keep a moved view in its chosen workspace. */
export function reconcileWorkspaceMaterialRename(courseId: string, from: string, to: string): number {
  const state = useWorkspaceStore.getState()
  let changed = 0
  const rewrite = (descriptor: TabDescriptor): TabDescriptor | null => {
    if (!('relPath' in descriptor.payload) || !('courseId' in descriptor.payload) || descriptor.payload.courseId !== courseId) return null
    const path = descriptor.payload.relPath
    if (path !== from && !path.startsWith(`${from}/`) && path !== to && !path.startsWith(`${to}/`)) return null
    const relPath = path === to || path.startsWith(`${to}/`) ? path : `${to}${path.slice(from.length)}`
    return { ...descriptor, payload: { ...descriptor.payload, relPath } } as TabDescriptor
  }
  for (const placementCourse of new Set([...runtimeLayouts.keys(), state.activeCourseId])) {
    if (!placementCourse || discardedCourses.has(placementCourse)) continue
    const target = workspaceApiForCourse(placementCourse)
    if (target) {
      let updated = false
      for (const panel of [...target.panels]) {
        if (!isTabDescriptor(panel.params?.descriptor)) continue
        const descriptor = rewrite(panel.params.descriptor)
        if (!descriptor) continue
        let id = panel.id.includes('::duplicate::') ? createDuplicatePanelId(descriptor) : tabPanelId(descriptor)
        if (id === panel.id) continue
        if (target.getPanel(id)) id = createDuplicatePanelId(descriptor)
        const group = panel.group.id, index = panel.group.panels.indexOf(panel), active = panel.api.isActive
        const params = { ...panel.params, descriptor }
        panel.api.close()
        target.addPanel({ id, component: descriptor.kind, title: tabTitle(descriptor), params,
          inactive: !active, ...(target.getGroup(group) ? { position: { referenceGroup: group, index } } : {}) })
        updated = true; changed++
      }
      if (updated) {
        if (placementCourse === state.activeCourseId) state.notifyLayoutChanged()
        else state.saveRetainedLayout(placementCourse, target.toJSON())
      }
    } else {
      const raw = runtimeLayouts.get(placementCourse)
      if (!raw) continue
      const layout = structuredClone(raw) as RetainedLayout
      const ids = new Map<string, string>()
      for (const [id, saved] of Object.entries(layout.panels)) {
        if (!isTabDescriptor(saved.params?.descriptor)) continue
        const descriptor = rewrite(saved.params.descriptor)
        if (!descriptor) continue
        const nextId = id.includes('::duplicate::') ? createDuplicatePanelId(descriptor) : tabPanelId(descriptor)
        if (nextId === id) continue
        ids.set(id, nextId); delete layout.panels[id]
        layout.panels[nextId] = { ...saved, id: nextId, title: tabTitle(descriptor), params: { ...saved.params, descriptor } }
        changed++
      }
      if (ids.size) {
        const visit = (node: RetainedLayout['grid']['root']): void => {
          if (Array.isArray(node.data)) node.data.forEach(visit)
          else { node.data.views = node.data.views.map(id => ids.get(id) ?? id); if (node.data.activeView) node.data.activeView = ids.get(node.data.activeView) ?? node.data.activeView }
        }
        visit(layout.grid.root)
        state.saveRetainedLayout(placementCourse, layout)
      }
    }
  }
  return changed
}

export interface WorkspacePanelMovePosition {
  groupId?: string
  direction?: 'within' | 'left' | 'right' | 'above' | 'below'
  index?: number
}

/** Transfer presentation only: resources, live content and identities stay intact. */
export async function moveWorkspacePanel(input: {
  sourceCourseId: string | null
  panelId: string
  targetCourseId: string
  position?: WorkspacePanelMovePosition
}): Promise<boolean> {
  const state = useWorkspaceStore.getState()
  if (input.sourceCourseId === input.targetCourseId) return false
  const unavailable = (): false => {
    showToast('창을 옮기지 못했어요. 출발 과목에서 창을 확인한 뒤 다시 시도해 주세요.', 'danger')
    return false
  }
  if ((input.sourceCourseId !== null && discardedCourses.has(input.sourceCourseId)) || discardedCourses.has(input.targetCourseId)) return unavailable()
  const source = workspaceApiForCourse(input.sourceCourseId), target = workspaceApiForCourse(input.targetCourseId)
  const panel = source?.getPanel(input.panelId)
  if (!source || !target || !panel || !hydratedCourses.has(input.targetCourseId) || !isTabDescriptor(panel.params?.descriptor)) return unavailable()
  if (target.getPanel(input.panelId)) {
    showToast('이 과목에 같은 창이 이미 열려 있어요. 출발 과목에 창을 그대로 두었어요. 도착 과목의 같은 창을 닫은 후 다시 옮겨 주세요.')
    return false
  }
  const group = input.position?.groupId ? target.getGroup(input.position.groupId) : undefined
  if (input.position?.groupId && !group) return unavailable()
  const direction = input.position?.direction
  const position = group ? { referenceGroup: group.id, direction: direction ?? 'within',
    ...(input.position?.index !== undefined ? { index: input.position.index } : {}) }
    : direction && direction !== 'within' ? { direction } : undefined
  let added: IDockviewPanel | undefined
  suppressLayoutEvents = true
  try {
    const descriptor = panel.params.descriptor
    added = target.addPanel({ id: panel.id, component: descriptor.kind,
      title: panel.title ?? tabTitle(descriptor), params: { ...panel.params },
      ...(position ? { position } : {}) })
    rebindPanelContent(panel.api, added.api, target, input.targetCourseId)
    closeWorkspacePanel(source, panel.id, 'transfer')
    if (descriptor.kind === 'browser') useBrowserGuests.getState().setGuestCourse(descriptor.payload.tabId, input.targetCourseId)
    // Publish both live ownership snapshots before subscribers (guest reaping).
    if (input.sourceCourseId !== null) runtimeLayouts.set(input.sourceCourseId, source.toJSON())
    runtimeLayouts.set(input.targetCourseId, target.toJSON())
    if (api && state.activeCourseId) {
      useWorkspaceStore.setState({ openTabs: tabsFromLayout(api.toJSON()), activePanelId: api.activePanel?.id ?? null })
    }
  } catch (error) {
    if (added && source.getPanel(panel.id) === panel) {
      rebindPanelContent(added.api, panel.api, source, input.sourceCourseId)
      target.removePanel(added)
    }
    console.error('[Bandal] 창을 옮기지 못했습니다.', error)
    showToast('창을 옮기지 못했어요. 원래 창에서 다시 시도해 주세요.', 'danger')
    return false
  } finally { suppressLayoutEvents = false }
  state.saveRetainedLayout(input.sourceCourseId, source.toJSON())
  state.saveRetainedLayout(input.targetCourseId, target.toJSON())
  if (state.activeCourseId === input.targetCourseId) state.notifyLayoutChanged()
  state.flushPendingSave()
  return true
}

/** Resolve ownership independently of whichever course is currently selected. */
export function browserTabCourseId(tabId: string): string | null {
  const ownsTab = (descriptor: unknown): boolean =>
    isTabDescriptor(descriptor) && descriptor.kind === 'browser' && descriptor.payload.tabId === tabId
  // A newly adopted popup can mount before its retained layout snapshot updates.
  for (const [courseId, courseApi] of courseApis) {
    if (courseId !== null && discardedCourses.has(courseId)) continue
    if (courseApi.panels.some(panel => ownsTab(panel.params?.descriptor))) return courseId
  }
  const state = useWorkspaceStore.getState()
  if ((state.activeCourseId === null || !discardedCourses.has(state.activeCourseId)) && Object.values(state.openTabs).some(ownsTab)) return state.activeCourseId
  for (const [courseId, layout] of runtimeLayouts) {
    if (Object.values(tabsFromLayout(layout)).some(ownsTab)) return courseId
  }
  return null
}

/** Site-created pages belong to their opener even while its course is hidden. */
export function openBrowserTabInCourse(descriptor: TabDescriptor, courseId: string | null | undefined, background: boolean): boolean {
  const state = useWorkspaceStore.getState()
  if (courseId !== undefined && courseId !== null && discardedCourses.has(courseId)) return false
  const target = courseId === undefined ? undefined : courseApis.get(courseId)
  if (courseId === undefined || courseId === state.activeCourseId) {
    state.openTab(descriptor, { background })
    return true
  }
  if (!target) {
    // A popup from an evicted course stays with its opener. Never silently
    // route an explicitly owned page into the currently selected course.
    if (courseId === null || !runtimeLayouts.has(courseId)) return false
    const layout = appendRetainedBrowserTab(runtimeLayouts.get(courseId), descriptor)
    state.saveRetainedLayout(courseId, layout)
    return true
  }
  const previous = target.activePanel
  target.addPanel({ id: tabPanelId(descriptor), component: descriptor.kind, title: tabTitle(descriptor), params: { descriptor } })
  previous?.api.setActive()
  const layout = target.toJSON()
  state.saveRetainedLayout(courseId!, layout)
  return true
}

type RetainedLayout = ReturnType<DockviewApi['toJSON']>
function appendRetainedBrowserTab(raw: unknown, descriptor: TabDescriptor): RetainedLayout {
  const restored = validateLayout(raw)?.layout
  const layout: RetainedLayout = restored ? structuredClone(restored) : {
    grid: { root: { type: 'branch', data: [] }, width: 0, height: 0, orientation: 'HORIZONTAL' as RetainedLayout['grid']['orientation'] },
    panels: {}
  }
  const id = tabPanelId(descriptor)
  if (layout.panels[id]) return layout
  layout.panels[id] = { id, contentComponent: descriptor.kind, title: tabTitle(descriptor), params: { descriptor } }
  const groups: Array<{ id: string; views: string[]; activeView?: string }> = []
  const visit = (node: RetainedLayout['grid']['root']): void => {
    if (Array.isArray(node.data)) node.data.forEach(visit)
    else groups.push(node.data)
  }
  visit(layout.grid.root)
  const group = groups.find(group => group.id === layout.activeGroup) ?? groups[0]
  if (group) group.views.push(id)
  else {
    const groupId = `browser-${id}`
    layout.grid.root = { type: 'branch', data: [{ type: 'leaf', data: { id: groupId, views: [id], activeView: id } }] }
    layout.activeGroup = groupId
  }
  return layout
}

export function closeBrowserTab(tabId: string): void {
  const state = useWorkspaceStore.getState()
  const apis = new Set([...courseApis.values(), ...(api ? [api] : [])])
  for (const target of apis) {
    let changed = false
    for (const panel of [...target.panels]) {
      const descriptor = panel.params?.descriptor
      if (isTabDescriptor(descriptor) && descriptor.kind === 'browser' && descriptor.payload.tabId === tabId) {
        panel.api.close()
        changed = true
      }
    }
    if (changed) for (const [courseId, courseApi] of courseApis) {
      if (courseApi === target) {
        if (courseId === state.activeCourseId) state.notifyLayoutChanged()
        else state.saveRetainedLayout(courseId, target.toJSON())
      }
    }
  }
  // Site-created tabs can close themselves while their course has no Dockview.
  for (const [courseId, raw] of runtimeLayouts) {
    if (courseApis.has(courseId)) continue
    const ids = Object.entries(tabsFromLayout(raw)).filter(([, descriptor]) =>
      descriptor.kind === 'browser' && descriptor.payload.tabId === tabId).map(([id]) => id)
    if (!ids.length) continue
    const layout = structuredClone(raw) as RetainedLayout
    for (const id of ids) delete layout.panels[id]
    const remaining = validateLayout(layout)?.layout ?? {
      ...layout, panels: {}, grid: { ...layout.grid, root: { type: 'branch' as const, data: [] } }
    }
    state.saveRetainedLayout(courseId, remaining)
  }
}

function belongsToLearningSpace(descriptor: TabDescriptor, binding: LearningBinding, standalone: boolean): boolean {
  if (standalone) return true
  if (descriptor.kind === 'learning') return descriptor.payload.courseId === binding.courseId && descriptor.payload.rootRelPath === binding.rootRelPath
  if (!binding.rootRelPath || !('courseId' in descriptor.payload) || descriptor.payload.courseId !== binding.courseId || !('relPath' in descriptor.payload)) return false
  return descriptor.payload.relPath === binding.rootRelPath || descriptor.payload.relPath.startsWith(`${binding.rootRelPath}/`)
}

function learningSpaceApi(binding: LearningBinding): DockviewApi | null {
  return courseApis.get(binding.courseId) ?? (useWorkspaceStore.getState().activeCourseId === binding.courseId ? api : null)
}

/** Check before list removal; a native page may still veto closing its tab. */
export async function prepareCloseLearningSpace(binding: LearningBinding, standalone: boolean): Promise<boolean> {
  const target = learningSpaceApi(binding)
  const descriptors = target ? target.panels.flatMap(panel => isTabDescriptor(panel.params?.descriptor) ? [panel.params.descriptor] : [])
    : Object.values(tabsFromLayout(runtimeLayouts.get(binding.courseId)))
  const moved = workspacePanelPlacements().filter(placement => placement.courseId !== binding.courseId &&
    (standalone ? 'courseId' in placement.descriptor.payload && placement.descriptor.payload.courseId === binding.courseId
      : belongsToLearningSpace(placement.descriptor, binding, false))).map(placement => placement.descriptor)
  try {
    for (const descriptor of descriptors) if (belongsToLearningSpace(descriptor, binding, standalone) && !await canCloseTab(descriptor)) return false
    for (const descriptor of moved) if (!await canCloseTab(descriptor)) return false
    return true
  } catch {
    showToast('학습 공간의 탭을 닫지 못했어요. 다시 시도해 주세요.', 'danger')
    return false
  }
}

/** Remove already-deleted resources from mounted, evicted and closed layouts. */
export async function closeLearningSpace(binding: LearningBinding, standalone: boolean): Promise<boolean> {
  const state = useWorkspaceStore.getState()
  const target = learningSpaceApi(binding)
  if (standalone) state.discardPendingSave(binding.courseId)
  closedTabs = closedTabs.filter(tab => tab.courseId !== binding.courseId || !belongsToLearningSpace(tab.descriptor, binding, standalone))
  if (target) {
    for (const panel of [...target.panels]) {
      const descriptor = panel.params?.descriptor
      if (standalone || isTabDescriptor(descriptor) && belongsToLearningSpace(descriptor, binding, false)) panel.api.close()
    }
    if (!standalone) {
      if (state.activeCourseId === binding.courseId) state.notifyLayoutChanged()
      else state.saveRetainedLayout(binding.courseId, target.toJSON())
    }
  } else if (!standalone) {
    const raw = runtimeLayouts.get(binding.courseId)
    if (raw) {
      const layout = structuredClone(raw) as RetainedLayout
      for (const [panelId, descriptor] of Object.entries(tabsFromLayout(layout))) if (belongsToLearningSpace(descriptor, binding, false)) delete layout.panels[panelId]
      const remaining = validateLayout(layout)?.layout ?? { ...layout, panels: {}, grid: { ...layout.grid, root: { type: 'branch' as const, data: [] } } }
      state.saveRetainedLayout(binding.courseId, remaining)
    }
  }
  if (standalone && state.activeCourseId === binding.courseId) {
    useWorkspaceStore.setState({ openTabs: {}, activePanelId: null })
    state.showLearningHome()
  }
  closeResourceTabs(descriptor => standalone
    ? 'courseId' in descriptor.payload && descriptor.payload.courseId === binding.courseId
    : belongsToLearningSpace(descriptor, binding, false))
  return true
}
