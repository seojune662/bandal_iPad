import { useEffect, useState } from 'react'
import type { IDockviewPanelProps } from 'dockview'
import type { TabDescriptor } from '../../../../shared/tabs'
import { useT } from '../../i18n'
import { usePluginsStore } from '../../stores/pluginsStore'
import { useUiStore } from '../../stores/uiStore'
import {
  isPointerPassthroughActive,
  onPointerPassthrough
} from '../browser/webviewPassthrough'
import { isTabDescriptor } from '../workspace/tabIdentity'
import './plugins.css'

type PluginPanelDescriptor = Extract<TabDescriptor, { kind: 'plugin-panel' }>

function pluginDescriptor(params: unknown): PluginPanelDescriptor | null {
  if (typeof params !== 'object' || params === null) return null
  const descriptor = (params as { descriptor?: unknown }).descriptor
  if (!isTabDescriptor(descriptor) || descriptor.kind !== 'plugin-panel') {
    return null
  }
  return descriptor
}

function permissionsApproved(
  plugin: ReturnType<typeof usePluginsStore.getState>['plugins'][number]
): boolean {
  return (
    plugin.approvedPermissions !== null &&
    plugin.manifest.permissions.every((permission) =>
      plugin.approvedPermissions?.includes(permission)
    )
  )
}

function useWebviewPassthrough(): boolean {
  const [external, setExternal] = useState(isPointerPassthroughActive)
  const [dragging, setDragging] = useState(false)

  useEffect(() => onPointerPassthrough(setExternal), [])
  useEffect(() => {
    const start = (): void => setDragging(true)
    const end = (): void => setDragging(false)
    const pointerStart = (event: PointerEvent): void => {
      const target = event.target
      if (target instanceof Element && target.closest('.dv-sash') !== null) {
        start()
      }
    }
    window.addEventListener('dragstart', start, true)
    window.addEventListener('dragend', end, true)
    window.addEventListener('drop', end, true)
    window.addEventListener('pointerdown', pointerStart, true)
    window.addEventListener('pointerup', end, true)
    window.addEventListener('pointercancel', end, true)
    window.addEventListener('blur', end)
    return () => {
      window.removeEventListener('dragstart', start, true)
      window.removeEventListener('dragend', end, true)
      window.removeEventListener('drop', end, true)
      window.removeEventListener('pointerdown', pointerStart, true)
      window.removeEventListener('pointerup', end, true)
      window.removeEventListener('pointercancel', end, true)
      window.removeEventListener('blur', end)
    }
  }, [])
  return external || dragging
}

function Placeholder({
  title,
  description,
  settings = false
}: {
  title: string
  description?: string | null
  settings?: boolean
}): JSX.Element {
  const t = useT()
  return (
    <div className="plugin-panel-placeholder">
      <span className="plugin-panel-placeholder__mark" aria-hidden="true">✦</span>
      <h2>{title}</h2>
      {description !== undefined && description !== null && (
        <p>{description}</p>
      )}
      {settings && (
        <button type="button" onClick={() => useUiStore.getState().openSettings()}>
          {t('plugins.panel.openSettings')}
        </button>
      )}
    </div>
  )
}

export function PluginPanelTab(props: IDockviewPanelProps): JSX.Element {
  const t = useT()
  const descriptor = pluginDescriptor(props.params)
  const plugins = usePluginsStore((state) => state.plugins)
  const refresh = usePluginsStore((state) => state.refresh)
  const passthrough = useWebviewPassthrough()

  useEffect(() => {
    void refresh().catch(() => undefined)
  }, [refresh])

  if (descriptor === null) {
    return <div className="plugin-panel" data-state="invalid" />
  }

  const plugin = plugins.find(
    (item) => item.manifest.id === descriptor.payload.pluginId
  )
  if (plugin === undefined) {
    return (
      <div className="plugin-panel" data-state="missing">
        <Placeholder
          title={t('plugins.panel.missing')}
          description={t('plugins.panel.missingDescription')}
        />
      </div>
    )
  }
  if (plugin.state === 'needs-approval' || !permissionsApproved(plugin)) {
    return (
      <div className="plugin-panel" data-state="needs-approval">
        <Placeholder
          title={t('plugins.panel.needsApproval')}
          description={t('plugins.panel.needsApprovalDescription')}
          settings
        />
      </div>
    )
  }
  if (!plugin.enabled || plugin.state === 'disabled') {
    return (
      <div className="plugin-panel" data-state="disabled">
        <Placeholder
          title={t('plugins.panel.disabled')}
          description={t('plugins.panel.disabledDescription')}
          settings
        />
      </div>
    )
  }
  if (plugin.state === 'errored') {
    return (
      <div className="plugin-panel" data-state="errored">
        <Placeholder
          title={t('plugins.panel.errored')}
          description={plugin.lastError}
          settings
        />
      </div>
    )
  }
  if (plugin.state === 'starting') {
    return (
      <div className="plugin-panel" data-state="starting">
        <Placeholder title={t('plugins.panel.starting')} />
      </div>
    )
  }

  const panel = plugin.manifest.contributes.panels.find(
    (item) => item.id === descriptor.payload.panelId
  )
  if (panel === undefined) {
    return (
      <div className="plugin-panel" data-state="missing-panel">
        <Placeholder
          title={t('plugins.panel.unknown')}
          description={t('plugins.panel.unknownDescription')}
        />
      </div>
    )
  }

  return (
    <div
      className="plugin-panel"
      data-state="active"
      data-passthrough={passthrough ? 'true' : undefined}
    >
      <webview
        src={`bandal-plugin://${plugin.manifest.id}/ui/${panel.entry}`}
        partition={`plugin:${plugin.manifest.id}`}
      />
    </div>
  )
}
