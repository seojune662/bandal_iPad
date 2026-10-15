const BODY = '[data-ipad-markdown-body], .note-tab .note-editor'
let fingerIntent: { body: Element; time: number } | undefined

export function mayAutoFocusMarkdown(root: HTMLElement): boolean {
  const body = root.closest(BODY)
  return !!body && fingerIntent?.body === body && performance.now() - fingerIntent.time < 5000 &&
    root.getClientRects().length > 0 && !root.closest('[hidden]')
}

/** Let the browser finish its own composition on blur before the note's
 * existing deactivation flush reads the editor. Never synthesize IME events. */
export function deactivateMarkdownInput(root: HTMLElement | null): void {
  if (!root) return
  if (fingerIntent && root.contains(fingerIntent.body)) fingerIntent = undefined
  const active = root.ownerDocument.activeElement
  if (active instanceof HTMLElement && root.contains(active) && active.closest(BODY)) active.blur()
}

/** Native paper contact has no DOM pointerdown. Move keyboard ownership too. */
export function focusPdfInputSurface(scroller: HTMLElement | null): void {
  fingerIntent = undefined
  if (!scroller) return
  const active = scroller.ownerDocument.activeElement
  if (active instanceof HTMLElement && scroller.contains(active) && active.matches('input, textarea, [contenteditable="true"]')) return
  scroller.tabIndex = -1
  scroller.focus({ preventScroll: true })
}

/** Pencil is ignored by Markdown; ordinary text/IME events are never canceled. */
export function installMarkdownInputPolicy(document: Document = window.document): () => void {
  const view = document.defaultView!
  const owned = new Set<number>()
  let suppress: { body: Element; until: number } | undefined
  const bodyFor = (target: EventTarget | null): Element | null => target instanceof Element ? target.closest(BODY) : null
  const block = (event: Event): void => { if (event.cancelable) event.preventDefault(); event.stopImmediatePropagation() }
  const pointer = (event: PointerEvent): void => {
    const body = bodyFor(event.target)
    if (event.type === 'pointerdown' && event.pointerType !== 'pen') {
      suppress = undefined
      fingerIntent = event.pointerType === 'touch' && body ? { body, time: performance.now() } : undefined
    }
    if (event.type === 'pointerdown' && event.pointerType === 'pen' && body) {
      owned.add(event.pointerId); suppress = { body, until: performance.now() + 1000 }
    }
    if (!owned.has(event.pointerId)) return
    block(event)
    if (suppress) suppress.until = performance.now() + 1000
    if (event.type === 'pointerup' || event.type === 'pointercancel') owned.delete(event.pointerId)
  }
  const compatibility = (event: Event): void => {
    if (suppress && performance.now() < suppress.until && bodyFor(event.target) === suppress.body) block(event)
  }
  const touch = (event: TouchEvent): void => {
    if (![...event.changedTouches].some(contact => (contact as Touch & { touchType?: string }).touchType === 'stylus')) return
    const body = bodyFor(event.target)
    if (body) { suppress = { body, until: performance.now() + 1000 }; block(event) }
  }
  for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) document.addEventListener(type, pointer as EventListener, true)
  for (const type of ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'selectstart']) document.addEventListener(type, compatibility, true)
  for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) document.addEventListener(type, touch as EventListener, { capture: true, passive: false })
  const blur = (): void => { owned.clear(); suppress = undefined; fingerIntent = undefined }
  view.addEventListener('blur', blur)
  return () => {
    for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) document.removeEventListener(type, pointer as EventListener, true)
    for (const type of ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'selectstart']) document.removeEventListener(type, compatibility, true)
    for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) document.removeEventListener(type, touch as EventListener, true)
    view.removeEventListener('blur', blur); blur()
  }
}
