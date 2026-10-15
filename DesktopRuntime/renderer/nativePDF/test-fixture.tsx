// The real desktop InkLayer/useDrawings execute here. Only disk IPC is mocked.
import { useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { InkLayer } from '../../upstream/src/renderer/src/features/ink/InkLayer'
import { useDrawings } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { setIpcAdapter, type IpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import type { Drawing, CreateDrawingInput, UpdateDrawingInput } from '../../upstream/src/shared/types/drawing'
import type { InkTool } from '../../upstream/src/renderer/src/features/ink/inkToolStore'
import { NativePDFPointerRelay } from './pointerRelay'
import { NativePDFEditorGeometry, type PDFFrame } from './editorGeometry'
import { NativePDFSession } from './session'
import type { JournaledDrawingInput } from './types'
import type { NativeObjectScene } from './objectScene'
import { nativePDFDrawingPayload } from './drawingPayload'
import { strokePath } from '../../upstream/src/renderer/src/features/ink/inkGeometry'
import '../../upstream/src/renderer/src/features/pdf/tools/pdfTools.css'

const state = { rows: [] as Drawing[], creates: 0, updates: 0, deletes: 0, scenes: [] as NativeObjectScene[], exports: [] as Drawing[][] }
const api = {
  invoke: async (channel: string, request: unknown): Promise<unknown> => {
    if (channel === 'drawings:listForFile') return [...state.rows]
    if (channel === 'drawings:create') {
      const now = new Date().toISOString()
      const row = { ...request as CreateDrawingInput, id: crypto.randomUUID(), createdAt: now, updatedAt: now }
      state.rows.push(row); state.creates++; return row
    }
    if (channel === 'drawings:update') {
      const input = request as UpdateDrawingInput, row = state.rows.find(row => row.id === input.id)
      if (!row) throw new Error('Missing fixture row')
      const updated = { ...row, ...input }
      state.rows = state.rows.map(current => current.id === input.id ? updated : current)
      state.updates++; return updated
    }
    if (channel === 'drawings:delete') {
      const ids = (request as { ids: string[] }).ids
      state.rows = state.rows.filter(row => !ids.includes(row.id)); state.deletes++; return undefined
    }
    if (channel === 'pdf:exportAnnotated') { state.exports.push(structuredClone(state.rows)); return { savedPath: null } }
    throw new Error(`Unimplemented fixture IPC: ${channel}`)
  }, on: () => () => undefined
}
setIpcAdapter(api as IpcAdapter)
const relay = new NativePDFPointerRelay(() => document.querySelector('.pdf-scroller'), () => exposed.tool('text'))
const editorGeometry = new NativePDFEditorGeometry()
let pendingStroke: JournaledDrawingInput | null = null
const exposed = { state, send: relay.accept.bind(relay), tool: (_tool: InkTool): void => {}, undo: async () => {}, ready: false,
  addDrawing: async (_input: CreateDrawingInput): Promise<Drawing | null> => null,
  payloads: () => state.rows.map(row => nativePDFDrawingPayload(row, 1.5)),
  legacyPath: (drawing: Drawing) => strokePath(drawing.data.points ?? [], drawing.style, 1.5, drawing.kind === 'highlighter'),
  deferredGesture: (inputs: Parameters<NativePDFPointerRelay['accept']>[0][]) => { for (const input of inputs) requestAnimationFrame(() => relay.accept(input)) },
  provisional: (): void => {},
  align: (native: PDFFrame) => {
    const editor = document.querySelector<HTMLElement>('.ink-layer__textbox-editor')!, page = editor.closest<HTMLElement>('[data-pdf-page]')!
    const viewport = document.querySelector('.pdf-scroller')!.getBoundingClientRect(), before = editor.getBoundingClientRect(), pageBounds = page.getBoundingClientRect()
    editorGeometry.apply(editor, native, viewport)
    return { before: before.toJSON(), after: editor.getBoundingClientRect().toJSON(), page: pageBounds.toJSON(), viewport: viewport.toJSON() }
  }, resetAlignment: () => editorGeometry.dispose() }
;(window as unknown as { nativeFixture: typeof exposed }).nativeFixture = exposed
function Fixture(): JSX.Element {
  const drawings = useDrawings('course', 'fixture.pdf'), [tool, setTool] = useState<InkTool>('rect')
  const [hasPending, setPending] = useState(false)
  const nativeSession = useRef<NativePDFSession | null>(null)
  if (!nativeSession.current) nativeSession.current = new NativePDFSession({ surfaceId: 'fixture', generation: 'fixture', courseId: 'course', relPath: 'fixture.pdf' }, {
    async invoke(channel) {
      if (channel === 'pdfNative:flush') return { pending: pendingStroke ? [pendingStroke] : [] }
      if (channel === 'pdfNative:mutationStatus') return { status: 'missing' }
      if (channel === 'pdfNative:ack') { pendingStroke = null; setPending(false); return {} }
      return {}
    }, on: () => () => {}
  }, drawings)
  exposed.provisional = () => {
    pendingStroke = { courseId: 'course', relPath: 'fixture.pdf', page: 1, kind: 'ink', clientMutationId: crypto.randomUUID(),
      documentRevision: 'a'.repeat(64), data: { inkVersion: 2, points: [{ x: 0.1, y: 0.2, p: 0 }] }, style: { color: 'ink', width: 0.004, opacity: 1 } }
    setPending(true)
  }
  exposed.tool = setTool; exposed.undo = drawings.undo; exposed.addDrawing = drawings.create; exposed.ready = !drawings.loading
  return <div className="pdf-tab" data-tool={tool}>
    <button id="native-pending-undo" disabled={!(drawings.canUndo || hasPending)} onClick={() => { void (async () => { await nativeSession.current?.flush(); await drawings.undo() })() }}>Undo</button>
    <button id="native-pending-redo" disabled={!drawings.canRedo || hasPending} onClick={() => { void drawings.redo() }}>Redo</button>
    <button id="native-pending-export" onClick={() => { void (async () => { await nativeSession.current?.flush(); await api.invoke('pdf:exportAnnotated', { courseId: 'course', relPath: 'fixture.pdf' }) })() }}>Export</button>
    <div className="pdf-scroller" style={{ width: 600, height: 600, overflow: 'auto' }}>
    <div data-pdf-page="1" data-native-pdf="true" style={{ position: 'relative', width: 600, height: 900 }}
      ref={node => { if (node) node.addEventListener('bandal-native-pdf-object-scene', event => state.scenes.push((event as CustomEvent<NativeObjectScene>).detail)) }}>
      <InkLayer aspect={1.5} baseWidthPx={600} surfaceWidthPt={600} ariaLabel="original object editor"
        className="pdf-drawing-layer native-fixture-ink" shapes={drawings.drawings} interactive={!drawings.loading}
        tool={{ activeTool: tool, width: 0.004, color: 'ink', opacity: 1 }}
        onCreate={shape => { void drawings.create({ ...shape, courseId: 'course', relPath: 'fixture.pdf', page: 1 }) }}
        onUpdate={(id, patch) => { void drawings.update({ id, ...patch }) }}
        onRemove={ids => { void drawings.remove(ids) }} resolveShapeId={drawings.resolveId} />
    </div>
  </div></div>
}
const style = document.createElement('style')
style.textContent = ':root{--drawing-ink:rgb(20,23,31);--accent:#3478f6}.native-fixture-ink{width:600px;height:900px;display:block;background:white}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
