import { useEffect, type RefObject } from 'react'
import { useCourseActive } from '../courseActivity'
import { tabDragSession } from '../tabDragSession'

export interface AnchorRect { x: number; y: number; width: number; height: number }
type AnchorListener = (tabId: string, rect: AnchorRect | null) => void
const anchorRects = new Map<string, AnchorRect>()
const anchors = new Map<string, HTMLElement>()
const listeners = new Set<AnchorListener>()
let frame = 0
let stopObserving: (() => void) | null = null
const moving = new Set<Element>()

function sameRect(a: AnchorRect | undefined, b: AnchorRect | null): boolean {
  return b === null ? a === undefined : a?.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
}
function publish(tabId: string, rect: AnchorRect | null): void {
  if (sameRect(anchorRects.get(tabId), rect)) return
  if (rect === null) anchorRects.delete(tabId)
  else anchorRects.set(tabId, rect)
  for (const listener of listeners) listener(tabId, rect)
}
export function getBrowserAnchorRect(tabId: string): AnchorRect | null { return anchorRects.get(tabId) ?? null }
export function onBrowserAnchorRect(listener: AnchorListener): () => void {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}
/** Retained content keeps its size while hidden, but must never expose its native page. */
export function readBrowserAnchorRect(element: HTMLElement): AnchorRect | null {
  if (!element.isConnected || element.closest('[hidden], [inert]') || getComputedStyle(element).visibility !== 'visible') return null
  const rect = element.getBoundingClientRect()
  return rect.width > 0 && rect.height > 0 && element.getClientRects().length > 0
    ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height } : null
}
function measureAll(): void {
  frame = 0
  for (const [tabId, element] of anchors) {
    publish(tabId, readBrowserAnchorRect(element))
  }
  // A drag can translate a group without resizing its page.
  for (const element of moving) if (!element.isConnected || !element.getAnimations().some(animation => animation.playState === 'running')) moving.delete(element)
  if ((tabDragSession.getSnapshot() !== null || moving.size > 0) && anchors.size) frame = requestAnimationFrame(measureAll)
}
/** One layout read batch per frame, including translations that ResizeObserver misses. */
export function scheduleBrowserAnchorLayout(): void {
  if (!frame && anchors.size) frame = requestAnimationFrame(measureAll)
}
function observeLayout(): void {
  stopObserving?.()
  if (!anchors.size) { stopObserving = null; return }
  const resize = new ResizeObserver(scheduleBrowserAnchorLayout)
  const mutation = new MutationObserver(scheduleBrowserAnchorLayout)
  const observed = new Set<Element>()
  for (const anchor of anchors.values()) for (let element: Element | null = anchor; element; element = element.parentElement) {
    if (observed.has(element)) continue
    observed.add(element)
    resize.observe(element)
    mutation.observe(element, { attributes: true, attributeFilter: ['style', 'class', 'hidden', 'data-left-rail', 'data-course-rail', 'data-right-rail', 'data-fullscreen'] })
  }
  const transitionStart = (event: TransitionEvent): void => {
    if (event.target instanceof Element && observed.has(event.target)) { moving.add(event.target); scheduleBrowserAnchorLayout() }
  }
  const transitionEnd = (event: TransitionEvent): void => {
    if (event.target instanceof Element && observed.has(event.target)) { moving.delete(event.target); scheduleBrowserAnchorLayout() }
  }
  document.addEventListener('transitionrun', transitionStart)
  document.addEventListener('transitionend', transitionEnd)
  document.addEventListener('transitioncancel', transitionEnd)
  const unsubscribeDrag = tabDragSession.subscribe(scheduleBrowserAnchorLayout)
  window.addEventListener('resize', scheduleBrowserAnchorLayout)
  window.addEventListener('scroll', scheduleBrowserAnchorLayout, true)
  stopObserving = () => {
    resize.disconnect(); mutation.disconnect(); unsubscribeDrag()
    window.removeEventListener('resize', scheduleBrowserAnchorLayout)
    window.removeEventListener('scroll', scheduleBrowserAnchorLayout, true)
    document.removeEventListener('transitionrun', transitionStart)
    document.removeEventListener('transitionend', transitionEnd)
    document.removeEventListener('transitioncancel', transitionEnd)
    moving.clear()
  }
}

/** Hiding or reparenting an anchor never destroys its native page. */
export function useBrowserAnchorRect(tabId: string, ref: RefObject<HTMLElement>): void {
  const courseActive = useCourseActive()
  useEffect(() => {
    const element = ref.current
    if (!courseActive || !tabId || !element) { publish(tabId, null); return }
    anchors.set(tabId, element)
    observeLayout()
    scheduleBrowserAnchorLayout()
    return () => {
      if (anchors.get(tabId) !== element) return
      anchors.delete(tabId)
      publish(tabId, null)
      observeLayout()
      if (!anchors.size) { cancelAnimationFrame(frame); frame = 0 }
    }
  }, [tabId, ref, courseActive])
}
