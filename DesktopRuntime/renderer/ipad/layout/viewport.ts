import { useLayoutEffect, type RefObject } from 'react'

/** Visual viewport coordinates keep an anchored popover above the keyboard,
 * including WKWebView's focus pan and split-window resizing. */
export function useViewportBounds(ref: RefObject<HTMLElement>): void {
  useLayoutEffect(() => {
    const node = ref.current
    if (!node) return
    const original = { left: node.style.left, top: node.style.top, right: node.style.right, bottom: node.style.bottom, maxHeight: node.style.maxHeight,
      maxWidth: node.style.maxWidth, overflowY: node.style.overflowY, boxSizing: node.style.boxSizing }
    const place = () => {
      Object.assign(node.style, original)
      const viewport = window.visualViewport
      const left = viewport?.offsetLeft ?? 0, top = viewport?.offsetTop ?? 0
      const width = viewport?.width ?? innerWidth, height = viewport?.height ?? innerHeight
      const style = getComputedStyle(node)
      const limit = (value: string, available: number) => `${Math.max(0, Math.min(parseFloat(value) || Infinity, available))}px`
      node.style.boxSizing = 'border-box'
      node.style.maxHeight = limit(style.maxHeight, height - 16)
      node.style.maxWidth = limit(style.maxWidth, width - 16)
      node.style.overflowY = 'auto'
      const rect = node.getBoundingClientRect()
      const dx = Math.max(left + 8 - rect.left, Math.min(0, left + width - 8 - rect.right))
      const dy = Math.max(top + 8 - rect.top, Math.min(0, top + height - 8 - rect.bottom))
      // WKWebView can union a translated scroll child's old and new accessibility
      // bounds (a 44px command became 624px tall after a 580px correction).
      // Move the layout box instead, retaining the caller's centering/flip
      // transform and restoring its original anchor before every measurement.
      if (dx !== 0) {
        node.style.left = `${(parseFloat(style.left) || node.offsetLeft) + dx}px`
        node.style.right = 'auto'
      }
      if (dy !== 0) {
        node.style.top = `${(parseFloat(style.top) || node.offsetTop) + dy}px`
        node.style.bottom = 'auto'
      }
    }
    place()
    let frame = 0
    const schedule = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(place)
    }
    const observer = new ResizeObserver(schedule)
    observer.observe(node)
    for (const child of node.children) observer.observe(child)
    window.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('scroll', schedule)
    node.addEventListener('animationend', schedule)
    return () => {
      cancelAnimationFrame(frame); observer.disconnect()
      window.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('scroll', schedule)
      node.removeEventListener('animationend', schedule)
      Object.assign(node.style, original)
    }
  })
}
