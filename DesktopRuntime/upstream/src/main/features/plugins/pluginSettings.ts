import {
  resolvePluginSettings,
  validSettingValue,
} from '../../../shared/plugins/configuration'
import type { PluginManifest } from '../../../shared/types/plugin'
import { ValidationError } from '../../db/errors'
import type { PluginDataStore } from './pluginDataStore'

export function createPluginSettings(deps: {
  data: PluginDataStore
  manifest(id: string): PluginManifest | null
  changed(id: string, values: Record<string, unknown>): void
}) {
  function schema(id: string) {
    const manifest = deps.manifest(id)
    if (manifest === null) throw new ValidationError('unknown plugin')
    return manifest.contributes.settings ?? []
  }
  function get(id: string): Record<string, unknown> {
    return resolvePluginSettings(schema(id), deps.data.get(id))
  }
  return {
    get,
    set(id: string, key: string, value: unknown): void {
      const field = schema(id).find((candidate) => candidate.key === key)
      if (field === undefined || !validSettingValue(field, value))
        throw new ValidationError('invalid plugin setting')
      const stored = deps.data.get(id)
      const current =
        typeof stored === 'object' && stored !== null && !Array.isArray(stored)
          ? stored
          : {}
      deps.data.set(id, { ...current, [key]: value })
      deps.changed(id, get(id))
    },
    reset(id: string): Record<string, unknown> {
      const stored = deps.data.get(id)
      const current =
        typeof stored === 'object' && stored !== null && !Array.isArray(stored)
          ? stored
          : {}
      deps.data.set(id, {
        ...current,
        ...resolvePluginSettings(schema(id), null),
      })
      const values = get(id)
      deps.changed(id, values)
      return values
    },
  }
}
