import { showToast } from '../../app/toast'
import { useCoursesStore } from '../../stores/coursesStore'
import { moveWorkspacePanel, useWorkspaceStore, workspaceApiForCourse, type WorkspacePanelMovePosition } from '../../stores/workspaceStore'
import { beginWorkspaceCourseMoveDrop, finishWorkspaceCourseMoveDrop, isWorkspaceCourseMoveDropCurrent, navigateWorkspaceCourseHover } from './courseTabMoveNavigation'
import type { WorkspaceTabDragSource } from './tabDragSession'

/** Course selection mounts Dockview asynchronously, even when its layout is cached. */
function waitForCourseWorkspace(courseId: string): Promise<boolean> {
  return new Promise(resolve => {
    let settled = false
    let stopWorkspace = (): void => {}
    let stopCourses = (): void => {}
    const timer = setTimeout(() => finish(false), 15_000)
    const finish = (ready: boolean): void => {
      if (settled) return
      settled = true
      clearTimeout(timer); stopWorkspace(); stopCourses(); resolve(ready)
    }
    const check = (): void => {
      const courses = useCoursesStore.getState(), state = useWorkspaceStore.getState()
      if (courses.selectedCourseId !== courseId || !courses.courses.some(course => course.id === courseId)) { finish(false); return }
      if (state.activeCourseId !== courseId) return
      if (state.hydration === 'error' || state.surface !== 'course') { finish(false); return }
      if (state.hydration === 'ready' && workspaceApiForCourse(courseId)) finish(true)
    }
    stopWorkspace = useWorkspaceStore.subscribe(check)
    stopCourses = useCoursesStore.subscribe(check)
    check()
  })
}

/** A row drop and a canvas drop use the same retained, one-shot transfer. */
export async function dropWorkspaceTabOnCourse(
  source: WorkspaceTabDragSource,
  targetCourseId: string,
  position?: WorkspacePanelMovePosition
): Promise<boolean> {
  if (source.courseId === targetCourseId || !beginWorkspaceCourseMoveDrop(source.nonce)) return false
  let accepted = false
  try {
    if (useCoursesStore.getState().selectedCourseId !== targetCourseId && !navigateWorkspaceCourseHover(source.nonce, targetCourseId)) return false
    if (!await waitForCourseWorkspace(targetCourseId)) {
      if (useCoursesStore.getState().selectedCourseId === targetCourseId)
        showToast('과목을 불러오지 못해 탭을 옮기지 못했어요. 원래 과목의 탭은 그대로 있어요.', 'danger')
      return false
    }
    // A subscriber may navigate again in the same turn that hydration becomes
    // ready, before this continuation runs. Do not commit behind that choice.
    const state = useWorkspaceStore.getState(), api = workspaceApiForCourse(targetCourseId)
    if (!isWorkspaceCourseMoveDropCurrent(source.nonce) || useCoursesStore.getState().selectedCourseId !== targetCourseId || state.activeCourseId !== targetCourseId || state.hydration !== 'ready' || state.surface !== 'course' || !api) return false
    const target = position ?? (api.activeGroup ? { groupId: api.activeGroup.id, direction: 'within' as const, index: api.activeGroup.panels.length } : undefined)
    accepted = await moveWorkspacePanel({ sourceCourseId: source.courseId, panelId: source.panelId, targetCourseId, ...(target ? { position: target } : {}) })
    return accepted
  } catch (error) {
    console.error('[Bandal] 탭 이동을 마무리하지 못했습니다.', error)
    showToast('탭을 옮기지 못했어요. 원래 과목에서 다시 시도해 주세요.', 'danger')
    return false
  } finally { finishWorkspaceCourseMoveDrop(source.nonce, accepted) }
}
