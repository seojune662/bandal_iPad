import { scrollChainConsumes, type ParentSwipePolicy } from './browserSwipe'

const CHANNEL = 'bandal-browser-swipe-policy-v1'
const POLICY_TIMEOUT_MS = 120
type Direction = 'back' | 'forward'
type Pending = { finish: (allowed: boolean) => void; timer: ReturnType<typeof setTimeout> }

function ancestorPath(frame: Element): Element[] {
  const path: Element[] = []
  let item: Element | null = frame
  while (item) {
    const root = item.getRootNode()
    item = item.assignedSlot ?? item.parentElement ?? (root instanceof ShadowRoot ? root.host : null)
    if (item) path.push(item)
  }
  return path
}

function sourceFrame(source: MessageEventSource | null, observe: (root: ShadowRoot) => void, root: Document | ShadowRoot = document): Element | null {
  if (root instanceof ShadowRoot) observe(root)
  for (const frame of root.querySelectorAll<HTMLIFrameElement | HTMLFrameElement>('iframe,frame')) {
    if (frame.contentWindow === source) return frame
  }
  // Closed shadow roots cannot be inspected: their requests fail closed.
  for (const item of root.querySelectorAll('*')) {
    if (item.shadowRoot) {
      const frame = sourceFrame(source, observe, item.shadowRoot)
      if (frame) return frame
    }
  }
  return null
}

/** Install once per isolated preload, never once per gesture. */
export function createParentSwipePolicy(): { checkParents: ParentSwipePolicy | undefined; dispose: () => void } {
  const pending = new Map<string, Pending>()
  const scrollTimes = new WeakMap<EventTarget, number>()
  const shadowRoots = new Map<ShadowRoot, number>()
  const nativePostMessage = window.postMessage
  let active = true
  const post = (target: Window, data: unknown): void => { nativePostMessage.call(target, data, { targetOrigin: '*' }) }
  const recentlyScrolled = (path: Element[], startedAt: number): boolean => path.some(item => (scrollTimes.get(item) ?? -Infinity) >= startedAt)
  const allows = (frame: Element, direction: Direction, startedAt: number): boolean => {
    if (!active || !frame.isConnected || document.hidden) return false
    if (!Array.from(frame.getClientRects()).some(rect => rect.width > 0 && rect.height > 0) || /^(hidden|collapse)$/.test(getComputedStyle(frame).visibility)) return false
    const path = ancestorPath(frame)
    // Scroll events do not leave shadow roots. A newly discovered root might
    // already have consumed the opening packet, so this first gesture cannot
    // navigate; subsequent gestures use its installed scroll observer.
    if ([frame, ...path].some(item => {
      const root = item.getRootNode()
      return root instanceof ShadowRoot && (shadowRoots.get(root) ?? Infinity) >= startedAt
    })) return false
    return !scrollChainConsumes(path, direction === 'back' ? -1 : 1) && !recentlyScrolled(path, startedAt)
  }
  const checkParents: ParentSwipePolicy = (direction, startedAt) => {
    if (!active) return Promise.resolve(false)
    if (window.parent === window) return Promise.resolve(true)
    if (pending.size >= 32) return Promise.resolve(false)
    // getRandomValues also works on non-secure HTTP pages; randomUUID does not.
    const id = Array.from(crypto.getRandomValues(new Uint32Array(4)), value => value.toString(16).padStart(8, '0')).join('')
    return new Promise(resolve => {
      const finish = (allowed: boolean): void => {
        const request = pending.get(id)
        if (!request) return
        clearTimeout(request.timer)
        pending.delete(id)
        resolve(allowed)
      }
      pending.set(id, { finish, timer: setTimeout(() => finish(false), POLICY_TIMEOUT_MS) })
      try { post(window.parent, { channel: CHANNEL, kind: 'request', id, direction, startedAt }) }
      catch { finish(false) }
    })
  }
  const message = (event: MessageEvent): void => {
    const data = event.data as Record<string, unknown> | null
    if (!event.isTrusted || !data || typeof data !== 'object' || data.channel !== CHANNEL || typeof data.id !== 'string' || !/^[a-f0-9]{32}$/.test(data.id)) return
    if (data.kind === 'reply') {
      if (event.source !== window.parent || typeof data.allowed !== 'boolean') return
      const request = pending.get(data.id)
      if (!request) return
      event.stopImmediatePropagation()
      request.finish(data.allowed)
      return
    }
    if (data.kind !== 'request' || (data.direction !== 'back' && data.direction !== 'forward') || typeof data.startedAt !== 'number' || !Number.isFinite(data.startedAt) || data.startedAt > Date.now() + 1000) return
    for (const root of shadowRoots.keys()) {
      if (!root.host.isConnected) {
        root.removeEventListener('scroll', scroll, true)
        shadowRoots.delete(root)
      }
    }
    const frame = sourceFrame(event.source, root => {
      if (shadowRoots.has(root)) return
      shadowRoots.set(root, Date.now())
      root.addEventListener('scroll', scroll, true)
    })
    if (!frame) return
    // isTrusted alone does not authenticate postMessage. The unpredictable ID,
    // exact parent/child source and this early capture listener keep policy
    // replies private from page-world listeners. No message navigates history.
    event.stopImmediatePropagation()
    const source = event.source as Window, id = data.id, direction = data.direction, startedAt = data.startedAt
    void (async () => {
      const allowed = allows(frame, direction, startedAt) && await checkParents(direction, startedAt) && allows(frame, direction, startedAt)
      try { post(source, { channel: CHANNEL, kind: 'reply', id, allowed }) } catch { /* Detached child: its request times out. */ }
    })()
  }
  const scroll = (event: Event): void => {
    if (!event.isTrusted) return
    const target = event.target === document ? document.scrollingElement : event.target
    if (target) scrollTimes.set(target, Date.now())
  }
  const suspend = (): void => {
    active = false
    for (const request of pending.values()) request.finish(false)
  }
  const resume = (): void => { active = true }
  window.addEventListener('message', message, true)
  document.addEventListener('scroll', scroll, true)
  window.addEventListener('pagehide', suspend)
  window.addEventListener('pageshow', resume)
  return {
    checkParents: window.parent === window ? undefined : checkParents,
    dispose: () => {
      suspend()
      window.removeEventListener('message', message, true)
      document.removeEventListener('scroll', scroll, true)
      for (const root of shadowRoots.keys()) root.removeEventListener('scroll', scroll, true)
      shadowRoots.clear()
      window.removeEventListener('pagehide', suspend)
      window.removeEventListener('pageshow', resume)
    }
  }
}
