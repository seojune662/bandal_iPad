import { useEffect, useMemo, useRef, useState } from 'react'
import type { McpServerSummary } from '../../../../shared/types/mcp'
import type { PluginLogEntry, PluginSummary } from '../../../../shared/types/plugin'
import type { Settings } from '../../../../shared/types/settings'
import { describePermission } from '../../../../shared/plugins/permissions'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useLocale, useT } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import { usePluginsStore } from '../../stores/pluginsStore'
import { useWorkflowPacksStore } from '../../stores/workflowPacksStore'
import { PluginPermissionDialog } from '../plugins/PluginPermissionDialog'
import { CatalogPanel } from './catalog/CatalogPanel'
import { PluginDevelopmentPanel } from './PluginDevelopmentPanel'
import { MarketplacePanel } from './MarketplacePanel'
import { PluginConfiguration } from './PluginConfiguration'
import { ImportDialog } from './PacksPanel'
import { McpServerEditor, loadMcpServers, summaryInput, useMcpRegistry } from './McpServersPanel'
import { parseMcpConfigText } from './mcpImport'
import { type McpPreset } from './mcpPresets'
import { PluginFeatureMark } from './PluginFeatureMark'
import { buildPluginCenterRows, filterPluginCenterRows, type PluginCenterFilter, type PluginCenterRow } from './pluginCenterModel'
import { Icon } from './SettingsIcon'
import './settings-plugins.css'
import './plugin-center.css'

type CenterView = { kind: 'list' } | { kind: 'row'; id: string } | { kind: 'catalog' | 'developer' | 'manual' | 'import' }
function approved(plugin: PluginSummary): boolean {
  return plugin.state !== 'needs-approval' && plugin.approvedPermissions !== null && plugin.manifest.permissions.every(permission => plugin.approvedPermissions?.includes(permission))
}

function availablePresetName(preset: McpPreset, servers: readonly McpServerSummary[]): string {
  const base = preset.input('', {}).name
  let candidate = base, suffix = 2
  while (servers.some(server => server.name === candidate)) candidate = `${base}-${suffix++}`
  return candidate
}

function PresetSetup({ preset, disabled, busy, onSave }: { preset: McpPreset; disabled: boolean; busy: boolean; onSave: (values: Record<string, string>) => void }): JSX.Element {
  const t = useT()
  const ko = useLocale() === 'ko-KR'
  const [values, setValues] = useState<Record<string, string>>({})
  const complete = preset.fields.every(field => (values[field.key] ?? '').trim())
  return <form className="plugin-center-setup" onSubmit={event => { event.preventDefault(); if (complete && !busy && !disabled) onSave(values) }}>
    <p>{ko ? '아래 정보를 저장한 뒤 연결을 확인합니다. 확인에 성공하면 화면 도우미에서 사용할 수 있습니다.' : 'Save these details and check the connection. After a successful check, the screen assistant can use this tool.'}</p>
    {preset.id === 'notion' && <p>{ko ? 'Notion에서 통합을 만들고 토큰을 복사한 다음, 사용할 페이지에 해당 통합의 접근 권한을 추가해 주세요.' : 'Create a Notion integration, copy its token, then grant the integration access to the pages you want to use.'} <button type="button" className="plugin-center-help-link" onClick={() => { void invoke('shell:openExternal', { url: 'https://www.notion.com/help/create-integrations-with-the-notion-api' }).catch(() => undefined) }}>{ko ? 'Notion 설정 안내' : 'Notion setup guide'}</button></p>}
    {preset.fields.map(field => <label className="settings-mcp-field" key={field.key}><span>{t(field.labelKey)}</span><input type={field.secret ? 'password' : 'text'} autoComplete="off" value={values[field.key] ?? ''} placeholder={field.placeholder} onChange={event => setValues(current => ({ ...current, [field.key]: event.target.value }))} /></label>)}
    <p className="plugin-center-hint">{ko ? '연결 확인 시 서버를 실행합니다. 실행 환경이나 서비스 토큰이 준비되지 않았다면 설정은 꺼진 상태로 남습니다.' : 'Checking runs the server. If its runtime or service credentials are not ready, the saved tool stays off.'}</p>
    <button type="submit" className="settings-extension-button settings-extension-button--primary" disabled={disabled || busy || !complete}>{busy ? ko ? '연결 확인 중…' : 'Checking connection…' : ko ? '연결하고 사용하기' : 'Connect and use'}</button>
    <details><summary>{ko ? '실행 정보' : 'Execution details'}</summary><code>{preset.packageName}</code></details>
  </form>
}

