import { useEffect, useRef, useState } from 'react'
import type { DockviewApi } from 'dockview'
import { useWorkspaceStore, workspaceApiForCourse, type WorkspacePanelMovePosition } from '../../stores/workspaceStore'
import { BANDAL_TAB_DRAG_MIME, matchesWorkspaceMoveData } from './tabDrag'
import { tabDragSession } from './tabDragSession'
import { beginWorkspaceCourseMoveDrop, finishWorkspaceCourseMoveDrop } from './courseTabMoveNavigation'
import { showToast } from '../../app/toast'
import { dropWorkspaceTabOnCourse } from './workspaceTabDrop'
import { moveWorkspacePanel as movePanelWithinWorkspace } from './workspaceLayout'

export interface MoveTarget {
  position: WorkspacePanelMovePosition | undefined
  x: number; y: number; width: number; height: number
  label: string
}

/** Geometry uses public groups and DOM slots, never Dockview's private DnD data. */
export function courseMoveTarget(api: DockviewApi, root: HTMLElement, x: number, y: number): MoveTarget | null {
  const bounds = root.getBoundingClientRect()
  if (!Number.isFinite(x) || !Number.isFinite(y) || bounds.width <= 0 || bounds.height <= 0) return null
  if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) return null
  const relative = (rect: { left: number; top: number; width: number; height: number }, position: MoveTarget['position'], label: string): MoveTarget => ({
    x: rect.left - bounds.left, y: rect.top - bounds.top, width: rect.width, height: rect.height, position, label
  })
  if (api.groups.length === 0) return relative(bounds, undefined, '여기에 탭 놓기')
  for (const group of api.groups) {
    if (!root.contains(group.element)) continue
    const rect = group.element.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) continue
    if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue
    const header = group.element.querySelector<HTMLElement>(':scope > .dv-tabs-and-actions-container')
    const headerRect = header?.getBoundingClientRect()
    if (header && headerRect && headerRect.width > 0 && headerRect.height > 0 && x >= headerRect.left && x <= headerRect.right && y >= headerRect.top && y <= headerRect.bottom) {
      const tabs = [...header.querySelectorAll<HTMLElement>('.dv-tabs-container .dv-tab')]
        .map((tab, index) => ({ box: tab.getBoundingClientRect(), index }))
        .filter(({ box }) => box.width > 0 && box.height > 0)
      const next = tabs.find(({ box }) => x < box.left + box.width / 2)
      const last = tabs.at(-1)
      const index = next?.index ?? (last ? last.index + 1 : group.panels.length)
      const edge = Math.max(headerRect.left + 2, Math.min(headerRect.right - 2,
        next?.box.left ?? last?.box.right ?? headerRect.left))
      return relative({ left: edge - 2, top: headerRect.top, width: 4, height: headerRect.height }, { groupId: group.id, direction: 'within', index }, '')
    }
    const content = group.element.querySelector<HTMLElement>(':scope > .dv-content-container')?.getBoundingClientRect()
    if (!content || content.width <= 0 || content.height <= 0 || x < content.left || x > content.right || y < content.top || y > content.bottom) continue
    const distance = [x - content.left, content.right - x, y - content.top, content.bottom - y]
    const nearest = distance.indexOf(Math.min(...distance))
    const directions = ['left', 'right', 'above', 'below'] as const
    if (distance[nearest]! >= 0 && distance[nearest]! <= 36) {
      const direction = directions[nearest]!
      const split = { left: content.left, top: content.top, width: content.width, height: content.height }
      if (nearest < 2) { split.width /= 2; if (nearest === 1) split.left += split.width }
      else { split.height /= 2; if (nearest === 3) split.top += split.height }
      return relative(split, { groupId: group.id, direction }, '여기에 나누어 놓기')
    }
    return relative(content, { groupId: group.id, direction: 'within' }, '이 그룹으로 이동')
  }
  return null
}

