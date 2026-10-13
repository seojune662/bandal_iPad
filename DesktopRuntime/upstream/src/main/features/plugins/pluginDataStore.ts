/**
 * Per-plugin settings blob (`bandal.settings.get/set`).
 *
 * One JSON file per plugin under `<userData>/plugin-data/<id>.json`, written
 * atomically with mode 0o600 like the workflow-pack store. Capped at
 * `PLUGIN_LIMITS.settingsBytes` so a plugin cannot use the app profile as a
 * disk. A corrupt file is quarantined and read as `null`.
 */

import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import {
  PLUGIN_ID_MAX_LENGTH,
  PLUGIN_ID_PATTERN,
  PLUGIN_LIMITS
} from '../../../shared/types/plugin'
import { ValidationError } from '../../db/errors'
import { quarantineFile, writeFileAtomic } from '../../lib/atomicWrite'

export interface PluginDataStore {
  get(pluginId: string): unknown
  /** `undefined` / functions are not JSON: rejected with ValidationError. */
  set(pluginId: string, value: unknown): void
  remove(pluginId: string): void
}

export const PLUGIN_DATA_DIR = 'plugin-data'

function assertPluginId(pluginId: string): void {
  if (
    typeof pluginId !== 'string' ||
    pluginId.length > PLUGIN_ID_MAX_LENGTH ||
    !PLUGIN_ID_PATTERN.test(pluginId)
  ) {
    throw new ValidationError('invalid plugin id')
  }
}

export function createPluginDataStore(deps: {
  userDataDir: string
  now?: () => Date
}): PluginDataStore {
  const dir = join(deps.userDataDir, PLUGIN_DATA_DIR)
  const fileFor = (pluginId: string): string => {
    assertPluginId(pluginId)
    return join(dir, `${pluginId}.json`)
  }

  return {
    get(pluginId) {
      const file = fileFor(pluginId)
      if (!existsSync(file)) return null
      let text: string
      try {
        text = readFileSync(file, 'utf8')
      } catch (error) {
        console.error('[plugins] settings read failed', pluginId, error)
        throw error
      }
      try {
        return JSON.parse(text) as unknown
      } catch (error) {
        const quarantined = quarantineFile(file, deps.now?.() ?? new Date())
        console.error(
          `[plugins] settings for ${pluginId} were corrupt; moved to ${quarantined ?? '(gone)'}`,
          error
        )
        return null
      }
    },
    set(pluginId, value) {
      const file = fileFor(pluginId)
      let json: string | undefined
      try {
        json = JSON.stringify(value ?? null)
      } catch {
        throw new ValidationError('settings value must be JSON-serializable')
      }
      if (json === undefined) {
        throw new ValidationError('settings value must be JSON-serializable')
      }
      if (Buffer.byteLength(json, 'utf8') > PLUGIN_LIMITS.settingsBytes) {
        throw new ValidationError(
          `settings value exceeds ${PLUGIN_LIMITS.settingsBytes} bytes`
        )
      }
      mkdirSync(dir, { recursive: true })
      writeFileAtomic(file, json, { mode: 0o600 })
    },
    remove(pluginId) {
      rmSync(fileFor(pluginId), { force: true })
    }
  }
}
