import { openStudyMarket } from './studyMarketNavigation'
import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState
} from 'react'
import { v4 as uuidv4 } from 'uuid'
import type { PushPayload } from '../../../shared/ipc/events'
import { invoke, onPush } from '../lib/ipc'
import { usePrintRequests } from '../features/print/usePrintRequests'
import { useAgentWorkspaceSync } from '../features/agent/workspaceSync'
import { CourseSidebar } from '../features/courses/CourseSidebar'
import { LearningDialogsHost } from '../features/learning/LearningDialogsHost'
import { LearningSpacesPanel } from '../features/learning/LearningSpacesPanel'
import { FeatureLauncherPanel } from '../features/launcher/FeatureLauncherPanel'
import { MaterialsSidebar } from '../features/materials/MaterialsSidebar'
import { OnboardingOverlay } from '../features/onboarding/OnboardingOverlay'
import { useOnboardingStore } from '../features/onboarding/onboardingStore'
import { TourOverlay } from '../features/onboarding/tour/TourOverlay'
import { useTourStore } from '../features/onboarding/tour/tourStore'
import { useUpdateNotifications } from '../features/updates/useUpdateNotifications'
import { WorkspaceHost } from '../features/workspace/WorkspaceHost'
import { RecordingIndicator } from '../features/recordings/RecordingIndicator'
import { RailResizer } from './RailResizer'
import { applyStoredRailWidths } from './railWidth'
import { descriptorFor } from '../features/workspace/tabIdentity'
import { useAuthStore } from '../stores/authStore'
import { useCoursesStore } from '../stores/coursesStore'
import { useUiStore } from '../stores/uiStore'
import { useWorkspaceStore } from '../stores/workspaceStore'
import { useDownloads } from '../features/browser/downloadsStore'
import { useAgentRuns } from '../features/browser/AgentRunBanner'
import { useBrowserGuests } from '../features/browser/browserGuestsStore'
import { requestWebVideoResume } from '../features/browser/videoBridge'
import { requestVideoResume } from '../features/file/lib/videoProgress'
import { useUniversityStore } from '../stores/universityStore'
import { useGlobalShortcuts } from './shortcuts'
import { showToast, ToastHost } from './toast'
import { PresentationProgress } from '../features/file/pptx/presentationJobs'
import { usePluginsStore } from '../stores/pluginsStore'
import { subscribePluginEditor } from '../features/plugins/pluginEditor'
import { ShellChrome } from './ShellChrome'
import { GlobalNavigation } from './GlobalNavigation'
import { useWindowState } from './useWindowState'
import { usePresence } from '../components/usePresence'
import { acquirePointerPassthrough } from '../features/browser/webviewPassthrough'
import './app-shell.css'

const BoardOverlay = lazy(() =>
  import('../features/board/BoardPanel').then((module) => ({
    default: module.BoardOverlay
  }))
)
const LinkGraphOverlay = lazy(() =>
  import('../features/links/graph/LinkGraphOverlay').then((module) => ({
    default: module.LinkGraphOverlay
  }))
)
const BrowserWebviewLayer = lazy(() =>
  import('../features/browser/BrowserWebviewLayer').then((module) => ({
    default: module.BrowserWebviewLayer
  }))
)
const PrintPreviewOverlay = lazy(() =>
  import('../features/print/PrintPreviewOverlay').then((module) => ({
    default: module.PrintPreviewOverlay
  }))
)
const SettingsApp = lazy(() =>
  import('../features/settings/SettingsApp').then((module) => ({
    default: module.SettingsApp
  }))
)
const QuickFileSearch = lazy(() =>
  import('./QuickFileSearch').then((module) => ({
    default: module.QuickFileSearch
  }))
)

function scheduleAfterFirstPaint(task: () => void): () => void {
  let idle: number | null = null
  const frame = window.requestAnimationFrame(() => {
    idle = window.requestIdleCallback(task, { timeout: 800 })
  })
  return () => {
    window.cancelAnimationFrame(frame)
    if (idle !== null) window.cancelIdleCallback(idle)
  }
}

