import { useDismissableMenu } from '../../components/useDismissableMenu'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type {
  Course,
  CourseGroup,
  PickedFolder
} from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { BandalMark } from '../../components/BandalMark'
import { Tooltip } from '../../components/Tooltip'
import { useCoursesStore } from '../../stores/coursesStore'
import { UniversityShortcuts } from '../university/UniversityShortcuts'
import { AiShortcuts } from '../ai/AiShortcuts'
import {
  ArchiveCourseDialog,
  CourseFormDialog,
  DeleteCourseDialog
} from './CourseDialogs'
import {
  CourseGroupNameDialog,
  DeleteCourseGroupDialog
} from './CourseGroupDialogs'
import { CourseGroupRow } from './CourseGroupRow'
import {
  persistCollapsedCourseIds,
  readCollapsedCourseIds,
  selectAndExpandCourse
} from './courseCollapse'
import { useCourseDrag } from './useCourseDrag'
import { CourseListItem } from './CourseListItem'
import { openStudyMarketSell } from '../studyMarket/controller'
import {
  persistCollapsedGroupIds,
  readCollapsedGroupIds
} from './courseGroupCollapse'
import { folderProblemMessage } from './folderMessages'
import {
  COURSE_COLORS,
  courseColorLabel,
  normalizeCourseColor,
  type CourseColor
} from './courseColors'
import './courses.css'

interface ContextMenuState {
  course: Course
  x: number
  y: number
  placement: 'top' | 'bottom'
  alignEnd: boolean
}

interface AddMenuState {
  x: number
  y: number
}

interface GroupContextMenuState {
  group: CourseGroup
  x: number
  y: number
  placement: 'top' | 'bottom'
  alignEnd: boolean
}


