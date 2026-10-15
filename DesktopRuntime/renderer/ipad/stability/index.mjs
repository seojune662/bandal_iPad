import { fileURLToPath } from 'node:url'
const materials = fileURLToPath(new URL('./materialActions.tsx', import.meta.url))
const recovery = fileURLToPath(new URL('./recovery.ts', import.meta.url))
const documentBoundary = fileURLToPath(new URL('./DocumentErrorBoundary.tsx', import.meta.url))
const operations = fileURLToPath(new URL('./operations.ts', import.meta.url))
const materialWatch = fileURLToPath(new URL('./MaterialWatchNotice.tsx', import.meta.url))
function replace(source, needle, value, count = 1) {
  const actual = source.split(needle).length - 1
  if (actual !== count) throw new Error(`iPad stability adapter anchor changed (${actual}/${count}): ${needle}`)
  return source.split(needle).join(value)
}
export function adaptStabilitySource(source, id) {
  let code = source
  if (id.endsWith('/features/help/HelpHub.tsx')) {
    code = replace(code, "import { showToast } from '../../app/toast'\n", '')
    code = replace(code, '  const checkUpdates = useUpdateStore((state) => state.check)\n', '')
    code = replace(code, "  const checkingUpdate = updateStatus?.phase === 'checking'\n", '')
    code = replace(code, '            disabled={checkingUpdate}\n', '')
    code = replace(code, `              void checkUpdates().catch((error: unknown) => {
                console.error('[Bandal] 업데이트를 확인하지 못했습니다.', error)
                showToast(t('help.updateFailed'), 'danger')
              })`, `              closeMenu()
              useUiStore.getState().openSettings('about')`)
    code = replace(code, "{t(checkingUpdate ? 'help.menu.checkingUpdate' : 'help.menu.checkUpdate')}", "{locale === 'ko-KR' ? '업데이트 안내' : 'Update instructions'}")
  }
  if (id.endsWith('/features/workspace/panelContentHost.tsx')) {
    code = `import { DocumentErrorBoundary } from ${JSON.stringify(documentBoundary)}\n` + code
    code = replace(code, '<Component {...entry.props} />', '<DocumentErrorBoundary><Component {...entry.props} /></DocumentErrorBoundary>')
  }
  if (id.endsWith('/features/notes/NoteTab.tsx')) {
    code = `import { trackDocumentClose } from ${JSON.stringify(recovery)}\n` + code
    code = replace(code, 'const task = preserveNoteOnClose({', 'const task = trackDocumentClose(() => preserveNoteOnClose({')
    code = replace(code, '      notify: showToast\n    })', '      notify: showToast\n    }))')
  }
  if (id.endsWith('/features/materials/MaterialTree.tsx')) {
    const start = code.indexOf('function startMaterialDragEvent('), end = code.indexOf('\nfunction focusAdjacentRow(', start)
    if (start < 0 || end < 0) throw new Error('iPad material drag adapter boundary changed')
    code = code.slice(0, start) + 'const startMaterialDragEvent = startIPadMaterialDrag\n' + code.slice(end)
    code = `import { startIPadMaterialDrag } from ${JSON.stringify(materials)}\n` + code
  }
  if (id.endsWith('/features/materials/MaterialsSidebar.tsx')) {
    code = `import { MaterialMoveDialog } from ${JSON.stringify(materials)}\n` + code
    code = `import { MaterialWatchNotice } from ${JSON.stringify(materialWatch)}\n` + code
    code = replace(code, '  const [linkTarget, setLinkTarget]', '  const [moveTarget, setMoveTarget] = useState<{ courseId: string; node: MaterialNode } | null>(null)\n  const [linkTarget, setLinkTarget]')
    const watchStart = code.indexOf('  // [M5] Live tree:'), watchEnd = code.indexOf('\n\n  useEffect(() => {', watchStart)
    if (watchStart < 0 || watchEnd < 0 || !code.slice(watchStart, watchEnd).includes("invoke('materials:unwatch'")) throw new Error('iPad material watch adapter boundary changed')
    code = code.slice(0, watchStart) + code.slice(watchEnd)
    code = replace(code, '      {error !== null && (', `      <MaterialWatchNotice key={course?.folderPath} courseId={course && !course.missing ? course.id : null} onChange={id => loadTree(id, { silent: true })} />
      {error !== null && (`)
    code = replace(code, '    toDirRelPath: string\n  ): Promise<void> => {', '    toDirRelPath: string,\n    propagate = false\n  ): Promise<void> => {')
    code = replace(code, "      showToast(operationError(moveError, '자료를 이동하지 못했습니다.'), 'danger')", "      if (propagate) throw moveError\n      showToast(operationError(moveError, '자료를 이동하지 못했습니다.'), 'danger')")
    code = replace(code, '      {contextMenu !== null && (', `      {moveTarget !== null && <MaterialMoveDialog target={moveTarget.node} tree={useMaterialsStore.getState().tree} onClose={() => setMoveTarget(null)} onMove={async directory => {
        if (!course || course.id !== moveTarget.courseId || course.missing) throw new Error('자료를 연 과목이 변경되었습니다. 메뉴를 다시 열어 주세요.')
        await moveMaterial({ version: 1, courseId: course.id, relPath: moveTarget.node.relPath, kind: moveTarget.node.kind }, directory, true)
      }} />}
      {contextMenu !== null && (`)
    code = replace(code, '          onClose={closeContextMenu}', `          onClose={closeContextMenu}
          onMove={() => { if (course && contextMenu.target) setMoveTarget({ courseId: course.id, node: contextMenu.target }); closeContextMenu() }}`)
    code = replace(code, '폴더에서 자료를 표시하지 못했습니다.', '자료 미리보기를 열지 못했습니다.', 2)
  }
  if (id.endsWith('/features/materials/MaterialsContextMenu.tsx')) {
    code = `import { exportMaterial } from ${JSON.stringify(materials)}\n` + code
    code = replace(code, '  onReveal: () => void', '  onReveal: () => void\n  onMove: () => void')
    code = replace(code, '  onReveal,', '  onReveal,\n  onMove,')
    code = replace(code, '      <button type="button" role="menuitem" onClick={onCopyAbsolutePath}>', `      <button type="button" role="menuitem" disabled={!hasTarget} onClick={onMove}><Icon name="folderOpen" />이동…</button>
      {target && target.kind !== 'dir' && activeCourseId && <>
        <button type="button" role="menuitem" onClick={() => { onClose(); void exportMaterial('materials:share', activeCourseId, target.relPath) }}>공유…</button>
        <button type="button" role="menuitem" onClick={() => { onClose(); void exportMaterial('materials:export', activeCourseId, target.relPath) }}>파일에 저장…</button>
      </>}
      <button type="button" role="menuitem" onClick={onCopyAbsolutePath}>`)
    code = replace(code, '        disabled={!hasTarget}\n        onClick={onReveal}', "        disabled={!hasTarget || target?.kind === 'dir'}\n        onClick={onReveal}")
    code = replace(code, '<Icon name="folderOpen" />폴더에서 보기', '<Icon name="folderOpen" />미리보기')
  }
  if (id.endsWith('/app/RendererErrorBoundary.tsx')) {
    code = `import { recoverRenderer } from ${JSON.stringify(recovery)}\n` + code
    code = replace(code, 'onClick={() => window.location.reload()}', 'onClick={() => { void recoverRenderer().catch(() => undefined) }}')
    code = replace(code, '이미 저장한 파일과 필기는 보존되어 있습니다. 앱을 다시 불러오면 마지막\n            작업 화면부터 복구를 시도합니다.', '저장을 확인한 뒤 화면을 다시 불러옵니다. 저장 충돌이나 오류가 있으면\n            현재 문서를 유지하고 문제를 알려드립니다.')
  }
  if (id.endsWith('/stores/pluginsStore.ts')) {
    code = `import { BandalOperationError } from ${JSON.stringify(operations)}\n` + code
    code = replace(code, 'let refreshGeneration = 0', "let refreshGeneration = 0\nconst ipadPlugins = (plugins: PluginSummary[]): PluginSummary[] => plugins.map(plugin => ({ ...plugin, state: 'disabled' }))")
    code = replace(code, 'set({ plugins, loading: false, error: null })', 'set({ plugins: ipadPlugins(plugins), loading: false, error: null })')
    code = replace(code, 'set({ plugins: result.plugins, loading: false, error: null })', 'set({ plugins: ipadPlugins(result.plugins), loading: false, error: null })')
    code = replace(code, "await invoke('plugins:runCommand', { pluginId, commandId, ...(context ? { context } : {}) })", "throw new BandalOperationError({ code: 'UNSUPPORTED_ACTION', channel: 'plugins:runCommand', category: 'unsupported', retryable: false, message: '로컬 실행 플러그인은 데스크톱 반달에서 사용할 수 있습니다.' })")
  }
  if (id.endsWith('/features/plugins/PluginPanelTab.tsx')) {
    code = `import type { IDockviewPanelProps } from 'dockview'
import './plugins.css'
export function PluginPanelTab(_props: IDockviewPanelProps): JSX.Element { return <div className="plugin-panel" data-state="unsupported"><div className="plugin-panel-placeholder"><h2>iPad에서 실행할 수 없는 플러그인</h2><p>이 탭은 데스크톱 반달에서 사용할 수 있습니다. 설치 정보와 설정은 보관됩니다.</p></div></div> }`
  }
  if (id.endsWith('/features/plugins/PluginMenuItems.tsx')) {
    code = replace(code, '                  role="menuitem"', '                  role="menuitem" disabled title="이 플러그인은 데스크톱에서 실행할 수 있습니다"')
  }
  if (id.endsWith('/features/chat/AddMenu.tsx')) {
    code = replace(code, "Promise.all([invoke('agent:skills', { provider, courseId }), invoke('materials:tree', { courseId })]).then(([nextSkills, tree]) => {", "invoke('materials:tree', { courseId }).then(tree => {")
    code = replace(code, 'setSkills(nextSkills)', 'setSkills([])')
    code = replace(code, 'title="사진, 파일, 스킬 추가"', 'title="사진 및 파일 추가"')
    code = replace(code, "'해당 생성 스킬 연결 필요'", "'iPad API 연결은 CLI 스킬을 지원하지 않습니다'")
    code = replace(code, "type=\"button\" onClick={() => setSection('skills')}", "type=\"button\" disabled title=\"설치된 CLI 스킬은 데스크톱에서 사용할 수 있습니다\" onClick={() => setSection('skills')}")
    code = replace(code, '{skills.length}개 연결됨', '데스크톱 CLI 기능')
    code = replace(code, '현재 AI 계정에 설치된 스킬을 사용해요. 새로 설치했다면 메뉴를 다시 열어 주세요. 연결 설정은 설정 → AI에서 관리할 수 있어요.', 'iPad에서는 API로 AI를 사용합니다. 설치된 CLI 스킬과 해당 생성 작업은 데스크톱에서 사용할 수 있어요. 사진과 과목 자료는 위 메뉴에서 첨부할 수 있습니다.')
  }
  if (id.endsWith('/features/chat/AgentConnectionControls.tsx')) {
    if (!code.includes('export function AgentConnectionControls(')) throw new Error('iPad AI setup adapter boundary changed')
    code = `import type { AgentAvailability, AgentProvider } from '../../../../shared/types/agent-events'
import { useLocale } from '../../i18n'
import { useUiStore } from '../../stores/uiStore'
import { useAgentConnectionStore } from './agentConnectionStore'
import { featureReadiness } from ${JSON.stringify(operations)}
import './agent-connection.css'
export function AgentConnectionControls({ provider, availability }: { provider: AgentProvider; availability: AgentAvailability }): JSX.Element {
  const connection = useAgentConnectionStore(state => state.connections[provider])
  const state = featureReadiness('ai', connection.availability ?? availability)
  const english = useLocale() === 'en-US'
  const name = provider === 'codex' ? 'OpenAI' : provider === 'claude-code' ? 'Claude' : 'Gemini'
  return <section className="agent-connection" aria-label={english ? name + ' API setup' : name + ' API 연결 설정'} data-state={connection.availabilityError ? 'unknown' : state.state}>
    <p className="agent-connection__intro">{state.state === 'available'
      ? english ? 'An API key is configured. Requests still depend on the provider connection, credentials and quota.' : 'API 키가 등록되어 있습니다. 실제 요청은 제공자 연결, 인증 및 사용 한도에 따라 달라집니다.'
      : state.state === 'unsupported' ? state.reason
        : english ? 'Add this provider’s API key in AI settings to use it on iPad.' : 'iPad에서 사용하려면 AI 설정에 이 제공자의 API 키를 등록해 주세요.'}</p>
    <p className="agent-connection__limits">{english ? 'API usage is billed by the provider, separately from a chat subscription.' : 'API 사용료는 제공자가 별도로 청구하며 채팅 구독과 다릅니다.'}</p>
    {connection.availabilityError && <p className="agent-connection__error" role="alert">{connection.availabilityError}</p>}
    <button type="button" className="agent-connection__primary" onClick={() => useUiStore.getState().openSettings('ai')}>{english ? 'Open API settings' : 'API 연결 설정 열기'}</button>
  </section>
}`
  }
  if (id.endsWith('/settings/PluginDevelopmentPanel.tsx')) {
    code = `export function PluginDevelopmentPanel(): JSX.Element { return <section className="marketplace-form"><h2>플러그인 개발</h2><p>로컬 코드 실행과 개발 폴더 감시는 iPad에서 지원하지 않습니다. 데스크톱 반달에서 개발할 수 있습니다. 학습 팩과 HTTPS MCP 도구는 iPad에서도 사용할 수 있습니다.</p></section> }`
  }
  if (id.endsWith('/settings/PluginsCategoryPanel.tsx')) {
    code = replace(code, "disabled={actionDisabled || row.kind === 'plugin' && (settings === null || row.plugin.state === 'starting' && runtime) || row.kind === 'external' && !available}", "disabled={actionDisabled || row.kind === 'plugin' || row.kind === 'external' && !available}")
    code = replace(code, "{!runtime && <p className=\"plugin-center-hint\">{ko ? '확장 기능 실행이 꺼져 있습니다. 이 확장을 켤 때 실행 여부와 권한을 확인합니다.' : 'Extension execution is off. Enabling this extension will review its execution and permissions.'}</p>}", "<p className=\"plugin-center-hint\">{ko ? '이 플러그인의 로컬 실행은 iPad에서 지원하지 않습니다. 설정과 설치 정보는 보관되며 데스크톱에서 사용할 수 있습니다.' : 'Local plugin execution is unavailable on iPad. Its settings and installation details remain available for desktop use.'}</p>")
    code = replace(code, "{ko ? '켜면 도구 목록과 해당 메뉴에서 사용할 수 있습니다.' : 'When enabled, these actions appear in the tools list and relevant menus.'}", "{ko ? '아래 작업은 데스크톱에서 실행할 수 있습니다.' : 'These actions can run on desktop.'}")
    code = replace(code, 'disabled={actionDisabled || !runtime} onClick=', 'disabled title="iPad에서는 플러그인을 실행할 수 없습니다" onClick=')
    code = replace(code, 'aria-expanded={logsOpen} onClick={() => setLogsOpen(open => !open)}', 'disabled title="iPad 실행 로그는 제공되지 않습니다" aria-expanded={false} onClick={() => setLogsOpen(open => !open)}')
    code = replace(code, '<button role="menuitem" onClick={installFolder}>', '<button role="menuitem" disabled title="로컬 실행 플러그인은 데스크톱에서 설치해 주세요" onClick={installFolder}>')
  }
  if (id.endsWith('/settings/ExtensionsPanel.tsx')) {
    code = replace(code, "disabled={pending || pendingId === '__install__'}", 'disabled title="iPad에서는 플러그인을 실행할 수 없습니다"')
    code = replace(code, 'disabled={pending}\n                    onClick={() => void reload(plugin)}', 'disabled\n                    onClick={() => void reload(plugin)}')
    code = replace(code, 'aria-expanded={logsOpen}', 'disabled aria-expanded={false}')
    code = replace(code, 'disabled={pendingId !== null}\n          onClick={() => void install()}', 'disabled\n          onClick={() => void install()}')
  }
  if (id.endsWith('/settings/catalog/CatalogCard.tsx')) {
    code = replace(code, "const runtimeBlocked = entry.kind === 'extension' && !runtimeEnabled", "const runtimeBlocked = entry.kind === 'extension'")
    code = replace(code, 'onClick={onOpenExperimental}', 'disabled onClick={onOpenExperimental}')
    code = replace(code, "{t('settings.catalog.card.enableInExperimental')}", "{ko ? 'iPad에서 실행할 수 없는 플러그인' : 'Plugin cannot run on iPad'}")
  }
  return code === source ? null : { code, map: null }
}
export default function ipadStabilityPlugin() { return { name: 'bandal-ipad-stability', enforce: 'pre', transform: adaptStabilitySource } }
