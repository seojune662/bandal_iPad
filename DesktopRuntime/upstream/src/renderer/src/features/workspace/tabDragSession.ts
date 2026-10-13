export type WorkspaceDragKind = 'tab' | 'group' | 'resize' | null
export interface WorkspaceTabDragSource {
  courseId: string | null
  panelId: string
  nonce: string
}
let kind: WorkspaceDragKind = null
let source: WorkspaceTabDragSource | null = null
let headerPressed = false
let revision = 0
const listeners = new Set<() => void>()
const notify = (): void => { for (const listener of listeners) listener() }

export const tabDragSession = {
  getSnapshot: (): WorkspaceDragKind => kind,
  getSource: (): WorkspaceTabDragSource | null => source,
  // A press delays automatic native focus without hiding a native page or
  // claiming a drag before Chromium has actually started it.
  isFocusBlocked: (): boolean => headerPressed || kind !== null,
  isHeaderPressed: (): boolean => headerPressed,
  beginTab: (next: WorkspaceTabDragSource): void => {
    revision += 1
    headerPressed = false
    source = next
    kind = 'tab'
    notify()
  },
  subscribe: (listener: () => void): (() => void) => {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  },
  begin: (next: Exclude<WorkspaceDragKind, null>): void => {
    if (kind === next) return
    revision += 1
    headerPressed = false
    if (next !== 'tab') source = null
    kind = next
    notify()
  },
  end: (): void => {
    if (kind === null && source === null && !headerPressed) return
    revision += 1
    headerPressed = false
    kind = null
    source = null
    notify()
  }
}

/** One owner for tab/group DnD and sash resizing; file uploads stay independent. */
export function installWorkspaceDragSession(root: HTMLElement): () => void {
  const start = (event: DragEvent): void => {
    if (event.defaultPrevented || !(event.target instanceof Element)) return
    if (event.target.closest('.dv-tab')) tabDragSession.begin('tab')
    else if (event.target.closest('.dv-tabs-and-actions-container'))
      tabDragSession.begin('group')
  }
  const pointer = (event: PointerEvent): void => {
    if (!(event.target instanceof Element) || (event.button !== undefined && event.button !== 0)) return
    if (event.target.closest('.dv-sash'))
      tabDragSession.begin('resize')
    else if (event.target.closest('.dv-tabs-and-actions-container, .dv-tab')) {
      headerPressed = true
      revision += 1
      notify()
    }
  }
  const end = (): void => tabDragSession.end()
  // Target handlers need the trusted source during the entire drop dispatch.
  // Chromium runs microtasks between native listener callbacks. A microtask
  // here clears the source before later capture/target listeners see `drop`.
  let dropCleanup: ReturnType<typeof setTimeout> | null = null
  const dropped = (): void => {
    const droppedRevision = revision
    if (dropCleanup !== null) clearTimeout(dropCleanup)
    dropCleanup = setTimeout(() => {
      dropCleanup = null
      if (revision === droppedRevision) end()
    }, 0)
  }
  // Starting native HTML DnD cancels the pointer stream. Only a sash owns it.
  const endPointer = (): void => {
    if (kind === 'resize') end()
    else if (headerPressed) {
      headerPressed = false
      notify()
    }
  }
  const key = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') end()
  }
  const reflect = (): void => {
    if (kind === 'tab' || kind === 'group') root.dataset.tabDragging = 'true'
    else delete root.dataset.tabDragging
  }
  const unsubscribe = tabDragSession.subscribe(reflect)
  reflect()
  root.addEventListener('dragstart', start)
  root.addEventListener('pointerdown', pointer, true)
  window.addEventListener('drop', dropped, true)
  for (const name of ['dragend', 'mouseup'] as const)
    window.addEventListener(name, end, true)
  // A course switch blurs its focused tab; that is not losing the app window.
  window.addEventListener('blur', end)
  window.addEventListener('pointerup', endPointer, true)
  window.addEventListener('pointercancel', endPointer, true)
  window.addEventListener('keydown', key, true)
  return () => {
    if (dropCleanup !== null) clearTimeout(dropCleanup)
    end()
    unsubscribe()
    root.removeEventListener('dragstart', start)
    root.removeEventListener('pointerdown', pointer, true)
    window.removeEventListener('drop', dropped, true)
    for (const name of ['dragend', 'mouseup'] as const)
      window.removeEventListener(name, end, true)
    window.removeEventListener('blur', end)
    window.removeEventListener('pointerup', endPointer, true)
    window.removeEventListener('pointercancel', endPointer, true)
    window.removeEventListener('keydown', key, true)
  }
}
