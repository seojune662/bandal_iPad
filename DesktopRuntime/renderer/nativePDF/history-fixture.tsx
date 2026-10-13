// Test only: run the canonical desktop hook/history with the native journal
// session. Database receipts and OS ACKs are controlled transport boundaries.
import { createRoot } from 'react-dom/client'
import { useDrawings, type DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { usePdfToolStore } from '../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import { setIpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import type { Drawing, CreateDrawingInput } from '../../upstream/src/shared/types/drawing'
import { NativePDFSession } from './session'
import type { JournaledDrawingInput, NativePDFTransport } from './types'

const assert = (value: unknown, message: string): void => { if (!value) throw new Error(message) }
const copy = <T,>(value: T): T => structuredClone(value)
const turn = () => new Promise<void>(resolve => requestAnimationFrame(() => resolve()))
export async function runNativeHistoryFixture(): Promise<string[]> {
  const rows = new Map<string, Drawing>(), receipts = new Map<string, string>(), pending = new Map<string, JournaledDrawingInput>()
  let creates = 0, failedAck = false, failedWrite = false
  let api!: DrawingsApi
  const listeners = new Set<(payload: { courseId: string }) => void>()
  const adapter = {
    on: (channel: string, listener: (payload: { courseId: string }) => void) => { if (channel === 'materials:changed') listeners.add(listener); return () => listeners.delete(listener) },
    invoke: async (channel: string, request: any): Promise<any> => {
      if (channel === 'drawings:listForFile') return copy([...rows.values()])
      if (channel === 'drawings:create') {
        creates++
        if (failedWrite) throw new Error('Disk full')
        const input = request as CreateDrawingInput
        if (input.clientMutationId && receipts.has(input.clientMutationId)) return copy(rows.get(receipts.get(input.clientMutationId)!)!)
        const row: Drawing = { id:crypto.randomUUID(),courseId:input.courseId,relPath:input.relPath,page:input.page,kind:input.kind,data:copy(input.data),style:copy(input.style),createdAt:new Date().toISOString(),updatedAt:new Date().toISOString() }
        rows.set(row.id,row); if (input.clientMutationId) receipts.set(input.clientMutationId,row.id)
        return copy(row)
      }
      if (channel === 'drawings:delete') { request.ids.forEach((id: string) => rows.delete(id)); return undefined }
      throw new Error('Unexpected history fixture channel: ' + channel)
    }
  }
  setIpcAdapter(adapter as never)
  const transport: NativePDFTransport = { on:()=>()=>{}, async invoke(channel, request: any) {
    if (channel === 'pdfNative:mutationStatus') {
      const id = receipts.get(request.input.clientMutationId)
      return id ? {status:rows.has(id)?'live':'deleted',drawingId:id} : {status:'missing'}
    }
    if (channel === 'pdfNative:ack') {
      if (failedAck) throw new Error('ACK interrupted')
      pending.delete(request.clientMutationId); return {}
    }
    if (channel === 'pdfNative:flush') return {pending:[...pending.values()]}
    if (channel === 'pdfNative:close') return {}
    throw new Error('Unexpected native history channel: ' + channel)
  } }
  const identity = {surfaceId:'history',generation:'first',courseId:'history-course',relPath:'lecture.pdf'}
  const input = (): JournaledDrawingInput => ({courseId:identity.courseId,relPath:identity.relPath,page:1,kind:'ink',documentRevision:'a'.repeat(64),clientMutationId:crypto.randomUUID(),data:{inkVersion:2,points:[{x:.2,y:.3,p:0,t:0,tiltX:-20,tiltY:30},{x:.2,y:.3,p:1,t:12,tiltX:10,tiltY:-40}]},style:{color:'blue',width:.004,opacity:.8}})
  function Editor() { api=useDrawings(identity.courseId,identity.relPath); return null }
  const container = document.createElement('div'); document.body.append(container)
  const root=createRoot(container); root.render(<Editor/>)
  const passes:string[]=[]
  const history=()=>Object.values(usePdfToolStore.getState().histories).reduce((sum,entry)=>({undo:sum.undo+entry.undo.length,redo:sum.redo+entry.redo.length}),{undo:0,redo:0})
  const session=()=>new NativePDFSession({...identity,generation:crypto.randomUUID()},transport,{create:value=>api.create(value),flush:()=>api.flush!()})
  try {
    for(let i=0;i<100&&(!api||api.loading);i++)await turn()
    assert(api&&!api.loading,'Original useDrawings must finish loading')
    const first=input(), active=session();pending.set(first.clientMutationId,first);failedAck=true
    await active.accept(first).then(()=>{throw new Error('Expected failed ACK')},error=>assert(error.message==='ACK interrupted','Actual ACK failure'))
    await turn()
    assert(creates===1&&rows.size===1&&api.drawings.length===1&&history().undo===1,'Canonical save creates one original history entry before ACK')
    const original=[...rows.values()][0]!
    assert(active.mutationIdForDrawing(original.id)===first.clientMutationId,'Canonical snapshot retains pending preview identity')
    failedAck=false;await active.flush();await turn()
    assert(creates===1&&history().undo===1&&pending.size===0,'Retrying native ACK must not call canonical create or record history again')
    await active.flush();await api.undo();await turn()
    assert(rows.size===0&&history().undo===0&&history().redo===1,'Original undo removes a native stroke exactly once')
    await active.flush();await api.redo();await turn()
    const restored=[...rows.values()][0]!
    assert(rows.size===1&&restored.id!==original.id&&history().undo===1&&history().redo===0,'Original redo creates one mapped canonical row')
    assert(JSON.stringify(restored.data)===JSON.stringify(first.data)&&JSON.stringify(restored.style)===JSON.stringify(first.style),'Redo preserves v2 pressure/time/tilt/style')
    // Lost acknowledgement from the old operation arrives after undo/redo.
    // The receipt targets its deleted old ID, never the new redo row.
    pending.set(first.clientMutationId,first)
    const recovery=session(), beforeCreates=creates
    await recovery.flush();await turn()
    assert(creates===beforeCreates&&rows.size===1&&rows.has(restored.id)&&history().undo===1&&pending.size===0,'Tombstone replay after redo must not resurrect old ink or alter history')
    passes.push('canonical useDrawings native create → lost ACK retry → undo/redo → tombstone replay preserves exactly one history and v2 data')
    const second=input();pending.set(second.clientMutationId,second);failedWrite=true
    const retry=session();await retry.accept(second).then(()=>{throw new Error('Expected failed canonical write')},()=>{})
    await turn();assert(rows.size===1&&history().undo===1,'Failed canonical create cannot add undo history')
    failedWrite=false;await retry.flush();await turn()
    assert(rows.size===2&&history().undo===2&&pending.size===0&&api.error===null,'Retry writes once, clears the original save error and records one history')
    passes.push('canonical write failure keeps native journal, then successful retry clears save failure without duplicate history')
    // A live receipt recovered by another surface does not become an edit in
    // that surface. The actual original hook learns the row through reload.
    const third=input(), row=await adapter.invoke('drawings:create',third)
    pending.set(third.clientMutationId,third);listeners.forEach(listener=>listener({courseId:identity.courseId}));await turn()
    const oldHistory=history().undo, oldCreates=creates
    await session().flush();await turn()
    assert(api.drawings.some(drawing=>drawing.id===row.id)&&history().undo===oldHistory&&creates===oldCreates,'Live receipt reload must not invent a local undo entry')
    passes.push('canonical live-receipt recovery reloads the persisted object without inventing history')
    const fourth=input(), beforeRace=history().undo, beforeRaceCreates=creates
    pending.set(fourth.clientMutationId,fourth)
    await Promise.all([session().accept(fourth),session().accept(fourth)]);await turn()
    assert(history().undo===beforeRace+1&&creates===beforeRaceCreates+1,'Concurrent native surfaces replaying the same journal operation must own one original create/history entry')
    passes.push('two native surfaces racing one durable journal operation share canonical create and one history entry')
    return passes
  } finally { root.unmount();container.remove();setIpcAdapter(null) }
}
