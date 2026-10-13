import type { ChatContext } from '../../../../shared/types/chatCapabilities'
import { startTransition } from 'react'
import { create } from 'zustand'
import type {
  AgentAvailability,
  AgentEvent,
  AgentProvider,
  PermissionResponse
} from '../../../../shared/types/agent-events'
import type {
  AgentModelOption,
  ChatAttachment,
  ChatSurface
} from '../../../../shared/types/chat'
import { invoke, onPush, type Unsubscribe } from '../../lib/ipc'
import { isAgentConnectionReady, useAgentConnectionStore } from './agentConnectionStore'
import {
  appendLocalUserMessage,
  applyAgentEvents,
  checkBatchSeq,
  clearNotice,
  hydrateFromHistory,
  initialChatViewState,
  markSendFailed,
  type ChatViewState
} from './chatModel'

export type ChatPhase = 'loading' | 'ready' | 'error'

export interface ChatSessionSnapshot {
  state: ChatViewState
  phase: ChatPhase
  provider: AgentProvider
  availability: AgentAvailability | null
  openError: string | null
  models: AgentModelOption[]
  effort?: string | null
  configurationError?: string | null
  configuring?: boolean
  permissionResponses?: Record<string, 'pending' | 'error'>
  /** Conversation title (first user message). Null until the first send. */
  title: string | null
}

interface ChatSessionStoreState {
  /** Keyed by CONVERSATION id, not course — one course holds many. */
  sessions: Record<string, ChatSessionSnapshot>
}

interface ConversationRuntime {
  /** The course this conversation belongs to (needed for reopen). */
  courseId: string
  surface: ChatSurface
  providerGeneration: number
  modelsGeneration: number
  modelsRevision: number
  refCount: number
  unsubscribe: Unsubscribe | null
  lastSeq: number | null
  queue: AgentEvent[]
  raf: number | null
  hydrationBatches: { sessionId: string; seq: number; events: AgentEvent[] }[]
  hydrating: boolean
  openVersion: number
  modelsPromise: Promise<void> | null
  modelsProvider: AgentProvider | null
}

const EMPTY_SNAPSHOT: ChatSessionSnapshot = {
  state: initialChatViewState,
  phase: 'loading',
  provider: 'claude-code',
  availability: null,
  openError: null,
  models: [],
  title: null
}

const runtimes = new Map<string, ConversationRuntime>()

export const useChatSessionStore = create<ChatSessionStoreState>(() => ({
  sessions: {}
}))

function runtimeFor(courseId: string, conversationId: string): ConversationRuntime {
  let runtime = runtimes.get(conversationId)
  if (runtime === undefined) {
    runtime = {
      courseId,
      surface: 'app',
      providerGeneration: 0,
      modelsGeneration: 0,
      modelsRevision: 0,
      refCount: 0,
      unsubscribe: null,
      lastSeq: null,
      queue: [],
      raf: null,
      hydrationBatches: [],
      hydrating: false,
      openVersion: 0,
      modelsPromise: null,
      modelsProvider: null
    }
    runtimes.set(conversationId, runtime)
  }
  return runtime
}

function snapshotFor(conversationId: string): ChatSessionSnapshot {
  return useChatSessionStore.getState().sessions[conversationId] ?? EMPTY_SNAPSHOT
}

function updateSnapshot(
  conversationId: string,
  update: (current: ChatSessionSnapshot) => ChatSessionSnapshot
): void {
  useChatSessionStore.setState((store) => {
    const current = store.sessions[conversationId] ?? EMPTY_SNAPSHOT
    const next = update(current)
    if (next === current) {
      return store
    }
    return { sessions: { ...store.sessions, [conversationId]: next } }
  })
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : '채팅을 여는 중 문제가 발생했습니다.'
}

function flushQueue(courseId: string, conversationId: string): void {
  const runtime = runtimeFor(courseId, conversationId)
  runtime.raf = null
  if (runtime.hydrating || runtime.queue.length === 0) {
    return
  }
  const events = runtime.queue
  runtime.queue = []
  startTransition(() => {
    updateSnapshot(conversationId, (current) => ({
      ...current,
      state: applyAgentEvents(current.state, events)
    }))
  })
}

function scheduleFlush(courseId: string, conversationId: string): void {
  const runtime = runtimeFor(courseId, conversationId)
  if (runtime.raf !== null || runtime.refCount === 0) {
    return
  }
  runtime.raf = requestAnimationFrame(() => flushQueue(courseId, conversationId))
}