export function AppShell(): JSX.Element {
  useWindowState()
  usePrintRequests()
  useAgentWorkspaceSync()
  const courses = useCoursesStore((state) => state.courses)
  const selectedCourseId = useCoursesStore((state) => state.selectedCourseId)
  const selectCourse = useCoursesStore((state) => state.selectCourse)
  const loadCourses = useCoursesStore((state) => state.loadCourses)
  const activeWorkspaceCourseId = useWorkspaceStore(
    (state) => state.activeCourseId
  )
  const workspaceHydration = useWorkspaceStore((state) => state.hydration)
  const openTab = useWorkspaceStore((state) => state.openTab)
  const [pendingChat, setPendingChat] = useState<{
    courseId: string
    conversationId: string
  } | null>(null)
  const [pendingMaterial, setPendingMaterial] = useState<{
    courseId: string
    relPath: string
  } | null>(null)
  const consumedPendingOpen = useRef(false)
  const initTheme = useUiStore((state) => state.initTheme)
  const leftRailOpen = useUiStore((state) => state.leftRailOpen)
  const courseRailOpen = useUiStore((state) => state.courseRailOpen)
  const leftRailPanel = useUiStore((state) => state.leftRailPanel)
  const [launcherMounted, setLauncherMounted] = useState(false)
  const [learningMounted, setLearningMounted] = useState(false)
  useEffect(() => { if (leftRailPanel === 'plugins') setLauncherMounted(true) }, [leftRailPanel])
  useEffect(() => { if (leftRailPanel === 'learning') setLearningMounted(true) }, [leftRailPanel])
  const rightRailOpen = useUiStore((state) => state.rightRailOpen)
  const workspaceSurface = useWorkspaceStore((state) => state.surface)
  const activeTabKind = useWorkspaceStore((state) => state.activePanelSource()?.descriptor.kind ?? null)
  const courseRailVisible = courseRailOpen && workspaceSurface !== 'study-market'
  const materialsRailVisible = rightRailOpen && workspaceSurface === 'course' && activeTabKind !== 'learning'
  // GlobalNavigation owns the board entry point; the shell owns its overlay.
  const isBoardOverlayOpen = useUiStore((state) => state.isBoardOverlayOpen)
  const closeBoardOverlay = useUiStore((state) => state.closeBoardOverlay)
  const isLinkGraphOpen = useUiStore((state) => state.isLinkGraphOpen)
  const closeLinkGraph = useUiStore((state) => state.closeLinkGraph)
  const isSettingsOpen = useUiStore((state) => state.isSettingsOpen)
  const settingsPresent = usePresence(isSettingsOpen, 160)
  useLayoutEffect(() => settingsPresent ? acquirePointerPassthrough() : undefined, [settingsPresent])
  const settingsCategory = useUiStore((state) => state.settingsCategory)
  const openSettings = useUiStore((state) => state.openSettings)
  const closeSettings = useUiStore((state) => state.closeSettings)
  const isOnboardingVisible = useOnboardingStore((state) => state.visible)

  useLayoutEffect(() => {
    const active = document.activeElement
    if (active instanceof HTMLElement && active.closest('[inert]')) {
      document.querySelector<HTMLButtonElement>('.shell-chrome button')?.focus()
    }
  }, [leftRailOpen, courseRailOpen, leftRailPanel, materialsRailVisible, settingsPresent, workspaceSurface])

  const selectedCourse =
    courses.find((course) => course.id === selectedCourseId) ?? null

  // [M6-A] ⌘T/⌘W/⌘P/⌘,/⌘1..9 — see app/shortcuts.ts for the guard rules.
  useGlobalShortcuts()

  // Auto-update toasts. Inert in `pnpm dev` (main reports phase 'unsupported').
  useUpdateNotifications()
  useEffect(() => {
    window.addEventListener('bandal:open-study-market', openStudyMarket)
    return () => window.removeEventListener('bandal:open-study-market', openStudyMarket)
  }, [])
  useEffect(subscribePluginEditor, [])

  useEffect(() => {
    void useAuthStore.getState().init()
    void initTheme().catch((error: unknown) => {
      console.error('[Bandal] 테마 설정을 불러오지 못했습니다.', error)
    })
    void loadCourses()
    // First-run onboarding. AI availability is checked only when AI is used.
    void useOnboardingStore.getState().init()
    const cancelDeferredBoot = scheduleAfterFirstPaint(() => {
      void useTourStore.getState().init()
      useDownloads.getState().init()
      useAgentRuns.getState().init()
      void usePluginsStore.getState().refresh().catch((error: unknown) => {
        console.error('[Bandal] 플러그인 목록을 불러오지 못했습니다.', error)
      })
    })
    // [M8] 학교 바로가기 — the rail section renders nothing until this lands.
    void useUniversityStore.getState().init()
    return cancelDeferredBoot
  }, [initTheme, loadCourses])

  // The assistant can now create, rename and remove courses on its own, so the
  // list has to follow changes it did not originate in this window.
  useEffect(() => {
    const unsubscribe = onPush('courses:changed', () => {
      void loadCourses()
    })
    return unsubscribe
  }, [loadCourses])

  useEffect(() => {
    return onPush('ui:openSettings', ({ category }) => openSettings(category))
  }, [openSettings])

  useEffect(() => {
    return onPush('ui:openChat', (payload) => {
      setPendingChat(payload)
      selectCourse(payload.courseId)
    })
  }, [selectCourse])

  const handleOpenMaterial = useCallback(
    (payload: PushPayload<'ui:openMaterial'>): void => {
      requestVideoResume(payload.courseId, payload.relPath, {
        positionSec: payload.positionSec,
        playbackRate: payload.playbackRate
      })
      setPendingMaterial({
        courseId: payload.courseId,
        relPath: payload.relPath
      })
      selectCourse(payload.courseId)
    },
    [selectCourse]
  )

  const handleOpenUrl = useCallback(
    (payload: PushPayload<'ui:openUrl'>): void => {
      const workspace = useWorkspaceStore.getState()
      const browser = useBrowserGuests.getState()
      const normalizedUrl = (() => {
        try {
          return new URL(payload.url).href
        } catch {
          return payload.url
        }
      })()
      const existing = Object.values(workspace.openTabs).find((descriptor) => {
        if (descriptor.kind !== 'browser') return false
        const currentUrl =
          browser.nav[descriptor.payload.tabId]?.url ??
          descriptor.payload.initialUrl
        try {
          return new URL(currentUrl).href === normalizedUrl
        } catch {
          return currentUrl === normalizedUrl
        }
      })
      const tabId =
        existing?.kind === 'browser' ? existing.payload.tabId : uuidv4()
      requestWebVideoResume(tabId, {
        positionSec: payload.positionSec,
        playbackRate: payload.playbackRate
      })
      workspace.openTab(
        descriptorFor('browser', { tabId, initialUrl: payload.url })
      )
    },
    []
  )

  useEffect(() => {
    return onPush('ui:openMaterial', handleOpenMaterial)
  }, [handleOpenMaterial])

  useEffect(() => {
    return onPush('ui:openUrl', handleOpenUrl)
  }, [handleOpenUrl])

  useEffect(
    () => onPush('pip:error', ({ message }) => showToast(message, 'danger')),
    []
  )

  useEffect(() => {
    const stopNotice = onPush(
      'plugins:notice',
      ({ pluginName, message, tone }) => {
        showToast(`${pluginName}: ${message}`, tone)
      }
    )
    const stopClosePanel = onPush('plugins:closePanel', ({ pluginId, panelId }) => {
      useWorkspaceStore.getState().closeTabsMatching(descriptorFor('plugin-panel', { pluginId, panelId }))
    })
    const stopOpenPanel = onPush(
      'plugins:openPanel',
      ({ pluginId, panelId }) => {
        openTab(descriptorFor('plugin-panel', { pluginId, panelId }))
      }
    )
    return () => {
      stopNotice()
      stopClosePanel()
      stopOpenPanel()
    }
  }, [openTab])

  useEffect(() => {
    if (consumedPendingOpen.current) return
    consumedPendingOpen.current = true
    // Same replay rule as deepLinkQueue: did-finish-load precedes React's
    // subscriptions, so a newly-created window pulls the buffered action only
    // after these onPush effects have mounted. Main clears it on this read.
    void invoke('ui:consumePendingOpen', {})
      .then((pending) => {
        if (pending?.material !== undefined) {
          handleOpenMaterial(pending.material)
        }
        if (pending?.url !== undefined) handleOpenUrl(pending.url)
      })
      .catch((error: unknown) => {
        console.error('[Bandal] 보류된 열기 요청을 가져오지 못했습니다.', error)
      })
  }, [handleOpenMaterial, handleOpenUrl])

  useEffect(() => {
    if (pendingChat === null) return
    if (selectedCourseId !== pendingChat.courseId) {
      if (courses.some((course) => course.id === pendingChat.courseId)) {
        selectCourse(pendingChat.courseId)
      }
      return
    }
    if (
      activeWorkspaceCourseId !== pendingChat.courseId ||
      workspaceHydration !== 'ready'
    ) {
      return
    }
    openTab(
      descriptorFor('chat', {
        courseId: pendingChat.courseId,
        conversationId: pendingChat.conversationId
      })
    )
    setPendingChat((current) =>
      current?.courseId === pendingChat.courseId &&
      current.conversationId === pendingChat.conversationId
        ? null
        : current
    )
  }, [
    activeWorkspaceCourseId,
    courses,
    openTab,
    pendingChat,
    selectCourse,
    selectedCourseId,
    workspaceHydration
  ])

  useEffect(() => {
    if (pendingMaterial === null) return
    if (selectedCourseId !== pendingMaterial.courseId) {
      if (courses.some((course) => course.id === pendingMaterial.courseId)) {
        selectCourse(pendingMaterial.courseId)
      }
      return
    }
    if (
      activeWorkspaceCourseId !== pendingMaterial.courseId ||
      workspaceHydration !== 'ready'
    ) {
      return
    }
    openTab(
      descriptorFor('file', {
        courseId: pendingMaterial.courseId,
        relPath: pendingMaterial.relPath
      })
    )
    setPendingMaterial((current) =>
      current?.courseId === pendingMaterial.courseId &&
      current.relPath === pendingMaterial.relPath
        ? null
        : current
    )
  }, [
    activeWorkspaceCourseId,
    courses,
    openTab,
    pendingMaterial,
    selectCourse,
    selectedCourseId,
    workspaceHydration
  ])

  useEffect(() => {
    if (!isSettingsOpen) return
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape' || event.defaultPrevented) return
      event.preventDefault()
      closeSettings()
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [closeSettings, isSettingsOpen])

  // [M5] A file dropped outside a drop target must never navigate the window.
  useEffect(() => {
    const prevent = (event: DragEvent): void => event.preventDefault()
    window.addEventListener('dragover', prevent)
    window.addEventListener('drop', prevent)
    return () => {
      window.removeEventListener('dragover', prevent)
      window.removeEventListener('drop', prevent)
    }
  }, [])

  // 저장된 사이드바 폭 복원 (없으면 tokens.css 기본값 그대로).
  useEffect(() => {
    applyStoredRailWidths()
  }, [])

  return (
    <div
      className="app-shell"
      data-settings={settingsPresent ? 'open' : 'closed'}
      data-board={isBoardOverlayOpen ? 'open' : 'closed'}
      data-left-rail={leftRailOpen ? 'open' : 'closed'}
      data-course-rail={leftRailOpen && courseRailVisible ? 'open' : 'closed'}
      data-left-panel={leftRailPanel}
      data-right-rail={materialsRailVisible ? 'open' : 'closed'}
    >
      <GlobalNavigation />
      <div id="course-rail" className="shell-course-rail" aria-hidden={!leftRailOpen || !courseRailVisible || settingsPresent}
        {...{ inert: !leftRailOpen || !courseRailVisible || settingsPresent ? '' : undefined }}>
        <CourseSidebar hidden={leftRailPanel !== 'courses'} />
        {learningMounted && <LearningSpacesPanel hidden={leftRailPanel !== 'learning'} />}
        {launcherMounted && <FeatureLauncherPanel hidden={leftRailPanel !== 'plugins'} />}
      </div>
      {leftRailOpen && courseRailVisible && !settingsPresent && <RailResizer side="left" />}

      <main className="app-workspace" aria-label="작업 공간" {...{ inert: settingsPresent ? '' : undefined }}>
        <WorkspaceHost />
        <RecordingIndicator />
      </main>

      <div className="shell-materials-rail" aria-hidden={!materialsRailVisible || settingsPresent}
        {...{ inert: !materialsRailVisible || settingsPresent ? '' : undefined }}>
        <MaterialsSidebar course={selectedCourse} />
      </div>
      {materialsRailVisible && !settingsPresent && <RailResizer side="right" />}

      <Suspense fallback={null}>
        <BrowserWebviewLayer />
        <PrintPreviewOverlay />
        {isBoardOverlayOpen && <BoardOverlay onClose={closeBoardOverlay} />}
        {isLinkGraphOpen && selectedCourse !== null && (
          <LinkGraphOverlay
            courseId={selectedCourse.id}
            onClose={closeLinkGraph}
          />
        )}
        <QuickFileSearch />
      </Suspense>
      {isOnboardingVisible && <OnboardingOverlay />}
      <ToastHost />
      <LearningDialogsHost />
      <PresentationProgress />
      {settingsPresent && (
        <div className="settings-overlay shell-settings-overlay" data-open={isSettingsOpen}
          {...{ inert: !isSettingsOpen ? '' : undefined }}>
          <Suspense
            fallback={
              <div className="settings-load-state" role="status">
                설정 불러오는 중…
              </div>
            }
          >
            <SettingsApp
              embedded
              onClose={closeSettings}
              initialCategory={settingsCategory}
            />
          </Suspense>
        </div>
      )}
      <ShellChrome />
      <TourOverlay />
    </div>
  )
}
