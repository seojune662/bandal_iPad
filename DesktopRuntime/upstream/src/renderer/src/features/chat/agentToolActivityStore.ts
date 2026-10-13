import { useCallback, useEffect } from 'react'
import { create } from 'zustand'
import type {
  AgentAction,
  AgentConfirmScope,
  AgentConfirmRequest,
  AgentConfirmationState
} from '../../../../shared/types/agentTools'
import { invoke, onPush, type Unsubscribe } from '../../lib/ipc'
import { showToast } from '../../app/toast'

export type AgentUndoState = 'idle' | 'pending' | 'complete' | 'error'

export interface AgentConfirmationActivity {
  kind: 'confirmation'
  request: AgentConfirmRequest
  response: boolean | null
  resolution?: AgentConfirmationState['status']
  revision?: number
  isResponding: boolean
  hasResponseError: boolean
}

export interface AgentChangesActivity {
  kind: 'changes'
  turnId: string
  actions: AgentAction[]
  loadState: 'loading' | 'ready' | 'error'
  undoState: AgentUndoState
}

export type AgentToolActivityItem =
  | AgentConfirmationActivity
  | AgentChangesActivity

export interface AgentToolActivitySnapshot {
  items: AgentToolActivityItem[]
}

interface AgentToolActivityStoreState {
  conversations: Record<string, AgentToolActivitySnapshot>
}

interface AgentToolRuntime {
  refCount: number
  unsubscribe: Unsubscribe | null
}

const EMPTY_SNAPSHOT: AgentToolActivitySnapshot = { items: [] }
const runtimes = new Map<string, AgentToolRuntime>()

export const useAgentToolActivityStore =
  create<AgentToolActivityStoreState>(() => ({ conversations: {} }))

function snapshotFor(conversationId: string): AgentToolActivitySnapshot {
  return useAgentToolActivityStore.getState().conversations[conversationId] ?? EMPTY_SNAPSHOT
}

function updateSnapshot(
  conversationId: string,
  update: (
    current: AgentToolActivitySnapshot
  ) => AgentToolActivitySnapshot
): void {
  useAgentToolActivityStore.setState((store) => {
    const current = store.conversations[conversationId] ?? EMPTY_SNAPSHOT
    const next = update(current)
    if (next === current) {
      return store
    }
    return {
      conversations: { ...store.conversations, [conversationId]: next }
    }
  })
}

function runtimeFor(conversationId: string): AgentToolRuntime {
  let runtime = runtimes.get(conversationId)
  if (runtime === undefined) {
    runtime = { refCount: 0, unsubscribe: null }
    runtimes.set(conversationId, runtime)
  }
  return runtime
}

/** Records a pushed confirmation once, even when more than one surface listens. */
export function recordAgentConfirmation(request: AgentConfirmRequest): void {
  updateSnapshot(request.conversationId, (current) => {
    const existingIndex = current.items.findIndex(
      (item) =>
        item.kind === 'confirmation' &&
        item.request.requestId === request.requestId
    )
    if (existingIndex >= 0) {
      const items = [...current.items]
      const existing = items[existingIndex]
      if (existing?.kind !== 'confirmation') {
        return current
      }
      items[existingIndex] = { ...existing, request }
      return { items }
    }
    return {
      items: [
        ...current.items,
        {
          kind: 'confirmation',
          request,
          response: null,
          isResponding: false,
          hasResponseError: false
        }
      ]
    }
  })
}

function updateConfirmation(
  conversationId: string,
  requestId: string,
  update: (item: AgentConfirmationActivity) => AgentConfirmationActivity
): void {
  updateSnapshot(conversationId, (current) => {
    let changed = false
    const items = current.items.map((item) => {
      if (
        item.kind !== 'confirmation' ||
        item.request.requestId !== requestId
      ) {
        return item
      }
      changed = true
      return update(item)
    })
    return changed ? { items } : current
  })
}

function ensureChangesActivity(conversationId: string, turnId: string): void {
  updateSnapshot(conversationId, (current) => {
    const existing = current.items.find(
      (item) => item.kind === 'changes' && item.turnId === turnId
    )
    if (existing !== undefined) {
      return current
    }
    return {
      items: [
        ...current.items,
        {
          kind: 'changes',
          turnId,
          actions: [],
          loadState: 'loading',
          undoState: 'idle'
        }
      ]
    }
  })
}

function updateChanges(
  conversationId: string,
  turnId: string,
  update: (item: AgentChangesActivity) => AgentChangesActivity
): void {
  updateSnapshot(conversationId, (current) => {
    let changed = false
    const items = current.items.map((item) => {
      if (item.kind !== 'changes' || item.turnId !== turnId) {
        return item
      }
      changed = true
      return update(item)
    })
    return changed ? { items } : current
  })
}

function fetchTurnChanges(conversationId: string, turnId: string): void {
  ensureChangesActivity(conversationId, turnId)
  void invoke('agentTools:changes', { turnId })
    .then((changes) => {
      updateChanges(conversationId, turnId, (item) => ({
        ...item,
        turnId: changes.turnId,
        actions: changes.actions,
        loadState: 'ready'
      }))
    })
    .catch(() => {
      updateChanges(conversationId, turnId, (item) => ({
        ...item,
        loadState: 'error'
      }))
    })
}

export function syncConfirmation(state: AgentConfirmationState): void {
  const existing = snapshotFor(state.request.conversationId).items.find((item) => item.kind === 'confirmation' && item.request.requestId === state.request.requestId)
  // Reconnect snapshots and duplicate pushes must not undo a local response.
  if (existing?.kind === 'confirmation' && existing.revision !== undefined && existing.revision >= state.revision) return
  recordAgentConfirmation(state.request)
  updateConfirmation(state.request.conversationId, state.request.requestId, (item) => ({
    ...item, revision: state.revision, resolution: state.status,
    response: state.status === 'pending' ? null : state.status === 'approved',
    isResponding: state.status === 'pending' ? item.isResponding : false,
    hasResponseError: state.status === 'pending' ? item.hasResponseError : false
  }))
}

