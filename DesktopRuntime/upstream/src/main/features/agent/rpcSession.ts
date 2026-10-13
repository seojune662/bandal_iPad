import type { ChildProcess } from 'node:child_process'
import type { AgentErrorCode, AgentEvent, AgentSession, AgentStartSessionOptions, PermissionResponse, ToolResultSummary, TurnStopReason, Usage } from '../../../shared/types/agent-events'
import type { ChatAttachment } from '../../../shared/types/chat'
import { createJsonRpc, RpcResponseError, type RpcMessage, type RpcObject } from './jsonRpc'
import { killProcessTree } from './platform'
import { AgentUnavailableError } from './binaryLocator'

export const AGENT_INACTIVITY_MS = 5 * 60 * 1000
export const AGENT_CANCEL_TIMEOUT_MS = 5000

interface Turn {
  sequence: number
  id: string
  cancelled: boolean
  startedAt: number
  usage?: Usage
  errorMessage?: string
  timer?: ReturnType<typeof setTimeout>
  cancelTimer?: ReturnType<typeof setTimeout>
  items: Map<string, RpcObject>
  completedItems: Set<string>
}
interface Approval { id: string | number; method: string; params: RpcObject; turn: Turn }

/** The UI's default choice is not a provider model identifier. */
export function providerModel(model: string | undefined | null): string | undefined {
  const selected = model?.trim()
  return selected && selected !== 'default' ? selected : undefined
}
function errorCode(error: Error): AgentErrorCode {
  if (error instanceof AgentUnavailableError) return error.code
  if (['ENOENT', 'EACCES', 'ENOEXEC'].includes(String((error as NodeJS.ErrnoException).code))) return 'spawn-failed'
  if (error instanceof SyntaxError) return 'malformed-output'
  return /authenticate|authentication|unauthorized|credential|logged.in|login|api.key|(?:OAuth|access|refresh) token.*(?:expired|invalid|revoked)|IneligibleTierError|not eligible|RESTRICTED_DASHER|no longer supported.*Gemini Code Assist/i.test(error.message) ? 'not-logged-in' : error instanceof RpcResponseError ? 'unknown' : 'process-crashed'
}
function resultSummary(item: RpcObject): ToolResultSummary | undefined {
  const content = item.aggregatedOutput ?? item.result?.content ?? item.content ?? item.error?.message
  const text = (typeof content === 'string' ? content : Array.isArray(content) ? content.map(part => part?.text ?? part?.content?.text ?? '').join('\n') : '').trim()
  if (!text) return undefined
  const first = text.split('\n')[0] ?? text
  const summary = first.slice(0, 160)
  return { summary, ...(text.length > summary.length ? { preview: text.slice(0, 2000), truncated: text.length > 2000 } : {}) }
}
function geminiPermission(tool: RpcObject): { toolName: string; input: RpcObject } {
  const raw = tool.rawInput && typeof tool.rawInput === 'object' ? tool.rawInput : {}
  const paths = [
    ...(Array.isArray(tool.locations) ? tool.locations.map(location => location?.path) : []),
    ...(Array.isArray(tool.content) ? tool.content.filter(part => part?.type === 'diff').map(part => part.path) : [])
  ].filter((path): path is string => typeof path === 'string')
  const toolName = tool.kind === 'edit' ? 'fileChange' : tool.kind === 'read' ? 'Read' : tool.kind === 'execute' ? 'Bash' : tool.title ?? tool.kind ?? 'Gemini 작업'
  return { toolName, input: { ...raw, ...(paths.length ? { paths: [...new Set(paths)] } : {}), ...(tool.title ? { title: tool.title } : {}) } }
}

