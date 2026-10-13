import { useLayoutEffect, useState } from 'react'
import type { AnchorRect } from '../workspace/panels/browserAnchor'
import { setNativeHostBlocked } from './nativeHostVisibility'

const SURFACES = '[role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], [role="tooltip"], dialog[open]'
export function overlapsNativePage(rect: AnchorRect | null, surfaces: readonly AnchorRect[]): boolean {
  return rect !== null && surfaces.some(surface =>
    surface.x < rect.x + rect.width && surface.x + surface.width > rect.x &&
    surface.y < rect.y + rect.height && surface.y + surface.height > rect.y)
}
/** Only DOM surfaces that overlap a native page replace it with a still preview. */
export function useNativePageOcclusion(): readonly AnchorRect[] {
  const [rects, setRects] = useState<readonly AnchorRect[]>([])
  useLayoutEffect(() => {
    let frame = 0
    const schedule = (): void => { if (!frame) frame = requestAnimationFrame(update) }
    const resize = new ResizeObserver(schedule)
    const update = (): void => {
      frame = 0
      resize.disconnect()
      const next: AnchorRect[] = []
      let modal = false
      for (const surface of document.querySelectorAll(SURFACES)) {
        if (surface.closest('[inert]') || !surface.getClientRects().length || getComputedStyle(surface).visibility === 'hidden') continue
        resize.observe(surface)
        const bounds = surface.getBoundingClientRect()
        if (bounds.width <= 0 || bounds.height <= 0) continue
        modal ||= surface.getAttribute('aria-modal') === 'true'
        next.push(surface.getAttribute('aria-modal') === 'true'
          ? { x: 0, y: 0, width: innerWidth, height: innerHeight }
          : { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height })
      }
      setNativeHostBlocked('modal-surfaces', modal)
      setRects(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next)
      for (const element of moving) if (!element.isConnected || !element.getAnimations().some(animation => animation.playState === 'running')) moving.delete(element)
      if (moving.size) schedule()
    }
    const relevant = (node: Node): boolean => node instanceof Element &&
      (node.matches(SURFACES) || node.closest(SURFACES) !== null || node.querySelector(SURFACES) !== null)
    const moving = new Set<Element>()
    const start = (event: TransitionEvent): void => {
      if (event.target instanceof Element && relevant(event.target)) { moving.add(event.target); schedule() }
    }
    const end = (event: TransitionEvent): void => {
      if (event.target instanceof Element) moving.delete(event.target)
      schedule()
    }
    const observer = new MutationObserver(records => {
      if (records.some(record => record.type === 'attributes'
        ? relevant(record.target)
        : [...record.addedNodes, ...record.removedNodes].some(relevant))) schedule()
    })
    observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'inert', 'open', 'role', 'aria-modal', 'aria-hidden', 'class', 'style', 'data-open', 'data-settings', 'data-left-rail', 'data-course-rail', 'data-right-rail'] })
    window.addEventListener('resize', schedule)
    window.addEventListener('scroll', schedule, true)
    document.addEventListener('transitionrun', start)
    document.addEventListener('transitionend', end)
    document.addEventListener('transitioncancel', end)
    update()
    return () => {
      observer.disconnect(); resize.disconnect(); cancelAnimationFrame(frame)
      window.removeEventListener('resize', schedule); window.removeEventListener('scroll', schedule, true)
      document.removeEventListener('transitionrun', start); document.removeEventListener('transitionend', end); document.removeEventListener('transitioncancel', end)
      setNativeHostBlocked('modal-surfaces', false)
    }
  }, [])
  return rects
}
