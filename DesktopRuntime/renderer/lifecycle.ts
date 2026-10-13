import type { NoteRef } from '../upstream/src/shared/types/note'
type Snapshot = NoteRef & { markdown: string }
type FlushReport = { ok: boolean; pending: Array<NoteRef & { status: string }> }
interface Registry {
  readOpenNoteSnapshots(): Snapshot[]
  flushOpenNoteSession(ref: NoteRef): Promise<{ result: { status: string } } | null>
}
declare global { interface Window { __bandalFlushNative?: () => Promise<FlushReport> } }
const key = (ref: NoteRef) => `${ref.courseId}\0${ref.relPath}`

/** A flush which awaited disk may have raced another input or a newly opened
 * note. Require a stable snapshot before the host releases the WebKit process.
 */
export async function flushNativeNotes(registry: Registry): Promise<FlushReport> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const before = registry.readOpenNoteSnapshots()
    const pending: FlushReport['pending'] = []
    for (const ref of before) {
      const result = await registry.flushOpenNoteSession(ref)
      if (result && result.result.status !== 'saved') pending.push({ courseId: ref.courseId, relPath: ref.relPath, status: result.result.status })
    }
    if (pending.length) return { ok: false, pending }
    const after = registry.readOpenNoteSnapshots()
    const previous = new Map(before.map(ref => [key(ref), ref.markdown]))
    if (after.every(ref => previous.get(key(ref)) === ref.markdown)) return { ok: true, pending: [] }
  }
  return { ok: false, pending: registry.readOpenNoteSnapshots().map(ref => ({ courseId: ref.courseId, relPath: ref.relPath, status: 'editing' })) }
}

interface InkRegistry { flushNativeInk(): Promise<FlushReport>; nativeInkRevision(): number }
/** Ink and notes may change one another while their independent queues await
 * IPC. Both original writers must settle within the same stable revision. */
export async function flushNativeWorkspace(notes: Registry, ink: InkRegistry): Promise<FlushReport> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const revision = ink.nativeInkRevision()
    const firstNotes = await flushNativeNotes(notes)
    if (!firstNotes.ok) return firstNotes
    const drawing = await ink.flushNativeInk()
    if (!drawing.ok) return drawing
    const finalNotes = await flushNativeNotes(notes)
    if (!finalNotes.ok) return finalNotes
    if (revision === ink.nativeInkRevision()) return { ok: true, pending: [] }
  }
  return { ok: false, pending: [{ courseId: '', relPath: '', status: 'editing' }] }
}

/** Original note registry remains the only writer and conflict authority. */
export function installNativeLifecycle(): void {
  let flight: Promise<FlushReport> | undefined
  window.__bandalFlushNative = () => {
    if (flight) return flight
    flight = Promise.all([import('../upstream/src/renderer/src/features/notes/noteSessionRegistry'), import('./pencil/persistence')]).then(([notes, ink]) => flushNativeWorkspace(notes, ink)).finally(() => { flight = undefined })
    return flight
  }
}