export function CourseTabMoveOverlay(): JSX.Element {
  const overlayRef = useRef<HTMLDivElement>(null)
  const [preview, setPreview] = useState<MoveTarget | null>(null)
  useEffect(() => {
    const root = overlayRef.current?.closest<HTMLElement>('.workspace-host')
    if (!root) return
    let inside = false
    let point: { x: number; y: number; target: Node | null } | null = null
    let previewFrame: number | null = null
    let lastCourse = useWorkspaceStore.getState().activeCourseId
    let lastHydration = useWorkspaceStore.getState().hydration
    let lastSurface = useWorkspaceStore.getState().surface
    const reflectGuides = (): void => {
      const source = tabDragSession.getSource(), state = useWorkspaceStore.getState()
      const heldTab = !!source && tabDragSession.getSnapshot() === 'tab'
      if (heldTab && state.activeCourseId !== source.courseId) root.dataset.courseTabMoving = 'true'
      else delete root.dataset.courseTabMoving
      if (heldTab && !inside) root.dataset.tabDragOutside = 'true'
      else delete root.dataset.tabDragOutside
    }
    const targetAtPoint = (x: number, y: number): { courseId: string | null; target: MoveTarget } | null => {
      const source = tabDragSession.getSource(), state = useWorkspaceStore.getState()
      if (!source || tabDragSession.getSnapshot() !== 'tab' ||
        state.surface !== 'course' || state.hydration !== 'ready' || (state.activeCourseId === null && source.courseId !== null)) return null
      const api = workspaceApiForCourse(state.activeCourseId)
      const target = api ? courseMoveTarget(api, root, x, y) : null
      return target ? { courseId: state.activeCourseId, target } : null
    }
    const withinRoot = (x: number, y: number, target: Node | null): boolean => {
      const bounds = root.getBoundingClientRect()
      return !!target && root.contains(target) && x >= bounds.left && x <= bounds.right && y >= bounds.top && y <= bounds.bottom
    }
    const showPreview = (destination: ReturnType<typeof targetAtPoint>): void => {
      setPreview(current => JSON.stringify(current) === JSON.stringify(destination?.target ?? null) ? current : destination?.target ?? null)
    }
    const refreshPreview = (): void => {
      if (!point || !inside) return
      const hit = document.elementFromPoint?.(point.x, point.y) ?? point.target
      inside = withinRoot(point.x, point.y, hit)
      reflectGuides()
      showPreview(inside ? targetAtPoint(point.x, point.y) : null)
    }
    const schedulePreview = (): void => {
      if (!point || !inside) return
      if (previewFrame !== null) cancelAnimationFrame(previewFrame)
      previewFrame = requestAnimationFrame(() => { previewFrame = null; refreshPreview() })
    }
    const over = (event: DragEvent): void => {
      point = { x: event.clientX, y: event.clientY, target: event.target instanceof Node ? event.target : null }
      inside = withinRoot(point.x, point.y, point.target)
      reflectGuides()
      if (!inside || !event.dataTransfer?.types.includes(BANDAL_TAB_DRAG_MIME)) { setPreview(null); return }
      const destination = targetAtPoint(point.x, point.y)
      showPreview(destination)
      // Course hydration and Dockview layout can finish after this native
      // event. Re-evaluate the held position without requiring another wiggle.
      schedulePreview()
      if (!destination) return
      event.preventDefault()
      event.stopPropagation()
      event.dataTransfer.dropEffect = 'move'
    }
    const drop = (event: DragEvent): void => {
      setPreview(null)
      const source = tabDragSession.getSource()
      const hit = document.elementFromPoint?.(event.clientX, event.clientY) ?? (event.target instanceof Node ? event.target : null)
      const destination = withinRoot(event.clientX, event.clientY, hit) ? targetAtPoint(event.clientX, event.clientY) : null
      if (event.type !== 'drop' || !source || !destination || !event.dataTransfer || !matchesWorkspaceMoveData(event.dataTransfer, source)) return
      event.preventDefault()
      event.stopPropagation()
      const { courseId: targetCourseId, target } = destination
      if (targetCourseId !== source.courseId) {
        if (targetCourseId !== null) void dropWorkspaceTabOnCourse(source, targetCourseId, target.position)
        return
      }
      if (!beginWorkspaceCourseMoveDrop(source.nonce)) return
      let accepted = false
      try {
        const api = workspaceApiForCourse(targetCourseId), panel = api?.getPanel(source.panelId)
        if (api && panel && target.position?.groupId) {
          const withinOwnContent = target.position.direction === 'within' && target.position.index === undefined && panel.group.id === target.position.groupId
          accepted = withinOwnContent || movePanelWithinWorkspace(api, source.panelId, { ...target.position, groupId: target.position.groupId })
          if (accepted) useWorkspaceStore.getState().notifyLayoutChanged()
        }
      } catch (error) {
        console.error('[Bandal] 창 이동을 마무리하지 못했습니다.', error)
        showToast('탭을 옮기지 못했어요. 다시 시도해 주세요.', 'danger')
      } finally { finishWorkspaceCourseMoveDrop(source.nonce, accepted) }
    }
    const leave = (event: DragEvent): void => {
      // Child targets can emit dragleave with no relatedTarget while the
      // pointer is still over the canvas. Only a real region exit clears it.
      const next = event.relatedTarget instanceof Node ? event.relatedTarget : document.elementFromPoint?.(event.clientX, event.clientY)
      if (!next || !root.contains(next)) { inside = false; reflectGuides(); setPreview(null) }
    }
    const unsubscribe = tabDragSession.subscribe(() => { inside = false; point = null; reflectGuides(); setPreview(null) })
    const stopCourse = useWorkspaceStore.subscribe(state => {
      if (state.activeCourseId !== lastCourse || state.hydration !== lastHydration || state.surface !== lastSurface) {
        lastCourse = state.activeCourseId; lastHydration = state.hydration; lastSurface = state.surface
        setPreview(null)
        schedulePreview()
      }
      reflectGuides()
    })
    reflectGuides()
    window.addEventListener('dragenter', over, true)
    window.addEventListener('dragover', over, true)
    root.addEventListener('drop', drop, true)
    root.addEventListener('dragleave', leave)
    return () => {
      if (previewFrame !== null) cancelAnimationFrame(previewFrame)
      unsubscribe(); stopCourse(); window.removeEventListener('dragenter', over, true); window.removeEventListener('dragover', over, true); root.removeEventListener('drop', drop, true); root.removeEventListener('dragleave', leave)
      delete root.dataset.courseTabMoving; delete root.dataset.tabDragOutside
    }
  }, [])
  return <div className="course-tab-move-overlay" ref={overlayRef} aria-hidden="true">
    {preview && <div className="course-tab-move-preview" data-tab-insertion={preview.position?.index !== undefined || undefined} style={{ left: preview.x, top: preview.y, width: preview.width, height: preview.height }}>{preview.label && <span>{preview.label}</span>}</div>}
  </div>
}