export function CourseSidebar({ hidden = false }: { hidden?: boolean }): JSX.Element {
  const allCourses = useCoursesStore((state) => state.courses)
  const courses = useMemo(() => allCourses.filter(course => course.workspaceKind !== 'study-space'), [allCourses])
  const groups = useCoursesStore((state) => state.groups)
  const selectedCourseId = useCoursesStore((state) => state.selectedCourseId)
  const isLoading = useCoursesStore((state) => state.isLoading)
  const pendingCourseId = useCoursesStore((state) => state.pendingCourseId)
  const error = useCoursesStore((state) => state.error)
  const selectCourse = useCoursesStore((state) => state.selectCourse)
  const createGroup = useCoursesStore((state) => state.createGroup)
  const renameGroup = useCoursesStore((state) => state.renameGroup)
  const deleteGroup = useCoursesStore((state) => state.deleteGroup)
  const createCourse = useCoursesStore((state) => state.createCourse)
  const pickFolder = useCoursesStore((state) => state.pickFolder)
  const addCourseFromFolder = useCoursesStore((state) => state.addCourseFromFolder)
  const relinkCourse = useCoursesStore((state) => state.relinkCourse)
  const renameCourse = useCoursesStore((state) => state.renameCourse)
  const setCourseColor = useCoursesStore((state) => state.setCourseColor)
  const archiveCourse = useCoursesStore((state) => state.archiveCourse)
  const deleteCourse = useCoursesStore((state) => state.deleteCourse)
  const clearError = useCoursesStore((state) => state.clearError)
  const loadCourses = useCoursesStore((state) => state.loadCourses)

  const [query, setQuery] = useState('')
  const [createDialogOpen, setCreateDialogOpen] = useState(false)
  const [linkTarget, setLinkTarget] = useState<PickedFolder | null>(null)
  const [renameTarget, setRenameTarget] = useState<Course | null>(null)
  const [archiveTarget, setArchiveTarget] = useState<Course | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<Course | null>(null)
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null)
  const [addMenu, setAddMenu] = useState<AddMenuState | null>(null)
  const [createGroupDialogOpen, setCreateGroupDialogOpen] = useState(false)
  const [renameGroupTarget, setRenameGroupTarget] = useState<CourseGroup | null>(
    null
  )
  const [deleteGroupTarget, setDeleteGroupTarget] = useState<CourseGroup | null>(
    null
  )
  const [groupContextMenu, setGroupContextMenu] =
    useState<GroupContextMenuState | null>(null)
  const [collapsedCourseIds, setCollapsedCourseIds] = useState(
    readCollapsedCourseIds
  )
  const [collapsedGroupIds, setCollapsedGroupIds] = useState(
    readCollapsedGroupIds
  )
  const contextMenuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(contextMenuRef)
  const addMenuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(addMenuRef)
  const groupContextMenuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(groupContextMenuRef)

  useEffect(() => {
    const refreshAfterSettingsChange = (): void => {
      void loadCourses()
    }
    window.addEventListener('focus', refreshAfterSettingsChange)
    return () => window.removeEventListener('focus', refreshAfterSettingsChange)
  }, [loadCourses])

  const normalizedQuery = query.trim().toLocaleLowerCase()
  const isSearching = query.length > 0
  const { dropTarget, setDropTarget, draggingCourseId, rowDragProps, handleGroupDragOver, handleGroupDrop, handleUngroupedDragOver, handleUngroupedDrop } = useCourseDrag(isSearching)

  const visibleCourses = useMemo(() => {
    if (normalizedQuery.length === 0) return courses
    return courses.filter((course) =>
      course.name.toLocaleLowerCase().includes(normalizedQuery)
    )
  }, [courses, normalizedQuery])

  const organizedCourses = useMemo(() => {
    const sortedGroups = [...groups].sort(
      (first, second) => first.sortOrder - second.sortOrder
    )
    const coursesByGroup = new Map<string, Course[]>()
    for (const group of sortedGroups) coursesByGroup.set(group.id, [])

    const ungroupedCourses: Course[] = []
    for (const course of courses) {
      if (course.groupId === null || !coursesByGroup.has(course.groupId)) {
        ungroupedCourses.push(course)
      } else {
        coursesByGroup.get(course.groupId)?.push(course)
      }
    }

    return { sortedGroups, coursesByGroup, ungroupedCourses }
  }, [courses, groups])

  // Stable callbacks: the dismiss effect must not re-arm on every render.
  const closeContextMenu = useCallback(() => setContextMenu(null), [])
  const closeAddMenu = useCallback(() => setAddMenu(null), [])
  const closeGroupContextMenu = useCallback(
    () => setGroupContextMenu(null),
    []
  )
  useDismissableMenu(contextMenu !== null, contextMenuRef, closeContextMenu)
  useDismissableMenu(addMenu !== null, addMenuRef, closeAddMenu)
  useDismissableMenu(
    groupContextMenu !== null,
    groupContextMenuRef,
    closeGroupContextMenu
  )

  const setCourseExpanded = useCallback(
    (courseId: string, expanded: boolean): void => {
      setCollapsedCourseIds((current) => {
        const next = new Set(current)
        if (expanded) next.delete(courseId)
        else next.add(courseId)
        persistCollapsedCourseIds(next)
        return next
      })
    },
    []
  )

  const setGroupCollapsed = useCallback(
    (groupId: string, collapsed: boolean): void => {
      setCollapsedGroupIds((current) => {
        const next = new Set(current)
        if (collapsed) next.add(groupId)
        else next.delete(groupId)
        persistCollapsedGroupIds(next)
        return next
      })
    },
    []
  )

  const handleContextMenu = (event: React.MouseEvent, course: Course): void => {
    event.preventDefault()
    selectCourse(course.id)
    setAddMenu(null)
    setGroupContextMenu(null)
    setContextMenu({
      course,
      x: event.clientX,
      y: event.clientY,
      placement: event.clientY > window.innerHeight / 2 ? 'top' : 'bottom',
      alignEnd: false
    })
  }

  const openCourseMenu = (
    event: React.MouseEvent<HTMLButtonElement>,
    course: Course
  ): void => {
    event.stopPropagation()
    const rect = event.currentTarget.getBoundingClientRect()
    const placement = rect.bottom > window.innerHeight / 2 ? 'top' : 'bottom'
    selectCourse(course.id)
    setAddMenu(null)
    setGroupContextMenu(null)
    setContextMenu({
      course,
      x: rect.right,
      y: placement === 'top' ? rect.top : rect.bottom,
      placement,
      alignEnd: true
    })
  }

  const changeCourseColor = async (color: CourseColor): Promise<void> => {
    if (contextMenu === null) return
    try {
      await setCourseColor(contextMenu.course.id, color)
      setContextMenu(null)
    } catch {
      showToast('과목 색상을 바꾸지 못했어요.', 'danger')
    }
  }

  const openAddMenu = (event: React.MouseEvent<HTMLButtonElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect()
    setContextMenu(null)
    setGroupContextMenu(null)
    setAddMenu({ x: rect.right, y: rect.bottom })
  }

  const openGroupMenu = (
    event: React.MouseEvent<HTMLElement>,
    group: CourseGroup
  ): void => {
    const fromContextMenu = event.type === 'contextmenu'
    const rect = event.currentTarget.getBoundingClientRect()
    setAddMenu(null)
    setContextMenu(null)
    setGroupContextMenu({
      group,
      x: fromContextMenu ? event.clientX : rect.right,
      y: fromContextMenu ? event.clientY : rect.bottom,
      placement:
        fromContextMenu && event.clientY > window.innerHeight / 2
          ? 'top'
          : 'bottom',
      alignEnd: !fromContextMenu
    })
  }

  /** Native folder picker → link dialog (name prefilled with the basename). */
  const startFolderAdd = async (): Promise<void> => {
    setAddMenu(null)
    try {
      const picked = await pickFolder()
      if (picked !== null) setLinkTarget(picked)
    } catch {
      // The rail shows the store's persistent error message.
    }
  }

  const startRelink = async (course: Course): Promise<void> => {
    setContextMenu(null)
    try {
      const picked = await pickFolder()
      if (picked === null) return
      const result = await relinkCourse(course.id, picked.path)
      if (result.status === 'ok') showToast('폴더를 다시 연결했어요.')
    } catch {
      // The rail shows the store's persistent error message.
    }
  }

  const handleArchive = async (): Promise<void> => {
    if (archiveTarget === null) return
    try {
      await archiveCourse(archiveTarget.id, true)
      showToast(`“${archiveTarget.name}” 과목을 보관했어요.`)
      setArchiveTarget(null)
    } catch {
      showToast('과목을 보관하지 못했어요.', 'danger')
      // Keep the confirmation open so the user can retry or cancel.
    }
  }

  const handleDelete = async (): Promise<void> => {
    if (deleteTarget === null) return
    try {
      await deleteCourse(deleteTarget.id)
      setDeleteTarget(null)
    } catch {
      // Keep the confirmation open so the user can retry or cancel.
    }
  }

  const handleDeleteGroup = async (): Promise<void> => {
    if (deleteGroupTarget === null) return
    await deleteGroup(deleteGroupTarget.id)
    setCollapsedGroupIds((current) => {
      if (!current.has(deleteGroupTarget.id)) return current
      const next = new Set(current)
      next.delete(deleteGroupTarget.id)
      persistCollapsedGroupIds(next)
      return next
    })
  }

  const renderCourse = (course: Course, dragEnabled: boolean): JSX.Element => {
    const expanded = !collapsedCourseIds.has(course.id)
    return <CourseListItem key={course.id} course={course}
      selected={course.id === selectedCourseId} pending={course.id === pendingCourseId}
      expanded={expanded} menuOpen={contextMenu?.course.id === course.id}
      dropBefore={dropTarget?.kind === 'before' && dropTarget.courseId === course.id}
      dragging={draggingCourseId === course.id} dragProps={rowDragProps(course, dragEnabled)}
      onContextMenu={event => handleContextMenu(event, course)}
      onOpenMenu={event => openCourseMenu(event, course)}
      onToggle={() => setCourseExpanded(course.id, !expanded)}
      onSelect={() => selectAndExpandCourse(course.id, expanded, selectCourse, setCourseExpanded)}
    />
  }

  return (
    <aside className="app-rail app-rail--left" aria-label="과목 목록" hidden={hidden}>
      <UniversityShortcuts />
      <AiShortcuts />

      <div className="rail-heading">
        <div>
          <h2>과목</h2>
        </div>
        <Tooltip label="과목 추가" placement="bottom">
          <button
            type="button"
            className="bare-icon-button"
            aria-label="과목 추가"
            aria-haspopup="menu"
            aria-expanded={addMenu !== null}
            onClick={openAddMenu}
          >
            <Icon name="plus" />
          </button>
        </Tooltip>
      </div>

      <div className="rail-search">
        <Icon name="search" className="rail-search__icon" />
        <label className="sr-only" htmlFor="course-search">
          과목 검색
        </label>
        <input
          id="course-search"
          type="search"
          placeholder="과목 찾기"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        {query.length > 0 && (
          <button
            type="button"
            className="rail-search__clear"
            aria-label="검색어 지우기"
            onClick={() => setQuery('')}
          >
            <Icon name="x" />
          </button>
        )}
      </div>

      {error !== null && (
        <div className="rail-error" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="오류 닫기" onClick={clearError}>
            <Icon name="x" />
          </button>
        </div>
      )}

      <div
        className="app-rail__body course-list-area"
        data-tour="course-sidebar"
      >
        {isLoading && courses.length === 0 && groups.length === 0 ? (
          <div className="loading-list" aria-label="과목 불러오는 중">
            <span />
            <span />
            <span />
          </div>
        ) : courses.length === 0 && groups.length === 0 ? (
          <div className="empty-state empty-state--courses">
            <BandalMark size={56} className="empty-state__moon" />
            <p className="empty-state__text">첫 과목을 만들어보세요</p>
            <button
              type="button"
              className="button button--primary"
              onClick={() => void startFolderAdd()}
            >
              <Icon name="folderPlus" />
              폴더에서 추가
            </button>
            <button
              type="button"
              className="empty-state__alt"
              onClick={() => setCreateDialogOpen(true)}
            >
              새 과목 만들기
            </button>
          </div>
        ) : isSearching && visibleCourses.length === 0 ? (
          <div className="rail-zero-result">
            <p>일치하는 과목이 없어요</p>
            <button type="button" onClick={() => setQuery('')}>
              검색 지우기
            </button>
          </div>
        ) : isSearching ? (
          <ul className="course-list">
            {visibleCourses.map((course) => renderCourse(course, false))}
          </ul>
        ) : (
          <ul className="course-list">
            <li
              className="course-ungrouped-drop-zone course-ungrouped-drop-zone--top"
              data-drag-active={draggingCourseId !== null || undefined}
              data-drop-ungrouped={
                (dropTarget?.kind === 'ungrouped' &&
                  dropTarget.position === 'top') ||
                undefined
              }
              aria-hidden="true"
              onDragOver={(event) => handleUngroupedDragOver(event, 'top')}
              onDragLeave={() => {
                setDropTarget((target) =>
                  target?.kind === 'ungrouped' && target.position === 'top'
                    ? null
                    : target
                )
              }}
              onDrop={handleUngroupedDrop}
            />
            {organizedCourses.ungroupedCourses.map((course) =>
              renderCourse(course, true)
            )}
            {organizedCourses.sortedGroups.map((group) => {
              const groupCourses =
                organizedCourses.coursesByGroup.get(group.id) ?? []
              return (
                <CourseGroupRow
                  key={group.id}
                  group={group}
                  courseCount={groupCourses.length}
                  collapsed={collapsedGroupIds.has(group.id)}
                  menuOpen={groupContextMenu?.group.id === group.id}
                  dropInto={
                    dropTarget?.kind === 'group' &&
                    dropTarget.groupId === group.id
                  }
                  onToggle={() =>
                    setGroupCollapsed(
                      group.id,
                      !collapsedGroupIds.has(group.id)
                    )
                  }
                  onOpenMenu={(event) => openGroupMenu(event, group)}
                  onHeaderDragOver={(event) =>
                    handleGroupDragOver(event, group.id)
                  }
                  onHeaderDragLeave={(event) => {
                    if (
                      event.relatedTarget instanceof Node &&
                      event.currentTarget.contains(event.relatedTarget)
                    ) {
                      return
                    }
                    setDropTarget((target) =>
                      target?.kind === 'group' && target.groupId === group.id
                        ? null
                        : target
                    )
                  }}
                  onHeaderDrop={(event) => handleGroupDrop(event, group.id)}
                >
                  {groupCourses.map((course) => renderCourse(course, true))}
                </CourseGroupRow>
              )
            })}
            <li
              className="course-ungrouped-drop-zone course-ungrouped-drop-zone--bottom"
              data-drag-active={draggingCourseId !== null || undefined}
              data-drop-ungrouped={
                (dropTarget?.kind === 'ungrouped' &&
                  dropTarget.position === 'bottom') ||
                undefined
              }
              aria-hidden="true"
              onDragOver={(event) => handleUngroupedDragOver(event, 'bottom')}
              onDragLeave={() => {
                setDropTarget((target) =>
                  target?.kind === 'ungrouped' && target.position === 'bottom'
                    ? null
                    : target
                )
              }}
              onDrop={handleUngroupedDrop}
            />
          </ul>
        )}
      </div>

      {addMenu !== null && (
        <div
          ref={addMenuRef}
          className="context-menu"
          role="menu"
          aria-label="과목 추가"
          data-placement="bottom"
          data-align="end"
          style={{ left: addMenu.x, top: addMenu.y }}
        >
          <button
            type="button"
            role="menuitem"
            onClick={() => void startFolderAdd()}
          >
            <Icon name="folderPlus" />
            폴더에서 추가
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setAddMenu(null)
              setCreateDialogOpen(true)
            }}
          >
            <Icon name="plus" />새 과목 만들기
          </button>
          <span className="context-menu__separator" />
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              clearError()
              setAddMenu(null)
              setCreateGroupDialogOpen(true)
            }}
          >
            <Icon name="plus" />새 그룹 만들기
          </button>
        </div>
      )}

      {contextMenu !== null && (
        <div
          ref={contextMenuRef}
          className="context-menu context-menu--course"
          role="menu"
          aria-label={`${contextMenu.course.name} 과목 메뉴`}
          data-placement={contextMenu.placement}
          data-align={contextMenu.alignEnd ? 'end' : undefined}
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <p className="context-menu__label">{contextMenu.course.name}</p>
          <div
            className="context-menu__color-group"
            role="group"
            aria-label="과목 색상"
          >
            <span className="context-menu__color-label">색상</span>
            <div className="context-menu__color-palette">
              {COURSE_COLORS.map((color) => {
                const selected =
                  normalizeCourseColor(contextMenu.course.color) === color
                return (
                  <button
                    key={color}
                    type="button"
                    className="context-menu__color-swatch"
                    role="menuitemradio"
                    data-course-color={color}
                    data-selected={selected || undefined}
                    aria-label={courseColorLabel(color)}
                    aria-checked={selected}
                    disabled={contextMenu.course.id === pendingCourseId}
                    onClick={() => void changeCourseColor(color)}
                  >
                    <span />
                  </button>
                )
              })}
            </div>
          </div>
          <span className="context-menu__separator" />
          <button
            type="button"
            role="menuitem"
            disabled={contextMenu.course.missing}
            onClick={() => {
              openStudyMarketSell({ courseId: contextMenu.course.id })
              setContextMenu(null)
            }}
          >
            <Icon name="fileText" />
            자료 판매하기
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setRenameTarget(contextMenu.course)
              setContextMenu(null)
            }}
          >
            <Icon name="pencil" />
            이름 변경
          </button>
          {contextMenu.course.missing && (
            <button
              type="button"
              role="menuitem"
              onClick={() => void startRelink(contextMenu.course)}
            >
              <Icon name="link" />
              다시 연결
            </button>
          )}
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              clearError()
              setArchiveTarget(contextMenu.course)
              setContextMenu(null)
            }}
          >
            <Icon name="archive" />
            보관
          </button>
          <span className="context-menu__separator" />
          <button
            type="button"
            role="menuitem"
            className="context-menu__danger"
            onClick={() => {
              clearError()
              setDeleteTarget(contextMenu.course)
              setContextMenu(null)
            }}
          >
            <Icon name="trash" />
            삭제
          </button>
        </div>
      )}

      {groupContextMenu !== null && (
        <div
          ref={groupContextMenuRef}
          className="context-menu"
          role="menu"
          aria-label={`${groupContextMenu.group.name} 그룹 메뉴`}
          data-placement={groupContextMenu.placement}
          data-align={groupContextMenu.alignEnd ? 'end' : undefined}
          style={{ left: groupContextMenu.x, top: groupContextMenu.y }}
        >
          <p className="context-menu__label">{groupContextMenu.group.name}</p>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              clearError()
              setRenameGroupTarget(groupContextMenu.group)
              setGroupContextMenu(null)
            }}
          >
            <Icon name="pencil" />
            이름 변경
          </button>
          <span className="context-menu__separator" />
          <button
            type="button"
            role="menuitem"
            className="context-menu__danger"
            onClick={() => {
              clearError()
              setDeleteGroupTarget(groupContextMenu.group)
              setGroupContextMenu(null)
            }}
          >
            <Icon name="trash" />
            그룹 삭제
          </button>
        </div>
      )}

      <CourseFormDialog
        open={createDialogOpen}
        mode="create"
        onClose={() => setCreateDialogOpen(false)}
        onSubmit={async (name, color) => {
          await createCourse({ name, color })
        }}
      />
      <CourseFormDialog
        open={linkTarget !== null}
        mode="link"
        initialName={linkTarget?.name ?? ''}
        folderPath={linkTarget?.path}
        onClose={() => setLinkTarget(null)}
        onSubmit={async (name, color) => {
          if (linkTarget === null) return
          const result = await addCourseFromFolder({
            folderPath: linkTarget.path,
            name,
            color
          })
          // Thrown messages stay inside the dialog so the user can re-pick.
          if (result.status === 'failed') {
            throw new Error(folderProblemMessage(result.reason))
          }
          if (result.status === 'duplicate') {
            showToast('이미 등록된 폴더예요. 그 과목으로 이동했어요.')
          }
        }}
      />
      <CourseFormDialog
        open={renameTarget !== null}
        mode="rename"
        initialName={renameTarget?.name ?? ''}
        initialColor={normalizeCourseColor(renameTarget?.color ?? 'gold')}
        onClose={() => setRenameTarget(null)}
        onSubmit={async (name) => {
          if (renameTarget !== null) await renameCourse(renameTarget.id, name)
        }}
      />
      <ArchiveCourseDialog
        courseName={archiveTarget?.name ?? null}
        pending={archiveTarget?.id === pendingCourseId}
        error={archiveTarget === null ? null : error}
        onClose={() => setArchiveTarget(null)}
        onConfirm={handleArchive}
      />
      <DeleteCourseDialog
        courseName={deleteTarget?.name ?? null}
        pending={deleteTarget?.id === pendingCourseId}
        error={deleteTarget === null ? null : error}
        onClose={() => setDeleteTarget(null)}
        onConfirm={handleDelete}
      />
      <CourseGroupNameDialog
        open={createGroupDialogOpen}
        mode="create"
        onClose={() => setCreateGroupDialogOpen(false)}
        onSubmit={async (name) => {
          await createGroup(name)
        }}
      />
      <CourseGroupNameDialog
        open={renameGroupTarget !== null}
        mode="rename"
        initialName={renameGroupTarget?.name ?? ''}
        onClose={() => setRenameGroupTarget(null)}
        onSubmit={async (name) => {
          if (renameGroupTarget !== null) {
            await renameGroup(renameGroupTarget.id, name)
          }
        }}
      />
      <DeleteCourseGroupDialog
        groupName={deleteGroupTarget?.name ?? null}
        onClose={() => setDeleteGroupTarget(null)}
        onConfirm={handleDeleteGroup}
      />
    </aside>
  )
}
