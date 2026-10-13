import { create } from 'zustand'
import type { ChatAttachment } from '../../../../shared/types/chat'
import type { ChatContext, ChatSkill, CreationKind } from '../../../../shared/types/chatCapabilities'
export interface DraftFile { name: string; path?: string; relPath?: string }
export interface ComposerDraft {
  excludeCurrentMaterial?: boolean
  quotes?: import('./chatPromptBus').ChatQuote[]
  text: string; images: ChatAttachment[]; files: DraftFile[]; skills: ChatSkill[]
  creation: CreationKind | null; browser: boolean; screen: boolean
}
const empty: ComposerDraft = { text: '', images: [], files: [], skills: [], creation: null, browser: false, screen: false }
export const useComposerDraftStore = create<{ drafts: Record<string, ComposerDraft> }>(() => ({ drafts: {} }))
export function useComposerDraft(id: string): ComposerDraft { return useComposerDraftStore((store) => store.drafts[id] ?? empty) }
export function updateComposerDraft(id: string, update: Partial<ComposerDraft> | ((draft: ComposerDraft) => Partial<ComposerDraft>)): void {
  let patch: Partial<ComposerDraft> = {}
  useComposerDraftStore.setState((store) => {
    const draft = store.drafts[id] ?? empty
    patch = typeof update === 'function' ? update(draft) : update
    return { drafts: { ...store.drafts, [id]: { ...draft, ...patch } } }
  })
  draftChannel?.postMessage({ kind: 'patch', id, patch })
}

/** Remove the submitted snapshot without discarding newer edits from another composer. */
export function consumeComposerDraft(id: string, sent: ComposerDraft): void {
  const remaining = <T,>(current: T[], submitted: T[]): T[] => {
    const counts = new Map<string, number>()
    for (const item of submitted) { const key = JSON.stringify(item); counts.set(key, (counts.get(key) ?? 0) + 1) }
    return current.filter(item => {
      const key = JSON.stringify(item), count = counts.get(key) ?? 0
      if (count === 0) return true
      counts.set(key, count - 1)
      return false
    })
  }
  updateComposerDraft(id, current => ({
    text: current.text === sent.text ? '' : current.text,
    quotes: remaining(current.quotes ?? [], sent.quotes ?? []),
    images: remaining(current.images, sent.images),
    files: remaining(current.files, sent.files),
    skills: remaining(current.skills, sent.skills),
    creation: current.creation === sent.creation ? null : current.creation,
    browser: sent.browser ? false : current.browser,
    screen: sent.screen ? false : current.screen
  }))
}
export function draftContext(draft: ComposerDraft): ChatContext {
  return { ...(draft.excludeCurrentMaterial ? { excludeCurrentMaterial: true } : {}), files: draft.files.flatMap((file) => file.relPath ? [{ name: file.name, relPath: file.relPath }] : []), skillIds: draft.skills.map((skill) => skill.id), skillNames: draft.skills.map((skill) => skill.name), ...(draft.creation ? { creation: draft.creation } : {}), browser: draft.browser, screen: draft.screen }
}

// Drafts are shared across renderer windows without persisting images to disk.
const draftChannel = typeof window !== 'undefined' && typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel('bandal-composer-v2') : null
if (draftChannel) {
  draftChannel.onmessage = ({ data }) => {
    if (data.kind === 'hello') draftChannel.postMessage({ kind: 'snapshot', drafts: useComposerDraftStore.getState().drafts })
    if (data.kind === 'snapshot') useComposerDraftStore.setState(store => ({ drafts: { ...data.drafts, ...store.drafts } }))
    if (data.kind === 'patch' && typeof data.id === 'string') useComposerDraftStore.setState(store => ({ drafts: { ...store.drafts, [data.id]: { ...(store.drafts[data.id] ?? empty), ...data.patch } } }))
  }
  draftChannel.postMessage({ kind: 'hello' })
}