/** One process and configuration per conversation; every async operation owns one turn. */
export function createRpcSession(options: AgentStartSessionOptions, provider: 'codex' | 'gemini', spawn: () => ChildProcess, cleanup: () => void = () => {}): AgentSession {
  const listeners = new Set<(event: AgentEvent) => void>()
  const queues = new Set<{ items: AgentEvent[]; wake?: (() => void) | undefined }>()
  const approvals = new Map<string, Approval>()
  const resolvedApprovals = new Set<string>()
  const completedTurns = new Set<string>()
  let child: ChildProcess | null = null, rpc: ReturnType<typeof createJsonRpc> | null = null
  let disposed = false, terminated = false, exited = false, started = false, cleaned = false, sessionKey = '', sequence = 0
  let active: Turn | null = null, initialization: Promise<void> | null = null
  let supportsImages = true
  let systemContextAccepted = false
  const model = providerModel(options.model)
  let resolveId!: (id: string) => void, rejectId!: (error: Error) => void
  const sessionId = new Promise<string>((resolve, reject) => { resolveId = resolve; rejectId = reject })
  void sessionId.catch(() => {})
  const emit = (event: AgentEvent): void => {
    if (disposed) return
    for (const listener of listeners) listener(event)
    for (const queue of queues) { queue.items.push(event); queue.wake?.() }
  }
  const clean = (): void => { if (!cleaned) { cleaned = true; cleanup() } }
  const turnError = (turn: Turn, message: string, code: AgentErrorCode = 'unknown'): void => {
    if (turn.errorMessage === message) return
    turn.errorMessage = message
    const authenticationFailed = errorCode(new Error(message)) === 'not-logged-in'
    emit({ type: 'error', code: authenticationFailed ? 'not-logged-in' : code, message: authenticationFailed ? `${provider === 'codex' ? 'ChatGPT' : 'Gemini'} 연결을 다시 확인해야 해요. 설정 → AI에서 다시 로그인해 주세요.` : message, fatal: false })
  }
  const clearTimers = (turn: Turn): void => { clearTimeout(turn.timer); clearTimeout(turn.cancelTimer) }
  const discardApprovals = (turn?: Turn): void => {
    for (const [key, approval] of approvals) {
      if (turn && approval.turn !== turn) continue
      approvals.delete(key); resolvedApprovals.add(key)
      emit({ type: 'permission-resolved', requestId: key, behavior: 'deny' })
    }
  }
  const kill = (): void => {
    if (!child?.pid || exited) return
    const pid = child.pid
    killProcessTree(pid, 'SIGTERM')
    const timer = setTimeout(() => { if (!exited && child?.pid === pid) killProcessTree(pid, 'SIGKILL') }, 3000)
    timer.unref()
  }
  const complete = (turn: Turn, reason: TurnStopReason): void => {
    if (active !== turn) return
    active = null; clearTimers(turn)
    if (turn.id) {
      completedTurns.add(turn.id)
      if (completedTurns.size > 100) completedTurns.delete(completedTurns.values().next().value!)
    }
    discardApprovals(turn)
    emit({ type: 'turn-complete', stopReason: reason, durationMs: Date.now() - turn.startedAt, ...(turn.usage ? { usage: turn.usage } : {}) })
  }
  const fatal = (error: Error): void => {
    if (disposed || terminated) return
    terminated = true
    const turn = active
    if (turn) clearTimers(turn)
    // A broken transport cannot receive denial replies. Resolve the UI locally.
    discardApprovals()
    rejectId(error)
    const code = errorCode(error)
    const message = /no longer supported.*Gemini Code Assist/i.test(error.message) ? '현재 Google 계정의 Gemini Code Assist 연결이 서버에서 지원 종료로 거절됐어요. 설정 → AI에서 Gemini API 키를 연결하거나 다른 제공자를 선택해 주세요.' : code === 'not-logged-in' ? `${provider === 'codex' ? 'ChatGPT' : 'Gemini'} 연결을 다시 확인해야 해요. 설정 → AI에서 다시 로그인해 주세요.` : error.message
    emit({ type: 'error', code, message, fatal: true })
    if (turn) complete(turn, turn.cancelled ? 'interrupted' : 'error')
    rpc?.dispose(); kill(); clean()
    for (const queue of queues) queue.wake?.()
  }
  const armTimeout = (turn: Turn): void => {
    clearTimeout(turn.timer)
    if (active !== turn || terminated || turn.cancelled || [...approvals.values()].some(approval => approval.turn === turn)) return
    turn.timer = setTimeout(() => { if (active === turn) fatal(new Error('AI 작업이 5분 동안 응답하지 않았어요. 다시 보내면 대화를 이어갈 수 있어요.')) }, AGENT_INACTIVITY_MS)
    turn.timer.unref()
  }
  const safeReply = (reply: () => void): void => { try { reply() } catch (error) { fatal(error instanceof Error ? error : new Error(String(error))) } }
  function answer(key: string, response: PermissionResponse): void {
    const pending = approvals.get(key)
    if (!pending) return
    // Remove before writing/emitting: disposal and provider echoes are reentrant.
    approvals.delete(key); resolvedApprovals.add(key)
    if (pending.turn !== active || terminated || disposed || !rpc || rpc.closed) {
      emit({ type: 'permission-resolved', requestId: key, behavior: 'deny' }); return
    }
    const allow = response.behavior === 'allow'
    let result: unknown
    if (provider === 'gemini') {
      const choices = pending.params.options as { optionId: string; kind: string }[] | undefined
      const selected = choices?.find(option => option.kind === (allow ? 'allow_once' : 'reject_once'))
      result = selected ? { outcome: { outcome: 'selected', optionId: selected.optionId } } : { outcome: { outcome: 'cancelled' } }
    } else if (pending.method === 'item/permissions/requestApproval') result = { permissions: allow ? pending.params.permissions ?? {} : {}, scope: 'turn' }
    else if (pending.method === 'mcpServer/elicitation/request') result = { action: allow ? 'accept' : 'decline', content: null }
    else result = { decision: allow ? 'accept' : 'decline' }
    safeReply(() => rpc!.respond(pending.id, result))
    emit({ type: 'permission-resolved', requestId: key, behavior: response.behavior })
    armTimeout(pending.turn)
  }
  function receive(message: RpcMessage): void {
    if (terminated || disposed) return
    const p = message.params ?? {}, method = message.method ?? '', turn = active
    const foreignSession = provider === 'codex' ? p.threadId && sessionKey && p.threadId !== sessionKey : p.sessionId && sessionKey && p.sessionId !== sessionKey
    const notificationTurn = p.turnId ?? p.turn?.id
    const foreignTurn = notificationTurn && (completedTurns.has(notificationTurn) || (turn?.id && notificationTurn !== turn.id))
    if (foreignSession || foreignTurn || !turn) {
      if (message.id !== undefined && rpc) safeReply(() => rpc!.reject(message.id!, '이미 끝났거나 다른 대화의 요청이에요.'))
      return
    }
    if (message.id !== undefined) {
      const supported = provider === 'gemini' ? method === 'session/request_permission' : ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/permissions/requestApproval', 'mcpServer/elicitation/request'].includes(method)
      if (!supported) { safeReply(() => rpc!.reject(message.id!, '이 요청은 반달에서 지원하지 않아요. 대화로 필요한 내용을 물어봐 주세요.')); return }
      const key = `${provider}:${typeof message.id}:${message.id}`
      if (approvals.has(key) || resolvedApprovals.has(key)) return
      if (turn.cancelled) {
        approvals.set(key, { id: message.id, method, params: p, turn }); answer(key, { behavior: 'deny' }); return
      }
      clearTimeout(turn.timer)
      approvals.set(key, { id: message.id, method, params: p, turn })
      const item = turn.items.get(p.itemId) ?? {}
      const gemini = provider === 'gemini' ? geminiPermission(p.toolCall ?? {}) : null
      const toolName = gemini?.toolName ?? (method.includes('commandExecution') ? 'Bash' : method.includes('fileChange') ? 'fileChange' : method === 'mcpServer/elicitation/request' ? 'serviceAuthorization' : '추가 접근')
      const paths = Array.isArray(item.changes) ? item.changes.map(change => change?.path).filter((path): path is string => typeof path === 'string') : []
      const input = gemini?.input ?? { ...p, ...(paths.length ? { paths } : p.grantRoot ? { path: p.grantRoot } : {}) }
      if (provider === 'gemini' && p.toolCall?.toolCallId) emit({ type: 'tool-start', toolCallId: p.toolCall.toolCallId, toolName, label: p.toolCall.title ?? toolName, input })
      emit({ type: 'permission-request', requestId: key, toolName, input })
      return
    }
    armTimeout(turn)
    if (provider === 'codex') {
      if (method === 'turn/started') turn.id = p.turn?.id ?? turn.id
      if (method === 'item/agentMessage/delta') emit({ type: 'text-delta', blockId: p.itemId, text: p.delta ?? '' })
      if (method === 'item/reasoning/summaryTextDelta' || method === 'item/reasoning/textDelta') emit({ type: 'thinking-delta', blockId: p.itemId, text: p.delta ?? '' })
      if (method === 'item/started' || method === 'item/completed') {
        const item = p.item ?? {}, id = item.id ?? ''
        if (method === 'item/completed' && turn.completedItems.has(id)) return
        turn.items.set(id, item)
        if (method === 'item/completed') turn.completedItems.add(id)
        if (item.type === 'agentMessage' && method === 'item/completed') emit({ type: 'text-final', blockId: id, text: item.text ?? '' })
        else if (['commandExecution', 'fileChange', 'mcpToolCall', 'webSearch', 'imageGeneration'].includes(item.type)) {
          if (method === 'item/started') emit({ type: 'tool-start', toolCallId: id, toolName: item.tool ?? item.type, label: item.command ?? item.tool ?? item.type, input: item.arguments ?? item })
          else {
            const result = resultSummary(item)
            emit({ type: 'tool-end', toolCallId: id, ok: !['failed', 'declined'].includes(item.status) && !item.error && !(typeof item.exitCode === 'number' && item.exitCode !== 0), ...(result ? { result } : {}) })
          }
        }
      }
      if (method === 'serverRequest/resolved') {
        const key = `codex:${typeof p.requestId}:${p.requestId}`
        if (approvals.delete(key)) { resolvedApprovals.add(key); armTimeout(turn); emit({ type: 'permission-resolved', requestId: key, behavior: 'deny' }) }
      }
      if (method === 'thread/tokenUsage/updated') {
        const u = p.tokenUsage?.last
        if (u) { turn.usage = { inputTokens: u.inputTokens ?? 0, outputTokens: u.outputTokens ?? 0, cacheReadTokens: u.cachedInputTokens ?? 0 }; emit({ type: 'usage', usage: turn.usage }) }
      }
      if (method === 'turn/completed') {
        if (!turn.id && typeof p.turn?.id === 'string') turn.id = p.turn.id
        if (p.turn?.error) turnError(turn, p.turn.error.message ?? '응답을 완료하지 못했어요.')
        complete(turn, turn.cancelled || p.turn?.status === 'interrupted' ? 'interrupted' : p.turn?.status === 'failed' ? 'error' : 'success')
      }
      // The protocol follows this error with turn/completed. Keep the turn busy.
      if (method === 'error' && !p.willRetry) turnError(turn, p.error?.message ?? 'Codex 연결 오류')
    } else if (method === 'session/update' && started) {
      const u = p.update ?? {}, id = u.toolCallId ?? `gemini-${turn.sequence}`
      if (u.sessionUpdate === 'agent_message_chunk' && u.content?.type === 'text') emit({ type: 'text-delta', blockId: id, text: u.content.text })
      if (u.sessionUpdate === 'agent_thought_chunk' && u.content?.type === 'text') emit({ type: 'thinking-delta', blockId: `${id}-thinking`, text: u.content.text })
      if (u.sessionUpdate === 'tool_call') emit({ type: 'tool-start', toolCallId: id, toolName: u.kind ?? 'tool', label: u.title ?? '작업 중', input: u.rawInput })
      if (u.sessionUpdate === 'tool_call_update' && ['completed', 'failed'].includes(u.status) && !turn.completedItems.has(id)) {
        turn.completedItems.add(id)
        const result = resultSummary(u)
        emit({ type: 'tool-end', toolCallId: id, ok: u.status === 'completed', ...(result ? { result } : {}) })
      }
    }
  }
  async function initialize(): Promise<void> {
    child = spawn()
    child.once('close', () => { exited = true })
    rpc = createJsonRpc(child, receive, fatal)
    child.stderr?.on('data', () => {})
    let actualModel: string | null = model ?? null
    if (provider === 'codex') {
      await rpc.request('initialize', { clientInfo: { name: 'bandal', title: 'Bandal', version: '0.60.0' }, capabilities: {} })
      if (disposed || terminated) return
      rpc.notify('initialized')
      const common = { cwd: options.cwd, ...(model ? { model } : {}), approvalPolicy: 'untrusted', approvalsReviewer: 'user', sandbox: options.accessPolicy?.mode === 'full' && options.accessPolicy.scope.course ? 'workspace-write' : 'read-only', developerInstructions: options.systemPromptAppend ?? null,
        ...(options.webSearch ? { config: { web_search: options.webSearch } } : {}) }
      const result = await rpc.request(options.resumeCliSessionId ? 'thread/resume' : 'thread/start', { ...common, ...(options.resumeCliSessionId ? { threadId: options.resumeCliSessionId } : {}) })
      sessionKey = result.thread.id
      actualModel = typeof result.model === 'string' ? result.model : actualModel
    } else {
      const initialized = await rpc.request('initialize', { protocolVersion: 1, clientInfo: { name: 'bandal', version: '0.60.0' }, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } })
      if (disposed || terminated) return
      supportsImages = initialized.agentCapabilities?.promptCapabilities?.image === true
      if (options.resumeCliSessionId && !initialized.agentCapabilities?.loadSession) throw new Error('이 Gemini CLI는 대화 재개를 지원하지 않아요. 설정 → AI에서 업데이트해 주세요.')
      const params = { cwd: options.cwd, mcpServers: [], ...(options.resumeCliSessionId ? { sessionId: options.resumeCliSessionId } : {}) }
      const result = await rpc.request(options.resumeCliSessionId ? 'session/load' : 'session/new', params)
      sessionKey = options.resumeCliSessionId ?? result.sessionId
      actualModel = typeof result.models?.currentModelId === 'string' ? result.models.currentModelId : actualModel
      if (model) { await rpc.request('session/set_model', { sessionId: sessionKey, modelId: model }); actualModel = model }
    }
    if (disposed || terminated) return
    started = true; resolveId(sessionKey)
    emit({ type: 'session-started', sessionId: sessionKey, model: actualModel, provider })
  }
  function interrupt(turn: Turn): void {
    if (active !== turn || terminated || !rpc || !sessionKey) return
    if (provider === 'gemini') safeReply(() => rpc!.notify('session/cancel', { sessionId: sessionKey }))
    else if (turn.id) void rpc.request('turn/interrupt', { threadId: sessionKey, turnId: turn.id }).catch(error => { if (active === turn) fatal(error) })
  }
  return {
    sessionId,
    get closed() { return disposed || terminated },
    on(callback) { listeners.add(callback); return () => listeners.delete(callback) },
    events: { [Symbol.asyncIterator]() { const queue = { items: [] as AgentEvent[], wake: undefined as (() => void) | undefined }; queues.add(queue); return {
      async next(): Promise<IteratorResult<AgentEvent>> { for (;;) { const item = queue.items.shift(); if (item) return { value: item, done: false }; if (disposed || terminated) { queues.delete(queue); return { value: undefined, done: true } }; await new Promise<void>(resolve => { queue.wake = resolve }); queue.wake = undefined } },
      async return(): Promise<IteratorResult<AgentEvent>> { queues.delete(queue); return { value: undefined, done: true } }
    } } },
    sendMessage(content: string, attachments: ChatAttachment[] = []) {
      if (disposed || terminated) throw new Error('AI 연결이 닫혔어요. 다시 보내 주세요.')
      if (active) throw new Error('진행 중인 응답을 마친 뒤 보내 주세요.')
      const turn: Turn = { sequence: ++sequence, id: '', cancelled: false, startedAt: Date.now(), items: new Map(), completedItems: new Set() }
      active = turn; armTimeout(turn)
      initialization ??= initialize()
      void initialization.then(async () => {
        if (active !== turn || disposed || terminated) return
        if (turn.cancelled) { complete(turn, 'interrupted'); return }
        if (attachments.length && !supportsImages) throw new RpcResponseError('session/prompt', -32602, '이 Gemini CLI는 이미지 입력을 지원하지 않아요. 설정 → AI에서 업데이트해 주세요.')
        if (provider === 'codex') {
          const result = await rpc!.request('turn/start', { threadId: sessionKey, input: [{ type: 'text', text: content }, ...attachments.map(image => ({ type: 'image', url: `data:${image.mediaType};base64,${image.dataBase64}` }))], ...(model ? { model } : {}), ...(options.effort ? { effort: options.effort } : {}) })
          if (active !== turn || disposed || terminated) return
          turn.id = result.turn?.id ?? turn.id
          if (turn.cancelled) interrupt(turn)
        } else {
          const text = !systemContextAccepted && options.systemPromptAppend ? `${options.systemPromptAppend}\n\n${content}` : content
          const result = await rpc!.request('session/prompt', { sessionId: sessionKey, prompt: [{ type: 'text', text }, ...attachments.map(image => ({ type: 'image', mimeType: image.mediaType, data: image.dataBase64 }))] }, 0)
          if (active !== turn || disposed || terminated) return
          if (!turn.cancelled && result.stopReason !== 'cancelled') systemContextAccepted = true
          complete(turn, turn.cancelled || result.stopReason === 'cancelled' ? 'interrupted' : result.stopReason === 'max_tokens' ? 'budget' : result.stopReason === 'max_turn_requests' ? 'max-turns' : 'success')
        }
      }).catch(error => {
        if (active !== turn || disposed || terminated) return
        if (started && error instanceof RpcResponseError && errorCode(error) !== 'not-logged-in') {
          turnError(turn, error.message, errorCode(error)); complete(turn, turn.cancelled ? 'interrupted' : 'error')
        } else fatal(error instanceof Error ? error : new Error(String(error)))
      })
    },
    respondPermission: answer,
    cancel() {
      const turn = active
      if (!turn || turn.cancelled || disposed || terminated) return
      turn.cancelled = true; clearTimeout(turn.timer)
      for (const [key] of approvals) answer(key, { behavior: 'deny' })
      interrupt(turn)
      if (active !== turn || terminated || disposed) return
      turn.cancelTimer = setTimeout(() => {
        if (active !== turn || terminated || disposed) return
        terminated = true; discardApprovals(); complete(turn, 'interrupted')
        rpc?.dispose(); rejectId(new Error('응답을 취소했어요.')); kill(); clean()
        for (const queue of queues) queue.wake?.()
      }, AGENT_CANCEL_TIMEOUT_MS)
      turn.cancelTimer.unref()
    },
    dispose() {
      if (disposed) return
      disposed = true
      if (active) clearTimers(active)
      active = null; approvals.clear(); rpc?.dispose(); rejectId(new Error('대화를 닫았어요.'))
      kill(); clean()
      for (const queue of queues) queue.wake?.()
    }
  }
}
