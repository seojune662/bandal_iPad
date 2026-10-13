import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from 'react'
import type { PluginSummary } from '../../../../../shared/types/plugin'
import type {
  CatalogEntry,
  PluginCatalog
} from '../../../../../shared/types/pluginCatalog'
import type { Settings } from '../../../../../shared/types/settings'
import type { WorkflowPackSummary } from '../../../../../shared/types/workflowPack'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { useUiStore } from '../../../stores/uiStore'
import { parsePackImportText } from '../packImport'
import { Icon } from '../SettingsIcon'
import { CatalogCard } from './CatalogCard'
import { filterEntries } from './catalogModel'
import { compareSemver } from '../../../../../shared/plugins/semver'
import { SourcesSection } from './SourcesSection'
import './catalog.css'

function entryKey(entry: CatalogEntry): string {
  return `${entry.sourceUrl}:${entry.kind}:${entry.id}`
}

function isCatalog(value: unknown): value is PluginCatalog {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as { entries?: unknown; sources?: unknown }
  return Array.isArray(candidate.entries) && Array.isArray(candidate.sources)
}

function InstallMenu({
  busy,
  onFolder,
  onPackPaste
}: {
  busy: boolean
  onFolder: () => void
  onPackPaste: () => void
}): JSX.Element {
  const t = useT()
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const closeOnPointer = (event: PointerEvent): void => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') setOpen(false)
    }
    document.addEventListener('pointerdown', closeOnPointer)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeOnPointer)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [open])

  return (
    <div className="settings-catalog-install-menu" ref={rootRef}>
      <button
        type="button"
        className="settings-catalog-primary-button"
        aria-haspopup="menu"
        aria-expanded={open}
        disabled={busy}
        onClick={() => setOpen((current) => !current)}
      >
        <span aria-hidden="true">+</span>
        {t('settings.catalog.installMenu.button')}
      </button>
      {open && (
        <div className="settings-catalog-install-menu__popup" role="menu">
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setOpen(false)
              onFolder()
            }}
          >
            <Icon name="folder" />
            {t('settings.catalog.installMenu.folder')}
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setOpen(false)
              onPackPaste()
            }}
          >
            <Icon name="packs" />
            {t('settings.catalog.installMenu.packPaste')}
          </button>
        </div>
      )}
    </div>
  )
}

function PackPasteDialog({
  onClose,
  onImported
}: {
  onClose: () => void
  onImported: () => Promise<void>
}): JSX.Element {
  const t = useT()
  const [text, setText] = useState('')
  const [saving, setSaving] = useState(false)
  const [feedback, setFeedback] = useState<string | null>(null)
  const parsed = useMemo(() => parsePackImportText(text), [text])

  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !saving) onClose()
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [onClose, saving])

  const importPack = async (): Promise<void> => {
    if (saving || parsed.pack === undefined) return
    setSaving(true)
    setFeedback(null)
    try {
      await invoke('packs:importText', { json: text })
      await onImported()
      onClose()
    } catch {
      setFeedback(t('settings.catalog.packPaste.error'))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div
      className="settings-pack-modal"
      role="presentation"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget && !saving) onClose()
      }}
    >
      <section
        className="settings-pack-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-catalog-pack-paste-title"
      >
        <header>
          <h2 id="settings-catalog-pack-paste-title">
            {t('settings.catalog.packPaste.title')}
          </h2>
          <button
            type="button"
            className="settings-pack-button"
            disabled={saving}
            onClick={onClose}
          >
            {t('settings.catalog.packPaste.cancel')}
          </button>
        </header>
        <label className="settings-pack-import-field">
          <span>{t('settings.catalog.packPaste.label')}</span>
          <textarea
            rows={10}
            spellCheck={false}
            value={text}
            onChange={(event) => {
              setText(event.currentTarget.value)
              setFeedback(null)
            }}
          />
        </label>
        {parsed.pack !== undefined && (
          <div className="settings-pack-import-preview">
            <strong>{parsed.pack.name}</strong>
          </div>
        )}
        {parsed.errors.length > 0 && (
          <ul className="settings-pack-errors" role="alert">
            {parsed.errors.map((error) => <li key={error}>{error}</li>)}
          </ul>
        )}
        {feedback !== null && (
          <p className="settings-pack-feedback" role="alert">{feedback}</p>
        )}
        <footer>
          <button
            type="button"
            className="settings-pack-button settings-pack-button--primary"
            disabled={saving || parsed.pack === undefined}
            onClick={() => void importPack()}
          >
            {t(
              saving
                ? 'settings.catalog.packPaste.importing'
                : 'settings.catalog.packPaste.confirm'
            )}
          </button>
        </footer>
      </section>
    </div>
  )
}

