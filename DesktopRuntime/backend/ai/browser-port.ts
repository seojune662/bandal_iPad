import { createLMSBrowserTools } from './browser-lms'
import { createGrantsRepo, normalizeOrigin, ANY_ORIGIN, type BrowserCapability } from '../../upstream/src/main/features/browserAgent/grants'
import { createAuditRepo } from '../../upstream/src/main/features/browserAgent/audit'
import { checkNavigation } from '../../upstream/src/main/features/browserAgent/navigation'
import { canClick, canType, canSelect } from '../../upstream/src/main/features/browserAgent/actionPolicy'
import { resolveRef } from '../../upstream/src/main/features/browserAgent/refs'
import { createRunRegistry, createConversationRunScope, RunStopped } from '../../upstream/src/main/features/browserAgent/run'
import { redactText, redactUrl } from '../../upstream/src/main/features/browserAgent/redact'
import { getSettings } from '../../upstream/src/main/settingsStore'
import { emit } from '../native'
import { platform } from './adapter'

/** Native async page boundary, with original desktop grants, navigation/element
 * policies, stale references, audit records and visible run controls. */
export function createBrowserBridge(deps: { db: any; courses: any; courseLinks: any; confirmer: any; handle: (channel: string, fn: (request: any) => any) => void; onTabs?: (courseId: string, tabs: any[]) => void }) {
  const grants = createGrantsRepo(deps.db), audit = createAuditRepo(deps.db)
  const runs = createRunRegistry({ emit: state => emit('browserAgent:run-state', state) })
  const scopes = new Map<string, ReturnType<typeof createConversationRunScope>>()
  const resumes = new Map<string, (value: 'resumed' | 'stopped') => void>()
  audit.prune()
  function finish(sessionId: string) { const scope = scopes.get(sessionId), run = scope?.current(); if (run) { resumes.get(run.runId)?.('stopped'); resumes.delete(run.runId) }; scope?.finish() }
  // Registry maintenance is UI state, so disabling agent access must not block it.
  deps.handle('browserAgent:registerTab', request => platform('native:browserTool', { tool: 'registerTab', input: request }))
  deps.handle('browserAgent:syncTabs', async request => {
    deps.courses.getById(request.courseId)
    const result = await platform('native:browserTool', { tool: 'syncTabs', courseId: request.courseId, input: request })
    deps.onTabs?.(request.courseId, request.tabs.map((tab: any) => ({ ...tab, courseId: request.courseId, active: tab.tabId === request.activeTabId })))
    return result
  })
  deps.handle('browserAgent:grants', () => ({ grants: grants.list() }))
  deps.handle('browserAgent:revokeGrant', request => { grants.revoke(request.id); return { ok: true } })
  deps.handle('browserAgent:auditTail', request => ({ entries: audit.tail(request.courseId, Math.min(1000, Math.max(1, request.limit ?? 200))) }))
  deps.handle('browserAgent:stopRun', request => { runs.stop(request.runId); resumes.get(request.runId)?.('stopped'); resumes.delete(request.runId); return { ok: true } })
  deps.handle('browserAgent:resumeRun', request => { runs.resume(request.runId); resumes.get(request.runId)?.('resumed'); resumes.delete(request.runId); return { ok: true } })
  function toolsFor(courseId: string, conversationId: string, getTurnId: () => string) {
    finish(conversationId)
    const scope = createConversationRunScope({ registry: runs, courseId, getTurnId }); scopes.set(conversationId, scope)
    const enabled = () => { if (!getSettings().browser.agentUse) throw new Error('브라우저 에이전트 사용이 설정에서 꺼져 있어요.'); deps.courses.getById(courseId) }
    function log(action: any, url: string, detail: string) { audit.record({ courseId, runId: getTurnId(), action, url: redactUrl(url), detail: redactText(detail) }) }
    async function native(tool: string, input: any = {}, expected?: any) {
      enabled(); scope.assertLive(input.tabId)
      const turn = getTurnId()
      const result = await platform('native:browserTool', { tool, courseId, input, ...(input.expectedFacts ? { expectedFacts: input.expectedFacts } : {}), ...(expected ? { expectedUrl: expected.url, expectedGeneration: expected.generation } : {}) })
      if (getTurnId() !== turn) throw new RunStopped()
      enabled(); scope.assertLive(input.tabId)
      if (!result || result.status === 'error') throw new Error(result?.message ?? '브라우저 작업을 완료하지 못했어요.')
      return result
    }
    async function gate(url: string, capability: BrowserCapability) {
      enabled(); const turn = getTurnId()
      const grant = grants.find({ courseId, url, capability })
      const verdict = checkNavigation({ url, capability, heldCapability: grant?.capability ?? null })
      if (verdict.allowed) { if (grant) grants.touch(grant.id); return }
      if (verdict.reason !== 'no-grant') { log('denied', url, verdict.message); throw new Error(verdict.message) }
      const origin = normalizeOrigin(url); if (!origin) throw new Error('올바른 웹 주소를 확인해 주세요.')
      const answer = await deps.confirmer.confirm({ courseId, conversationId, turnId: turn, tool: 'browser_access', summary: `${origin} 을 읽고 다룰까요?`, details: ['보기와 누르기, 파일 받기까지 할 수 있어요.', '글을 쓰거나 제출하는 건 그때마다 따로 물어봐요.'], scopes: ['once', 'site', 'course'] })
      if (getTurnId() !== turn) throw new RunStopped()
      enabled(); scope.assertLive()
      if (answer === false) { log('denied', url, '학생이 접근을 허용하지 않았어요.'); throw new Error('학생이 접근을 허용하지 않았어요.') }
      if (answer === 'site' || answer === 'course') grants.grant({ courseId, url: answer === 'course' ? ANY_ORIGIN : origin, capability })
      log('grant', url, answer === 'once' ? '이번 한 번만' : '학생이 선택한 사이트/과목 범위 · 30일')
    }
    async function inspect(tabId: string, ref?: string, focused = false) {
      const before = await native('inspect', { tabId, ...(ref ? { ref } : {}), ...(focused ? { focused: true } : {}) })
      if (typeof before.url !== 'string' || !Number.isInteger(before.generation)) throw new Error('브라우저 페이지 상태를 확인하지 못했어요.')
      return before
    }
    async function checked(tool: string, input: any, capability: BrowserCapability = 'interact') {
      const before = await inspect(input.tabId)
      await gate(before.url, capability)
      const result = await native(tool, input, before)
      log(tool === 'read' || tool === 'find' ? 'read' : tool === 'snapshot' ? 'snapshot' : 'navigate', before.url, tool)
      scope.step(tool === 'read' ? '페이지를 읽는 중' : '페이지를 살펴보는 중', result.url ?? before.url)
      return result
    }
    return {
      async browser_tabs() { const result = await native('tabs'); log('snapshot', '', `탭 ${result.tabs?.length ?? 0}개`); return { ...result, tabs: (result.tabs ?? []).map((tab: any) => ({ ...tab, title: redactText(tab.title ?? ''), url: redactUrl(tab.url ?? '') })) } },
      async browser_open(url: string) { await gate(url, 'read'); const result = await native('open', { url }); scope.assertLive(result.tabId); scope.step('페이지를 여는 중', result.url); log('navigate', result.url, '탭에서 열었어요'); return result },
      browser_snapshot: (tabId: string, maxChars: number | null) => checked('snapshot', { tabId, maxChars: Math.min(60_000, Math.max(1, maxChars ?? 12_000)) }, 'read'),
      browser_read: (tabId: string, maxChars: number | null) => checked('read', { tabId, maxChars: Math.min(60_000, Math.max(1, maxChars ?? 8_000)) }, 'read'),
      browser_scroll: (tabId: string, to: any) => checked('scroll', { tabId, to }),
      async browser_act(tabId: string, ref: string, action: any) {
        const before = await inspect(tabId, ref), resolution = resolveRef(ref, before.generation)
        if (!resolution.ok) throw new Error(resolution.message)
        if (!before.facts) throw new Error('그 요소를 찾지 못했어요.')
        const policy = action.kind === 'click' ? canClick(before.facts) : action.kind === 'type' ? canType(before.facts) : canSelect(before.facts)
        if (!policy.allowed) { log('denied', before.url, policy.message); throw new Error(policy.message) }
        await gate(before.url, 'interact')
        if (action.kind === 'click' && before.facts.href) await gate(new URL(before.facts.href, before.url).href, 'read')
        const result = await native('act', { tabId, ref, action, expectedFacts: before.facts }, before)
        log('navigate', before.url, action.kind); return result
      },
      async browser_key(tabId: string, key: string) {
        if (!['Enter', 'Tab', 'Escape', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(key)) throw new Error('지원하지 않는 키입니다.')
        const before = await inspect(tabId, undefined, true); await gate(before.url, 'interact')
        if (key === 'Enter' && before.facts?.href) await gate(new URL(before.facts.href, before.url).href, 'read')
        if (key === 'Enter' && before.facts?.formAction) await gate(new URL(before.facts.formAction, before.url).href, 'interact')
        if (key === 'Enter' && await deps.confirmer.confirm({ courseId, conversationId, turnId: getTurnId(), tool: 'browser_key', summary: 'Enter 키를 누를까요?', details: ['현재 페이지의 양식이 제출될 수 있어요.'], scopes: ['once'] }) === false) throw new Error('학생이 중지했어요.')
        return native('key', { tabId, key, focusToken: before.focusToken, expectedFacts: before.facts, approved: key === 'Enter' }, before)
      },
      browser_hover: (tabId: string, ref: string) => checked('hover', { tabId, ref }),
      browser_back: (tabId: string) => checked('back', { tabId }), browser_forward: (tabId: string) => checked('forward', { tabId }),
      browser_reload: (tabId: string) => checked('reload', { tabId }), browser_stop: (tabId: string) => checked('stop', { tabId }),
      browser_focus_tab: (tabId: string) => checked('focus', { tabId }), browser_close_tab: (tabId: string) => checked('close', { tabId }),
      browser_find: (tabId: string, text: string) => checked('find', { tabId, text }, 'read'),
      async browser_handoff(tabId: string, message: string) {
        await native('handoff', { tabId, message }); scope.wait(message)
        const run = scope.current(); if (!run) throw new RunStopped()
        const outcome = await new Promise<'resumed' | 'stopped'>(resolve => { const timer = setTimeout(() => { resumes.delete(run.runId); runs.stop(run.runId); resolve('stopped') }, 5 * 60 * 1000); resumes.set(run.runId, value => { clearTimeout(timer); resolve(value) }) })
        if (outcome === 'stopped') throw new RunStopped(); return { status: 'resumed' }
      },
      async browser_download(requestedCourse: string, url: string, dirRelPath: string) { if (requestedCourse !== courseId) throw new Error('이 대화에 연결된 과목에만 내려받을 수 있어요.'); await gate(url, 'download'); const result = await native('download', { url, dirRelPath }); log('download', url, `자료 ${result.relPath ?? ''}`); return result },
      async browser_submit(tabId: string, ref: string) {
        const before = await inspect(tabId, ref); const resolved = resolveRef(ref, before.generation); if (!resolved.ok) throw new Error(resolved.message)
        await gate(before.url, 'interact')
        if (await deps.confirmer.confirm({ courseId, conversationId, turnId: getTurnId(), tool: 'browser_submit', summary: '웹 페이지의 내용을 제출할까요?', details: [redactUrl(before.url), '제출은 되돌리기 어려울 수 있어요. 현재 양식 내용을 직접 확인하세요.'], scopes: ['once'] }) === false) throw new Error('학생이 제출을 취소했어요.')
        if (before.facts?.formAction) await gate(new URL(before.facts.formAction, before.url).href, 'interact')
        return native('submit', { tabId, ref, expectedFacts: before.facts, approved: true }, before)
      },
      async browser_use_saved_login(tabId: string) {
        const before = await inspect(tabId); await gate(before.url, 'interact')
        if (await deps.confirmer.confirm({ courseId, conversationId, turnId: getTurnId(), tool: 'browser_use_saved_login', summary: '저장된 로그인 정보를 채울까요?', details: [redactUrl(before.url), '로그인 버튼은 직접 눌러 주세요. 비밀번호는 AI에 전달하지 않아요.'], scopes: ['once'] }) === false) throw new Error('학생이 로그인 채우기를 취소했어요.')
        const result = await native('savedLogin', { tabId }, before)
        log('navigate', before.url, '학생이 승인한 저장 로그인 채우기'); return result
      },
      async browser_attach_file(tabId: string, ref: string, requestedCourse: string, relPath: string) {
        if (requestedCourse !== courseId) throw new Error('이 대화 과목의 파일만 첨부할 수 있어요.')
        const before = await inspect(tabId, ref), resolved = resolveRef(ref, before.generation)
        if (!resolved.ok) throw new Error(resolved.message)
        if (before.facts?.tag !== 'input' || before.facts?.type !== 'file') throw new Error('현재 파일 선택 칸을 다시 확인해 주세요.')
        await gate(before.url, 'interact')
        if (await deps.confirmer.confirm({ courseId, conversationId, turnId: getTurnId(), tool: 'browser_attach_file', summary: '과목 파일을 이 사이트에 첨부할까요?', details: [redactUrl(before.url), relPath, '파일은 사이트에 공개됩니다. 양식 제출은 별도로 확인합니다.'], scopes: ['once'] }) === false) throw new Error('학생이 파일 첨부를 취소했어요.')
        const result = await native('attachFile', { tabId, ref, courseId, relPath, expectedFacts: before.facts, approved: true }, before)
        log('navigate', before.url, `학생이 승인한 파일 첨부: ${relPath}`); return result
      },
      ...createLMSBrowserTools({ db: deps.db, courseId, courseLinks: deps.courseLinks, enabled, gate, native, log })
    }
  }
  return { toolsFor, finish, dispose() { for (const id of scopes.keys()) finish(id); scopes.clear(); runs.disposeAll() } }
}
