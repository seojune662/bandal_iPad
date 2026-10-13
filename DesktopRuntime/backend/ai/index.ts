import './abort'
import { createWorkflowBridge } from './workflow'
import { createBrowserBridge } from './browser-port'
import { AGENT_PROVIDERS, isAgentProvider, type AgentProvider } from '../../upstream/src/shared/types/agent-events'
import { createSessionManager } from '../../upstream/src/main/features/agent/SessionManager'
import { createEventBatcher } from '../../upstream/src/main/features/agent/eventBatcher'
import { resolveConversationProvider } from '../../upstream/src/main/features/agent/conversationRouting'
import { serializeTranscript, CARRYOVER_HISTORY_LIMIT } from '../../upstream/src/main/features/agent/transcriptCarryover'
import { createAgentConfirmer } from '../../upstream/src/main/features/agentTools/confirm'
import { createAgentJournal } from '../../upstream/src/main/features/agentTools/journal'
import { createAgentTools, type AgentTools } from '../../upstream/src/main/features/agentTools/tools'
import { DEFAULT_AI_ACCESS, parseAiAccess } from '../../upstream/src/shared/types/aiAccess'
import { appPermissionAllowed } from '../../upstream/src/main/features/agent/accessPolicy'
import { getSettings } from '../../upstream/src/main/settingsStore'
import { parseMaterialEditTargetId, restoreMaterialBackup } from '../../upstream/src/main/features/agentTools/documentBackup'
import { randomUUID } from '../shims/crypto'
import { emit } from '../native'
import { sendLearningWithSession, validateConnectedLearningAi } from '../../upstream/src/main/features/learning/learningAgent'
import { createLearningGrounding } from '../../upstream/src/main/features/learning/learningGrounding'
import type { LearningAiSettings } from '../../upstream/src/shared/types/learning'
import type { createLearningRuntime } from '../../upstream/src/main/features/learning/learningRuntime'
import { createNativeAdapter, platform, receiveEvent, receiveTool } from './adapter'

