import { BANDAL_TAB_DRAG_MIME } from './tabDrag'
import { tabDragSession } from './tabDragSession'

/** Native tab DnD needs edge scrolling when the destination tab is offscreen. */
export function installTabDragScrolling(root: HTMLElement): () => void {
  let frame: number | null = null
  let tabs: HTMLElement | null = null
  let velocity = 0
  let previous = 0
  const stop = (): void => {
    if (frame !== null) cancelAnimationFrame(frame)
    frame = null
    tabs = null
    velocity = 0
    previous = 0
  }
  const tick = (time: number): void => {
    frame = null
    if (!tabs?.isConnected || velocity === 0) return
    const elapsed = previous ? Math.min(32, time - previous) : 16
    previous = time
    const before = tabs.scrollLeft
    tabs.scrollLeft += (velocity * elapsed) / 1000
    if (tabs.scrollLeft !== before) frame = requestAnimationFrame(tick)
  }
  const over = (event: DragEvent): void => {
    if (
      !event.dataTransfer?.types.includes(BANDAL_TAB_DRAG_MIME) ||
      !(event.target instanceof Element)
    )
      return
    const next = event.target.closest<HTMLElement>(
      '.dv-tabs-container.dv-horizontal'
    )
    if (!next || !root.contains(next)) {
      stop()
      return
    }
    const rect = next.getBoundingClientRect()
    const zone = Math.min(40, rect.width / 4)
    velocity =
      event.clientX < rect.left + zone
        ? -500 * (1 - (event.clientX - rect.left) / zone)
        : event.clientX > rect.right - zone
          ? 500 * (1 - (rect.right - event.clientX) / zone)
          : 0
    if (!velocity) {
      stop()
      return
    }
    tabs = next
    if (frame === null) {
      previous = 0
      frame = requestAnimationFrame(tick)
    }
  }
  const leave = (event: DragEvent): void => {
    if (
      !(event.relatedTarget instanceof Node) ||
      !tabs?.contains(event.relatedTarget)
    )
      stop()
  }
  const unsubscribe = tabDragSession.subscribe(() => {
    if (tabDragSession.getSnapshot() === null) stop()
  })
  root.addEventListener('dragover', over)
  root.addEventListener('dragleave', leave)
  return () => {
    stop()
    unsubscribe()
    root.removeEventListener('dragover', over)
    root.removeEventListener('dragleave', leave)
  }
}
