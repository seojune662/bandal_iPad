import type { DragEvent as ReactDragEvent } from 'react'
import { workspaceApiForCourse } from '../../../upstream/src/renderer/src/stores/workspaceStore'
import { useUiStore } from '../../../upstream/src/renderer/src/stores/uiStore'
import { isTabDescriptor } from '../../../upstream/src/renderer/src/features/workspace/tabIdentity'
import { BANDAL_TAB_DRAG_MIME, writeWorkspaceTabDragData } from '../../../upstream/src/renderer/src/features/workspace/tabDrag'
import { tabDragSession, type WorkspaceTabDragSource } from '../../../upstream/src/renderer/src/features/workspace/tabDragSession'
import { acquireNativeInput } from '../nativeSurfaces'
import { activateIpadAuxiliary, ipadPanelState, isIpadRailVisible } from '../layout/coordination'

/** The persistent course icon reveals row destinations without changing the
 * selected course. An open overlay can make the pressed workspace inert; the
 * already owned pointer stream continues at window level until its drop. */
export function revealWorkspaceCourseDropSidebar(event: ReactDragEvent<HTMLElement>): void {
  if (tabDragSession.getSnapshot() !== 'tab' || !tabDragSession.getSource() ||
    !event.dataTransfer.types.includes(BANDAL_TAB_DRAG_MIME)) return
  event.preventDefault(); event.stopPropagation(); event.dataTransfer.dropEffect = 'move'
  const ui = useUiStore.getState()
  if (!ui.leftRailOpen || !ui.courseRailOpen || ui.leftRailPanel !== 'courses' ||
    ui.isSettingsOpen || ui.isBoardOverlayOpen || ui.isLinkGraphOpen) ui.showCourses()
  if (!isIpadRailVisible('left') && ipadPanelState().last !== 'left') activateIpadAuxiliary('left')
}

export const TAB_DRAG_DISTANCE = 8
type Contact = {
  id: number; element: HTMLElement; startX: number; startY: number; x: number; y: number
  source: WorkspaceTabDragSource; transfer: DataTransfer; label: string
  active: boolean; ended: boolean; target: Element | null; preview?: HTMLElement
  release?: () => Promise<void>
}

/** Only tab labels own this immediate gesture. Drop geometry, resource identity,
 * course hydration, cancellation navigation and persistence retain desktop owners. */
