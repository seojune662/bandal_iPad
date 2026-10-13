import { readFileSync, realpathSync, statSync } from 'node:fs'
import { basename, join } from 'node:path'
import type { Session } from 'electron'
import type { BrowserExtensionSummary } from '../../../shared/types/browserExtension'
import type { BrowserExtensionPreference } from '../../../shared/types/settings'

const SUPPORTED_PERMISSIONS = new Set([
  'activeTab',
  'scripting',
  'storage',
  'tabs',
  'unlimitedStorage',
  'webRequest',
  'webRequestBlocking'
])

const UNSUPPORTED_MANIFEST_KEYS = [
  'action',
  'background',
  'browser_action',
  'chrome_url_overrides',
  'commands',
  'declarative_net_request',
  'oauth2',
  'options_page',
  'options_ui',
  'page_action',
  'side_panel'
] as const

interface VerifiedManifest {
  name: string
  version: string
}

function manifestAt(directory: string): VerifiedManifest {
  if (!statSync(directory).isDirectory()) throw new TypeError('확장 경로가 폴더가 아닙니다.')
  const raw: unknown = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8'))
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new TypeError('manifest.json 형식이 올바르지 않습니다.')
  }
  const manifest = raw as Record<string, unknown>
  if (manifest.manifest_version !== 3) {
    throw new TypeError('Manifest V3 확장만 지원합니다.')
  }
  if (
    typeof manifest.name !== 'string' || manifest.name.trim() === '' ||
    typeof manifest.version !== 'string' || manifest.version.trim() === ''
  ) {
    throw new TypeError('확장 이름과 버전이 필요합니다.')
  }
  const unsupportedKey = UNSUPPORTED_MANIFEST_KEYS.find((key) => key in manifest)
  if (unsupportedKey !== undefined) {
    throw new TypeError(`이 빌드가 지원하지 않는 확장 기능입니다: ${unsupportedKey}`)
  }
  const permissions = Array.isArray(manifest.permissions) ? manifest.permissions : []
  const unsupportedPermission = permissions.find((permission) =>
    typeof permission !== 'string' || !SUPPORTED_PERMISSIONS.has(permission)
  )
  if (unsupportedPermission !== undefined) {
    throw new TypeError(`지원하지 않는 확장 권한입니다: ${String(unsupportedPermission)}`)
  }
  return {
    name: manifest.name.trim().slice(0, 160),
    version: manifest.version.trim().slice(0, 80)
  }
}

function message(error: unknown): string {
  return error instanceof Error && error.message !== ''
    ? error.message
    : '확장을 불러오지 못했습니다.'
}

export interface BrowserExtensionManager {
  restore(): Promise<void>
  reconcile(): Promise<void>
  install(path: string): Promise<BrowserExtensionSummary>
  setEnabled(path: string, enabled: boolean): Promise<BrowserExtensionSummary[]>
  remove(path: string): Promise<BrowserExtensionSummary[]>
  list(): BrowserExtensionSummary[]
}

export function createBrowserExtensionManager(deps: {
  session: Session
  getPreferences: () => readonly BrowserExtensionPreference[]
  setPreferences: (preferences: readonly BrowserExtensionPreference[]) => void
}): BrowserExtensionManager {
  const errors = new Map<string, string>()

  function loadedByPath(): Map<string, Electron.Extension> {
    return new Map(
      deps.session.extensions.getAllExtensions().map((extension) => [
        extension.path,
        extension
      ])
    )
  }

  async function load(path: string): Promise<void> {
    try {
      manifestAt(path)
      if (!loadedByPath().has(path)) {
        await deps.session.extensions.loadExtension(path, { allowFileAccess: false })
      }
      errors.delete(path)
    } catch (error) {
      errors.set(path, message(error))
    }
  }

  async function reconcile(): Promise<void> {
    const preferences = deps.getPreferences()
    const enabled = new Set(
      preferences.filter((entry) => entry.enabled).map((entry) => entry.path)
    )
    for (const extension of loadedByPath().values()) {
      if (!enabled.has(extension.path)) {
        deps.session.extensions.removeExtension(extension.id)
      }
    }
    for (const preference of preferences) {
      if (preference.enabled) await load(preference.path)
    }
  }

  function list(): BrowserExtensionSummary[] {
    const loaded = loadedByPath()
    return deps.getPreferences().map((preference) => {
      const extension = loaded.get(preference.path)
      let manifest: VerifiedManifest = {
        name: basename(preference.path),
        version: ''
      }
      try {
        manifest = manifestAt(preference.path)
      } catch (error) {
        if (!errors.has(preference.path)) errors.set(preference.path, message(error))
      }
      const failure = errors.get(preference.path) ?? null
      return {
        id: extension?.id ?? null,
        name: extension?.name ?? manifest.name,
        version: extension?.version ?? manifest.version,
        path: preference.path,
        enabled: preference.enabled,
        status: !preference.enabled
          ? 'disabled'
          : extension !== undefined && failure === null
            ? 'loaded'
            : 'error',
        error: failure
      }
    })
  }

  return {
    restore: reconcile,
    reconcile,
    async install(pathInput) {
      const path = realpathSync(pathInput)
      manifestAt(path)
      const current = deps.getPreferences()
      deps.setPreferences([
        ...current.filter((entry) => entry.path !== path),
        { path, enabled: true }
      ])
      await load(path)
      return list().find((entry) => entry.path === path) as BrowserExtensionSummary
    },
    async setEnabled(path, enabled) {
      deps.setPreferences(deps.getPreferences().map((entry) =>
        entry.path === path ? { ...entry, enabled } : entry
      ))
      await reconcile()
      return list()
    },
    async remove(path) {
      const extension = loadedByPath().get(path)
      if (extension !== undefined) deps.session.extensions.removeExtension(extension.id)
      errors.delete(path)
      deps.setPreferences(deps.getPreferences().filter((entry) => entry.path !== path))
      return list()
    },
    list
  }
}
