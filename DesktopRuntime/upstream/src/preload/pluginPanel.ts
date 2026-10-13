/** Minimal bridge for sandboxed `bandal-plugin://` panel guests. */

import { contextBridge, ipcRenderer } from 'electron'

type PluginPanelListener = (payload: unknown) => void

const CHANNEL = 'bandal-plugin:message'
const listeners = new Set<PluginPanelListener>()

ipcRenderer.on(CHANNEL, (_event, payload: unknown) => {
  for (const listener of listeners) listener(payload)
})

contextBridge.exposeInMainWorld(
  'bandal',
  Object.freeze({
    postMessage(payload: unknown): void {
      // Main owns the permission/rate-limit boundary. `sendToHost` would emit
      // only on the embedding renderer's <webview> DOM node and bypass the
      // WebContents `ipc-message` listener installed by pluginPanels.ts.
      ipcRenderer.send(CHANNEL, payload)
    },
    onMessage(listener: unknown): () => void {
      if (typeof listener !== 'function') {
        throw new TypeError('onMessage expects a function')
      }
      const callback = listener as PluginPanelListener
      listeners.add(callback)
      return () => listeners.delete(callback)
    }
  })
)