export function CatalogPanel({
  settings,
  updatesOnly = false
}: {
  settings: Settings | null
  updatesOnly?: boolean
}): JSX.Element {
  const t = useT()
  const mountedRef = useRef(true)
  const [catalog, setCatalog] = useState<PluginCatalog | null>(null)
  const [catalogFailed, setCatalogFailed] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [plugins, setPlugins] = useState<PluginSummary[]>([])
  const [packs, setPacks] = useState<WorkflowPackSummary[]>([])
  const [query, setQuery] = useState('')
  const [installedOnly, setInstalledOnly] = useState(false)
  const [sourcesOpen, setSourcesOpen] = useState(false)
  const [pendingEntry, setPendingEntry] = useState<string | null>(null)
  const [installErrors, setInstallErrors] = useState<Readonly<Record<string, string>>>({})
  const [manualBusy, setManualBusy] = useState(false)
  const [manualError, setManualError] = useState(false)
  const [packPasteOpen, setPackPasteOpen] = useState(false)

  const loadCatalog = useCallback(async (refresh: boolean): Promise<void> => {
    if (refresh && mountedRef.current) setRefreshing(true)
    try {
      const response: unknown = await invoke('plugins:catalog', { refresh })
      if (!isCatalog(response)) throw new Error('invalid catalog response')
      if (!mountedRef.current) return
      setCatalog(response)
      setCatalogFailed(false)
    } catch {
      if (mountedRef.current) setCatalogFailed(true)
    } finally {
      if (refresh && mountedRef.current) setRefreshing(false)
    }
  }, [])

  const refreshInstalled = useCallback(async (): Promise<void> => {
    const [pluginResult, packResult] = await Promise.allSettled([
      invoke('plugins:list', {}),
      invoke('packs:list', {})
    ])
    if (!mountedRef.current) return
    if (
      pluginResult.status === 'fulfilled' &&
      Array.isArray(pluginResult.value?.plugins)
    ) {
      setPlugins(pluginResult.value.plugins)
    }
    if (
      packResult.status === 'fulfilled' &&
      Array.isArray(packResult.value?.packs)
    ) {
      setPacks(packResult.value.packs)
    }
  }, [])

  useEffect(() => {
    mountedRef.current = true
    void loadCatalog(false).finally(() => void loadCatalog(true))
    void refreshInstalled()
    return () => {
      mountedRef.current = false
    }
  }, [loadCatalog, refreshInstalled])

  const extensionVersions = useMemo(
    () => new Map(plugins.map((plugin) => [plugin.manifest.id, plugin.manifest.version])),
    [plugins]
  )
  const packVersions = useMemo(
    () => new Map(packs.map((summary) => [summary.pack.name, summary.pack.version])),
    [packs]
  )
  const installedIds = useMemo(() => new Set(extensionVersions.keys()), [extensionVersions])
  const installedPackNames = useMemo(() => new Set(packVersions.keys()), [packVersions])
  const entries = catalog?.entries ?? []
  const visibleEntries = filterEntries(entries, {
    query,
    installedOnly,
    installedIds,
    installedPackNames
  }).filter((entry) => {
    if (!updatesOnly) return true
    const installed = entry.kind === 'extension' ? extensionVersions.get(entry.id) : packVersions.get(entry.name)
    return installed !== undefined && compareSemver(entry.version, installed) > 0
  })
  const installedCount = filterEntries(entries, {
    query: '',
    installedOnly: true,
    installedIds,
    installedPackNames
  }).length
  const sourceErrors = (catalog?.sources ?? []).filter((source) => source.status === 'error')
  const runtimeEnabled = settings?.experimental.extensionRuntime ?? false

  const installEntry = async (entry: CatalogEntry): Promise<void> => {
    const key = entryKey(entry)
    if (pendingEntry !== null) return
    setPendingEntry(key)
    setInstallErrors((current) => {
      const next = { ...current }
      delete next[key]
      return next
    })
    try {
      await invoke('plugins:installFromCatalog', {
        sourceUrl: entry.sourceUrl,
        id: entry.id
      })
      await refreshInstalled()
    } catch {
      setInstallErrors((current) => ({
        ...current,
        [key]: t('settings.catalog.card.installFailed')
      }))
    } finally {
      if (mountedRef.current) setPendingEntry(null)
    }
  }

  const installFolder = async (): Promise<void> => {
    if (manualBusy) return
    setManualBusy(true)
    setManualError(false)
    try {
      const picked = await invoke('plugins:pickFolder', {})
      if (picked.path === null) return
      await invoke('plugins:installFromFolder', { path: picked.path })
      await refreshInstalled()
    } catch {
      setManualError(true)
    } finally {
      if (mountedRef.current) setManualBusy(false)
    }
  }

  const updateSources = async (next: readonly string[]): Promise<void> => {
    if (settings === null) throw new Error('settings unavailable')
    await invoke('settings:set', { pluginSources: next })
    await loadCatalog(true)
  }

  const emptyLabel =
    query.trim().length > 0 || installedOnly
      ? t('settings.catalog.noResults')
      : t('settings.catalog.empty')

  return (
    <section className="settings-catalog" aria-label={t('settings.catalog.label')}>
      <div className="settings-catalog-toolbar">
        <div className="segmented settings-catalog-toolbar__segments">
          <button
            type="button"
            className={`segmented__option${!installedOnly ? ' segmented__option--selected' : ''}`}
            aria-pressed={!installedOnly}
            onClick={() => setInstalledOnly(false)}
          >
            {t('settings.catalog.filter.all', { count: entries.length })}
          </button>
          <button
            type="button"
            className={`segmented__option${installedOnly ? ' segmented__option--selected' : ''}`}
            aria-pressed={installedOnly}
            onClick={() => setInstalledOnly(true)}
          >
            {t('settings.catalog.filter.installed', { count: installedCount })}
          </button>
        </div>
        <label className="settings-catalog-search">
          <Icon name="search" />
          <span className="settings-catalog-visually-hidden">
            {t('settings.catalog.search.label')}
          </span>
          <input
            type="search"
            value={query}
            placeholder={t('settings.catalog.search.placeholder')}
            onChange={(event) => setQuery(event.currentTarget.value)}
          />
        </label>
        <button
          type="button"
          className="secondary-button"
          aria-expanded={sourcesOpen}
          aria-controls="settings-catalog-sources"
          onClick={() => setSourcesOpen((current) => !current)}
        >
          {t('settings.catalog.sources.manage')}
        </button>
        <button
          type="button"
          className="secondary-button settings-catalog-refresh"
          disabled={refreshing}
          onClick={() => void loadCatalog(true)}
        >
          <span
            className={refreshing ? 'settings-catalog-refresh__icon--spinning' : undefined}
            aria-hidden="true"
          >
            ↻
          </span>
          {t('settings.catalog.refresh')}
        </button>
        <InstallMenu
          busy={manualBusy}
          onFolder={() => void installFolder()}
          onPackPaste={() => setPackPasteOpen(true)}
        />
      </div>

      {catalogFailed && (
        <div className="inline-notice settings-catalog-notice" role="alert">
          <span>{t('settings.catalog.loadFailed')}</span>
        </div>
      )}
      {manualError && (
        <div className="inline-notice settings-catalog-notice" role="alert">
          <span>{t('settings.catalog.manualInstallFailed')}</span>
        </div>
      )}
      {sourceErrors.map((source) => (
        <div
          className="inline-notice settings-catalog-notice"
          role="alert"
          key={source.url}
        >
          <span>{`${source.url} · ${source.error ?? t('settings.catalog.sources.unknownError')}`}</span>
        </div>
      ))}

      {sourcesOpen && (
        <div id="settings-catalog-sources">
          <SourcesSection
            sources={catalog?.sources ?? []}
            userUrls={settings?.pluginSources ?? []}
            disabled={settings === null}
            onChange={updateSources}
          />
        </div>
      )}

      {catalog === null && !catalogFailed ? (
        <div className="settings-catalog-empty" role="status">
          <span className="settings-catalog-spinner" aria-hidden="true" />
          <span>{t('settings.catalog.loading')}</span>
        </div>
      ) : visibleEntries.length === 0 ? (
        <div className="settings-catalog-empty">
          <Icon name="packs" />
          <span>{emptyLabel}</span>
        </div>
      ) : (
        <div className="settings-catalog-grid">
          {visibleEntries.map((entry) => {
            const key = entryKey(entry)
            const installedVersion =
              entry.kind === 'extension'
                ? extensionVersions.get(entry.id) ?? null
                : packVersions.get(entry.name) ?? null
            return (
              <CatalogCard
                key={key}
                entry={entry}
                installedVersion={installedVersion}
                installing={pendingEntry === key}
                error={installErrors[key] ?? null}
                runtimeEnabled={runtimeEnabled}
                onInstall={() => void installEntry(entry)}
                onOpenExperimental={() =>
                  useUiStore.getState().openSettings('experimental')
                }
              />
            )
          })}
        </div>
      )}

      {packPasteOpen && (
        <PackPasteDialog
          onClose={() => setPackPasteOpen(false)}
          onImported={refreshInstalled}
        />
      )}
    </section>
  )
}
