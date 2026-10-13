import type { PptxPresentation, PptxTextRunInfo } from '@silurus/ooxml/pptx'

interface RenderedSlide {
  canvas: HTMLCanvasElement
  runs: PptxTextRunInfo[]
}

interface Entry {
  promise: Promise<RenderedSlide>
  consumers: Set<AbortSignal>
  bytes: number
}

/** Two in-flight slide renders across all open viewers and clipboard jobs. */
let running = 0
const queue: (() => void)[] = []
const retained = new Map<Entry, () => void>()
const WINDOW_BUDGET = 64 * 1024 * 1024
function schedule<T>(work: () => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const run = (): void => {
      running++
      void work().then(resolve, reject).finally(() => {
        running--
        queue.shift()?.()
      })
    }
    if (running < 2) run()
    else queue.push(run)
  })
}

/** Bounded, per-deck LRU. Unmounted pages withdraw work before it starts. */
export class SlideRenderCache {
  private entries = new Map<string, Entry>()
  private disposed = false

  constructor(private presentation: PptxPresentation, private budget = 24 * 1024 * 1024) {}

  render(index: number, width: number, dpr: number, signal: AbortSignal): Promise<RenderedSlide> {
    const key = `${index}:${width}:${dpr}`
    let entry = this.entries.get(key)
    if (entry) {
      this.entries.delete(key)
      this.entries.set(key, entry)
      if (!entry.bytes) entry.consumers.add(signal)
      const evict = retained.get(entry)
      if (evict) { retained.delete(entry); retained.set(entry, evict) }
      return entry.promise
    }
    const consumers = new Set([signal])
    const alive = (): boolean => !this.disposed && [...consumers].some((consumer) => !consumer.aborted)
    const promise = schedule(async () => {
      if (!alive()) throw new DOMException('Slide no longer visible', 'AbortError')
      const runs: PptxTextRunInfo[] = []
      const bitmap = await this.presentation.renderSlideToBitmap(index, {
        width, dpr, onTextRun: (run) => runs.push(run)
      })
      try {
        if (!alive()) throw new DOMException('Slide no longer visible', 'AbortError')
        const canvas = document.createElement('canvas')
        canvas.width = bitmap.width
        canvas.height = bitmap.height
        const context = canvas.getContext('2d')
        if (!context) throw new Error('슬라이드 이미지를 만들지 못했어요.')
        context.drawImage(bitmap, 0, 0)
        return { canvas, runs }
      } finally {
        bitmap.close()
      }
    })
    entry = { promise, consumers, bytes: 0 }
    this.entries.set(key, entry)
    const pending = entry
    void promise.then(({ canvas }) => {
      consumers.clear()
      if (this.disposed || this.entries.get(key) !== pending) return
      pending.bytes = canvas.width * canvas.height * 4
      retained.set(pending, () => this.entries.delete(key))
      let bytes = [...this.entries.values()].reduce((sum, value) => sum + value.bytes, 0)
      for (const [oldKey, old] of this.entries) {
        if (bytes <= this.budget) break
        if (old.bytes === 0) continue
        bytes -= old.bytes
        this.entries.delete(oldKey)
        retained.delete(old)
      }
      let total = [...retained.keys()].reduce((sum, value) => sum + value.bytes, 0)
      for (const [old, evict] of retained) {
        if (total <= WINDOW_BUDGET) break
        total -= old.bytes
        evict()
        retained.delete(old)
      }
    }, () => {
      if (this.entries.get(key) === pending) this.entries.delete(key)
    })
    return promise
  }

  dispose(): void {
    this.disposed = true
    for (const entry of this.entries.values()) retained.delete(entry)
    this.entries.clear()
  }
}
