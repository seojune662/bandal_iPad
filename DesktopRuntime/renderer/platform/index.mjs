import { fileURLToPath } from 'node:url'
const apiPath = fileURLToPath(new URL('./api.ts', import.meta.url))
const pdfResourcesPath = fileURLToPath(new URL('./pdfResources.ts', import.meta.url))
const keyboardFiles = new Map([
  ['features/settings/SettingsApp.tsx', 1], ['features/workspace/WorkspaceTab.tsx', 1],
  ['features/chat/MarkdownView.tsx', 1], ['features/materials/MaterialTree.tsx', 2],
  ['features/courses/FavoritesSection.tsx', 1], ['features/notes/NoteTab.tsx', 1],
  ['features/settings/browser/BrowserSettingsPanel.tsx', 1]
])
function replace(source, needle, value, count = 1) {
  if (source.split(needle).length - 1 !== count) throw new Error(`Desktop platform adapter anchor changed: ${needle}`)
  return source.split(needle).join(value)
}
export function adaptPlatformSource(source, id) {
  let code = source
  if (id.endsWith('/renderer/src/features/pdf/PdfTab.tsx')) {
    code = `import { pdfResourceOptions } from ${JSON.stringify(pdfResourcesPath)}\n` + code
    code = replace(code, 'const PDF_DOCUMENT_OPTIONS = {', 'const PDF_DOCUMENT_OPTIONS = {\n  ...pdfResourceOptions,')
  }
  if (['/renderer/src/features/pdf/renderClip.ts', '/renderer/src/features/materials/preview/mediaThumbnails.ts', '/renderer/src/features/studyMarket/renderPreview.ts'].some(suffix => id.endsWith(suffix))) {
    code = `import { pdfResourceOptions } from ${JSON.stringify(pdfResourcesPath)}\n` + code
    code = replace(code, 'pdfjs.getDocument({', 'pdfjs.getDocument({ ...pdfResourceOptions,')
    if (id.endsWith('/features/pdf/renderClip.ts')) {
      code = replace(code, "import './pdfWorker'", "import { configurePdfWorker } from './pdfWorker'\nconfigurePdfWorker()")
    }
  }
  if (id.endsWith('/renderer/src/app/AppShell.tsx')) {
    code = replace(code, "descriptorFor('file', {\n        courseId: pendingMaterial.courseId,\n        relPath: pendingMaterial.relPath\n      })", "nativeMaterialDescriptor(pendingMaterial.courseId, pendingMaterial.relPath)")
    // Use the same material kind/router as the real material sidebar, including
    // recording resolution and OS fallback, after workspace hydration settles.
    code = replace(code, 'openTab(\n      nativeMaterialDescriptor(pendingMaterial.courseId, pendingMaterial.relPath)\n    )', 'openMaterialInCourse(pendingMaterial.courseId, materialKindForPath(pendingMaterial.relPath), pendingMaterial.relPath)')
    code = "import { materialKindForPath } from '../../../shared/materialKind'\nimport { openMaterialInCourse } from '../features/workspace/openMaterial'\n" + code
  }
  if (id.endsWith('/renderer/src/features/chat/ChatSurface.tsx')) {
    code = replace(code, 'const session = useChatSession(courseId, conversationKey, surface)', "const effectiveSurface = surface === 'app' && (variant === 'sidebar' || sourcePanelId) ? 'desktop' : surface\n  const session = useChatSession(courseId, conversationKey, effectiveSurface)")
    code = replace(code, 'surface={surface}', 'surface={session.surface ?? effectiveSurface}')
  }
  if (id.endsWith('/renderer/src/features/chat/chatSessionStore.ts')) {
    code = replace(code, 'export interface ChatSessionSnapshot {', 'export interface ChatSessionSnapshot {\n  surface?: ChatSurface')
    code = replace(code, '  runtime.surface = surface\n', '  runtime.surface = snapshotFor(conversationId).surface ?? surface\n')
    code = replace(code, '    checkpoint = result.eventSeq', '    runtime.surface = result.sessionInfo?.surface ?? runtime.surface\n    checkpoint = result.eventSeq')
    code = replace(code, '      provider: result.sessionInfo?.provider ?? current.provider,', '      surface: runtime.surface,\n      provider: result.sessionInfo?.provider ?? current.provider,')
  }
  if (id.endsWith('/renderer/src/features/chat/useChatSession.ts')) {
    code = replace(code, 'export interface ChatSessionApi {', 'export interface ChatSessionApi {\n  surface?: ChatSurface')
  }
  if (id.endsWith('/main/features/browser/webviewPolicy.ts')) {
    code = replace(code, "    action === 'toggle-left-rail' ||", "    action === 'open-assistant' ||\n    action === 'toggle-left-rail' ||")
    code = replace(code, "  switch (action) {", "  switch (action) {\n    case 'open-assistant': return action as PassthroughAction")
  }
  for (const [file, count] of keyboardFiles) if (id.endsWith('/renderer/src/' + file)) {
    const matches = [...code.matchAll(/window\.bandal\?\.platform === (['"])darwin\1/g)]
    if (matches.length !== count) throw new Error(`Keyboard platform anchor changed: ${file}`)
    code = code.replace(/window\.bandal\?\.platform === (['"])darwin\1/g, "['darwin', 'ipad'].includes(window.bandal?.platform ?? '')")
  }
  if (id.endsWith('/shared/keymap.ts') || id.endsWith('/settings/shortcuts/shortcutModel.ts')) {
    code = replace(code, "platform === 'darwin' || platform === 'mac' || platform === 'macos'", "platform === 'darwin' || platform === 'mac' || platform === 'macos' || platform === 'ipad'")
  }
  if (id.endsWith('/shared/keymap.ts')) {
    code = replace(code, "  | 'new-ai-tab'", "  | 'new-ai-tab'\n  | 'open-assistant'")
    code = replace(code, "export const SHORTCUT_SPECS = [", "export const SHORTCUT_SPECS = [\n  { id: 'open-assistant', labelKo: '현재 자료의 AI 열기', labelEn: 'Open current material assistant', defaultChord: 'mod+shift+space', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },")
  }
  if (id.endsWith('/shared/ipc/events.ts')) {
    code = replace(code, "export interface ShortcutPassthrough {\n  action:", "export interface ShortcutPassthrough {\n  action:\n    | 'open-assistant'")
  }
  if (id.endsWith('/renderer/src/app/shortcuts.ts')) {
    code = "import { openActiveAssistant } from '../features/assistantPanel/assistantController'\n" + code
    code = replace(code, "  | { type: 'new-tab' }", "  | { type: 'new-tab' }\n  | { type: 'open-assistant' }")
    code = replace(code, "  switch (id) {", "  switch (id) {\n    case 'open-assistant': return { type: 'open-assistant' }")
    code = replace(code, '  switch (action.type) {', "  switch (action.type) {\n    case 'open-assistant': openActiveAssistant(); return")
    code = replace(code, '  switch (action) {', "  switch (action) {\n    case 'open-assistant': return { type: 'open-assistant' }")
  }
  if (id.endsWith('/settings/SettingsPanels.tsx')) {
    const start = code.indexOf('function GeminiApiKeyRow('), end = code.indexOf('\nfunction AgentConnector(', start)
    if (start < 0 || end < 0) throw new Error('Desktop API row boundary changed')
    let row = code.slice(start, end)
    row = replace(row, 'function GeminiApiKeyRow({ onRefresh }: { onRefresh: () => void })', 'function GeminiApiKeyRow({ onRefresh, provider }: { onRefresh: () => void; provider: AgentProvider })')
    row = replace(row, "invoke('agent:geminiApiKey', {})", "nativeAIRequest('agent:apiKey', { provider })")
    row = replace(row, "invoke('agent:setGeminiApiKey', { key: nextKey })", "nativeAIRequest('agent:setApiKey', { provider, key: nextKey })")
    row = replace(row, "refreshAgentConnectionAfterMutation('gemini')", 'refreshAgentConnectionAfterMutation(provider)')
    row = replace(row, "url: 'https://aistudio.google.com/apikey'", "url: provider === 'codex' ? 'https://platform.openai.com/api-keys' : provider === 'claude-code' ? 'https://console.anthropic.com/settings/keys' : 'https://aistudio.google.com/apikey'")
    row = replace(row, '}, [])', '}, [provider])')
    code = code.slice(0, start) + row + code.slice(end)
    const connectorStart = code.indexOf('function AgentConnector('), connectorEnd = code.indexOf('\nfunction ProviderCard(', connectorStart)
    let connector = code.slice(connectorStart, connectorEnd)
    const returnStart = connector.indexOf('  return <>'), returnEnd = connector.lastIndexOf('\n}')
    if (returnStart < 0 || returnEnd < 0) throw new Error('Desktop connector boundary changed')
    connector = connector.slice(0, returnStart) + '  return <GeminiApiKeyRow provider={provider} onRefresh={onRefresh} />' + connector.slice(returnEnd)
    code = code.slice(0, connectorStart) + connector + code.slice(connectorEnd)
    code = `import { nativeAIRequest } from ${JSON.stringify(apiPath)}\n` + code
  }
  if (id.endsWith('/settings/McpServersPanel.tsx')) {
    code = replace(code, "server?.transport ?? 'stdio'", "server?.transport ?? 'http'")
    code = replace(code, 'value="stdio"', 'value="stdio" disabled')
    code = replace(code, '<span>stdio</span>', "<span>stdio — {t('settings.mcp.notice.stdio')}</span>")
  }
  if (id.endsWith('/settings/PluginsCategoryPanel.tsx')) {
    // The bundled catalog presets launch local Node processes. Preserve their
    // original rows, but explain the platform limit before asking for a token.
    code = replace(code, "const complete = preset.fields.every(field => (values[field.key] ?? '').trim())", "const complete = preset.fields.every(field => (values[field.key] ?? '').trim())\n  const localOnly = preset.input('', {}).transport === 'stdio'")
    code = replace(code, 'if (complete && !busy && !disabled) onSave(values)', 'if (complete && !busy && !disabled && !localOnly) onSave(values)')
    code = replace(code, "{ko ? '아래 정보를 저장한 뒤 연결을 확인합니다. 확인에 성공하면 화면 도우미에서 사용할 수 있습니다.'", "{localOnly ? t('settings.mcp.notice.stdio') : ko ? '아래 정보를 저장한 뒤 연결을 확인합니다. 확인에 성공하면 화면 도우미에서 사용할 수 있습니다.'")
    code = replace(code, 'autoComplete="off" value={values[field.key]', 'autoComplete="off" disabled={localOnly} value={values[field.key]')
    code = replace(code, 'disabled={disabled || busy || !complete}', 'disabled={disabled || busy || !complete || localOnly}')
  }
  if (id.endsWith('/settings/advanced/ExperimentalPanel.tsx')) {
    code = replace(code, 'disabled={settings === null}', 'disabled={settings === null || flag === \'extensionRuntime\'}')
  }
  if (id.endsWith('/i18n/messages/ko-KR.ts') || id.endsWith('/i18n/messages/en-US.ts')) {
    const ko = id.endsWith('/ko-KR.ts')
    const labels = {
      'settings.mcp.notice.stdio': ko ? 'iPad에서 로컬 명령어는 실행할 수 없습니다. HTTPS 원격 MCP 서버를 사용하세요.' : 'Local commands cannot run on iPad. Use an HTTPS remote MCP server.',
      'settings.assistant.screen.description': ko ? '반달 앱 안의 화면을 캡처해 AI에 첨부합니다. 다른 앱 화면 읽기·조작은 iPad에서 지원하지 않습니다.' : 'Capture a view inside Bandal and attach it to AI. Reading or controlling another app is unavailable on iPad.',
      'settings.ai.claude.description': 'Claude API · BYOK', 'settings.ai.codex.description': 'OpenAI API · BYOK', 'settings.ai.gemini.description': 'Gemini API · BYOK',
      'settings.ai.apiKey.description': ko ? '키는 이 기기의 키체인에 보관됩니다. 제공자 API 사용료가 적용됩니다.' : 'Keys are stored in this device’s Keychain. Provider API billing applies.',
      'settings.browser.dnt.description': ko ? 'iPad에서는 웹 페이지 신호와 직접 연 주소 요청에 적용됩니다. 페이지 내부의 모든 요청에 헤더를 추가하지는 못합니다.' : 'On iPad, signals are exposed to pages and headers apply to directly opened URLs. Headers cannot be added to every page subrequest.',
      'settings.experimental.extensionRuntime.description': ko ? 'iPad에서는 로컬 프로세스를 실행하는 플러그인을 지원하지 않습니다. 학습 팩은 별도로 사용할 수 있습니다.' : 'Local process plugins are unavailable on iPad. Learning packs are supported separately.',
      'settings.ai.apiKey.inputLabel': ko ? 'API 키' : 'API key',
      'settings.ai.install': ko ? '실행 환경' : 'Runtime', 'settings.ai.installed': ko ? 'iPad API 연결 내장' : 'Built-in iPad API adapter',
      'settings.ai.version': ko ? '연결 방식' : 'Connection type', 'settings.ai.login': ko ? 'API 연결' : 'API connection',
      'settings.ai.loginRequired': ko ? 'API 키 필요' : 'API key required', 'settings.ai.subscription': ko ? '사용 방식' : 'Billing mode'
    }
    for (const [key, value] of Object.entries(labels)) {
      const expression = new RegExp(`('${key.replaceAll('.', '\\.')}': )'[^\\n]*'`)
      if (!expression.test(code)) throw new Error(`API translation anchor changed: ${key}`)
      code = code.replace(expression, (_all, prefix) => prefix + JSON.stringify(value))
    }
  }
  return code === source ? null : { code, map: null }
}
export default function ipadPlatformPlugin() { return { name: 'bandal-ipad-platform-contracts', enforce: 'pre', transform: adaptPlatformSource } }