function loadModels(
  courseId: string,
  conversationId: string,
  provider: AgentProvider
): void {
  const runtime = runtimeFor(courseId, conversationId)
  if (!isAgentConnectionReady(snapshotFor(conversationId).availability)) return
  const revision = useAgentConnectionStore.getState().connections[provider].modelsRevision
  const refresh = revision !== runtime.modelsRevision
  if (!refresh && (
    (runtime.modelsPromise !== null && runtime.modelsProvider === provider) ||
    (runtime.modelsProvider === provider &&
      snapshotFor(conversationId).models.length > 0)
  )) {
    return
  }
  const generation = ++runtime.modelsGeneration
  runtime.modelsRevision = revision
  runtime.modelsProvider = provider
  runtime.modelsPromise = invoke('agent:models', { provider, ...(refresh ? { refresh: true } : {}) })
    .then(({ models }) => {
      if (runtime.modelsGeneration !== generation || runtime.modelsProvider !== provider) return
      updateSnapshot(conversationId, (current) => current.provider === provider ? { ...current, models } : current)
    })
    .catch(() => {
      // Main normally returns a fallback. Keep the selector usable if IPC is
      // unavailable during teardown or in an older preload.
    })
    .finally(() => {
      if (runtime.modelsGeneration === generation) runtime.modelsPromise = null
    })
}

async function openConversation(
  courseId: string,
  conversationId: string,
  opts: { discardQueue: boolean },
  surface?: ChatSurface
): Promise<void> {
  const runtime = runtimeFor(courseId, conversationId)
  const version = ++runtime.openVersion
  const availabilityAtOpen = useAgentConnectionStore.getState().connections
  runtime.hydrating = true
  if (opts.discardQueue) {
    runtime.queue = []
    runtime.hydrationBatches = []
  }
  let checkpoint: number | undefined
  try {
    const result = await invoke('chat:open', {
      courseId,
      sessionId: conversationId,
      surface: surface ?? runtime.surface
    })
    if (version !== runtime.openVersion) {
      return
    }
    checkpoint = result.eventSeq
    const provider = result.sessionInfo?.provider ?? snapshotFor(conversationId).provider
    const connection = useAgentConnectionStore.getState().connections[provider]
    const availability = connection.availability !== null && connection.availabilityRevision > availabilityAtOpen[provider].availabilityRevision ? connection.availability : result.availability
    updateSnapshot(conversationId, (current) => ({
      ...current,
      provider: result.sessionInfo?.provider ?? current.provider,
      availability,
      openError: null,
      title: result.sessionInfo?.title ?? current.title,
      effort: result.sessionInfo?.effort ?? null,
      state: { ...applyAgentEvents(hydrateFromHistory(result.history, result.sessionInfo?.model ?? null), result.pendingPermissions ?? []), streaming: result.sessionInfo?.status === 'running' },
      phase: 'ready'
    }))
    loadModels(
      courseId,
      conversationId,
      result.sessionInfo?.provider ?? snapshotFor(conversationId).provider
    )
  } catch (error) {
    if (version !== runtime.openVersion) {
      return
    }
    updateSnapshot(conversationId, (current) => ({
      ...current,
      openError: errorMessage(error),
      phase: 'error'
    }))
  } finally {
    if (version === runtime.openVersion) {
      runtime.hydrating = false
      if (checkpoint !== undefined) runtime.lastSeq = checkpoint
      const frames = runtime.hydrationBatches.splice(0)
      for (const frame of frames) handleBatch(courseId, conversationId, frame)
      scheduleFlush(courseId, conversationId)
    }
  }
}

function handleBatch(
  courseId: string,
  conversationId: string,
  batch: { sessionId: string; seq: number; events: AgentEvent[] }
): void {
  if (batch.sessionId !== conversationId) {
    return
  }
  const runtime = runtimeFor(courseId, conversationId)
  if (runtime.hydrating) { runtime.hydrationBatches.push(batch); return }
  const check = checkBatchSeq(runtime.lastSeq, batch.seq)
  if (check === 'stale') {
    return
  }
  runtime.lastSeq = batch.seq
  if (check === 'gap') {
    void openConversation(courseId, conversationId, { discardQueue: true })
    return
  }
  runtime.queue.push(...batch.events)
  scheduleFlush(courseId, conversationId)
}

/**
 * Retains the sole push listener for a conversation and preserves state on
 * release. Refcounted per conversation: the same conversation mounted twice
 * (tab + popup) shares one listener.
 */