function PluginLogs({ id }: { id: string }): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [entries, setEntries] = useState<PluginLogEntry[] | null>(null)
  const [error, setError] = useState(false)
  useEffect(() => { let active = true; void invoke('plugins:logs', { id }).then(result => { if (active) setEntries(result.entries) }).catch(() => { if (active) setError(true) }); return () => { active = false } }, [id])
  return <div className="plugin-center-logs">{error ? <p role="alert">{ko ? '로그를 불러오지 못했습니다.' : 'Could not load logs.'}</p> : entries === null ? <p role="status">{ko ? '불러오는 중…' : 'Loading…'}</p> : entries.length === 0 ? <p>{ko ? '기록된 로그가 없습니다.' : 'No logs recorded.'}</p> : entries.map((entry, index) => <p key={index}><time>{entry.at}</time> {entry.level}: {entry.message}</p>)}</div>
}

export function PluginsCategoryPanel({ searchTarget, initialFilter = 'all' }: { searchTarget?: string | null; initialFilter?: PluginCenterFilter } = {}): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const ko = locale === 'ko-KR'
  const [view, setView] = useState<CenterView>({ kind: 'list' })
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<PluginCenterFilter>(initialFilter)
  const [settings, setSettings] = useState<Settings | null>(null)
  const [settingsError, setSettingsError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [pending, setPending] = useState<string | null>(null)
  const [feedback, setFeedback] = useState<string | null>(null)
  const [permissionPlugin, setPermissionPlugin] = useState<PluginSummary | null>(null)
  const [runtimePlugin, setRuntimePlugin] = useState<PluginSummary | null>(null)
  const [logsOpen, setLogsOpen] = useState(false)
  const [editing, setEditing] = useState(false)
  const [packImportOpen, setPackImportOpen] = useState(false)
  const [importText, setImportText] = useState('')
  const [menuOpen, setMenuOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const runtimeRef = useRef<HTMLElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  useFocusTrap(runtimeRef, { active: runtimePlugin !== null, onEscape: pending ? undefined : () => setRuntimePlugin(null) })
  useFocusTrap(menuRef, { active: menuOpen, onEscape: () => setMenuOpen(false) })
  const scrollTop = useRef(0)
  const focusRow = useRef<string | null>(null)
  const handledTarget = useRef<string | null>(null)
  const packs = useWorkflowPacksStore(state => state.packs)
  const packsLoading = useWorkflowPacksStore(state => state.loading)
  const packsError = useWorkflowPacksStore(state => state.error)
  const plugins = usePluginsStore(state => state.plugins)
  const pluginsLoading = usePluginsStore(state => state.loading)
  const pluginsError = usePluginsStore(state => state.error)
  const registry = useMcpRegistry()
  const runtime = settings?.experimental.extensionRuntime ?? false
  const rows = useMemo(() => buildPluginCenterRows(packs, plugins, registry.servers, runtime, ko), [packs, plugins, registry.servers, runtime, ko])
  const visible = useMemo(() => filterPluginCenterRows(rows, query, filter), [rows, query, filter])
  const selected = view.kind === 'row' ? rows.find(row => row.id === view.id) : undefined
  const parsedImport = useMemo(() => parseMcpConfigText(importText), [importText])
  const available = registry.availability?.available === true
  const otherEnabled = plugins.filter(plugin => plugin.manifest.id !== (permissionPlugin ?? runtimePlugin)?.manifest.id && plugin.enabled && approved(plugin)).map(plugin => plugin.manifest.name)
  const runtimeNotice = ko
    ? `확장 기능 실행을 켜면 이 플러그인이 실행됩니다.${otherEnabled.length ? ` 이미 켜 둔 ${otherEnabled.join(', ')}도 함께 시작합니다.` : ''}`
    : `Enabling extension execution starts this plugin.${otherEnabled.length ? ` It also starts ${otherEnabled.join(', ')}, which are already enabled.` : ''}`

  useEffect(() => { setFilter(initialFilter) }, [initialFilter])
  useEffect(() => {
    let active = true, pushed = false
    setSettingsError(false)
    const stop = onPush('settings:changed', ({ settings: next }) => { pushed = true; if (active) setSettings(next) })
    void invoke('settings:get', {}).then(next => { if (active && !pushed) setSettings(next) }).catch(() => { if (active) setSettingsError(true) })
    void useWorkflowPacksStore.getState().load()
    void usePluginsStore.getState().refresh().catch(() => undefined)
    return () => { active = false; stop() }
  }, [attempt])
  useEffect(() => {
    if (!searchTarget || handledTarget.current === searchTarget) return
    const match = rows.find(row => row.name === searchTarget || row.kind === 'plugin' && row.plugin.manifest.contributes.settings?.some(field => field.title === searchTarget))
    if (match) { handledTarget.current = searchTarget; setView({ kind: 'row', id: match.id }); return }
    if (['MCP 서버', 'MCP servers', '서버 연결', 'Server connections'].includes(searchTarget)) { handledTarget.current = searchTarget; setFilter('external'); setView({ kind: 'list' }) }
    if (['개발자 센터', 'Developer center', '로컬 개발', 'Local development'].includes(searchTarget)) { handledTarget.current = searchTarget; setView({ kind: 'developer' }) }
    if (['카탈로그', 'Catalog', '소스', 'Sources'].includes(searchTarget)) { handledTarget.current = searchTarget; setView({ kind: 'catalog' }) }
  }, [searchTarget, rows])
  useEffect(() => {
    if (view.kind !== 'list') { const scroller = rootRef.current?.closest('.settings-content'); if (scroller) scroller.scrollTop = 0; return }
    const scroller = rootRef.current?.closest('.settings-content')
    if (scroller) scroller.scrollTop = scrollTop.current
    if (focusRow.current) [...rootRef.current?.querySelectorAll<HTMLElement>('[data-feature-id]') ?? []].find(row => row.dataset['featureId'] === focusRow.current)?.querySelector<HTMLElement>('.plugin-center-row__open')?.focus({ preventScroll: true })
  }, [view])

  const openView = (next: CenterView, rowId?: string): void => {
    if (view.kind === 'list') scrollTop.current = rootRef.current?.closest('.settings-content')?.scrollTop ?? 0
    focusRow.current = rowId ?? null
    setLogsOpen(false); setEditing(false); setMenuOpen(false); setFeedback(null); setView(next)
  }
  const back = (): void => { setEditing(false); setLogsOpen(false); setView({ kind: 'list' }) }
  const run = async (id: string, operation: () => Promise<void>): Promise<void> => {
    if (pending !== null) return
    setPending(id); setFeedback(null)
    try { await operation() } catch (error) { setFeedback(error instanceof Error ? error.message : ko ? '작업을 완료하지 못했습니다. 다시 시도해 주세요.' : 'Could not finish. Please try again.') } finally { setPending(null) }
  }
  const enablePlugin = async (plugin: PluginSummary, enableRuntime = false): Promise<void> => {
    await run(`plugin:${plugin.manifest.id}`, async () => {
      if (!approved(plugin)) await invoke('plugins:approve', { id: plugin.manifest.id })
      if (enableRuntime) setSettings(await invoke('settings:set', { experimental: { extensionRuntime: true } }))
      await invoke('plugins:setEnabled', { id: plugin.manifest.id, enabled: true })
      await usePluginsStore.getState().refresh()
      setPermissionPlugin(null); setRuntimePlugin(null)
    })
  }
  const checkAndEnable = async (server: McpServerSummary): Promise<void> => {
    const result = await invoke('mcp:test', { id: server.id })
    if (!result.ok) { await loadMcpServers(); throw new Error(result.error || (ko ? '연결 확인에 실패했습니다. 설정을 확인한 뒤 다시 시도해 주세요.' : 'Connection check failed. Review the settings and try again.')) }
    await invoke('mcp:save', summaryInput(server, true))
    await loadMcpServers()
  }
  const toggle = (row: PluginCenterRow): void => {
    if (pending !== null) return
    if (row.kind === 'study') { void run(row.id, () => useWorkflowPacksStore.getState().setEnabled(row.summary.pack.id, !row.checked)); return }
    if (row.kind === 'plugin') {
      if (row.checked) { void run(row.id, async () => { await invoke('plugins:setEnabled', { id: row.plugin.manifest.id, enabled: false }); await usePluginsStore.getState().refresh() }); return }
      if (!approved(row.plugin)) { setPermissionPlugin(row.plugin); return }
      if (!runtime) { setRuntimePlugin(row.plugin); return }
      void enablePlugin(row.plugin); return
    }
    if (row.kind === 'external') void run(row.id, async () => { if (row.server.enabled) { await invoke('mcp:save', summaryInput(row.server, false)); await loadMcpServers() } else await checkAndEnable(row.server) })
  }
  const savedExternal = (server: McpServerSummary): void => {
    setEditing(false); setView({ kind: 'row', id: `mcp:${server.id}` })
    void run(`mcp:${server.id}`, () => checkAndEnable(server))
  }
  const installFolder = (): void => { setMenuOpen(false); void run('install', async () => { const picked = await invoke('plugins:pickFolder', {}); if (!picked.path) return; const result = await invoke('plugins:installFromFolder', { path: picked.path }); await usePluginsStore.getState().refresh(); openView({ kind: 'row', id: `plugin:${result.plugin.manifest.id}` }); if (result.warnings.length) setFeedback(result.warnings.join('\n')) }) }
  const actionDisabled = pending !== null
  const switchFor = (row: PluginCenterRow): JSX.Element => <button type="button" role="switch" aria-label={ko ? `${row.name} 사용` : `Use ${row.name}`} aria-checked={row.checked} className={`toggle${row.checked ? ' toggle--checked' : ''}`} disabled={actionDisabled || row.kind === 'plugin' && (settings === null || row.plugin.state === 'starting' && runtime) || row.kind === 'external' && !available} onClick={() => toggle(row)}><span className="toggle__thumb" /></button>

  return <div className="plugin-center" ref={rootRef} aria-busy={pending !== null}>
    {view.kind === 'list' ? <>
      <div className="plugin-center-toolbar">
        <label className="plugin-center-search"><Icon name="search" /><input type="search" aria-label={t('settings.pluginCenter.search')} placeholder={t('settings.pluginCenter.search')} value={query} onChange={event => setQuery(event.target.value)} /></label>
        <select className="language-select" aria-label={t('settings.pluginCenter.filter')} value={filter} onChange={event => setFilter(event.target.value as PluginCenterFilter)}>{(['all', 'study', 'plugin', 'external'] as const).map(id => <option key={id} value={id}>{t(`settings.pluginCenter.filter.${id}`)}</option>)}</select>
        <button type="button" className="settings-extension-button" onClick={() => openView({ kind: 'catalog' })}>{t('settings.pluginCenter.browse')}</button>
        <div className="plugin-center-add"><button type="button" className="settings-extension-button settings-extension-button--primary" aria-expanded={menuOpen} aria-haspopup="menu" onClick={() => setMenuOpen(open => !open)}>{t('settings.pluginCenter.add')} <span aria-hidden="true">⌄</span></button>{menuOpen && <><button className="plugin-center-menu-dismiss" aria-label={ko ? '추가 메뉴 닫기' : 'Close add menu'} onClick={() => setMenuOpen(false)} /><div ref={menuRef} className="plugin-center-menu" role="menu" onKeyDown={event => { if (event.key === 'Escape') setMenuOpen(false) }}>
          <button role="menuitem" onClick={installFolder}>{ko ? '플러그인 폴더에서 설치' : 'Install plugin from folder'}</button>
          <button role="menuitem" onClick={() => { setMenuOpen(false); setPackImportOpen(true) }}>{ko ? '학습 도구 가져오기' : 'Import study tool'}</button>
          <button role="menuitem" onClick={() => openView({ kind: 'import' })}>{ko ? 'MCP 설정 가져오기' : 'Import MCP settings'}</button>
          <button role="menuitem" disabled={!available} onClick={() => openView({ kind: 'manual' })}>{ko ? '외부 도구 직접 추가' : 'Add external tool manually'}</button>
          <button role="menuitem" onClick={() => openView({ kind: 'developer' })}>{ko ? '개발 및 배포 관리' : 'Development and publishing'}</button>
          {runtime && <button role="menuitem" onClick={() => { setMenuOpen(false); void run('runtime', async () => { setSettings(await invoke('settings:set', { experimental: { extensionRuntime: false } })); await usePluginsStore.getState().refresh() }) }}>{ko ? '실행 중인 확장 모두 끄기' : 'Stop all extension execution'}</button>}
        </div></>}</div>
      </div>
      {(packsLoading || pluginsLoading || registry.loading) && rows.length === 6 && <p role="status">{t('settings.pluginCenter.loading')}</p>}
      {(packsError || pluginsError || settingsError || registry.error) && <p className="plugin-center-feedback" role="alert">{ko ? '일부 기능을 불러오지 못했습니다.' : 'Some tools could not be loaded.'} <button className="settings-extension-button" onClick={() => { setAttempt(n => n + 1); void loadMcpServers() }}>{ko ? '다시 불러오기' : 'Reload'}</button></p>}
      {!available && registry.availability && <p className="plugin-center-hint">{registry.availability.reason}</p>}
      <ul className="plugin-center-list" aria-label={t('settings.pluginCenter.list')}>{visible.map(row => <li className="plugin-center-row" data-feature-id={row.id} key={row.id}>
        <button type="button" className="plugin-center-row__open" onClick={() => openView({ kind: 'row', id: row.id }, row.id)}><PluginFeatureMark row={row} /><span className="plugin-center-row__copy"><strong>{row.name}</strong><span>{row.outcome}</span></span></button>
        <span className="plugin-center-row__status">{row.status}</span>{row.kind === 'preset' ? <button className="settings-extension-button" disabled={!available || actionDisabled} onClick={() => openView({ kind: 'row', id: row.id }, row.id)}>{t('settings.pluginCenter.setup')}</button> : switchFor(row)}
      </li>)}</ul>
      {visible.length === 0 && <p className="plugin-center-empty">{t('settings.pluginCenter.empty')}</p>}
    </> : <>
      <button type="button" className="back-button plugin-center-back" onClick={back}><Icon name="arrow-left" />{t('settings.pluginCenter.back')}</button>
      {selected && <>
        <header className="plugin-center-detail-heading"><PluginFeatureMark row={selected} /><div><h2>{selected.name}</h2><p>{selected.outcome}</p></div></header>
        <div className="plugin-center-detail-state"><span>{selected.status}</span>{selected.kind !== 'preset' && switchFor(selected)}</div>
        {selected.kind === 'study' && <>
          <p>{ko ? '켜면 앱의 도구 목록에서 선택할 수 있습니다. 여기서 켜는 것만으로 자료가 생성되지는 않습니다.' : 'When enabled, this appears in the app’s tools list. Enabling it does not generate materials.'}</p>
          <details className="plugin-center-advanced"><summary>{ko ? '상세 정보' : 'Details'}</summary><p>{`v${selected.summary.pack.version} · ${selected.summary.pack.author}`}</p><p>{selected.summary.pack.schemaVersion === 2 ? ko ? '학습 공간 안에서 사용할 결과를 만듭니다.' : 'Creates results to use inside a learning space.' : ko ? `결과 필기는 ${selected.summary.pack.outputs.dir} 폴더에 저장합니다.` : `Result notes are saved in ${selected.summary.pack.outputs.dir}.`}</p><pre>{selected.summary.pack.recipe}</pre></details>
          {selected.summary.source === 'user' && <div className="plugin-center-actions"><button className="settings-extension-button" onClick={() => { void run(selected.id, async () => { await navigator.clipboard.writeText(JSON.stringify(selected.summary.pack, null, 2)); setFeedback(ko ? '설정을 복사했습니다.' : 'Settings copied.') }) }}>{ko ? '설정 복사' : 'Copy settings'}</button><button className="settings-extension-button settings-extension-button--danger" disabled={actionDisabled} onClick={() => { if (window.confirm(ko ? '이 학습 도구를 삭제할까요?' : 'Remove this study tool?')) void run(selected.id, async () => { await useWorkflowPacksStore.getState().remove(selected.summary.pack.id); back() }) }}>{ko ? '삭제' : 'Remove'}</button></div>}
        </>}
        {selected.kind === 'plugin' && <>
          {!runtime && <p className="plugin-center-hint">{ko ? '확장 기능 실행이 꺼져 있습니다. 이 확장을 켤 때 실행 여부와 권한을 확인합니다.' : 'Extension execution is off. Enabling this extension will review its execution and permissions.'}</p>}
          {selected.plugin.lastError && <p className="plugin-center-feedback" role="alert">{selected.plugin.lastError}</p>}
          <section><h3>{ko ? '사용할 수 있는 작업' : 'Available actions'}</h3><ul>{selected.plugin.manifest.contributes.commands.map(command => <li key={command.id}>{command.title}</li>)}{selected.plugin.manifest.contributes.panels.map(panel => <li key={panel.id}>{panel.title}</li>)}</ul><p>{ko ? '켜면 도구 목록과 해당 메뉴에서 사용할 수 있습니다.' : 'When enabled, these actions appear in the tools list and relevant menus.'}</p></section>
          {(selected.plugin.manifest.contributes.settings?.length ?? 0) > 0 && <PluginConfiguration manifest={selected.plugin.manifest} />}
          <details className="plugin-center-advanced"><summary>{ko ? '권한 및 버전' : 'Permissions and version'}</summary><p>{`v${selected.plugin.manifest.version} · ${selected.plugin.manifest.author}`}</p><ul>{selected.plugin.manifest.permissions.map(permission => <li key={permission}>{describePermission(permission, locale)}</li>)}</ul></details>
          <div className="plugin-center-actions"><button className="settings-extension-button" disabled={actionDisabled || !runtime} onClick={() => { void run(selected.id, async () => { await invoke('plugins:reload', { id: selected.plugin.manifest.id }); await usePluginsStore.getState().refresh() }) }}>{ko ? '다시 시작' : 'Restart'}</button><button className="settings-extension-button" aria-expanded={logsOpen} onClick={() => setLogsOpen(open => !open)}>{ko ? '로그 보기' : 'View logs'}</button><button className="settings-extension-button settings-extension-button--danger" disabled={actionDisabled} onClick={() => { if (window.confirm(t('settings.plugins.confirmUninstall', { name: selected.name }))) void run(selected.id, async () => { await invoke('plugins:uninstall', { id: selected.plugin.manifest.id }); await usePluginsStore.getState().refresh(); back() }) }}>{ko ? '삭제' : 'Remove'}</button></div>
          {logsOpen && <PluginLogs id={selected.plugin.manifest.id} />}
        </>}
        {selected.kind === 'preset' && <PresetSetup key={selected.id} preset={selected.preset} disabled={!available} busy={actionDisabled} onSave={values => { void run(selected.id, async () => { const result = await invoke('mcp:save', { ...selected.preset.input(t(selected.preset.descriptionKey), values), name: availablePresetName(selected.preset, registry.servers), enabled: false }); setView({ kind: 'row', id: `mcp:${result.server.id}` }); await loadMcpServers(); await checkAndEnable(result.server) }) }} />}
        {selected.kind === 'external' && <>
          <p>{ko ? '켜면 화면 도우미의 새 대화에서 이 도구를 사용할 수 있습니다. 일반 학습 대화에는 적용되지 않습니다.' : 'Enabling makes this tool available in new screen assistant conversations. It does not apply to study conversations.'}</p>
          <p className="plugin-center-hint">{ko ? '끄기와 설정 변경도 새 화면 도우미 대화부터 적용됩니다. 제공자와 서비스 권한에 따라 일부 도구는 읽기만 지원할 수 있습니다.' : 'Turning off or changing settings also applies from a new screen assistant conversation. Some tools may be read-only depending on the provider and service permissions.'}</p>
          {selected.server.lastTest && <p>{ko ? '마지막 연결 확인: ' : 'Last connection check: '}<time dateTime={selected.server.lastTest.at}>{new Date(selected.server.lastTest.at).toLocaleString(locale)}</time></p>}
          <p>{ko ? '연결 확인은 서버가 제공하는 도구 목록까지 확인합니다. 계정의 실제 자료 접근 권한은 서비스 설정에 따라 달라집니다.' : 'The connection check verifies the server’s tool list. Access to actual account data depends on your service settings.'}</p>
          {selected.server.lastTest?.error && <p className="plugin-center-feedback" role="alert">{selected.server.lastTest.error}</p>}
          {selected.server.lastTest?.ok && <p>{ko ? `확인한 도구 ${selected.server.lastTest.tools.length}개` : `${selected.server.lastTest.tools.length} tools checked`}</p>}
          <div className="plugin-center-actions"><button className="settings-extension-button" disabled={actionDisabled || !available} onClick={() => { void run(selected.id, async () => { const result = await invoke('mcp:test', { id: selected.server.id }); await loadMcpServers(); if (!result.ok) throw new Error(result.error || (ko ? '설정을 확인한 뒤 다시 시도해 주세요.' : 'Review settings and try again.')) }) }}>{ko ? '연결 다시 확인' : 'Check connection again'}</button><button className="settings-extension-button" disabled={actionDisabled || !available} onClick={() => setEditing(true)}>{ko ? '연결 설정 수정' : 'Edit connection settings'}</button><button className="settings-extension-button settings-extension-button--danger" disabled={actionDisabled} onClick={() => { if (window.confirm(t('settings.mcp.delete.message', { name: selected.name }))) void run(selected.id, async () => { await invoke('mcp:delete', { id: selected.server.id }); await loadMcpServers(); back() }) }}>{ko ? '등록 삭제' : 'Remove registration'}</button></div>
          {editing && <McpServerEditor key={selected.server.id} server={selected.server} disableOnSave submitLabel={ko ? '저장하고 다시 연결' : 'Save and reconnect'} onCancel={() => setEditing(false)} onSaved={savedExternal} />}
          <details className="plugin-center-advanced"><summary>{ko ? '서버와 확인한 도구' : 'Server and checked tools'}</summary><p>{selected.server.name} · {selected.server.transport}</p><code>{selected.server.command ?? selected.server.url}</code><ul>{selected.server.lastTest?.tools.map(tool => <li key={tool}>{tool}</li>)}</ul></details>
        </>}
      </>}
      {view.kind === 'catalog' && <CatalogPanel settings={settings} />}
      {view.kind === 'developer' && <><PluginDevelopmentPanel /><MarketplacePanel /></>}
      {view.kind === 'manual' && <><p>{ko ? '서버 설정을 저장한 뒤 연결을 확인합니다. 성공한 경우에만 사용을 켭니다.' : 'Save the server settings, then check the connection. It is enabled only after success.'}</p><McpServerEditor server={null} submitLabel={ko ? '연결하고 사용하기' : 'Connect and use'} onCancel={back} onSaved={savedExternal} /></>}
      {view.kind === 'import' && <form className="plugin-center-setup" onSubmit={event => { event.preventDefault(); void run('import', async () => { let failed = 0; for (const input of parsedImport.servers) { try { await invoke('mcp:save', { ...input, enabled: false }) } catch { failed++ } } await loadMcpServers(); if (failed) throw new Error(ko ? `${failed}개 서버를 저장하지 못했습니다. 이름 중복과 실행 환경을 확인해 주세요.` : `Could not save ${failed} servers. Check duplicate names and server runtimes.`); setImportText(''); setFilter('external'); back(); setFeedback(ko ? '꺼진 상태로 가져왔습니다. 각 도구의 설정에서 연결을 확인한 뒤 켜 주세요.' : 'Imported with tools off. Check each connection before enabling it.') }) }}>
        <h2>{ko ? 'MCP 설정 가져오기' : 'Import MCP settings'}</h2><p>{ko ? 'Claude Desktop 또는 Cursor의 MCP JSON을 붙여넣으세요. 가져오기만으로 서버를 실행하지 않습니다.' : 'Paste MCP JSON from Claude Desktop or Cursor. Importing does not run the servers.'}</p><label className="settings-mcp-field"><span>MCP JSON</span><textarea rows={8} value={importText} onChange={event => setImportText(event.target.value)} /></label>{parsedImport.errors.map(error => <p role="alert" key={error}>{error}</p>)}<ul>{parsedImport.servers.map(server => <li key={server.name}>{server.name}</li>)}</ul><button className="settings-extension-button settings-extension-button--primary" type="submit" disabled={actionDisabled || !available || !parsedImport.servers.length || parsedImport.errors.length > 0}>{ko ? '꺼진 상태로 가져오기' : 'Import with tools off'}</button>
      </form>}
    </>}
    {feedback && <p className="plugin-center-feedback" role="status">{feedback}</p>}
    {packImportOpen && <ImportDialog onClose={() => setPackImportOpen(false)} />}
    {permissionPlugin && <PluginPermissionDialog plugin={permissionPlugin} pending={actionDisabled} notice={!runtime ? runtimeNotice : undefined} approveLabel={!runtime ? ko ? '승인하고 실행 켜기' : 'Approve and enable execution' : undefined} onApprove={() => { void enablePlugin(permissionPlugin, !runtime) }} onCancel={() => setPermissionPlugin(null)} />}
    {runtimePlugin && <div className="plugin-permission-modal" role="presentation"><section ref={runtimeRef} className="plugin-permission-dialog" role="dialog" aria-modal="true" aria-labelledby="plugin-runtime-title"><h2 id="plugin-runtime-title">{ko ? '확장 기능 실행 켜기' : 'Enable extension execution'}</h2><p>{runtimeNotice}</p><div className="plugin-permission-dialog__actions"><button disabled={actionDisabled} onClick={() => setRuntimePlugin(null)}>{ko ? '취소' : 'Cancel'}</button><button className="plugin-permission-dialog__approve" disabled={actionDisabled} onClick={() => { void enablePlugin(runtimePlugin, true) }}>{ko ? '실행을 켜고 활성화' : 'Enable execution and activate'}</button></div></section></div>}
  </div>
}
