// Production tool/provider/palette and original DrawingLayer/useDrawings.
// Only repository/native IPC are fixtures. No physical Pencil claims.
import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { PdfInputProvider, usePdfInputStoreApi } from './PdfInputStore'
import { PdfInputToolbar } from './PdfPalette'
import { installMarkdownInputPolicy, mayAutoFocusMarkdown } from './markdown'
import { installScribblePolicy } from '../../pencil/scribble'
import { useDrawings } from '../../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { DrawingLayer } from '../../../upstream/src/renderer/src/features/pdf/tools/DrawingLayer'
import { usePdfToolStore } from '../../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import type { Drawing } from '../../../upstream/src/shared/types/drawing'
import type { StoreApi } from 'zustand/vanilla'
import type { PdfInputState } from './PdfInputStore'
const calls: Array<{ channel: string; payload: Record<string, unknown> }> = [], saved: Drawing[] = []
let sequence = 0, deferred = false
let failSurfaceAfter = -1
const acknowledgements: Array<() => void> = []
const drawingReplies: Array<() => void> = []
const fixturePath = (id: string): string => new URLSearchParams(location.search).has('sharedPDF') ? 'shared.pdf' : `${id}.pdf`
const stores = new Map<string, StoreApi<PdfInputState>>()
const trace = { calls, saved, stores, regions: [] as unknown[], actions: [] as string[], operationErrors: [] as Array<{ operation: string; retry(): Promise<void> }>,
  drawingLoadAttempts: 0,
  defer: (value: boolean) => { deferred = value }, waiting: () => acknowledgements.length,
  failSurfaceAfter: (successes: number) => { failSurfaceAfter = successes },
  ack: () => acknowledgements.splice(0).forEach(done => done()),
  waitingDrawings: () => drawingReplies.length, acknowledgeDrawings: () => drawingReplies.splice(0).forEach(done => done()),
  legacy: () => usePdfToolStore.getState(), mayAutoFocusMarkdown }
Object.assign(window, { inputFixture: trace, bandal: { platform: 'ipad', invoke: async (channel: string, payload: Record<string, unknown>) => {
  calls.push({ channel, payload: structuredClone(payload) })
  if (channel === 'runtime:nativeSurfaceSession') return { sessionId: 'input-fixture' }
  if (channel === 'runtime:nativeSurfaces') {
    if (failSurfaceAfter === 0) { failSurfaceAfter = -1; throw new Error('fixture geometry ACK failure') }
    if (failSurfaceAfter > 0) failSurfaceAfter--
    if (deferred) await new Promise<void>(resolve => acknowledgements.push(resolve))
    return { revision: payload.revision }
  }
  throw new Error(`Unexpected native IPC ${channel}`)
} } })
window.addEventListener('bandal:operation-error', event => trace.operationErrors.push((event as CustomEvent).detail))
setIpcAdapter({ invoke: async (channel: string, request: Record<string, unknown>) => {
  if (channel === 'drawings:listForFile') {
    trace.drawingLoadAttempts++
    if (new URLSearchParams(location.search).has('deferDrawings')) await new Promise<void>(resolve => drawingReplies.push(resolve))
    if (new URLSearchParams(location.search).has('failDrawings')) throw new Error('Fixture drawings load failed' +
      (new URLSearchParams(location.search).has('longDrawingsError') ? ' 긴 오류 세부사항'.repeat(100) : ''))
    return saved.filter(item => item.relPath === request.relPath)
  }
  if (channel === 'drawings:create') { const entry = { ...request, id: `saved-${++sequence}`, createdAt: '', updatedAt: '' } as unknown as Drawing; saved.push(entry); return entry }
  if (channel === 'drawings:delete') { const ids = request.ids as string[]; for (let index=saved.length-1; index>=0; index--) if (ids.includes(saved[index]!.id)) saved.splice(index,1); return {} }
  if (channel === 'pdf:exportAnnotated') { trace.actions.push('export'); return { savedPath: '/fixture/export.pdf' } }
  throw new Error(`Unexpected repository IPC ${channel}`)
}, on: () => () => undefined } as IpcAdapter)
usePdfToolStore.getState().setActiveTool('eraser'); usePdfToolStore.getState().setColor('violet')
usePdfToolStore.getState().recordHistory('existing-whiteboard', { kind: 'remove', drawings: [] })
installMarkdownInputPolicy()
installScribblePolicy(document, async value => { trace.regions.push(value) })

function PDF({ id, active }: { id: string; active: boolean }): JSX.Element {
  const drawings = useDrawings('fixture', fixturePath(id)), store = usePdfInputStoreApi()
  useEffect(() => { stores.set(id, store); return () => { stores.delete(id) } }, [id, store])
  return <div className="pdf-tab">
    <PdfInputToolbar currentPage={1} numPages={3} zoomPercent={100} isPreviewOpen={false} isRailOpen={false} annotationCount={0}
      courseId="fixture" relPath={fixturePath(id)} drawingsApi={drawings} onJumpToPage={page => trace.actions.push(`page:${page}`)}
      onZoomIn={() => trace.actions.push('zoom-in')} onZoomOut={() => trace.actions.push('zoom-out')} onZoomFit={() => trace.actions.push('fit')}
      onTogglePreview={() => trace.actions.push('preview')} onToggleRail={() => trace.actions.push('rail')}
      onOpenPageNotes={() => trace.actions.push('notes')} pageNoteCount={0} pageNotePaired={false} pageNoteSyncEnabled={false} onTogglePageNoteSync={() => undefined} />
    <div className="pdf-scroller" data-panel={id}>
      <div className="pdf-page" data-pdf-page="1"><DrawingLayer courseId="fixture" relPath={fixturePath(id)} page={1}
        pageWidth={600} pageWidthPt={600} aspect={1.4} drawings={drawings.drawings} loading={drawings.loading} interactive={active}
        create={drawings.create} update={drawings.update} refine={drawings.refine} remove={drawings.remove} resolveId={drawings.resolveId} /></div>
    </div>
  </div>
}
function Fixture(): JSX.Element {
  const [active, setActive] = useState('a'), [generation, setGeneration] = useState(0)
  return <>
    <nav><button onClick={() => setActive('a')}>Focus A</button><button onClick={() => setActive('b')}>Focus B</button><button onClick={() => setGeneration(value => value+1)}>Reopen A</button></nav>
    <main>{['a','b'].map(id => <section key={id} data-fixture-panel={id}>
      <PdfInputProvider key={id === 'a' ? generation : id} panelId={id} active={active===id} visible onActivate={() => setActive(id)}><PDF id={id} active={active===id} /></PdfInputProvider>
    </section>)}</main>
    <div className="note-tab"><div className="note-editor" data-ipad-markdown-body="true"><div role="textbox" contentEditable suppressContentEditableWarning aria-label="Markdown fixture">Markdown text</div><a href="#ignored">Markdown link</a></div></div>
  </>
}
const style = document.createElement('style')
style.textContent = 'body{margin:0;font-family:system-ui;background:#e9ecf0}nav{height:50px;display:flex;gap:20px}nav button{min-height:44px}main{display:flex;gap:10px;height:650px;padding:0 10px}main>section{width:calc(50% - 5px);min-width:0}.pdf-tab{height:100%;position:relative}.pdf-scroller{height:100%;overflow:auto}.pdf-page{width:600px;height:840px;background:white;position:relative}.ink-layer{width:600px;height:840px;display:block}.note-tab{margin:16px;background:white}.note-editor{padding:15px;min-height:120px}[contenteditable]{min-height:75px;outline:1px solid #999}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
