/**
 * Per-CONVERSATION batching of AgentEvents into `chat:event-batch` frames.
 *
 * Delta events (text/thinking/tool-input) are coalesced: consecutive deltas
 * for the same block merge into one event, and delivery is debounced 40ms
 * with a 250ms max wait (Orca-derived parameters). Every non-delta event
 * flushes the pending frame immediately so structural updates never lag.
 */

import type { AgentEvent } from '../../../shared/types/agent-events'
import type { ChatEventBatch } from '../../../shared/ipc/events'

export const BATCH_DEBOUNCE_MS = 40
export const BATCH_MAX_WAIT_MS = 250

export interface EventBatcher {
  push(courseId: string, sessionId: string, event: AgentEvent): void
  checkpoint(sessionId: string): number
  flush(sessionId: string): void
  dispose(): void
}

export interface EventBatcherDeps {
  send: (batch: ChatEventBatch) => void
  debounceMs?: number
  maxWaitMs?: number
}

interface SessionBuffer {
  /** Carried on every frame so conversation subscribers can filter by course. */
  courseId: string
  seq: number
  pending: AgentEvent[]
  debounceTimer: NodeJS.Timeout | null
  maxWaitTimer: NodeJS.Timeout | null
}

function isDelta(event: AgentEvent): boolean {
  return (
    event.type === 'text-delta' ||
    event.type === 'thinking-delta' ||
    event.type === 'tool-input-delta'
  )
}

/** Merges `event` into the last pending event when both target one block. */
function tryMerge(pending: AgentEvent[], event: AgentEvent): AgentEvent[] | null {
  const last = pending[pending.length - 1]
  if (last === undefined || last.type !== event.type) {
    return null
  }
  if (
    (event.type === 'text-delta' || event.type === 'thinking-delta') &&
    (last.type === 'text-delta' || last.type === 'thinking-delta') &&
    last.blockId === event.blockId
  ) {
    return [
      ...pending.slice(0, -1),
      { ...last, text: last.text + event.text }
    ]
  }
  if (
    event.type === 'tool-input-delta' &&
    last.type === 'tool-input-delta' &&
    last.toolCallId === event.toolCallId
  ) {
    return [
      ...pending.slice(0, -1),
      { ...last, partialInput: last.partialInput + event.partialInput }
    ]
  }
  return null
}

export function createEventBatcher(deps: EventBatcherDeps): EventBatcher {
  const debounceMs = deps.debounceMs ?? BATCH_DEBOUNCE_MS
  const maxWaitMs = deps.maxWaitMs ?? BATCH_MAX_WAIT_MS
  /** Keyed by CONVERSATION id — seq is monotonic per conversation. */
  const buffers = new Map<string, SessionBuffer>()

  function bufferFor(courseId: string, sessionId: string): SessionBuffer {
    let buffer = buffers.get(sessionId)
    if (buffer === undefined) {
      buffer = {
        courseId,
        seq: 0,
        pending: [],
        debounceTimer: null,
        maxWaitTimer: null
      }
      buffers.set(sessionId, buffer)
    }
    return buffer
  }

  function clearTimers(buffer: SessionBuffer): void {
    if (buffer.debounceTimer !== null) {
      clearTimeout(buffer.debounceTimer)
      buffer.debounceTimer = null
    }
    if (buffer.maxWaitTimer !== null) {
      clearTimeout(buffer.maxWaitTimer)
      buffer.maxWaitTimer = null
    }
  }

  function flushBuffer(sessionId: string, buffer: SessionBuffer): void {
    clearTimers(buffer)
    if (buffer.pending.length === 0) {
      return
    }
    buffer.seq += 1
    const events = buffer.pending
    buffer.pending = []
    deps.send({ courseId: buffer.courseId, sessionId, seq: buffer.seq, events })
  }

  return {
    push: (courseId, sessionId, event) => {
      const buffer = bufferFor(courseId, sessionId)
      const merged = tryMerge(buffer.pending, event)
      buffer.pending = merged ?? [...buffer.pending, event]

      if (!isDelta(event)) {
        flushBuffer(sessionId, buffer)
        return
      }
      if (buffer.debounceTimer !== null) {
        clearTimeout(buffer.debounceTimer)
      }
      buffer.debounceTimer = setTimeout(
        () => flushBuffer(sessionId, buffer),
        debounceMs
      )
      if (buffer.maxWaitTimer === null) {
        buffer.maxWaitTimer = setTimeout(
          () => flushBuffer(sessionId, buffer),
          maxWaitMs
        )
      }
    },
    checkpoint: (sessionId) => {
      const buffer = buffers.get(sessionId)
      if (!buffer) return 0
      flushBuffer(sessionId, buffer)
      return buffer.seq
    },
    flush: (sessionId) => {
      const buffer = buffers.get(sessionId)
      if (buffer !== undefined) {
        flushBuffer(sessionId, buffer)
      }
    },
    dispose: () => {
      for (const [sessionId, buffer] of buffers) {
        flushBuffer(sessionId, buffer)
      }
      buffers.clear()
    }
  }
}