/** Retains both assistant-tool push listeners while a course chat is mounted. */
export function acquireAgentToolActivity(conversationId: string): () => void {
  const runtime = runtimeFor(conversationId)
  runtime.refCount += 1
  if (runtime.refCount === 1) {
    const unsubscribeState = onPush('agentTools:confirmationChanged', (state) => {
      if (state.request.conversationId === conversationId) syncConfirmation(state)
    })
    void invoke('agentTools:confirmations', { conversationId }).then((states) => states.forEach(syncConfirmation)).catch(() => undefined)
    const unsubscribeConfirm = onPush('agentTools:confirm', (request) => {
      // Was `request.conversationId === conversationId`. That is why an approval card
      // appeared in EVERY past conversation of the same course: one card, one
      // course key, every ChatSurface mounted for it.
      if (request.conversationId === conversationId) {
        recordAgentConfirmation(request)
      }
    })
    const unsubscribeChanged = onPush('agentTools:changed', (event) => {
      if (event.conversationId === conversationId) {
        fetchTurnChanges(conversationId, event.turnId)
      }
    })
    // The in-app tools failed to come up. Say so — otherwise the assistant
    // just quietly cannot touch the app or the browser, and explains that as
    // if it were a limitation of the product.
    const unsubscribeUnavailable = onPush('agentTools:unavailable', (event) => {
      if (event.sessionId !== conversationId) return
      showToast(
        '앱 도구를 불러오지 못했어요. 대화를 다시 열면 복구돼요.',
        'danger'
      )
    })
    runtime.unsubscribe = () => {
      unsubscribeState()
      unsubscribeConfirm()
      unsubscribeChanged()
      unsubscribeUnavailable()
    }
  }

  let released = false
  return () => {
    if (released) {
      return
    }
    released = true
    runtime.refCount = Math.max(0, runtime.refCount - 1)
    if (runtime.refCount === 0) {
      runtime.unsubscribe?.()
      runtime.unsubscribe = null
    }
  }
}

export function respondToAgentConfirm(
  conversationId: string,
  requestId: string,
  approved: boolean,
  scope?: AgentConfirmScope
): void {
  const confirmation = snapshotFor(conversationId).items.find(
    (item) =>
      item.kind === 'confirmation' && item.request.requestId === requestId
  )
  if (
    confirmation?.kind !== 'confirmation' ||
    confirmation.response !== null ||
    confirmation.isResponding
  ) {
    return
  }

  updateConfirmation(conversationId, requestId, (item) => ({
    ...item,
    isResponding: true,
    hasResponseError: false
  }))
  void invoke('agentTools:respondConfirm', {
    requestId,
    approved,
    // `exactOptionalPropertyTypes`: the key must be absent, not undefined.
    ...(scope === undefined ? {} : { scope })
  })
    .then(result => result.state ? [result.state] : invoke('agentTools:confirmations', { conversationId }))
    .then((states) => {
      states.forEach(syncConfirmation)
      if (!states.some((state) => state.request.requestId === requestId)) {
        updateConfirmation(conversationId, requestId, (item) => ({ ...item, response: false, resolution: 'cancelled', isResponding: false, hasResponseError: false }))
      }
    })
    .catch(() => {
      updateConfirmation(conversationId, requestId, (item) => ({
        ...item,
        isResponding: false,
        hasResponseError: true
      }))
    })
}

export function undoAgentTurn(conversationId: string, turnId: string): void {
  const changes = snapshotFor(conversationId).items.find(
    (item) => item.kind === 'changes' && item.turnId === turnId
  )
  if (
    changes?.kind !== 'changes' ||
    changes.undoState === 'pending' ||
    !changes.actions.some(
      (action) => action.undoable && action.undoneAt === null
    )
  ) {
    return
  }

  updateChanges(conversationId, turnId, (item) => ({
    ...item,
    undoState: 'pending'
  }))
  void invoke('agentTools:undo', { turnId })
    .then(() => {
      const undoneAt = new Date().toISOString()
      updateChanges(conversationId, turnId, (item) => ({
        ...item,
        actions: item.actions.map((action) =>
          action.undoable && action.undoneAt === null
            ? { ...action, undoneAt }
            : action
        ),
        undoState: 'complete'
      }))
      fetchTurnChanges(conversationId, turnId)
    })
    .catch(() => {
      updateChanges(conversationId, turnId, (item) => ({
        ...item,
        undoState: 'error'
      }))
    })
}

export interface AgentToolActivityApi extends AgentToolActivitySnapshot {
  respondConfirm: (
    requestId: string,
    approved: boolean,
    scope?: AgentConfirmScope
  ) => void
  undoTurn: (turnId: string) => void
}

export function useAgentToolActivity(
  conversationKey: string
): AgentToolActivityApi {
  const conversationId = conversationKey
  const snapshot = useAgentToolActivityStore(
    useCallback(
      (store) =>
        store.conversations[conversationId] ?? snapshotFor(conversationId),
      [conversationId]
    )
  )

  useEffect(() => acquireAgentToolActivity(conversationId), [conversationId])

  const respondConfirm = useCallback(
    (requestId: string, approved: boolean, scope?: AgentConfirmScope) => {
      respondToAgentConfirm(conversationId, requestId, approved, scope)
    },
    [conversationId]
  )
  const undoTurn = useCallback(
    (turnId: string) => undoAgentTurn(conversationId, turnId),
    [conversationId]
  )

  return { ...snapshot, respondConfirm, undoTurn }
}
