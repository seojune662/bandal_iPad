import { ensureSettingsLoaded } from '../../../stores/settingsSnapshot'
import { create } from 'zustand'
import {
  TUTORIAL_VERSION,
  type Settings
} from '../../../../../shared/types/settings'
import { showToast } from '../../../app/toast'
import { invoke, onPush } from '../../../lib/ipc'
import { useCoursesStore } from '../../../stores/coursesStore'
import { useUiStore } from '../../../stores/uiStore'
import { useWorkspaceStore, type WorkspaceSurface } from '../../../stores/workspaceStore'
import { COURSE_COLORS } from '../../courses/courseColors'
import { descriptorFor } from '../../workspace/tabIdentity'
import { shouldShowOnboarding } from '../onboardingModel'
import { TOUR_STEP_COUNT, TOUR_STEPS } from './tourScript'
import type { TourBeforeAction } from './tourTypes'
import { onboardingCopy } from '../onboardingCopy'
import { captureLauncherContext } from '../../launcher/launcherContext'
import { tabPanelId } from '../../workspace/tabIdentity'
import samplePdf from '../../../../../../web-demo/public/sample.pdf?inline'

export type TourStatus =
  | 'idle'
  | 'offer'
  | 'acknowledging'
  | 'starting'
  | 'running'
  | 'cleaning'

interface TourStore {
  status: TourStatus
  stepIndex: number
  courseId: string | null
  seedNotePath: string | null
  seedPdfPath: string | null
  transitioning: boolean
  init: () => Promise<void>
  start: () => Promise<void>
  later: () => Promise<boolean>
  next: () => void
  back: () => void
  skip: () => void
  finish: () => void
}

let initialized = false
let lastSeenVersion = 0
let unsubscribeSettings: (() => void) | null = null

// Invalidates asynchronous step setup before any cleanup or new tour.
let tourGeneration = 0

type TourLocation = {
  selectedCourseId: string | null
  activeCourseId: string | null
  activePanelId: string | null
  surface: WorkspaceSurface
  ui: Pick<ReturnType<typeof useUiStore.getState>, 'leftRailOpen' | 'courseRailOpen' | 'leftRailPanel' | 'rightRailOpen' | 'isSettingsOpen' | 'settingsCategory' | 'isBoardOverlayOpen' | 'isLinkGraphOpen'>
}
let previousLocation: TourLocation | null = null

function captureLocation(): TourLocation {
  const workspace = useWorkspaceStore.getState()
  const ui = useUiStore.getState()
  return {
    selectedCourseId: useCoursesStore.getState().selectedCourseId,
    activeCourseId: workspace.activeCourseId, activePanelId: workspace.activePanelId,
    surface: workspace.surface,
    ui: { leftRailOpen: ui.leftRailOpen, courseRailOpen: ui.courseRailOpen, leftRailPanel: ui.leftRailPanel,
      rightRailOpen: ui.rightRailOpen, isSettingsOpen: ui.isSettingsOpen, settingsCategory: ui.settingsCategory,
      isBoardOverlayOpen: ui.isBoardOverlayOpen, isLinkGraphOpen: ui.isLinkGraphOpen }
  }
}

async function restoreLocation(): Promise<void> {
  const previous = previousLocation
  if (!previous) return
  const courses = useCoursesStore.getState()
  const available = (id: string | null): string | null => id && courses.courses.some(course => course.id === id) ? id : null
  const active = available(previous.activeCourseId)
  courses.selectCourse(available(previous.selectedCourseId))
  const workspace = useWorkspaceStore.getState()
  workspace.showCourseWorkspace(active)
  if (active) {
    await waitForWorkspaceCourse(active)
    if (previous.activePanelId && useWorkspaceStore.getState().openTabs[previous.activePanelId]) {
      useWorkspaceStore.getState().activatePanel(previous.activePanelId)
    }
  }
  if (previous.surface === 'learning-home') workspace.showLearningHome()
  else if (previous.surface === 'study-market') workspace.showStudyMarket()
  useUiStore.setState(previous.ui)
  previousLocation = null
}

function tutorialSettings(courseId: string | null): Settings['tutorial'] {
  return { seenVersion: Math.max(lastSeenVersion, TUTORIAL_VERSION), activeCourseId: courseId }
}

function chooseTourColor(): string {
  const courses = useCoursesStore.getState().courses
  const used = new Set(courses.map((course) => course.color))
  const unused = COURSE_COLORS.find((color) => !used.has(color))
  if (unused !== undefined) return unused
  return COURSE_COLORS[courses.length % COURSE_COLORS.length] ?? COURSE_COLORS[0]
}

