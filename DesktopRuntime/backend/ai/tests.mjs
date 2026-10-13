import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { runWorkflowTests } from './workflow-tests.mjs'
let backend, plans = [], cancel = new Map(), calls = [], mcpCalls = 0
const browserPage = { url: 'https://example.com/page', generation: 1, facts: { tag: 'input', type: 'text', inNonGetForm: false, href: null, disabled: false } }; let browserActions = 0, browserRequests = 0, browserKeys = 0
export function setBackend(value) { backend = value }
export async function platformFixture(channel, request) {
  if (channel === 'native:mcpCancel') return { ok: true }
  if (channel === 'native:mcpProbe') { assert.equal(request.config.headers.Authorization, 'Bearer fixture-mcp-secret'); return { durationMs: 1, tools: [{ name: 'echo', description: 'Fixture echo', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] } }
  if (channel === 'native:mcpCall') { mcpCalls++; return { content: [{ type: 'text', text: request.arguments.text + ' Bearer fixture-mcp-secret' }] } }
  if (channel === 'native:browserTool') {
    browserRequests++
    const { tool, input } = request
    if (request.expectedUrl && (request.expectedUrl !== browserPage.url || request.expectedGeneration !== browserPage.generation)) return { status: 'error', message: 'stale page' }
    if (tool === 'registerTab' || tool === 'syncTabs') return { ok: true }
    if (tool === 'savedLogin') return { filled: true, submitted: false }
    if (tool === 'inspect') return { status: 'ok', ...browserPage }
    if (tool === 'tabs') return { status: 'ok', tabs: [{ tabId: 'fixture-tab', title: 'Fixture', url: browserPage.url, active: true, asleep: false }], activeTabId: 'fixture-tab' }
    if (tool === 'read') return { status: 'ok', url: browserPage.url, text: 'Real fixture page body' }
    if (tool === 'snapshot') return { status: 'ok', url: browserPage.url, outline: 'f0:e0@1 input', generation: browserPage.generation }
    if (tool === 'act') { browserActions++; return { status: 'ok', url: browserPage.url, title: 'Fixture', navigated: false } }
    if (tool === 'key') { browserKeys++; return { status: 'ok', semanticAction: 'click' } }
    if (tool === 'handoff') return { status: 'ok' }
    throw new Error('Unmocked browser primitive ' + tool)
  }
  if (channel === 'native:aiAvailability') return { installed: true, loggedIn: true, version: 'fixture native API', transport: 'api' }
  if (channel === 'native:aiModels') return { models: [{ id: 'fixture', displayName: 'Fixture', isDefault: false }], source: 'live', status: 'ready' }
  if (channel === 'native:aiRun') { calls.push(request); const plan = plans.shift(); if (!plan) throw new Error('Unexpected paid API request in fixture'); return plan(request) }
  if (channel === 'native:learningDictionary') return { status: 'not-found', query: request.text, entries: [] }
  if (channel === 'native:learningExtract') return { raw: { title: 'Fixture article', language: 'en', paragraphs: [('The climate is changing and the communities are learning to adapt. We can use science to understand the world and to make better choices for the future. ').repeat(4)] }, sourceUrl: request.url, access: 'public' }
  if (channel === 'native:aiCancel') { cancel.get(request.requestId)?.(); return { ok: true } }
  throw new Error('Unmocked private service ' + channel)
}
const wait = async predicate => { const until = Date.now() + 3000; while (!predicate()) { if (Date.now() > until) throw new Error('AI fixture timed out'); await new Promise(r => setTimeout(r, 2)) } }
const tool = (request, name, args) => backend.invokePrivate('nativeAI:tool', { requestId: request.requestId, call: { id: crypto.randomUUID(), name, arguments: JSON.stringify(args) } })
const event = (request, text) => backend.invokePrivate('nativeAI:event', { requestId: request.requestId, event: { type: 'text-delta', text } })
const complete = { text: '완료했습니다.', model: 'fixture-api-model', usage: { inputTokens: 7, outputTokens: 3 } }
export async function runAITests(invoke, pushes) {
  const course = await invoke('courses:create', { name: 'API fixture only', color: 'blue' }), sessionId = crypto.randomUUID()
  const request = { courseId: course.id, sessionId }
  const initial = await invoke('chat:open', request)
  assert.equal(initial.history.length, 0)
  assert.equal(backend.repositories.db.prepare('SELECT COUNT(*) n FROM agent_sessions WHERE id=?').get(sessionId).n, 0)
  await assert.rejects(invoke('nativeAI:tool', {}), /not connected|Unsupported/i)
  let note
  plans.push(async req => {
    const created = JSON.parse(await tool(req, 'create_note', { courseId: course.id, dirRelPath: '', title: 'AI 실물 필기', markdown: '보존할 원문' }))
    assert.equal(created.isError, undefined)
    note = JSON.parse(created.content[0].text)
    await event(req, '완료'); await event(req, '했습니다.')
    return complete
  })
  const first = await invoke('chat:send', { ...request, content: '실물 필기 작성' })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(sessionId)?.status === 'idle')
  const finished = await invoke('chat:open', request)
  assert.equal(finished.history.length, 2); assert.equal(finished.history[1].blocks.find(b => b.kind === 'text').payload.text, '완료했습니다.')
  assert.equal((await invoke('notes:read', note)).markdown, '보존할 원문')
  const usage = await invoke('usage:summary', { windowDays: 7 })
  assert.ok(JSON.stringify(usage).includes('fixture-api-model'))
  const turnId = `${sessionId}:${first.turnSeq}`
  assert.equal((await invoke('agentTools:changes', { turnId })).actions[0].tool, 'create_note')
  assert.ok(pushes.some(push => push.channel === 'chat:event-batch' && push.payload.events.some(event => event.type === 'tool-end')))

  // Current desktop defaults automatically handle course actions. An explicit
  // restricted choice must persist and restore the original approval rail.
  assert.equal((await invoke('chat:accessPolicy', request)).mode, 'full')
  await invoke('chat:accessPolicy', { ...request, policy: { mode: 'ask', scope: { course: false, browser: false, screen: false } } })
  assert.equal((await invoke('chat:accessPolicy', request)).mode, 'ask')

  plans.push(async req => {
    const result = JSON.parse(await tool(req, 'overwrite_note', { ...note, markdown: '승인 없이 변경되면 안 됨' }))
    assert.equal(JSON.parse(result.content[0].text).cancelled, true)
    return complete
  })
  await invoke('chat:send', { ...request, content: '덮어쓰기 요청 후 취소' })
  await wait(() => pushes.some(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === sessionId))
  await invoke('chat:cancel', request)
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(sessionId)?.status !== 'running')
  assert.equal((await invoke('notes:read', note)).markdown, '보존할 원문')

  let suspendedRequest
  plans.push(req => new Promise(resolve => { suspendedRequest = req; cancel.set(req.requestId, () => resolve(complete)) }))
  await invoke('chat:send', { ...request, content: '중단 스트림' })
  await wait(() => suspendedRequest !== undefined)
  await event(suspendedRequest, '부분 답변')
  await invoke('chat:cancel', request)
  await assert.rejects(tool(suspendedRequest, 'create_note', { courseId: course.id, dirRelPath: '', title: '늦은 도구' }), /취소|종료/)
  await event(suspendedRequest, '취소 후 표시되면 안 됨')
  const stopped = await invoke('chat:open', request)
  assert.ok(stopped.history.some(m => m.blocks.some(b => b.payload?.text === '부분 답변' && b.payload?.interrupted)))
  assert.ok(!JSON.stringify(stopped.history).includes('취소 후 표시되면 안 됨'))
  const switched = await invoke('chat:setProvider', { ...request, provider: 'codex' })
  assert.equal(switched.sessionInfo.provider, 'codex'); assert.ok(switched.carried.messages >= 2)
  await learningTests(invoke)
  await browserTests(invoke, pushes)
  await mcpTests(invoke, pushes)
  await runWorkflowTests({invoke,plans,tool,complete,wait,backend,pushes})
  const preferences = await invoke('settings:get', {})
  assert.equal(preferences.experimental.extensionRuntime, false)
  await assert.rejects(invoke('settings:set', { experimental: { extensionRuntime: true } }), /iPad/)
  await assert.rejects(invoke('settings:set', { browser: { extensions: [{ path: '/fake', enabled: true }] } }), /Chromium/)
  assert.equal((await invoke('settings:get', {})).experimental.extensionRuntime, false)
  console.log('AI fixture passed: original lazy sessions/history/tools/approval cancellation/partial interruption/provider carryover/usage/private callbacks')
}