type Handler = (request: any) => unknown | Promise<unknown>
export function installAI(deps: { handle: (channel: string, action: Handler) => void; handlePrivate: (channel: string, action: Handler) => void; db: any; courses: any; chat: any; usage: any; repositories: any; mcp: ReturnType<typeof import('../mcp').installMCP>; invoke: (channel: string, request?: any) => Promise<any> }) {
  const { handle, chat, courses, repositories: repos } = deps
  const warm = new Map<string, AgentProvider>(), surfaces = new Map<string, 'app' | 'desktop' | 'study'>(), toolSets = new Map<string, AgentTools>()
  let workflow: ReturnType<typeof createWorkflowBridge>
  let learning: ReturnType<typeof createLearningRuntime> | undefined
  const grounding = createLearningGrounding(id => courses.getFolder(id))
  const blockedModels = new Map<AgentProvider, Set<string>>()
  async function validateLearningAi(ai: LearningAiSettings): Promise<LearningAiSettings> {
    if (!isAgentProvider(ai.provider) || !ai.model?.trim() || ['default', 'auto'].includes(ai.model)) throw new Error('학습 공간에서 AI 제공자와 모델을 직접 선택하세요.')
    return validateConnectedLearningAi(ai, provider => platform('native:aiAvailability', { provider }), async selected => {
      const catalog = await platform('native:aiModels', { provider: selected.provider })
      const model = catalog.models.find((item: any) => !item.isDefault && (item.id === selected.model || item.resolvedModel === selected.model))
      if (!model || blockedModels.get(selected.provider)?.has(selected.model)) throw new Error('현재 연결에서 사용할 모델을 다시 선택하세요. 필요하면 모델 목록을 새로고침하세요.')
      if (selected.effort !== null && !model.supportedEfforts?.includes(selected.effort)) throw new Error('선택한 모델에서 지원하지 않는 사고 수준입니다.')
      return selected
    })
  }
  let workspace: any = { selectedCourseId: null, tabs: [], documents: [] }
  const batches = createEventBatcher({ send: batch => emit('chat:event-batch', batch) })
  const confirmer = createAgentConfirmer({
    allow: request => {
      const session = chat.getSession(request.conversationId)
      // Keep native browser/site, screen, remote-server and provider requests
      // behind their explicit approval boundary. Course tools follow the exact
      // current desktop policy, including deliberate restricted choices.
      if (session?.surface === 'study' || /^(browser_|lms_|desktop_|clipboard|mcp_|cli:)/.test(request.tool)) return false
      return appPermissionAllowed(session?.accessPolicy ?? DEFAULT_AI_ACCESS, request.tool, request.courseId === session?.courseId)
    },
    emit: request => emit('agentTools:confirm', request), changed: state => emit('agentTools:confirmationChanged', state)
  })
  const journal = createAgentJournal(deps.db)
  const browser = createBrowserBridge({ db: deps.db, courses, courseLinks: repos.courseLinks, confirmer, handle, onTabs: (courseId, tabs) => { workspace.browserTabs = [...(workspace.browserTabs ?? []).filter((tab: any) => tab.courseId !== courseId), ...tabs] } })
  const managers = Object.fromEntries(AGENT_PROVIDERS.map(provider => {
    const adapter = createNativeAdapter(provider, chat, id => { const tools = toolSets.get(id); if (!tools) throw new Error('대화 도구 연결이 종료되었습니다.'); return tools }, id => { deps.mcp.cancel(id); confirmer.cancelConversation(id) })
    return [provider, createSessionManager({ adapter, repo: { ...chat,
      // The access-policy control may persist a provisional conversation while
      // SessionManager is awaiting provider availability. Adopt that exact row
      // on first send without losing its policy or creating a duplicate ID.
      createSession: (id: string, courseId: string, selectedProvider: AgentProvider, surface: string) => {
        const existing = chat.getSession(id)
        if (existing && existing.courseId === courseId && existing.provider === selectedProvider && existing.surface === surface) return existing
        return chat.createSession(id, courseId, selectedProvider, surface)
      }
    },
      getCourse: id => { const course = courses.getById(id); return { folder: courses.getFolder(id), name: course.name } },
      emit: (courseId, sessionId, event) => batches.push(courseId, sessionId, event),
      eventCheckpoint: id => batches.checkpoint(id),
      onUserMessage: message => emit('chat:message', { sessionId: message.sessionId, message }),
      onUsage: input => deps.usage.record(input),
      onTurnSettled: ({ courseId, sessionId, turnSeq, reason, error }) => {
        browser.finish(sessionId); workflow?.settle({ sessionId, reason, error })
        if (reason === 'success' && !learning?.isStudySession(sessionId)) emit('runtime:notification', { kind: 'agentComplete', id: `${sessionId}:${turnSeq}`, title: 'AI 응답이 도착했어요', body: (() => { try { return courses.getById(courseId)?.name ?? '' } catch { return '' } })(), courseId })
        void learning?.settle(sessionId, reason, error).catch(error => emit('backend:error', { operation: 'learning.settle', message: String(error) }))
      },
      requestPermission: request => confirmer.confirm(request),
      onRequestsCancelled: id => { deps.mcp.cancel(id); browser.finish(id); confirmer.cancelConversation(id) },
      onPermissionResolved: (id, requestId) => confirmer.cancelProviderRequest(id, requestId),
      async startToolServer(courseId, sessionId, turnSeq, surface) {
        const remoteTools = surface === 'desktop'
        if (remoteTools) await deps.mcp.refresh()
        const originalTools = createAgentTools({ courseId, getTurnId: () => `${sessionId}:${turnSeq()}`,
          packRunGuard: { restrictionFor: id => workflow?.restrictionFor(id) ?? null }, packGuardKey: sessionId,
          browser: browser.toolsFor(courseId, sessionId, () => `${sessionId}:${turnSeq()}`),
          learning: { restriction: () => learning?.restrictionFor(sessionId) ?? null,
            verifyArticle: url => { if (!learning) throw new Error('학습 실행을 준비 중입니다.'); return learning.verifyArticle(sessionId, url) },
            submitResult: draft => { if (!learning) throw new Error('학습 실행을 준비 중입니다.'); return learning.submitResult(sessionId, draft) },
            readMaterial: async (requestedCourseId, relPath, maxChars) => {
              if (requestedCourseId !== courseId) throw new Error('이 학습 공간의 과목 자료만 사용할 수 있어요.')
              const source = await grounding.material({ courseId, rootRelPath: '' }, relPath)
              return { relPath, pathScope: 'course', supported: true, contentHash: source.contentHash, text: source.text.slice(0, maxChars), truncated: source.truncated || source.text.length > maxChars }
            } },
          accessMode: () => chat.getSession(sessionId)?.accessPolicy?.mode ?? 'auto',
          coursesRepo: courses, courseGroupsRepo: repos.groups, courseLinksRepo: repos.courseLinks,
          materialsRepo: { ...repos.materials, writeFile: (input: any) => repos.materials.writeFile({ ...input, createDirIfMissing: true }) }, materialLinksRepo: repos.links, notesRepo: repos.notes,
          favoritesRepo: repos.favorites, boardRepo: repos.board, canvasRepo: repos.canvas,
          linkService: repos.linkService, searchIndex: { query: (...args: any[]) => deps.invoke('search:query', { courseId: args[0], query: args[1], limit: args[2] }).then(result => result.hits) },
          appState: () => ({ selectedCourseId: workspace.selectedCourseId, groups: repos.groups.list(), courses: courses.list().map((course: any) => ({ id: course.id, name: course.name, groupId: course.groupId, groupName: repos.groups.list().find((group: any) => group.id === course.groupId)?.name ?? null })), workspaceTabs: workspace.tabs ?? [], browserTabs: getSettings().browser.agentUse ? workspace.browserTabs ?? [] : [] }),
          confirm: async input => (await confirmer.confirm({ ...input, conversationId: sessionId })) !== false,
          journal: { record: entry => { journal.record(entry); emit('materials:changed', { courseId: entry.courseId }); emit('courses:changed', {}); emit('board:changed', { courseId: entry.courseId }) } }
        })
        const tools = remoteTools ? deps.mcp.wrap(originalTools, { courseId, sessionId, turn: () => `${sessionId}:${turnSeq()}`,
          restriction: () => learning?.restrictionFor(sessionId) ?? workflow?.restrictionFor(sessionId) ?? null,
          confirm: request => confirmer.confirm(request) }) : originalTools
        toolSets.set(sessionId, tools)
        // SessionManager passes this descriptor to the provider adapter. The
        // native API adapter invokes tools in-process; no HTTP server is faked.
        return { mcpConfigPath: '', extraAllowedTools: tools.names, extraEnv: { BANDAL_NATIVE_CONVERSATION_ID: sessionId }, codexOverrides: [],
          mcpHint: 'Bandal function tools are available through the native API connection.', url: `bandal-api://conversation/${sessionId}`, token: '',
          close: async () => { deps.mcp.cancel(sessionId); browser.finish(sessionId); toolSets.delete(sessionId); confirmer.cancelConversation(sessionId) } }
      }
    })]
  })) as Record<AgentProvider, ReturnType<typeof createSessionManager>>
  async function manager(request: any) {
    courses.getById(request.courseId)
    const saved = chat.getSession(request.sessionId)
    if (saved && saved.courseId !== request.courseId) throw new Error('대화가 이 과목에 속하지 않습니다.')
    const provider = await resolveConversationProvider({ storedProvider: saved?.provider, warmProvider: warm.get(request.sessionId), preferredProvider: getSettings().agentProvider,
      check: provider => platform('native:aiAvailability', { provider }) })
    warm.set(request.sessionId, provider); return managers[provider]
  }
  workflow = createWorkflowBridge({ chat, courses, manager, confirm: request => confirmer.confirm(request) })
  deps.handlePrivate('nativeAI:event', receiveEvent); deps.handlePrivate('nativeAI:tool', receiveTool)
  deps.handlePrivate('nativeAI:workspace', request => { workspace = { ...request, browserTabs: workspace.browserTabs ?? [] }; return { ok: true } })
  handle('chat:context', request => {
    const course = courses.getById(request.courseId)
    const material = (workspace.documents ?? []).find((item: any) => item.courseId === request.courseId && (workspace.tabs ?? []).some((tab: any) => tab.active && ((item.documentId && tab.documentId === item.documentId) || (item.relPath && tab.relPath === item.relPath))))
    return { id: workspace.refreshId ?? randomUUID(), courseId: course.id, courseName: course.name, capturedAt: new Date().toISOString(), ...(material ? { material: { ...material, ...(workspace.selection ? { selection: workspace.selection } : {}) } } : {}), refresh: material ? 'cached' : 'failed' }
  })
  handle('agent:availability', request => { if (!isAgentProvider(request.provider)) throw new Error('Unknown AI provider'); return platform('native:aiAvailability', request) })
  handle('agent:models', request => { if (request.refresh) blockedModels.delete(request.provider); return platform('native:aiModels', request) })
  handle('agent:apiKey', request => platform('native:aiKeyStatus', request))
  handle('agent:setApiKey', async request => { const result = await platform('native:aiSetKey', request); if (isAgentProvider(request.provider)) managers[request.provider].invalidateCredentials(); return result })
  handle('agent:geminiApiKey', () => platform('native:aiKeyStatus', { provider: 'gemini' }))
  handle('agent:setGeminiApiKey', async request => { const result = await platform('native:aiSetKey', { ...request, provider: 'gemini' }); managers.gemini.invalidateCredentials(); return result })
  handle('agent:installCommand', () => ({ command: 'iPad에서는 CLI를 설치할 수 없습니다. API 키로 연결하세요.', supported: false }))
  for (const channel of ['agent:install', 'agent:login', 'agent:reopenLogin', 'agent:submitLoginCode']) handle(channel, () => ({ ok: false, message: '이 기능은 데스크톱 CLI용입니다. iPad에서는 같은 제공자의 API 키를 등록하세요.' }))
  handle('agent:cancelLogin', () => ({ ok: false }))
  handle('agent:skills', () => [])
  handle('chat:open', async request => {
    const result = await (await manager(request)).open(request.courseId, request.sessionId, request.surface)
    surfaces.set(request.sessionId, result.sessionInfo.surface)
    return result
  })
  handle('chat:send', async request => { if (request.context?.skillIds?.length || request.context?.creation) throw new Error('선택한 실행형 제작 스킬은 iPad API 런타임에서 아직 연결되지 않았습니다.'); return (await manager(request)).send(request.courseId, request.sessionId, request.content, request.attachments, request.context) })
  handle('chat:cancel', async request => { (await manager(request)).cancel(request.courseId, request.sessionId); return { ok: true } })
  handle('chat:close', async request => { (await manager(request)).close(request.courseId, request.sessionId); warm.delete(request.sessionId); surfaces.delete(request.sessionId); return { ok: true } })
  handle('chat:deleteConversation', async request => { (await manager(request)).close(request.courseId, request.sessionId); chat.softDeleteSession(request.sessionId); warm.delete(request.sessionId); surfaces.delete(request.sessionId); return { ok: true } })
  handle('chat:respondPermission', async request => { (await manager(request)).respondPermission(request.courseId, request.sessionId, request.requestId, request.response); return { ok: true } })
  handle('chat:accessPolicy', async request => { await manager(request); if (request.policy) { if (!chat.getSession(request.sessionId)) chat.createSession(request.sessionId, request.courseId, warm.get(request.sessionId), surfaces.get(request.sessionId)); chat.setAccessPolicy(request.sessionId, parseAiAccess(request.policy)) }; return chat.getSession(request.sessionId)?.accessPolicy ?? parseAiAccess(null) })
  handle('chat:setConfiguration', async request => { (await manager(request)).setModel(request.courseId, request.sessionId, request.model, request.effort); const result = { model: request.model, effort: request.effort ?? null }; emit('chat:configurationChanged', { sessionId: request.sessionId, ...result }); return result })
  handle('chat:setModel', async request => { (await manager(request)).setModel(request.courseId, request.sessionId, request.model); return { ok: true } })
  handle('chat:setProvider', async request => {
    if (!isAgentProvider(request.provider)) throw new Error('AI 제공자를 확인해 주세요.')
    const previous = await manager(request), info = chat.getSession(request.sessionId), old = warm.get(request.sessionId)!
    if (info?.status === 'running') throw new Error('응답이 끝난 뒤 제공자를 바꿔 주세요.')
    if (old === request.provider) return { sessionInfo: info, carried: null }
    const transcript = serializeTranscript(chat.historyTail(request.sessionId, CARRYOVER_HISTORY_LIMIT))
    previous.close(request.courseId, request.sessionId)
    const sessionInfo = info ? chat.switchProvider(request.sessionId, request.provider) : chat.createSession(request.sessionId, request.courseId, request.provider, request.surface ?? surfaces.get(request.sessionId))
    const carried = { messages: transcript.messages, chars: transcript.text.length, truncated: transcript.truncated }
    if (info) chat.appendNotice(request.courseId, request.sessionId, { kind: 'provider-switch', from: old, to: request.provider, carried })
    warm.set(request.sessionId, request.provider); return { sessionInfo, carried }
  })
  handle('agentTools:confirmations', request => confirmer.list(request.conversationId))
  handle('agentTools:respondConfirm', request => ({ ok: true, state: confirmer.resolve(request) }))
  handle('agentTools:changes', request => journal.forTurn(request.turnId))
  handle('agentTools:undo', request => journal.undoTurn(request.turnId, {
    course: async ({ targetId }) => { courses.softDelete({ courseId: targetId }); emit('courses:changed', {}) },
    material: async ({ courseId, targetId }) => { await repos.materials.softDelete({ courseId, relPath: targetId }); emit('materials:changed', { courseId }) },
    note: async ({ courseId, targetId }) => { await repos.materials.softDelete({ courseId, relPath: targetId }); emit('materials:changed', { courseId }) },
    link: async ({ courseId, targetId }) => { repos.links.remove(courseId, targetId); emit('materials:changed', { courseId }) },
    task: async ({ courseId, targetId }) => { repos.board.softDelete({ id: targetId }); emit('board:changed', { courseId }) },
    board: async ({ targetId }) => { repos.canvas.removeBoard(targetId) },
    shape: async ({ targetId }) => { const [boardId, shapeId] = targetId.split('\0'); if (!boardId || !shapeId) throw new Error('Invalid shape undo target'); repos.canvas.removeShapes({ boardId, ids: [shapeId] }) },
    'material-edit': async ({ courseId, targetId }) => { const parsed = parseMaterialEditTargetId(targetId); if (!parsed) throw new Error('Invalid document undo target'); restoreMaterialBackup({ courseFolder: courses.getFolder(courseId), relPath: parsed.relPath, backupAbs: parsed.backupAbs }); repos.materials.invalidateTree(courseId); emit('materials:changed', { courseId }) }
  }))
  chat.markDanglingInterrupted()
  return { managers, confirmer, journal, workflow, validateLearningAi,
    connectLearning(runtime: ReturnType<typeof createLearningRuntime>) { learning = runtime },
    rejectModel(provider: AgentProvider, model: string) { const blocked = blockedModels.get(provider) ?? new Set<string>(); blocked.add(model); blockedModels.set(provider, blocked) },
    sendLearning(courseId: string, sessionId: string, provider: AgentProvider, prompt: string, ai: LearningAiSettings) { warm.set(sessionId, provider); return sendLearningWithSession(managers[provider], courseId, sessionId, prompt, ai, validateLearningAi) },
    assertSourceTab(courseId: string, tabId: string, url: string) {
      courses.getById(courseId)
      const tab = (workspace.browserTabs ?? []).find((tab: any) => tab.tabId === tabId && tab.courseId === courseId && tab.url === url)
      if (!tab) throw new Error('이 과목에 연결된 현재 브라우저 탭을 확인할 수 없습니다.')
    },
    dispose() { workflow.dispose(); browser.dispose(); Object.values(managers).forEach(manager => manager.disposeAll()); confirmer.disposeAll(); batches.dispose() } }
}