function descriptorCourseId(
  descriptor: ReturnType<typeof descriptorFor>
): string | null {
  return 'courseId' in descriptor.payload &&
    typeof descriptor.payload.courseId === 'string'
    ? descriptor.payload.courseId
    : null
}

async function closeCourseTabs(courseId: string): Promise<void> {
  const workspace = useWorkspaceStore.getState()
  await workspace.closeTabs(Object.entries(workspace.openTabs)
    .filter(([, descriptor]) => descriptorCourseId(descriptor) === courseId).map(([panelId]) => panelId))
}

function revealTourSurfaces(): void {
  const ui = useUiStore.getState()
  ui.closeSettings()
  ui.closeBoardOverlay()
  ui.showCourses()
  if (!ui.rightRailOpen) ui.toggleRightRail()
}

function unknownCourse(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return message.toLowerCase().includes('unknown course')
}

async function waitForWorkspaceCourse(
  courseId: string,
  timeoutMs = 3_000
): Promise<void> {
  const ready = (): boolean => {
    const state = useWorkspaceStore.getState()
    return state.activeCourseId === courseId && state.hydration === 'ready'
  }
  if (ready()) return

  await new Promise<void>((resolve) => {
    let settled = false
    const finish = (): void => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      unsubscribe()
      resolve()
    }
    const unsubscribe = useWorkspaceStore.subscribe(() => {
      if (ready()) finish()
    })
    const timeout = setTimeout(finish, timeoutMs)
  })
}

async function waitForPaint(): Promise<void> {
  await new Promise<void>((resolve) => {
    window.requestAnimationFrame(() => resolve())
  })
}

async function prepareStep(
  action: TourBeforeAction | null,
  courseId: string,
  seedNotePath: string,
  seedPdfPath: string,
  isCurrent: () => boolean
): Promise<void> {
  if (action === null || !isCurrent()) return
  const ui = useUiStore.getState()
  ui.showCourses()
  const courses = useCoursesStore.getState()
  courses.selectCourse(courseId)
  const workspace = useWorkspaceStore.getState()
  workspace.showCourseWorkspace(courseId)
  await waitForWorkspaceCourse(courseId)
  if (!isCurrent() || useWorkspaceStore.getState().activeCourseId !== courseId) return
  if (action === 'show-materials') return
  const pdf = descriptorFor('pdf', { courseId, relPath: seedPdfPath })
  if (action === 'open-reading') {
    workspace.openTab(pdf)
    workspace.openTab(descriptorFor('note', { courseId, relPath: seedNotePath }), { beside: true })
    return
  }
  workspace.openTab(pdf)
  await waitForPaint()
  if (!isCurrent()) return
  await waitForPaint()
  if (!isCurrent()) return
  if (action === 'open-assistant') {
    // Open only this document's actual sidebar. Never fall back to a new chat
    // or dispatch a prompt if the document is still mounting.
    const panel = document.querySelector<HTMLElement>(`[data-tour-panel="${CSS.escape(tabPanelId(pdf))}"]`)
    const toggle = panel?.querySelector<HTMLButtonElement>('.tab-assistant-toggle')
    if (toggle?.getAttribute('aria-expanded') === 'false') toggle.click()
    return
  }
  await captureLauncherContext()
  if (!isCurrent()) return
  useUiStore.setState({ leftRailOpen: true, courseRailOpen: true, leftRailPanel: 'plugins' })
}

/**
 * One cleanup path for finish, skip, failed starts and boot-time leak repair.
 * The marker is cleared only after both the soft delete and guarded purge have
 * completed, so a transient failure remains repairable on the next boot.
 */