export function acquireChatSession(
  courseId: string,
  conversationId: string,
  surface: ChatSurface = 'app'
): () => void {
  const runtime = runtimeFor(courseId, conversationId)
  runtime.courseId = courseId
  runtime.surface = surface
  if (useChatSessionStore.getState().sessions[conversationId] === undefined) {
    updateSnapshot(conversationId, (current) => ({ ...current }))
  }
  const wasUnused = runtime.refCount === 0
  runtime.refCount += 1
  if (wasUnused) {
    runtime.lastSeq = null
    runtime.queue = []
    const unsubscribeBatch = onPush('chat:event-batch', (batch) => {
      handleBatch(courseId, conversationId, batch)
    })
    const unsubscribeMessage = onPush('chat:message', (event) => {
      if (event.sessionId !== conversationId) return
      flushQueue(courseId, conversationId)
      updateSnapshot(conversationId, (current) => {
        if (current.state.messages.some((message) => message.id === event.message.id)) return current
        const incoming = hydrateFromHistory([event.message], null).messages[0]!
        const userText = incoming.blocks.find(block => block.kind === 'text')
        const optimistic = incoming.role === 'user' ? current.state.messages.findIndex(message => message.role === 'user' && message.id.startsWith('local-') && message.blocks.some(block => block.kind === 'text' && userText?.kind === 'text' && block.text === userText.text)) : -1
        const messages = optimistic >= 0 ? current.state.messages.map((message, index) => index === optimistic ? incoming : message) : [...current.state.messages, incoming]
        messages.sort((a, b) => (a.turnSeq ?? Infinity) - (b.turnSeq ?? Infinity))
        return { ...current, state: { ...current.state, messages } }
      })
    })
    const unsubscribeSettings = onPush('chat:configurationChanged', (event) => {
      if (event.sessionId === conversationId) updateSnapshot(conversationId, (current) => ({ ...current, effort: event.effort, state: { ...current.state, model: event.model } }))
    })
    const unsubscribeConnection = useAgentConnectionStore.subscribe((store, previous) => {
      const provider = snapshotFor(conversationId).provider
      const generation = runtime.providerGeneration
      const connection = store.connections[provider], before = previous.connections[provider]
      if (connection.availability !== null && connection.availabilityRevision !== before.availabilityRevision) {
        updateSnapshot(conversationId, current => current.provider === provider && current.phase !== 'loading' && runtime.providerGeneration === generation ? { ...current, availability: connection.availability } : current)
      }
      if (connection.modelsInvalidationRevision !== before.modelsInvalidationRevision || !isAgentConnectionReady(connection.availability) && isAgentConnectionReady(before.availability)) {
        runtime.modelsGeneration += 1
        runtime.modelsProvider = null
        runtime.modelsPromise = null
        updateSnapshot(conversationId, current => current.provider === provider ? { ...current, models: [] } : current)
      }
      if (store.connections[provider].modelsRevision !== previous.connections[provider].modelsRevision) loadModels(courseId, conversationId, provider)
    })
    runtime.unsubscribe = () => { unsubscribeBatch(); unsubscribeMessage(); unsubscribeSettings(); unsubscribeConnection() }
    void openConversation(
      courseId,
      conversationId,
      { discardQueue: false },
      surface
    )
  }

  let released = false
  return () => {
    if (released) {
      return
    }
    released = true
    runtime.refCount = Math.max(0, runtime.refCount - 1)
    if (runtime.refCount !== 0) {
      return
    }
    runtime.unsubscribe?.()
    runtime.unsubscribe = null
    runtime.openVersion += 1
    runtime.hydrating = false
    runtime.lastSeq = null
    runtime.queue = []
    if (runtime.raf !== null) {
      cancelAnimationFrame(runtime.raf)
      runtime.raf = null
    }
  }
}

