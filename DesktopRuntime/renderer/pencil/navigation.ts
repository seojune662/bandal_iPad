interface TouchPoint { x: number; y: number }
interface NavigationGesture {
  viewport: HTMLElement
  points: Map<number, TouchPoint>
  moved: boolean
}

const viewportSelector = '.pdf-scroller, .canvas-tab__viewport'
const editableSelector = 'input,textarea,select,button,[contenteditable=true],.ink-layer__text-editor'

/** Input adapter only. The desktop's existing wheel zoom handler, scroll
 * containers, page sizing and zoom persistence still own the PDF layout. */
export function installPencilNavigation(): () => void {
  const stylus = new Set<number>()
  const ignored = new Set<number>()
  const gestures = new Map<HTMLElement, NavigationGesture>()
  const owners = new Map<number, NavigationGesture>()
  const originalTouchActions = new Map<HTMLElement, string>()
  let suppressClickUntil = 0
  // iOS WebKit may cancel a pointer stream when its native recognizer takes
  // ownership. TouchEvents with a non-passive start own finger navigation;
  // Pencil remains on PointerEvents for pressure/coalesced samples.
  const useTouchEvents = navigator.maxTouchPoints > 0 && 'ontouchstart' in window
  const touchStylus = new Set<number>()
  const touchTargets = new Map<number, { target: Element; viewport: HTMLElement }>()
  const retainedTargets = new Map<Element, { ids: Set<number>; listener: EventListener }>()
  const handledTouches = new WeakSet<TouchEvent>()

  const prepare = (): void => {
    for (const viewport of document.querySelectorAll<HTMLElement>(viewportSelector)) {
      if (originalTouchActions.has(viewport)) continue
      originalTouchActions.set(viewport, viewport.style.touchAction)
      viewport.style.touchAction = 'none'
    }
    for (const viewport of originalTouchActions.keys()) {
      if (!viewport.isConnected) { gestures.delete(viewport); originalTouchActions.delete(viewport) }
    }
    for (const [id, entry] of touchTargets) {
      if (!entry.viewport.isConnected) {
        touchStylus.delete(id)
        release({ pointerId: id } as PointerEvent)
        releaseTouchTarget(id)
      }
    }
  }
  const observer = new MutationObserver(prepare)
  observer.observe(document.documentElement, { childList: true, subtree: true })
  prepare()

  function release(event: PointerEvent): void {
    if (useTouchEvents && event.pointerType === 'touch') return
    stylus.delete(event.pointerId)
    ignored.delete(event.pointerId)
    const gesture = owners.get(event.pointerId)
    owners.delete(event.pointerId)
    if (!gesture) return
    gesture.points.delete(event.pointerId)
    if (gesture.moved) suppressClickUntil = performance.now() + 400
    if (gesture.points.size === 0) gestures.delete(gesture.viewport)
  }

  function down(event: PointerEvent): void {
    const target = event.target instanceof Element ? event.target : null
    const viewport = target?.closest<HTMLElement>(viewportSelector)
    if (!viewport || target?.closest(editableSelector)) return
    if (event.pointerType === 'pen') {
      stylus.add(event.pointerId)
      for (const id of owners.keys()) ignored.add(id)
      gestures.clear(); owners.clear()
      return
    }
    if (event.pointerType !== 'touch' || useTouchEvents) return
    // Contact radius is not a palm classifier: iPad ordinary fingers can
    // exceed 30 CSS points. Pencil ownership suppresses competing fingers.
    if (stylus.size > 0) { ignored.add(event.pointerId); return }
    let gesture = gestures.get(viewport)
    if (!gesture) {
      gesture = { viewport, points: new Map(), moved: false }
      gestures.set(viewport, gesture)
    }
    if (gesture.points.size >= 2) { ignored.add(event.pointerId); return }
    gesture.points.set(event.pointerId, { x: event.clientX, y: event.clientY })
    owners.set(event.pointerId, gesture)
    try { viewport.setPointerCapture(event.pointerId) } catch { /* Detached surface */ }
  }

  function move(event: PointerEvent): void {
    if (event.pointerType !== 'touch' || useTouchEvents) return
    moveFinger(event.pointerId, event.clientX, event.clientY, () => event.preventDefault())
  }

  function moveFinger(id: number, x: number, y: number, preventDefault: () => void): void {
    if (ignored.has(id) || stylus.size > 0 || touchStylus.size > 0) { preventDefault(); return }
    const gesture = owners.get(id)
    const previous = gesture?.points.get(id)
    if (!gesture || !previous) return
    preventDefault()
    const next = { x, y }
    const other = [...gesture.points.entries()].find(([otherID]) => otherID !== id)?.[1]
    gesture.points.set(id, next)
    const dx = next.x - previous.x, dy = next.y - previous.y
    if (Math.hypot(dx, dy) > 0) gesture.moved = true
    if (!other) {
      gesture.viewport.scrollLeft -= dx
      gesture.viewport.scrollTop -= dy
      return
    }
    const before = Math.hypot(previous.x - other.x, previous.y - other.y)
    const after = Math.hypot(next.x - other.x, next.y - other.y)
    if (before < 8 || after < 8) return
    const ratio = Math.min(1.5, Math.max(0.67, after / before))
    const centerX = (next.x + other.x) / 2, centerY = (next.y + other.y) / 2
    if (gesture.viewport.matches('.pdf-scroller')) {
      // PDF text spans and buffered canvases are replaced during zoom. The
      // original wheel listener belongs to this stable scroller; dispatching
      // to the initial hit node loses the rest of a pinch after it detaches.
      gesture.viewport.dispatchEvent(new WheelEvent('wheel', {
        bubbles: true, cancelable: true, ctrlKey: true,
        clientX: centerX, clientY: centerY, deltaY: -Math.log(ratio) / 0.002, deltaMode: 0
      }))
    } else {
      const pages = gesture.viewport.querySelector<HTMLElement>('.canvas-tab__pages')
      if (!pages) return
      const old = pages.getBoundingClientRect()
      const width = Math.min(4000, Math.max(240, old.width * ratio))
      if (Math.abs(old.width - width) < 0.1) return
      const ax = (centerX - old.left) / old.width, ay = (centerY - old.top) / old.height
      pages.style.width = `${width}px`
      pages.style.flexShrink = '0'
      const updated = pages.getBoundingClientRect()
      gesture.viewport.scrollLeft += updated.left + ax * updated.width - centerX
      gesture.viewport.scrollTop += updated.top + ay * updated.height - centerY
    }
  }

  function retainTouchTarget(id: number, target: Element, viewport: HTMLElement): void {
    if (touchTargets.get(id)?.target === target) return
    releaseTouchTarget(id)
    let retained = retainedTargets.get(target)
    if (!retained) {
      // iOS keeps sending an existing touch stream to its initial target even
      // after PDF text/canvas rendering detaches it. These events no longer
      // reach document. Keep only the active stream's target alive until end.
      const listener: EventListener = (event): void => {
        if (target.isConnected) return
        if (event.type === 'touchmove') touchMove(event as TouchEvent)
        else touchEnd(event as TouchEvent)
      }
      retained = { ids: new Set(), listener }
      retainedTargets.set(target, retained)
      target.addEventListener('touchmove', listener, { capture: true, passive: false })
      target.addEventListener('touchend', listener, true)
      target.addEventListener('touchcancel', listener, true)
    }
    retained.ids.add(id)
    touchTargets.set(id, { target, viewport })
  }

  function releaseTouchTarget(id: number): void {
    const entry = touchTargets.get(id)
    if (!entry) return
    touchTargets.delete(id)
    const retained = retainedTargets.get(entry.target)
    if (!retained) return
    retained.ids.delete(id)
    if (retained.ids.size > 0) return
    entry.target.removeEventListener('touchmove', retained.listener, true)
    entry.target.removeEventListener('touchend', retained.listener, true)
    entry.target.removeEventListener('touchcancel', retained.listener, true)
    retainedTargets.delete(entry.target)
  }

  function touchStart(event: TouchEvent): void {
    if (!useTouchEvents) return
    const target = event.target instanceof Element ? event.target : null
    const viewport = target?.closest<HTMLElement>(viewportSelector)
    if (!viewport || target?.closest(editableSelector)) return
    for (const touch of Array.from(event.changedTouches)) {
      retainTouchTarget(touch.identifier, touch.target instanceof Element ? touch.target : target!, viewport)
      if ((touch as Touch & { touchType?: string }).touchType === 'stylus') {
        touchStylus.add(touch.identifier)
        for (const id of owners.keys()) ignored.add(id)
        gestures.clear(); owners.clear()
        continue
      }
      if (stylus.size || touchStylus.size) {
        ignored.add(touch.identifier); continue
      }
      let gesture = gestures.get(viewport)
      if (!gesture) {
        gesture = { viewport, points: new Map(), moved: false }
        gestures.set(viewport, gesture)
      }
      if (gesture.points.size >= 2) { ignored.add(touch.identifier); continue }
      gesture.points.set(touch.identifier, { x: touch.clientX, y: touch.clientY })
      owners.set(touch.identifier, gesture)
      event.preventDefault()
    }
  }
  function touchMove(event: TouchEvent): void {
    if (!useTouchEvents || handledTouches.has(event)) return
    // A target can detach during document capture, and retained ancestor/child
    // targets may share an event path. Each native event must update once.
    handledTouches.add(event)
    for (const touch of Array.from(event.changedTouches)) {
      if (touchStylus.has(touch.identifier)) continue
      moveFinger(touch.identifier, touch.clientX, touch.clientY, () => event.preventDefault())
    }
  }
  function touchEnd(event: TouchEvent): void {
    if (!useTouchEvents || handledTouches.has(event)) return
    handledTouches.add(event)
    for (const touch of Array.from(event.changedTouches)) {
      touchStylus.delete(touch.identifier)
      release({ pointerId: touch.identifier } as PointerEvent)
      releaseTouchTarget(touch.identifier)
    }
  }

  function click(event: MouseEvent): void {
    if (performance.now() < suppressClickUntil && event.target instanceof Element && event.target.closest(viewportSelector)) {
      event.preventDefault(); event.stopImmediatePropagation()
    }
  }
  function reset(): void {
    for (const id of touchTargets.keys()) releaseTouchTarget(id)
    touchStylus.clear(); stylus.clear(); ignored.clear(); gestures.clear(); owners.clear()
  }
  document.addEventListener('touchstart', touchStart, { capture: true, passive: false })
  document.addEventListener('touchmove', touchMove, { capture: true, passive: false })
  document.addEventListener('touchend', touchEnd, true)
  document.addEventListener('touchcancel', touchEnd, true)
  document.addEventListener('pointerdown', down, true)
  document.addEventListener('pointermove', move, { capture: true, passive: false })
  document.addEventListener('pointerup', release, true)
  document.addEventListener('pointercancel', release, true)
  document.addEventListener('lostpointercapture', release, true)
  document.addEventListener('click', click, true)
  window.addEventListener('blur', reset)
  document.addEventListener('visibilitychange', reset)
  return () => {
    observer.disconnect(); reset()
    for (const [viewport, action] of originalTouchActions) viewport.style.touchAction = action
    document.removeEventListener('touchstart', touchStart, true)
    document.removeEventListener('touchmove', touchMove, true)
    document.removeEventListener('touchend', touchEnd, true)
    document.removeEventListener('touchcancel', touchEnd, true)
    document.removeEventListener('pointerdown', down, true)
    document.removeEventListener('pointermove', move, true)
    document.removeEventListener('pointerup', release, true)
    document.removeEventListener('pointercancel', release, true)
    document.removeEventListener('lostpointercapture', release, true)
    document.removeEventListener('click', click, true)
    window.removeEventListener('blur', reset)
    document.removeEventListener('visibilitychange', reset)
  }
}