async function cleanupCourse(
  courseId: string,
  clearMarker: boolean
): Promise<void> {
  await closeCourseTabs(courseId)

  try {
    await useCoursesStore.getState().loadCourses()
  } catch (error) {
    console.error('[Bandal] 튜토리얼 정리 전 과목 목록을 불러오지 못했습니다.', error)
  }

  const coursesState = useCoursesStore.getState()
  const otherCourse = coursesState.courses.find(course => course.id === previousLocation?.activeCourseId && course.id !== courseId)
    ?? coursesState.courses.find(course => course.id !== courseId)
  if (otherCourse !== undefined) {
    coursesState.selectCourse(otherCourse.id)
    useWorkspaceStore.getState().setActiveCourse(otherCourse.id)
  }

  let liveCourseExists = coursesState.courses.some(
    (course) => course.id === courseId
  )
  if (!liveCourseExists) {
    try {
      const liveCourses = await invoke('courses:list', {})
      liveCourseExists = liveCourses.some((course) => course.id === courseId)
    } catch (error) {
      console.error('[Bandal] 남은 튜토리얼 과목을 확인하지 못했습니다.', error)
    }
  }

  if (liveCourseExists) {
    await useCoursesStore.getState().deleteCourse(courseId)
  }

  if (otherCourse === undefined) {
    useWorkspaceStore.getState().setActiveCourse(null)
  } else {
    useWorkspaceStore.getState().setActiveCourse(otherCourse.id)
  }

  try {
    await invoke('courses:purge', { courseId })
  } catch (error) {
    // A completed purge followed by a settings write crash leaves only the
    // marker. Treat that exact recovery case as already clean.
    if (!unknownCourse(error)) throw error
  }

  if (clearMarker) {
    await invoke('settings:set', { tutorial: tutorialSettings(null) })
  }
}

