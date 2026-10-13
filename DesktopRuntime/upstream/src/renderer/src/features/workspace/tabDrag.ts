import type { TabDescriptor } from '../../../../shared/tabs'
import type { WorkspaceTabDragSource } from './tabDragSession'

export const BANDAL_TAB_DRAG_MIME = 'application/x-bandal-tab'

/** A drag preview is a label, not a copy of the tab's interactive controls. */
export function setWorkspaceTabDragImage(
  dataTransfer: DataTransfer,
  source: HTMLElement,
  title: string
): void {
  const preview = document.createElement('div')
  preview.className = 'workspace-tab-drag-preview'
  preview.setAttribute('aria-hidden', 'true')
  const icon = source.querySelector('.workspace-tab__kind')?.cloneNode(true)
  if (icon) preview.append(icon)
  const label = document.createElement('span')
  label.textContent = title
  preview.append(label)
  document.body.append(preview)
  dataTransfer.setDragImage(preview, 24, 18)
  setTimeout(() => preview.remove(), 0)
}

/** Adds Bandal's cross-feature payload without clearing dockview's DnD data. */
export function writeWorkspaceTabDragData(
  dataTransfer: DataTransfer,
  descriptor: TabDescriptor,
  label: string,
  source?: WorkspaceTabDragSource
): void {
  // Dockview initializes every tab drag as move-only. Favorites intentionally
  // copy the descriptor while the original workspace tab stays open, so a
  // copy-only drop target is incompatible with dockview's default and
  // Chromium refuses to emit `drop`. Keep move enabled for dockview's own tab
  // rearranging, and additionally allow the cross-feature copy operation.
  dataTransfer.effectAllowed = 'copyMove'
  dataTransfer.setData(
    BANDAL_TAB_DRAG_MIME,
    JSON.stringify({ descriptor, label, ...(source ? { source } : {}) })
  )
  dataTransfer.setData('text/plain', label)
}

/** Only a live tab header in this renderer can authorize moving a panel. */
export function matchesWorkspaceMoveData(dataTransfer: DataTransfer, source: WorkspaceTabDragSource): boolean {
  try {
    const payload = JSON.parse(dataTransfer.getData(BANDAL_TAB_DRAG_MIME))
    return payload?.source?.nonce === source.nonce &&
      payload.source.courseId === source.courseId && payload.source.panelId === source.panelId
  } catch { return false }
}
