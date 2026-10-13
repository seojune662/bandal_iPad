// The production hook and original desktop popovers run unchanged. Only the
// native bridge is replaced: tests inspect the actual layout IPC it emits.
import { useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { createPortal } from 'react-dom'
import { useNativePDF } from './useNativePDF'
import type { NativePDFEvent, NativePDFTransport } from './types'
import { PdfToolRail } from '../../upstream/src/renderer/src/features/pdf/tools/PdfToolRail'
import { HighlightPopover } from '../../upstream/src/renderer/src/features/pdf/popovers'
import { useDrawings } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { usePdfToolStore } from '../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import { setIpcAdapter, type IpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import type { Annotation } from '../../upstream/src/shared/types/annotation'

let subscriber: ((event: NativePDFEvent) => void) | undefined
const trace = { calls: [] as Array<{ channel: string; payload: Record<string, unknown> }>, active: false, pointerEvents: 0,
  contact: () => {
    const identity = trace.calls.find(call => call.channel === 'pdfNative:open')?.payload
    if (identity) subscriber?.({ surfaceId: String(identity.surfaceId), generation: String(identity.generation), type: 'activate', payload: {} })
  } }
document.addEventListener('pointerdown', () => trace.pointerEvents++, true)
Object.assign(window, { nativeLayoutTrace: trace })
const transport: NativePDFTransport = {
  async invoke(channel, payload) {
    trace.calls.push({ channel, payload: structuredClone(payload) })
    if (channel === 'pdfNative:capabilities') return { enabled: true }
    if (channel === 'pdfNative:open') return { pending: [], pageSizes: [{ page: 1, width: 600, height: 900 }] }
    if (channel === 'pdfNative:flush') return { pending: [] }
    if (channel === 'pdfNative:pageGeometry') return { x: 0, y: 0, width: 600, height: 900 }
    return {}
  }, on: (_channel, listener) => { subscriber = listener; return () => { subscriber = undefined } }
}
Object.assign(window, { bandal: transport })
setIpcAdapter({ invoke: async channel => {
  if (channel === 'drawings:listForFile') return []
  throw new Error(`Unexpected fixture IPC ${channel}`)
}, on: () => () => undefined } as IpcAdapter)
usePdfToolStore.getState().setActiveTool('pen')
const annotation: Annotation = { id: 'highlight', courseId: 'fixture', relPath: 'fixture.pdf', page: 1, color: 'yellow',
  rects: [], anchor: { quote: 'A highlighted passage', prefix: '', suffix: '' }, comment: null, createdAt: '', updatedAt: '' }
function Fixture(): JSX.Element {
  const scroller = useRef<HTMLDivElement>(null), drawings = useDrawings('fixture', 'fixture.pdf')
  const [highlight, setHighlight] = useState(false), [modal, setModal] = useState(false)
  const native = useNativePDF({ panelId: 'fixture', courseId: 'fixture', relPath: 'fixture.pdf', visible: true, interactive: true,
    scroller, pdf: null, drawings, annotations: [], page: 1, zoom: 1, blocked: highlight,
    activeAnnotation: null, hoveredAnnotation: null, onViewport: () => undefined, onSelection: () => undefined,
    onReady: () => undefined, onAnnotation: () => undefined, onPageAction: () => undefined, onBodyTap: () => setHighlight(false), onActivate: () => undefined })
  trace.active = native.active
  return <>
    <nav><button onClick={() => setHighlight(true)}>Open highlight</button><button onClick={() => setModal(true)}>Open modal</button></nav>
    <PdfToolRail courseId="fixture" relPath="fixture.pdf" drawingsApi={drawings} />
    <div ref={scroller} className="pdf-scroller" style={{ position: 'absolute', left: 60, top: 60, width: 700, height: 650, overflow: 'auto' }}>
      <div data-pdf-page="1" data-native-pdf="true" style={{ width: 600, height: 900 }} />
      {highlight && <HighlightPopover annotation={annotation} position={{ left: 100, top: 150 }} isStale={false}
        onChangeColor={() => undefined} onSaveComment={() => undefined} onDelete={() => setHighlight(false)}
        onDismiss={() => setHighlight(false)} onAskAi={() => undefined} onSendToNote={() => undefined} />}
    </div>
    {modal && createPortal(<section role="dialog" aria-modal="true" aria-label="Settings fixture"
      style={{ position: 'fixed', top: 180, left: 200, width: 400, height: 300, zIndex: 500, background: 'white' }}>
      <button onClick={() => setModal(false)}>Close modal</button>
    </section>, document.body)}
  </>
}
const style = document.createElement('style')
style.textContent = '.pdf-tool-rail-shell{position:fixed;left:70px;top:65px;width:600px;z-index:10}.pdf-popover{position:absolute;width:300px;background:white;z-index:250}:root{--bg-overlay:white;--border-subtle:#ddd;--drawing-ink:#16171a;--drawing-red:red}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
