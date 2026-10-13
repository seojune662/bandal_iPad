/**
 * Wire protocol between the plugin HOST (sandboxed Chromium renderer) and main.
 *
 * Every message is structured-clone-safe JSON. Main is the only side that
 * touches repos, the network or the renderer; the host only runs plugin code
 * and forwards. Identity (`pluginId`) on host→main messages is trusted only
 * after it matches the owner of its dedicated transport — the broker re-checks permissions
 * per call, so a misbehaving plugin cannot borrow another plugin's grants.
 */

import type { PluginManifest } from './plugin'

export type PluginApiMethod =
  | 'courses.list'
  | 'courses.current'
  | 'notes.list'
  | 'notes.read'
  | 'notes.write'
  | 'notes.create'
  | 'materials.list'
  | 'materials.readText'
  | 'notices.show'
  | 'settings.get'
  | 'settings.set'
  | 'panel.post'
  | 'panel.open'
  | 'panel.close'
  | 'net.fetch'
  | 'editor.getSelection'
  | 'editor.replaceSelection'

export const PLUGIN_API_METHODS = [
  'courses.list',
  'courses.current',
  'notes.list',
  'notes.read',
  'notes.write',
  'notes.create',
  'materials.list',
  'materials.readText',
  'notices.show',
  'settings.get',
  'settings.set',
  'panel.post',
  'panel.open',
  'panel.close',
  'net.fetch',
  'editor.getSelection',
  'editor.replaceSelection'
] as const satisfies readonly PluginApiMethod[]

type MissingPluginApiMethod = Exclude<
  PluginApiMethod,
  (typeof PLUGIN_API_METHODS)[number]
>
const _allPluginApiMethodsListed: MissingPluginApiMethod extends never
  ? true
  : never = true
void _allPluginApiMethodsListed

export type PluginErrorCode =
  | 'permission-denied'
  | 'rate-limited'
  | 'not-found'
  | 'validation'
  | 'timeout'
  | 'payload-too-large'
  | 'plugin-not-active'
  | 'internal'

export type PluginEventName = 'note:saved' | 'course:changed' | 'settings:changed'

export const PLUGIN_RPC_PROTOCOL_VERSION = 1

/** Budgets enforced by the broker (main) and mirrored by the host. */
export const PLUGIN_RPC_LIMITS = {
  messageBytes: 1024 * 1024,
  apiTimeoutMs: 10_000,
  commandTimeoutMs: 30_000,
  activateTimeoutMs: 10_000,
  /** Token bucket per plugin: calls per window. */
  apiCallsPerWindow: 60,
  apiWindowMs: 10_000,
  noticesPerMinute: 5,
  fetchesPerMinute: 20,
  fetchResponseBytes: 5 * 1024 * 1024,
  fetchTimeoutMs: 15_000,
  panelMessageBytes: 64 * 1024
} as const

export type HostToMain =
  | { t: 'ready'; protocolVersion: typeof PLUGIN_RPC_PROTOCOL_VERSION }
  | { t: 'activated'; pluginId: string; ok: true; commands: string[] }
  | { t: 'activated'; pluginId: string; ok: false; error: string }
  | { t: 'deactivated'; pluginId: string }
  | {
      t: 'api'
      id: number
      pluginId: string
      method: PluginApiMethod
      args: unknown[]
    }
  | {
      t: 'commandResult'
      id: number
      pluginId: string
      ok: boolean
      error?: string
    }
  | {
      t: 'log'
      pluginId: string
      level: 'info' | 'warn' | 'error'
      message: string
    }

export type MainToHost =
  | {
      t: 'load'
      pluginId: string
      /** Absolute plugin folder; main reads `<dir>/<manifest.main>` and sends source to the sandbox. */
      dir: string
      manifest: PluginManifest
      appVersion: string
    }
  | { t: 'unload'; pluginId: string }
  | { t: 'apiResult'; id: number; ok: true; value: unknown }
  | {
      t: 'apiResult'
      id: number
      ok: false
      error: { code: PluginErrorCode; message: string }
    }
  | { t: 'command'; id: number; pluginId: string; commandId: string; context?: unknown }
  | { t: 'event'; pluginId: string; name: PluginEventName; payload: unknown }
  | { t: 'panelMessage'; pluginId: string; panelId: string; payload: unknown }
  | { t: 'shutdown' }
