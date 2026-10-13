export interface BrowserSwipeState {
  canBack: boolean
  canForward: boolean
  enabled: boolean
  theme: 'light' | 'dark'
}

export const BROWSER_SWIPE_IDLE_MS = 180

export type ParentSwipePolicy = (direction: 'back' | 'forward', startedAt: number) => Promise<boolean>

export function scrollChainConsumes(path: EventTarget[], deltaX: number): boolean {
  const viewport = document.scrollingElement
  const rootCss = viewport === document.documentElement ? getComputedStyle(document.documentElement) : null
  const bodyCss = rootCss && document.body ? getComputedStyle(document.body) : null
  // Propagated body overflow belongs to the viewport, not a second container.
  const bodyOverflow = rootCss && bodyCss && bodyCss.display !== 'none'
    && (!rootCss.overflowX || rootCss.overflowX === 'visible') && (!rootCss.overflowY || rootCss.overflowY === 'visible')
    && (!rootCss.contain || rootCss.contain === 'none') && (!bodyCss.contain || bodyCss.contain === 'none')
  for (const item of path) {
    if (!(item instanceof Element) || (bodyOverflow && item === document.body)) continue
    const css = getComputedStyle(item)
    // The viewport scrolls with its default overflow:visible. Plain elements
    // must be scroll containers before their overscroll policy has an effect.
    const overflow = item === viewport && bodyOverflow ? bodyCss!.overflowX : css.overflowX
    if (item !== viewport && !/^(auto|scroll|hidden)$/.test(overflow)) continue
    if (css.overscrollBehaviorX === 'contain' || css.overscrollBehaviorX === 'none') return true
    if (overflow === 'hidden' || overflow === 'clip' || item.scrollWidth <= item.clientWidth + 1) continue
    const max = item.scrollWidth - item.clientWidth
    const x = item.scrollLeft
    if (css.direction === 'rtl' ? (deltaX < 0 ? x > -max + 1 : x < -1) : (deltaX < 0 ? x > 1 : x < max - 1)) return true
  }
  return false
}

export function waitForSwipe(state: () => BrowserSwipeState, checkParents?: ParentSwipePolicy): Promise<'back' | 'forward'> {
  return new Promise(resolve => {
    let distance = 0, vertical = 0, last = -Infinity, blocked = false, timer: ReturnType<typeof setTimeout> | undefined
    let gesture = 0, policyRequest = 0, startedAt = 0, parentAllowed = !checkParents
    let parentDirection: 'back' | 'forward' | undefined
    let hint: HTMLElement | null = null
    const clear = (): void => { hint?.remove(); hint = null }
    const commit = (direction: 'back' | 'forward', expectedGesture: number): void => {
      const current = state()
      if (gesture !== expectedGesture || document.hidden || !current.enabled || !(direction === 'back' ? current.canBack : current.canForward)) return
      window.removeEventListener('wheel', wheel)
      window.removeEventListener('blur', cancel)
      window.removeEventListener('pagehide', cancel)
      document.removeEventListener('visibilitychange', visibilityChanged)
      resolve(direction)
    }
    const wheel = (event: WheelEvent): void => {
      if (!event.isTrusted) return
      const now = performance.now()
      if (now - last >= BROWSER_SWIPE_IDLE_MS) {
        distance = 0; vertical = 0; blocked = false; clear()
        gesture++; startedAt = Date.now(); parentAllowed = !checkParents; parentDirection = undefined
      }
      last = now
      clearTimeout(timer)
      // Check the actual direction on every packet, including a reversal.
      // Once scrolling owns a gesture, reaching its edge cannot turn the
      // remaining movement (or momentum) into a history navigation.
      if (event.deltaX !== 0 && scrollChainConsumes(event.composedPath(), event.deltaX)) blocked = true
      if (event.defaultPrevented || document.hidden || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || event.deltaMode !== 0) blocked = true
      if (checkParents && !blocked && event.deltaX !== 0) {
        const direction = event.deltaX < 0 ? 'back' : 'forward'
        if (direction !== parentDirection) {
          parentAllowed = false
          parentDirection = direction
          const expectedGesture = gesture, request = ++policyRequest
          void checkParents(direction, startedAt).catch(() => false).then(allowed => {
            if (gesture !== expectedGesture || policyRequest !== request) return
            parentAllowed = allowed
            if (!allowed) { blocked = true; clear() }
          })
        }
      }
      distance += event.deltaX
      vertical += Math.abs(event.deltaY)
      if (vertical > 12 && vertical > Math.abs(distance) / 1.5) blocked = true
      const flags = state()
      const available = flags.enabled && (distance < 0 ? flags.canBack : flags.canForward)
      if (!blocked && parentAllowed && available && Math.abs(distance) > 12 && Math.abs(distance) > vertical * 1.5) {
        event.preventDefault()
        if (!hint) {
          hint = document.createElement('div')
          hint.setAttribute('aria-hidden', 'true')
          hint.style.cssText = 'all:initial;position:fixed;top:45%;z-index:2147483647;border-radius:50%;width:44px;height:44px;display:grid;place-items:center;pointer-events:none;box-shadow:0 3px 16px #0003;'
          document.documentElement.append(hint)
        }
        // Use the app's neutral theme, never the page CSS or course accent.
        hint.style.color = flags.theme === 'dark' ? '#171717' : '#ffffff'
        hint.style.backgroundColor = flags.theme === 'dark' ? '#ececec' : '#171717'
        hint.style.left = distance < 0 ? '12px' : 'auto'
        hint.style.right = distance > 0 ? '12px' : 'auto'
        hint.style.opacity = String(Math.min(1, Math.abs(distance) / 160))
        hint.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${distance < 0 ? 'M14 6l-6 6 6 6' : 'M10 6l6 6-6 6'}"/></svg>`
      } else clear()
      timer = setTimeout(() => {
        clear()
        if (!blocked && parentAllowed && Math.abs(distance) >= 160 && Math.abs(distance) > vertical * 1.5) {
          const direction = distance < 0 ? 'back' : 'forward', expectedGesture = gesture
          // The first unclaimed packet can scroll an ancestor before its policy
          // reply arrives. Recheck recent ancestor scrolling before committing.
          if (checkParents) void checkParents(direction, startedAt).catch(() => false).then(allowed => { if (allowed) commit(direction, expectedGesture) })
          else commit(direction, expectedGesture)
        }
        distance = 0; vertical = 0; last = -Infinity; blocked = false
      }, BROWSER_SWIPE_IDLE_MS)
    }
    const cancel = (): void => { gesture++; blocked = true; clear() }
    const visibilityChanged = (): void => { if (document.hidden) cancel() }
    // Let page widgets consume wheel input before deciding to navigate.
    window.addEventListener('wheel', wheel, { passive: false })
    window.addEventListener('blur', cancel)
    window.addEventListener('pagehide', cancel)
    document.addEventListener('visibilitychange', visibilityChanged)
  })
}
