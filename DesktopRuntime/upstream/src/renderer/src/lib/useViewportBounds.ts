import { useLayoutEffect, type RefObject } from 'react'

/** Keep anchored overlays reachable after content changes, zoom and window resizing.
 * Anchors and existing flip transforms stay intact; translate only corrects overflow.
 */
export function useViewportBounds(ref: RefObject<HTMLElement>): void {
  useLayoutEffect(() => {
    const node = ref.current
    if (!node) return
    const original = {
      translate: node.style.translate,
      maxHeight: node.style.maxHeight,
      maxWidth: node.style.maxWidth,
      overflowY: node.style.overflowY,
      boxSizing: node.style.boxSizing
    }
    const place = () => {
      Object.assign(node.style, original)
      const style = getComputedStyle(node)
      const limit = (value: string, available: number) => `${Math.max(0, Math.min(parseFloat(value) || Infinity, available))}px`
      node.style.boxSizing = 'border-box'
      node.style.maxHeight = limit(style.maxHeight, window.innerHeight - 16)
      node.style.maxWidth = limit(style.maxWidth, window.innerWidth - 16)
      node.style.overflowY = 'auto'
      const rect = node.getBoundingClientRect()
      const dx = Math.max(8 - rect.left, Math.min(0, window.innerWidth - 8 - rect.right))
      const dy = Math.max(8 - rect.top, Math.min(0, window.innerHeight - 8 - rect.bottom))
      node.style.translate = `${dx}px ${dy}px`
    }
    place()
    let frame = 0
    const schedule = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(place)
    }
    const observer = new ResizeObserver(schedule)
    observer.observe(node)
    // The outer surface can stay capped while content grows inside it.
    for (const child of node.children) observer.observe(child)
    window.addEventListener('resize', schedule)
    node.addEventListener('animationend', schedule)
    return () => {
      cancelAnimationFrame(frame)
      observer.disconnect()
      window.removeEventListener('resize', schedule)
      node.removeEventListener('animationend', schedule)
      Object.assign(node.style, original)
    }
  })
}