async function learningTests(invoke) {
  const course = await invoke('courses:create', { name: 'Grounded learning fixture', color: 'blue' })
  const note = await invoke('notes:create', { courseId: course.id, dirRelPath: '', title: 'Grounding source', markdown: 'Water freezes at zero degrees Celsius.' })
  const original = await invoke('notes:read', note)
  await invoke('notes:write', { ...note, markdown: 'Water freezes at zero degrees Celsius.', expectedMtime: original.mtime })
  const ai = { provider: 'codex', model: 'fixture', effort: null }
  const project = await invoke('learning:create', { placement: 'standalone', name: '원문 복습', topic: '물', purpose: 'course-review', linkedCourseId: course.id, ai })
  const binding = project.binding
  const reference = { kind: 'material', pathScope: 'course', sourceCourseId: course.id, relPath: note.relPath, quote: 'Water freezes at zero degrees Celsius.' }
  const draft = { version: 1, artifacts: [{ kind: 'quiz', title: 'Water quiz', questions: [{ id: 'q1', type: 'choice', prompt: 'When does water freeze?', options: [{ id: 'a', text: 'Zero Celsius' }, { id: 'b', text: 'One hundred Celsius' }], answer: 'a', explanation: 'The original note gives the freezing point.', sourceRefs: [reference] }] }] }
  const get = () => invoke('learning:get', { binding })
  const untilRun = async (id, status) => { const until = Date.now() + 3000; while (true) { const state = await get(), run = state.runs.find(item => item.id === id); if (run && status.includes(run.status)) return { state, run }; if (Date.now() > until) throw new Error('Learning run timed out: ' + JSON.stringify(run)); await new Promise(resolve => setTimeout(resolve, 2)) } }
  plans.push(async request => {
    const forbidden = JSON.parse(await tool(request, 'create_note', { courseId: course.id, dirRelPath: '', title: 'Forbidden learning write' }))
    assert.equal(forbidden.isError, true)
    const read = JSON.parse(await tool(request, 'read_material', { courseId: course.id, relPath: note.relPath }))
    assert.equal(read.isError, undefined); assert.ok(read.content[0].text.includes(reference.quote))
    const submitted = JSON.parse(await tool(request, 'learning_submit_result', { draft }))
    assert.equal(submitted.isError, undefined, JSON.stringify(submitted))
    assert.equal((await get()).artifacts.length, 0, 'Result must await provider settlement')
    return complete
  })
  const started = await invoke('study:generate', { courseId: course.id, packId: 'quiz', binding, source: { kind: 'material', relPath: note.relPath, sourceCourseId: course.id } })
  const { state } = await untilRun(started.runId, ['complete', 'failed'])
  assert.equal(state.runs.find(run => run.id === started.runId).status, 'complete', JSON.stringify(state.runs))
  assert.equal(state.artifacts.length, 1)
  const artifact = await invoke('learning:getArtifact', { binding, id: state.artifacts[0].id })
  assert.equal(artifact.questions[0].sourceRefs[0].contentHash.length, 64)
  assert.equal((await invoke('learning:resolveSource', { binding, sourceRef: artifact.questions[0].sourceRefs[0] })).missing, false)
  const attemptId = crypto.randomUUID()
  const answered = await invoke('learning:saveQuizAnswer', { binding, artifactId: artifact.id, attemptId, questionId: 'q1', answer: 'a' })
  assert.equal(answered.quizAttempts[0].id, attemptId)
  const finished = await invoke('learning:finishQuiz', { binding, artifactId: artifact.id, attemptId })
  assert.equal(finished.quizAttempts[0].score, 1); assert.ok(finished.quizAttempts[0].resultRelPath)

  plans.push(async request => {
    const bad = structuredClone(draft); bad.artifacts[0].questions[0].sourceRefs[0].quote = 'This sentence was invented.'
    const submitted = JSON.parse(await tool(request, 'learning_submit_result', { draft: bad }))
    assert.equal(submitted.isError, true); return complete
  })
  const bad = await invoke('learning:run', { binding, kind: 'create-quiz', source: { kind: 'material', relPath: note.relPath, sourceCourseId: course.id } })
  const rejected = await untilRun(bad.runId, ['failed'])
  assert.equal(rejected.state.artifacts.length, 1, 'Ungrounded generated content must never publish')

  let pending
  plans.push(request => new Promise(resolve => { pending = request; cancel.set(request.requestId, () => resolve(complete)) }))
  const cancelled = await invoke('learning:run', { binding, kind: 'create-cards', source: { kind: 'material', relPath: note.relPath, sourceCourseId: course.id } })
  await wait(() => pending !== undefined)
  await invoke('learning:runCancel', { binding, runId: cancelled.runId })
  await assert.rejects(tool(pending, 'learning_submit_result', { draft }), /취소|종료/)
  assert.equal((await untilRun(cancelled.runId, ['cancelled'])).state.artifacts.length, 1)

  const reading = await invoke('learning:create', { placement: 'standalone', name: 'Reading fixture', topic: 'Climate', purpose: 'english-reading', topicIds: ['environment'], readingSetupConfirmed: true, level: 'intermediate', readingMinutes: 1, ai })
  const article = await invoke('learning:addArticle', { binding: reading.binding, url: 'https://example.com/article?utm_source=fixture' })
  const snapshot = await invoke('learning:getArticle', { binding: reading.binding, id: article.addedArticleId })
  assert.equal(snapshot.sourceUrl, 'https://example.com/article'); assert.equal(snapshot.contentHash.length, 64)
  const first = snapshot.paragraphs[0], sentence = first.sentences[0]
  assert.equal(first.text.slice(sentence.start, sentence.end), sentence.text)
  console.log('Learning fixture passed: original review space, grounded AI quiz, restricted tools, settlement publication, actual quiz result, invalid citation rejection, cancellation, offline article snapshot')
}

