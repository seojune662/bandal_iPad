/** One owner registry for HTML above native PDF/browser surfaces. Coordinates
 * are viewport CSS pixels; Swift applies the same mask and hit-test geometry. */
export type NativeOverlayRect = { x: number; y: number; width: number; height: number }
type Invoke = (channel: string, request: Record<string, unknown>) => Promise<unknown>
const blockers = new Set<string>()
const inputOwners = new Set<string>()
const pendingReleases = new Map<string, number>()
const overlays = new Map<string, HTMLElement>()
const listeners = new Set<() => void>()
let session: Promise<string> | undefined
let revision = 0
let frame = 0
let flight: Promise<void> = Promise.resolve()
let observing = false
let lastSignature = ''
let modalBlocked = false

export const isNativeHostBlocked = (): boolean => blockers.size > 0 || modalBlocked
export function onNativeHostBlocked(listener: () => void): () => void {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}
function invoke(channel: string, request: Record<string, unknown>): Promise<unknown> {
  return (window.bandal.invoke as Invoke)(channel, request)
}
function nativeSession(): Promise<string> {
  if (!session) session = invoke('runtime:nativeSurfaceSession', {}).then(value => {
    const identifier = (value as { sessionId?: unknown })?.sessionId
    if (typeof identifier !== 'string' || !identifier) throw new Error('화면 연결을 준비하지 못했습니다.')
    return identifier
  }).catch(error => { session = undefined; throw error })
  return session
}
function report(error: unknown): void {
  window.dispatchEvent(new CustomEvent('bandal:operation-error', { detail: { reason: error, operation: '화면 표시 갱신', retry: flushNativeSurfaceLayout } }))
}
function visibleRect(element: HTMLElement): NativeOverlayRect | null {
  if (!element.isConnected || element.closest('[hidden], [inert]')) return null
  const style = getComputedStyle(element)
  if (style.display === 'none' || style.visibility === 'hidden') return null
  const rect = element.getBoundingClientRect()
  const left = Math.max(0, rect.left - 2), top = Math.max(0, rect.top - 2)
  const right = Math.min(window.innerWidth, rect.right + 2), bottom = Math.min(window.innerHeight, rect.bottom + 2)
  return rect.width > 0 && rect.height > 0 && right > left && bottom > top
    ? { x: left, y: top, width: right-left, height: bottom-top } : null
}
export function nativeOverlayRects(): NativeOverlayRect[] {
  // Include existing nonmodal desktop portals, whose lifetime is not owned by
  // the new iPad chrome. Explicit registrations cover floating UI and drawers.
  const elements = new Set([...overlays.values(), ...document.querySelectorAll<HTMLElement>(
    '.pdf-popover, .pdf-tool-popover, .context-menu, .page-image-menu, [data-bandal-native-overlay]')])
  return [...elements].flatMap(element => { const rect = visibleRect(element); return rect ? [rect] : [] }).slice(0, 128)
}
function observe(): void {
  if (observing) return
  observing = true
  const observer = new MutationObserver(schedule)
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true,
    attributeFilter: ['style', 'class', 'hidden', 'inert', 'data-open', 'aria-modal', 'data-bandal-native-overlay'] })
  window.addEventListener('resize', schedule)
  document.addEventListener('scroll', schedule, true)
  window.visualViewport?.addEventListener('resize', schedule)
  window.visualViewport?.addEventListener('scroll', schedule)
  // Full-document lifetime. A reload creates a new registry and host session.
}
function schedule(): void {
  if (frame) return
  frame = requestAnimationFrame(() => { frame = 0; void flushNativeSurfaceLayout().catch(report) })
}
export function flushNativeSurfaceLayout(): Promise<void> {
  observe()
  if (frame) { cancelAnimationFrame(frame); frame = 0 }
  const previous = isNativeHostBlocked()
  modalBlocked = [...document.querySelectorAll<HTMLElement>('[aria-modal="true"], .shell-settings-overlay[data-open="true"]')].some(element => visibleRect(element) !== null)
  if (previous !== isNativeHostBlocked()) for (const listener of [...listeners]) listener()
  const state = { blocked: isNativeHostBlocked(), inputBlocked: inputOwners.size > 0, overlays: nativeOverlayRects() }
  const signature = JSON.stringify(state)
  if (signature === lastSignature) return flight
  lastSignature = signature
  const sequence = ++revision
  // Serial delivery means releasing a drag cannot overtake its final mask.
  const next = flight.catch(() => undefined).then(async () => {
    const sessionId = await nativeSession()
    const reply = await invoke('runtime:nativeSurfaces', { sessionId, revision: sequence, ...state }) as { revision?: number }
    if (typeof reply?.revision !== 'number' || reply.revision < sequence) throw new Error('화면 배치 응답을 확인하지 못했습니다.')
    // Ended gestures belong to this registry, not to a dismissible error
    // notice. After a connection recovers, commit the latest geometry first,
    // then release only ended owners. Never await our own serial flight here.
    if (sequence === revision) {
      let changed = false
      for (const [token, required] of pendingReleases) if (required <= sequence) {
        inputOwners.delete(token); pendingReleases.delete(token); changed = true
      }
      if (changed) schedule()
    }
  })
  flight = next.catch(error => { lastSignature = ''; throw error })
  return flight
}
export function setNativeHostBlocked(owner: string, blocked: boolean): void {
  const previous = isNativeHostBlocked()
  if (blocked) blockers.add(owner)
  else blockers.delete(owner)
  if (previous !== isNativeHostBlocked()) for (const listener of [...listeners]) listener()
  void flushNativeSurfaceLayout().catch(report)
}
export function registerNativeOverlay(owner: string, element: HTMLElement): () => void {
  overlays.set(owner, element)
  const resize = new ResizeObserver(schedule); resize.observe(element)
  schedule()
  return () => {
    resize.disconnect()
    if (overlays.get(owner) === element) overlays.delete(owner)
    schedule()
  }
}
/** Wait for native acknowledgement before accepting a palette drag. The
 * release also waits for final geometry before restoring document input. */
export async function acquireNativeInput(owner: string): Promise<() => Promise<void>> {
  const token = `${owner}:${crypto.randomUUID()}`
  inputOwners.add(token)
  try { await flushNativeSurfaceLayout() }
  catch (error) { inputOwners.delete(token); void flushNativeSurfaceLayout().catch(report); throw error }
  let released = false
  return async () => {
    if (released) return
    if (inputOwners.has(token)) {
      pendingReleases.set(token, Number.MAX_SAFE_INTEGER)
      const geometry = flushNativeSurfaceLayout()
      pendingReleases.set(token, revision)
      await geometry
      inputOwners.delete(token); pendingReleases.delete(token)
    }
    await flushNativeSurfaceLayout()
    released = true
  }
}
