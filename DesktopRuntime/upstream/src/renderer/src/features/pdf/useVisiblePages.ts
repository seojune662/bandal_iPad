import { useCourseActive } from '../workspace/courseActivity'
/**
 * Page virtualization for the PDF scroller. One IntersectionObserver
 * (rootMargin = one viewport in each direction) watches every page wrapper;
 * only pages near the viewport render a real pdf.js canvas — the rest stay
 * cheap aspect-ratio placeholders, keeping 100+ page documents smooth.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { RefObject } from 'react'

const NEAR_VIEWPORT_MARGIN = '100% 0px 100% 0px'

export interface VisiblePagesApi {
  /** Pages (1-based) that should render for real. */
  visiblePages: Set<number>
  /** Ref callback factory — attach to each page wrapper element. */
  registerPage(page: number): (element: HTMLElement | null) => void
  /** Live element for a page, e.g. for scroll-to-page. */
  elementFor(page: number): HTMLElement | null
  /** Page whose box covers the vertical middle of the scroller viewport. */
  pageAtViewportCenter(): number
  /** Stable semantic position at the viewport center (page + offset in page). */
  captureViewportAnchor(): PdfViewportAnchor | null
  /** Restores a semantic position after page boxes have been reflowed. */
  restoreViewportAnchor(anchor: PdfViewportAnchor): boolean
  /** Marks cached page offsets stale after zoom or another layout change. */
  invalidatePageOffsets(): void
}

export interface PageViewport {
  scrollTop: number
  readonly clientHeight: number
  getBoundingClientRect(): { top: number }
}

export interface PageBoxElement {
  getBoundingClientRect(): { top: number; height: number }
}

/**
 * A pixel-independent reading position. `pageOffset` is the viewport center's
 * vertical position inside the page (0 = top, 1 = bottom).
 */
export interface PdfViewportAnchor {
  page: number
  pageOffset: number
}

interface PageCenter {
  page: number
  center: number
}

/**
 * Measures page positions only while invalid, then answers scroll-frame
 * queries by binary-searching cached content-space centers.
 */
export class PageCenterCache {
  private centers: PageCenter[] = []
  private invalid = true

  invalidate(): void {
    this.invalid = true
  }

  pageAtViewportCenter(
    scroller: PageViewport,
    elements: ReadonlyMap<number, PageBoxElement>
  ): number {
    if (this.invalid) this.measure(scroller, elements)
    if (this.centers.length === 0) return 1

    const target = scroller.scrollTop + scroller.clientHeight / 2
    let low = 0
    let high = this.centers.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if ((this.centers[middle]?.center ?? 0) < target) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    if (low === 0) return this.centers[0]?.page ?? 1
    if (low === this.centers.length) {
      return this.centers[this.centers.length - 1]?.page ?? 1
    }
    const before = this.centers[low - 1]
    const after = this.centers[low]
    if (before === undefined || after === undefined) return 1
    return target - before.center <= after.center - target
      ? before.page
      : after.page
  }

  captureViewportAnchor(
    scroller: PageViewport,
    elements: ReadonlyMap<number, PageBoxElement>
  ): PdfViewportAnchor | null {
    if (scroller.clientHeight <= 0) return null
    const page = this.pageAtViewportCenter(scroller, elements)
    const element = elements.get(page)
    if (element === undefined) return null
    const scrollerTop = scroller.getBoundingClientRect().top
    const box = element.getBoundingClientRect()
    if (box.height <= 0) return null
    const center = scrollerTop + scroller.clientHeight / 2
    return {
      page,
      pageOffset: Math.min(1, Math.max(0, (center - box.top) / box.height))
    }
  }

  restoreViewportAnchor(
    scroller: PageViewport,
    elements: ReadonlyMap<number, PageBoxElement>,
    anchor: PdfViewportAnchor
  ): boolean {
    if (scroller.clientHeight <= 0) return false
    const element = elements.get(anchor.page)
    if (element === undefined) return false
    const scrollerTop = scroller.getBoundingClientRect().top
    const box = element.getBoundingClientRect()
    if (box.height <= 0) return false
    const pageOffset = Math.min(1, Math.max(0, anchor.pageOffset))
    const anchoredPoint = box.top + box.height * pageOffset
    const viewportCenter = scrollerTop + scroller.clientHeight / 2
    scroller.scrollTop += anchoredPoint - viewportCenter
    return true
  }