async function browserTests(invoke, pushes) {
  const course = await invoke('courses:create', { name: 'Browser tools fixture', color: 'blue' }), sessionId = crypto.randomUUID()
  const request = { courseId: course.id, sessionId }
  await invoke('chat:open', request)
  await invoke('browserAgent:registerTab', { tabId: 'fixture-tab', webContentsId: 1 })
  await invoke('browserAgent:syncTabs', { courseId: course.id, tabs: [{ tabId: 'fixture-tab', title: 'Fixture', url: browserPage.url, asleep: false }], activeTabId: 'fixture-tab' })
  await backend.invokePrivate('nativeAI:workspace', { selectedCourseId: course.id, tabs: [], documents: [] })
  let reachedHandoff = false
  plans.push(async req => {
    const state = JSON.parse(await tool(req, 'app_state', {}))
    assert.equal(JSON.parse(state.content[0].text).browserTabs[0].tabId, 'fixture-tab')
    const read = JSON.parse(await tool(req, 'browser_read', { tabId: 'fixture-tab' }))
    assert.equal(read.isError, undefined, JSON.stringify(read)); assert.ok(read.content[0].text.includes('Real fixture page body'))
    const snapshot = JSON.parse(await tool(req, 'browser_snapshot', { tabId: 'fixture-tab' }))
    assert.equal(snapshot.isError, undefined)
    const stale = JSON.parse(await tool(req, 'browser_type', { tabId: 'fixture-tab', ref: 'f0:e0@0', text: 'stale target' }))
    assert.equal(stale.isError, true); assert.equal(browserActions, 0)
    browserPage.facts.type = 'password'
    const password = JSON.parse(await tool(req, 'browser_type', { tabId: 'fixture-tab', ref: 'f0:e0@1', text: 'never fill' }))
    assert.equal(password.isError, true); assert.equal(browserActions, 0)
    browserPage.facts.type = 'text'
    const typed = JSON.parse(await tool(req, 'browser_type', { tabId: 'fixture-tab', ref: 'f0:e0@1', text: 'approved text' }))
    assert.equal(typed.isError, undefined, JSON.stringify(typed)); assert.equal(browserActions, 1)
    browserPage.facts.href = 'file:///private/fixture'
    const unsafeEnter = JSON.parse(await tool(req, 'browser_key', { tabId: 'fixture-tab', key: 'Enter' }))
    assert.equal(unsafeEnter.isError, true); assert.equal(browserKeys, 0, 'Enter anchor navigation must pass the same original URL gate as a click')
    browserPage.facts.href = null
    const login = JSON.parse(await tool(req, 'browser_use_saved_login', { tabId: 'fixture-tab' }))
    assert.equal(login.isError, undefined); assert.equal(JSON.parse(login.content[0].text).submitted, false)
    reachedHandoff = true
    const handed = JSON.parse(await tool(req, 'browser_handoff', { tabId: 'fixture-tab', message: '직접 확인한 뒤 계속하세요' }))
    assert.equal(handed.isError, undefined); assert.ok(handed.content[0].text.includes('resumed'))
    return complete
  })
  await invoke('chat:send', { ...request, content: 'Read the fixture page after explicit site approval' })
  await wait(() => pushes.some(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === sessionId))
  const approval = pushes.find(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === sessionId).payload
  assert.equal(approval.tool, 'browser_access')
  await invoke('agentTools:respondConfirm', { requestId: approval.requestId, approved: true, scope: 'site' })
  await wait(() => pushes.some(push => push.channel === 'agentTools:confirm' && push.payload.tool === 'browser_use_saved_login'))
  const loginApproval = pushes.findLast(push => push.channel === 'agentTools:confirm' && push.payload.tool === 'browser_use_saved_login').payload
  assert.deepEqual(Array.from(loginApproval.scopes), ['once'])
  await invoke('agentTools:respondConfirm', { requestId: loginApproval.requestId, approved: true, scope: 'once' })
  await wait(() => reachedHandoff && pushes.some(push => push.channel === 'browserAgent:run-state' && push.payload.courseId === course.id && push.payload.status === 'waiting'))
  const run = pushes.findLast(push => push.channel === 'browserAgent:run-state' && push.payload.courseId === course.id && push.payload.status === 'waiting').payload
  await invoke('browserAgent:resumeRun', { runId: run.runId })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(sessionId)?.status === 'idle')
  const grant = (await invoke('browserAgent:grants', {})).grants.find(grant => grant.courseId === course.id)
  assert.equal(grant.origin, 'https://example.com')
  assert.ok((await invoke('browserAgent:auditTail', { courseId: course.id })).entries.some(entry => entry.action === 'read'))
  await invoke('browserAgent:revokeGrant', { id: grant.id })
  assert.ok((await invoke('browserAgent:grants', {})).grants.find(g => g.id === grant.id).revokedAt)
  await invoke('settings:set', { browser: { agentUse: false } })
  const before = browserRequests
  plans.push(async req => { const denied = JSON.parse(await tool(req, 'browser_tabs', {})); assert.equal(denied.isError, true); return complete })
  await invoke('chat:send', { ...request, content: 'Browser disabled fixture' })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(sessionId)?.status === 'idle')
  assert.equal(browserRequests, before)
  await invoke('settings:set', { browser: { agentUse: true } })
  console.log('Browser tools fixture passed: real site approval/grant audit/revocation, stale/password refusal, native typed action, original visible handoff/resume, master setting denial')
}

