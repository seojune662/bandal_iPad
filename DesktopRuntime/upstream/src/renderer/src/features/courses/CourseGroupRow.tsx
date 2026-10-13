import type {
  DragEventHandler,
  MouseEvent as ReactMouseEvent,
  ReactNode
} from 'react'
import type { CourseGroup } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'

interface CourseGroupRowProps {
  group: CourseGroup
  courseCount: number
  collapsed: boolean
  menuOpen: boolean
  dropInto: boolean
  children: ReactNode
  onToggle: () => void
  onOpenMenu: (event: ReactMouseEvent<HTMLElement>) => void
  onHeaderDragOver: DragEventHandler<HTMLDivElement>
  onHeaderDragLeave: DragEventHandler<HTMLDivElement>
  onHeaderDrop: DragEventHandler<HTMLDivElement>
}

export function CourseGroupRow({
  group,
  courseCount,
  collapsed,
  menuOpen,
  dropInto,
  children,
  onToggle,
  onOpenMenu,
  onHeaderDragOver,
  onHeaderDragLeave,
  onHeaderDrop
}: CourseGroupRowProps): JSX.Element {
  return (
    <li className="course-group-row">
      <div
        className="course-group-row__header"
        data-drop-into={dropInto || undefined}
        onContextMenu={(event) => {
          event.preventDefault()
          onOpenMenu(event)
        }}
        onDragOver={onHeaderDragOver}
        onDragLeave={onHeaderDragLeave}
        onDrop={onHeaderDrop}
      >
        <button
          type="button"
          className="course-group-row__toggle"
          aria-label={`${group.name} 그룹 ${collapsed ? '펼치기' : '접기'}`}
          aria-expanded={!collapsed}
          onClick={onToggle}
        >
          <Icon name="chevronRight" />
          <span className="course-group-row__name">{group.name}</span>
          <span
            className="course-group-row__count"
            aria-label={`과목 ${courseCount}개`}
          >
            {courseCount}
          </span>
        </button>
        <button
          type="button"
          className="course-group-row__menu-button"
          aria-label={`${group.name} 그룹 메뉴`}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={(event) => onOpenMenu(event)}
        >
          <span aria-hidden="true">⋯</span>
        </button>
      </div>

      {!collapsed && (
        <ul className="course-group-row__courses">
          {courseCount === 0 ? (
            <li className="course-group-row__empty">
              과목을 끌어다 놓으세요
            </li>
          ) : (
            children
          )}
        </ul>
      )}
    </li>
  )
}
