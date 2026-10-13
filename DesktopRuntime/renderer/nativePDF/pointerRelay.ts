/** Pencil input for the desktop's object editors only. Pen/highlighter never
 * enter this path: their live rendering and page coordinates stay native. */
const nativeEvents = new WeakSet<Event>()
export function captureNativePDFPointer(element: Element, pointerId: number, event: Event): void {
  if (!nativeEvents.has(event)) element.setPointerCapture(pointerId)
}
interface Point { x: number; y: number; p: number }
interface Input { phase: 'down' | 'move' | 'up' | 'cancel'; page: number; points: Point[] }
let nextPointer = 1_000_000

export class NativePDFPointerRelay {
  private active: { id: number; page: number; target: Element; svg: SVGSVGElement; start: Point; moved: boolean } | null = null
  private lastTap: { page: number; x: number; y: number; time: number } | null = null
  private queued: Input[] = []
  private frame = 0
  private disposed = false
  constructor(private root: () => HTMLElement | null, private enterTextTool: () => void = () => {}) {}
  accept(input: Input): void {
    if (this.disposed || !['down', 'move', 'up', 'cancel'].includes(input.phase) || !Number.isInteger(input.page)
      || !Array.isArray(input.points) || input.points.some(p => !p || ![p.x, p.y, p.p].every(Number.isFinite))) return
    this.queued.push(input); this.flush()
  }
  private flush(): void {
    cancelAnimationFrame(this.frame)
    while (this.queued.length) {
      const input = this.queued[0]!
      const page = this.root()?.querySelector<HTMLElement>(`[data-pdf-page="${input.page}"]`)
      const svg = page?.querySelector<SVGSVGElement>('svg.ink-layer')
      if (!page || !svg) { this.frame = requestAnimationFrame(() => this.flush()); return }
      this.queued.shift()
      const bounds = svg.getBoundingClientRect()
      if (!bounds.width || !bounds.height) continue
      if (input.phase === 'down') {
        const first = input.points[0]; if (!first) continue
        const target = document.elementFromPoint(bounds.left + first.x * bounds.width, bounds.top + first.y * bounds.height)
        this.active = { id: nextPointer++, page: input.page, target: target && svg.contains(target) ? target : svg, svg, start: first, moved: false }
      }
      const active = this.active
      if (!active || active.page !== input.page) continue
      const samples = input.phase === 'down' ? input.points.slice(0, 1) : input.points
      for (const point of samples) {
        if (Math.hypot((point.x-active.start.x)*bounds.width, (point.y-active.start.y)*bounds.height) > 6) active.moved = true
        const type = `pointer${input.phase === 'down' ? 'down' : input.phase === 'up' ? 'up' : input.phase === 'cancel' ? 'cancel' : 'move'}`
        const event = new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: active.id, pointerType: 'pen', isPrimary: true,
          button: 0, buttons: input.phase === 'up' || input.phase === 'cancel' ? 0 : 1,
          clientX: bounds.left + point.x * bounds.width, clientY: bounds.top + point.y * bounds.height, pressure: point.p })
        nativeEvents.add(event)
        // React's object manipulation handlers live on the picked shape; the
        // SVG root then receives move/end through bubbling without synthetic
        // pointer capture, which WebKit correctly refuses for fabricated IDs.
        const target = active.target.isConnected ? active.target : svg
        target.dispatchEvent(event)
        if (input.phase === 'up' && !active.moved) {
          const time = performance.now(), previous = this.lastTap
          if (previous && previous.page === active.page && time-previous.time < 350 &&
              Math.hypot((point.x-previous.x)*bounds.width, (point.y-previous.y)*bounds.height) <= 12) {
            const textbox = target.closest('.ink-layer__textbox-group, .ink-layer__textbox-object, .ink-layer__textbox-hit-target')
            const doubleClick = (): void => {
              if (this.disposed || !target.isConnected) return
              target.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, detail: 2,
                clientX: bounds.left+point.x*bounds.width, clientY: bounds.top+point.y*bounds.height }))
            }
            if (textbox && svg.dataset.bandalInkTool !== 'text') {
              this.enterTextTool()
              // Original InkLayer finishes its previous text session on a
              // tool transition. Start editing after that layout effect so
              // it cannot immediately close the newly opened editor.
              requestAnimationFrame(doubleClick)
            } else doubleClick()
            this.lastTap = null
          } else this.lastTap = { page: active.page, x: point.x, y: point.y, time }
        } else if (input.phase === 'cancel' || active.moved) this.lastTap = null
        if (input.phase === 'up' || input.phase === 'cancel') break
      }
      if (input.phase === 'up' || input.phase === 'cancel') this.active = null
    }
  }
  dispose(): void { this.disposed = true; cancelAnimationFrame(this.frame); this.queued = []; this.active = null; this.lastTap = null }
}
