/**
 * Ring buffer of recent plugin log lines, surfaced to the settings UI via
 * `plugins:logs`. Denials and errors are also echoed to the main-process
 * console with a `[plugins]` prefix so a broken plugin is diagnosable from
 * the terminal (mirrors `noteBlocked` in browser/hardenWebviews.ts).
 */

import type { PluginLogEntry } from '../../../shared/types/plugin'

export const PLUGIN_LOG_CAPACITY = 200
const MAX_MESSAGE_LENGTH = 2000

export interface PluginLog {
  push(entry: Omit<PluginLogEntry, 'at'>): PluginLogEntry
  /** Newest last. `null` = every plugin. */
  list(pluginId: string | null): PluginLogEntry[]
  clear(pluginId: string | null): void
}

export function createPluginLog(
  deps: { now?: () => string; capacity?: number; warn?: (line: string) => void } = {}
): PluginLog {
  const now = deps.now ?? (() => new Date().toISOString())
  const capacity = deps.capacity ?? PLUGIN_LOG_CAPACITY
  const warn = deps.warn ?? ((line: string) => console.warn(line))
  let entries: PluginLogEntry[] = []

  return {
    push(entry) {
      const message =
        entry.message.length > MAX_MESSAGE_LENGTH
          ? `${entry.message.slice(0, MAX_MESSAGE_LENGTH)}…`
          : entry.message
      const full: PluginLogEntry = { ...entry, message, at: now() }
      entries = [...entries, full].slice(-capacity)
      if (full.level === 'denied' || full.level === 'error') {
        warn(`[plugins] ${full.pluginId}: ${full.level}: ${message}`)
      }
      return full
    },
    list(pluginId) {
      return pluginId === null
        ? [...entries]
        : entries.filter((entry) => entry.pluginId === pluginId)
    },
    clear(pluginId) {
      entries =
        pluginId === null
          ? []
          : entries.filter((entry) => entry.pluginId !== pluginId)
    }
  }
}
