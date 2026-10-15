import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import { DEFAULT_SETTINGS } from '../../../upstream/src/shared/types/settings'
import { DEFAULT_AI_ACCESS } from '../../../upstream/src/shared/types/aiAccess'
import { SETTINGS_CATEGORIES } from '../../../upstream/src/shared/settingsCategories'
import { SettingsApp } from '../../../upstream/src/renderer/src/features/settings/SettingsApp'
import { ChatSurface } from '../../../upstream/src/renderer/src/features/chat/ChatSurface'
import { useChatSessionStore } from '../../../upstream/src/renderer/src/features/chat/chatSessionStore'
import { initialChatViewState } from '../../../upstream/src/renderer/src/features/chat/chatModel'
import { updateComposerDraft } from '../../../upstream/src/renderer/src/features/chat/composerDraftStore'
import { useAgentConnectionStore } from '../../../upstream/src/renderer/src/features/chat/agentConnectionStore'
import '../../../upstream/src/renderer/src/styles/tokens.css'
import '../../../upstream/src/renderer/src/styles/base.css'
import '../../../upstream/src/renderer/src/app/app-shell.css'
import '../layout/layout.css'

const listeners = new Map<string, Set<(event: unknown) => void>>()
const saved = { value: structuredClone(DEFAULT_SETTINGS), fail: false }
const calls: Array<{ channel: string; request: Record<string, unknown> }> = []
const emit = (channel: string, event: unknown) => listeners.get(channel)?.forEach(listener => listener(event))
const on = (channel: string, listener: (event: unknown) => void) => {
  const set = listeners.get(channel) ?? new Set(); set.add(listener); listeners.set(channel, set)
  return () => { set.delete(listener) }
}
const invoke = async (channel: string, request: Record<string, unknown>) => {
  calls.push({ channel, request })
  if (channel === 'settings:get') return saved.value
  if (channel === 'settings:set') {
    if (saved.fail) throw new Error('Fixture storage unavailable')
    saved.value = { ...saved.value, ...request }
    emit('settings:changed', { settings: saved.value }); return saved.value
  }
  if (channel === 'agent:availability') return { installed: true, loggedIn: true, version: 'API', code: 'ready' }
  if (channel === 'agent:apiKey' || channel === 'agent:geminiApiKey') return { configured: true }
  if (channel === 'agent:models') return { models: [{ id: 'fixture-model', displayName: '길이가 긴 AI 모델 이름 · 상세 추론 모델', isDefault: true }], source: 'fallback', status: 'ready' }
  if (channel === 'chat:open') return { history: [], eventSeq: 0, sessionInfo: null, availability: { installed: true, loggedIn: true } }
  if (channel === 'chat:context') return { id: 'context', courseId: 'course', courseName: '자료구조', material: { title: '아주 긴 이름을 가진 10주차 강의자료.pdf', relPath: 'lectures/10.pdf', page: 12, selection: '이진 검색 트리의 탐색 과정' }, capturedAt: '', refresh: 'fresh' }
  if (channel === 'chat:accessPolicy') return DEFAULT_AI_ACCESS
  if (channel === 'chat:conversations') return { conversations: [] }
  if (channel === 'chat:send' || channel === 'chat:cancel' || channel === 'chat:respondPermission') return { ok: true }
  if (channel === 'plugins:list') return { plugins: [] }
  if (channel === 'plugins:catalog') return { entries: [], sources: [] }
  if (channel === 'mcp:list') return { servers: [], availability: { available: false, reason: 'HTTPS remote connections only' } }
  if (channel === 'packs:list') return { packs: [] }
  if (['courses:list', 'materials:tree', 'favorites:list', 'agentTools:confirmations', 'browser:importSources', 'credentials:list', 'agent:skills'].includes(channel)) return []
  if (channel === 'auth:getState') return { phase: 'signed-out' }
  if (channel === 'credentials:availability') return { available: true }
  if (channel === 'browser:profiles') return [{ id: 'default', name: '기본 프로필', icon: '' }]
  if (channel === 'browser:extensions') return { extensions: [] }
  if (channel === 'browser:sessionSites') return { sites: [] }
  if (channel === 'browser:sitePermissions') return { permissions: [] }
  if (channel === 'browserAgent:grants' || channel === 'chat:grants') return { grants: [] }
  if (channel === 'browserAgent:auditTail') return { entries: [] }
  if (channel === 'appleCalendar:state') return { supported: true, connected: false, authorization: 'denied', calendars: [], selectedCalendarIds: [], destinationCalendarId: null }
  if (channel === 'permissions:status') return { platform: 'ios', permissions: [{ id: 'microphone', state: 'denied', canRequest: false, canOpenSettings: true }, { id: 'calendar', state: 'not-determined', canRequest: true, canOpenSettings: true }], checkedAt: '' }
  if (channel === 'usage:summary') return { windowDays: 7, since: null, totals: { turns: 0, sessions: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, agentMs: 0 }, byProvider: [] }
  if (channel === 'update:status') return { phase: 'unsupported', currentVersion: 'fixture' }
  if (channel === 'pdfNative:capabilities') return { development: false, enabled: false }
  if (channel === 'runtime:recordingDevices') return [{ deviceId: 'built-in', label: 'iPad 마이크', kind: 'audioinput', groupId: 'native' }]
  if (channel === 'recordings:models') return []
  if (channel === 'runtime:nativeSurfaceSession') return { sessionId: 'settings-chat' }
  if (channel === 'runtime:nativeSurfaces') return { revision: request.revision }
  throw new Error(`Unknown fixture request: ${channel}`)
}
Object.assign(window, { bandal: { platform: 'ipad', invoke, on, pathForFile: () => '' } })
setIpcAdapter({ invoke, on } as IpcAdapter)
const bootstrap = (window as unknown as { __settingsUiBootstrap: {
  requests: Array<{ channel: string; request: Record<string, unknown>; resolve: (value: unknown) => void; reject: (error: unknown) => void }>
  subscriptions: Array<{ channel: string; listener: (event: unknown) => void; active: boolean }>
} }).__settingsUiBootstrap
for (const entry of bootstrap.subscriptions) if (entry.active) on(entry.channel, entry.listener)
for (const entry of bootstrap.requests) void invoke(entry.channel, entry.request).then(entry.resolve, entry.reject)
const trace = { saved, calls, categories: SETTINGS_CATEGORIES.map(category => category.id), show: (_mode: string, _category = 'general') => {}, sessions: useChatSessionStore, initialChatViewState, updateComposerDraft, connections: useAgentConnectionStore }
Object.assign(window, { ipadSettingsChatFixture: trace })
const before = new URLSearchParams(location.search).has('before')
if (!before) await import('./styles.css')
function Fixture(): JSX.Element {
  const [mode, setMode] = useState('settings'), [category, setCategory] = useState('general')
  trace.show = (next, nextCategory = 'general') => { setMode(next); setCategory(nextCategory) }
  return <div className="app-shell ipad-shell" data-ipad-side="none" style={{ height: '100%', width: '100%' }}>
    {mode === 'settings' ? <SettingsApp initialCategory={category} onClose={() => setMode('tab')} /> : <ChatSurface courseId="course" conversationId="ui-conversation" variant={mode === 'sidebar' ? 'sidebar' : 'tab'} />}
  </div>
}
const style = document.createElement('style')
style.textContent = 'html,body,#root{width:100%;height:100%;margin:0}*{box-sizing:border-box}button,input,select,textarea{font-family:inherit}'
// The baseline keeps all original CSS, omitting the new style layer and summary.
if (before) style.textContent += '.ipad-chat-context-summary{display:none}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