export async function sendChatMessage(
  courseId: string,
  conversationId: string,
  content: string,
  attachments: ChatAttachment[] = [],
  context?: ChatContext
): Promise<void> {
  const text = content.trim()
  if (text === '' && attachments.length === 0 && !context) {
    return
  }
  const localId = `local-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
  // First message doubles as the title — optimistic, and identical to the rule
  // main applies in setTitleIfEmpty, so the next open confirms it unchanged.
  const derivedTitle = text.replace(/\s+/g, ' ').trim().slice(0, 60)
  updateSnapshot(conversationId, (current) => ({
    ...current,
    title: current.title ?? (derivedTitle === '' ? null : derivedTitle),
    state: appendLocalUserMessage(current.state, localId, text, attachments, context)
  }))
  const request = {
    courseId,
    sessionId: conversationId,
    content: text,
    ...(context ? { context } : {}),
    ...(attachments.length === 0 ? {} : { attachments })
  }
  try { await invoke('chat:send', request) } catch (error) {
    updateSnapshot(conversationId, (current) => ({
      ...current, state: { ...markSendFailed(current.state), messages: current.state.messages.filter((message) => message.id !== localId) }
    }))
    throw error
  }
}

export function cancelChatTurn(courseId: string, conversationId: string): void {
  void invoke('chat:cancel', { courseId, sessionId: conversationId }).catch(() => {
    // Best-effort: turn-complete(interrupted) is authoritative.
  })
}

export function respondToChatPermission(
  courseId: string, conversationId: string, requestId: string, response: PermissionResponse
): void {
  if (snapshotFor(conversationId).permissionResponses?.[requestId] === 'pending') return
  updateSnapshot(conversationId, (current) => ({ ...current, permissionResponses: { ...current.permissionResponses, [requestId]: 'pending' } }))
  void invoke('chat:respondPermission', { courseId, sessionId: conversationId, requestId, response })
    // Keep the latch until the authoritative permission-resolved event. A slow
    // push must not make a successfully submitted button clickable again.
    .catch(() => updateSnapshot(conversationId, (current) => current.state.pendingPermissionId !== requestId ? current : ({ ...current, permissionResponses: { ...current.permissionResponses, [requestId]: 'error' } })))
}

export async function setChatConfiguration(courseId: string, conversationId: string, model: string, effort: string | null): Promise<void> {
  if (snapshotFor(conversationId).configuring) return
  updateSnapshot(conversationId, (current) => ({ ...current, configuring: true, configurationError: null }))
  try {
    const result = await invoke('chat:setConfiguration', { courseId, sessionId: conversationId, model, effort })
    updateSnapshot(conversationId, (current) => ({ ...current, effort: result.effort, state: { ...current.state, model: result.model } }))
  } catch (error) {
    updateSnapshot(conversationId, (current) => ({ ...current, configurationError: errorMessage(error) }))
    throw error
  } finally { updateSnapshot(conversationId, (current) => ({ ...current, configuring: false })) }
}

export function refreshChatSession(
  courseId: string,
  conversationId: string
): void {
  void openConversation(courseId, conversationId, { discardQueue: false })
}

export function dismissChatNotice(
  _courseId: string,
  conversationId: string
): void {
  updateSnapshot(conversationId, (current) => ({
    ...current,
    state: clearNotice(current.state)
  }))
}

export function setChatModel(
  courseId: string,
  conversationId: string,
  model: string
): void {
  void invoke('chat:setModel', { courseId, sessionId: conversationId, model })
    .then(() => {
      updateSnapshot(conversationId, (current) => ({
        ...current,
        state: { ...current.state, model }
      }))
    })
    .catch(() => {
      // Keep the previously confirmed selection when changing the model fails.
    })
}

/**
 * Saves the preferred provider and switches THIS conversation to it in place
 * (same id, same tab). Main clears the old CLI's resume record and persists a
 * system notice; the next send replays the prior transcript into the new
 * CLI's first prompt. The conversation is then reopened so the notice, the
 * provider's availability and its model list all come from the new provider.
 */
export async function setChatProvider(
  courseId: string,
  conversationId: string,
  provider: AgentProvider
): Promise<void> {
  const runtime = runtimeFor(courseId, conversationId)
  const generation = ++runtime.providerGeneration
  runtime.openVersion += 1
  runtime.modelsGeneration += 1
  runtime.modelsProvider = null
  runtime.modelsPromise = null
  updateSnapshot(conversationId, (current) => ({
    ...current,
    provider,
    phase: 'loading',
    availability: null,
    openError: null,
    models: []
  }))
  try {
    await invoke('settings:set', { agentProvider: provider })
    if (runtime.providerGeneration !== generation) return
    await invoke('chat:setProvider', {
      courseId,
      sessionId: conversationId,
      provider,
      surface: runtime.surface
    })
    if (runtime.providerGeneration === generation) {
      await openConversation(courseId, conversationId, { discardQueue: true })
    }
  } catch (error: unknown) {
    // A newer switch already owns the snapshot — leave its state alone.
    if (runtime.providerGeneration !== generation) {
      return
    }
    updateSnapshot(conversationId, (current) => ({
      ...current,
      phase: 'error',
      openError: errorMessage(error)
    }))
  }
}

export function selectChatSession(conversationId: string): ChatSessionSnapshot {
  return snapshotFor(conversationId)
}
