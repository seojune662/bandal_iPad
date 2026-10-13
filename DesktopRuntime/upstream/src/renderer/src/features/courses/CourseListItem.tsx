import type { HTMLAttributes, MouseEventHandler } from 'react'
import type { Course } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { FavoritesSection } from './FavoritesSection'
import { CourseMark } from './CourseMark'
import { useWorkspaceCourseHover } from './useWorkspaceCourseHover'

interface CourseListItemProps {
  course: Course
  selected: boolean
  pending: boolean
  expanded: boolean
  menuOpen: boolean
  dropBefore: boolean
  dragging: boolean
  dragProps: HTMLAttributes<HTMLDivElement>
  onContextMenu: MouseEventHandler<HTMLDivElement>
  onOpenMenu: MouseEventHandler<HTMLButtonElement>
  onToggle: () => void
  onSelect: () => void
}

export function CourseListItem({
  course,
  selected,
  pending,
  expanded,
  menuOpen,
  dropBefore,
  dragging,
  dragProps,
  onContextMenu,
  onOpenMenu,
  onToggle,
  onSelect
}: CourseListItemProps): JSX.Element {
  const hover = useWorkspaceCourseHover().rowProps(course.id, !pending)
  return (
    <li>
      <div
        className="course-row"
        data-selected={selected}
        data-missing={course.missing || undefined}
        data-drop-before={dropBefore || undefined}
        data-dragging={dragging || undefined}
        {...dragProps}
        onDragEnter={event => { hover.onDragEnter?.(event); if (!event.defaultPrevented) dragProps.onDragEnter?.(event) }}
        onDragOver={event => { hover.onDragOver?.(event); if (!event.defaultPrevented) dragProps.onDragOver?.(event) }}
        onDragLeave={dragProps.onDragLeave}
        onDrop={event => { hover.onDrop?.(event); if (!event.defaultPrevented) dragProps.onDrop?.(event) }}
        onContextMenu={onContextMenu}
      >
        <button
          type="button"
          className="course-row__toggle"
          aria-label={`${course.name} ${expanded ? '접기' : '펼치기'}`}
          aria-expanded={expanded}
          disabled={pending}
          onClick={() => {
            onToggle()
          }}
        >
          <Icon name="chevronRight" />
        </button>
        <button
          type="button"
          className="course-row__select"
          aria-current={selected ? 'page' : undefined}
          disabled={pending}
          onClick={onSelect}
        >
          <CourseMark color={course.color} />
          <span className="course-row__name">{course.name}</span>
          {course.missing ? (
            <span className="course-row__badge">연결 끊김</span>
          ) : null}
        </button>
        <button
          type="button"
          className="course-row__menu-button"
          aria-label={`${course.name} 과목 메뉴`}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          disabled={pending}
          onClick={onOpenMenu}
        >
          <span aria-hidden="true">⋯</span>
        </button>
      </div>
      {expanded && (
        <div className="course-row__children">
          <FavoritesSection courseId={course.id} />
        </div>
      )}
    </li>
  )
}