async function mcpTests(invoke, pushes) {
  const input = { name: 'fixture', description: 'Fixture only', transport: 'http', url: 'https://mcp.example.test/rpc', enabled: false, headers: { Authorization: 'Bearer fixture-mcp-secret' } }
  await assert.rejects(invoke('mcp:save', { ...input, transport: 'stdio', command: 'npx' }), /stdio/)
  await assert.rejects(invoke('mcp:save', { ...input, url: 'http://localhost:1234' }), /HTTPS/)
  const { server } = await invoke('mcp:save', input)
  assert.equal(server.headers, undefined); assert.deepEqual(server.headerKeys, ['Authorization'])
  const summaryInput = { id: server.id, name: server.name, description: server.description, transport: server.transport, url: server.url, enabled: true }
  await assert.rejects(invoke('mcp:save', summaryInput), /검사/)
  assert.equal((await invoke('mcp:test', { id: server.id })).ok, true)
  await invoke('mcp:save', summaryInput)
  const course = await invoke('courses:create', { name: 'MCP approval fixture', color: 'green' }), request = { courseId: course.id, sessionId: crypto.randomUUID(), surface: 'desktop' }
  const study = { courseId: course.id, sessionId: crypto.randomUUID(), surface: 'app' }
  await invoke('chat:open', study)
  plans.push(async req => { assert.ok(!req.tools.some(tool => tool.name.startsWith('mcp_fixture_')), 'Original MCP settings apply only to screen assistant conversations'); return complete })
  await invoke('chat:send', { ...study, content: 'No remote server tools in a normal study conversation' })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(study.sessionId)?.status === 'idle')
  await invoke('chat:open', request)
  let result
  await invoke('chat:accessPolicy', { ...request, policy: { mode: 'ask', scope: { course: true, browser: false, screen: false } } })
  assert.equal(backend.repositories.db.prepare('SELECT surface FROM agent_sessions WHERE id=?').get(request.sessionId).surface, 'desktop', 'Changing a provisional assistant policy must preserve its surface')
  plans.push(async req => {
    const definition = req.tools.find(tool => tool.name.startsWith('mcp_fixture_echo_')); assert.ok(definition)
    result = JSON.parse(await tool(req, definition.name, { text: 'approved fixture input' }))
    return complete
  })
  await invoke('chat:send', { ...request, content: 'Run fixture tool' })
  await wait(() => pushes.some(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === request.sessionId))
  const approval = pushes.findLast(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === request.sessionId).payload
  assert.deepEqual(Array.from(approval.scopes), ['once']); assert.equal(mcpCalls, 0)
  await invoke('agentTools:respondConfirm', { requestId: approval.requestId, approved: true, scope: 'once' })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(request.sessionId)?.status === 'idle')
  assert.equal(mcpCalls, 1); assert.ok(JSON.stringify(result).includes('approved fixture input')); assert.ok(!JSON.stringify(result).includes('fixture-mcp-secret'))
  plans.push(async req => { const definition = req.tools.find(tool => tool.name.startsWith('mcp_fixture_echo_')); result = JSON.parse(await tool(req, definition.name, { text: 'must not run' })); return complete })
  await invoke('chat:send', { ...request, content: 'Disable while approval pending' })
  await wait(() => pushes.some(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === request.sessionId && push.payload.requestId !== approval.requestId))
  const pending = pushes.findLast(push => push.channel === 'agentTools:confirm' && push.payload.conversationId === request.sessionId).payload
  await invoke('mcp:save', { ...summaryInput, enabled: false })
  await invoke('agentTools:respondConfirm', { requestId: pending.requestId, approved: true, scope: 'once' })
  await wait(() => backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(request.sessionId)?.status === 'idle')
  assert.equal(mcpCalls, 1); assert.equal(result.isError, true)
  await invoke('mcp:delete', { id: server.id }); assert.equal((await invoke('mcp:list', {})).servers.length, 0)
  console.log('MCP fixture passed: original encrypted registry, stdio/HTTP rejection, secret summaries, test-before-enable, actual approved tool execution/redaction, disable-during-approval guard')
}