export function installWorkspaceTouchDrag(root: HTMLElement): () => void {
  let contact: Contact | null = null, frame = 0
  let suppressClick: { element: HTMLElement; x: number; y: number; until: number } | null = null
  const report = (reason: unknown): void => {
    window.dispatchEvent(new CustomEvent('bandal:operation-error', { detail: { reason, operation: '탭 이동' } }))
  }
  const dispatch = (current: Contact, target: Element, type: string, relatedTarget: Element | null = null): void => {
    target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: current.transfer,
      clientX: current.x, clientY: current.y, relatedTarget }))
  }
  const hit = (current: Contact): Element | null => document.elementFromPoint(current.x, current.y)
  const reflect = (current: Contact): void => {
    if (current.preview) {
      current.preview.style.left = `${Math.min(window.innerWidth - 100, Math.max(8, current.x + 16))}px`
      current.preview.style.top = `${Math.max(8, current.y - 54)}px`
    }
    const target = hit(current)
    if (target !== current.target) {
      if (current.target?.isConnected) dispatch(current, current.target, 'dragleave', target)
      if (target) dispatch(current, target, 'dragenter', current.target)
      current.target = target
    }
    if (target) dispatch(current, target, 'dragover')
  }
  const tick = (): void => {
    frame = 0
    if (!contact?.active || contact.ended) return
    // Re-hit-test while held: selecting a cold course may replace the target
    // under a stationary finger after its workspace finishes hydration.
    reflect(contact)
    frame = requestAnimationFrame(tick)
  }
  const finish = (drop: boolean): void => {
    const current = contact
    if (!current) return
    contact = null
    cancelAnimationFrame(frame); frame = 0
    if (current.active) {
      suppressClick = { element: current.element, x: current.x, y: current.y, until: performance.now() + 500 }
      // Preserve the live session through the complete synchronous drop. The
      // canonical course transfer retains its source during asynchronous work.
      if (drop && current.release) {
        const target = hit(current)
        if (target) dispatch(current, target, 'drop')
      }
      if (current.target?.isConnected) dispatch(current, current.target, 'dragleave')
      current.preview?.remove()
      delete root.dataset.ipadTabDragging
      tabDragSession.end()
    }
    try { if (current.element.hasPointerCapture(current.id)) current.element.releasePointerCapture(current.id) } catch { /* Removed by drop. */ }
    if (current.release) void current.release().catch(report)
  }
  const cancel = (): void => finish(false)
  const down = (event: PointerEvent): void => {
    if (contact) {
      // WebKit may reuse a touch pointer ID for the next tap while an ended
      // drag still awaits native acknowledgement. Never overwrite its owner.
      const nextGesture = contact.ended && event.isPrimary && event.pointerType === 'touch'
      cancel()
      if (!nextGesture) return
    }
    if (event.pointerType !== 'touch' || !event.isPrimary || event.button !== 0 || !(event.target instanceof Element)) return
    const element = event.target.closest<HTMLElement>('.dv-tab[data-ipad-panel-id]')
    if (!element || !root.contains(element) || element.closest('[hidden], [inert]') ||
      event.target.closest('button, input, textarea, select, a, [contenteditable="true"]')) return
    const course = element.closest<HTMLElement>('[data-workspace-course]')
    if (!course) return
    const courseId = course.dataset.workspaceCourse || null
    const panel = workspaceApiForCourse(courseId)?.getPanel(element.dataset.ipadPanelId!)
    if (!panel || !isTabDescriptor(panel.params?.descriptor)) return
    const source = { courseId, panelId: panel.id, nonce: crypto.randomUUID() }
    const transfer = new DataTransfer()
    writeWorkspaceTabDragData(transfer, panel.params.descriptor, panel.title ?? '', source)
    contact = { id: event.pointerId, element, source, transfer, label: panel.title ?? '', startX: event.clientX,
      startY: event.clientY, x: event.clientX, y: event.clientY, active: false, ended: false, target: null }
  }
  const move = (event: PointerEvent): void => {
    const current = contact
    if (!current || event.pointerId !== current.id || current.ended) return
    current.x = event.clientX; current.y = event.clientY
    if (!current.active) {
      if (Math.hypot(current.x - current.startX, current.y - current.startY) < TAB_DRAG_DISTANCE) return
      if (!current.element.isConnected) { cancel(); return }
      current.active = true
      tabDragSession.beginTab(current.source)
      root.dataset.ipadTabDragging = 'true'
      const preview = document.createElement('div')
      preview.className = 'ipad-tab-drag-preview'
      preview.setAttribute('aria-hidden', 'true')
      preview.dataset.bandalNativeOverlay = 'true'
      preview.textContent = current.label
      document.body.append(preview); current.preview = preview
      try { current.element.setPointerCapture(current.id) } catch { /* Synthetic test input. */ }
      // The finger may cross a native PDF/browser view. Its input barrier must
      // acknowledge before committing a drop, even if the finger already lifted.
      void acquireNativeInput('workspace-touch-tab').then(release => {
        if (contact !== current) { void release().catch(report); return }
        current.release = release
        if (current.ended) finish(true)
      }).catch(error => { if (contact === current) cancel(); report(error) })
      frame = requestAnimationFrame(tick)
    }
    event.preventDefault(); event.stopPropagation()
    reflect(current)
  }
  const up = (event: PointerEvent): void => {
    const current = contact
    if (!current || event.pointerId !== current.id) return
    if (!current.active) { finish(false); return }
    event.preventDefault(); event.stopPropagation()
    current.x = event.clientX; current.y = event.clientY; current.ended = true
    suppressClick = { element: current.element, x: current.x, y: current.y, until: performance.now() + 500 }
    if (current.release) finish(true)
  }
  const cancelled = (event: PointerEvent): void => { if (contact?.id === event.pointerId) cancel() }
  const key = (event: KeyboardEvent): void => { if (event.key === 'Escape') cancel() }
  const hidden = (): void => { if (document.visibilityState === 'hidden') cancel() }
  const nativeDrag = (event: DragEvent): void => { if (contact) event.preventDefault() }
  const context = (event: MouseEvent): void => { if (contact?.active) { event.preventDefault(); event.stopPropagation() } }
  const click = (event: MouseEvent): void => {
    if (!suppressClick || performance.now() > suppressClick.until) return
    if ((event.target instanceof Node && suppressClick.element.contains(event.target)) ||
      Math.hypot(event.clientX - suppressClick.x, event.clientY - suppressClick.y) < 24) {
      event.preventDefault(); event.stopPropagation(); suppressClick = null
    }
  }
  const stopSession = tabDragSession.subscribe(() => {
    if (contact?.active && tabDragSession.getSource()?.nonce !== contact.source.nonce) cancel()
  })
  window.addEventListener('pointerdown', down, true)
  window.addEventListener('pointermove', move, { capture: true, passive: false })
  window.addEventListener('pointerup', up, true)
  window.addEventListener('pointercancel', cancelled, true)
  window.addEventListener('keydown', key, true)
  window.addEventListener('blur', cancel)
  window.addEventListener('resize', cancel)
  window.addEventListener('click', click, true)
  root.addEventListener('dragstart', nativeDrag, true)
  root.addEventListener('contextmenu', context, true)
  document.addEventListener('visibilitychange', hidden)
  return () => {
    cancel(); stopSession()
    window.removeEventListener('pointerdown', down, true)
    window.removeEventListener('pointermove', move, true)
    window.removeEventListener('pointerup', up, true)
    window.removeEventListener('pointercancel', cancelled, true)
    window.removeEventListener('keydown', key, true)
    window.removeEventListener('blur', cancel)
    window.removeEventListener('resize', cancel)
    window.removeEventListener('click', click, true)
    root.removeEventListener('dragstart', nativeDrag, true)
    root.removeEventListener('contextmenu', context, true)
    document.removeEventListener('visibilitychange', hidden)
  }
}
