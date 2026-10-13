import { useEffect, useState, type HTMLAttributes } from 'react'
import type { Course } from '../../../../shared/types/course'
import { useCoursesStore } from '../../stores/coursesStore'
import {
  canAcceptCourseDrag,
  clearCurrentCourseDrag,
  COURSE_DRAG_MIME,
  getCurrentCourseDrag,
  parseCourseDrag,
  serializeCourseDrag,
  setCurrentCourseDrag
} from './courseDrag'

type CourseDropTarget =
  | { kind: 'before'; courseId: string }
  | { kind: 'group'; groupId: string }
  | { kind: 'ungrouped'; position: 'top' | 'bottom' }

export function useCourseDrag(isSearching: boolean) {
  const organizeCourse = useCoursesStore((state) => state.organizeCourse)
  const [dropTarget, setDropTarget] = useState<CourseDropTarget | null>(null)
  const [draggingCourseId, setDraggingCourseId] = useState<string | null>(null)
  useEffect(() => () => clearCurrentCourseDrag(), [])
  useEffect(() => {
    if (!isSearching) return
    clearCurrentCourseDrag()
    setDraggingCourseId(null)
    setDropTarget(null)
  }, [isSearching])
  const finishCourseDrag = (): void => {
    clearCurrentCourseDrag()
    setDraggingCourseId(null)
    setDropTarget(null)
  }

  const startCourseDrag = (
    event: React.DragEvent<HTMLDivElement>,
    courseId: string
  ): void => {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData(COURSE_DRAG_MIME, serializeCourseDrag(courseId))
    setCurrentCourseDrag({ version: 1, courseId })
    setDraggingCourseId(courseId)
    setDropTarget(null)
  }

  const courseIdFromDrop = (
    event: React.DragEvent<HTMLElement>
  ): string | null => {
    if (!canAcceptCourseDrag(event.dataTransfer.types)) return null
    const current = getCurrentCourseDrag()
    const parsed = parseCourseDrag(event.dataTransfer.getData(COURSE_DRAG_MIME))
    if (current === null || parsed?.courseId !== current.courseId) return null
    return parsed.courseId
  }

  const isUpperCourseRowHalf = (
    event: React.DragEvent<HTMLDivElement>
  ): boolean => {
    const bounds = event.currentTarget.getBoundingClientRect()
    return (
      bounds.height === 0 || event.clientY <= bounds.top + bounds.height / 2
    )
  }

  const organizeDroppedCourse = (
    courseId: string,
    groupId: string | null,
    beforeCourseId: string | null
  ): void => {
    if (beforeCourseId === courseId) return
    finishCourseDrag()
    void organizeCourse(courseId, groupId, beforeCourseId).catch(() => {
      // The store owns the persistent error shown above the list.
    })
  }

  const handleGroupDragOver = (
    event: React.DragEvent<HTMLDivElement>,
    groupId: string
  ): void => {
    if (
      !canAcceptCourseDrag(event.dataTransfer.types) ||
      getCurrentCourseDrag() === null
    ) {
      return
    }
    event.preventDefault()
    event.stopPropagation()
    setDropTarget({ kind: 'group', groupId })
  }

  const handleGroupDrop = (
    event: React.DragEvent<HTMLDivElement>,
    groupId: string
  ): void => {
    if (getCurrentCourseDrag() === null) return
    const draggedCourseId = courseIdFromDrop(event)
    if (draggedCourseId === null) return
    event.preventDefault()
    event.stopPropagation()
    organizeDroppedCourse(draggedCourseId, groupId, null)
  }

  const handleUngroupedDragOver = (
    event: React.DragEvent<HTMLLIElement>,
    position: 'top' | 'bottom'
  ): void => {
    if (
      !canAcceptCourseDrag(event.dataTransfer.types) ||
      getCurrentCourseDrag() === null
    ) {
      return
    }
    event.preventDefault()
    event.stopPropagation()
    setDropTarget({ kind: 'ungrouped', position })
  }

  const handleUngroupedDrop = (event: React.DragEvent<HTMLLIElement>): void => {
    if (getCurrentCourseDrag() === null) return
    const draggedCourseId = courseIdFromDrop(event)
    if (draggedCourseId === null) return
    event.preventDefault()
    event.stopPropagation()
    organizeDroppedCourse(draggedCourseId, null, null)
  }

  const rowDragProps = (
    course: Course,
    dragEnabled: boolean
  ): HTMLAttributes<HTMLDivElement> => ({
    draggable: dragEnabled,
    onDragStart: dragEnabled
      ? (event) => startCourseDrag(event, course.id)
      : undefined,
    onDragEnd: dragEnabled ? finishCourseDrag : undefined,
    onDragOver: dragEnabled
      ? (event) => {
          const current = getCurrentCourseDrag()
          const accepts = canAcceptCourseDrag(event.dataTransfer.types)
          if (
            !accepts ||
            current === null ||
            current.courseId === course.id ||
            !isUpperCourseRowHalf(event)
          ) {
            setDropTarget((target) =>
              target?.kind === 'before' && target.courseId === course.id
                ? null
                : target
            )
            return
          }
          event.preventDefault()
          event.stopPropagation()
          setDropTarget({ kind: 'before', courseId: course.id })
        }
      : undefined,
    onDragLeave: dragEnabled
      ? (event) => {
          if (
            event.relatedTarget instanceof Node &&
            event.currentTarget.contains(event.relatedTarget)
          ) {
            return
          }
          setDropTarget((target) =>
            target?.kind === 'before' && target.courseId === course.id
              ? null
              : target
          )
        }
      : undefined,
    onDrop: dragEnabled
      ? (event) => {
          const current = getCurrentCourseDrag()
          if (
            current === null ||
            current.courseId === course.id ||
            !isUpperCourseRowHalf(event)
          ) {
            return
          }
          const draggedCourseId = courseIdFromDrop(event)
          if (draggedCourseId === null || draggedCourseId === course.id) {
            return
          }
          event.preventDefault()
          event.stopPropagation()
          organizeDroppedCourse(draggedCourseId, course.groupId, course.id)
        }
      : undefined
  })
  return {
    dropTarget,
    setDropTarget,
    draggingCourseId,
    rowDragProps,
    handleGroupDragOver,
    handleGroupDrop,
    handleUngroupedDragOver,
    handleUngroupedDrop
  }
}
