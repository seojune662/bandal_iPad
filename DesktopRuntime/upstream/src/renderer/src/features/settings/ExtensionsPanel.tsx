import { useEffect, useState } from 'react'
import type {
  PluginLogEntry,
  PluginPermission,
  PluginSummary
} from '../../../../shared/types/plugin'
import { useLocale, useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { usePluginsStore } from '../../stores/pluginsStore'
import { PluginPermissionDialog } from '../plugins/PluginPermissionDialog'
import { PluginConfiguration } from './PluginConfiguration'

export function pluginPermissionsApproved(plugin: PluginSummary): boolean {
  const approved = plugin.approvedPermissions
  return (
    approved !== null &&
    plugin.manifest.permissions.every((permission: PluginPermission) =>
      approved.includes(permission)
    )
  )
}

function publishPlugin(plugin: PluginSummary): void {
  usePluginsStore.setState((state) => {
    const exists = state.plugins.some(
      (item) => item.manifest.id === plugin.manifest.id
    )
    return {
      plugins: exists
        ? state.plugins.map((item) =>
            item.manifest.id === plugin.manifest.id ? plugin : item
          )
        : [...state.plugins, plugin],
      error: null
    }
  })
}

function forgetPlugin(pluginId: string): void {
  usePluginsStore.setState((state) => ({
    plugins: state.plugins.filter((item) => item.manifest.id !== pluginId),
    error: null
  }))
}

function PluginStateChip({ plugin }: { plugin: PluginSummary }): JSX.Element {
  const t = useT()
  return (
    <span
      className="settings-extension-state"
      data-state={plugin.state}
    >
      {t(`settings.plugins.state.${plugin.state}`)}
    </span>
  )
}

function PluginLogs({
  entries,
  loading
}: {
  entries: readonly PluginLogEntry[]
  loading: boolean
}): JSX.Element {
  const locale = useLocale()
  const t = useT()
  if (loading) {
    return <p className="settings-extension-logs__empty">{t('settings.plugins.logs.loading')}</p>
  }
  if (entries.length === 0) {
    return <p className="settings-extension-logs__empty">{t('settings.plugins.logs.empty')}</p>
  }
  return (
    <ol className="settings-extension-logs__list">
      {entries.map((entry, index) => (
        <li key={`${entry.at}:${entry.level}:${index}`} data-level={entry.level}>
          <time dateTime={entry.at}>
            {new Intl.DateTimeFormat(locale, {
              dateStyle: 'short',
              timeStyle: 'medium'
            }).format(new Date(entry.at))}
          </time>
          <span>{entry.level}</span>
          <p>{entry.message}</p>
        </li>
      ))}
    </ol>
  )
}

export interface ExtensionsPanelProps {
  initialOpenLogIds?: readonly string[]
}

export function ExtensionsPanel({
  initialOpenLogIds = []
}: ExtensionsPanelProps = {}): JSX.Element {
  const t = useT()
  const ko = useLocale() === 'ko-KR'
  const plugins = usePluginsStore((state) => state.plugins)
  const loading = usePluginsStore((state) => state.loading)
  const storeError = usePluginsStore((state) => state.error)
  const refresh = usePluginsStore((state) => state.refresh)
  const [pendingId, setPendingId] = useState<string | null>(null)
  const [permissionPlugin, setPermissionPlugin] =
    useState<PluginSummary | null>(null)
  const [openLogIds, setOpenLogIds] = useState<ReadonlySet<string>>(
    () => new Set(initialOpenLogIds)
  )
  const [logsById, setLogsById] = useState<
    Readonly<Record<string, readonly PluginLogEntry[]>>
  >({})
  const [logsLoadingId, setLogsLoadingId] = useState<string | null>(null)
  const [feedback, setFeedback] = useState<string | null>(null)
  const [warnings, setWarnings] = useState<readonly string[]>([])

  useEffect(() => {
    void refresh().catch(() => undefined)
  }, [refresh])

  const fail = (key: string, error: unknown): void => {
    console.error('[Bandal] 플러그인 작업에 실패했습니다.', error)
    setFeedback(t(key))
  }

  const setEnabled = async (
    plugin: PluginSummary,
    enabled: boolean
  ): Promise<void> => {
    if (pendingId !== null) return
    if (
      enabled &&
      (plugin.state === 'needs-approval' ||
        !pluginPermissionsApproved(plugin))
    ) {
      setPermissionPlugin(plugin)
      return
    }
    setPendingId(plugin.manifest.id)
    setFeedback(null)
    try {
      const result = await invoke('plugins:setEnabled', {
        id: plugin.manifest.id,
        enabled
      })
      publishPlugin(result.plugin)
    } catch (error) {
      fail('settings.plugins.error.toggle', error)
    } finally {
      setPendingId(null)
    }
  }

  const approveAndEnable = async (): Promise<void> => {
    const plugin = permissionPlugin
    if (plugin === null || pendingId !== null) return
    setPendingId(plugin.manifest.id)
    setFeedback(null)
    try {
      const approved = await invoke('plugins:approve', {
        id: plugin.manifest.id
      })
      publishPlugin(approved.plugin)
      const enabled = await invoke('plugins:setEnabled', {
        id: plugin.manifest.id,
        enabled: true
      })
      publishPlugin(enabled.plugin)
      setPermissionPlugin(null)
    } catch (error) {
      fail('settings.plugins.error.approve', error)
    } finally {
      setPendingId(null)
    }
  }

  const install = async (): Promise<void> => {
    if (pendingId !== null) return
    setPendingId('__install__')
    setFeedback(null)
    setWarnings([])
    try {
      const picked = await invoke('plugins:pickFolder', {})
      if (picked.path === null) return
      const installed = await invoke('plugins:installFromFolder', {
        path: picked.path
      })
      publishPlugin(installed.plugin)
      setWarnings(installed.warnings)
      setFeedback(t('settings.plugins.installed', {
        name: installed.plugin.manifest.name
      }))
    } catch (error) {
      fail('settings.plugins.error.install', error)
    } finally {
      setPendingId(null)
    }
  }

  const reload = async (plugin: PluginSummary): Promise<void> => {
    if (pendingId !== null) return
    setPendingId(plugin.manifest.id)
    setFeedback(null)
    try {
      const result = await invoke('plugins:reload', {
        id: plugin.manifest.id
      })
      publishPlugin(result.plugin)
    } catch (error) {
      fail('settings.plugins.error.reload', error)
    } finally {
      setPendingId(null)
    }
  }

  const uninstall = async (plugin: PluginSummary): Promise<void> => {
    if (
      pendingId !== null ||
      !window.confirm(
        t('settings.plugins.confirmUninstall', {
          name: plugin.manifest.name
        })
      )
    ) {
      return
    }
    setPendingId(plugin.manifest.id)
    setFeedback(null)
    try {
      await invoke('plugins:uninstall', { id: plugin.manifest.id })
      forgetPlugin(plugin.manifest.id)
    } catch (error) {
      fail('settings.plugins.error.uninstall', error)
    } finally {
      setPendingId(null)
    }
  }

  const toggleLogs = async (pluginId: string): Promise<void> => {
    if (openLogIds.has(pluginId)) {
      setOpenLogIds((current) => {
        const next = new Set(current)
        next.delete(pluginId)
        return next
      })
      return
    }
    setOpenLogIds((current) => new Set([...current, pluginId]))
    setLogsLoadingId(pluginId)
    try {
      const result = await invoke('plugins:logs', { id: pluginId })
      setLogsById((current) => ({
        ...current,
        [pluginId]: result.entries
      }))
    } catch (error) {
      fail('settings.plugins.error.logs', error)
    } finally {
      setLogsLoadingId((current) => (current === pluginId ? null : current))
    }
  }

  return (
    <div className="settings-extensions">
      <div className="settings-extensions__toolbar">
        <div>
          <h2>{t('settings.plugins.title')}</h2>
          <p>{t('settings.plugins.description')}</p>
        </div>
        <button
          type="button"
          className="settings-extension-button settings-extension-button--primary"
          disabled={pendingId !== null}
          onClick={() => void install()}
        >
          {t(
            pendingId === '__install__'
              ? 'settings.plugins.action.installing'
              : 'settings.plugins.action.install'
          )}
        </button>
      </div>

      {warnings.length > 0 && (
        <div className="settings-extension-warnings" role="status">
          <strong>{t('settings.plugins.warnings')}</strong>
          <ul>
            {warnings.map((warning) => <li key={warning}>{warning}</li>)}
          </ul>
        </div>
      )}
      {feedback !== null && (
        <p className="settings-extension-feedback" role="status">{feedback}</p>
      )}

      {loading && plugins.length === 0 ? (
        <p className="settings-extensions__state">{t('settings.plugins.loading')}</p>
      ) : storeError !== null && plugins.length === 0 ? (
        <div className="settings-extensions__state" role="alert">
          <span>{t('settings.plugins.error.load')}</span>
          <button
            type="button"
            className="settings-extension-button"
            onClick={() => void refresh().catch(() => undefined)}
          >
            {t('settings.plugins.action.retry')}
          </button>
        </div>
      ) : plugins.length === 0 ? (
        <p className="settings-extensions__state">{t('settings.plugins.empty')}</p>
      ) : (
        <div className="settings-extensions__list">
          {plugins.map((plugin) => {
            const id = plugin.manifest.id
            const pending = pendingId === id
            const logsOpen = openLogIds.has(id)
            const active =
              plugin.enabled &&
              plugin.state !== 'needs-approval' &&
              pluginPermissionsApproved(plugin)
            return (
              <article className="settings-extension-card" key={id}>
                <div className="settings-extension-card__main">
                  <div className="settings-extension-card__copy">
                    <div className="settings-extension-card__title">
                      <strong>{plugin.manifest.name}</strong>
                      <PluginStateChip plugin={plugin} />
                    </div>
                    <p>{plugin.manifest.description}</p>
                    <small>
                      {t('settings.plugins.metadata', {
                        version: plugin.manifest.version,
                        author: plugin.manifest.author
                      })}
                    </small>
                    {plugin.lastError !== null && (
                      <p className="settings-extension-card__error" role="alert">
                        {plugin.lastError}
                      </p>
                    )}
                  </div>
                  <button
                    type="button"
                    role="switch"
                    aria-label={t('settings.plugins.enabledLabel', {
                      name: plugin.manifest.name
                    })}
                    aria-checked={active}
                    className="settings-extension-switch"
                    data-checked={active ? 'true' : undefined}
                    disabled={pending || pendingId === '__install__'}
                    onClick={() => void setEnabled(plugin, !active)}
                  >
                    <span />
                  </button>
                </div>
                <div className="settings-extension-card__actions">
                  <button
                    type="button"
                    className="settings-extension-button"
                    disabled={pending}
                    onClick={() => void reload(plugin)}
                  >
                    {t('settings.plugins.action.reload')}
                  </button>
                  <button
                    type="button"
                    className="settings-extension-button"
                    aria-expanded={logsOpen}
                    aria-controls={`plugin-logs-${id}`}
                    onClick={() => void toggleLogs(id)}
                  >
                    {t('settings.plugins.action.logs')}
                  </button>
                  <button
                    type="button"
                    className="settings-extension-button settings-extension-button--danger"
                    disabled={pending}
                    onClick={() => void uninstall(plugin)}
                  >
                    {t('settings.plugins.action.uninstall')}
                  </button>
                </div>
                {logsOpen && (
                  <div className="settings-extension-logs" id={`plugin-logs-${id}`}>
                    <PluginLogs
                      entries={logsById[id] ?? []}
                      loading={logsLoadingId === id}
                    />
                  </div>
                )}
                {(plugin.manifest.contributes.settings?.length ?? 0) > 0 && <details className="plugin-configuration-details">
                  <summary>{ko ? '플러그인 설정' : 'Plugin settings'}</summary>
                  <PluginConfiguration manifest={plugin.manifest} />
                </details>}
              </article>
            )
          })}
        </div>
      )}

      {storeError !== null && plugins.length > 0 && (
        <p className="settings-extension-feedback" role="alert">
          {t('settings.plugins.error.load')}
        </p>
      )}
      {permissionPlugin !== null && (
        <PluginPermissionDialog
          plugin={permissionPlugin}
          pending={pendingId === permissionPlugin.manifest.id}
          onCancel={() => {
            if (pendingId === null) setPermissionPlugin(null)
          }}
          onApprove={() => void approveAndEnable()}
        />
      )}
    </div>
  )
}
