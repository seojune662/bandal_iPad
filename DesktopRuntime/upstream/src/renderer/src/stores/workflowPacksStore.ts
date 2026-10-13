/** One installed-pack registry for Settings, study menus and the launcher. */
import { create } from 'zustand'
import type { WorkflowPackSummary } from '../../../shared/types/workflowPack'
import { invoke, onPush } from '../lib/ipc'

export interface WorkflowPacksState {
  packs: WorkflowPackSummary[]
  hasLoaded: boolean
  loading: boolean
  error: string | null
  load: () => Promise<void>
  refresh: () => Promise<void>
  setEnabled: (id: string, enabled: boolean) => Promise<void>
  remove: (id: string) => Promise<void>
}

let unsubscribe: (() => void) | null = null
let generation = 0
let request: Promise<void> | null = null

export const useWorkflowPacksStore = create<WorkflowPacksState>()((set, get) => {
  const subscribe = (): void => {
    if (unsubscribe) return
    unsubscribe = onPush('packs:changed', ({ packs }) => {
      generation++
      set({ packs, hasLoaded: true, loading: false, error: null })
    })
  }
  const refresh = (): Promise<void> => {
    subscribe()
    const current = ++generation
    set({ loading: true, error: null })
    const pending = invoke('packs:list', {}).then(({ packs }) => {
      if (current === generation) set({ packs, hasLoaded: true, loading: false, error: null })
    }).catch((error: unknown) => {
      if (current === generation) set({ loading: false, error: error instanceof Error ? error.message : '학습 기능을 불러오지 못했어요.' })
    }).finally(() => { if (request === pending) request = null })
    request = pending
    return pending
  }
  const mutate = async (work: () => Promise<unknown>): Promise<void> => {
    subscribe()
    const before = generation
    await work()
    // Main normally supplies a fresh snapshot. Also support older/demo hosts
    // that acknowledge a mutation without emitting that push.
    if (before === generation) await refresh()
  }
  return {
    packs: [], hasLoaded: false, loading: false, error: null,
    load: () => { subscribe(); return get().hasLoaded ? Promise.resolve() : request ?? refresh() },
    refresh,
    setEnabled: (id, enabled) => mutate(() => invoke('packs:setEnabled', { id, enabled })),
    remove: id => mutate(() => invoke('packs:remove', { id }))
  }
})

export function resetWorkflowPacksStoreForTests(): void {
  unsubscribe?.(); unsubscribe = null; generation++; request = null
  useWorkflowPacksStore.setState({ packs: [], hasLoaded: false, loading: false, error: null })
}