export const useTourStore = create<TourStore>()((set, get) => {
  const enterStep = async (stepIndex: number): Promise<void> => {
    const state = get()
    if (
      state.status !== 'running' ||
      state.transitioning ||
      state.courseId === null ||
      state.seedNotePath === null ||
      state.seedPdfPath === null
    ) {
      return
    }
    const step = TOUR_STEPS[stepIndex]
    if (step === undefined) return

    const generation = tourGeneration
    const isCurrent = (): boolean => generation === tourGeneration &&
      get().status === 'running' && get().courseId === state.courseId
    set({ transitioning: true })
    try {
      await prepareStep(
        step.before,
        state.courseId,
        state.seedNotePath,
        state.seedPdfPath,
        isCurrent
      )
    } catch (error) {
      // Step setup is presentational. A missing/failed surface must never
      // make the narration impossible to finish.
      console.error('[Bandal] 튜토리얼 화면을 준비하지 못했습니다.', error)
    }
    if (isCurrent()) {
      set({ stepIndex, transitioning: false })
    }
  }

  const endTour = async (): Promise<void> => {
    const state = get()
    if (state.status !== 'running' || state.courseId === null) return
    tourGeneration += 1
    set({ status: 'cleaning', transitioning: false })
    try {
      await cleanupCourse(state.courseId, true)
      await restoreLocation()
      set({
        status: 'idle',
        stepIndex: 0,
        courseId: null,
        seedNotePath: null,
        seedPdfPath: null
      })
    } catch (error) {
      console.error('[Bandal] 튜토리얼 임시 과목을 정리하지 못했습니다.', error)
      showToast(
        onboardingCopy().cleanupFailed,
        'danger'
      )
      set({ status: 'running' })
    }
  }

  return {
    status: 'idle',
    stepIndex: 0,
    courseId: null,
    seedNotePath: null,
    seedPdfPath: null,
    transitioning: false,

    init: async () => {
      if (initialized) return
      initialized = true

      unsubscribeSettings = onPush('settings:changed', ({ settings }) => {
        const replayRequested = lastSeenVersion > 0 && settings.tutorial.seenVersion === 0
        lastSeenVersion = settings.tutorial.seenVersion
        if (replayRequested && get().status === 'idle' &&
            !shouldShowOnboarding(settings.onboarding)) void get().start()
      })

      try {
        const settings = await ensureSettingsLoaded()
        lastSeenVersion = settings.tutorial.seenVersion
        const leakedCourseId = settings.tutorial.activeCourseId
        if (leakedCourseId !== null) {
          try {
            await cleanupCourse(leakedCourseId, true)
          } catch (error) {
            // Boot repair is intentionally quiet. Keeping the marker intact
            // makes the next boot another safe retry.
            console.error('[Bandal] 남은 튜토리얼 과목을 복구하지 못했습니다.', error)
          }
          return
        }

        if (
          settings.tutorial.seenVersion < TUTORIAL_VERSION &&
          !shouldShowOnboarding(settings.onboarding)
        ) {
          set({ status: 'offer' })
        }
      } catch (error) {
        console.error('[Bandal] 튜토리얼 설정을 불러오지 못했습니다.', error)
      }
    },

    start: async () => {
      const previousStatus = get().status
      if (previousStatus !== 'idle' && previousStatus !== 'offer') return
      tourGeneration += 1
      previousLocation = captureLocation()
      set({ status: 'starting', transitioning: false })

      let createdCourseId: string | null = null
      let markerWritten = false
      try {
        const settings = await invoke('settings:get', {})
        lastSeenVersion = settings.tutorial.seenVersion
        const copy = onboardingCopy()
        if (settings.dataRoot.trim().length === 0) {
          showToast(copy.dataRoot, 'danger')
          previousLocation = null
          set({ status: previousStatus })
          return
        }

        // Never overwrite a recovery marker with a second sample course.
        // A previous interrupted cleanup must succeed before a fresh tour.
        if (settings.tutorial.activeCourseId !== null) {
          if (settings.tutorial.seenVersion === 0) {
            // Consume the replay request without discarding its recovery
            // marker, so another replay can retry after a failed purge.
            await invoke('settings:set', { tutorial: tutorialSettings(settings.tutorial.activeCourseId) })
          }
          await cleanupCourse(settings.tutorial.activeCourseId, true)
        }
        revealTourSurfaces()

        const course = await useCoursesStore.getState().createCourse({
          name: copy.courseName,
          color: chooseTourColor()
        })
        createdCourseId = course.id

        await invoke('settings:set', {
          tutorial: tutorialSettings(course.id)
        })
        markerWritten = true

        const seed = await invoke('materials:writeFile', {
          courseId: course.id,
          dirRelPath: '',
          fileName: copy.noteName,
          encoding: 'utf8',
          data: copy.seedNote
        })
        const pdf = await invoke('materials:writeFile', {
          courseId: course.id, dirRelPath: '', fileName: copy.pdfName,
          encoding: 'base64', data: samplePdf.slice(samplePdf.indexOf(',') + 1)
        })
        useCoursesStore.getState().selectCourse(course.id)
        useWorkspaceStore.getState().showCourseWorkspace(course.id)
        await waitForWorkspaceCourse(course.id)

        set({
          status: 'running',
          stepIndex: 0,
          courseId: course.id,
          seedNotePath: seed.relPath,
          seedPdfPath: pdf.relPath,
          transitioning: false
        })
      } catch (error) {
        console.error('[Bandal] 튜토리얼을 시작하지 못했습니다.', error)
        if (createdCourseId !== null) {
          try {
            await cleanupCourse(createdCourseId, markerWritten)
          } catch (cleanupError) {
            console.error(
              '[Bandal] 시작에 실패한 튜토리얼 과목을 정리하지 못했습니다.',
              cleanupError
            )
          }
        }
        await restoreLocation()
        showToast(onboardingCopy().startFailed, 'danger')
        set({
          status: 'idle',
          stepIndex: 0,
          courseId: null,
          seedNotePath: null,
          seedPdfPath: null,
          transitioning: false
        })
      }
    },

    later: async () => {
      const status = get().status
      if (status !== 'idle' && status !== 'offer') return false
      set({ status: 'acknowledging' })
      try {
        const settings = await invoke('settings:get', {})
        lastSeenVersion = settings.tutorial.seenVersion
        if (settings.tutorial.activeCourseId !== null) {
          previousLocation = captureLocation()
          await cleanupCourse(settings.tutorial.activeCourseId, false)
          await restoreLocation()
        }
        await invoke('settings:set', { tutorial: tutorialSettings(null) })
        set({ status: 'idle' })
        return true
      } catch (error) {
        console.error('[Bandal] 튜토리얼 제안 상태를 저장하지 못했습니다.', error)
        await restoreLocation()
        showToast(onboardingCopy().saveFailed, 'danger')
        set({ status })
        return false
      }
    },

    next: () => {
      const state = get()
      if (state.status !== 'running' || state.transitioning) return
      const nextIndex = state.stepIndex + 1
      if (nextIndex >= TOUR_STEP_COUNT) {
        void endTour()
      } else {
        void enterStep(nextIndex)
      }
    },

    back: () => {
      const state = get()
      if (
        state.status !== 'running' ||
        state.transitioning ||
        state.stepIndex <= 0
      ) {
        return
      }
      void enterStep(state.stepIndex - 1)
    },

    skip: () => {
      void endTour()
    },

    finish: () => {
      void endTour()
    }
  }
})

/** Reset module subscriptions and recovery state between lifecycle tests. */
export function resetTourForTests(): void {
  unsubscribeSettings?.()
  unsubscribeSettings = null
  initialized = false
  lastSeenVersion = 0
  previousLocation = null
  tourGeneration += 1
  useTourStore.setState({ status: 'idle', stepIndex: 0, courseId: null, seedNotePath: null, seedPdfPath: null, transitioning: false })
}
