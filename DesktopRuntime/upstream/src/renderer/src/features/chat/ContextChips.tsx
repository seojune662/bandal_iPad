import { useEffect, useState } from 'react'
import type { MessageContextSnapshot } from '../../../../shared/types/chatContext'
import { invoke, onPush } from '../../lib/ipc'
import { updateComposerDraft, useComposerDraft } from './composerDraftStore'
const pending = new Map<string, Promise<MessageContextSnapshot>>()
function load(courseId: string, sourcePanelId?: string | undefined): Promise<MessageContextSnapshot> {
  let request = pending.get(`${courseId}:${sourcePanelId ?? ''}`)
  if (!request) { request = invoke('chat:context', { courseId, ...(sourcePanelId ? { sourcePanelId } : {}) }).finally(() => pending.delete(`${courseId}:${sourcePanelId ?? ''}`)); pending.set(`${courseId}:${sourcePanelId ?? ''}`, request) }
  return request
}
export function useMaterialContext(courseId: string, sourcePanelId?: string | undefined) {
  const [snapshot, setSnapshot] = useState<MessageContextSnapshot | null>(null), [error, setError] = useState(false)
  useEffect(() => {
    let active = true
    setSnapshot(null); setError(false)
    const refresh = (): void => { void load(courseId, sourcePanelId).then(value => { if (active) { setSnapshot(value); setError(false) } }).catch(() => { if (active) setError(true) }) }
    const off = onPush('assistant:contextChanged', event => { if (event.courseId === courseId) refresh() })
    refresh(); window.addEventListener('focus', refresh)
    return () => { active = false; off(); window.removeEventListener('focus', refresh) }
  }, [courseId, sourcePanelId])
  return { snapshot, error }
}
export function ContextChips({ courseId, conversationId, sourcePanelId }: { courseId: string; conversationId: string; sourcePanelId?: string | undefined }): JSX.Element {
  const { snapshot, error } = useMaterialContext(courseId, sourcePanelId)
  const draft = useComposerDraft(conversationId)
  const material = snapshot?.material
  return <div className="chat-context-chips chat-context-auto" aria-label="자동 연결 자료" data-error={error || snapshot?.refresh === 'failed' || undefined}>
    <span className="chat-context-course">{snapshot?.courseName ?? '이 과목'}{error || snapshot?.refresh === 'failed' ? ' · 원본 자료를 확인할 수 없어요' : ''}</span>
    {material && !draft.excludeCurrentMaterial && <span className="chat-context-chip" title={`${material.relPath ?? material.url ?? material.title}${material.selection ? '\n선택한 글을 우선 참고해요.' : ''}`}>
      {material.title}{material.page ? ` · ${material.page}쪽` : ''}{material.unsaved ? ' · 저장 전 필기' : ''}{material.selection ? ' · 선택한 글' : ''}
      <button type="button" aria-label="자동 연결 자료 제거" onClick={() => updateComposerDraft(conversationId, { excludeCurrentMaterial: true })}>×</button>
    </span>}
    {material && draft.excludeCurrentMaterial && <button type="button" className="chat-context-restore" onClick={() => updateComposerDraft(conversationId, { excludeCurrentMaterial: false })}>현재 자료 연결</button>}
  </div>
}
