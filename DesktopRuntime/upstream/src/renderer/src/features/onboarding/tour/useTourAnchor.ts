import { useEffect, useRef, useState } from 'react'
import type { TourAnchorKey, TourAnchorRect } from './tourTypes'

const POLL_INTERVAL_MS = 150
const RAF_MEASURE_INTERVAL_MS = 100

function rectOf(element: HTMLElement): TourAnchorRect {
  const rect = element.getBoundingClientRect()
  return {
    top: rect.top,
    right: rect.right,
    bottom: rect.bottom,
    left: rect.left,
    width: rect.width,
    height: rect.height
  }
}

function sameRect(
  current: TourAnchorRect | null,
  next: TourAnchorRect
): boolean {
  return (
    current !== null &&
    current.top === next.top &&
    current.right === next.right &&
    current.bottom === next.bottom &&
    current.left === next.left &&
    current.width === next.width &&
    current.height === next.height
  )
}

function outsideViewport(rect: TourAnchorRect): boolean {
  const horizontallyOutside =
    rect.right <= 0 ||
    rect.left >= window.innerWidth ||
    (rect.width <= window.innerWidth &&
      (rect.left < 0 || rect.right > window.innerWidth))
  const verticallyOutside =
    rect.bottom <= 0 ||
    rect.top >= window.innerHeight ||
    (rect.height <= window.innerHeight &&
      (rect.top < 0 || rect.bottom > window.innerHeight))
  return horizontallyOutside || verticallyOutside
}

function findRenderedAnchor(target: TourAnchorKey): HTMLElement | null {
  const element = document.querySelector<HTMLElement>(
    `[data-tour="${target}"]`
  )
  if (element === null || element.getClientRects().length === 0) return null
  const styles = window.getComputedStyle(element)
  if (styles.display === 'none' || styles.visibility === 'hidden') return null
  return element
}

/**
 * Tracks a live `data-tour` anchor without ever trapping the tour on a UI
 * variant that does not render it. A missing anchor leaves the explanation
 * centered; every one of the five steps remains available to read.
 */
export function useTourAnchor(
  target: TourAnchorKey | null,
  fallbackTarget: TourAnchorKey | null = null
): TourAnchorRect | null {
  const [rect, setRect] = useState<TourAnchorRect | null>(null)
  const elementRef = useRef<HTMLElement | null>(null)
  const observerRef = useRef<ResizeObserver | null>(null)

  useEffect(() => {
    setRect(null)
    elementRef.current = null
    observerRef.current?.disconnect()
    observerRef.current = null

    if (target === null) return

    let disposed = false
    let measureFrame: number | null = null
    let loopFrame: number | null = null
    let lastLoopMeasure = 0
    let primaryMisses = 0

    const measure = (): void => {
      const element = elementRef.current
      if (element === null || !element.isConnected) return
      let next = rectOf(element)
      if (outsideViewport(next)) {
        element.scrollIntoView({ block: 'nearest', inline: 'nearest' })
        next = rectOf(element)
      }
      setRect((current) => (sameRect(current, next) ? current : next))
    }

    const scheduleMeasure = (): void => {
      if (measureFrame !== null) return
      measureFrame = window.requestAnimationFrame(() => {
        measureFrame = null
        measure()
      })
    }

    const connect = (element: HTMLElement | null): void => {
      if (elementRef.current === element) return
      observerRef.current?.disconnect()
      observerRef.current = null
      elementRef.current = element

      if (element === null) {
        setRect(null)
        return
      }

      if (typeof ResizeObserver !== 'undefined') {
        const observer = new ResizeObserver(scheduleMeasure)
        observer.observe(element)
        if (document.body !== element) observer.observe(document.body)
        observerRef.current = observer
      }
      measure()
    }

    const findAnchor = (): void => {
      const primary = findRenderedAnchor(target)
      if (primary !== null) {
        primaryMisses = 0
        connect(primary)
        return
      }

      // Allow the primary surface one polling interval to mount before
      // choosing an optional fallback.
      if (fallbackTarget !== null && primaryMisses === 0) {
        primaryMisses += 1
        connect(null)
        return
      }

      const fallback =
        fallbackTarget === null
          ? null
          : findRenderedAnchor(fallbackTarget)
      connect(fallback)
    }

    const loop = (now: number): void => {
      if (disposed) return
      if (now - lastLoopMeasure >= RAF_MEASURE_INTERVAL_MS) {
        lastLoopMeasure = now
        const element = elementRef.current
        if (element !== null && !element.isConnected) connect(null)
        else measure()
      }
      loopFrame = window.requestAnimationFrame(loop)
    }

    findAnchor()
    const pollTimer = window.setInterval(findAnchor, POLL_INTERVAL_MS)
    loopFrame = window.requestAnimationFrame(loop)
    window.addEventListener('resize', scheduleMeasure)
    window.addEventListener('scroll', scheduleMeasure, true)

    return () => {
      disposed = true
      window.clearInterval(pollTimer)
      observerRef.current?.disconnect()
      observerRef.current = null
      elementRef.current = null
      if (measureFrame !== null) window.cancelAnimationFrame(measureFrame)
      if (loopFrame !== null) window.cancelAnimationFrame(loopFrame)
      window.removeEventListener('resize', scheduleMeasure)
      window.removeEventListener('scroll', scheduleMeasure, true)
    }
  }, [fallbackTarget, target])

  return rect
}
