type Rect = { x: number; y: number; width: number; height: number }
export type ScribbleRegions = { revision: number; viewport: { width: number; height: number }; protected: Rect[]; editors: Rect[]; controls: Rect[] }
const controlsSelector = '.pdf-tool-rail-shell, .pdf-tool-popover, .pdf-toolbar button, .pdf-toolbar input[type="range"], .ipad-pdf-palette, .ipad-pdf-popover button, .ipad-pdf-popover input[type="range"]'
const protectedSelector = `.ink-layer, .pdf-toolbar, ${controlsSelector}, [data-bandal-native-pdf], [data-native-pdf="true"], [data-bandal-native-overlay], [data-ipad-markdown-body], .note-tab .note-editor`
const controlSelector = '.pdf-tool-rail-shell button, .pdf-toolbar button, .pdf-tool-popover button, .ipad-pdf-palette button:not([data-ipad-palette-drag]), .ipad-pdf-popover button'
const editorSelector = '.ink-layer[data-bandal-ink-tool="text"] .ink-layer__textbox-editor [contenteditable="true"], .pdf-toolbar__page-input:not(:disabled):not([readonly])'
// Selecting an existing text object also opens a keyboard editor. That does
// not grant Scribble permission: handwriting remains a text-tool-only action.
const keyboardEditorSelector = '.ink-layer:is([data-bandal-ink-tool="text"], [data-bandal-ink-tool="select"]) .ink-layer__textbox-editor [contenteditable="true"]'

/** Publish geometry only. Never send text, input values or document identities. */
export function scribbleRegions(document: Document, revision: number): ScribbleRegions {
  const view = document.defaultView!
  const rect = (element: Element): Rect[] => {
    const bounds = element.getBoundingClientRect()
    const x = Math.max(0, bounds.left), y = Math.max(0, bounds.top)
    const width = Math.min(view.innerWidth, bounds.right) - x, height = Math.min(view.innerHeight, bounds.bottom) - y
    return width > 0 && height > 0 && view.getComputedStyle(element).visibility !== 'hidden'
      ? [{ x, y, width, height }] : []
  }
  return { revision, viewport: { width: view.innerWidth, height: view.innerHeight },
    protected: [...document.querySelectorAll(protectedSelector)].flatMap(rect).slice(0, 512),
    editors: [...document.querySelectorAll(editorSelector)].flatMap(rect).slice(0, 64),
    controls: [...document.querySelectorAll(controlsSelector)].flatMap(rect).slice(0, 512) }
}

export function installScribblePolicy(document: Document = window.document,
  publish: (value: ScribbleRegions) => Promise<unknown> = value => window.webkit!.messageHandlers!.bandal!.postMessage({ channel: 'runtime:scribbleRegions', request: value })): () => void {
  const view = document.defaultView!
  let frame = 0, revision = 0, last = '', disposed = false
  const observed = new Set<Element>()
  let control: { id: number; button: HTMLButtonElement } | undefined
  const flush = (): void => {
    frame = 0
    // The native editor's SVG projection and its size can change without a
    // window resize. Track the real regions, not just documentElement's size.
    const current = new Set(document.querySelectorAll(`${protectedSelector}, ${editorSelector}`))
    for (const element of observed) if (!current.has(element)) { resize.unobserve(element); observed.delete(element) }
    for (const element of current) if (!observed.has(element)) { resize.observe(element); observed.add(element) }
    const value = scribbleRegions(document, ++revision)
    if (control) value.editors = []
    const signature = JSON.stringify({ ...value, revision: 0 })
    if (signature === last) return
    last = signature
    void publish(value).catch(() => { last = '' })
  }
  const schedule = (): void => { if (!disposed && !frame) frame = view.requestAnimationFrame(flush) }
  const observer = new MutationObserver(schedule)
  observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true,
    attributeFilter: ['class', 'style', 'transform', 'hidden', 'data-bandal-ink-tool', 'contenteditable'] })
  const resize = new ResizeObserver(schedule)
  resize.observe(document.documentElement)
  let lastActivation: { button: HTMLButtonElement; until: number } | undefined
  const down = (event: PointerEvent): void => {
    if (event.pointerType !== 'pen') lastActivation = undefined
    if (event.pointerType !== 'pen' || !(event.target instanceof Element)) return
    const button = event.target.closest<HTMLButtonElement>(controlSelector)
    if (!button || button.disabled) return
    // A Pencil button press owns the whole gesture; it cannot begin a stroke
    // on the underlying document or focus a nearby text editor.
    event.preventDefault(); event.stopImmediatePropagation()
    const focused = document.activeElement
    if (focused instanceof HTMLElement && focused.matches('input, textarea, [contenteditable="true"]')) focused.blur()
    control = { id: event.pointerId, button }
    try { button.setPointerCapture(event.pointerId) } catch { /* Synthetic fixture pointer. */ }
    view.cancelAnimationFrame(frame); flush()
  }
  const move = (event: PointerEvent): void => {
    if (control?.id === event.pointerId) { event.preventDefault(); event.stopImmediatePropagation() }
  }
  const end = (event: PointerEvent): void => {
    if (!control || event.pointerId !== control.id) return
    const { button } = control
    control = undefined
    event.preventDefault(); event.stopImmediatePropagation()
    try { button.releasePointerCapture(event.pointerId) } catch { /* Capture already ended. */ }
    const bounds = button.getBoundingClientRect()
    if (event.type !== 'pointercancel' && button.isConnected && !button.disabled &&
      event.clientX >= bounds.left && event.clientX <= bounds.right && event.clientY >= bounds.top && event.clientY <= bounds.bottom) {
      lastActivation = { button, until: view.performance.now() + 800 }
      button.click() // Preserve the original React action and its single owner.
    }
    schedule()
  }
  const click = (event: MouseEvent): void => {
    if (event.isTrusted && lastActivation && view.performance.now() < lastActivation.until &&
      event.target instanceof Node && lastActivation.button.contains(event.target)) {
      event.preventDefault(); event.stopImmediatePropagation()
      lastActivation = undefined
    }
  }
  const beforeInput = (event: Event): void => {
    if (!(event.target instanceof Element)) return
    const layer = event.target.closest('.ink-layer')
    if (layer && (control || !event.target.closest(keyboardEditorSelector))) event.preventDefault()
  }
  document.addEventListener('pointerdown', down, true)
  document.addEventListener('pointermove', move, true)
  document.addEventListener('pointerup', end, true)
  document.addEventListener('pointercancel', end, true)
  document.addEventListener('click', click, true)
  document.addEventListener('beforeinput', beforeInput, true)
  document.addEventListener('scroll', schedule, true)
  view.addEventListener('resize', schedule)
  view.visualViewport?.addEventListener('resize', schedule)
  view.visualViewport?.addEventListener('scroll', schedule)
  schedule()
  return () => {
    disposed = true; observer.disconnect(); resize.disconnect(); view.cancelAnimationFrame(frame)
    document.removeEventListener('pointermove', move, true)
    document.removeEventListener('pointerdown', down, true); document.removeEventListener('pointerup', end, true)
    document.removeEventListener('pointercancel', end, true); document.removeEventListener('click', click, true)
    document.removeEventListener('beforeinput', beforeInput, true); document.removeEventListener('scroll', schedule, true)
    view.removeEventListener('resize', schedule)
    view.visualViewport?.removeEventListener('resize', schedule)
    view.visualViewport?.removeEventListener('scroll', schedule)
  }
}
