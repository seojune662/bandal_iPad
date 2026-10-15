// Tests the real InkLayer + useDrawings, with only disk IPC delayed.
import { useEffect } from 'react'
import { createRoot } from 'react-dom/client'
import { InkLayer } from '../../upstream/src/renderer/src/features/ink/InkLayer'
import { useDrawings, type DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { setIpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import { flushNativeInk } from './persistence'

const check = (condition: unknown, message: string): void => { if (!condition) throw new Error(message) }
const frame = (): Promise<void> => new Promise(resolve => requestAnimationFrame(() => resolve()))

async function raster(svg: SVGSVGElement): Promise<Uint8ClampedArray> {
  const copy = svg.cloneNode(true) as SVGSVGElement
  copy.setAttribute('xmlns', 'http://www.w3.org/2000/svg')
  copy.setAttribute('width', '600'); copy.setAttribute('height', '900')
  // Resolve the theme token for an isolated, deterministic alpha fixture.
  for (const node of copy.querySelectorAll('[fill]')) if (node.getAttribute('fill')?.startsWith('var(')) node.setAttribute('fill', '#000')
  const image = new Image()
  image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(copy))
  await image.decode()
  const canvas = document.createElement('canvas'); canvas.width = 600; canvas.height = 900
  const context = canvas.getContext('2d')!
  context.fillStyle = '#fff'; context.fillRect(0, 0, 600, 900)
  context.drawImage(image, 0, 0)
  return context.getImageData(0, 0, 600, 900).data
}

export async function runHandoffFixture(): Promise<string> {
  let release!: () => void
  const pending = new Promise<void>(resolve => { release = resolve })
  let writes = 0, saved = false
  let api!: DrawingsApi
  setIpcAdapter({ on: () => () => undefined, invoke: (async (channel: string, input: object) => {
    if (channel === 'drawings:listForFile') return []
    if (channel === 'drawings:create') {
      writes++; await pending; saved = true
      return { ...input, id: 'written-ink', createdAt: '', updatedAt: '' }
    }
    throw new Error(`Unexpected IPC ${channel}`)
  }) as never })
  const host = document.createElement('div'); document.body.append(host)
  let ready!: () => void
  const mounted = new Promise<void>(resolve => { ready = resolve })
  function Editor(): JSX.Element {
    api = useDrawings('handoff-course', 'handoff.pdf')
    useEffect(() => { ready() }, [])
    return <InkLayer aspect={1.5} baseWidthPx={600} shapes={api.drawings} ariaLabel="Delayed PDF ink handoff"
      tool={{ activeTool: 'highlighter', color: 'ink', width: 0.03, opacity: 0.3 }}
      onCreate={input => { void api.create({ ...input, courseId: 'handoff-course', relPath: 'handoff.pdf', page: 1 }) }}
      onUpdate={() => undefined} onRemove={() => undefined} />
  }
  const root = createRoot(host)
  try {
    root.render(<Editor />); await mounted; await frame()
    const svg = host.querySelector('svg')!
    svg.style.width = '600px'; svg.style.height = '900px'
    svg.setPointerCapture = () => undefined
    const rect = svg.getBoundingClientRect()
    const send = (type: string, x: number): void => { svg.dispatchEvent(new PointerEvent(type, {
      bubbles: true, pointerId: 180, pointerType: 'pen', clientX: rect.left + x, clientY: rect.top + 220,
      pressure: 0.6, buttons: type === 'pointerup' ? 0 : 1
    })) }
    send('pointerdown', 50)
    for (let i = 1; i <= 96; i++) send('pointermove', 50 + i * 5)
    await frame()
    const live = await raster(svg)
    // Preserve the entire edge coverage through the optimistic handoff, not
    // just the fully covered centerline where separate-fill seams are hidden.
    const center = (pixels: Uint8ClampedArray, x: number): number => pixels[(220 * 600 + x) * 4]!
    for (let x = 60; x <= 520; x++) check(Math.abs(center(live, x) - 178) <= 1,
      `Highlighter opacity must be uniform, x=${x}, value=${center(live, x)}`)
    send('pointerup', 530)
    check(svg.querySelector('[data-ink-measured]'), 'Measured preview must survive until the React commit')
    await frame(); await frame()
    check(writes === 1 && !saved, 'Disk must still be delayed during the optimistic handoff')
    check(svg.querySelectorAll('.ink-layer__mark').length === 1, 'One canonical optimistic stroke must be visible while disk waits')
    check(!svg.querySelector('[data-ink-measured]'), 'The same commit must remove the transient preview')
    const optimistic = await raster(svg)
    for (let i = 0; i < live.length; i++) check(optimistic[i] === live[i], `Handoff coverage changed at channel ${i}`)
    release(); await api.flush?.(); await frame()
    check(svg.querySelectorAll('.ink-layer__mark').length === 1, 'Acknowledgement must replace the optimistic ID without duplicating ink')
    const committed = await raster(svg)
    for (let i = 0; i < live.length; i++) check(committed[i] === live[i], `Saved coverage changed at channel ${i}`)
    return 'WebKit raster: exact full-image measured → optimistic → saved handoff during delayed disk IPC'
  } finally {
    release(); await flushNativeInk(); root.unmount(); host.remove(); setIpcAdapter(null)
  }
}
