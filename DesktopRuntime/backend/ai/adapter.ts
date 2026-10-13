import { randomUUID } from '../shims/crypto'
import type { AgentAdapter, AgentEvent, AgentProvider, AgentSession, AgentStartSessionOptions } from '../../upstream/src/shared/types/agent-events'
import type { ChatRepo } from '../../upstream/src/main/features/agent/chatRepo'
import type { AgentTools } from '../../upstream/src/main/features/agentTools/tools'

export const platform = (channel: string, request: unknown = {}): Promise<any> => (globalThis as any).__bandalPlatform.invoke(channel, request)
interface Running { event: (event: any) => void; tool: (call: any) => Promise<string> }
const running = new Map<string, Running>()
export function receiveEvent(request: any) { running.get(request.requestId)?.event(request.event); return { ok: true } }
export async function receiveTool(request: any) {
  const active = running.get(request.requestId)
  if (!active) throw new Error('AI 요청이 취소되었거나 종료되었습니다.')
  return active.tool(request.call)
}

export function createNativeAdapter(provider: AgentProvider, repo: ChatRepo,
  toolsFor: (sessionId: string) => AgentTools, cancelled: (sessionId: string) => void): AgentAdapter {
  return {
    provider,
    capabilities: { imageInput: true, resume: true, interactivePermissions: true, streamingInput: false, partialText: true, cancel: true },
    checkAvailability: () => platform('native:aiAvailability', { provider }),
    async startSession(options: AgentStartSessionOptions): Promise<AgentSession> {
      const availability = await platform('native:aiAvailability', { provider })
      if (!availability.loggedIn) throw new Error(availability.reason)
      const conversation = options.mcpExtraEnv?.BANDAL_NATIVE_CONVERSATION_ID
      if (!conversation) throw new Error('네이티브 API 대화 연결이 없습니다.')
      const tools = toolsFor(conversation)
      const history: any[] = (options.resumeCliSessionId ? repo.historyTail(conversation) : []).map(message => ({ role: message.role,
        text: message.blocks.filter(block => block.kind === 'text').map(block => (block.payload as any)?.text ?? '').join('\n'),
        images: message.blocks.flatMap(block => (block.payload as any)?.images ?? []) })).filter(message => message.text || message.images.length)
      const identifier = options.resumeCliSessionId ?? randomUUID()
      const listeners = new Set<(event: AgentEvent) => void>()
      let active: string | null = null, text = '', closed = false
      let queue: AgentEvent[] = [], wake: (() => void) | undefined, iterating = false
      const emit = (event: AgentEvent) => { if (closed) return; for (const listener of listeners) listener(event); if (iterating) queue.push(event); wake?.(); wake = undefined }
      const session: AgentSession = {
        get closed() { return closed },
        sessionId: Promise.resolve(identifier),
        events: { async *[Symbol.asyncIterator]() { iterating = true; try { while (!closed) { if (!queue.length) await new Promise<void>(resolve => { wake = resolve }); for (const event of queue) yield event; queue = [] } } finally { iterating = false; queue = [] } } },
        on(callback) { listeners.add(callback); return () => { listeners.delete(callback) } },
        sendMessage(content, attachments = []) {
          if (closed || active) throw new Error('AI 대화가 닫혔거나 이미 응답 중입니다.')
          const requestId = randomUUID(), blockId = randomUUID(), started = Date.now()
          active = requestId; text = ''
          history.push({ role: 'user', text: content, images: [...attachments] })
          emit({ type: 'session-started', sessionId: identifier, provider, model: options.model ?? null })
          running.set(requestId, {
            event(event) { if (active !== requestId) return; if (event.type === 'text-delta' && typeof event.text === 'string') { text += event.text; emit({ type: 'text-delta', blockId, text: event.text }) } },
            async tool(call) {
              if (active !== requestId) throw new Error('AI 요청이 취소되었습니다.')
              if (!tools.names.includes(call.name)) throw new Error('이 대화에 허용되지 않은 AI 도구입니다.')
              const input = JSON.parse(call.arguments)
              emit({ type: 'tool-start', toolCallId: call.id, toolName: call.name, label: call.name, input })
              const result = await tools.call(call.name, input)
              if (active !== requestId) throw new Error('AI 요청이 취소되었습니다.')
              const output = JSON.stringify(result)
              emit({ type: 'tool-end', toolCallId: call.id, ok: !result.isError, result: { summary: result.isError ? '실행 실패' : '완료', preview: output.slice(0, 2000), truncated: output.length > 2000 } })
              return output
            }
          })
          void platform('native:aiRun', { requestId, provider, model: options.model, effort: options.effort,
            system: `${options.systemPromptAppend ?? ''}\nThis is Bandal's native iPad API transport. There is no shell or arbitrary executable runtime. Use only the provided Bandal function tools. Never claim an unperformed action.`,
            messages: history, tools: tools.definitions }).then(result => {
              if (active !== requestId) return
              if (text) history.push({ role: 'assistant', text })
              if (result.model) emit({ type: 'session-started', sessionId: identifier, provider, model: result.model })
              emit({ type: 'text-final', blockId, text: result.text ?? text })
              active = null
              emit({ type: 'turn-complete', stopReason: 'success', usage: result.usage, durationMs: Date.now() - started })
            }, error => {
              if (active !== requestId) return
              if (text) history.push({ role: 'assistant', text })
              emit({ type: 'error', code: /429|한도/.test(error.message) ? 'usage-limit' : 'unknown', message: String(error.message), fatal: false })
              active = null
              emit({ type: 'turn-complete', stopReason: 'error', durationMs: Date.now() - started })
            }).finally(() => { running.delete(requestId); if (active === requestId) active = null })
        },
        respondPermission() { /* App tools use the original AgentConfirmer. No CLI permissions are issued. */ },
        cancel() {
          const requestId = active
          if (!requestId) return
          active = null; running.delete(requestId); cancelled(conversation)
          void platform('native:aiCancel', { provider, requestId }).catch(() => undefined)
          if (text) history.push({ role: 'assistant', text })
          emit({ type: 'turn-complete', stopReason: 'interrupted' })
        },
        dispose() { session.cancel(); closed = true; listeners.clear(); queue = []; wake?.() }
      }
      return session
    }
  }
}
