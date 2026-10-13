import { useCallback, useEffect, useMemo, useState } from 'react'
import type { PluginSummary } from '../../../../shared/types/plugin'
import type { NativeStudyExperience, WorkflowPackFollowUp, WorkflowPackOutputs, WorkflowPackScope, WorkflowPackSummary } from '../../../../shared/types/workflowPack'
import { pluginCommandActionId, pluginPanelKey, usePluginsStore } from '../../stores/pluginsStore'
import { ensureSettingsLoaded, settingsSnapshot } from '../../stores/settingsSnapshot'
import { useWorkflowPacksStore } from '../../stores/workflowPacksStore'
import { onPush } from '../../lib/ipc'

interface FeatureEntryBase {
  id: string
  label: string
  description: string
  source: 'builtin' | 'user' | 'extension'
  enabled: boolean
  category?: 'native-study' | 'document-pack' | 'extension'
  /** Installed/runtime availability; target-specific scope is resolved separately. */
  unavailableReason: string | null
}
export interface PackFeatureEntry extends FeatureEntryBase {
  kind: 'pack'
  packId: string
  schemaVersion: 1 | 2
  worksOn: readonly WorkflowPackScope[]
  experience?: NativeStudyExperience
  usesWeb: boolean
  outputs: WorkflowPackOutputs
  followUp?: WorkflowPackFollowUp
}
export interface PluginCommandFeatureEntry extends FeatureEntryBase {
  kind: 'plugin-command'
  pluginId: string
  pluginName: string
  commandId: string
  defaultChord: string | null
  menuLocations: readonly ('editor' | 'materials')[]
}
export interface PluginPanelFeatureEntry extends FeatureEntryBase {
  kind: 'plugin-panel'
  pluginId: string
  pluginName: string
  panelId: string
}
export type FeatureEntry = PackFeatureEntry | PluginCommandFeatureEntry | PluginPanelFeatureEntry

function pluginUnavailable(plugin: PluginSummary, permission: 'commands' | 'panel', runtime: boolean): string | null {
  if (!runtime) return '플러그인 실행이 꺼져 있어요. 설정에서 켤 수 있어요.'
  if (!plugin.enabled || plugin.state === 'disabled') return '플러그인이 비활성화되어 있어요.'
  if (plugin.state === 'needs-approval' || !plugin.approvedPermissions?.includes(permission)) return '플러그인 권한 승인이 필요해요.'
  if (plugin.state === 'starting') return '플러그인을 시작하는 중이에요.'
  if (plugin.state === 'errored') return plugin.lastError || '플러그인을 시작하지 못했어요.'
  return null
}

/** Presentation references only. Execution always uses the existing host APIs. */
export function buildFeatureInventory(packs: readonly WorkflowPackSummary[], plugins: readonly PluginSummary[], extensionRuntime: boolean): FeatureEntry[] {
  const entries: FeatureEntry[] = packs.map(({ pack, source, enabled }): PackFeatureEntry => ({
    kind: 'pack', id: `pack:${pack.id}`, packId: pack.id, label: pack.name,
    description: pack.description, source, enabled, category: pack.schemaVersion === 2 ? 'native-study' : 'document-pack',
    unavailableReason: enabled ? null : '학습 팩이 비활성화되어 있어요.',
    schemaVersion: pack.schemaVersion, worksOn: pack.worksOn, usesWeb: pack.usesWeb, outputs: pack.outputs,
    ...(pack.schemaVersion === 2 ? { experience: pack.experience } : {}),
    ...(pack.followUp ? { followUp: pack.followUp } : {})
  }))
  for (const plugin of plugins) {
    const { manifest } = plugin
    for (const command of manifest.contributes.commands) entries.push({
      kind: 'plugin-command', id: pluginCommandActionId(manifest.id, command.id),
      pluginId: manifest.id, pluginName: manifest.name, commandId: command.id,
      label: command.title, description: manifest.description, source: 'extension', enabled: plugin.enabled,
      unavailableReason: pluginUnavailable(plugin, 'commands', extensionRuntime), defaultChord: command.defaultChord,
      menuLocations: (manifest.contributes.menus ?? []).filter(menu => menu.command === command.id).map(menu => menu.location)
    })
    for (const panel of manifest.contributes.panels) entries.push({
      kind: 'plugin-panel', id: pluginPanelKey(manifest.id, panel.id),
      pluginId: manifest.id, pluginName: manifest.name, panelId: panel.id,
      label: panel.title, description: manifest.description, source: 'extension', enabled: plugin.enabled,
      unavailableReason: pluginUnavailable(plugin, 'panel', extensionRuntime)
    })
  }
  return entries
}

export function useFeatureInventory(): { entries: FeatureEntry[]; loading: boolean; error: string | null; reload: () => Promise<void> } {
  const packs = useWorkflowPacksStore(state => state.packs)
  const packsLoading = useWorkflowPacksStore(state => state.loading)
  const packsLoaded = useWorkflowPacksStore(state => state.hasLoaded)
  const packsError = useWorkflowPacksStore(state => state.error)
  const plugins = usePluginsStore(state => state.plugins)
  const pluginsLoading = usePluginsStore(state => state.loading)
  const pluginsError = usePluginsStore(state => state.error)
  const [runtime, setRuntime] = useState(settingsSnapshot().experimental.extensionRuntime)
  const [settingsError, setSettingsError] = useState<string | null>(null)
  const reload = useCallback(async () => {
    await Promise.allSettled([useWorkflowPacksStore.getState().refresh(), usePluginsStore.getState().refresh(),
      ensureSettingsLoaded().then(settings => { setRuntime(settings.experimental.extensionRuntime); setSettingsError(null) })
        .catch(() => setSettingsError('플러그인 실행 설정을 불러오지 못했어요.'))])
  }, [])
  useEffect(() => {
    let active = true, pushed = false
    const stop = onPush('settings:changed', ({ settings }) => {
      pushed = true
      if (active) { setRuntime(settings.experimental.extensionRuntime); setSettingsError(null) }
    })
    void ensureSettingsLoaded().then(settings => {
      if (active && !pushed) { setRuntime(settings.experimental.extensionRuntime); setSettingsError(null) }
    }).catch(() => { if (active) setSettingsError('플러그인 실행 설정을 불러오지 못했어요.') })
    void Promise.allSettled([useWorkflowPacksStore.getState().load(), usePluginsStore.getState().refresh()])
    return () => { active = false; stop() }
  }, [])
  const entries = useMemo(() => buildFeatureInventory(packs, plugins, runtime), [packs, plugins, runtime])
  return { entries, loading: packsLoading || pluginsLoading || (!packsLoaded && !packsError),
    error: packsError ?? pluginsError ?? settingsError, reload }
}
