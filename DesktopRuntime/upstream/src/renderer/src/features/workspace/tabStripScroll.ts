const WHEEL_LINE_PX = 16
const DOM_DELTA_LINE = 1
const DOM_DELTA_PAGE = 2

interface HorizontalScroller {
  clientWidth: number
  scrollLeft: number
  scrollWidth: number
}

interface VerticalWheelInput {
  deltaMode: number
  deltaX: number
  deltaY: number
  preventDefault: () => void
}

function wheelDeltaPx(event: VerticalWheelInput, pageWidth: number): number {
  if (event.deltaMode === DOM_DELTA_LINE) {
    return event.deltaY * WHEEL_LINE_PX
  }
  if (event.deltaMode === DOM_DELTA_PAGE) {
    return event.deltaY * pageWidth
  }
  return event.deltaY
}

/**
 * Converts mouse-wheel-only vertical input to horizontal movement. Trackpad
 * gestures with a horizontal component stay on the browser's native path.
 */
export function applyVerticalWheelToTabStrip(
  tabs: HorizontalScroller,
  event: VerticalWheelInput
): boolean {
  if (event.deltaX !== 0 || event.deltaY === 0) return false

  const maxScrollLeft = tabs.scrollWidth - tabs.clientWidth
  if (maxScrollLeft <= 0) return false

  const nextScrollLeft = Math.min(
    maxScrollLeft,
    Math.max(0, tabs.scrollLeft + wheelDeltaPx(event, tabs.clientWidth))
  )
  event.preventDefault()
  tabs.scrollLeft = nextScrollLeft
  return true
}

/** Delegates from the stable workspace root because dockview replaces groups. */
export function installTabStripWheelScrolling(root: HTMLElement): () => void {
  const handleWheel = (event: WheelEvent): void => {
    if (!(event.target instanceof Element)) return
    const tabs = event.target.closest<HTMLElement>(
      '.dv-tabs-container.dv-horizontal'
    )
    if (tabs === null || !root.contains(tabs)) return
    applyVerticalWheelToTabStrip(tabs, event)
  }

  root.addEventListener('wheel', handleWheel, { passive: false })
  return () => root.removeEventListener('wheel', handleWheel)
}
