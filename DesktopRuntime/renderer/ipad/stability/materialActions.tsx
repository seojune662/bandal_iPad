import { useEffect, useId, useRef, useState, type DragEvent } from 'react'
import { createPortal } from 'react-dom'
import type { MaterialNode } from '../../../upstream/src/shared/types/materials'
import { clearCurrentMaterialDrag, MATERIAL_MOVE_MIME, serializeMaterialMoveDrag, setCurrentMaterialDrag } from '../../../upstream/src/renderer/src/features/materials/materialMoveDrag'
import { beginMaterialFileDrag, clearMaterialFileDrag } from '../../../upstream/src/renderer/src/features/materials/materialFileDrag'
import { setNativeHostBlocked } from '../nativeSurfaces'
import { reportOperationError } from './operations'

let stopDrag: (() => void) | undefined
/** Keep the normal HTML drag alive. The desktop path cancels it to call an
 * Electron OS-drag API, which cannot create a UIDragSession on iPad. */
export function startIPadMaterialDrag(event: DragEvent, courseId: string, node: MaterialNode): void {
  stopDrag?.()
  const payload = { version: 1 as const, courseId, relPath: node.relPath, kind: node.kind }
  event.dataTransfer.effectAllowed = 'copyMove'
  event.dataTransfer.setData(MATERIAL_MOVE_MIME, serializeMaterialMoveDrag(payload))
  setCurrentMaterialDrag(payload)
  if (node.kind !== 'dir') beginMaterialFileDrag({ courseId, relPath: node.relPath, kind: node.kind })
  const clear = () => {
    clearCurrentMaterialDrag(); clearMaterialFileDrag()
    window.removeEventListener('dragend', clear)
    window.removeEventListener('drop', dropped)
    window.removeEventListener('blur', clear)
    window.removeEventListener('pagehide', clear)
    window.removeEventListener('keydown', key)
    if (stopDrag === clear) stopDrag = undefined
  }
  const dropped = () => { window.setTimeout(clear, 0) }
  const key = (event: KeyboardEvent) => { if (event.key === 'Escape') clear() }
  stopDrag = clear
  window.addEventListener('dragend', clear)
  window.addEventListener('drop', dropped)
  window.addEventListener('blur', clear)
  window.addEventListener('pagehide', clear)
  window.addEventListener('keydown', key)
}

export async function exportMaterial(channel: 'materials:share' | 'materials:export', courseId: string, relPath: string): Promise<void> {
  try { await (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)(channel, { courseId, relPath }) }
  catch (reason) { reportOperationError(reason, { operation: channel === 'materials:share' ? '자료 공유' : '파일에 저장' }) }
}

export function materialMoveFolders(tree: MaterialNode[], target: MaterialNode): Array<{ path: string; name: string }> {
  const folders = [{ path: '', name: '자료 최상위 폴더' }]
  const visit = (nodes: MaterialNode[], depth: number) => {
    if (depth > 14) return
    for (const node of nodes) {
      if (node.kind !== 'dir') continue
      if (target.kind === 'dir' && (node.relPath === target.relPath || node.relPath.startsWith(target.relPath + '/'))) continue
      folders.push({ path: node.relPath, name: node.relPath })
      visit(node.children ?? [], depth + 1)
    }
  }
  visit(tree, 0)
  const parent = target.relPath.includes('/') ? target.relPath.slice(0, target.relPath.lastIndexOf('/')) : ''
  return folders.filter(folder => folder.path !== parent)
}

export function MaterialMoveDialog({ target, tree, onMove, onClose }: {
  target: MaterialNode; tree: MaterialNode[]; onMove: (directory: string) => Promise<void>; onClose: () => void
}): JSX.Element {
  const titleId = useId(), owner = 'material-move-' + titleId
  const panel = useRef<HTMLElement>(null)
  const folders = materialMoveFolders(tree, target)
  const [directory, setDirectory] = useState(folders[0]?.path ?? '')
  const [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null)
  useEffect(() => {
    const previous = document.activeElement
    setNativeHostBlocked(owner, true)
    panel.current?.querySelector<HTMLElement>('select, button')?.focus()
    return () => { setNativeHostBlocked(owner, false); if (previous instanceof HTMLElement && previous.isConnected) previous.focus() }
  }, [owner])
  return createPortal(<div className="ipad-material-move-backdrop" style={{ position: 'fixed', inset: 0, zIndex: 10000, background: '#0005', display: 'grid', placeItems: 'center', padding: 20 }}>
    <section ref={panel} role="dialog" aria-modal="true" aria-labelledby={titleId} aria-busy={busy} style={{ width: 'min(440px, 100%)', maxHeight: '80dvh', overflow: 'auto', padding: 24, borderRadius: 18, color: 'var(--text-primary, #242321)', background: 'var(--surface-1, #fff)' }} onKeyDown={event => {
      if (event.key === 'Escape' && !busy) { event.stopPropagation(); onClose() }
      if (event.key === 'Tab') {
        const items = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled),select:not(:disabled)')]
        const first = items[0], last = items.at(-1)
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }
    }}>
      <h2 id={titleId}>자료 이동</h2><p style={{ overflowWrap: 'anywhere' }}>{target.name}</p>
      {folders.length ? <label>이동할 폴더<select aria-label="이동할 폴더" value={directory} disabled={busy} onChange={event => setDirectory(event.target.value)} style={{ display: 'block', width: '100%', minHeight: 44, marginTop: 10 }}>{folders.map(folder => <option key={folder.path} value={folder.path}>{folder.name}</option>)}</select></label> : <p>이동할 다른 폴더가 없습니다. 자료 목록에서 새 폴더를 만들어 주세요.</p>}
      {error && <p role="alert">{error}</p>}
      <div style={{ display: 'flex', gap: 12, justifyContent: 'flex-end', marginTop: 24 }}>
        <button type="button" disabled={busy} onClick={onClose} style={{ minHeight: 44, minWidth: 72 }}>취소</button>
        <button type="button" disabled={busy || !folders.length} style={{ minHeight: 44, minWidth: 88 }} onClick={() => {
          setBusy(true); setError(null)
          void onMove(directory).then(onClose).catch(reason => setError(reason instanceof Error ? reason.message : '자료를 이동하지 못했습니다.')).finally(() => setBusy(false))
        }}>{busy ? '이동 중…' : '이동'}</button>
      </div>
    </section>
  </div>, document.body)
}
