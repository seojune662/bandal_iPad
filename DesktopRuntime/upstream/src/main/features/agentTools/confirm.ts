import { randomUUID } from 'node:crypto'
import type { AgentConfirmRequest, AgentConfirmResponse, AgentConfirmScope, AgentConfirmationState } from '../../../shared/types/agentTools'

const DEFAULT_TIMEOUT_MS = 2 * 60 * 1000
interface PendingConfirmation {
  request: AgentConfirmRequest
  resolve: (outcome: AgentConfirmScope | false) => void
  timer: ReturnType<typeof setTimeout>
  promise: Promise<AgentConfirmScope | false>
}
export interface AgentConfirmer {
  confirm(input: Omit<AgentConfirmRequest, 'requestId'>): Promise<AgentConfirmScope | false>
  resolve(response: AgentConfirmResponse): AgentConfirmationState | null
  list(conversationId: string): AgentConfirmationState[]
  cancelProviderRequest(conversationId: string, providerRequestId: string): void
  cancelConversation(conversationId: string): void
  disposeAll(): void
}
export function createAgentConfirmer(deps: {
  emit: (request: AgentConfirmRequest) => void
  changed?: (state: AgentConfirmationState) => void
  timeoutMs?: number
  allow?: (request: Omit<AgentConfirmRequest, 'requestId'>) => boolean
}): AgentConfirmer {
  const pending = new Map<string, PendingConfirmation>()
  const states = new Map<string, AgentConfirmationState>()
  const operations = new Map<string, string>()
  let revision = 0
  const configuredTimeout = deps.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const timeoutMs = Number.isFinite(configuredTimeout) && configuredTimeout >= 0 ? configuredTimeout : 0
  function publish(request: AgentConfirmRequest, status: AgentConfirmationState['status'], scope?: AgentConfirmScope): AgentConfirmationState {
    const state: AgentConfirmationState = { request, status, revision: ++revision, ...(scope ? { scope } : {}) }
    states.set(request.requestId, state)
    if (states.size > 1000) {
      for (const [id, old] of states) {
        if (old.status !== 'pending') { states.delete(id); break }
      }
    }
    try { deps.changed?.(state) } catch (error) { console.error('[agent] confirmation notification failed', error) }
    return state
  }
  function settle(id: string, status: Exclude<AgentConfirmationState['status'], 'pending'>, scope?: AgentConfirmScope): AgentConfirmationState | null {
    const item = pending.get(id)
    if (!item) return states.get(id) ?? null
    pending.delete(id)
    clearTimeout(item.timer)
    const state = publish(item.request, status, scope)
    item.resolve(status === 'approved' ? scope ?? 'once' : false)
    return state
  }
  return {
    confirm(input) {
      const key = input.turnId ? JSON.stringify([input.conversationId, input.turnId, input.tool, input.operationKey ?? input.details]) : null
      const previousId = key ? operations.get(key) : undefined
      if (previousId) {
        const waiting = pending.get(previousId)
        if (waiting) return waiting.promise
        // A failed/denied/cancelled action cannot re-prompt in the same turn.
        // Approved calls may be legitimately repeated, but must ask afresh.
        if (states.get(previousId)?.status !== 'approved') return Promise.resolve(false)
      }
      if (deps.allow?.(input)) return Promise.resolve('once')
      const request = { ...input, requestId: randomUUID() }
      let resolve!: (outcome: AgentConfirmScope | false) => void
      const promise = new Promise<AgentConfirmScope | false>(done => { resolve = done })
      const timer = setTimeout(() => settle(request.requestId, 'expired'), timeoutMs)
      pending.set(request.requestId, { request, resolve, timer, promise })
      if (key) { operations.set(key, request.requestId); if (operations.size > 2000) operations.delete(operations.keys().next().value!) }
      try { publish(request, 'pending'); deps.emit(request) }
      catch { settle(request.requestId, 'cancelled') }
      return promise
    },
    resolve(response) {
      const item = pending.get(response.requestId)
      if (item && response.approved === true && response.scope !== undefined && !(item.request.scopes ?? ['once']).includes(response.scope)) {
        throw new Error('이 요청에서 선택할 수 없는 승인 범위예요.')
      }
      return settle(response.requestId, response.approved === true ? 'approved' : 'denied', response.scope)
    },
    list(conversationId) { return [...states.values()].filter((state) => state.request.conversationId === conversationId) },
    cancelProviderRequest(conversationId, providerRequestId) {
      for (const [id, item] of pending) if (item.request.conversationId === conversationId && item.request.providerRequestId === providerRequestId) settle(id, 'cancelled')
    },
    cancelConversation(conversationId) {
      for (const [id, item] of pending) if (item.request.conversationId === conversationId) settle(id, 'cancelled')
    },
    disposeAll() { for (const id of pending.keys()) settle(id, 'cancelled') }
  }
}
