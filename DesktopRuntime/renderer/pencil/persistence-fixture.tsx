// Isolated browser test; never imported by the application.
import { useEffect } from 'react'
import { createRoot } from 'react-dom/client'
import { useDrawings, type DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { setIpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import { createCanvasSaveQueue } from '../../upstream/src/renderer/src/features/canvas/canvasSaveQueue'
import { createInkFlushRegistry, flushNativeInk, registerNativeInk } from './persistence'

const assert = (condition: unknown, message: string): void => { if (!condition) throw new Error(message) }
const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>(done => { resolve = done })
  return { promise, resolve }
}

export async function runPersistenceFixture(): Promise<string[]> {
  const passes: string[] = []
  const calls: Array<{ acknowledge: () => void }> = []
  const saved: unknown[] = []
  setIpcAdapter({
    on: () => () => undefined,
    invoke: (async (channel: string, request: object) => {
      if (channel === 'drawings:listForFile') return [...saved]
      if (channel === 'drawings:create') {
        const wait = deferred(); calls.push({ acknowledge: wait.resolve }); await wait.promise
        const result = { ...request, id: `saved-${saved.length}`, createdAt: '2026-10-14T00:00:00Z', updatedAt: '2026-10-14T00:00:00Z' }
        saved.push(result); return result
      }
      throw new Error(`unexpected channel ${channel}`)
    }) as never
  })
  let api!: DrawingsApi
  const mounted = deferred()
  function Editor() {
    api = useDrawings('fixture-course', 'lecture.pdf')
    useEffect(() => { mounted.resolve() }, [])
    return null
  }
  const container = document.createElement('div'); document.body.append(container)
  const root = createRoot(container); root.render(<Editor />); await mounted.promise
  const input = { courseId: 'fixture-course', relPath: 'lecture.pdf', page: 1, kind: 'stroke' as const,
    data: { points: [{ x: .1, y: .1, p: .2 }, { x: .2, y: .2, p: .8 }] },
    style: { color: 'ink', width: .003, opacity: 1 } }
  const first = api.create(input as never), second = api.create(input as never)
  await Promise.resolve(); assert(calls.length === 1, 'PDF serial queue should have only first IPC in flight')
  root.unmount()
  let finished = false
  const flush = flushNativeInk().then(result => { finished = true; return result })
  await Promise.resolve(); assert(!finished, 'flush must await the unmounted PDF queue')
  calls[0]!.acknowledge(); await first
  for (let turn = 0; calls.length < 2 && turn < 20; turn++) await Promise.resolve()
  assert(calls.length === 2, 'second original PDF save must begin after first acknowledgement')
  assert(!finished, 'flush must not complete at the first IPC reply')
  calls[1]!.acknowledge(); await second
  assert((await flush).ok && saved.length === 2, 'both completed strokes must be saved after unmount')
  passes.push('actual PDF hook serial IPC saves survive unmount and complete before lifecycle release')
  setIpcAdapter(null); container.remove()

  const queue = createCanvasSaveQueue(() => undefined)
  const close = registerNativeInk({ key: 'canvas-test', courseId: 'fixture-course', relPath: 'canvas:fixture' }, queue.flush)
  const image = deferred(), disk = deferred()
  let wrote = false
  void queue.prepare(async () => { await image.promise; void queue.enqueue(['image'], async () => { await disk.promise; wrote = true }) })
  let canvasDone = false
  const canvasFlush = flushNativeInk().then(result => { canvasDone = true; return result })
  close(); await Promise.resolve(); assert(!canvasDone, 'image preparation participates in original canvas queue')
  image.resolve(); await Promise.resolve(); await Promise.resolve()
  assert(!canvasDone && !wrote, 'canvas flush waits for prepared image to be persisted')
  disk.resolve(); assert((await canvasFlush).ok && wrote, 'canvas save must finish before release')
  passes.push('actual whiteboard preparation and shape queue remain registered after tab closes')

  const registry = createInkFlushRegistry()
  let failed = true
  const retire = registry.register({ key: 'failed', courseId: 'fixture-course', relPath: 'canvas:failed' }, async () => { if (failed) throw new Error('disk full') })
  retire(); const failure = await registry.flush()
  assert(!failure.ok && failure.pending[0]?.error === 'disk full', 'closed editor errors cannot be reported as success')
  failed = false; assert((await registry.flush()).ok, 'original queue retry can clear failed retired entry')
  passes.push('failed retired writes block release and successful retry clears the barrier')

  const racing = createInkFlushRegistry()
  const gate = deferred(); let writes = 0, committed = 0
  racing.register({ key: 'early', courseId: 'fixture-course', relPath: 'early.pdf' }, async () => { committed = writes })
  racing.register({ key: 'late', courseId: 'fixture-course', relPath: 'late.pdf' }, () => gate.promise)
  const globalFlush = racing.flush(); await Promise.resolve()
  writes++; racing.changed(); gate.resolve()
  assert((await globalFlush).ok && committed === 1, 'global flush must revisit a queue edited while waiting for another queue')
  passes.push('edits across multiple surfaces require a globally stable save revision')
  return passes
}
