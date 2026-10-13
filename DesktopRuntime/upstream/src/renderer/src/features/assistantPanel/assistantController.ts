import { useSyncExternalStore } from 'react'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { useUiStore } from '../../stores/uiStore'
import { showToast } from '../../app/toast'
import { descriptorFor } from '../workspace/tabIdentity'
import type { LearningBinding } from '../../../../shared/types/learning'
import { openLearning } from '../learning/learningNavigation'

interface AssistantController {
  courseId: string | null
  open: boolean
  show(): void
  focus(): void
}

const controllers = new Map<string, AssistantController>()
const listeners = new Set<() => void>()
const pendingFocus = new Set<string>()
const pendingShow = new Set<string>()
let pendingCourseFocus: string | null = null
const keyFor = (panelId: string, courseId: string | null): string => JSON.stringify([courseId, panelId])
useWorkspaceStore.subscribe(state => {
  const activeKey = state.surface === 'course' && state.activePanelId ? keyFor(state.activePanelId, state.activeCourseId) : null
  for (const key of pendingShow) if (key !== activeKey) { pendingShow.delete(key); pendingFocus.delete(key) }
  if (state.surface !== 'course') { pendingFocus.clear(); pendingCourseFocus = null }
})
const notify = (): void => { for (const listener of listeners) listener() }
const subscribe = (listener: () => void): (() => void) => {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

/** Connect shell shortcuts to each tab's existing state and composer. */
export function registerAssistantController(panelId: string, controller: AssistantController,
  workspaceCourseId: string | null = controller.courseId): () => void {
  const key = keyFor(panelId, workspaceCourseId)
  controllers.set(key, controller)
  notify()
  const workspace = useWorkspaceStore.getState()
  const source = workspace.activePanelSource()
  if (workspace.surface === 'course' && workspace.activeCourseId === workspaceCourseId && source?.panelId === panelId && pendingShow.delete(key)) {
    controller.show()
  }
  if (workspace.activeCourseId === workspaceCourseId && source?.panelId === panelId && (pendingFocus.delete(key) ||
      (source.descriptor.kind === 'chat' && pendingCourseFocus === controller.courseId))) {
    pendingCourseFocus = null
    controller.focus()
  }
  return () => {
    if (controllers.get(key) !== controller) return
    controllers.delete(key)
    pendingFocus.delete(key)
    pendingShow.delete(key)
    notify()
  }
}

function focusPanel(panelId: string): void {
  const key = keyFor(panelId, useWorkspaceStore.getState().activeCourseId)
  const controller = controllers.get(key)
  if (controller) controller.focus()
  else pendingFocus.add(key)
}

/** Opening never creates a replacement conversation for an existing document. */
export function openActiveAssistant(): void {
  const workspace = useWorkspaceStore.getState()
  if (workspace.surface === 'study-market') {
    workspace.showCourseWorkspace(useCoursesStore.getState().selectedCourseId)
    useUiStore.getState().showCourses()
  }
  if (workspace.surface === 'learning-home') {
    pendingCourseFocus = null
    pendingFocus.clear(); pendingShow.clear()
    window.dispatchEvent(new CustomEvent('bandal:choose-ai-context'))
    return
  }
  const source = workspace.activePanelSource()
  const controller = source && controllers.get(keyFor(source.panelId, workspace.activeCourseId))
  if (controller?.courseId) {
    pendingCourseFocus = null
    pendingFocus.clear()
    controller.show()
    controller.focus()
    return
  }

  const { selectedCourseId, courses } = useCoursesStore.getState()
  if (!selectedCourseId || !courses.some(course => course.id === selectedCourseId)) {
    useUiStore.getState().showCourses()
    showToast('과목을 선택하면 AI와 대화할 수 있어요.')
    return
  }

  // Focus by actual panel identity: legacy chat tabs retain their old panel ID
  // even after ChatTab normalizes the descriptor to a specific conversation.
  const existing = workspace.activeCourseId === selectedCourseId
    ? Object.entries(workspace.openTabs).find(([, descriptor]) =>
      descriptor.kind === 'chat' && descriptor.payload.courseId === selectedCourseId)
    : undefined
  if (existing) {
    workspace.activatePanel(existing[0])
    focusPanel(existing[0])
    return
  }
  pendingCourseFocus = selectedCourseId
  workspace.openTab(descriptorFor('chat', { courseId: selectedCourseId }))
  const opened = workspace.activePanelSource()
  if (opened?.descriptor.kind === 'chat' && opened.descriptor.payload.courseId === selectedCourseId) {
    pendingCourseFocus = null
    focusPanel(opened.panelId)
  }
}

export function useActiveAssistantOpen(): boolean {
  const surface = useWorkspaceStore(state => state.surface)
  const panelId = useWorkspaceStore(state => state.activePanelId)
  const courseId = useWorkspaceStore(state => state.activeCourseId)
  return useSyncExternalStore(subscribe, () => surface === 'course' && panelId ? controllers.get(keyFor(panelId, courseId))?.open === true : false, () => false)
}

/** The home picker names a destination; it never reuses a hidden source. */
export async function openChosenAssistant(choice: { courseId: string; binding?: LearningBinding }): Promise<void> {
  const courses = useCoursesStore.getState()
  if (!courses.courses.some(course => course.id === choice.courseId) || (choice.binding && choice.binding.courseId !== choice.courseId)) {
    throw new Error('선택한 과목이나 학습 공간을 찾을 수 없어요.')
  }
  if (choice.binding) openLearning(choice.binding)
  else { courses.selectCourse(choice.courseId); useWorkspaceStore.getState().showCourseWorkspace(choice.courseId) }
  const ready = (): boolean => {
    const state = useWorkspaceStore.getState()
    return state.surface === 'course' && state.activeCourseId === choice.courseId && state.hydration === 'ready'
  }
  if (!ready()) await new Promise<void>((resolve, reject) => {
    const finish = (): void => { clearTimeout(timer); stop(); resolve() }
    const stop = useWorkspaceStore.subscribe(state => {
      if (state.surface !== 'course' || state.activeCourseId !== choice.courseId) {
        clearTimeout(timer); stop(); reject(new Error('다른 화면으로 이동해 AI 열기를 취소했어요.'))
      } else if (ready()) finish()
    })
    const timer = setTimeout(() => { stop(); reject(new Error('작업 공간을 열지 못했어요. 다시 선택해 주세요.')) }, 10_000)
    if (ready()) finish()
  })
  // Hydration publishes its state before replaying queued opens.
  await Promise.resolve()
  if (!ready()) return
  const workspace = useWorkspaceStore.getState()
  const source = workspace.activePanelSource()
  if (choice.binding) {
    if (source?.descriptor.kind !== 'learning' || source.descriptor.payload.courseId !== choice.binding.courseId || source.descriptor.payload.rootRelPath !== choice.binding.rootRelPath) {
      throw new Error('선택한 학습 공간을 열지 못했어요.')
    }
    const key = keyFor(source.panelId, choice.courseId)
    const controller = controllers.get(key)
    if (controller) { controller.show(); controller.focus() }
    else { pendingShow.add(key); pendingFocus.add(key) }
  } else openActiveAssistant()
}

/** Test-only reset; production registrations are released with their panels. */
export function resetAssistantControllersForTests(): void {
  controllers.clear()
  pendingFocus.clear()
  pendingShow.clear()
  pendingCourseFocus = null
  notify()
}
