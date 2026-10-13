/** Security policy and message transport for plugin panel `<webview>` guests. */

import { session, type Session, type WebContents } from 'electron'
import { PLUGIN_RPC_LIMITS } from '../../../shared/types/pluginRpc'
import type { PluginStore } from './pluginStore'
import {
  createPluginProtocolHandler,
  parsePluginUrl,
  PLUGIN_SCHEME
} from './pluginProtocol'
import { payloadBytes } from './rpcBroker'

const PANEL_CHANNEL = 'bandal-plugin:message'
const PARTITION_PREFIX = 'plugin:'

interface PluginPanelsConfig {
  store: PluginStore
  preloadPath: string
  onPanelMessage(pluginId: string, panelId: string, payload: unknown): void
  log(pluginId: string, message: string): void
}

let config: PluginPanelsConfig | null = null
const registeredProtocols = new Set<string>()
const guests = new Set<WebContents>()
const pluginSessions = new Map<Session, string>()

function pluginIdForPartition(partition: unknown): string | null {
  if (typeof partition !== 'string' || !partition.startsWith(PARTITION_PREFIX)) {
    return null
  }
  const pluginId = partition.slice(PARTITION_PREFIX.length)
  return pluginId === '' ? null : pluginId
}

function activePlugin(pluginId: string) {
  const plugin = config?.store.get(pluginId) ?? null
  if (
    plugin === null ||
    !plugin.enabled ||
    plugin.state !== 'active' ||
    plugin.approvedPermissions === null ||
    !plugin.approvedPermissions.includes('panel')
  ) {
    return null
  }
  return plugin
}

function panelIdForUrl(pluginId: string, url: string): string | null {
  const plugin = activePlugin(pluginId)
  if (plugin === null) return null
  const parsed = parsePluginUrl(url)
  if (parsed === null || parsed.pluginId !== pluginId || parsed.isStyles) return null
  const entry = parsed.segments.join('/')
  return (
    plugin.manifest.contributes.panels.find((panel) => panel.entry === entry)
      ?.id ?? null
  )
}

function isPluginUrl(pluginId: string, url: string): boolean {
  const parsed = parsePluginUrl(url)
  return parsed !== null && parsed.pluginId === pluginId
}

function registerPanelProtocol(pluginId: string): void {
  if (config === null || registeredProtocols.has(pluginId)) return
  const partition = `${PARTITION_PREFIX}${pluginId}`
  const panelSession = session.fromPartition(partition)
  pluginSessions.set(panelSession, pluginId)
  panelSession.setPermissionCheckHandler(() => false)
  panelSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false)
  })
  panelSession.protocol.handle(
    PLUGIN_SCHEME,
    createPluginProtocolHandler({
      rootFor: (requestedId) => {
        if (requestedId !== pluginId) return null
        return config?.store.get(requestedId) === null
          ? null
          : (config?.store.dirFor(requestedId) ?? null)
      },
      stylesFor: (requestedId) =>
        requestedId === pluginId &&
        config?.store.manifestFor(requestedId)?.styles === 'styles.css'
    })
  )
  registeredProtocols.add(pluginId)
}

export function configurePluginPanels(next: PluginPanelsConfig): () => void {
  config = next
  return () => {
    if (config === next) config = null
    guests.clear()
  }
}

/**
 * Handles a plugin guest during `will-attach-webview`.
 * Returns true when the request was recognized and safely configured.
 */
export function preparePluginPanelWebview(
  params: Record<string, string>,
  webPreferences: Record<string, unknown>
): boolean {
  if (config === null) return false
  const pluginId = pluginIdForPartition(params['partition'])
  const src = params['src'] ?? ''
  if (pluginId === null || panelIdForUrl(pluginId, src) === null) return false

  registerPanelProtocol(pluginId)
  delete params['preload']
  delete webPreferences['preloadURL']
  webPreferences['preload'] = config.preloadPath
  webPreferences['partition'] = `${PARTITION_PREFIX}${pluginId}`
  webPreferences['nodeIntegration'] = false
  webPreferences['nodeIntegrationInSubFrames'] = false
  webPreferences['nodeIntegrationInWorker'] = false
  webPreferences['contextIsolation'] = true
  webPreferences['sandbox'] = true
  webPreferences['webSecurity'] = true
  webPreferences['allowRunningInsecureContent'] = false
  webPreferences['experimentalFeatures'] = false
  webPreferences['enableBlinkFeatures'] = ''
  webPreferences['webviewTag'] = false
  webPreferences['plugins'] = false
  webPreferences['safeDialogs'] = true
  return true
}

/** Returns true when `guest` belongs to a configured plugin panel. */
export function attachPluginPanelGuest(guest: WebContents): boolean {
  if (config === null) return false
  const pluginId = pluginSessions.get(guest.session) ?? null
  if (pluginId === null || activePlugin(pluginId) === null) return false
  guests.add(guest)

  const guard = (event: Electron.Event, url: string): void => {
    if (!isPluginUrl(pluginId, url)) event.preventDefault()
  }
  guest.on('will-navigate', guard)
  guest.on('will-redirect', guard)
  guest.setWindowOpenHandler(() => ({ action: 'deny' }))
  guest.on('ipc-message', (_event, channel, ...args) => {
    if (channel !== PANEL_CHANNEL || args.length !== 1 || config === null) return
    const panelId = panelIdForUrl(pluginId, guest.getURL())
    if (panelId === null) return
    const payload = args[0]
    if (payloadBytes(payload) > PLUGIN_RPC_LIMITS.panelMessageBytes) {
      config.log(pluginId, 'panel message rejected: payload is too large')
      return
    }
    config.onPanelMessage(pluginId, panelId, payload)
  })
  guest.once('destroyed', () => guests.delete(guest))
  return true
}

export function postPluginPanelMessage(
  pluginId: string,
  panelId: string,
  payload: unknown
): void {
  if (config === null) return
  if (payloadBytes(payload) > PLUGIN_RPC_LIMITS.panelMessageBytes) {
    throw new Error('panel message payload is too large')
  }
  for (const guest of guests) {
    if (guest.isDestroyed()) continue
    const guestPluginId = pluginSessions.get(guest.session) ?? null
    if (
      guestPluginId !== pluginId ||
      panelIdForUrl(pluginId, guest.getURL()) !== panelId
    ) {
      continue
    }
    try {
      guest.send(PANEL_CHANNEL, payload)
    } catch (error) {
      config.log(
        pluginId,
        `panel message delivery failed: ${
          error instanceof Error ? error.message : String(error)
        }`
      )
    }
  }
}