  private measure(
    scroller: PageViewport,
    elements: ReadonlyMap<number, PageBoxElement>
  ): void {
    const scrollerTop = scroller.getBoundingClientRect().top
    const scrollTop = scroller.scrollTop
    const centers: PageCenter[] = []
    for (const [page, element] of elements) {
      const box = element.getBoundingClientRect()
      centers.push({
        page,
        center: box.top - scrollerTop + scrollTop + box.height / 2
      })
    }
    centers.sort((a, b) => a.center - b.center || a.page - b.page)
    this.centers = centers
    this.invalid = false
  }
}

function setsEqual(a: Set<number>, b: Set<number>): boolean {
  if (a.size !== b.size) return false
  for (const value of a) {
    if (!b.has(value)) return false
  }
  return true
}

export function useVisiblePages(
  scrollerRef: RefObject<HTMLElement>
): VisiblePagesApi {
  const courseActive = useCourseActive()
  const activeRef = useRef(courseActive)
  activeRef.current = courseActive
  const [visiblePages, setVisiblePages] = useState<Set<number>>(new Set([1]))
  const observerRef = useRef<IntersectionObserver | null>(null)
  const elementsRef = useRef(new Map<number, HTMLElement>())
  const pageOfElementRef = useRef(new WeakMap<Element, number>())
  const intersectingRef = useRef(new Set<number>([1]))
  const pageCenterCacheRef = useRef(new PageCenterCache())

  useEffect(() => {
    const scroller = scrollerRef.current
    if (scroller === null || !courseActive) return

    let observing = true
    const observer = new IntersectionObserver(
      (entries) => {
        if (!observing || !activeRef.current || scroller.clientHeight === 0) return
        const intersecting = intersectingRef.current
        for (const entry of entries) {
          const page = pageOfElementRef.current.get(entry.target)
          if (page === undefined) continue
          if (entry.isIntersecting) {
            intersecting.add(page)
          } else {
            intersecting.delete(page)
          }
        }
        setVisiblePages((current) =>
          setsEqual(current, intersecting) ? current : new Set(intersecting)
        )
      },
      { root: scroller, rootMargin: NEAR_VIEWPORT_MARGIN }
    )
    observerRef.current = observer
    for (const element of elementsRef.current.values()) {
      observer.observe(element)
    }
    return () => {
      observing = false
      observer.disconnect()
      observerRef.current = null
    }
  }, [scrollerRef, courseActive])

  // Ref callbacks are cached per page so PdfPageView memo props stay stable
  // and React does not detach/re-attach refs on every parent render.
  const refCallbacksRef = useRef(
    new Map<number, (element: HTMLElement | null) => void>()
  )
  const registerPage = useCallback((page: number) => {
    const cached = refCallbacksRef.current.get(page)
    if (cached !== undefined) return cached
    const callback = (element: HTMLElement | null): void => {
      const previous = elementsRef.current.get(page)
      if (previous !== undefined && previous !== element) {
        observerRef.current?.unobserve(previous)
        elementsRef.current.delete(page)
        pageCenterCacheRef.current.invalidate()
      }
      if (element !== null) {
        elementsRef.current.set(page, element)
        pageOfElementRef.current.set(element, page)
        observerRef.current?.observe(element)
        if (previous !== element) pageCenterCacheRef.current.invalidate()
      }
    }
    refCallbacksRef.current.set(page, callback)
    return callback
  }, [])

  const elementFor = useCallback(
    (page: number): HTMLElement | null => elementsRef.current.get(page) ?? null,
    []
  )

  const pageAtViewportCenter = useCallback((): number => {
    const scroller = scrollerRef.current
    if (scroller === null) return 1
    return pageCenterCacheRef.current.pageAtViewportCenter(
      scroller,
      elementsRef.current
    )
  }, [scrollerRef])

  const captureViewportAnchor = useCallback((): PdfViewportAnchor | null => {
    const scroller = scrollerRef.current
    if (scroller === null) return null
    return pageCenterCacheRef.current.captureViewportAnchor(
      scroller,
      elementsRef.current
    )
  }, [scrollerRef])

  const restoreViewportAnchor = useCallback(
    (anchor: PdfViewportAnchor): boolean => {
      const scroller = scrollerRef.current
      if (scroller === null) return false
      return pageCenterCacheRef.current.restoreViewportAnchor(
        scroller,
        elementsRef.current,
        anchor
      )
    },
    [scrollerRef]
  )

  const invalidatePageOffsets = useCallback((): void => {
    pageCenterCacheRef.current.invalidate()
  }, [])

  return {
    visiblePages,
    registerPage,
    elementFor,
    pageAtViewportCenter,
    captureViewportAnchor,
    restoreViewportAnchor,
    invalidatePageOffsets
  }
}
