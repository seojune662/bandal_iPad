/** Renderer projection of the installed extension registry. */

import { create } from 'zustand'
import { chordFromKeyboardEvent, parseChord } from '../../../shared/keymap'
import type {
  PluginCommandContribution,
  PluginPanelContribution,
  PluginSummary
} from '../../../shared/types/plugin'
import { invoke, onPush } from '../lib/ipc'
import { settingsSnapshot } from './settingsSnapshot'

export interface InstalledPluginCommand {
  pluginId: string
  pluginName: string
  plugin: PluginSummary
  command: PluginCommandContribution
  actionId: string
}

export interface InstalledPluginPanel {
  pluginId: string
  pluginName: string
  plugin: PluginSummary
  panel: PluginPanelContribution
  panelKey: string
}

export interface PluginsState {
  plugins: PluginSummary[]
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
  runCommand: (pluginId: string, commandId: string, context?: { courseId: string; relPath: string }) => Promise<void>
}

let unsubscribe: (() => void) | null = null
let refreshGeneration = 0

export function pluginCommandActionId(
  pluginId: string,
  commandId: string
): string {
  return `plugin:${pluginId}:${commandId}`
}

export function pluginPanelKey(pluginId: string, panelId: string): string {
  return `plugin-panel:${pluginId}:${panelId}`
}

/** All declared commands, including disabled plugins (useful in Settings). */
export function commandsById(
  state: Pick<PluginsState, 'plugins'>
): ReadonlyMap<string, InstalledPluginCommand> {
  const commands = new Map<string, InstalledPluginCommand>()
  for (const plugin of state.plugins) {
    for (const command of plugin.manifest.contributes.commands) {
      const actionId = pluginCommandActionId(plugin.manifest.id, command.id)
      commands.set(actionId, {
        pluginId: plugin.manifest.id,
        pluginName: plugin.manifest.name,
        plugin,
        command,
        actionId
      })
    }
  }
  return commands
}

/** All declared panels, so persisted tabs can still resolve while disabled. */
export function panelsById(
  state: Pick<PluginsState, 'plugins'>
): ReadonlyMap<string, InstalledPluginPanel> {
  const panels = new Map<string, InstalledPluginPanel>()
  for (const plugin of state.plugins) {
    for (const panel of plugin.manifest.contributes.panels) {
      const panelKey = pluginPanelKey(plugin.manifest.id, panel.id)
      panels.set(panelKey, {
        pluginId: plugin.manifest.id,
        pluginName: plugin.manifest.name,
        plugin,
        panel,
        panelKey
      })
    }
  }
  return panels
}

function canonicalChord(value: string): string | null {
  const parsed = parseChord(value)
  if (parsed === null) return null
  return chordFromKeyboardEvent({
    key: parsed.key,
    metaKey: parsed.mod,
    ctrlKey: false,
    altKey: parsed.alt,
    shiftKey: parsed.shift
  })
}

/**
 * Active plugin chord → command. Per-command settings overrides use the
 * action id (`plugin:<pluginId>:<commandId>`) as their key.
 */
export function chordMap(
  state: Pick<PluginsState, 'plugins'>,
  overrides: Readonly<Record<string, string | null>> =
    settingsSnapshot().keybindings
): ReadonlyMap<string, InstalledPluginCommand> {
  const result = new Map<string, InstalledPluginCommand>()
  for (const item of commandsById(state).values()) {
    if (!item.plugin.enabled || item.plugin.state !== 'active') continue
    const hasOverride = Object.prototype.hasOwnProperty.call(
      overrides,
      item.actionId
    )
    const override = hasOverride ? overrides[item.actionId] : undefined
    if (override === null) continue

    const defaultChord = item.command.defaultChord
    const requested = override ?? defaultChord
    if (requested === null) continue
    const normalized = canonicalChord(requested)
    // Keep a valid manifest default when a persisted override is malformed,
    // matching shared resolveKeymap's invalid-override behavior.
    const fallback =
      normalized === null && override !== undefined && defaultChord !== null
        ? canonicalChord(defaultChord)
        : normalized
    if (fallback !== null) result.set(fallback, item)
  }
  return result
}

export const usePluginsStore = create<PluginsState>()((set) => ({
  plugins: [],
  loading: false,
  error: null,

  refresh: async () => {
    if (unsubscribe === null) {
      unsubscribe = onPush('plugins:changed', ({ plugins }) => {
        refreshGeneration += 1
        set({ plugins, loading: false, error: null })
      })
    }

    const generation = ++refreshGeneration
    set({ loading: true, error: null })
    try {
      const result = await invoke('plugins:list', {})
      if (generation !== refreshGeneration) return
      set({ plugins: result.plugins, loading: false, error: null })
    } catch (error) {
      if (generation !== refreshGeneration) return
      set({
        loading: false,
        error:
          error instanceof Error && error.message.trim().length > 0
            ? error.message
            : '플러그인을 불러오지 못했어요.'
      })
      throw error
    }
  },

  runCommand: async (pluginId, commandId, context) => {
    await invoke('plugins:runCommand', { pluginId, commandId, ...(context ? { context } : {}) })
  }
}))

/** Test-only reset, including the idempotent push subscription. */
export function resetPluginsStoreForTests(): void {
  unsubscribe?.()
  unsubscribe = null
  refreshGeneration += 1
  usePluginsStore.setState({ plugins: [], loading: false, error: null })
}
