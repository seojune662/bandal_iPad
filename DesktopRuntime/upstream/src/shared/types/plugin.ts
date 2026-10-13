/**
 * Third-party extensions ("확장") — real code, unlike workflow packs.
 *
 * A plugin is a folder under `<userData>/plugins/<id>/` with a manifest, a
 * `main.js` that runs in a dedicated Worker in its own OS-sandboxed
 * Chromium renderer (never the app renderer or the main process), and an optional `ui/` tree served to a
 * `<webview>` on `bandal-plugin://<id>/ui/…`. Everything the plugin can do is
 * an RPC to main gated by the permissions the user approved on first enable.
 *
 * Field names are borrowed from Obsidian's manifest (id, name, version,
 * minAppVersion, description, author) so a port is mostly a rewrite of
 * `main.js` — Obsidian community plugins themselves are NOT loadable: the API,
 * the editor (Milkdown, not CodeMirror) and the sandbox are all different.
 */

export const PLUGIN_MANIFEST_VERSION = 2

/** Capabilities a manifest can request; each maps onto host API methods. */
export const PLUGIN_PERMISSIONS = [
  'courses.read',
  'notes.read',
  'notes.write',
  'materials.read',
  'commands',
  'panel',
  'notices',
  'settings',
  'editor.read',
  'editor.write',
  'menus',
  'themes',
  'events'
] as const

export type PluginStaticPermission = (typeof PLUGIN_PERMISSIONS)[number]

/** `net:<hostname>` — exact https hostname, lowercase, no wildcard in v1. */
export type PluginNetPermission = `net:${string}`

export type PluginPermission = PluginStaticPermission | PluginNetPermission

export const PLUGIN_NET_PERMISSION_PREFIX = 'net:'

/** `/^[a-z0-9][a-z0-9-]{0,62}(\.[a-z0-9][a-z0-9-]{0,62})*$/`, ≤ 128 chars. */
export const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,62}(\.[a-z0-9][a-z0-9-]{0,62})*$/
export const PLUGIN_ID_MAX_LENGTH = 128
/** Command / panel ids: `/^[a-z0-9][a-z0-9-]{0,47}$/`. */
export const PLUGIN_CONTRIBUTION_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,47}$/

export const PLUGIN_LIMITS = {
  nameLength: 40,
  descriptionLength: 300,
  authorLength: 80,
  commands: 32,
  panels: 4,
  manifestBytes: 32 * 1024,
  mainBytes: 2 * 1024 * 1024,
  files: 200,
  totalBytes: 20 * 1024 * 1024,
  settingsBytes: 256 * 1024
} as const

export interface PluginCommandContribution {
  id: string
  title: string
  /** Chord in `shared/keymap.ts` syntax, or null for none. Users may rebind. */
  defaultChord: string | null
}

export interface PluginPanelContribution {
  id: string
  title: string
  /** HTML entry relative to `ui/` (no `..`, no leading slash). */
  entry: string
}

export interface PluginSettingDefinition {
  key: string
  title: string
  description?: string
  type: 'string' | 'number' | 'boolean' | 'select'
  default: string | number | boolean
  options?: readonly string[]
  min?: number
  max?: number
}

export interface PluginMenuContribution {
  command: string
  location: 'editor' | 'materials'
}

export interface PluginThemeContribution {
  id: string
  title: string
  base: 'light' | 'dark'
  tokens: Readonly<Record<string, string>>
}

export interface PluginManifest {
  manifestVersion: 1 | 2
  /** Immutable; settings and data folders key on it. */
  id: string
  name: string
  /** semver */
  version: string
  /** semver; compared with `__APP_VERSION__`. */
  minAppVersion: string
  description: string
  author: string
  /** Single file name inside the plugin folder; default `main.js`. */
  main: string
  permissions: readonly PluginPermission[]
  contributes: {
    commands: readonly PluginCommandContribution[]
    panels: readonly PluginPanelContribution[]
    settings?: readonly PluginSettingDefinition[]
    menus?: readonly PluginMenuContribution[]
    themes?: readonly PluginThemeContribution[]
  }
  /** `styles.css` applied ONLY inside the plugin's own panel pages. */
  styles: 'styles.css' | null
}

export type PluginState =
  | 'disabled'
  | 'needs-approval'
  | 'starting'
  | 'active'
  | 'errored'

export interface PluginSummary {
  manifest: PluginManifest
  enabled: boolean
  state: PluginState
  /** What the user approved; null until first approval. Re-approval is
   * required when the manifest asks for anything outside this set. */
  approvedPermissions: readonly PluginPermission[] | null
  installedAt: string
  lastError: string | null
}

export type PluginLogLevel = 'info' | 'warn' | 'denied' | 'error'

export interface PluginLogEntry {
  at: string
  pluginId: string
  level: PluginLogLevel
  message: string
}
