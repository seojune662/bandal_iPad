import type { LearningBinding } from '../../../../shared/types/learning'
import type { LearningView } from '../../../../shared/tabs'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { useUiStore } from '../../stores/uiStore'

export function openLearningHome(): void {
  const ui = useUiStore.getState()
  ui.closeSettings(); ui.closeBoardOverlay(); ui.closeLinkGraph()
  useUiStore.setState({ leftRailOpen: true, courseRailOpen: true, leftRailPanel: 'learning' })
  useWorkspaceStore.getState().showLearningHome()
}

export function returnToCourseWorkspace(courseId?: string): void {
  const courses = useCoursesStore.getState()
  const target = courseId ?? courses.selectedCourseId
  if (target && !courses.courses.some(course => course.id === target)) return
  courses.selectCourse(target)
  useUiStore.getState().showCourses()
}

export const RECENT_ENGLISH_KEY = 'bandal:lastEnglishBinding'
export function rememberEnglishBinding(binding: LearningBinding): void { try { localStorage.setItem(RECENT_ENGLISH_KEY, JSON.stringify(binding)) } catch { /* The explicit picker remains available. */ } }

export const LEARNING_CHANGED_EVENT = 'bandal:learning-changed'

export function notifyLearningChanged(): void {
  window.dispatchEvent(new Event(LEARNING_CHANGED_EVENT))
}

export function openLearning(binding: LearningBinding, view: LearningView = 'home', itemId?: string): void {
  useCoursesStore.getState().selectCourse(binding.courseId)
  useWorkspaceStore.getState().setActiveCourse(binding.courseId)
  useWorkspaceStore.getState().openTab(descriptorFor('learning', {
    ...binding, view, ...(itemId === undefined ? {} : { itemId })
  }))
}

export function learningError(error: unknown): string {
  return error instanceof Error ? error.message : '학습 자료를 처리하지 못했어요.'
}
