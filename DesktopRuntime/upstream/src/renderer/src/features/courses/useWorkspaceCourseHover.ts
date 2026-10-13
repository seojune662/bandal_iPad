import type { DragEvent, HTMLAttributes } from 'react'
import { useCoursesStore } from '../../stores/coursesStore'
import { BANDAL_TAB_DRAG_MIME, matchesWorkspaceMoveData } from '../workspace/tabDrag'
import { tabDragSession } from '../workspace/tabDragSession'
import { navigateWorkspaceCourseHover } from '../workspace/courseTabMoveNavigation'
import { dropWorkspaceTabOnCourse } from '../workspace/workspaceTabDrop'

/** Entering a folder changes the canvas immediately; the held tab stays in its source. */
export function useWorkspaceCourseHover(): { rowProps(courseId: string, enabled: boolean): HTMLAttributes<HTMLDivElement> } {
  return { rowProps: (courseId, enabled) => {
    const enter = (event: DragEvent<HTMLDivElement>): void => {
      const source = tabDragSession.getSource(), courses = useCoursesStore.getState()
      if (!enabled || !source || tabDragSession.getSnapshot() !== 'tab' || !event.dataTransfer.types.includes(BANDAL_TAB_DRAG_MIME) ||
        !courses.courses.some(course => course.id === courseId)) return
      event.preventDefault()
      event.stopPropagation()
      event.dataTransfer.dropEffect = 'move'
      // Native DnD can change child targets or omit dragleave during a course
      // render. Selection must follow the current entry, never a queued timer.
      if (courses.selectedCourseId !== courseId) navigateWorkspaceCourseHover(source.nonce, courseId)
    }
    return {
      onDragEnter: enter,
      onDragOver: enter,
      onDrop: event => {
        const source = tabDragSession.getSource()
        if (!enabled || !source || tabDragSession.getSnapshot() !== 'tab' || !event.dataTransfer.types.includes(BANDAL_TAB_DRAG_MIME) ||
          !matchesWorkspaceMoveData(event.dataTransfer, source)) return
        event.preventDefault()
        event.stopPropagation()
        void dropWorkspaceTabOnCourse(source, courseId)
      }
    }
  } }
}
